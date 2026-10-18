#!/usr/bin/env bash
# Crée le cluster kind du cours + un registry Docker local branché dessus.
# Idempotent : relancer le script ne casse rien.
# Recette officielle : https://kind.sigs.k8s.io/docs/user/local-registry/
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
source ../versions.env

# 1. Registry local (localhost:5001)
if [ "$(docker inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || true)" != "true" ]; then
  docker run -d --restart=always -p "127.0.0.1:${REGISTRY_PORT}:5000" \
    --network bridge --name "${REGISTRY_NAME}" "${REGISTRY_IMAGE}"
fi

# 2. Cluster
if ! kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER_NAME}"; then
  kind create cluster --config kind-config.yaml
else
  echo "Cluster ${KIND_CLUSTER_NAME} déjà présent — rien à faire."
fi

# 3. Alias localhost:5001 -> registry sur chaque nœud
REGISTRY_DIR="/etc/containerd/certs.d/localhost:${REGISTRY_PORT}"
for node in $(kind get nodes --name "${KIND_CLUSTER_NAME}"); do
  docker exec "${node}" mkdir -p "${REGISTRY_DIR}"
  printf '[host."http://%s:5000"]\n' "${REGISTRY_NAME}" \
    | docker exec -i "${node}" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
done

# 4. Registry sur le réseau Docker "kind"
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${REGISTRY_NAME}")" = "null" ]; then
  docker network connect kind "${REGISTRY_NAME}"
fi

# 5. Documenter le registry (KEP-1755)
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

kubectl cluster-info --context "kind-${KIND_CLUSTER_NAME}"
