# Rapport — Lab 4 : packaging du modèle

Binôme : TODO · Dataset : TODO (`name` de dataset.yaml) · Modèle : `scoring-model` v TODO

## 1. Comparatif des tailles

| Image | Taille | CVE HIGH + CRITICAL |
|---|---|---|
| `scoring-api:naive` | TODO | TODO |
| `scoring-api:optimized` | TODO | TODO |
| `scoring-api:bentoml` | TODO | TODO |

## 2. Comparatif des latences

Recopier le tableau de `reports/benchmark.md` (machine, nombre d'appels).

| Backend | P50 (ms) | P95 (ms) | P99 (ms) |
|---|---|---|---|
| sklearn_pipeline | TODO | TODO | TODO |
| onnx_python | TODO | TODO | TODO |
| onnx_batch_100 | TODO | TODO | TODO |

## 3. Interprétation

- Pourquoi l'image optimisée est-elle plus petite ? (TODO : base, multi-stage, dépendances)
- Pourquoi ONNX est-il plus rapide que scikit-learn ? (TODO)
- Que montrent les scans Trivy et ModelScan ? (TODO)

## 4. Choix recommandé

TODO : quelle image retenir en production pour ce cas d'usage, et pourquoi ?

## 5. Pistes d'amélioration

- TODO (quantization INT8, image distroless, …)
