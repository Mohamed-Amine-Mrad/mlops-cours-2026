#!/usr/bin/env bash
# shellcheck disable=SC2329  # fonctions de test appelées indirectement via check()
# =============================================================================
# Vérification automatique du Lab 3 — Validation des données et du modèle
# Lancer depuis la racine du repo :  make check-m3
# Pré-requis : port-forwards actifs (make pf), .env présent (cp .env.example .env), données
# et modèle locaux (dvc pull, ou dvc repro). L'API KFP est jointe sur KFP_HOST (défaut
# http://localhost:8080, port-forward de l'UI) ; à défaut, un port-forward temporaire est
# ouvert le temps du script.
# Tout ce qui dépend du dataset (colonnes, cible, métrique, seuils) est lu dans dataset.yaml,
# params.yaml et tests/behavior.yaml. Les contrôles locaux tournent dans des dossiers
# temporaires (pipelines/stage.py) : le repo n'est pas modifié.
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
export MLFLOW_DISABLE_AGENT_HINT=1 PYTHONWARNINGS=ignore DO_NOT_TRACK=true

FAILS=0
TOTAL=0
K=(kubectl --context kind-mlops-lab)
KFP_HOST=${KFP_HOST:-http://localhost:8080}
MODEL_NAME=scoring-model
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
py() { t 300 uv run --no-sync python "$@"; }

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

# --- Great Expectations --------------------------------------------------------------
gx_suite_ok() {
  py - <<'EOF'
import json
from pathlib import Path

from src.dataset_config import load_config
from src.validate_data import CHECKPOINT, SUITE

cfg = load_config()
for f in ("great_expectations.yml", f"checkpoints/{CHECKPOINT}.json",
          f"expectations/{SUITE}.json", f"validation_definitions/{SUITE}.json"):
    assert (Path("gx") / f).exists(), f"gx/{f} absent"
suite = json.loads(Path(f"gx/expectations/{SUITE}.json").read_text())["expectations"]
covered = {}
for e in suite:
    for col in [e["kwargs"].get("column"), *e["kwargs"].get("column_set", [])]:
        covered[col] = covered.get(col, 0) + 1
missing = [c for c in cfg.columns if covered.get(c, 0) < 3]  # ensemble + non-nul + type
assert not missing, f"colonnes peu ou pas couvertes : {missing}"
types = {e["type"] for e in suite}
assert len(types) >= 5, f"seulement {len(types)} types d'expectations"
EOF
}
gx_git_ok() {
  git ls-files --error-unmatch gx/great_expectations.yml gx/expectations/scoring_contract.json \
    gx/checkpoints/scoring_gate.json gx/validation_definitions/scoring_contract.json || return 1
  ! git ls-files gx/uncommitted | grep -q .
}
gx_green_ok() {
  py - "$TMP" <<'EOF'
import json
import sys
from pathlib import Path

from pipelines.stage import run_stage
from src.dataset_config import load_config
from src.validate_data import REPORT_HTML, REPORT_JSON

tmp, cfg = Path(sys.argv[1]), load_config()
run_stage("src.validate_data", inputs={cfg.raw_path: cfg.raw_path},
          outputs={str(REPORT_JSON): tmp / "validation.json",
                   str(REPORT_HTML): tmp / "validation.html"})
summary = json.loads((tmp / "validation.json").read_text())
assert summary["success"] and summary["n_checks"] >= 2 * len(cfg.columns), summary
assert (tmp / "validation.html").stat().st_size > 0
EOF
}
gx_blocks_ok() {
  py - "$TMP" <<'EOF'
import subprocess
import sys
from pathlib import Path

import pandas as pd

from pipelines.stage import run_stage
from src.dataset_config import load_config
from src.simulate import corrupt

tmp, cfg = Path(sys.argv[1]), load_config()
corrupt(cfg, pd.read_csv(cfg.raw_path)).to_csv(tmp / "corrupted.csv", index=False)
try:
    run_stage("src.validate_data", inputs={cfg.raw_path: tmp / "corrupted.csv"})
except subprocess.CalledProcessError:
    sys.exit(0)  # le gate a refusé les données : c'est ce qu'on attend
sys.exit("données corrompues acceptées")
EOF
}

# --- Drift -------------------------------------------------------------------------------
drift_ok() {
  # Entraînement vs test : pas de drift, rapports JSON et HTML (Evidently) produits
  py - "$TMP" <<'EOF'
import json
import sys
from pathlib import Path

from pipelines.stage import run_stage
from src.detect_drift import CURRENT_CSV, REFERENCE_CSV, REPORT_HTML, REPORT_JSON

tmp = Path(sys.argv[1])
run_stage("src.detect_drift",
          inputs={str(REFERENCE_CSV): REFERENCE_CSV, str(CURRENT_CSV): CURRENT_CSV},
          outputs={str(REPORT_JSON): tmp / "drift.json", str(REPORT_HTML): tmp / "drift.html"})
summary = json.loads((tmp / "drift.json").read_text())
assert not summary["drift_detected"], summary["drifted"]
assert "Dataset Drift" in (tmp / "drift.html").read_text(encoding="utf-8")  # rapport Evidently
EOF
}
drift_detected_ok() {
  # Scénario de params.yaml (drift.simulation) : le gate doit le signaler (code retour 1)
  py - "$TMP" <<'EOF'
import json
import subprocess
import sys
from pathlib import Path

import pandas as pd
import yaml

from pipelines.stage import run_stage
from src.detect_drift import CURRENT_CSV, REFERENCE_CSV, REPORT_JSON
from src.simulate import drift

tmp = Path(sys.argv[1])
scenario = yaml.safe_load(Path("params.yaml").read_text())["drift"]["simulation"]
drift(pd.read_csv(CURRENT_CSV), scenario).to_csv(tmp / "drifted.csv", index=False)
try:
    run_stage("src.detect_drift", args=["reference.csv", "current.csv"],
              inputs={"reference.csv": REFERENCE_CSV, "current.csv": tmp / "drifted.csv"},
              outputs={str(REPORT_JSON): tmp / "drift-sim.json"})
except subprocess.CalledProcessError:
    assert json.loads((tmp / "drift-sim.json").read_text())["drifted"]
    sys.exit(0)
sys.exit("drift simulé non détecté")
EOF
}

# --- Modèle ----------------------------------------------------------------------------------
model_local_ok() {
  py - <<'EOF'
from src.train import MODEL_DIR, TEST_CSV, TRAIN_CSV

for path in (MODEL_DIR / "MLmodel", TRAIN_CSV, TEST_CSV):
    assert path.exists(), f"{path} absent"
EOF
}
behavior_yaml_ok() {
  py - <<'EOF'
from pathlib import Path

import yaml

from src.dataset_config import load_config

cfg = load_config()
expect = yaml.safe_load(Path("tests/behavior.yaml").read_text())
cases = (expect.get("invariance") or []) + (expect.get("directional") or [])
assert expect.get("invariance") and expect.get("directional"), "invariance et directional"
unknown = [c["column"] for c in cases if c["column"] not in cfg.features]
assert not unknown, f"colonnes absentes de dataset.yaml : {unknown}"
EOF
}
pytest_ok() {
  local out
  out=$(py -m pytest -q -p no:cacheprovider tests/test_model_behavior.py 2>&1) || return 1
  grep -qE "[0-9]+ passed" <<<"$out"
}
validate_model_ok() {
  py - "$TMP" <<'EOF'
import json
import sys
from pathlib import Path

from pipelines.stage import run_stage
from src.train import MODEL_DIR, TEST_CSV, TRAIN_CSV
from src.validate_model import REPORT_HTML, REPORT_JSON

tmp = Path(sys.argv[1])
run_stage("src.validate_model",
          inputs={str(p): p for p in (MODEL_DIR, TRAIN_CSV, TEST_CSV)},
          outputs={str(REPORT_JSON): tmp / "model.json", str(REPORT_HTML): tmp / "model.html"})
summary = json.loads((tmp / "model.json").read_text())
assert summary["success"] and summary["evidently"] and summary["behavior"], summary
assert (tmp / "model.html").stat().st_size > 0
EOF
}

# --- Image, composants, pipelines -------------------------------------------------------------
image_ok() {
  local img reg rest repo tag
  img=$(py -c "from pipelines.components import PIPELINE_IMAGE as i; print(i)") || return 1
  reg=${img%%/*}
  rest=${img#*/}
  repo=${rest%:*}
  tag=${rest##*:}
  [ "$tag" != "1.0.0" ] || return 1 # l'image du Lab 2 ne contient ni GX ni Evidently
  t 10 curl -fsS "http://${reg}/v2/${repo}/tags/list" | grep -q "\"${tag}\""
}
components_ok() {
  py - <<'EOF'
from pipelines import components as c

names = ["ingest_data", "validate_data", "prepare_features", "detect_drift", "train_model",
         "evaluate_model", "validate_model", "register_model"]
for name in names:
    image = getattr(c, name).component_spec.implementation.container.image
    assert image == c.PIPELINE_IMAGE, f"{name} : image {image}"
for gate in ("validate_data", "detect_drift", "validate_model"):
    outputs = getattr(c, gate).component_spec.outputs or {}
    kinds = {o.type for o in outputs.values()}
    assert any("HTML" in str(k) for k in kinds), f"{gate} : pas de sortie HTML"
EOF
}
pipeline_ok() {
  py - "$TMP" <<'EOF'
import sys

import yaml
from kfp import compiler

from pipelines.drift_demo import drift_pipeline
from pipelines.scoring_pipeline import scoring_pipeline
from pipelines.test_bad_data import bad_data_pipeline


def compile_spec(func, name):
    path = f"{sys.argv[1]}/{name}.yaml"
    compiler.Compiler().compile(func, package_path=path)
    return next(yaml.safe_load_all(open(path)))


def deps(spec, task):
    return set(spec["root"]["dag"]["tasks"][task].get("dependentTasks", []))


spec = compile_spec(scoring_pipeline, "main")
assert spec["pipelineInfo"]["name"] == "scoring-pipeline"
assert "validate-data" in deps(spec, "prepare-features"), "prepare sans gate de données"
assert "detect-drift" in deps(spec, "train-model"), "train sans gate de drift"
assert "validate-model" in deps(spec, "register-model"), "register sans gate de modèle"
executors = spec["deploymentSpec"]["executors"].values()
assert all("resourceMemoryLimit" in e["container"].get("resources", {}) for e in executors)
bad = compile_spec(bad_data_pipeline, "bad")
assert bad["pipelineInfo"]["name"] == "scoring-bad-data-test"
assert "validate-data" in deps(bad, "prepare-features")
drift = compile_spec(drift_pipeline, "drift")
assert drift["pipelineInfo"]["name"] == "scoring-drift-demo"
assert "detect-drift" in drift["root"]["dag"]["tasks"]
EOF
}
hardcode_ok() {
  # Ni identifiant S3 en dur, ni nom de colonne de dataset.yaml dans le code du lab
  ! grep -rEq "mlops-lab-secret|minio123|minioadmin|AWS_SECRET_ACCESS_KEY\"? *[:=] *\"[^\"$]" \
    pipelines dags src 2>/dev/null || return 1
  py - <<'EOF'
import re
from pathlib import Path

from src.dataset_config import load_config

cfg = load_config()
files = [*Path("pipelines").glob("*.py"), *Path("dags").glob("*.py"),
         *(Path("src") / f for f in ("validate_data.py", "detect_drift.py", "simulate.py",
                                     "validate_model.py")),
         Path("tests/test_model_behavior.py")]
code = "\n".join(f.read_text() for f in files if f.exists())
found = [c for c in cfg.columns if re.search(rf"[\"']{re.escape(c)}[\"']", code)]
assert not found, f"colonnes en dur : {found}"
EOF
}

# --- Runs KFP (une seule série de requêtes, résultat dans $TMP/kfp.json) ------------------------
kfp_api_ok() { t 10 curl -fsS "${KFP_HOST}/apis/v2beta1/healthz"; }
query_kfp() {
  py - "$KFP_HOST" "$TMP/kfp.json" <<'EOF'
import json
import sys

import kfp

host, out = sys.argv[1:3]
client = kfp.Client(host=host)
runs, token = [], ""
while True:
    resp = client.list_runs(page_token=token, page_size=100, sort_by="created_at desc")
    runs += resp.runs or []
    token = resp.next_page_token
    if not token or len(runs) >= 500:
        break

specs = {}


def spec_of(run):
    """Spécification du pipeline exécuté (embarquée dans le run, ou version uploadée)."""
    spec = run.pipeline_spec
    ref = run.pipeline_version_reference
    if not spec and ref and ref.pipeline_version_id:
        if ref.pipeline_version_id not in specs:
            version = client.get_pipeline_version(ref.pipeline_id, ref.pipeline_version_id)
            specs[ref.pipeline_version_id] = version.pipeline_spec or {}
        spec = specs[ref.pipeline_version_id]
    spec = spec or {}
    return spec.get("pipeline_spec", spec)  # spec + platform_spec (kfp-kubernetes)


def blocked_by_gate(run):
    """validate-data en échec et prepare-features jamais réussi (si le détail est connu)."""
    details = client.get_run(run.run_id).run_details
    tasks = {t.display_name: t.state for t in (details.task_details or [])} if details else {}
    if not tasks:
        return True
    return tasks.get("validate-data") == "FAILED" and tasks.get("prepare-features") != "SUCCEEDED"


result = {"gated": [], "bad_blocked": False, "drift": []}
for run in runs:
    spec = spec_of(run)
    name = spec.get("pipelineInfo", {}).get("name")
    tasks = set(spec.get("root", {}).get("dag", {}).get("tasks", {}))
    if name == "scoring-pipeline" and run.state == "SUCCEEDED":
        if {"validate-data", "detect-drift", "validate-model"} <= tasks:
            result["gated"].append(run.run_id)
    elif name == "scoring-bad-data-test" and run.state == "FAILED" and not result["bad_blocked"]:
        result["bad_blocked"] = blocked_by_gate(run)
    elif name == "scoring-drift-demo" and run.state == "SUCCEEDED":
        result["drift"].append(run.run_id)
json.dump(result, open(out, "w"))
EOF
}
kfp_gated_ok() { py -c "import json,sys; sys.exit(not json.load(open('$TMP/kfp.json'))['gated'])"; }
kfp_bad_ok() { py -c "import json,sys; sys.exit(not json.load(open('$TMP/kfp.json'))['bad_blocked'])"; }
kfp_drift_ok() { py -c "import json,sys; sys.exit(not json.load(open('$TMP/kfp.json'))['drift'])"; }

# --- MLflow --------------------------------------------------------------------------------------
mlflow_health() { [ "$(t 10 curl -fsS "${MLFLOW_TRACKING_URI}/health")" = "OK" ]; }
gated_version_ok() {
  [ -f "$TMP/kfp.json" ] || return 1
  py - "$TMP/kfp.json" <<EOF
import json
import sys

from mlflow import MlflowClient

gated = set(json.load(open(sys.argv[1]))["gated"])
client = MlflowClient()
versions = client.search_model_versions("name = '${MODEL_NAME}'")
assert any(client.get_run(v.run_id).data.tags.get("kfp_run_id") in gated for v in versions), \
    "aucune version enregistrée par un run à gates"
EOF
}

# --- Checklist -------------------------------------------------------------------------------------
echo "Lab 3 — vérification (KFP : ${KFP_HOST}, MLflow : ${MLFLOW_TRACKING_URI})"
echo
check "Suite GX générée depuis dataset.yaml (gx/ : suite, validation, checkpoint)" \
  "python -m src.validate_data --build-suite (étapes 1.2-1.3)" gx_suite_ok
check "Suite GX versionnée dans Git, gx/uncommitted/ ignoré" \
  "git add gx/ (étape 1.5)" gx_git_ok
check "Suite GX verte sur les données courantes (rapport HTML produit)" \
  "étape 1.3 ; dvc pull si data/raw est vide" gx_green_ok
check "Gate GX : les données corrompues (src/simulate.py) sont refusées" "étape 1.4" gx_blocks_ok
check "Drift : rien entre entraînement et test, rapport Evidently produit" \
  "étape 5.1 (section drift de params.yaml)" drift_ok
check "Drift : le scénario simulé de params.yaml est détecté" "étape 5.2" drift_detected_ok
check "Modèle et données locaux (models/model, data/processed)" "dvc pull ou dvc repro (Lab 1)" \
  model_local_ok
check "tests/behavior.yaml : invariance et directionnels sur des colonnes de dataset.yaml" \
  "étape 6.1" behavior_yaml_ok
check "pytest tests/test_model_behavior.py vert" "étape 6.1 (lire la sortie de pytest)" pytest_ok
check "src/validate_model.py vert (Evidently + comportemental), rapport HTML" "étape 6.2" \
  validate_model_ok
check "Image du pipeline (PIPELINE_IMAGE, nouveau tag) dans le registry local" \
  "docker build + docker push (étapes 2.3 et 6.4)" image_ok
check "8 composants sur l'image du projet, 3 gates avec rapport HTML" "étapes 2, 5.3 et 6.3" \
  components_ok
check "Pipelines compilés : gates avant prepare, train et register ; tests et démo de drift" \
  "étapes 4.2, 5.3 et 6.3" pipeline_ok
check "Aucun identifiant S3 ni nom de colonne en dur (pipelines/, dags/, src/, tests/)" \
  "lire dataset.yaml via load_config" hardcode_ok
if ! kfp_api_ok >/dev/null 2>&1; then # port-forward temporaire vers l'UI/API KFP
  "${K[@]}" -n kubeflow port-forward svc/ml-pipeline-ui 18080:80 >/dev/null 2>&1 &
  PF_PID=$!
  KFP_HOST="http://localhost:18080"
  sleep 4
fi
check "KFP : API joignable (${KFP_HOST})" "make kfp-ui (Lab 2, étape 1.3)" \
  kfp_api_ok
query_kfp >/dev/null 2>&1
check "KFP : run réussi de 'scoring-pipeline' avec les 3 gates" "étape 6.4" kfp_gated_ok
check "KFP : run de 'scoring-bad-data-test' en échec, bloqué par validate-data" "étape 4.2" \
  kfp_bad_ok
check "KFP : run réussi de 'scoring-drift-demo'" "étape 6.4" kfp_drift_ok
check "MLflow : ${MLFLOW_TRACKING_URI}/health = OK" "make pf" mlflow_health
check "Registry : une version de '${MODEL_NAME}' enregistrée par un run à gates" \
  "register_model après validate_model (étape 6.4)" gated_version_ok

echo
if [ "$FAILS" -eq 0 ]; then
  echo "🎉 ${TOTAL}/${TOTAL} vérifications OK — Lab 3 validé."
else
  echo "${FAILS} échec(s) sur ${TOTAL} vérifications."
fi
exit $((FAILS > 255 ? 255 : FAILS))
