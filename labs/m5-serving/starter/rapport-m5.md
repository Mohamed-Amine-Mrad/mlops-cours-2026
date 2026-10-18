# Rapport — Lab 5 : serving avec KServe

Binôme : TODO · Dataset : TODO (`name` de dataset.yaml) · Modèle : `scoring-model` v TODO ·
Seuil de décision servi : TODO

## 1. Résumé

TODO (2-3 phrases) : l'architecture déployée — InferenceService `scoring-model` (mode, image,
passerelle), autoscaling, version en production à la fin du lab.

## 2. Benchmark de latence

Coller la sortie de `uv run python serving/locust_report.py` (requêtes `/predict` seulement).

| Run | Requêtes | RPS | P50 (ms) | P95 (ms) | P99 (ms) | Erreurs (%) |
|---|---|---|---|---|---|---|
| run_100 | TODO | TODO | TODO | TODO | TODO | TODO |
| run_500 | TODO | TODO | TODO | TODO | TODO | TODO |
| run_1000 | TODO | TODO | TODO | TODO | TODO | TODO |

Point de saturation : TODO (à partir de quelle charge le P99 décroche-t-il ? RPS max ?)

## 3. Scale-up observé

| Run | Pods (max observé) | CPU moyen par pod | Temps pour atteindre ce nombre de pods |
|---|---|---|---|
| run_100 | TODO | TODO | TODO s |
| run_500 | TODO | TODO | TODO s |
| run_1000 | TODO | TODO | TODO s |

Scale-to-zero : délai observé avant 0 pod : TODO s · démarrage à froid (`curl -w`) : TODO s.

## 4. Analyse canary

- Répartition observée sur 200 requêtes : TODO × 1.0.0 / TODO × 2.0.0.
- Le split est-il cohérent avec 90/10 ? (TODO : écart à la valeur attendue, variance)
- Décision (promotion ou rollback) et justification : TODO

## 5. Points d'amélioration

- TODO (cible de l'autoscaler, métrique de scaling, maxReplicas, ressources, batching…)

## 6. (Optionnel) Comparatif des serveurs et bonus batch

| Serveur | Protocole | P50 (ms) | P95 (ms) | P99 (ms) | Image | Mémoire du pod |
|---|---|---|---|---|---|---|
| FastAPI + ONNX Runtime (`scoring-model`) | V1 `/predict` | TODO | TODO | TODO | TODO | TODO |
| BentoML + scikit-learn (`scoring-bento`) | V1 `/predict` | TODO | TODO | TODO | TODO | TODO |
| Triton + ONNX Runtime (`scoring-triton`) | V2 | TODO | TODO | TODO | TODO | TODO |

Bonus batch (`BATCH_SIZE=50`) : TODO requêtes/s × 50 = TODO prédictions/s (contre TODO en
unitaire).
