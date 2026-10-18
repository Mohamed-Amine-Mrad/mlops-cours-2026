#!/usr/bin/env bash
# =============================================================================
# Lab 7 — port-forwards de la stack d'observabilité, en arrière-plan (comme make pf).
#   ./infra/monitoring/port-forward.sh          démarrer (idempotent)
#   ./infra/monitoring/port-forward.sh stop     arrêter
# Grafana :3000 · Prometheus :9090 · Alertmanager :9093 · Loki :3100 · Pushgateway :9091
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck disable=SC1091
source infra/versions.env
CTX="kind-${KIND_CLUSTER_NAME}"
LOG=/tmp/mlops-port-forward
FORWARDS=(
  "svc/kube-prom-stack-grafana 3000:80"
  "svc/kube-prom-stack-kube-prome-prometheus 9090:9090"
  "svc/kube-prom-stack-kube-prome-alertmanager 9093:9093"
  "svc/loki 3100:3100"
  "svc/prometheus-pushgateway 9091:9091"
)

stop() {
  for f in "${FORWARDS[@]}"; do pkill -f "port-forward ${f}" || true; done
}

if [ "${1:-start}" = "stop" ]; then
  stop
  exit 0
fi
stop
mkdir -p "$LOG"
for f in "${FORWARDS[@]}"; do
  svc=${f%% *}
  # shellcheck disable=SC2086  # "svc/x a:b" doit être découpé en arguments
  nohup kubectl --context "$CTX" -n monitoring port-forward ${f} \
    >"$LOG/${svc#svc/}.log" 2>&1 &
done
sleep 3
echo "Grafana      -> http://localhost:3000  (admin / admin)"
echo "Prometheus   -> http://localhost:9090"
echo "Alertmanager -> http://localhost:9093"
echo "Loki         -> http://localhost:3100"
echo "Pushgateway  -> http://localhost:9091"
