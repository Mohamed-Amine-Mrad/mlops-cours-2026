#!/usr/bin/env bash
# =============================================================================
# Lab 5 — Serving : Knative Serving (+ Kourier) + cert-manager + KServe + metrics-server
#                   [+ KEDA en option]
#
#   make kserve                      # installation standard
#   KSERVE_WITH_KEDA=1 make kserve   # + KEDA (autoscaling événementiel, « Pour aller plus loin »)
#   KSERVE_LIGHT=0 make kserve       # garder les contrôleurs LLMInferenceService et
#                                    # LocalModel de KServe (inutiles dans ce cours)
#
# Installe DANS le cluster existant « mlops-lab » (Lab 0) : on ne recrée jamais le
# cluster, SeaweedFS (S3) et MLflow y vivent. Le port hôte 30080 est déjà mappé
# par infra/kind/kind-config.yaml : on y expose la passerelle Kourier (NodePort).
# Méthode : manifests YAML publiés avec chaque release (méthode « Install using YAML » de
# KServe, kubectl apply --server-side), pas de Helm. Idempotent : relancer le script remet
# la configuration attendue. Versions : infra/versions.env (source unique de vérité).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
source ../versions.env

CTX="kind-${KIND_CLUSTER_NAME}"
k() { kubectl --context "${CTX}" "$@"; }
log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# retry <essais> <commande...> : les webhooks fraîchement installés mettent
# quelques secondes à répondre (erreurs « connection refused » ou x509 transitoires).
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

KNATIVE_SERVING_URL="https://github.com/knative/serving/releases/download/${KNATIVE_VERSION}"
KOURIER_URL="https://github.com/knative-extensions/net-kourier/releases/download/${KNATIVE_VERSION}"
CERT_MANAGER_URL="https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}"
KSERVE_URL="https://github.com/kserve/kserve/releases/download/${KSERVE_VERSION}"
METRICS_SERVER_URL="https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}"
KEDA_URL="https://github.com/kedacore/keda/releases/download/${KEDA_VERSION}"

# --- 0. Le cluster du Lab 0 doit exister ---------------------------------------
if ! k cluster-info >/dev/null 2>&1; then
  echo "Cluster ${CTX} injoignable. Lancez d'abord 'make up' (Lab 0) : ce script" >&2
  echo "ne crée PAS de cluster (SeaweedFS et MLflow vivent dans mlops-lab)." >&2
  exit 1
fi

# --- 1. Knative Serving + Kourier ------------------------------------------------
log "Knative Serving ${KNATIVE_VERSION}"
k apply -f "${KNATIVE_SERVING_URL}/serving-crds.yaml"
k wait --for=condition=Established --timeout=120s crd/services.serving.knative.dev
k apply -f "${KNATIVE_SERVING_URL}/serving-core.yaml"

log "Kourier ${KNATIVE_VERSION} (couche réseau de Knative, à la place d'Istio)"
k apply -f "${KOURIER_URL}/kourier.yaml"
k -n knative-serving wait --for=condition=Available deploy --all --timeout=300s
k -n kourier-system wait --for=condition=Available deploy --all --timeout=300s

log "Configuration Knative pour kind"
# Kourier comme ingress de Knative (clé « ingress-class » ; « ingress.class » est l'ancien nom)
retry 6 k -n knative-serving patch configmap/config-network --type merge \
  -p '{"data":{"ingress-class":"kourier.ingress.networking.knative.dev"}}'
# Domaine externe example.com, sans DNS : on passe l'en-tête Host à curl / Locust
k -n knative-serving patch configmap/config-domain --type merge \
  -p '{"data":{"example.com":""}}'
# Ne pas résoudre les tags du registry local en digest : le contrôleur Knative tourne
# dans un pod, pour qui localhost:5001 n'existe pas (seuls les nœuds kind le voient).
k -n knative-serving patch configmap/config-deployment --type merge \
  -p "{\"data\":{\"registries-skipping-tag-resolving\":\"kind.local,ko.local,dev.local,localhost:${REGISTRY_PORT}\"}}"
# Passerelle Kourier en NodePort 30080 (port hôte mappé par kind-config.yaml)
k -n kourier-system patch service/kourier \
  -p '{"spec":{"type":"NodePort","ports":[{"port":80,"nodePort":30080}]}}'

# --- 2. cert-manager (certificats des webhooks KServe) -------------------------
log "cert-manager ${CERT_MANAGER_VERSION}"
k apply -f "${CERT_MANAGER_URL}/cert-manager.yaml"
k -n cert-manager wait --for=condition=Available deploy --all --timeout=300s

# --- 3. KServe ------------------------------------------------------------------
log "KServe ${KSERVE_VERSION}"
# kserve.yaml (CRD + contrôleurs) ne contient plus le namespace depuis la v0.21
k create namespace kserve --dry-run=client -o yaml | k apply -f -
# --server-side : le CRD InferenceService dépasse la limite de taille de l'annotation
# last-applied-configuration de 'kubectl apply' classique.
retry 6 k apply --server-side --force-conflicts -f "${KSERVE_URL}/kserve.yaml"
k -n kserve wait --for=condition=Available deploy --all --timeout=300s

log "Configuration KServe : mode Knative par défaut, Kourier au lieu d'Istio"
k -n kserve patch configmap/inferenceservice-config --type merge \
  --patch-file inferenceservice-config-patch.yaml
k -n kserve rollout restart deploy/kserve-controller-manager
k -n kserve rollout status deploy/kserve-controller-manager --timeout=300s

log "Runtimes de modèles (ClusterServingRuntimes : sklearn, triton, ...)"
# Le fichier contient aussi des LLMInferenceServiceConfig, validés par le webhook du
# contrôleur llmisvc : il doit tourner pendant l'apply (relance après KSERVE_LIGHT=1).
k -n kserve scale deploy/llmisvc-controller-manager --replicas=1
k -n kserve rollout status deploy/llmisvc-controller-manager --timeout=300s
retry 6 k apply --server-side --force-conflicts -f "${KSERVE_URL}/kserve-cluster-resources.yaml"

if [ "${KSERVE_LIGHT:-1}" = "1" ]; then
  # Contrôleurs des LLMInferenceService et du cache LocalModel : non utilisés dans
  # le cours, on rend leur mémoire au poste (KSERVE_LIGHT=0 pour les garder).
  k -n kserve scale deploy/llmisvc-controller-manager \
    deploy/kserve-localmodel-controller-manager --replicas=0
fi

# --- 4. metrics-server (kubectl top, HPA sur le CPU) ----------------------------
log "metrics-server ${METRICS_SERVER_VERSION}"
k apply -f "${METRICS_SERVER_URL}/components.yaml"
# kind : certificats kubelet auto-signés -> --kubelet-insecure-tls (une seule fois)
if ! k -n kube-system get deploy metrics-server \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q kubelet-insecure-tls; then
  k -n kube-system patch deploy metrics-server --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
fi
k -n kube-system rollout status deploy/metrics-server --timeout=300s

# --- 5. KEDA (optionnel) --------------------------------------------------------
if [ "${KSERVE_WITH_KEDA:-0}" = "1" ]; then
  log "KEDA ${KEDA_VERSION}"
  k apply --server-side --force-conflicts -f "${KEDA_URL}/keda-${KEDA_VERSION#v}.yaml"
  k -n keda wait --for=condition=Available deploy --all --timeout=300s
fi

# --- Résumé ---------------------------------------------------------------------
log "Serving prêt"
k get pods -n knative-serving
k get pods -n kourier-system
k get pods -n cert-manager
k get pods -n kserve
k get svc kourier -n kourier-system
echo
echo "Passerelle Knative (Kourier) : http://localhost:30080 (en-tête Host = URL de l'ISVC)"
