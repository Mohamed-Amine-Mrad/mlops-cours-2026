#!/usr/bin/env bash
# shellcheck disable=SC2329  # fonctions de test appelées indirectement via check()
# =============================================================================
# Vérification automatique du Lab 4 — Packaging du modèle
# Lancer depuis la racine du repo :  make check-m4
# Pré-requis : Docker démarré, registry local (make cluster) et image poussée (étape 8).
# Variables optionnelles : IMAGE (défaut localhost:5001/scoring-api), TAG (défaut 1.0.0),
#                          CHECK_PORT (port hôte du conteneur de test, défaut 18480).
# Code retour = nombre de vérifications en échec (0 = tout est vert).
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

# shellcheck disable=SC1091
source infra/versions.env
IMAGE=${IMAGE:-localhost:${REGISTRY_PORT}/scoring-api}
TAG=${TAG:-1.0.0}
CHECK_PORT=${CHECK_PORT:-18480}
export CHECK_PORT
REPO_NAME=${IMAGE#*/} # scoring-api
CONTAINER=m4-check-$$
MAX_MB=500
FAILS=0
TOTAL=0

t() {
  local secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else "$@"; fi
}
py() { t 60 uv run --no-sync python "$@"; }

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

# --- Fonctions de test --------------------------------------------------------
onnx_ok() {
  [ -s packaging/model/model.onnx ] && [ -s packaging/model/metadata.json ]
}
registry_tag() {
  t 10 curl -fsS "http://localhost:${REGISTRY_PORT}/v2/${REPO_NAME}/tags/list" |
    grep -q "\"${TAG}\""
}
image_local() {
  docker image inspect "${IMAGE}:${TAG}" >/dev/null 2>&1 ||
    t 180 docker pull -q "${IMAGE}:${TAG}"
}
image_size() {
  local bytes
  bytes=$(docker image inspect -f '{{.Size}}' "${IMAGE}:${TAG}") || return 1
  [ "$bytes" -lt $((MAX_MB * 1000000)) ]
}
non_root() {
  local user
  user=$(docker image inspect -f '{{.Config.User}}' "${IMAGE}:${TAG}") || return 1
  [ -n "$user" ] && [ "${user%%:*}" != "root" ] && [ "${user%%:*}" != "0" ]
}
has_healthcheck() {
  docker image inspect -f '{{json .Config.Healthcheck}}' "${IMAGE}:${TAG}" |
    grep -q '"Test"'
}
container_up() {
  cleanup
  docker run -d --name "$CONTAINER" -p "127.0.0.1:${CHECK_PORT}:8000" "${IMAGE}:${TAG}" &&
    for _ in $(seq 1 30); do
      curl -fsS "http://localhost:${CHECK_PORT}/health" | grep -q '"ok"' && return 0
      sleep 1
    done
  return 1
}
container_healthy() {
  for _ in $(seq 1 20); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER")" = "healthy" ] && return 0
    sleep 1
  done
  return 1
}
# /predict sur une vraie ligne de data/processed/test.csv (colonnes lues dans dataset.yaml),
# puis requête invalide (colonne manquante) qui doit être refusée en 422.
predict_ok() {
  py - <<'EOF'
import json
import os
import urllib.error
import urllib.request

import pandas as pd

from src.dataset_config import load_config

cfg = load_config()
url = f"http://localhost:{os.environ['CHECK_PORT']}"
row = pd.read_csv("data/processed/test.csv")[cfg.features].head(1)
row = row.astype(object).where(row.notna(), None).to_dict("records")[0]


def post(body):
    req = urllib.request.Request(
        f"{url}/predict", json.dumps(body).encode(), {"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, None


status, out = post({"instances": [row]})
assert status == 200, status
pred = out["predictions"][0]
assert 0.0 <= pred["probability"] <= 1.0 and pred["prediction"] in (0, 1), out
assert out["positive_class"] == str(cfg.positive_class), out
incomplete = {k: v for k, v in row.items() if k != cfg.features[0]}
assert post({"instances": [incomplete]})[0] == 422
with urllib.request.urlopen(f"{url}/metadata", timeout=10) as r:
    assert json.load(r)["dataset"] == cfg.name
print(f"probability={pred['probability']:.3f} prediction={pred['prediction']}")
EOF
}
benchmark_ok() {
  [ -s reports/benchmark.md ] &&
    [ "$(grep -cE '^\| (sklearn|onnx)' reports/benchmark.md)" -ge 3 ]
}
trivy_ok() { [ -s reports/trivy_optimized.txt ] && [ -s reports/trivy_naive.txt ]; }
modelscan_onnx_ok() { grep -q "No issues found" reports/modelscan_onnx.txt; }
modelscan_pickle_ok() { grep -qE "CRITICAL: [1-9]" reports/modelscan_pickle.txt; }
bento_ok() { docker image inspect scoring-api:bentoml >/dev/null 2>&1; }
naive_ok() { docker image inspect scoring-api:naive >/dev/null 2>&1; }
report_ok() {
  [ -s reports/rapport-m4.md ] && [ "$(grep -c '^## ' reports/rapport-m4.md)" -ge 5 ]
}

# --- Vérifications --------------------------------------------------------------
echo "Lab 4 — Packaging du modèle (${IMAGE}:${TAG})"
check "Modèle ONNX exporté (packaging/model/)" \
  "uv run python packaging/app/export_onnx.py (étape 1)" onnx_ok
check "Image ${TAG} présente dans le registry local" \
  "docker push ${IMAGE}:${TAG} (étape 8) ; registry lancé par make cluster ?" registry_tag
check "Image récupérable (docker pull)" "docker pull ${IMAGE}:${TAG}" image_local
check "Taille de l'image < ${MAX_MB} Mo" "multi-stage + python:3.12-slim (étape 4)" image_size
SIZE=$(docker image inspect -f '{{.Size}}' "${IMAGE}:${TAG}" 2>/dev/null || echo 0)
echo "   ↳ taille mesurée : $((SIZE / 1000000)) Mo"
check "Utilisateur non-root" "USER 10001:10001 dans packaging/Dockerfile" non_root
check "HEALTHCHECK déclaré" "instruction HEALTHCHECK (étape 4.2)" has_healthcheck
check "Conteneur démarré, /health répond" \
  "docker run --rm ${IMAGE}:${TAG} pour voir les logs ; port ${CHECK_PORT} libre ?" container_up
check "Conteneur healthy (docker inspect)" "voir HEALTHCHECK et /health" container_healthy
check "/predict sur une ligne de test.csv + 422 si colonne manquante" \
  "uv run python packaging/sample_request.py | curl -d @- … (étape 2.2)" predict_ok
check "Rapport de benchmark (3 backends)" \
  "uv run python packaging/app/benchmark.py (étape 5)" benchmark_ok
check "Rapports Trivy (naive + optimized)" "étape 7.1" trivy_ok
check "ModelScan : ONNX sans problème" "étape 7.2" modelscan_onnx_ok
check "ModelScan : pickle piégé détecté" \
  "uv run python packaging/scan-demo/make_pickles.py puis modelscan (étape 7.2)" \
  modelscan_pickle_ok
check "Image naïve construite (scoring-api:naive)" "étape 3" naive_ok
check "Image BentoML construite (scoring-api:bentoml)" "bentoml containerize (étape 6)" bento_ok
check "Rapport rédigé (reports/rapport-m4.md, 5 sections)" "étape 9" report_ok

echo
echo "Résultat : $((TOTAL - FAILS))/${TOTAL} vérifications OK"
exit "$FAILS"
