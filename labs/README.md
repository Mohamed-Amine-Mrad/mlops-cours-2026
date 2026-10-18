# Labs du cours MLOps — sommaire

Chaque lab ajoute une brique au **même repo** : le vôtre. À la fin du Lab 8, ce repo est le
**socle** de votre mini-projet. Le cas d'usage par défaut est le credit scoring
(`dataset.yaml`) ; un binôme peut le remplacer par son propre dataset, validé avant le Lab 1.

| Lab | Énoncé | Durée de l'énoncé | Ce que le lab ajoute au repo | Vérification |
|---|---|---|---|---|
| 0 | [Setup de l'environnement](m0-setup/README.md) | 1 h + 1 h de préparation | cluster kind, registry, SeaweedFS (S3), MLflow | `make check-m0` |
| 1 | [Versionner un projet ML](m1-versioning/README.md) | 2 h | `dataset.yaml` exploité, DVC, 20+ runs MLflow, `@champion`, Feast | `make check-m1` |
| 2 | [Pipeline Kubeflow + Airflow](m2-pipelines/README.md) | 3 h | image du pipeline, `scoring-pipeline` KFP, DAG Airflow | `make check-m2` |
| 3 | [Validation données & modèle](m3-validation/README.md) | 2 h | Great Expectations, drift, tests de modèle, gates bloquantes | `make check-m3` |
| 4 | [Packaging du modèle](m4-packaging/README.md) | 2 h | API générée depuis `dataset.yaml`, ONNX, image < 500 Mo, scans | `make check-m4` |
| 5 | [Serving avec KServe](m5-serving/README.md) | 3 h | InferenceService, autoscaling, tests de charge, canary | `make check-m5` |
| 6 | [CI/CD/CT](m6-cicd/README.md) | 3 h | GitHub Actions, Argo CD, ré-entraînement déclenché par le drift | `make check-m6` |
| 7 | [Monitoring](m7-monitoring/README.md) | 3 h | Prometheus, Grafana, Loki, alertes, analyse du canary | `make check-m7` |
| 8 | [Gouvernance & Responsible AI](m8-governance/README.md) | 3 h | équité, SHAP, model card, image durcie, External Secrets | `make check-m8` |
| 9 | [LLMOps (RAG)](m9-llmops/README.md) | 2 h | projet `rag/` isolé : Qdrant, Ollama, Ragas, Phoenix | `make check-m9` |
| 10 | [Mini-projet](m10-capstone/README.md) | S1 → S12 | extension personnelle, livrables, soutenance | `make check-m10` |

Une partie des énoncés longs se termine en autonomie : le syllabus (`docs/syllabus.md`)
donne la répartition entre séance encadrée et travail personnel.

Les énoncés existent aussi en PDF (générés depuis ces Markdown : `make pdf`, ou dans les
*Releases* du repo du cours). Le Markdown fait foi.

**Conventions des énoncés** : les commandes s'exécutent depuis la racine du repo ; un bloc de
code qui commence par `# Fichier : chemin` est le contenu exact de ce fichier (`make check-sync`
le vérifie) ; les « Sortie attendue » sont celles du credit scoring.
