#!/usr/bin/env bash
# =============================================================================
# Airflow (Lab 2, variante de comparaison) — version lue dans infra/versions.env.
#   make airflow      (ou ./infra/airflow/install.sh)
#
# Comme dans la doc officielle « Running Airflow in Docker » : Airflow tourne en
# Docker Compose sur le poste (plus léger qu'un déploiement Helm dans kind).
# Les TASKS, elles, tournent dans le cluster kind : le KubernetesPodOperator y
# crée un pod par task, dans le namespace « airflow », avec l'image du pipeline.
# Idempotent. Arrêt (libère ~4 Go de RAM) : (cd infra/airflow && docker compose down)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
source ../versions.env

KCTX="kind-${KIND_CLUSTER_NAME}"
K=(kubectl --context "${KCTX}")

echo "==> 1/5 docker-compose.yaml officiel d'Airflow ${AIRFLOW_VERSION} (non modifié)"
if [ ! -f docker-compose.yaml ]; then
  curl -LfsSO "https://airflow.apache.org/docs/apache-airflow/${AIRFLOW_VERSION}/docker-compose.yaml"
fi
mkdir -p ./logs ./plugins ./config ../../dags

echo "==> 2/5 Fichier .env (UID, image épinglée)"
cat >.env <<EOF
AIRFLOW_UID=$(id -u)
AIRFLOW_IMAGE_NAME=apache/airflow:${AIRFLOW_VERSION}-python${PYTHON_VERSION}
EOF

echo "==> 3/5 kubeconfig « interne » (API server joignable depuis le réseau Docker kind)"
# shellcheck disable=SC2094 # faux positif : « kubeconfig » est une sous-commande de kind
kind get kubeconfig --internal --name "${KIND_CLUSTER_NAME}" >kubeconfig
chmod 600 kubeconfig # identifiants admin du cluster : ignoré par Git

echo "==> 4/5 Namespace « airflow » + secret s3-credentials pour les pods de tasks"
"${K[@]}" create namespace airflow --dry-run=client -o yaml | "${K[@]}" apply -f -
key_id=$("${K[@]}" -n storage get secret s3-credentials \
  -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
secret=$("${K[@]}" -n storage get secret s3-credentials \
  -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)
"${K[@]}" -n airflow create secret generic s3-credentials \
  --from-literal=AWS_ACCESS_KEY_ID="${key_id}" \
  --from-literal=AWS_SECRET_ACCESS_KEY="${secret}" \
  --dry-run=client -o yaml | "${K[@]}" apply -f -

echo "==> 5/5 Démarrage (premier lancement : 3 à 5 min)"
docker compose up airflow-init
docker compose up -d
for _ in $(seq 1 60); do
  if curl -sf http://localhost:8081/api/v2/monitor/health >/dev/null; then
    break
  fi
  sleep 5
done
docker compose ps
cat <<EOF

Airflow ${AIRFLOW_VERSION} prêt : http://localhost:8081  (airflow / airflow)
DAGs lus dans le dossier dags/ à la racine du repo.
EOF
