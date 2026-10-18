#!/usr/bin/env bash
# shellcheck disable=SC2329  # fonctions de test appelées indirectement via check()
# =============================================================================
# Vérification automatique du Lab 7 — Monitoring & observabilité ML
# Lancer depuis la racine du repo :  make check-m7
# Pré-requis : cluster du Lab 0 actif, make monitoring (étape 3), API instrumentée déployée
# (étape 2) et du trafic récent (monitoring/traffic.py). Aucun port-forward nécessaire :
# Prometheus, Alertmanager et Loki sont interrogés via le proxy de l'API Kubernetes.
# Variables optionnelles : NS (défaut scoring), ISVC (défaut scoring-model),
#   MON_NS (défaut monitoring), REGISTRY (défaut localhost:5001).
# Code retour = nombre de vérifications en échec (0 = tout est vert).
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

# shellcheck disable=SC1091
source infra/versions.env
NS=${NS:-scoring}
ISVC=${ISVC:-scoring-model}
MON_NS=${MON_NS:-monitoring}
REGISTRY=${REGISTRY:-localhost:${REGISTRY_PORT}}
CTX="kind-${KIND_CLUSTER_NAME}"
SVC="/api/v1/namespaces/${MON_NS}/services"
PROM="${SVC}/http:kube-prom-stack-kube-prome-prometheus:9090/proxy"
ALERTMANAGER="${SVC}/http:kube-prom-stack-kube-prome-alertmanager:9093/proxy"
LOKI="${SVC}/http:loki:3100/proxy"
FAILS=0
TOTAL=0

t() {
  local secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else "$@"; fi
}
k() { t 30 kubectl --context "$CTX" "$@"; }
if [ -x .venv/bin/python ]; then
  py() { t 180 .venv/bin/python "$@"; }
else
  py() { t 180 uv run --no-sync --quiet python "$@"; }
fi
export NS ISVC

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

urlenc() { py -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
# Nombre de séries renvoyées par une requête PromQL instantanée
prom_n() {
  k get --raw "${PROM}/api/v1/query?query=$(urlenc "$1")" |
    py -c 'import json, sys; print(len(json.load(sys.stdin)["data"]["result"]))'
}
prom_has() { [ "$(prom_n "$1")" -ge "${2:-1}" ]; }

# --- Fonctions de test --------------------------------------------------------
files_ok() {
  local f
  for f in values-monitoring.yaml scoring-podmonitor.yaml scoring-alerts.yaml \
    alertmanager-config.yaml evidently-cronjob.yaml traffic.py canary_analysis.py \
    evidently-job/calc_drift.py evidently-job/Dockerfile dashboards/kustomization.yaml; do
    [ -s "monitoring/$f" ] || return 1
  done
  ls monitoring/dashboards/scoring-*.json >/dev/null &&
    grep -q '^prometheus-client' packaging/requirements.txt
}
tests_ok() { LOG_PREDICTIONS=false py -m pytest -q -p no:cacheprovider tests/test_monitoring.py; }
pods_ready() { # pods_ready <sélecteur> : au moins un pod, tous les conteneurs prêts
  local s
  s=$(k get pods -n "$MON_NS" -l "$1" \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[*].ready}{" "}{end}')
  [ -n "$s" ] && ! grep -q false <<<"$s"
}
stack_ok() {
  local sel
  for sel in app.kubernetes.io/name=prometheus app.kubernetes.io/name=alertmanager \
    app.kubernetes.io/name=grafana app=kube-prometheus-stack-operator \
    app.kubernetes.io/name=kube-state-metrics app.kubernetes.io/name=prometheus-pushgateway \
    app.kubernetes.io/name=loki app.kubernetes.io/name=alloy; do
    pods_ready "$sel" || return 1
  done
}
podmonitor_ok() { k get podmonitor scoring-api -n "$MON_NS"; }
target_up() { prom_has "up{namespace=\"${NS}\",isvc=\"${ISVC}\"} == 1"; }
# Métriques métier + une série par attribut sensible de dataset.yaml reçu par l'API
business_ok() {
  local sel="namespace=\"${NS}\",isvc=\"${ISVC}\"" attr
  prom_has "ml_predictions_total{${sel}}" &&
    prom_has "ml_prediction_score_count{${sel}}" &&
    prom_has "ml_inference_latency_seconds_count{${sel}}" &&
    prom_has "http_requests_total{${sel},handler=\"/predict\"}" &&
    prom_has "ml_model_info{${sel}}" || return 1
  for attr in $(py -c 'from src.dataset_config import load_config
cfg = load_config()
print(" ".join(s.column for s in cfg.sensitive if s.column in cfg.features))'); do
    prom_has "ml_predictions_by_group_total{${sel},attribute=\"${attr}\"}" || return 1
  done
}
dashboards_ok() {
  local cm
  cm=$(k get configmap -n "$MON_NS" -l grafana_dashboard=1 -o name | grep scoring) || return 1
  [ -n "$cm" ] &&
    k exec -n "$MON_NS" deploy/kube-prom-stack-grafana -c grafana -- \
      test -f /tmp/dashboards/scoring-overview.json
}
rules_ok() {
  k get --raw "${PROM}/api/v1/rules?type=alert" | py -c '
import json, sys
groups = json.load(sys.stdin)["data"]["groups"]
rules = [r for g in groups if g["name"] == "scoring.alerts" for r in g["rules"]]
print(len(rules), [r["health"] for r in rules])
assert len(rules) >= 4 and all(r["health"] == "ok" for r in rules)'
}
alertmanager_ok() {
  k get secret slack-webhook -n "$MON_NS" -o jsonpath='{.data.url}' | grep -q . &&
    k get alertmanagerconfig scoring-slack -n "$MON_NS" &&
    k get --raw "${ALERTMANAGER}/api/v2/status" | grep -q 'scoring-slack'
}
drift_image_ok() {
  t 10 curl -fsS "http://${REGISTRY}/v2/scoring-drift/tags/list" | grep -q '"tags"'
}
# lastSuccessfulTime du CronJob, ou à défaut un Job réussi qui lui appartient
# (kubectl create job --from=cronjob/… pose l'ownerReference)
cronjob_ok() {
  [ -n "$(k get cronjob scoring-drift -n "$MON_NS" -o jsonpath='{.status.lastSuccessfulTime}')" ] ||
    k get jobs -n "$MON_NS" -o json | py -c '
import json, sys
jobs = json.load(sys.stdin)["items"]
assert any(
    any(o.get("name") == "scoring-drift" for o in j["metadata"].get("ownerReferences", []))
    and j.get("status", {}).get("succeeded", 0) >= 1
    for j in jobs
)'
}
drift_metric_ok() {
  local n
  n=$(py -c 'from src.dataset_config import load_config; print(len(load_config().features))')
  [ "$(prom_n 'ml_drift_score{model="scoring-model"}')" -eq "$n" ]
}
loki_ok() {
  # shellcheck disable=SC2016  # les accents graves sont la syntaxe LogQL, pas du shell
  local q='{namespace="'"${NS}"'", container="kserve-container"} |= `"event":"prediction"`'
  k get --raw "${LOKI}/loki/api/v1/query_range?limit=1&since=24h&query=$(urlenc "$q")" |
    py -c 'import json, sys; assert json.load(sys.stdin)["data"]["result"]'
}
canary_report_ok() {
  [ -s reports/m7/canary-analysis.md ] &&
    py -c 'import json
r = json.load(open("reports/m7/canary-analysis.json"))
assert r["decision"] in {"PROMOTE", "CONTINUE", "ROLLBACK", "WAIT"}
assert r["stable"] != r["canary"] and len(r["checks"]) >= 4'
}
report_ok() {
  [ -s reports/rapport-m7.md ] && [ "$(grep -c '^## ' reports/rapport-m7.md)" -ge 5 ] &&
    ! grep -q 'TODO' reports/rapport-m7.md
}

# --- Vérifications --------------------------------------------------------------
echo "Lab 7 — Monitoring & observabilité ML (${NS}/${ISVC}, stack dans ${MON_NS})"
check "Fichiers du lab (monitoring/, prometheus-client dans packaging/requirements.txt)" \
  "étapes 1 à 10 ; comparer avec l'arborescence de l'énoncé" files_ok
check "Tests du Lab 7 : /metrics de l'API, trafic, analyse du canary (pytest)" \
  "uv run pytest tests/test_monitoring.py -v (étape 1.4)" tests_ok
check "Stack prête : Prometheus, Alertmanager, Grafana, operator, Pushgateway, Loki, Alloy" \
  "make monitoring (étape 3) ; kubectl get pods -n ${MON_NS}" stack_ok
check "PodMonitor scoring-api présent" \
  "kubectl apply -f monitoring/scoring-podmonitor.yaml (étape 4)" podmonitor_ok
check "Cible ${ISVC} scrapée par Prometheus (up == 1)" \
  "Prometheus > Status > Target health ; image instrumentée déployée ? (étapes 2 et 4)" target_up
check "Métriques métier présentes (décisions, scores, latence, groupes de dataset.yaml)" \
  "générer du trafic : uv run python monitoring/traffic.py (étape 5)" business_ok
check "Dashboard scoring-overview chargé par Grafana" \
  "kubectl apply -k monitoring/dashboards (étape 5)" dashboards_ok
check "Règles d'alerte chargées (groupe scoring.alerts, ≥ 4 alertes, santé ok)" \
  "kubectl apply -f monitoring/scoring-alerts.yaml (étape 8.1)" rules_ok
check "Alertmanager : AlertmanagerConfig scoring-slack + Secret slack-webhook chargés" \
  "étape 8.2 ; kubectl logs -n ${MON_NS} alertmanager-kube-prom-stack-kube-prome-alertmanager-0" \
  alertmanager_ok
check "Image du job de drift dans le registry (scoring-drift)" \
  "docker build -f monitoring/evidently-job/Dockerfile … puis docker push (étape 6.3)" \
  drift_image_ok
check "CronJob scoring-drift : au moins une exécution réussie" \
  "kubectl create job --from=cronjob/scoring-drift manual-1 -n ${MON_NS} (étape 6.4)" cronjob_ok
check "Métrique de drift : une série ml_drift_score par variable de dataset.yaml" \
  "≥ 500 demandes dans la dernière heure, puis relancer le job (étape 6.5)" drift_metric_ok
check "Loki reçoit les prédictions journalisées par l'API" \
  "Alloy et Loki Running ? requête LogQL de l'étape 7.2" loki_ok
check "Rapport d'analyse du canary (reports/m7/canary-analysis.{md,json})" \
  "uv run python monitoring/canary_analysis.py (étape 10)" canary_report_ok
check "Rapport reports/rapport-m7.md : 5 sections remplies, sans TODO" \
  "labs/m7-monitoring/starter/rapport-m7.md (étape 9.5)" report_ok

echo
echo "Résultat : $((TOTAL - FAILS))/${TOTAL} vérifications OK"
exit "$FAILS"
