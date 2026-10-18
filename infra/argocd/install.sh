#!/usr/bin/env bash
# =============================================================================
# Lab 6 — Argo CD (GitOps) dans le cluster du cours — version : ARGOCD_VERSION
# de infra/versions.env.
#   make argocd        (ou ./infra/argocd/install.sh) ; idempotent : relancer sans risque
#
# - manifest officiel non-HA « install.yaml » du tag, appliqué avec
#   --server-side --force-conflicts (procédure Argo CD 3 : le CRD ApplicationSet dépasse
#   la taille maximale de l'annotation d'un « kubectl apply » classique) ;
# - réconciliation toutes les 60 s (défaut : 120 s + jusqu'à 60 s de gigue) : GitHub ne
#   peut pas appeler un cluster kind (pas de webhook), Argo CD interroge donc Git ;
# - Dex (SSO), le contrôleur de notifications et celui des ApplicationSets, inutiles
#   dans le cours, passent à 0 réplique (≈ 150 Mo de RAM rendus au poste).
# Argo Rollouts (ARGO_ROLLOUTS_VERSION) n'est PAS installé : le canary du cours est
# celui de KServe (canaryTrafficPercent), piloté par Git.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
source ../versions.env

CTX="kind-${KIND_CLUSTER_NAME}"
NS=argocd
URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
k() { kubectl --context "${CTX}" "$@"; }
log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
retry() {
  local n=$1 i
  shift
  for ((i = 1; i <= n; i++)); do
    "$@" && return 0
    echo "   ... nouvel essai dans 10 s ($i/$n)"
    sleep 10
  done
  return 1
}

if ! k cluster-info >/dev/null 2>&1; then
  echo "Cluster ${CTX} injoignable : lancez d'abord 'make up' (Lab 0)." >&2
  exit 1
fi

log "Argo CD ${ARGOCD_VERSION} (namespace ${NS})"
k create namespace "${NS}" --dry-run=client -o yaml | k apply -f -
retry 3 k apply -n "${NS}" --server-side --force-conflicts -f "${URL}"

log "Réconciliation toutes les 60 s ; composants inutiles au cours à 0 réplique"
k -n "${NS}" patch configmap argocd-cm --type merge \
  -p '{"data":{"timeout.reconciliation":"60s","timeout.reconciliation.jitter":"10s"}}'
k -n "${NS}" scale deploy argocd-dex-server argocd-notifications-controller \
  argocd-applicationset-controller --replicas=0
# Le délai de réconciliation n'est lu qu'au démarrage du contrôleur et du repo-server
k -n "${NS}" rollout restart deploy/argocd-repo-server statefulset/argocd-application-controller
for obj in deploy/argocd-redis deploy/argocd-repo-server deploy/argocd-server \
  statefulset/argocd-application-controller; do
  k -n "${NS}" rollout status "${obj}" --timeout=600s
done

log "Argo CD prêt"
k -n "${NS}" get pods
# Le mot de passe admin initial est créé par argocd-server à son premier démarrage
for _ in $(seq 1 30); do
  k -n "${NS}" get secret argocd-initial-admin-secret >/dev/null 2>&1 && break
  sleep 2
done
echo
echo "Interface : kubectl port-forward -n ${NS} svc/argocd-server 8443:443"
echo "            puis https://localhost:8443 (certificat auto-signé), utilisateur admin"
printf 'Mot de passe admin initial : '
k -n "${NS}" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' |
  base64 -d
echo
echo "CLI (optionnelle) : https://github.com/argoproj/argo-cd/releases/tag/${ARGOCD_VERSION}"
