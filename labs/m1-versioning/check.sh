#!/usr/bin/env bash
# shellcheck disable=SC2329  # fonctions de test appelées indirectement via check()
# =============================================================================
# Vérification automatique du Lab 1 — Versionner un projet ML end-to-end
# Lancer depuis la racine du repo :  make check-m1
# Pré-requis : port-forwards actifs (make pf) et .env présent (cp .env.example .env).
# Tout ce qui dépend du dataset (cible, métrique, seuil…) est lu dans dataset.yaml.
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
export MLFLOW_DISABLE_AGENT_HINT=1 DVC_NO_ANALYTICS=1 PYTHONWARNINGS=ignore

FAILS=0
TOTAL=0
EXPERIMENT=scoring
MODEL_NAME=scoring-model

# Exécute une commande avec un délai maximal (timeout absent sur macOS sans coreutils).
t() {
  local secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else "$@"; fi
}

# Lance la venv du repo sans la resynchroniser.
py() { t 90 uv run --no-sync python "$@"; }
dvc_() { t 60 uv run --no-sync dvc "$@"; }

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

# --- Contrat de données -------------------------------------------------------
contract_ok() {
  py - <<'EOF'
from src.dataset_config import load_config

cfg = load_config()
assert cfg.features and cfg.target and cfg.primary_metric
EOF
}
raw_ok() {
  py - <<'EOF'
import pandas as pd

from src.dataset_config import load_config

cfg = load_config()
df = pd.read_csv(cfg.raw_path)
cfg.validate_columns(df)
assert len(df) > 0
EOF
}

# --- DVC ----------------------------------------------------------------------
remote_ok() {
  [ "$(dvc_ config core.remote)" = "storage" ] &&
    [ "$(dvc_ config remote.storage.url)" = "s3://dvc-store/scoring" ] &&
    [ -n "$(dvc_ config remote.storage.endpointurl)" ]
}
creds_ok() {
  # Identifiants dans .dvc/config.local (non commité), jamais dans .dvc/config
  ! grep -qE "secret_access_key|access_key_id" .dvc/config &&
    grep -q "secret_access_key" .dvc/config.local
}
pipeline_ok() {
  local stages s
  for f in params.yaml dvc.yaml dvc.lock; do [ -f "$f" ] || return 1; done
  stages=$(dvc_ stage list --name-only) || return 1
  for s in download prepare train evaluate; do grep -qx "$s" <<<"$stages" || return 1; done
}
git_ok() {
  for f in dvc.yaml dvc.lock params.yaml .dvc/config src/prepare.py src/train.py \
    src/grid_search.py src/promote.py; do
    git ls-files --error-unmatch "$f" || return 1
  done
  # Les données et le modèle local sont gérés par DVC, pas par Git
  ! git ls-files data/ models/ | grep -vqE '(^|/)\.gitignore$'
}
status_ok() { dvc_ status | grep -q "Data and pipelines are up to date"; }
pushed_ok() { dvc_ status --cloud | grep -q "in sync"; }
metrics_ok() {
  py - <<'EOF'
import json

from src.dataset_config import load_config

cfg = load_config()
metrics = json.load(open("reports/metrics.json"))
assert cfg.primary_metric in metrics, f"{cfg.primary_metric} absent de reports/metrics.json"
EOF
}

# --- MLflow -------------------------------------------------------------------
mlflow_health() { [ "$(t 10 curl -fsS "${MLFLOW_TRACKING_URI}/health")" = "OK" ]; }
runs_ok() {
  py - <<EOF
from mlflow import MlflowClient

from src.dataset_config import load_config

cfg = load_config()
client = MlflowClient()
exp = client.get_experiment_by_name("${EXPERIMENT}")
runs = client.search_runs([exp.experiment_id], "attributes.status = 'FINISHED'", max_results=500)
runs = [r for r in runs if cfg.primary_metric in r.data.metrics
        and "decision_threshold" in r.data.params]
assert len(runs) >= 20, f"{len(runs)} runs seulement"
EOF
}
models_ok() {
  py - <<EOF
from mlflow import MlflowClient

client = MlflowClient()
exp = client.get_experiment_by_name("${EXPERIMENT}")
runs = client.search_runs([exp.experiment_id], max_results=500)
types = {r.data.params.get("model") for r in runs} - {None, "dummy"}
assert len(types) >= 3, f"types de modèles : {types}"
EOF
}
lineage_ok() {
  py - <<EOF
import yaml
from mlflow import MlflowClient

from src.dataset_config import load_config

cfg = load_config()
lock = yaml.safe_load(open("dvc.lock"))
md5 = next(o["md5"] for s in lock["stages"].values() for o in s.get("outs", [])
           if o["path"] == cfg.raw_path)
client = MlflowClient()
exp = client.get_experiment_by_name("${EXPERIMENT}")
runs = client.search_runs([exp.experiment_id], "tags.launched_by = 'dvc'", max_results=50)
assert any(r.data.tags.get("data_md5") == md5 for r in runs), "aucun run DVC sur ces données"
EOF
}
versions_ok() {
  py - <<EOF
from mlflow import MlflowClient

versions = MlflowClient().search_model_versions("name = '${MODEL_NAME}'")
assert len(versions) >= 3, f"{len(versions)} version(s)"
EOF
}
champion_ok() {
  py - <<EOF
from mlflow import MlflowClient

from src.dataset_config import load_config

cfg = load_config()
client = MlflowClient()
mv = client.get_model_version_by_alias("${MODEL_NAME}", "champion")
score = client.get_run(mv.run_id).data.metrics[cfg.primary_metric]
assert score >= cfg.promotion_threshold, f"{score} < {cfg.promotion_threshold}"
EOF
}
challenger_ok() {
  py -c "from mlflow import MlflowClient; \
MlflowClient().get_model_version_by_alias('${MODEL_NAME}', 'challenger')"
}
predict_ok() {
  py - <<EOF
import mlflow

from src.dataset_config import load_config
from src.train import TEST_CSV

X_test, _ = load_config().read_xy(TEST_CSV)
preds = mlflow.pyfunc.load_model("models:/${MODEL_NAME}@champion").predict(X_test.head(5))
assert len(preds) == 5
EOF
}

# --- Feast --------------------------------------------------------------------
feast_ok() {
  # Tester le fichier d'abord : FeatureStore() créerait un registre vide
  [ -f features/data/registry.db ] && [ -f features/data/online_store.db ] || return 1
  py - <<'EOF'
import pandas as pd
import yaml
from feast import FeatureStore

id_col = yaml.safe_load(open("params.yaml"))["prepare"]["id_column"]
store = FeatureStore(repo_path="features")
assert "request_features" in {fv.name for fv in store.list_feature_views()}
service = store.get_feature_service("scoring_v1")
first = int(pd.read_csv("data/processed/train.csv")[id_col].iloc[0])
row = store.get_online_features(features=service, entity_rows=[{id_col: first}]).to_dict()
values = [v[0] for k, v in row.items() if k != id_col]
assert values and all(v is not None for v in values), "store en ligne vide : feast materialize"
EOF
}

# --- Checklist ------------------------------------------------------------------
echo "Lab 1 — vérification du projet (MLflow : ${MLFLOW_TRACKING_URI})"
echo
check "dataset.yaml valide (src.dataset_config)" "relire dataset.yaml (étape 1)" contract_ok
check "Données brutes conformes au contrat" "python -m src.download ou dvc pull (étapes 1-2)" raw_ok
check "Remote DVC 'storage' -> s3://dvc-store/scoring (défaut)" "dvc remote add (étape 2.3)" \
  remote_ok
check "Identifiants S3 dans .dvc/config.local uniquement" "dvc remote modify --local (étape 2.3)" \
  creds_ok
check "dvc.yaml (download, prepare, train, evaluate) + params.yaml + dvc.lock" \
  "étapes 4.1 et 8" pipeline_ok
check "Code et pointeurs commités, données hors Git" "git add/commit (étapes 8.4 et 10.1)" git_ok
check "dvc status : pipeline à jour" "dvc repro puis git commit dvc.lock (étape 8)" status_ok
check "Remote S3 joignable, données poussées (dvc status --cloud)" "make pf ; dvc push" pushed_ok
check "reports/metrics.json contient la métrique primaire" "dvc repro (étape 8)" metrics_ok
check "MLflow : ${MLFLOW_TRACKING_URI}/health = OK" "make pf (étape 3)" mlflow_health
check "MLflow : ≥ 20 runs terminés dans '${EXPERIMENT}' (métrique + seuil)" \
  "python -m src.grid_search (étape 5)" runs_ok
check "MLflow : ≥ 3 types de modèles comparés" "python -m src.grid_search (étape 5)" models_ok
check "MLflow : un run DVC tracé avec le data_md5 de dvc.lock" "dvc repro (étape 8.3)" lineage_ok
check "Registry : '${MODEL_NAME}' a ≥ 3 versions" "python -m src.promote (étapes 7 et 8)" \
  versions_ok
check "Registry : @champion avec métrique ≥ seuil de dataset.yaml" "python -m src.promote (étape 7)" \
  champion_ok
check "Registry : alias @challenger présent" "python -m src.promote (étape 7)" challenger_ok
check "Modèle @champion chargé et prédit sur le jeu de test" "étape 7.4" predict_ok
check "Feast : vue request_features appliquée et matérialisée" \
  "cd features && feast apply && feast materialize-incremental … (étape 9)" feast_ok

echo
if [ "$FAILS" -eq 0 ]; then
  echo "🎉 ${TOTAL}/${TOTAL} vérifications OK — Lab 1 validé."
else
  echo "${FAILS} échec(s) sur ${TOTAL} vérifications."
fi
exit $((FAILS > 255 ? 255 : FAILS))
