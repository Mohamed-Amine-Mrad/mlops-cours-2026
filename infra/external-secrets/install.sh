#!/usr/bin/env bash
# =============================================================================
# Lab 8 — External Secrets Operator (ESO) dans le namespace "external-secrets".
#   make external-secrets      (ou ./infra/external-secrets/install.sh)
#
# Chart Helm officiel (https://charts.external-secrets.io), version lue dans
# infra/versions.env (EXTERNAL_SECRETS_VERSION=v2.11.0 -> chart 2.11.0).
# Installe les CRD (installCRDs=true par défaut) : SecretStore, ExternalSecret…
# servies en external-secrets.io/v1 uniquement (v1beta1 n'est plus servie par défaut).
# Trois déploiements : le contrôleur, le webhook d'admission et le cert-controller
# (certificats du webhook) — pas besoin de cert-manager.
# Installe DANS le cluster existant « mlops-lab » (Lab 0). Idempotent.
# Pré-requis : helm >= 3.15 (installé au Lab 0 ; Helm 4 conseillé), kubectl.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
source ../versions.env

CTX="kind-${KIND_CLUSTER_NAME}"
NS=external-secrets
CHART_VERSION="${EXTERNAL_SECRETS_VERSION#v}" # v2.11.0 -> 2.11.0
k() { kubectl --context "${CTX}" "$@"; }

command -v helm >/dev/null || {
  echo "helm introuvable : voir Lab 0, étape 2 (installation de helm)." >&2
  exit 1
}
if ! k cluster-info >/dev/null 2>&1; then
  echo "Cluster ${CTX} injoignable. Lancez d'abord 'make up' (Lab 0)." >&2
  exit 1
fi

echo "==> External Secrets Operator ${EXTERNAL_SECRETS_VERSION} (chart ${CHART_VERSION})"
helm repo add external-secrets https://charts.external-secrets.io --force-update >/dev/null
helm repo update external-secrets >/dev/null
helm --kube-context "${CTX}" upgrade --install external-secrets \
  external-secrets/external-secrets \
  --version "${CHART_VERSION}" \
  --namespace "${NS}" --create-namespace \
  --set installCRDs=true \
  --wait --timeout 10m

echo "==> Attente des CRD et des déploiements"
k wait --for=condition=Established --timeout=120s \
  crd/externalsecrets.external-secrets.io \
  crd/secretstores.external-secrets.io \
  crd/clustersecretstores.external-secrets.io
k -n "${NS}" wait --for=condition=Available deploy --all --timeout=300s

k -n "${NS}" get deploy
echo "API servies : $(k get crd externalsecrets.external-secrets.io \
  -o jsonpath='{range .spec.versions[?(@.served==true)]}{.name} {end}')"
cat <<EOF

ESO ${EXTERNAL_SECRETS_VERSION} prêt. Suite du Lab 8 (étape 8) :
  kubectl apply -f k8s/mlflow-creds-source.yaml
  kubectl -n scoring get secretstore,externalsecret
EOF
