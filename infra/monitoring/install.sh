#!/usr/bin/env bash
# =============================================================================
# Lab 7 — Stack d'observabilité dans le namespace "monitoring" (idempotent).
#   kube-prometheus-stack : Prometheus, Alertmanager, Grafana, operator, exporters
#   prometheus-pushgateway: réception des métriques du job de drift (CronJob)
#   Loki (monolithique)   : stockage des logs (chart grafana-community/loki)
#   Grafana Alloy         : collecte des logs des pods -> Loki (remplace Promtail)
#
# Usage (depuis la racine du repo) :
#   make monitoring                               # tout installer
#   ./infra/monitoring/install.sh kps             # seulement kube-prometheus-stack
#   ./infra/monitoring/install.sh pushgateway | loki | all
#
# Values de kube-prometheus-stack : monitoring/values-monitoring.yaml (écrit par
# l'étudiant à l'étape 3) s'il existe, sinon la copie de référence
# infra/monitoring/values-monitoring.yaml.
# Pré-requis : helm (Lab 0 : Helm 4 ; Helm >= 3.15 convient), kubectl, cluster du Lab 0.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck disable=SC1091
source infra/versions.env

# Versions des charts complémentaires (vérifiées en octobre 2026), surchargeables par
# l'environnement. kube-prometheus-stack : KUBE_PROMETHEUS_STACK_VERSION (versions.env).
: "${PUSHGATEWAY_CHART_VERSION:=3.9.0}"   # Pushgateway v1.11.3
: "${LOKI_CHART_VERSION:=18.13.8}"        # Loki 3.7.8
: "${ALLOY_CHART_VERSION:=1.13.0}"        # Alloy v1.20.0

CTX="kind-${KIND_CLUSTER_NAME}"
NS=monitoring
HERE=infra/monitoring
COMPONENT="${1:-all}"

KPS_VALUES=monitoring/values-monitoring.yaml
[ -f "$KPS_VALUES" ] || KPS_VALUES="$HERE/values-monitoring.yaml"

command -v helm >/dev/null || {
  echo "helm introuvable : voir Lab 0, étape 2 (installation de helm)." >&2
  exit 1
}
kubectl --context "$CTX" get nodes >/dev/null || {
  echo "Cluster $CTX injoignable : lancez 'make cluster' (Lab 0)." >&2
  exit 1
}

helm_up() {
  helm --kube-context "$CTX" upgrade --install --namespace "$NS" --create-namespace "$@"
}

repos() {
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts \
    --force-update >/dev/null
  # Chart Loki : maintenu par la communauté depuis 2026 (grafana/loki-stack est déprécié)
  helm repo add grafana-community https://grafana-community.github.io/helm-charts \
    --force-update >/dev/null
  helm repo add grafana https://grafana.github.io/helm-charts --force-update >/dev/null
  helm repo update prometheus-community grafana-community grafana >/dev/null
}

install_kps() {
  echo ">>> kube-prometheus-stack ${KUBE_PROMETHEUS_STACK_VERSION} (values : ${KPS_VALUES})"
  helm_up kube-prom-stack prometheus-community/kube-prometheus-stack \
    --version "${KUBE_PROMETHEUS_STACK_VERSION}" \
    --values "${KPS_VALUES}" --wait --timeout 10m
}

install_pushgateway() {
  echo ">>> prometheus-pushgateway ${PUSHGATEWAY_CHART_VERSION}"
  helm_up prometheus-pushgateway prometheus-community/prometheus-pushgateway \
    --version "${PUSHGATEWAY_CHART_VERSION}" \
    --values "$HERE/values-pushgateway.yaml" --wait --timeout 5m
}

install_loki() {
  echo ">>> Loki (chart grafana-community/loki ${LOKI_CHART_VERSION})"
  helm_up loki grafana-community/loki \
    --version "${LOKI_CHART_VERSION}" \
    --values "$HERE/values-loki.yaml" --wait --timeout 10m
  echo ">>> Grafana Alloy (chart grafana/alloy ${ALLOY_CHART_VERSION})"
  helm_up alloy grafana/alloy \
    --version "${ALLOY_CHART_VERSION}" \
    --values "$HERE/values-alloy.yaml" --wait --timeout 5m
}

repos
case "$COMPONENT" in
  kps) install_kps ;;
  pushgateway) install_pushgateway ;;
  loki) install_loki ;;
  all)
    install_kps
    install_pushgateway
    install_loki
    ;;
  *)
    echo "Composant inconnu : $COMPONENT (kps | pushgateway | loki | all)" >&2
    exit 2
    ;;
esac

kubectl --context "$CTX" -n "$NS" get pods
cat <<'EOF'

Accès depuis le poste (port-forwards en arrière-plan) : ./infra/monitoring/port-forward.sh
  Grafana      http://localhost:3000   (admin / admin)
  Prometheus   http://localhost:9090
  Alertmanager http://localhost:9093
  Loki         http://localhost:3100   (API, pas d'interface)
EOF
