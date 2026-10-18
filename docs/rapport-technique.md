# Rapport technique — plan à suivre

<!--
Ce fichier est le PLAN du rapport. Rédigez le rapport où vous voulez (ce fichier, LaTeX,
Typst, traitement de texte) mais rendez un PDF : docs/rapport.pdf, 10 pages maximum hors
page de garde et annexes, présent au tag `final` (48 h avant la soutenance).
Le jury lit le rapport AVANT la soutenance : il y cherche vos choix et vos chiffres, pas le
récit des labs (les énoncés existent déjà). Les pages indiquées sont des ordres de grandeur.
-->

**Page de garde :** titre du projet, dataset, noms et pseudos GitHub des deux membres,
extension de chacun, lien du repo, hash du commit du tag `final`.

## 1. Résumé exécutif (½ page)

Le problème, la solution, trois chiffres clés (ex. ROC AUC et coût métier du champion, P95 de
latence, nombre de checks verts), ce que vous retenez. Un lecteur pressé doit tout comprendre
en trois minutes.

## 2. Cas d'usage et données (1 page)

Le contexte métier et pourquoi le ML est pertinent (alternative : règles métier ? baseline ?).
Le dataset en cinq lignes (renvoyer à `docs/dataset-card.md` pour le détail), la matrice de
coûts, les attributs sensibles. Si vous avez changé de dataset : pourquoi, et ce que
l'adaptation a demandé (`dataset.yaml`, `src/download.py`, points d'attention par lab).

## 3. Architecture du socle (1 page ½)

Un diagramme de bout en bout : données (DVC, S3) → pipeline (KFP ou Airflow, gates de
validation) → registre MLflow (`scoring-model@champion`) → image (`scoring-api`) → KServe →
monitoring (Prometheus, Grafana, Evidently) → CI/CD (GitHub Actions, Argo CD) → retour vers le
ré-entraînement. Pour chaque brique : ce qu'elle fait chez vous et le lien vers l'ADR qui
justifie un choix non imposé.

## 4. Modèle et validation (1 page)

Baseline vs modèle retenu ; métrique de promotion et seuil (`dataset.yaml` → `metrics`) ;
choix du seuil de décision au regard du coût métier ; résultats globaux **et** par sous-groupe ;
ce que bloquent les gates (données invalides, drift, performance). Toujours un chiffre avec
son contexte : « ROC AUC 0,80 (baseline 0,76, run MLflow `…`) », jamais « accuracy 0,89 ».

## 5. Mise en service et SLO (1 page)

InferenceService, ressources, autoscaling, stratégie canary ; benchmark (P50 / P95 / P99 à
plusieurs niveaux de charge) ; SLO retenus et respect mesuré ; taille et scan de l'image.

## 6. Exploitation : CI/CD, monitoring, incidents (1 page)

Ce qui se passe quand on pousse un commit, quand le modèle se dégrade, quand les données
dérivent. Dashboards (une capture lisible), alertes et runbook. Un incident réellement
rencontré pendant le projet et comment vous l'avez diagnostiqué.

## 7. Gouvernance (1 page)

Analyse d'équité (tableau par attribut sensible, conclusion honnête), explicabilité (deux cas
commentés), sécurité de la chaîne (scan d'image, scan du modèle, secrets), classification AI
Act et obligations correspondantes. Renvoyer à `model-card/model-card.md`.

## 8. Extension de [membre 1] — `ext/<nom>` (1 page)

Rédigée par le membre concerné. Objectif et niveau (★ à ★★★) ; architecture (ce qui s'ajoute
au socle) ; démonstration que ça marche (chiffre, capture, test) ; tests écrits ; ADR associé ;
limites et suite.

## 9. Extension de [membre 2] — `ext/<nom>` (1 page)

Même plan, rédigée par l'autre membre.

## 10. Compromis, difficultés, améliorations (1 page)

Les choix faits « faute de mieux » et ce qu'ils coûtent ; les problèmes rencontrés et comment
vous les avez contournés (souvent la partie la plus appréciée) ; ce que vous feriez avec plus
de temps ou pour une vraie production d'entreprise.

## Annexes (hors limite de pages)

Index des ADR, commandes de reproduction (`git clone`, `make up`, `uv sync`, `dvc repro`,
pipeline), sortie de `make check-m10` au tag `final`. Le jury n'est pas tenu de lire les annexes.
