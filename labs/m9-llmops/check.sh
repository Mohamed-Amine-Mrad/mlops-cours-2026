#!/usr/bin/env bash
# Vérification de fin de Lab 9 (make check-m9) — à lancer depuis la racine du fork.
# Services attendus sur le poste : Ollama (ou vLLM), Qdrant, Phoenix et l'API RAG (rag/api.py).
# Tout est paramétrable par variables d'environnement (mêmes noms que rag/config.py).
set -uo pipefail

LLM_BACKEND="${LLM_BACKEND:-ollama}"
LLM_MODEL="${LLM_MODEL:-qwen3.5:4b}"
OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://localhost:11434}"
VLLM_BASE_URL="${VLLM_BASE_URL:-http://localhost:8000/v1}"
QDRANT_URL="${QDRANT_URL:-http://localhost:6333}"
COLLECTION="${QDRANT_COLLECTION:-mlops_course}"
PHOENIX_URL="${PHOENIX_COLLECTOR_ENDPOINT:-http://localhost:6006}"
PHOENIX_PROJECT="${PHOENIX_PROJECT_NAME:-rag-mlops}"
RAG_API_URL="${RAG_API_URL:-http://localhost:8090}"
MIN_DOCS="${M9_MIN_DOCS:-5}"
MIN_QUESTIONS="${M9_MIN_QUESTIONS:-20}"
MIN_RAGAS_ROWS="${M9_MIN_RAGAS_ROWS:-5}"
MIN_FAITHFULNESS="${M9_MIN_FAITHFULNESS:-0.7}"
RAG=rag
REPORTS=$RAG/reports

PASS=0
FAIL=0
ok() { echo "✅ $1"; PASS=$((PASS + 1)); }
ko() { echo "❌ $1${2:+ — $2}"; FAIL=$((FAIL + 1)); }
check() { # check "libellé" "indice si échec" commande...
  local label=$1 hint=$2; shift 2
  if "$@" >/dev/null 2>&1; then ok "$label"; else ko "$label" "$hint"; fi
}
py() { python3 -c "$@"; }

echo "== Lab 9 — RAG MLOps évalué et observé =="
[ -d "$RAG" ] || echo "⚠️  Dossier $RAG/ introuvable : lancez ce script depuis la racine du fork."

# 1. LLM servi (Ollama ou vLLM) + modèle disponible
if [ "$LLM_BACKEND" = "vllm" ]; then
  check "1. LLM servi par vLLM ($VLLM_BASE_URL)" "étape 1.2 (vllm serve)" \
    bash -c "curl -sf -m 5 '$VLLM_BASE_URL/models' | grep -q '\"id\"'"
else
  check "1a. Ollama répond ($OLLAMA_BASE_URL)" "étape 1.1 (ollama serve)" \
    curl -sf -m 5 "$OLLAMA_BASE_URL/api/version"
  if curl -sf -m 5 "$OLLAMA_BASE_URL/api/tags" 2>/dev/null | py "
import json, sys
names = [m['name'] for m in json.load(sys.stdin)['models']]
want = '$LLM_MODEL'
sys.exit(0 if any(n == want or n == want + ':latest' for n in names) else 1)" 2>/dev/null; then
    ok "1b. Modèle $LLM_MODEL présent dans Ollama"
  else
    ko "1b. Modèle $LLM_MODEL présent dans Ollama" "ollama pull $LLM_MODEL (ou exportez LLM_MODEL)"
  fi
fi

# 2. Qdrant up
check "2. Qdrant répond ($QDRANT_URL)" "étape 2 (docker start qdrant)" \
  bash -c "curl -sf -m 5 '$QDRANT_URL/' | grep -q '\"version\"'"

# 3. Ingestion : collection non vide
POINTS=$(curl -sf -m 10 "$QDRANT_URL/collections/$COLLECTION" 2>/dev/null \
  | py "import json, sys; print(json.load(sys.stdin)['result']['points_count'] or 0)" 2>/dev/null)
if [ "${POINTS:-0}" -gt 0 ] 2>/dev/null; then
  ok "3. Collection $COLLECTION indexée ($POINTS chunks)"
else
  ko "3. Collection $COLLECTION indexée" "introuvable ou vide : étape 3 (python ingest.py)"
fi

# 4. Nombre de documents distincts dans l'index
NDOCS=$(curl -sf -m 30 -X POST "$QDRANT_URL/collections/$COLLECTION/points/scroll" \
  -H 'Content-Type: application/json' \
  -d '{"limit": 100000, "with_payload": ["metadata.source"], "with_vector": false}' 2>/dev/null \
  | py "import json, sys
pts = json.load(sys.stdin)['result']['points']
print(len({p['payload']['metadata']['source'] for p in pts}))" 2>/dev/null)
if [ "${NDOCS:-0}" -ge "$MIN_DOCS" ] 2>/dev/null; then
  ok "4. Documents indexés : $NDOCS (≥ $MIN_DOCS)"
else
  ko "4. Documents indexés : ${NDOCS:-0} (≥ $MIN_DOCS attendus)" "étape 3.1 (PDF dans rag/docs/)"
fi

# 5. API RAG : /health puis une vraie question (réponse + sources)
check "5a. API RAG /health ($RAG_API_URL)" "étape 7.2 (uvicorn api:app --port 8090)" \
  curl -sf -m 10 "$RAG_API_URL/health"
ASK=$(curl -sf -m 300 -X POST "$RAG_API_URL/ask" -H 'Content-Type: application/json' \
  -d '{"question": "Quels sont les 4 signaux d or de Google SRE ?"}' 2>/dev/null)
if echo "$ASK" | py "import json, sys
r = json.load(sys.stdin)
assert r['answer'] and not r['blocked'] and r['sources']" 2>/dev/null; then
  ok "5b. API RAG /ask : réponse + sources"
else
  ko "5b. API RAG /ask : réponse + sources" "réponse vide, bloquée ou sans source"
fi

# 6. Golden set
NQ=$(py "import json
g = json.load(open('$RAG/golden_set.json', encoding='utf-8'))
assert all(i['question'] and i['ground_truth'] for i in g)
print(len(g))" 2>/dev/null)
if [ "${NQ:-0}" -ge "$MIN_QUESTIONS" ] 2>/dev/null; then
  ok "6. Golden set : $NQ questions (≥ $MIN_QUESTIONS)"
else
  ko "6. Golden set : ${NQ:-absent ou invalide} (≥ $MIN_QUESTIONS questions)" "étape 5"
fi

# 7-8. Rapport Ragas : lignes, 4 métriques, faithfulness moyenne
RAGAS=$(py "
import csv, math
rows = list(csv.DictReader(open('$REPORTS/ragas_results.csv', encoding='utf-8')))
cols = ['faithfulness', 'answer_relevancy', 'context_precision', 'context_recall']
assert rows and all(c in rows[0] for c in cols)
vals = []
for r in rows:
    try:
        v = float(r['faithfulness'])
    except ValueError:
        continue
    if not math.isnan(v):
        vals.append(v)
print(len(rows), round(sum(vals) / len(vals), 3) if vals else 0)" 2>/dev/null)
NROWS=${RAGAS% *}
FAITH=${RAGAS#* }
if [ -n "$RAGAS" ] && [ "$NROWS" -ge "$MIN_RAGAS_ROWS" ]; then
  ok "7. Ragas exécuté : $NROWS questions évaluées, 4 métriques"
else
  ko "7. Ragas exécuté ($REPORTS/ragas_results.csv : ${NROWS:-absent})" "étape 6"
fi
if [ -n "$RAGAS" ] && py "import sys; sys.exit(0 if $FAITH > $MIN_FAITHFULNESS else 1)"; then
  ok "8. Faithfulness moyenne $FAITH > $MIN_FAITHFULNESS"
else
  ko "8. Faithfulness moyenne ${FAITH:-?} > $MIN_FAITHFULNESS" "voir l'analyse de l'étape 6"
fi

# 9-10. Phoenix : UI + traces complètes (chaîne, retriever, LLM) dans le projet
check "9. Phoenix UI ($PHOENIX_URL)" "étape 7 (phoenix serve)" curl -sf -m 5 "$PHOENIX_URL/"
if curl -sf -m 30 "$PHOENIX_URL/v1/projects/$PHOENIX_PROJECT/spans?limit=1000" 2>/dev/null \
  | py "import json, sys
kinds = {s['span_kind'] for s in json.load(sys.stdin)['data']}
assert {'RETRIEVER', 'LLM', 'CHAIN'} <= kinds" 2>/dev/null; then
  ok "10. Traces Phoenix complètes (CHAIN + RETRIEVER + LLM, projet $PHOENIX_PROJECT)"
else
  ko "10. Traces Phoenix complètes (projet $PHOENIX_PROJECT)" "relancer avec PHOENIX_TRACING=1"
fi

# 11. Tokens comptés : phoenix_stats.json + métrique Prometheus de l'API
check "11a. Tokens comptés depuis Phoenix ($REPORTS/phoenix_stats.json)" "étape 7.1" \
  py "import json; s = json.load(open('$REPORTS/phoenix_stats.json')); assert s['tokens_in'] > 0"
check "11b. API /metrics expose rag_llm_tokens_total" "étape 7.2" \
  bash -c "curl -sf -m 10 '$RAG_API_URL/metrics' | grep -q '^rag_llm_tokens_total'"

# 12-13. Prompt injection avant / après guardrail
check "12. injection_before.log : 4 attaques testées" "étape 8.1" \
  bash -c "[ \$(grep -c '^--- Attack' '$REPORTS/injection_before.log') -eq 4 ]"
check "13. injection_after.log : 3 attaques bloquées, requête légitime passée" "étape 8.2" \
  bash -c "[ \$(grep -c '^--- ' '$REPORTS/injection_after.log') -eq 5 ] \
    && [ \$(grep -c '\[BLOCKED\]' '$REPORTS/injection_after.log') -ge 3 ] \
    && ! grep '^Response:' '$REPORTS/injection_after.log' | tail -1 | grep -q BLOCKED"

# 14. Rapport final
check "14. RAPPORT.md avec 9 sections" "étape 9" \
  bash -c "[ \$(grep -c '^## ' '$RAG/RAPPORT.md') -ge 9 ]"

echo
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "🎉 $PASS/$TOTAL vérifications OK — Lab 9 validé."
else
  echo "Lab 9 : $FAIL vérification(s) en échec sur $TOTAL."
fi
exit "$FAIL"
