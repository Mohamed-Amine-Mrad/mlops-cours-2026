#!/usr/bin/env bash
# =============================================================================
# Kubeflow Pipelines standalone (Lab 2) — version lue dans infra/versions.env.
#   make kfp      (ou ./infra/kfp/install.sh)
#
# Manifests officiels kustomize, env « platform-agnostic » : API server, UI,
# Argo Workflows (moteur d'exécution), MySQL (métadonnées), ML Metadata et un
# SeaweedFS INTERNE (stockage des artefacts, bucket mlpipeline — remplace MinIO
# depuis KFP 2.15). Ce SeaweedFS appartient à KFP : il est distinct du S3 du
# cours (namespace storage). Pas de Notebooks/Katib/KServe : trop lourd pour kind.
# Idempotent : relancer le script ré-applique les mêmes manifests.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
source ../versions.env

KCTX="kind-${KIND_CLUSTER_NAME}"
K=(kubectl --context "${KCTX}")
BASE="github.com/kubeflow/pipelines/manifests/kustomize"

if ! "${K[@]}" get nodes >/dev/null 2>&1; then
  echo "Cluster ${KCTX} injoignable : lancez d'abord 'make cluster' (Lab 0)." >&2
  exit 1
fi

echo "==> 1/3 KFP ${KFP_VERSION} : ressources cluster (CRD + namespace kubeflow)"
"${K[@]}" apply -k "${BASE}/cluster-scoped-resources?ref=${KFP_VERSION}"
"${K[@]}" wait --for condition=established --timeout=120s \
  crd/applications.app.k8s.io \
  crd/scheduledworkflows.kubeflow.org \
  crd/workflows.argoproj.io

echo "==> 2/3 KFP ${KFP_VERSION} : composants (env/platform-agnostic)"
"${K[@]}" apply -k "${BASE}/env/platform-agnostic?ref=${KFP_VERSION}"

echo "==> 3/3 Attente des déploiements (premier pull des images : 5 à 10 min)"
# mysql et seaweedfs d'abord : ml-pipeline et metadata-grpc redémarrent tant que
# la base n'est pas prête (quelques CrashLoopBackOff au début : c'est normal).
"${K[@]}" -n kubeflow rollout status deploy/mysql --timeout=900s
"${K[@]}" -n kubeflow rollout status deploy/seaweedfs --timeout=900s
"${K[@]}" -n kubeflow wait --for=condition=Available deploy --all --timeout=900s

"${K[@]}" -n kubeflow get pods
cat <<EOF

KFP ${KFP_VERSION} prêt. UI et API (à laisser tourner dans un terminal) :
  kubectl -n kubeflow port-forward svc/ml-pipeline-ui 8080:80
  -> http://localhost:8080   (SDK : kfp.Client(host="http://localhost:8080"))
Artefacts des runs : SeaweedFS interne de KFP (svc seaweedfs.kubeflow, bucket mlpipeline).
EOF
