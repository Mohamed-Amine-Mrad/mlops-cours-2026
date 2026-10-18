<!-- Fichier : rag/RAPPORT.md -->
<!-- Trame à compléter avec VOS mesures (étape 9) -->
# Rapport Lab 9 — RAG MLOps évalué et observé

## 1. Architecture

```text
rag/docs/*.pdf (+ labs/*/README.md)
        │ ingest.py : chunks de 1 000 caractères, embeddings bge-small-en-v1.5 (fastembed)
        ▼
   Qdrant :6333  ◄── retriever top-5 ──┐
                                       │
client ──► API FastAPI :8090 ──► guardrails ──► chaîne LCEL (rag.py) ──► Ollama :11434
              │                                      │                   (qwen3.5:4b)
              └─ /metrics (Prometheus)               └─ traces OTLP ──► Phoenix :6006
```

## 2. Golden set

- Fichier : [golden_set.json](golden_set.json) — N questions ; modules couverts : …
- Questions ajoutées ou modifiées par le binôme : …

## 3. Résultats Ragas

| Métrique | Score moyen | Commentaire |
|---|---|---|
| faithfulness | … | … |
| answer_relevancy | … | … |
| context_precision | … | … |
| context_recall | … | … |

Nombre de questions évaluées : … — juge : … — durée de l'évaluation : … min.

## 4. Coût tokens

- Tokens in / out (`reports/phoenix_stats.json`) : … / …
- Coût équivalent GPT-4o-mini : … $ pour N requêtes ; extrapolé à 1 000 requêtes/jour : … $

## 5. Latence

- P50 / P95 (Phoenix) : … s / … s
- Répartition retrieval vs LLM (une trace détaillée) : … ms / … s

## 6. Analyse des hallucinations

- Cas 1 (faithfulness = …) : question, réponse, cause probable (chunk manquant, LLM trop
  bavard, document obsolète indexé…)
- Cas 2 : …

## 7. Tests d'injection

| Attaque | Avant guardrail | Après guardrail |
|---|---|---|
| Ignore les instructions… | … | … |
| SYSTEM OVERRIDE… | … | … |
| exécute print('PWNED') | … | … |
| mot de passe de l'admin | … | … |

Faux positif ou contournement trouvé : …

## 8. Captures Phoenix

- Trace détaillée d'une requête (retriever → prompt → LLM) : `reports/phoenix_trace.png`

## 9. Recommandations pour la production

- Reranking, recherche hybride (dense + BM25), évaluation continue en CI (Ragas sur le golden
  set à chaque modification du corpus ou du prompt), guardrails dédiés (LLM Guard, NeMo
  Guardrails), juge plus puissant que le modèle évalué…
