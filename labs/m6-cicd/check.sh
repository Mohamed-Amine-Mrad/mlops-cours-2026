#!/usr/bin/env bash
# shellcheck disable=SC2329  # fonctions de test appelées indirectement via check()
# =============================================================================
# Vérification automatique du Lab 6 — CI/CD/CT (GitHub Actions, Argo CD, CT)
# Lancer depuis la racine du repo :  make check-m6
# Pré-requis : cluster du cours (Labs 0, 2, 5), make argocd, port-forwards (make pf et
# KFP sur 8080), webhook CT lancé (uv run python -m pipelines.trigger_ct serve).
# Variables optionnelles : NS_PROD (scoring), NS_STAGING (scoring-staging),
#   GATEWAY (http://localhost:30080), KFP_HOST (http://localhost:8080),
#   CT_WEBHOOK_PORT (8095), CHECK_KFP_PORT (port-forward de secours, 18680),
#   GITOPS_REMOTE (dépôt lu par Argo CD, origin), CHECK_ALLOW_LOCAL_REGISTRY=1 (CI du
#   cours : images de staging construites sur localhost:5001 au lieu de GHCR).
# Les vérifications impossibles dans votre environnement (gh absent…) sont SKIP et ne
# comptent pas comme des échecs. Code retour = nombre de vérifications en échec.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

# shellcheck disable=SC1091
source infra/versions.env
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi
NS_PROD=${NS_PROD:-scoring}
NS_STAGING=${NS_STAGING:-scoring-staging}
ISVC=scoring-model
GATEWAY=${GATEWAY:-http://localhost:30080}
KFP_HOST=${KFP_HOST:-http://localhost:8080}
CT_WEBHOOK_PORT=${CT_WEBHOOK_PORT:-8095}
CHECK_KFP_PORT=${CHECK_KFP_PORT:-18680}
export MLFLOW_TRACKING_URI=${MLFLOW_TRACKING_URI:-http://localhost:5000}
export GATEWAY NS_PROD
KCTX="kind-${KIND_CLUSTER_NAME}"
FAILS=0
TOTAL=0
SKIPS=0
PF_PID=""
TMP=$(mktemp -d)

t() {
  local secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else "$@"; fi
}
k() { t 30 kubectl --context "$KCTX" "$@"; }
py() { t 300 uv run --no-sync python "$@"; }

check() {
  local label=$1 hint=$2
  shift 2
  TOTAL=$((TOTAL + 1))
  if "$@" >"$TMP/out" 2>&1; then
    echo "✅ ${label}"
  else
    echo "❌ ${label}  →  ${hint}"
    tail -3 "$TMP/out" | awk '{print "     " $0}'
    FAILS=$((FAILS + 1))
  fi
}
skip() {
  echo "⏭️  ${1}  (SKIP : ${2})"
  SKIPS=$((SKIPS + 1))
}
cleanup() {
  [ -n "$PF_PID" ] && kill "$PF_PID" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

# Ce qu'Argo CD applique, c'est origin/main (pas votre copie locale) : on le lit dans Git
REMOTE=${GITOPS_REMOTE:-origin}
git fetch --quiet "$REMOTE" main >/dev/null 2>&1
REF="${REMOTE}/main"
git rev-parse --verify --quiet "$REF" >/dev/null || REF=HEAD
export REF

# --- CI ---------------------------------------------------------------------------
ci_schema_ok() { # schéma officiel si check-jsonschema est disponible (uvx), structure sinon
  if t 120 uvx --quiet check-jsonschema@0.38.2 --version >/dev/null 2>&1; then
    t 120 uvx --quiet check-jsonschema@0.38.2 --builtin-schema vendor.github-workflows \
      .github/workflows/ci.yml || return 1
  fi
  py - <<'EOF'
import yaml

wf = yaml.safe_load(open(".github/workflows/ci.yml", encoding="utf-8"))
on = wf.get("on", wf.get(True))  # « on » est lu comme True par YAML 1.1
assert "push" in on and "src/**" in on["push"]["paths"], "déclencheur push + paths"
text = open(".github/workflows/ci.yml", encoding="utf-8").read()
for needle in ("ruff check", "pytest", "docker/build-push-action", "ghcr.io",
               "pipelines.gitops deploy", "--env staging"):
    assert needle in text, f"étape manquante : {needle}"
assert ":latest" not in text, "tag latest : un tag doit désigner une image immuable"
print(sorted(wf["jobs"]))
EOF
}
ci_run_ok() {
  local conclusion
  conclusion=$(t 30 gh run list --workflow ci.yml --branch main --limit 1 \
    --json conclusion -q '.[0].conclusion')
  echo "dernier run : ${conclusion:-aucun}"
  [ "$conclusion" = "success" ]
}
tests_ok() { t 300 uv run --no-sync ruff check . && t 600 uv run --no-sync pytest -q; }
kustomize_ok() {
  local env
  for env in staging prod; do
    k kustomize "k8s/overlays/${env}" | grep -q "kind: InferenceService" || return 1
  done
}

# --- Argo CD ----------------------------------------------------------------------
argocd_ok() {
  k -n argocd wait --for=condition=Available deploy/argocd-server deploy/argocd-repo-server \
    deploy/argocd-redis --timeout=20s &&
    k -n argocd rollout status statefulset/argocd-application-controller --timeout=20s
}
apps_ok() {
  k -n argocd get applications.argoproj.io -o json >"$TMP/apps.json" || return 1
  py - "$TMP/apps.json" <<'EOF'
import json
import os
import sys

apps = {a["metadata"]["name"]: a for a in json.load(open(sys.argv[1]))["items"]}
for name, ns in (("scoring-staging", "scoring-staging"), ("scoring-prod", os.environ["NS_PROD"])):
    assert name in apps, f"Application {name} absente (kubectl apply -f k8s/argocd-app.yaml)"
    spec, status = apps[name]["spec"], apps[name].get("status", {})
    assert "VOTRE_USER" not in spec["source"]["repoURL"], f"{name} : repoURL non personnalisé"
    assert spec["destination"]["namespace"] == ns, f"{name} : namespace {ns} attendu"
    auto = spec.get("syncPolicy", {}).get("automated") or {}
    assert auto.get("prune") and auto.get("selfHeal"), f"{name} : automated prune + selfHeal"
    sync, health = status.get("sync", {}).get("status"), status.get("health", {}).get("status")
    print(f"{name}: {sync}/{health} @ {status.get('sync', {}).get('revision', '?')[:7]}")
    assert (sync, health) == ("Synced", "Healthy"), f"{name} : {sync}/{health}"
EOF
}
# L'ISVC de prod est suivi par Argo CD et porte l'image ET la part de canary de origin/main
isvc_gitops_ok() {
  k -n "$NS_PROD" get isvc "$ISVC" -o json >"$TMP/isvc.json" || return 1
  git show "${REF}:k8s/overlays/prod/kustomization.yaml" >"$TMP/prod.yaml" &&
    git show "${REF}:k8s/overlays/prod/canary.yaml" >"$TMP/canary.yaml" || return 1
  py - "$TMP" <<'EOF'
import json
import sys

import yaml

tmp = sys.argv[1]
isvc = json.load(open(f"{tmp}/isvc.json"))
tracking = isvc["metadata"].get("annotations", {}).get("argocd.argoproj.io/tracking-id", "")
assert tracking.startswith("scoring-prod:"), f"pas géré par l'Application scoring-prod ({tracking!r})"
image = next(i for i in yaml.safe_load(open(f"{tmp}/prod.yaml"))["images"])
expected = f"{image['newName']}:{image['newTag']}"
live = isvc["spec"]["predictor"]["containers"][0]["image"]
assert live == expected, f"image servie {live} != Git {expected}"
canary = yaml.safe_load(open(f"{tmp}/canary.yaml"))["spec"]["predictor"]["canaryTrafficPercent"]
assert isvc["spec"]["predictor"].get("canaryTrafficPercent") == canary, "canary != Git"
print(f"{live}, canary {canary} %")
EOF
}
staging_ok() {
  local registry='ghcr\.io/[a-z0-9._-]+/[a-z0-9._-]+'
  [ "${CHECK_ALLOW_LOCAL_REGISTRY:-0}" = "1" ] && registry="(${registry}|localhost:${REGISTRY_PORT})"
  k -n "$NS_STAGING" wait --for=condition=Ready "isvc/${ISVC}" --timeout=20s &&
    k -n "$NS_STAGING" get isvc "$ISVC" -o jsonpath='{.spec.predictor.containers[0].image}' |
    grep -E "^${registry}/scoring-api:"
}
served_prod_ok() { # la nouvelle révision (route latest-) sert le tag de Git
  local tag
  tag=$(git show "${REF}:k8s/overlays/prod/kustomization.yaml" |
    sed -nE 's/^ *newTag: *"?([^"]*)"?.*/\1/p')
  t 70 curl -fsS --max-time 60 -H "Host: latest-${ISVC}-predictor.${NS_PROD}.example.com" \
    "${GATEWAY}/version" | tee /dev/stderr | grep -Eq "\"version\": ?\"${tag}\""
}

# --- CT -----------------------------------------------------------------------------
webhook_ok() { t 10 curl -fsS "http://localhost:${CT_WEBHOOK_PORT}/health" | grep -q '"ok"'; }
retrain_ok() { # run MLflow lancé par le CT -> $TMP/ct.json (kfp_run_id, version, …)
  py - "$TMP/ct.json" <<'EOF'
import json
import sys

from mlflow import MlflowClient

c = MlflowClient()
exp = c.get_experiment_by_name("scoring")
runs = c.search_runs(
    [exp.experiment_id],
    "tags.launched_by = 'kfp' and tags.ct_trigger != 'manual' and attributes.status = 'FINISHED'",
    order_by=["attributes.start_time DESC"],
)
runs = [r for r in runs if r.data.tags.get("ct_trigger")]
assert runs, "aucun run MLflow avec le tag ct_trigger (ré-entraînement déclenché)"
drift = c.get_experiment_by_name("scoring-drift")
assert drift and c.search_runs([drift.experiment_id], max_results=1), "aucun rapport de dérive"
r = runs[0]
print(f"run {r.info.run_name} ct_trigger={r.data.tags['ct_trigger']} "
      f"kfp_run_id={r.data.tags.get('kfp_run_id')}")
json.dump({"kfp_run_ids": [x.data.tags.get("kfp_run_id") for x in runs]}, open(sys.argv[1], "w"))
EOF
}
kfp_run_ok() { # au moins un de ces runs KFP (ct-pipeline) a réussi
  [ -s "$TMP/ct.json" ] || return 1
  py - "$KFP_HOST" "$TMP/ct.json" <<'EOF'
import json
import sys

import kfp

client = kfp.Client(host=sys.argv[1])
states = {}
for run_id in json.load(open(sys.argv[2]))["kfp_run_ids"][:20]:
    try:
        states[run_id] = str(client.get_run(run_id).state)
    except Exception as exc:  # run supprimé de KFP
        states[run_id] = type(exc).__name__
print(states)
assert "SUCCEEDED" in states.values(), "aucun run ct-pipeline réussi dans KFP"
EOF
}
promotion_ok() { # @champion promu par la gate du CT, servi par la révision qui a le trafic
  git show "${REF}:k8s/overlays/prod/canary.yaml" >"$TMP/canary.yaml" || return 1
  py - "$TMP/canary.yaml" <<'EOF'
import json
import os
import sys
import urllib.request

import yaml
from mlflow import MlflowClient

mv = MlflowClient().get_model_version_by_alias("scoring-model", "champion")
tags = mv.tags
assert tags.get("promotion") == "passed" and tags.get("ct_trigger"), (
    f"@champion v{mv.version} n'est pas issu d'une promotion du CT ({tags.get('promotion')})"
)
# canary à 0 % (retour arrière) : c'est la révision précédente qui sert le trafic
canary = yaml.safe_load(open(sys.argv[1]))["spec"]["predictor"]["canaryTrafficPercent"]
route = "prev-" if canary == 0 else "latest-"
host = f"{route}scoring-model-predictor.{os.environ['NS_PROD']}.example.com"
req = urllib.request.Request(f"{os.environ['GATEWAY']}/version", headers={"Host": host})
served = json.load(urllib.request.urlopen(req, timeout=60))
print(f"@champion v{mv.version} (avant : v{tags.get('previous_champion')}), {route} : {served}")
assert served["model_version"] == mv.version, "la prod ne sert pas le @champion"
EOF
}
git_history_ok() {
  local staging model prod
  staging=$(git log "$REF" --format='%an|%s' -- k8s/overlays/staging | grep -c 'gitops(staging)')
  model=$(git log "$REF" --format='%s' -- packaging/model | grep -c '^ct: ')
  prod=$(git log "$REF" --format='%s' -- k8s/overlays/prod | grep -c 'gitops(prod)')
  echo "commits staging=${staging} modèle(CT)=${model} prod=${prod}"
  [ "$staging" -ge 1 ] && [ "$model" -ge 1 ] && [ "$prod" -ge 2 ]
}
no_hardcoded_columns() {
  py - <<'EOF'
import re
from pathlib import Path

from src.dataset_config import load_config

cfg = load_config()
names = set(cfg.features) | {cfg.target, str(cfg.positive_class)}
files = ["pipelines/ct_pipeline.py", "pipelines/trigger_ct.py", "pipelines/gitops.py",
         *map(str, Path("tests").glob("test_*.py")), "labs/m6-cicd/check.sh"]
found = {f: sorted(n for n in names if re.search(rf"[\"']{re.escape(n)}[\"']",
                                                  Path(f).read_text(encoding="utf-8")))
         for f in files if Path(f).exists() and f != "tests/test_dataset_config.py"}
found = {f: n for f, n in found.items() if n}
assert not found, f"noms de colonnes en dur : {found}"
EOF
}
no_secret_ok() {
  [ -n "${CT_WEBHOOK_TOKEN:-}" ] || {
    echo "CT_WEBHOOK_TOKEN absent de .env"
    return 1
  }
  ! git grep -q -F "$CT_WEBHOOK_TOKEN" "$REF" -- . ':!*.lock'
}
report_ok() {
  [ -s reports/rapport-m6.md ] && [ "$(grep -c '^## ' reports/rapport-m6.md)" -ge 5 ] &&
    ! grep -q 'TODO' reports/rapport-m6.md
}
files_ok() {
  local f
  for f in .github/workflows/ci.yml k8s/base/isvc.yaml k8s/base/kustomization.yaml \
    k8s/overlays/staging/kustomization.yaml k8s/overlays/prod/kustomization.yaml \
    k8s/overlays/prod/canary.yaml k8s/argocd-app.yaml pipelines/ct_pipeline.py \
    pipelines/trigger_ct.py pipelines/gitops.py tests/conftest.py tests/test_serve.py \
    tests/test_k8s.py tests/test_ct.py packaging/model/model.onnx; do
    [ -s "$f" ] || {
      echo "manquant : $f"
      return 1
    }
  done
}

# --- Vérifications --------------------------------------------------------------------
echo "Lab 6 — CI/CD/CT (Git : ${REF} = $(git rev-parse --short "$REF"), prod : ${NS_PROD})"
check "Fichiers du lab (workflow, k8s/, pipelines CT, tests, modèle versionné)" \
  "étapes 1, 2, 4 et 7" files_ok
check ".github/workflows/ci.yml valide (schéma GitHub Actions, lint/tests/build/deploy)" \
  "étape 2 ; uvx check-jsonschema --builtin-schema vendor.github-workflows …" ci_schema_ok
if command -v gh >/dev/null 2>&1 && t 15 gh auth status >/dev/null 2>&1; then
  check "Dernier run de la CI sur main : success (gh run list)" \
    "onglet Actions de votre fork ; gh run view --log-failed" ci_run_ok
else
  skip "Dernier run de la CI sur main" "gh absent ou non authentifié (gh auth login)"
fi
check "Lint + tests locaux (ruff, pytest)" "uv run pytest -q (étape 1)" tests_ok
check "Overlays Kustomize staging et prod construits" "kubectl kustomize k8s/overlays/prod" \
  kustomize_ok
check "Argo CD installé et prêt (namespace argocd)" "make argocd (étape 3)" argocd_ok
check "Applications scoring-staging et scoring-prod : Synced + Healthy, auto-sync + selfHeal" \
  "kubectl apply -f k8s/argocd-app.yaml (étape 4) ; kubectl get applications -n argocd" apps_ok
check "Staging : InferenceService prêt, image construite par la CI (ghcr.io)" \
  "CI verte + package GHCR public ou imagePullSecret (étapes 2 et 4)" staging_ok
check "Prod : InferenceService géré par Argo CD, image et canary = origin/main" \
  "git push ; Argo CD synchronise en ≤ 1 min (étapes 4, 5 et 8)" isvc_gitops_ok
check "Prod : la nouvelle révision sert le tag de Git (route latest-, /version)" \
  "étape 8 ; kubectl get isvc ${ISVC} -n ${NS_PROD}" served_prod_ok
check "Webhook CT joignable (localhost:${CT_WEBHOOK_PORT}/health)" \
  "uv run python -m pipelines.trigger_ct serve (étape 6)" webhook_ok
check "Ré-entraînement déclenché : run MLflow tagué ct_trigger + rapport de dérive" \
  "uv run python -m pipelines.trigger_ct detect (étape 7)" retrain_ok
if ! t 10 curl -fsS "${KFP_HOST}/apis/v2beta1/healthz" >/dev/null 2>&1; then
  kubectl --context "$KCTX" -n kubeflow port-forward svc/ml-pipeline-ui \
    "${CHECK_KFP_PORT}:80" >/dev/null 2>&1 &
  PF_PID=$!
  sleep 3
  KFP_HOST="http://localhost:${CHECK_KFP_PORT}"
fi
check "KFP : le run ct-pipeline de ce ré-entraînement a réussi" \
  "UI KFP, expérience scoring-ct (étape 7)" kfp_run_ok
check "Promotion : @champion issu de la gate du CT et servi en prod" \
  "étapes 7 et 9 ; journal du webhook" promotion_ok
check "Historique GitOps : commits CI (staging), bot CT (modèle) et prod (canary)" \
  "git log --oneline origin/main -- k8s packaging/model" git_history_ok
check "Aucun nom de colonne en dur dans le code du lab (dataset.yaml)" \
  "lire les colonnes via src.dataset_config" no_hardcoded_columns
check "CT_WEBHOOK_TOKEN dans .env et absent de Git" \
  "étape 6.2 : le jeton vit dans .env (ignoré par Git)" no_secret_ok
check "Rapport reports/rapport-m6.md : 5 sections, sans TODO" \
  "starter/rapport-m6.md (étape 9)" report_ok

echo
SUMMARY="Résultat : $((TOTAL - FAILS))/${TOTAL} vérifications OK"
[ "$SKIPS" -eq 0 ] || SUMMARY="${SUMMARY} (${SKIPS} SKIP)"
echo "$SUMMARY"
exit "$FAILS"
