#!/usr/bin/env bash
# shellcheck disable=SC2329  # fonctions de test appelées indirectement via check()
# =============================================================================
# Vérification automatique du Lab 2 — Pipeline Kubeflow + Airflow
# Lancer depuis la racine du repo :  make check-m2
# Pré-requis : port-forwards actifs (make pf) et .env présent (cp .env.example .env).
# L'API KFP est jointe sur KFP_HOST (défaut http://localhost:8080, port-forward de l'UI) ;
# à défaut, un port-forward temporaire est ouvert le temps du script.
# Tout ce qui dépend du dataset (colonnes, cible, métrique, seuil) est lu dans dataset.yaml.
# Code retour = nombre de vérifications en échec (0 = tout est vert).
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

ENV_FILE=.env
[ -f "$ENV_FILE" ] || ENV_FILE=.env.example
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
export MLFLOW_DISABLE_AGENT_HINT=1 PYTHONWARNINGS=ignore

FAILS=0
TOTAL=0
K=(kubectl --context kind-mlops-lab)
KFP_HOST=${KFP_HOST:-http://localhost:8080}
PIPELINE=scoring-pipeline
EXPERIMENT=scoring
MODEL_NAME=scoring-model
DAG_FILE=dags/scoring_dag.py
REPORT=reports/rapport-m2.md
AF=(docker compose --project-directory infra/airflow)
TMP=$(mktemp -d)
PF_PID=""
cleanup() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

# Exécute une commande avec un délai maximal (timeout absent sur macOS sans coreutils).
t() {
  local secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else "$@"; fi
}

# Lance la venv du repo sans la resynchroniser.
py() { t 120 uv run --no-sync python "$@"; }

# check "libellé" "indice en cas d'échec" commande [args...]
check() {
  local label=$1 hint=$2
  shift 2
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    echo "✅ ${label}"
  else
    echo "❌ ${label}  →  ${hint}"
    FAILS=$((FAILS + 1))
  fi
}

# --- Kubeflow Pipelines ---------------------------------------------------------
kfp_deploys_ok() { t 40 "${K[@]}" -n kubeflow wait --for=condition=Available deploy --all --timeout=30s; }
kfp_store_ok() {
  "${K[@]}" -n kubeflow get deploy seaweedfs &&
    "${K[@]}" -n kubeflow get secret mlpipeline-minio-artifact
}
kfp_api_ok() { t 10 curl -fsS "${KFP_HOST}/apis/v2beta1/healthz"; }

# --- Code du lab ------------------------------------------------------------------
validate_ok() {
  # Le gate de validation sur le fichier brut, via pipelines/stage.py (dossier temporaire :
  # le repo n'est pas modifié)
  py - <<'EOF'
from pipelines.stage import run_stage
from src.dataset_config import load_config

cfg = load_config()
run_stage("src.validate_data", inputs={cfg.raw_path: cfg.raw_path})
EOF
}
image_ok() {
  local img reg rest repo tag
  img=$(py -c "from pipelines.components import PIPELINE_IMAGE as i; print(i)") || return 1
  reg=${img%%/*}
  rest=${img#*/}
  repo=${rest%:*}
  tag=${rest##*:}
  t 10 curl -fsS "http://${reg}/v2/${repo}/tags/list" | grep -q "\"${tag}\""
}
components_ok() {
  py - <<'EOF'
from pipelines import components as c

names = ["ingest_data", "validate_data", "prepare_features", "train_model",
         "evaluate_model", "register_model"]
for name in names:
    image = getattr(c, name).component_spec.implementation.container.image
    assert image == c.PIPELINE_IMAGE, f"{name} : image {image}"
EOF
}
compile_ok() {
  py - "$TMP/pipeline.yaml" <<'EOF'
import sys

import yaml
from kfp import compiler

from pipelines.scoring_pipeline import scoring_pipeline

compiler.Compiler().compile(scoring_pipeline, package_path=sys.argv[1])
spec = next(yaml.safe_load_all(open(sys.argv[1])))
assert spec["pipelineInfo"]["name"] == "scoring-pipeline"
EOF
}
policies_ok() {
  [ -f "$TMP/pipeline.yaml" ] || return 1
  py - "$TMP/pipeline.yaml" <<'EOF'
import sys

import yaml

docs = list(yaml.safe_load_all(open(sys.argv[1])))
spec, text = docs[0], open(sys.argv[1]).read()
tasks = spec["root"]["dag"]["tasks"]
assert "maxRetryCount" in text, "aucun set_retry"
assert "activeDeadlineSeconds" in text, "aucun kubernetes.set_timeout"
executors = spec["deploymentSpec"]["executors"].values()
assert all("resourceMemoryLimit" in e["container"].get("resources", {}) for e in executors)
train = next(t for name, t in tasks.items() if name.startswith("train"))
assert not train.get("cachingOptions", {}).get("enableCache"), "cache actif sur le train"
EOF
}
hardcode_ok() {
  # Ni identifiant S3 en dur, ni nom de colonne de dataset.yaml dans le code orchestré
  ! grep -rEq "mlops-lab-secret|minio123|minioadmin|AWS_SECRET_ACCESS_KEY\"? *[:=] *\"[^\"$]" \
    pipelines dags 2>/dev/null || return 1
  py - <<'EOF'
import re
from pathlib import Path

from src.dataset_config import load_config

cfg = load_config()
files = ["pipelines/components.py", "pipelines/scoring_pipeline.py", "dags/scoring_dag.py"]
code = "\n".join(Path(f).read_text() for f in files if Path(f).exists())
found = [c for c in cfg.columns if re.search(rf"[\"']{re.escape(c)}[\"']", code)]
assert not found, f"colonnes en dur : {found}"
EOF
}

# --- Runs KFP (une seule requête, résultat dans $TMP/kfp.json) ---------------------
query_kfp() {
  py - "$KFP_HOST" "$TMP/kfp.json" "$PIPELINE" <<'EOF'
import json
import sys

import kfp

host, out, name = sys.argv[1:4]
client = kfp.Client(host=host)
pipeline_id = client.get_pipeline_id(name)
runs, token = [], ""
while True:
    resp = client.list_runs(page_token=token, page_size=100, sort_by="created_at desc")
    runs += resp.runs or []
    token = resp.next_page_token
    if not token or len(runs) >= 1000:
        break


def is_ours(run):
    ref = run.pipeline_version_reference
    if ref and pipeline_id and ref.pipeline_id == pipeline_id:
        return True
    spec = run.pipeline_spec or {}
    spec = spec.get("pipeline_spec", spec)  # spec + platform_spec (kfp-kubernetes)
    return spec.get("pipelineInfo", {}).get("name") == name


ok = [r.run_id for r in runs if r.state == "SUCCEEDED" and is_ours(r)]
json.dump({"pipeline": bool(pipeline_id), "succeeded": ok}, open(out, "w"))
EOF
}
kfp_pipeline_ok() { grep -q '"pipeline": true' "$TMP/kfp.json"; }
kfp_runs_ok() { # kfp_runs_ok N : au moins N runs réussis
  py -c "import json,sys; sys.exit(len(json.load(open('$TMP/kfp.json'))['succeeded']) < $1)"
}

# --- MLflow --------------------------------------------------------------------------
mlflow_health() { [ "$(t 10 curl -fsS "${MLFLOW_TRACKING_URI}/health")" = "OK" ]; }
kfp_mlflow_ok() { # runs MLflow lancés par un run KFP réussi -> $TMP/kfp_runs.json
  [ -f "$TMP/kfp.json" ] || return 1
  py - "$TMP/kfp.json" "$TMP/kfp_runs.json" <<EOF
import json
import sys

from mlflow import MlflowClient

from src.dataset_config import load_config

cfg = load_config()
succeeded = set(json.load(open(sys.argv[1]))["succeeded"])
client = MlflowClient()
exp = client.get_experiment_by_name("${EXPERIMENT}")
runs = client.search_runs(
    [exp.experiment_id], "tags.launched_by = 'kfp' and attributes.status = 'FINISHED'",
    max_results=500,
)
linked = [r.info.run_id for r in runs if r.data.tags.get("kfp_run_id") in succeeded
          and cfg.primary_metric in r.data.metrics and "decision_threshold" in r.data.params]
json.dump(linked, open(sys.argv[2], "w"))
assert linked, "aucun run MLflow relié à un run KFP réussi"
EOF
}
kfp_version_ok() {
  [ -f "$TMP/kfp_runs.json" ] || return 1
  py - "$TMP/kfp_runs.json" <<EOF
import json
import sys

from mlflow import MlflowClient

runs = set(json.load(open(sys.argv[1])))
versions = MlflowClient().search_model_versions("name = '${MODEL_NAME}'")
assert any(v.run_id in runs for v in versions), "aucune version produite par KFP"
EOF
}

# --- Airflow ---------------------------------------------------------------------------
dag_file_ok() {
  [ -f "$DAG_FILE" ] || return 1
  py - "$DAG_FILE" <<'EOF'
import ast
import sys

from pipelines.components import PIPELINE_IMAGE

source = open(sys.argv[1]).read()
tree = ast.parse(source)
assert '"scoring_dag"' in source, "dag_id scoring_dag absent"
images = [n.value.value for n in ast.walk(tree) if isinstance(n, ast.Assign)
          and any(getattr(t, "id", "") == "IMAGE" for t in n.targets)]
assert images == [PIPELINE_IMAGE], f"IMAGE du DAG {images} != {PIPELINE_IMAGE}"
EOF
}
airflow_mlflow_ok() {
  py - <<EOF
from mlflow import MlflowClient

from src.dataset_config import load_config

cfg = load_config()
client = MlflowClient()
exp = client.get_experiment_by_name("${EXPERIMENT}")
runs = client.search_runs(
    [exp.experiment_id], "tags.launched_by = 'airflow' and attributes.status = 'FINISHED'",
    max_results=50,
)
assert any(cfg.primary_metric in r.data.metrics for r in runs), "aucun run Airflow"
EOF
}
airflow_up() { t 20 "${AF[@]}" ps --services --status running 2>/dev/null | grep -qx airflow-scheduler; }
airflow_live_ok() {
  local errors dags runs
  errors=$(t 90 "${AF[@]}" exec -T airflow-scheduler airflow dags list-import-errors -o json \
    2>/dev/null | tail -n 1)
  ! grep -q "scoring_dag" <<<"$errors" || return 1
  dags=$(t 90 "${AF[@]}" exec -T airflow-scheduler airflow dags list -o json 2>/dev/null |
    tail -n 1)
  runs=$(t 90 "${AF[@]}" exec -T airflow-scheduler airflow dags list-runs scoring_dag \
    --state success -o json 2>/dev/null | tail -n 1)
  py - "$dags" "$runs" <<'EOF'
import json
import sys

dags = {d["dag_id"]: d for d in json.loads(sys.argv[1] or "[]")}
assert "scoring_dag" in dags, "DAG non chargé"
assert str(dags["scoring_dag"]["is_paused"]) != "True", "DAG en pause"
assert json.loads(sys.argv[2] or "[]"), "aucun run réussi"
EOF
}

# --- Rapport ---------------------------------------------------------------------------
report_ok() {
  [ -f "$REPORT" ] || return 1
  [ "$(wc -w <"$REPORT")" -ge 350 ] || return 1
  ! grep -q "TODO" "$REPORT" || return 1
  local s
  for s in Contexte "sultats" Analyse Recommandation Limites; do
    grep -qiE "^#+ .*${s}" "$REPORT" || return 1
  done
}

# --- Checklist ---------------------------------------------------------------------------
echo "Lab 2 — vérification (KFP : ${KFP_HOST}, MLflow : ${MLFLOW_TRACKING_URI})"
echo
check "KFP : déploiements du namespace kubeflow disponibles" "make kfp (étape 1)" kfp_deploys_ok
check "KFP : SeaweedFS interne (stockage des artefacts) présent" "make kfp (étape 1)" \
  kfp_store_ok
if ! kfp_api_ok >/dev/null 2>&1; then # port-forward temporaire vers l'UI/API KFP
  "${K[@]}" -n kubeflow port-forward svc/ml-pipeline-ui 18080:80 >/dev/null 2>&1 &
  PF_PID=$!
  KFP_HOST="http://localhost:18080"
  sleep 4
fi
check "KFP : API joignable (${KFP_HOST})" "make kfp-ui (étape 1.3)" kfp_api_ok
check "src/validate_data.py : fichier brut conforme au contrat (via pipelines/stage.py)" \
  "étapes 2.2-2.3 ; dvc pull si data/raw est vide" validate_ok
check "Image du pipeline (PIPELINE_IMAGE) dans le registry local" \
  "docker build + docker push (étape 2.4)" image_ok
check "6 composants KFP sur l'image du projet (pipelines/components.py)" "étape 2.5" \
  components_ok
check "Pipeline 'scoring-pipeline' compilé" "python -m pipelines.scoring_pipeline (étape 3)" \
  compile_ok
check "Retries, limites mémoire, timeouts, cache désactivé sur le train" "étape 6.1" policies_ok
check "Aucun identifiant S3 ni nom de colonne en dur (pipelines/, dags/)" \
  "lire dataset.yaml via load_config (étape 2)" hardcode_ok
query_kfp >/dev/null 2>&1
check "KFP : pipeline '${PIPELINE}' uploadé" "Upload pipeline, nom exact (étape 4.1)" \
  kfp_pipeline_ok
check "KFP : au moins 1 run réussi de '${PIPELINE}'" "Create run (étape 4.2)" kfp_runs_ok 1
check "KFP : au moins 2 runs réussis (test du cache)" "relancer un run (étape 6.2)" \
  kfp_runs_ok 2
check "MLflow : ${MLFLOW_TRACKING_URI}/health = OK" "make pf" mlflow_health
check "MLflow : run launched_by=kfp relié à un run KFP réussi (kfp_run_id)" \
  "étapes 4 et 5.1" kfp_mlflow_ok
check "Registry : une version de '${MODEL_NAME}' produite par KFP" "register_model (étape 5)" \
  kfp_version_ok
check "Airflow : ${DAG_FILE} (DAG scoring_dag, même image que KFP)" "étape 7.2" dag_file_ok
check "Airflow : run MLflow launched_by=airflow terminé" "déclencher scoring_dag (étape 7.3)" \
  airflow_mlflow_ok
if airflow_up; then
  check "Airflow : DAG chargé sans erreur, activé, avec un run réussi" \
    "airflow dags list-import-errors ; toggle ON ; Trigger (étape 7.3)" airflow_live_ok
else
  echo "⏭️  Airflow arrêté : vérification du DAG dans Airflow ignorée (make airflow pour l'inclure)"
fi
check "${REPORT} : ~500 mots, 5 sections, sans TODO" \
  "partir de labs/m2-pipelines/starter/rapport-m2.md et remplacer chaque TODO (étape 9)" report_ok

echo
if [ "$FAILS" -eq 0 ]; then
  echo "🎉 ${TOTAL}/${TOTAL} vérifications OK — Lab 2 validé."
else
  echo "${FAILS} échec(s) sur ${TOTAL} vérifications."
fi
exit $((FAILS > 255 ? 255 : FAILS))
