#!/usr/bin/env bash
# shellcheck disable=SC2329  # fonctions de test appelées indirectement via check()
# =============================================================================
# Vérification automatique du Lab 0 — Setup de l'environnement
# Lancer depuis la racine du repo :  make check-m0
# Pré-requis : port-forwards actifs (make pf) et .env présent (cp .env.example .env).
# Code retour = nombre de vérifications en échec (0 = tout est vert).
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

# Constantes du cours + endpoints/identifiants du lab (.env, à défaut .env.example)
# shellcheck disable=SC1091
source infra/versions.env
ENV_FILE=.env
[ -f "$ENV_FILE" ] || ENV_FILE=.env.example
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

CTX="kind-${KIND_CLUSTER_NAME}"
FAILS=0
TOTAL=0

# Exécute une commande avec un délai maximal (timeout absent sur macOS sans coreutils).
t() {
  local secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else "$@"; fi
}

kc() { t 15 kubectl --context "$CTX" --request-timeout=10s "$@"; }

# Lance la venv du repo sans la resynchroniser.
py() { t 30 uv run --no-sync python "$@"; }

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

# --- Fonctions de test --------------------------------------------------------
docker_hello() { t 60 docker run --rm hello-world | grep -q "Hello from Docker"; }
compose_ok() { t 10 docker compose version | grep -qE "version v?[2-9]\."; }
kubectl_ok() { t 10 kubectl version --client | grep -qE "Client Version: v1\.[0-9]+"; }
helm_ok() { t 10 helm version --short | grep -qE "^v[34]\."; }
k9s_ok() { t 10 k9s version -s; }
kind_ok() { t 10 kind get clusters | grep -qx "${KIND_CLUSTER_NAME}"; }
nodes_ready() {
  [ "$(kc get nodes --no-headers | awk '$2 == "Ready"' | wc -l | tr -d ' ')" -eq 3 ]
}
context_ok() { [ "$(kubectl config current-context)" = "$CTX" ]; }
registry_ok() {
  t 10 curl -fsS "http://localhost:${REGISTRY_PORT}/v2/" &&
    kc -n kube-public get configmap local-registry-hosting
}
seaweedfs_ok() {
  kc -n storage wait --for=condition=Available deploy/seaweedfs --timeout=10s
}
mlflow_pod_ok() {
  kc -n mlflow wait --for=condition=Available deploy/mlflow --timeout=10s
}
buckets_ok() {
  py - <<'EOF'
import os

import boto3

s3 = boto3.client("s3", endpoint_url=os.environ["AWS_ENDPOINT_URL"])
names = {b["Name"] for b in s3.list_buckets()["Buckets"]}
missing = {"mlflow-artifacts", "dvc-store", "mlops-test"} - names
assert not missing, f"buckets manquants : {missing}"
EOF
}
dvc_object_ok() {
  py - <<'EOF'
import os

import boto3

s3 = boto3.client("s3", endpoint_url=os.environ["AWS_ENDPOINT_URL"])
resp = s3.list_objects_v2(Bucket="mlops-test", Prefix="dvcstore/files/md5/")
assert resp.get("KeyCount", 0) > 0, "aucun objet DVC sous mlops-test/dvcstore/"
EOF
}
mlflow_health() {
  [ "$(t 10 curl -fsS "${MLFLOW_TRACKING_URI}/health")" = "OK" ]
}
mlflow_run_ok() {
  py - <<'EOF'
from mlflow.tracking import MlflowClient

client = MlflowClient()  # MLFLOW_TRACKING_URI lu dans l'environnement
exp = client.get_experiment_by_name("smoke-test")
assert exp is not None, "expérience smoke-test absente"
runs = client.search_runs(
    [exp.experiment_id], "attributes.run_name = 'hello-mlops'", max_results=1
)
assert runs, "run hello-mlops absent"
run = runs[0]
assert abs(run.data.metrics["accuracy"] - 0.42) < 1e-9
# L'artefact est relu à travers le proxy MLflow -> S3 (bucket mlflow-artifacts)
names = [a.path for a in client.list_artifacts(run.info.run_id)]
assert "hello.txt" in names, f"artefact hello.txt absent : {names}"
EOF
}
uv_python_ok() {
  t 10 uv --version &&
    py -c "import sys; assert sys.version_info[:2] == (3, 12), sys.version"
}
dvc_ok() { t 30 uv run --no-sync dvc --version | grep -qE "^3\."; }
remote_ok() {
  git remote get-url origin | grep -qE "github\.com[:/].+/mlops-cours-2026(\.git)?$"
}
pushed_ok() {
  git ls-files --error-unmatch labs/m0-setup/smoke_mlflow.py &&
    [ -n "$(git branch -r --contains HEAD 2>/dev/null)" ]
}

# --- Checklist ------------------------------------------------------------------
echo "Lab 0 — vérification de l'environnement (contexte ${CTX})"
echo
check "Docker : hello-world" "démarrer Docker / groupe docker (étape 1)" docker_hello
check "Docker Compose (plugin v2+)" "installer le plugin compose (étape 1)" compose_ok
check "kubectl installé" "étape 2.1" kubectl_ok
check "helm installé (v3/v4)" "étape 2.2" helm_ok
check "k9s installé" "étape 2.3" k9s_ok
check "kind : cluster ${KIND_CLUSTER_NAME} présent" "make cluster (étape 4)" kind_ok
check "Cluster : 3 nœuds Ready" "kubectl get nodes ; make cluster" nodes_ready
check "Contexte kubectl courant = ${CTX}" "kubectl config use-context ${CTX}" context_ok
check "Registry localhost:${REGISTRY_PORT} répond" "make cluster (étape 4.2)" registry_ok
check "SeaweedFS : pod Running/Ready" "make storage ; kubectl -n storage get pods" seaweedfs_ok
check "MLflow : pod Running/Ready" "make mlflow ; kubectl -n mlflow logs deploy/mlflow" \
  mlflow_pod_ok
check "S3 : buckets mlflow-artifacts, dvc-store, mlops-test" \
  "make pf ; créer mlops-test (étape 5.7)" buckets_ok
check "MLflow : ${MLFLOW_TRACKING_URI}/health = OK" "make pf (étape 5.5)" mlflow_health
check "MLflow : run hello-mlops (+ artefact hello.txt)" \
  "python labs/m0-setup/smoke_mlflow.py (étape 7.1)" mlflow_run_ok
check "uv + Python 3.12 (venv du repo)" "uv python install 3.12 ; uv sync (étape 6)" uv_python_ok
check "DVC 3.x installé" "uv sync (étape 6)" dvc_ok
check "DVC : objet poussé dans mlops-test/dvcstore/" "dvc push dans /tmp/dvc-smoke (étape 7.2)" \
  dvc_object_ok
check "Git : remote origin = VOTRE_USER/mlops-cours-2026" "étape 3.3" remote_ok
check "Git : smoke_mlflow.py commité et poussé" "git add/commit/push (étape 8.1)" pushed_ok

echo
if [ "$FAILS" -eq 0 ]; then
  echo "🎉 ${TOTAL}/${TOTAL} vérifications OK — Lab 0 validé."
else
  echo "${FAILS} échec(s) sur ${TOTAL} vérifications."
fi
exit $((FAILS > 255 ? 255 : FAILS))
