#!/usr/bin/env bash
# shellcheck disable=SC2329  # fonctions de test appelées indirectement via check()
# =============================================================================
# Vérification automatique du Lab 8 — Audit de gouvernance du modèle de scoring
# Lancer depuis la racine du repo :  make check-m8
# Pré-requis : Docker démarré, cluster du Lab 0 (contexte kind-mlops-lab), port-forwards
# (make pf) pour interroger MLflow, .env présent. Les attributs sensibles, features et
# noms de colonnes sont lus dans dataset.yaml (aucun nom de colonne en dur ici).
# Variables optionnelles : IMAGE (défaut scoring-api:distroless), NS (défaut scoring),
#                          CHECK_PORT (port hôte du conteneur de test, défaut 16880).
# Code retour = nombre de vérifications en échec (0 = tout est vert).
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

# shellcheck disable=SC1091
source infra/versions.env
ENV_FILE=.env
[ -f "$ENV_FILE" ] || ENV_FILE=.env.example
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
export MLFLOW_DISABLE_AGENT_HINT=1 PYTHONWARNINGS=ignore

CTX=${KCTX:-kind-${KIND_CLUSTER_NAME}}
NS=${NS:-scoring}
IMAGE=${IMAGE:-scoring-api:distroless}
CHECK_PORT=${CHECK_PORT:-16880}
ISVC=scoring-model
SA=scoring-sa
SECRET=s3-credentials
CONTAINER=m8-check-$$
FAILS=0
TOTAL=0

t() {
  local secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else "$@"; fi
}
py() { t 120 uv run --no-sync python "$@"; }
kc() { t 20 kubectl --context "$CTX" --request-timeout=15s "$@"; }

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

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# --- Fichiers du lab ----------------------------------------------------------------
files_ok() {
  local f
  for f in governance/__init__.py governance/fairness_analysis.py \
    governance/fairness_mitigation.py governance/explain.py governance/explain_local.py \
    packaging/Dockerfile.distroless k8s/rbac-scoring.yaml k8s/mlflow-creds-source.yaml; do
    [ -s "$f" ] || return 1
  done
}

# --- Sécurité : image et modèle ---------------------------------------------------
# Somme des « Total: N » d'un rapport Trivy (une ligne par cible scannée)
trivy_total() { grep -E "^Total: [0-9]+" "$1" | awk '{s += $2} END {print s + 0}'; }
trivy_reports() {
  [ -s reports/trivy_full.txt ] &&
    grep -qE "^Total: [0-9]+" reports/trivy_critical.txt &&
    grep -qE "^Total: [0-9]+" reports/trivy_distroless.txt
}
trivy_reduced() {
  trivy_reports &&
    [ "$(trivy_total reports/trivy_distroless.txt)" -le "$(trivy_total reports/trivy_critical.txt)" ]
}
image_ok() { docker image inspect "$IMAGE" >/dev/null 2>&1; }
non_root() {
  local user
  user=$(docker image inspect -f '{{.Config.User}}' "$IMAGE")
  [ -n "$user" ] && [[ ! "$user" =~ ^(root|0)(:|$) ]]
}
no_shell() { image_ok && ! t 30 docker run --rm --entrypoint sh "$IMAGE" -c true; }
python312() { t 30 docker run --rm --entrypoint python "$IMAGE" --version | grep -q "Python 3\.12\."; }
container_up() {
  cleanup
  docker run -d --name "$CONTAINER" -p "${CHECK_PORT}:8000" "$IMAGE" >/dev/null || return 1
  for _ in $(seq 1 20); do
    if t 5 curl -fsS "http://localhost:${CHECK_PORT}/health" | grep -q '"model_loaded":true'; then
      return 0
    fi
    sleep 1
  done
  return 1
}
modelscan_pickle_ok() { grep -qE "CRITICAL: [1-9]" reports/modelscan_pickle.txt; }
modelscan_onnx_ok() { grep -q "No issues found" reports/modelscan_onnx.txt; }

# --- Équité et explicabilité (lit dataset.yaml) -------------------------------------
fairness_baseline_ok() {
  py - <<'EOF'
import json

import pandas as pd

from src.dataset_config import load_config
from src.train import TEST_CSV

cfg = load_config()
report = json.load(open("reports/fairness_baseline.json"))
expected = cfg.sensitive_frame(pd.read_csv(TEST_CSV))
assert cfg.sensitive, "aucun attribut sensible dans dataset.yaml"
for attr, col in zip(cfg.sensitive, expected.columns, strict=True):
    entry = report["attributes"][attr.column]  # un rapport par attribut sensible
    groups = set(entry["groups"])
    assert groups and groups <= set(expected[col].unique()), (attr.column, groups)
    for key in ("demographic_parity_difference", "equalized_odds_difference"):
        assert isinstance(entry[key], float), key
    for metrics in entry["groups"].values():
        assert {"taux_refus", "TPR", "FPR", "cout_moyen"} <= set(metrics)
EOF
}
fairness_current() {
  py - <<'EOF'
import json

from mlflow import MlflowClient

from src.promote import MODEL_NAME

report = json.load(open("reports/fairness_baseline.json"))
client = MlflowClient()
version = client.get_model_version_by_alias(MODEL_NAME, "champion")
threshold = float(client.get_run(version.run_id).data.params["decision_threshold"])
assert str(report["model_version"]) == str(version.version), "audit d'une autre version"
assert abs(report["decision_threshold"] - threshold) < 1e-6, "audit à un autre seuil"
EOF
}
mitigation_ok() {
  py - <<'EOF'
import json

from src.dataset_config import load_config

cfg = load_config()
report = json.load(open("reports/fairness_mitigated.json"))
needed = {"champion", "sans_attribut", "threshold_optimizer_cout", "exponentiated_gradient"}
for attr in cfg.sensitive:
    entry = report["attributes"][attr.column]
    assert needed <= set(entry["strategies"]), attr.column
    assert "auc" in entry["proxy"], attr.column
    for result in entry["strategies"].values():
        assert {"business_cost", "equalized_odds_difference"} <= set(result)
EOF
}
shap_global_ok() { [ -s reports/shap_summary_bar.png ] && [ -s reports/shap_beeswarm.png ]; }
waterfalls_ok() {
  [ "$(find reports -maxdepth 1 -name 'shap_waterfall_*.png' -size +1k | wc -l)" -ge 3 ] &&
    grep -q "^## " reports/explanations_local.md
}
shap_importance_ok() {
  py - <<'EOF'
import json

from src.dataset_config import load_config

cfg = load_config()
report = json.load(open("reports/shap_importance.json"))
assert set(report["importance"]) == set(cfg.features), "importance incomplète"
assert set(report["sensitive_ranks"]) == {s.column for s in cfg.sensitive}
EOF
}

# --- Documentation -------------------------------------------------------------------
CARD=model-card/model-card.md
card_sections() {
  [ -s "$CARD" ] && [ "$(grep -c '^## ' "$CARD")" -ge 11 ] || return 1
  local section
  for section in "Détails" "Usage prévu" "Facteurs" "Métriques" "évaluation" \
    "entraînement" "Analyse quantitative" "éthiques" "Mises en garde"; do
    grep -qiE "^## .*${section}" "$CARD" || return 1
  done
}
card_complete() {
  [ -s "$CARD" ] && ! grep -q "TODO" "$CARD" && grep -qi "haut risque" "$CARD" &&
    py - <<'EOF'
from pathlib import Path

from src.dataset_config import load_config

card = Path("model-card/model-card.md").read_text(encoding="utf-8")
missing = [s.column for s in load_config().sensitive if s.column not in card]
assert not missing, f"attributs sensibles absents de la Model Card : {missing}"
EOF
}
compliance_ok() {
  local f=reports/compliance-ai-act.md
  [ -s "$f" ] && [ "$(grep -c '^## ' "$f")" -ge 5 ] && ! grep -q "TODO" "$f"
}

# --- Kubernetes : External Secrets, RBAC ------------------------------------------------
eso_installed() { kc -n external-secrets wait --for=condition=Available deploy --all --timeout=15s; }
eso_api_v1() {
  kc get crd externalsecrets.external-secrets.io \
    -o jsonpath='{.spec.versions[?(@.served==true)].name}' | grep -qw v1
}
store_ready() {
  [ "$(kc -n "$NS" get secretstore course-secrets \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = "True" ]
}
es_synced() {
  local status
  status=$(kc -n "$NS" get externalsecret "$SECRET" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}/{.status.conditions[?(@.type=="Ready")].reason}')
  [ "$status" = "True/SecretSynced" ]
}
secret_owned() {
  local kinds src dst
  kinds=$(kc -n "$NS" get secret "$SECRET" -o jsonpath='{.metadata.ownerReferences[*].kind}')
  [[ "$kinds" == *ExternalSecret* ]] || return 1
  for key in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    src=$(kc -n storage get secret "$SECRET" -o jsonpath="{.data.${key}}")
    dst=$(kc -n "$NS" get secret "$SECRET" -o jsonpath="{.data.${key}}")
    [ -n "$src" ] && [ "$src" = "$dst" ] || return 1
  done
}
no_secret_in_git() {
  local value dirs=()
  value=$(kc -n storage get secret "$SECRET" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' |
    base64 -d) || return 1
  [ -n "$value" ] || return 1
  for d in k8s serving; do [ -d "$d" ] && dirs+=("$d"); done
  [ ${#dirs[@]} -eq 0 ] || ! grep -rqF -- "$value" "${dirs[@]}"
}
rbac_objects() {
  kc -n "$NS" get role scoring-reader >/dev/null &&
    kc -n "$NS" get rolebinding scoring-reader-binding >/dev/null &&
    [ "$(kc -n "$NS" get serviceaccount "$SA" \
      -o jsonpath='{.automountServiceAccountToken}')" = "false" ]
}
can_i() { kc auth can-i "$@" --as="system:serviceaccount:${NS}:${SA}" -n "$NS"; }
rbac_least_privilege() {
  [ "$(can_i create pods)" = "no" ] && [ "$(can_i list secrets)" = "no" ] &&
    [ "$(can_i get "secret/${SECRET}")" = "yes" ]
}
isvc_sa() {
  [ "$(kc -n "$NS" get isvc "$ISVC" -o jsonpath='{.spec.predictor.serviceAccountName}')" = "$SA" ]
}
# L'ISVC de prod est géré par Argo CD (Lab 6, selfHeal) : le ServiceAccount doit venir de Git.
isvc_sa_git() {
  t 30 kubectl kustomize k8s/overlays/prod |
    grep -Eq "^[[:space:]]*serviceAccountName:[[:space:]]*${SA}[[:space:]]*$"
}

# --- Vérifications --------------------------------------------------------------
echo "Lab 8 — Audit de gouvernance (image ${IMAGE}, namespace ${NS})"
check "Fichiers du lab présents (governance/, Dockerfile.distroless, k8s/)" \
  "voir les blocs « # Fichier : » de l'énoncé" files_ok
echo "-- Sécurité"
check "Rapports Trivy (full, critical, distroless)" "étapes 1.2 et 1.3" trivy_reports
check "CVE HIGH/CRITICAL : distroless ≤ image du Lab 4" \
  "base dhi.io/python:3.12-debian13 (étape 1.3)" trivy_reduced
if [ -s reports/trivy_critical.txt ] && [ -s reports/trivy_distroless.txt ]; then
  echo "   ↳ HIGH+CRITICAL : $(trivy_total reports/trivy_critical.txt) (Lab 4)" \
    "-> $(trivy_total reports/trivy_distroless.txt) (distroless)"
fi
check "Image ${IMAGE} construite" \
  "docker build -f packaging/Dockerfile.distroless -t ${IMAGE} . (étape 1.3)" image_ok
check "Image : utilisateur non-root" "USER 65532:65532 dans Dockerfile.distroless" non_root
check "Image : aucun shell" "runtime dhi.io/python:3.12-debian13 (sans -dev)" no_shell
check "Image : Python 3.12" "mêmes FROM 3.12 pour builder et runtime" python312
check "Image : /health répond" \
  "docker run --rm ${IMAGE} pour voir les logs ; port ${CHECK_PORT} libre ?" container_up
check "ModelScan : pickle piégé détecté (CRITICAL)" \
  "make_pickles.py puis modelscan -p packaging/scan-demo/ (étape 2)" modelscan_pickle_ok
check "ModelScan : ONNX sans problème" "modelscan -p packaging/model/model.onnx (étape 2)" \
  modelscan_onnx_ok

echo "-- Équité et explicabilité (attributs sensibles de dataset.yaml)"
check "Rapport d'équité : un rapport par attribut sensible, groupes cohérents" \
  "uv run python -m governance.fairness_analysis (étape 3)" fairness_baseline_ok
check "Rapport d'équité = champion actuel (version, seuil)" \
  "make pf ; relancer governance.fairness_analysis après un changement de champion" \
  fairness_current
check "Atténuations comparées pour chaque attribut (+ test de proxy)" \
  "uv run python -m governance.fairness_mitigation (étape 4)" mitigation_ok
check "SHAP : importance globale + beeswarm" "uv run python -m governance.explain (étape 5.1)" \
  shap_global_ok
check "SHAP : importance couvrant toutes les features" "étape 5.1" shap_importance_ok
check "SHAP : ≥ 3 waterfalls + explications rédigées" \
  "uv run python -m governance.explain_local (étape 5.2)" waterfalls_ok

echo "-- Documentation"
check "Model Card : sections attendues (≥ 11)" \
  "cp labs/m8-governance/starter/model-card.md model-card/ (étape 6)" card_sections
check "Model Card complète (aucun TODO, attributs sensibles, haut risque)" "étape 6" \
  card_complete
check "Rapport de conformité AI Act (5 sections, aucun TODO)" \
  "reports/compliance-ai-act.md (étape 9)" compliance_ok

echo "-- Kubernetes"
check "External Secrets Operator installé" "make external-secrets (étape 8.1)" eso_installed
check "API external-secrets.io/v1 servie" "make external-secrets (étape 8.1)" eso_api_v1
check "SecretStore course-secrets prêt" \
  "kubectl describe secretstore course-secrets -n ${NS} (étape 8.2)" store_ready
check "ExternalSecret ${SECRET} synchronisé (SecretSynced)" \
  "kubectl describe externalsecret ${SECRET} -n ${NS}" es_synced
check "Secret ${SECRET} possédé par ESO, identique à la source" \
  "kubectl apply -f k8s/mlflow-creds-source.yaml (étape 8.2)" secret_owned
check "Aucune valeur secrète dans k8s/ ni serving/" \
  "supprimer les identifiants en clair des manifests" no_secret_in_git
check "RBAC : ${SA} (sans jeton monté), Role, RoleBinding" \
  "kubectl apply -f k8s/rbac-scoring.yaml (étape 7)" rbac_objects
check "RBAC : create pods = no, list secrets = no, get ${SECRET} = yes" \
  "kubectl auth can-i … --as=system:serviceaccount:${NS}:${SA} (étape 7)" rbac_least_privilege
check "Overlay Git de prod : serviceAccountName ${SA}" \
  "patch dans k8s/overlays/prod/kustomization.yaml (étape 7)" isvc_sa_git
check "InferenceService ${ISVC} sur le ServiceAccount ${SA}" \
  "fusion de la PR du lab dans main, puis synchronisation Argo CD scoring-prod (étape 9)" isvc_sa

echo
echo "Résultat : $((TOTAL - FAILS))/${TOTAL} vérifications OK"
exit "$FAILS"
