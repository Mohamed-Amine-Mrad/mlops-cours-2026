#!/usr/bin/env bash
# shellcheck disable=SC2329  # fonctions de test appelées indirectement via check()
# =============================================================================
# Vérification automatique du Lab 5 — Serving avec KServe
# Lancer depuis la racine du repo :  make check-m5
# Pré-requis : cluster du Lab 0 actif, make kserve (étape 1), port-forwards (make pf) pour
# interroger MLflow, InferenceService scoring-model déployé (étapes 3 à 7).
# Variables optionnelles : NS (défaut scoring), ISVC (défaut scoring-model),
#   GATEWAY (défaut http://localhost:30080, passerelle Kourier), CHECK_PORT (port local du
#   port-forward utilisé si l'InferenceService est en mode Standard, défaut 18580),
#   REGISTRY (défaut localhost:5001).
# Code retour = nombre de vérifications en échec (0 = tout est vert).
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

# shellcheck disable=SC1091
source infra/versions.env
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi
NS=${NS:-scoring}
ISVC=${ISVC:-scoring-model}
GATEWAY=${GATEWAY:-http://localhost:30080}
CHECK_PORT=${CHECK_PORT:-18580}
REGISTRY=${REGISTRY:-localhost:${REGISTRY_PORT}}
export MLFLOW_TRACKING_URI=${MLFLOW_TRACKING_URI:-http://localhost:5000}
SEL="serving.kserve.io/inferenceservice=${ISVC}"
FAILS=0
TOTAL=0
PF_PID=""

t() {
  local secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else "$@"; fi
}
k() { t 30 kubectl "$@"; }
py() { t 120 uv run --no-sync python "$@"; }

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

cleanup() { [ -n "$PF_PID" ] && kill "$PF_PID" >/dev/null 2>&1; }
trap cleanup EXIT

# --- Point d'appel du service ---------------------------------------------------
# Mode Knative (celui du lab) : passerelle Kourier sur le port 30080 + en-tête Host tiré de
# status.url. Mode Standard (si vous l'avez choisi) : port-forward vers le Service du prédicteur.
BASE_URL=$GATEWAY
HOST_HEADER=""
MODE=$(k get isvc "$ISVC" -n "$NS" \
  -o jsonpath='{.metadata.annotations.serving\.kserve\.io/deploymentMode}' 2>/dev/null)
URL=$(k get isvc "$ISVC" -n "$NS" -o jsonpath='{.status.url}' 2>/dev/null)
if [ "$MODE" = "Standard" ] || [ "$MODE" = "RawDeployment" ]; then
  kubectl -n "$NS" port-forward "svc/${ISVC}-predictor" "${CHECK_PORT}:80" >/dev/null 2>&1 &
  PF_PID=$!
  sleep 3
  BASE_URL="http://localhost:${CHECK_PORT}"
else
  HOST_HEADER=$(echo "$URL" | sed -E 's#^[a-z]+://##; s#/.*$##')
fi
export BASE_URL HOST_HEADER

# --- Fonctions de test --------------------------------------------------------
cluster_ok() { k get namespace "$NS"; }
knative_ok() {
  k -n knative-serving wait --for=condition=Available deploy --all --timeout=20s &&
    k -n kourier-system wait --for=condition=Available deploy --all --timeout=20s &&
    [ "$(k -n kourier-system get svc kourier \
      -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')" = "30080" ]
}
kserve_ok() {
  k -n cert-manager wait --for=condition=Available deploy --all --timeout=20s &&
    k -n kserve wait --for=condition=Available deploy/kserve-controller-manager --timeout=20s
}
metrics_ok() { k top nodes; }
isvc_ready() { k wait --for=condition=Ready "isvc/${ISVC}" -n "$NS" --timeout=25s; }
# Le premier appel peut réveiller un service à zéro pod (scale-to-zero) : délai généreux.
health_ok() {
  local args=(-fsS --max-time 60)
  [ -n "$HOST_HEADER" ] && args+=(-H "Host: ${HOST_HEADER}")
  curl "${args[@]}" "${BASE_URL}/health" | grep -q '"ok"'
}
# /predict sur une vraie ligne de data/processed/test.csv (colonnes lues dans dataset.yaml) ;
# la décision doit être cohérente avec le seuil renvoyé.
predict_ok() {
  py - <<'EOF'
import json
import os
import urllib.request

import pandas as pd

from src.dataset_config import load_config

cfg = load_config()
row = pd.read_csv("data/processed/test.csv")[cfg.features].head(1)
row = row.astype(object).where(row.notna(), None).to_dict("records")[0]
headers = {"Content-Type": "application/json"}
if os.environ["HOST_HEADER"]:
    headers["Host"] = os.environ["HOST_HEADER"]
body = json.dumps({"instances": [row]}).encode()
req = urllib.request.Request(f"{os.environ['BASE_URL']}/predict", body, headers)
with urllib.request.urlopen(req, timeout=60) as r:
    out = json.load(r)
pred = out["predictions"][0]
assert 0.0 <= pred["probability"] <= 1.0, out
assert pred["prediction"] == int(pred["probability"] >= out["threshold"]), out
assert out["positive_class"] == str(cfg.positive_class), out
print(f"probability={pred['probability']:.3f} threshold={out['threshold']}")
EOF
}
# Le seuil servi doit être le param MLflow decision_threshold du champion (Lab 1).
threshold_ok() {
  py - <<'EOF'
import json
import os
import urllib.request

from mlflow import MlflowClient

headers = {"Host": os.environ["HOST_HEADER"]} if os.environ["HOST_HEADER"] else {}
req = urllib.request.Request(f"{os.environ['BASE_URL']}/metadata", headers=headers)
with urllib.request.urlopen(req, timeout=60) as r:
    served = float(json.load(r)["threshold"])
client = MlflowClient()
mv = client.get_model_version_by_alias("scoring-model", "champion")
expected = float(client.get_run(mv.run_id).data.params["decision_threshold"])
print(f"served={served} champion v{mv.version}={expected}")
assert abs(served - expected) < 1e-4
EOF
}
# Autoscaling : au moins 2 pods possibles ET un autoscaler (KPA Knative, HPA ou KEDA).
autoscaling_ok() {
  local maxr
  maxr=$(k get isvc "$ISVC" -n "$NS" -o jsonpath='{.spec.predictor.maxReplicas}')
  [ "${maxr:-0}" -ge 2 ] || return 1
  [ -n "$(k get kpa -n "$NS" -l "$SEL" -o name 2>/dev/null)" ] ||
    k get hpa "${ISVC}-predictor" -n "$NS" ||
    [ -n "$(k get scaledobjects -n "$NS" -o name 2>/dev/null)" ]
}
canary_image_ok() {
  t 10 curl -fsS "http://${REGISTRY}/v2/scoring-api/tags/list" | grep -q '"2\.0\.0"' &&
    k get revisions -n "$NS" -l "$SEL" -o jsonpath='{..image}' | grep -q 'scoring-api:2\.0\.0'
}
# /version n'existe que dans la v2 : avec un canary à 10 %, on essaie jusqu'à 50 fois.
version_ok() {
  local args=(-fsS --max-time 5)
  [ -n "$HOST_HEADER" ] && args+=(-H "Host: ${HOST_HEADER}")
  health_ok || return 1 # service joignable (et réveillé) avant la rafale de requêtes
  for _ in $(seq 1 50); do
    curl "${args[@]}" "${BASE_URL}/version" 2>/dev/null | grep -q '"version":"2\.' && return 0
  done
  return 1
}
locust_ok() {
  local n
  for n in 100 500 1000; do
    awk -F, '$1 == "POST" && $3 > 0 {found = 1} END {exit !found}' \
      "reports/m5/run_${n}_stats.csv" || return 1
  done
}
# Rapport : au moins 5 sections ET le tableau des 3 runs rempli avec des nombres.
report_ok() {
  [ -s reports/rapport-m5.md ] && [ "$(grep -c '^## ' reports/rapport-m5.md)" -ge 5 ] &&
    [ "$(grep -cE '^\| *run_(100|500|1000) *\|( *[0-9][0-9.,]* *\|){6}' \
      reports/rapport-m5.md)" -ge 3 ]
}
files_ok() {
  local f
  for f in scoring-isvc-v1.yaml scoring-isvc-v1-autoscale.yaml scoring-isvc-canary.yaml \
    locustfile.py monitor.sh; do
    [ -s "serving/$f" ] || return 1
  done
}

# --- Vérifications --------------------------------------------------------------
echo "Lab 5 — Serving avec KServe (${NS}/${ISVC}, appel : ${BASE_URL}${HOST_HEADER:+ + Host: ${HOST_HEADER}})"
check "Cluster joignable, namespace ${NS} présent" \
  "make up (Lab 0) puis kubectl create namespace ${NS} (étape 2)" cluster_ok
check "Knative Serving + Kourier prêts, passerelle sur le NodePort 30080" \
  "make kserve (étape 1) ; kubectl get pods -n knative-serving -n kourier-system" knative_ok
check "cert-manager + contrôleur KServe prêts" \
  "make kserve (étape 1) ; kubectl get pods -n cert-manager -n kserve" kserve_ok
check "metrics-server répond (kubectl top nodes)" \
  "make kserve installe metrics-server ; attendre 1 min (étape 5)" metrics_ok
check "InferenceService ${ISVC} Ready" \
  "kubectl describe isvc ${ISVC} -n ${NS} ; logs : kubectl logs -n ${NS} -l ${SEL}" isvc_ready
check "/health répond via la passerelle" \
  "curl -H 'Host: <status.url sans http://>' ${GATEWAY}/health (étape 4)" health_ok
check "/predict : ligne réelle de test.csv (colonnes de dataset.yaml), décision cohérente" \
  "étape 4.2 ; vérifier l'image et data/processed/test.csv" predict_ok
check "Seuil servi = decision_threshold du champion (MLflow)" \
  "make pf ; l'image sert-elle le champion ? (Lab 4 : export_onnx.py puis rebuild)" threshold_ok
check "Autoscaling configuré (maxReplicas ≥ 2 + KPA, HPA ou KEDA)" \
  "kubectl apply -f serving/scoring-isvc-v1-autoscale.yaml (étape 5)" autoscaling_ok
check "Canary : image 2.0.0 dans le registry et déployée dans une révision" \
  "docker push ${REGISTRY}/scoring-api:2.0.0 puis serving/scoring-isvc-canary.yaml (étape 7)" \
  canary_image_ok
check "/version répond 2.x (v2 en canary ou promue)" \
  "serve.py modifié (étape 7.1) et image 2.0.0 reconstruite" version_ok
check "Tests de charge Locust : run_100, run_500, run_1000 (reports/m5/)" \
  "locust … --csv=reports/m5/run_<users> (étape 6)" locust_ok
check "Rapport reports/rapport-m5.md : 5 sections + tableau de charge rempli" \
  "starter/rapport-m5.md + sortie de serving/locust_report.py (étape 9)" report_ok
check "Manifests et scripts dans serving/" "étapes 3 à 7" files_ok

echo
echo "Résultat : $((TOTAL - FAILS))/${TOTAL} vérifications OK"
exit "$FAILS"
