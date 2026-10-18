---
module: 8
lab: 8
title: "Audit de gouvernance du modèle de scoring"
subtitle: "Sécurité, équité, explicabilité, conformité AI Act"
running_title: "Lab 8 — Audit gouvernance"
duree: "3 heures (atelier guidé)"
stack: "Trivy · ModelScan · Fairlearn · SHAP · Model Cards · External Secrets"
prerequis: "Labs 4 et 5 réussis : image scoring-api + InferenceService scoring-model"
livrable: "Rapport d'audit complet + Model Card + InferenceService sécurisé"
---

# Lab 8 — Audit de gouvernance du modèle de scoring

*Faire passer le modèle de scoring de crédit par une revue complète de gouvernance : scanner
l'image et le modèle, mesurer les disparités selon les attributs sensibles, appliquer et
chiffrer une atténuation, expliquer les refus avec SHAP, produire une Model Card auditable et
situer le tout dans l'AI Act européen et le RGPD.*

Le credit scoring rend ce lab central : décider qui obtient un crédit, c'est exactement le
genre de décision où un modèle peut discriminer (âge, sexe, nationalité), où la personne
concernée a droit à une explication, et que l'AI Act classe **à haut risque**. Un modèle qui
« marche » (ROC AUC 0,81, coût métier minimal) n'est pas pour autant déployable : ce lab
produit les preuves qu'un auditeur, un régulateur ou un client refusé pourraient demander.

## Objectifs

> [!NOTE]
> **À la fin du lab, vous aurez :**
>
> - Un rapport Trivy sur l'image `scoring-api` du Lab 4 et une **image durcie** (distroless,
>   Python 3.12, non-root) qui corrige l'essentiel des CVE.
> - Un rapport ModelScan comparant pickle (piégé), ONNX et skops.
> - Des métriques Fairlearn **pour chaque attribut sensible de `dataset.yaml`** (âge, statut
>   personnel, nationalité), au seuil de décision du modèle, avec leur diagnostic.
> - Une comparaison chiffrée de trois atténuations (retirer l'attribut, ThresholdOptimizer,
>   ExponentiatedGradient) : le compromis **coût métier / équité**.
> - Une importance globale SHAP et **trois explications locales** (« pourquoi cette demande
>   est-elle refusée ? »), avec un test contrefactuel sur les attributs sensibles.
> - Une Model Card complète et un rapport de conformité AI Act / RGPD sourcé.
> - Un RBAC minimal pour l'InferenceService + un ExternalSecret pour les identifiants S3.

## Plan du lab

| # | Étape | Durée |
|---|---|---|
| 1 | Scanner l'image scoring-api avec Trivy + corriger | 25 min |
| 2 | Scanner les modèles avec ModelScan (pickle vs ONNX) | 15 min |
| 3 | Fairlearn : mesurer les disparités | 25 min |
| 4 | Atténuer : retirer l'attribut, ThresholdOptimizer, ExponentiatedGradient | 25 min |
| 5 | SHAP : importance globale + 3 explications locales | 25 min |
| 6 | Générer la Model Card | 25 min |
| 7 | RBAC K8s minimal pour l'InferenceService | 15 min |
| 8 | ExternalSecret pour les identifiants S3 | 15 min |
| 9 | Rapport de conformité AI Act | 10 min |

> [!TIP]
> **Setup rapide**
> Aucune installation d'infra lourde cette fois : tout le lab se fait avec des scripts Python
> (`governance/`), Docker et kubectl. Seule brique ajoutée au cluster : External Secrets
> Operator (étape 8, `make external-secrets`, 2 minutes). Les étapes 7 et 8 réutilisent
> l'InferenceService `scoring-model` du Lab 5 (namespace `scoring`), géré par Argo CD depuis le
> Lab 6 : on le modifie par un commit, pas par `kubectl patch`. Fairlearn 0.14, SHAP 0.52
> et ModelScan 0.8.8 sont déjà dans l'environnement du cours (`uv sync`).

> [!WARNING]
> **Prérequis actifs**
> Docker démarré, cluster du Lab 0 actif (`kubectl get nodes`), port-forwards lancés
> (`make pf`) et `.env` chargé. Le Registry MLflow contient `scoring-model@champion` (Lab 1),
> l'image `localhost:5001/scoring-api:1.0.0` est dans le registry local (Lab 4) et
> l'InferenceService `scoring-model` tourne dans le namespace `scoring` (Lab 5), synchronisé
> par l'Application Argo CD `scoring-prod` (Lab 6). Pour l'image durcie (étape 1.3), il vous
> faut un **compte Docker gratuit** (Docker Hub).

> [!NOTE]
> **Vous travaillez sur votre propre dataset ?**
> Rien ne change dans le code : les scripts bouclent sur la section `sensitive` de **votre**
> `dataset.yaml` (un rapport par attribut, tranches définies par `bins`/`labels` pour un
> attribut numérique), lisent le seuil de décision de votre champion et le coût métier de
> votre `cost_matrix`. Les chiffres seront différents. Points d'attention : (1) déclarez dans
> `sensitive` tous les attributs protégés présents dans vos données (âge, sexe, origine,
> handicap…) — avec le socle actuel, ils doivent aussi figurer dans les features ;
> (2) `target.positive_class` doit rester la classe **défavorable** (le risque) : « prédire 1 »
> = refuser ; (3) un groupe de moins de 30 individus dans le jeu de test donne des taux
> inexploitables : regroupez les modalités rares dans `src/download.py` si besoin.

## Branche de travail

Comme chaque lab (convention du Lab 0, étape 8.1), celui-ci se fait sur sa propre branche,
créée depuis `main` à jour, et se termine par une pull request relue par le partenaire du
binôme :

```bash
cd ~/mlops-cours-2026
git switch main && git pull
git switch -c lab/m8-governance
```

## Convention de notation

Les blocs de code contiennent des commandes shell à exécuter telles quelles depuis la racine de
votre fork (`~/mlops-cours-2026`) : elles n'ont **pas** de préfixe `$`, vous pouvez les
copier-coller directement. Les lignes commençant par `#` sont des commentaires. Un bloc dont la
première ligne est `# Fichier : chemin` est le contenu **complet** de ce fichier. Les encadrés
« Sortie attendue » montrent le résultat attendu, avec les chiffres réels obtenus sur le
dataset par défaut (German Credit, champion `scoring-model` v3).

## Étape 1/9 — Scanner l'image scoring-api avec Trivy + corriger (25 min)

### 1.1 Préparation

```bash
cd ~/mlops-cours-2026
set -a && source .env && set +a
make pf
mkdir -p reports model-card governance k8s
uv run python -c "import fairlearn, shap; print(fairlearn.__version__, shap.__version__)"
```

> **Sortie attendue :** `0.14.0 0.52.0`.

Les scripts d'audit forment un petit paquet Python, `governance/`, lancé en module depuis la
racine (`python -m governance.…`), comme `src/` :

```python
# Fichier : governance/__init__.py
"""Audit de gouvernance du modèle champion (Lab 8) : équité, explicabilité."""
```

Trivy tourne dans un conteneur, à la version épinglée dans `infra/versions.env` (comme au
Lab 4) ; le volume `trivy-cache` garde la base de vulnérabilités entre deux scans :

```bash
trivy() {
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
    -v trivy-cache:/root/.cache/ aquasec/trivy:0.75.0 "$@"
}
```

> [!CAUTION]
> **Le scanner lui-même peut être compromis**
> En mars 2026, des identifiants volés ont permis de publier un binaire Trivy piégé (v0.69.4),
> des images Docker `aquasec/trivy` piégées (tags 0.69.5 et 0.69.6) et de déplacer 76 des 77
> tags de l'action GitHub `trivy-action` vers du code malveillant (CVE-2026-33634, voir
> [l'analyse d'Aqua Security](https://www.aquasec.com/blog/trivy-supply-chain-attack-what-you-need-to-know)).
> Leçon de gouvernance : un tag est **mutable**. On épingle une version postérieure à
> l'incident (0.75.0), et en CI on épingle par **empreinte** : l'image par son digest
> (`docker buildx imagetools inspect aquasec/trivy:0.75.0` donne le `sha256:…` à écrire
> `aquasec/trivy:0.75.0@sha256:…`), une action GitHub par le SHA complet de son commit.

### 1.2 Scan Trivy de l'image du Lab 4

```bash
docker pull localhost:5001/scoring-api:1.0.0
# Scan complet (toutes sévérités)
trivy image localhost:5001/scoring-api:1.0.0 > reports/trivy_full.txt
# Scan focalisé HIGH/CRITICAL
trivy image --severity HIGH,CRITICAL localhost:5001/scoring-api:1.0.0 \
  > reports/trivy_critical.txt
# Compter les CVE
grep "^Total" reports/trivy_full.txt reports/trivy_critical.txt
grep -c "CVE-" reports/trivy_critical.txt
# Celles qu'une mise à jour corrigerait aujourd'hui
trivy image --severity HIGH,CRITICAL --ignore-unfixed localhost:5001/scoring-api:1.0.0 \
  | grep "^Total"
```

> **Sortie attendue :** une ligne `Total: N (…)` par cible scannée : le système Debian de
> `python:3.12-slim`, puis les paquets Python de l'image. La plupart des CVE viennent des
> paquets Debian (glibc, systemd, perl, ncurses…), et beaucoup n'ont **pas de correctif**
> publié (`--ignore-unfixed` les masque) : un `apt-get upgrade` ne suffira pas. Les nombres
> exacts changent chaque semaine avec la base de vulnérabilités : notez-les pour le rapport.

### 1.3 Corriger via une base distroless

La réduction des CVE passe par une image de base plus minimale. Une image « distroless » ne
contient que le runtime : ni shell, ni gestionnaire de paquets, ni utilitaires. Moins de
paquets, moins de CVE, et un attaquant qui prendrait la main sur le conteneur n'aurait même
pas de `sh` à sa disposition.

L'énoncé d'origine utilisait `gcr.io/distroless/python3-debian12`. En 2026, ce n'est plus
possible : il faut une base qui embarque **le même Python que le projet (3.12)**, car les
dépendances de l'image (onnxruntime, numpy, pandas, pydantic-core…) sont des wheels compilées
pour un interpréteur précis (`cp312`).

| Base candidate (octobre 2026) | Python | Shell / apt | Accès | Verdict |
|---|---|---|---|---|
| `python:3.12-slim` (Lab 4) | 3.12 | oui / oui | libre | la référence à durcir |
| `gcr.io/distroless/python3-debian12` | 3.11 | non / non | libre | plus mise à jour par le projet distroless, mauvais Python |
| `gcr.io/distroless/python3-debian13` | 3.13 | non / non | libre | mauvais Python : il faudrait tout re-tester en 3.13 |
| `cgr.dev/chainguard/python` | dernière version | non / non | gratuit : tags `latest` seulement | version non épinglable |
| `dhi.io/python:3.12-debian13` | 3.12 | non / non | compte Docker gratuit | **retenue** |

[Docker Hardened Images](https://docs.docker.com/dhi/) (DHI) est un catalogue d'images
minimales et durcies, passé en open source (Apache 2.0) et gratuit en décembre 2025 : runtime
sans shell, utilisateur `nonroot` (UID 65532) par défaut, et une variante `-dev` (avec shell et
pip) pour le stage de build. Le catalogue (définitions des images) est public sur GitHub.

> [!WARNING]
> **Connexion au registre dhi.io**
> Les images DHI se téléchargent après authentification avec un compte Docker (gratuit) :
> `docker login dhi.io`, avec votre identifiant Docker et un *personal access token* (Docker
> Hub → Account settings → Personal access tokens) plutôt que votre mot de passe. Sans compte
> Docker, voyez l'enseignant : l'alternative libre, `gcr.io/distroless/python3-debian13`, impose
> Python 3.13, un builder `python:3.13-slim-trixie`, un venv adapté au chemin `/usr/bin/python`
> de l'image (voir sa documentation) et de re-tester tout le projet en 3.13.

```dockerfile
# Fichier : packaging/Dockerfile.distroless
# Image de serving DURCIE (Lab 8) : même API, même modèle que packaging/Dockerfile (Lab 4),
# sur une base « distroless » : ni shell, ni gestionnaire de paquets, utilisateur non-root.
# Contexte de build = RACINE du repo, après `docker login dhi.io` (compte Docker gratuit) :
#   docker build -f packaging/Dockerfile.distroless -t scoring-api:distroless .
#
# Base : Docker Hardened Images (DHI, Apache 2.0, gratuites depuis décembre 2025), Python
# 3.12 sur Debian 13. gcr.io/distroless/python3 ne convient pas : debian12 = Python 3.11
# (plus mise à jour), debian13 = Python 3.13. Or les dépendances sont des wheels compilées
# pour UN interpréteur (cp312) : builder et runtime doivent avoir le même Python, celui du
# projet. On suit le schéma recommandé par DHI : un venv construit dans la variante -dev.

# --- Stage 1 : builder (variante -dev : shell + pip, root) ----------------------------
FROM dhi.io/python:3.12-debian13-dev AS builder
ENV PATH="/opt/venv/bin:$PATH"
RUN python -m venv /opt/venv
COPY packaging/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# --- Stage 2 : runtime distroless (pas de shell, pas d'apt, utilisateur nonroot) -------
FROM dhi.io/python:3.12-debian13 AS runtime
WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Même arborescence que le repo (et que l'image du Lab 4) ; fichiers en lecture seule.
COPY dataset.yaml ./
COPY src/__init__.py src/dataset_config.py src/
COPY packaging/app/__init__.py packaging/app/serve.py packaging/app/
COPY packaging/model/model.onnx packaging/model/metadata.json packaging/model/

# nonroot (UID 65532) existe déjà dans l'image de base : USER numérique pour runAsNonRoot.
USER 65532:65532
EXPOSE 8000

# Forme exec obligatoire : il n'y a pas de /bin/sh pour interpréter une chaîne.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --start-interval=2s \
    CMD ["python", "-c", \
         "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"]

ARG VERSION=1.0.0
ARG MODEL_VERSION=unknown
LABEL org.opencontainers.image.title="scoring-api" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.base.name="dhi.io/python:3.12-debian13" \
      mlflow.model_name="scoring-model" \
      mlflow.model_alias="champion" \
      mlflow.model_version="${MODEL_VERSION}"
# Comme l'image du Lab 5 : l'API expose la version de son image (/version, /metadata).
ENV APP_VERSION=${VERSION}

CMD ["python", "-m", "uvicorn", "app.serve:app", "--app-dir", "packaging", \
     "--host", "0.0.0.0", "--port", "8000"]
```

Comme au Lab 4, un `.dockerignore` propre à ce Dockerfile (lu par BuildKit) n'envoie au build
que les fichiers copiés dans l'image :

```text
# Fichier : packaging/Dockerfile.distroless.dockerignore
# .dockerignore propre à packaging/Dockerfile.distroless (BuildKit le lit à la place de
# celui de la racine) : même liste blanche que l'image du Lab 4 — aucun secret (.env),
# aucune donnée, aucun pickle de la démo ModelScan ne peut entrer dans l'image.
*
!dataset.yaml
!src/__init__.py
!src/dataset_config.py
!packaging/requirements.txt
!packaging/app/__init__.py
!packaging/app/serve.py
!packaging/model/model.onnx
!packaging/model/metadata.json
```

```bash
docker login dhi.io
MODEL_VERSION=$(uv run python -c \
    "import json; print(json.load(open('packaging/model/metadata.json'))['model_version'])")
docker build -f packaging/Dockerfile.distroless -t scoring-api:distroless \
    --build-arg VERSION=1.0.0 --build-arg MODEL_VERSION="$MODEL_VERSION" .
docker images scoring-api
# Le bon Python, un utilisateur non-root… et aucun shell
docker run --rm --entrypoint python scoring-api:distroless --version
docker inspect -f '{{.Config.User}}' scoring-api:distroless
docker run --rm --entrypoint sh scoring-api:distroless -c "echo shell" \
  || echo "pas de shell dans l'image"
# L'API répond comme celle du Lab 4
uv run python packaging/sample_request.py > /tmp/request.json
docker run -d --rm -p 8001:8000 --name scoring-distroless scoring-api:distroless
sleep 5 && curl -s http://localhost:8001/health
curl -s -X POST http://localhost:8001/predict -H "Content-Type: application/json" \
    -d @/tmp/request.json
docker inspect -f '{{.State.Health.Status}}' scoring-distroless
docker stop scoring-distroless
```

> **Sortie attendue :** une taille du même ordre que `scoring-api:optimized` (≈ 206 Mo de
> dépendances Python identiques), sans bash, apt ni perl. `Python 3.12.x`, utilisateur
> `65532:65532`, puis une erreur `exec: "sh": executable file not found in $PATH` suivie de
> `pas de shell dans l'image`. `/health` répond `{"status":"ok","model_loaded":true}`,
> `/predict` renvoie exactement la même probabilité que l'image du Lab 4 (même modèle ONNX,
> mêmes dépendances) et l'état de santé devient `healthy` (le `HEALTHCHECK` n'a pas besoin de
> shell : il est écrit en forme exec).

```bash
# Nouveau scan
trivy image --severity HIGH,CRITICAL scoring-api:distroless > reports/trivy_distroless.txt
echo "AVANT : $(grep -c CVE- reports/trivy_critical.txt)"
echo "APRÈS : $(grep -c CVE- reports/trivy_distroless.txt)"
grep "^Total" reports/trivy_critical.txt reports/trivy_distroless.txt
# Publier l'image durcie à côté de la 1.0.0
docker tag scoring-api:distroless localhost:5001/scoring-api:1.0.0-distroless
docker push localhost:5001/scoring-api:1.0.0-distroless
```

> **Sortie attendue :** la cible système de l'image durcie n'a plus (ou presque plus) de CVE
> HIGH/CRITICAL : les paquets Debian inutiles ont disparu et DHI corrige vite les autres. Les
> CVE qui restent viennent des **paquets Python** (identiques dans les deux images) : elles se
> corrigent en mettant à jour `packaging/requirements.txt`, pas en changeant de base. Noter le
> chiffre avant/après pour le rapport.

> [!NOTE]
> **Un tag n'est pas une preuve**
> `scoring-api:distroless` peut être reconstruit demain avec un autre contenu. Ce qui
> identifie l'image auditée, c'est son digest
> (`docker images --digests localhost:5001/scoring-api`). En production, on signe ce digest
> (Cosign, voir le cours) et on fait échouer la CI si Trivy trouve une CVE CRITICAL
> corrigeable : `trivy image --exit-code 1 --ignore-unfixed --severity CRITICAL …`.

## Étape 2/9 — ModelScan : pickle vs ONNX (15 min)

Le Lab 4 a déjà montré le danger : un pickle **exécute du code** à son chargement. On reprend
sa démonstration pour l'audit (le champion a pu changer depuis), puis on regarde comment
ModelScan s'utilise comme garde-fou automatique.

```bash
# Deux pickles du champion (script du Lab 4) : model.pkl sain, malicious.pkl piégé
uv run python packaging/scan-demo/make_pickles.py
uv run modelscan -p packaging/scan-demo/ > reports/modelscan_pickle.txt
uv run modelscan -p packaging/model/model.onnx > reports/modelscan_onnx.txt
echo "=== PICKLE ===" && grep -E "Total Issues|CRITICAL|Description" reports/modelscan_pickle.txt
echo "=== ONNX ===" && grep -E "No issues|skipped" reports/modelscan_onnx.txt
```

> **Sortie attendue :**

```text
=== PICKLE ===
Total Issues: 1
Total Issues By Severity:
    - CRITICAL: 1
--- CRITICAL ---
  - Severity: CRITICAL
  - Description: Use of unsafe operator 'system' from module 'posix'
=== ONNX ===
 No issues found! 🎉
Total skipped: 1 - run with --show-skipped to see the full list.
```

ONNX donne systématiquement « No issues found », mais **parce que ModelScan ne le lit pas**
(« skipped ») : c'est un graphe protobuf déclaratif, sans code. En CI, c'est le **code
retour** qui compte :

```bash
for f in packaging/scan-demo/model.pkl packaging/scan-demo/malicious.pkl \
         packaging/model/model.onnx; do
  uv run modelscan -p "$f" > /dev/null 2>&1; echo "$f -> code $?"
done
uv run modelscan -p packaging/scan-demo/ -r json -o reports/modelscan_pickle.json
```

> **Sortie attendue :** `model.pkl -> code 0` (scanné, rien trouvé), `malicious.pkl -> code 1`
> (problème trouvé), `model.onnx -> code 3` (aucun fichier pris en charge). Le code 2 signale
> une erreur de scan. Une CI qui échoue sur « code ≠ 0 » bloquerait donc l'ONNX : la bonne
> règle est « échec si code 1 ou 2 ». Le rapport JSON (`issues[].operator` = `system`,
> `module` = `posix`) est la version exploitable par un outil.

Le modèle du Registry, lui, est sérialisé en **skops** par MLflow 3. ModelScan l'ignore aussi ;
c'est skops qui l'audite, en listant les types que le fichier demande à instancier hors de sa
liste de confiance :

```bash
uv run mlflow artifacts download -u models:/scoring-model@champion -d /tmp/champion
uv run python -c "from skops.io import get_untrusted_types; \
print(get_untrusted_types(file='/tmp/champion/model.skops'))"
```

> **Sortie attendue :** `['numpy.dtype']`, le seul type que le Lab 1 a explicitement autorisé
> (`SKOPS_TRUSTED_TYPES` de `src/train.py`) : pas de surprise dans le fichier.

| Format | Code exécuté au chargement ? | Audit | Usage |
|---|---|---|---|
| pickle / joblib | oui, n'importe lequel | ModelScan (heuristique : opérateurs dangereux) | jamais d'origine non maîtrisée |
| skops (MLflow 3) | seulement des types autorisés | `skops.io.get_untrusted_types` | Registry |
| ONNX | non (graphe déclaratif) | rien à exécuter | production (API) |

> [!CAUTION]
> **Le vrai risque du pickle**
> Un pickle peut exécuter du code arbitraire au chargement :
> `class Evil: def __reduce__(self): return (os.system, ("rm -rf ~",))`. ModelScan détecte ces
> motifs statiquement mais ne garantit pas l'absence de tout risque (un opérateur inconnu de sa
> liste passe). Règle : en production, ONNX pour tout modèle qui ne vient pas d'une source
> totalement maîtrisée ; ne chargez **jamais** `malicious.pkl`.

## Étape 3/9 — Fairlearn : mesurer les disparités (25 min)

### 3.1 Ce qu'on mesure, et à quel seuil

Le modèle ne décide pas avec `predict()` (seuil 0,5) : il refuse une demande quand
P(`bad`) ≥ `decision_threshold`, le seuil qui minimise le coût métier, loggé par le Lab 1
dans le run du champion (0,318 ici). L'audit d'équité doit porter sur **ces décisions-là**,
sinon on audite un autre modèle que celui qui est servi.

Les groupes à comparer viennent de la section `sensitive` de `dataset.yaml` : le script ne
contient aucun nom de colonne, il boucle sur `cfg.sensitive` et `cfg.sensitive_frame(X)`
renvoie le groupe de chaque demande (l'âge est découpé en `<25` / `>=25` par `bins`).

```bash
grep -A6 "^sensitive:" dataset.yaml
```

> [!WARNING]
> **Pour Fairlearn, « sélectionner » = REFUSER**
> La classe positive est `bad` (le risque) : `selection_rate` est donc le **taux de refus**,
> et la parité démographique compare des taux de refus. La règle des 4/5 (pratique américaine
> de détection d'un effet discriminatoire, ratio des taux de l'issue **favorable** < 0,8) se
> calcule sur les taux d'**acceptation** : le script la calcule à part.

Pour chaque groupe, on calcule : l'effectif, le taux réel de mauvais payeurs, le taux de
refus (avec un intervalle de confiance bootstrap : les petits groupes sont trompeurs), le
**TPR** (part des mauvais payeurs effectivement refusés : la protection de la banque), le
**FPR** (part des **bons** payeurs refusés à tort : le préjudice subi par le demandeur) et le
coût métier moyen par demande.

### 3.2 Le script d'analyse

`load_champion()` sera réutilisé par les scripts suivants : il charge la **version exacte**
pointée par `@champion` et le seuil loggé dans son run.

```python
# Fichier : governance/fairness_analysis.py
"""Étape 3 — mesure des disparités du modèle champion, attribut sensible par attribut sensible.

Pour CHAQUE attribut de la section `sensitive` de dataset.yaml (aucun nom en dur ici) :
  - métriques par groupe au seuil de décision du modèle (param `decision_threshold` du
    run, Lab 1) : taux de défaut réel, taux de refus, TPR, FPR, coût métier par demande ;
  - indicateurs d'équité : parité démographique (écart, ratio), ratio d'acceptation
    (règle des 4/5), equalized odds ;
  - intervalle de confiance bootstrap du taux de refus (petits groupes = chiffres fragiles).
Classe positive = « à risque » : pour Fairlearn, « sélectionner » une demande = la REFUSER.

Usage (racine du repo) :
    uv run python -m governance.fairness_analysis | tee reports/fairness_baseline.txt
Sorties : le rapport sur la sortie standard + reports/fairness_baseline.json
"""

import json
import os
from pathlib import Path

import mlflow
import numpy as np
import pandas as pd
from fairlearn.metrics import (
    MetricFrame,
    count,
    demographic_parity_difference,
    demographic_parity_ratio,
    equalized_odds_difference,
    false_positive_rate,
    false_positive_rate_difference,
    selection_rate,
    true_positive_rate,
)
from mlflow import MlflowClient
from sklearn.pipeline import Pipeline

from src.dataset_config import DatasetConfig, load_config
from src.promote import MODEL_NAME
from src.train import TEST_CSV

REPORT_JSON = Path("reports/fairness_baseline.json")
MIN_GROUP_SIZE = 30  # en dessous, les taux d'un groupe sont trop incertains pour conclure
N_BOOT = 200  # tirages bootstrap pour l'intervalle de confiance à 95 %
FOUR_FIFTHS = 0.8  # règle des 4/5 : ratio minimal toléré entre taux d'acceptation
RATES = ["taux_defaut", "taux_refus", "TPR", "FPR"]


def load_champion() -> tuple[Pipeline, float, str]:
    """Le champion du Registry, son seuil de décision (Lab 1) et son numéro de version."""
    mlflow.set_tracking_uri(os.getenv("MLFLOW_TRACKING_URI", "http://localhost:5000"))
    client = MlflowClient()
    version = client.get_model_version_by_alias(MODEL_NAME, "champion")
    # Le seuil fait partie du modèle : c'est lui qui décide (et non 0,5)
    threshold = float(client.get_run(version.run_id).data.params["decision_threshold"])
    # On charge la version exacte : l'alias pourrait bouger pendant l'audit
    model = mlflow.sklearn.load_model(f"models:/{MODEL_NAME}/{version.version}")
    return model, threshold, str(version.version)


def group_table(cfg: DatasetConfig, y_true, y_pred, groups: pd.Series) -> pd.DataFrame:
    """Une ligne par groupe : effectif, taux réels, taux de refus, TPR, FPR, coût moyen."""
    metrics = {
        "n": count,
        "taux_defaut": lambda yt, yp: float(np.mean(yt)),  # mauvais payeurs réels
        "taux_refus": selection_rate,  # P(refus) : la « sélection » de Fairlearn
        "TPR": true_positive_rate,  # mauvais payeurs effectivement refusés
        "FPR": false_positive_rate,  # BONS payeurs refusés à tort
        "cout_moyen": lambda yt, yp: cfg.business_cost(yt, yp) / len(yt),
    }
    mf = MetricFrame(metrics=metrics, y_true=y_true, y_pred=y_pred, sensitive_features=groups)
    table = mf.by_group
    table.loc["(ensemble)"] = mf.overall
    # IC à 95 % du taux de refus : rééchantillonnage des demandes (bootstrap)
    boot = MetricFrame(
        metrics={"refus": selection_rate},
        y_true=y_true,
        y_pred=y_pred,
        sensitive_features=groups,
        n_boot=N_BOOT,
        ci_quantiles=[0.025, 0.975],
        random_state=cfg.random_state,
    )
    low, high = boot.by_group_ci
    table["refus_ic95_bas"] = low["refus"]
    table["refus_ic95_haut"] = high["refus"]
    return table


def fairness_indicators(y_true, y_pred, groups: pd.Series) -> dict[str, float]:
    """Indicateurs d'équité d'un jeu de décisions (0/1, 1 = refus) pour un attribut."""
    y_pred = np.asarray(y_pred)
    return {
        "demographic_parity_difference": demographic_parity_difference(
            y_true, y_pred, sensitive_features=groups
        ),
        "demographic_parity_ratio": demographic_parity_ratio(
            y_true, y_pred, sensitive_features=groups
        ),
        # Règle des 4/5 : elle porte sur l'issue FAVORABLE (l'acceptation = 1 - refus)
        "acceptance_rate_ratio": demographic_parity_ratio(
            y_true, 1 - y_pred, sensitive_features=groups
        ),
        "equalized_odds_difference": equalized_odds_difference(
            y_true, y_pred, sensitive_features=groups
        ),
        "false_positive_rate_difference": false_positive_rate_difference(
            y_true, y_pred, sensitive_features=groups
        ),
    }


def print_attribute(column: str, table: pd.DataFrame, ind: dict) -> None:
    shown = table.copy()
    shown["n"] = shown["n"].astype(int)
    for col in RATES:
        shown[col] = shown[col].map("{:.0%}".format)
    shown["cout_moyen"] = shown["cout_moyen"].map("{:.2f}".format)
    shown["refus_IC95"] = [
        f"[{lo:.0%} ; {hi:.0%}]" if pd.notna(lo) else ""
        for lo, hi in zip(table["refus_ic95_bas"], table["refus_ic95_haut"], strict=True)
    ]
    print(f"\n=== Attribut sensible : {column} ===")
    print(shown.drop(columns=["refus_ic95_bas", "refus_ic95_haut"]).to_string())
    ratio = ind["acceptance_rate_ratio"]
    alert = "  <-- sous la règle des 4/5" if ratio < FOUR_FIFTHS else ""
    print(f"Demographic Parity Diff (refus)  : {ind['demographic_parity_difference']:.3f}")
    print(f"Demographic Parity Ratio (refus) : {ind['demographic_parity_ratio']:.3f}")
    print(f"Ratio d'acceptation (4/5)        : {ratio:.3f}{alert}")
    print(f"Equalized Odds Diff (TPR/FPR)    : {ind['equalized_odds_difference']:.3f}")
    print(f"Groupe le plus refusé            : {ind['most_refused_group']}")
    if ind["small_groups"]:
        print(f"Attention : moins de {MIN_GROUP_SIZE} demandes pour {ind['small_groups']}")


def main() -> None:
    cfg = load_config()
    model, threshold, version = load_champion()
    X_test, y_test = cfg.read_xy(TEST_CSV)
    y_pred = (model.predict_proba(X_test)[:, 1] >= threshold).astype(int)
    sensitive = cfg.sensitive_frame(X_test)  # un groupe par attribut (age découpé en tranches)

    print(f"Modèle {MODEL_NAME} v{version} · seuil de décision {threshold:.3f}")
    print(f"{len(y_test)} demandes de test · prédiction 1 = « {cfg.positive_class} » = REFUS")
    cost = cfg.business_cost(y_test, y_pred)
    print(f"Global : refus {y_pred.mean():.0%}, coût métier {cost:.0f}")

    report = {
        "model_name": MODEL_NAME,
        "model_version": version,
        "decision_threshold": threshold,
        "n_test": len(y_test),
        "business_cost": cost,
        "refusal_rate": float(y_pred.mean()),
        "attributes": {},
    }
    for attr, group_col in zip(cfg.sensitive, sensitive.columns, strict=True):
        groups = sensitive[group_col]
        table = group_table(cfg, y_test, y_pred, groups)
        by_group = table.drop("(ensemble)")
        ind = fairness_indicators(y_test, y_pred, groups) | {
            "most_refused_group": by_group["taux_refus"].idxmax(),
            "small_groups": [g for g, n in by_group["n"].items() if n < MIN_GROUP_SIZE],
        }
        print_attribute(attr.column, table, ind)
        report["attributes"][attr.column] = {
            "groups_column": group_col,
            "groups": by_group.to_dict(orient="index"),
            **ind,
        }

    REPORT_JSON.parent.mkdir(parents=True, exist_ok=True)
    REPORT_JSON.write_text(json.dumps(report, indent=2, ensure_ascii=False, default=float) + "\n")
    print(f"\n-> {REPORT_JSON}")


if __name__ == "__main__":
    main()
```

### 3.3 Lancer et interpréter

```bash
uv run python -m governance.fairness_analysis | tee reports/fairness_baseline.txt
```

> **Sortie attendue :**

```text
Modèle scoring-model v3 · seuil de décision 0.318
200 demandes de test · prédiction 1 = « bad » = REFUS
Global : refus 63%, coût métier 108

=== Attribut sensible : age ===
              n taux_defaut taux_refus  TPR  FPR cout_moyen   refus_IC95
age_group
<25          39         49%        77%  95%  60%       0.44  [63% ; 90%]
>=25        161         25%        60%  85%  51%       0.57  [52% ; 67%]
(ensemble)  200         30%        63%  88%  52%       0.54
Demographic Parity Diff (refus)  : 0.173
Demographic Parity Ratio (refus) : 0.775
Ratio d'acceptation (4/5)        : 0.572  <-- sous la règle des 4/5
Equalized Odds Diff (TPR/FPR)    : 0.094
Groupe le plus refusé            : <25

=== Attribut sensible : personal_status ===
                      n taux_defaut taux_refus   TPR  FPR cout_moyen    refus_IC95
personal_status
female div/dep/mar   61         33%        72%   95%  61%       0.49   [60% ; 81%]
male div/sep          9         33%        67%  100%  50%       0.33  [33% ; 100%]
male mar/wid         12         25%        83%   67%  89%       1.08  [57% ; 100%]
male single         118         29%        56%   85%  44%       0.53   [46% ; 65%]
(ensemble)          200         30%        63%   88%  52%       0.54
Demographic Parity Diff (refus)  : 0.274
Demographic Parity Ratio (refus) : 0.671
Ratio d'acceptation (4/5)        : 0.378  <-- sous la règle des 4/5
Equalized Odds Diff (TPR/FPR)    : 0.448
Groupe le plus refusé            : male mar/wid
Attention : moins de 30 demandes pour ['male div/sep', 'male mar/wid']

=== Attribut sensible : foreign_worker ===
                  n taux_defaut taux_refus   TPR  FPR cout_moyen   refus_IC95
foreign_worker
no                6         17%        50%  100%  40%       0.33  [0% ; 100%]
yes             194         30%        63%   88%  53%       0.55  [56% ; 70%]
(ensemble)      200         30%        63%   88%  52%       0.54
Demographic Parity Diff (refus)  : 0.134
Demographic Parity Ratio (refus) : 0.789
Ratio d'acceptation (4/5)        : 0.732  <-- sous la règle des 4/5
Equalized Odds Diff (TPR/FPR)    : 0.126
Groupe le plus refusé            : yes
Attention : moins de 30 demandes pour ['no']

-> reports/fairness_baseline.json
```

Lecture, attribut par attribut :

- **Âge** : les moins de 25 ans sont refusés à 77 % contre 60 % ; leur ratio d'acceptation
  (23 % / 40 % = 0,57) est très en dessous de 0,8. Une partie de l'écart s'explique par le
  risque réel (49 % de mauvais payeurs contre 25 %), mais pas tout : parmi les **bons**
  payeurs, les jeunes sont aussi plus souvent refusés à tort (FPR 60 % contre 51 %).
- **Statut personnel** : écarts spectaculaires (FPR de 89 % pour `male mar/wid`), mais sur 9
  et 12 personnes ; les intervalles de confiance ([57 % ; 100 %]) interdisent de conclure.
- **Travailleur étranger** : 6 personnes dans le groupe `no`, intervalle [0 % ; 100 %] :
  rien n'est mesurable sur ce jeu de test. Une absence de preuve n'est pas une preuve
  d'absence : c'est un **écart à documenter** dans la Model Card.

> [!WARNING]
> **Un attribut sensible mal codé**
> La documentation du jeu corrigé « South German Credit » (UCI 522, Grömping 2019) signale des
> erreurs de codage dans la Statlog German Credit : le sexe **ne peut pas** être retrouvé à
> partir de `personal_status`. Les libellés `male …` / `female …` sont peut-être faux. Leçon :
> un audit d'équité commence par la qualité des attributs sensibles eux-mêmes.

> [!NOTE]
> **Interprétation des métriques Fairlearn**
> Demographic Parity : même taux de refus par groupe. Equalized Odds : mêmes TPR **et** FPR
> par groupe. Equal Opportunity : même taux d'erreur pour les « méritants » — ici les bons
> payeurs, donc même FPR. Les trois ne peuvent pas être satisfaites simultanément quand les
> taux réels diffèrent entre groupes (théorème d'impossibilité, Chouldechova 2017). Le choix
> dépend du cas d'usage et doit être **justifié** : pour le crédit, la question centrale est
> « un bon payeur a-t-il la même chance d'obtenir son crédit quel que soit son groupe ? »
> (FPR, equalized odds), plutôt qu'une stricte parité des taux de refus. Attention :
> `equal_opportunity_difference` de Fairlearn compare les TPR de la classe positive (ici les
> mauvais payeurs détectés) ; pour les bons payeurs, c'est l'écart de FPR qu'il faut lire.

## Étape 4/9 — Atténuer les disparités : trois stratégies chiffrées (25 min)

### 4.1 Faut-il retirer l'attribut sensible des features ?

C'est le premier réflexe (« fairness through unawareness ») : si le modèle ne voit pas l'âge,
il ne peut pas discriminer selon l'âge… sauf si d'autres variables le **trahissent**
(ancienneté dans l'emploi, logement, situation familiale). On ne débat pas : on mesure. Le
script ré-entraîne le champion sans la colonne, puis teste si un modèle simple retrouve le
groupe à partir des autres variables (AUC : 0,5 = impossible, 1 = parfait).

On compare ensuite deux atténuations de Fairlearn :

- **ThresholdOptimizer** (post-traitement) : le modèle ne change pas, on choisit **un seuil
  par groupe** sous la contrainte « equalized odds ». Son objectif par défaut est
  l'accuracy… qui n'est pas le coût métier : le script montre les deux.
- **ExponentiatedGradient** (réduction, *in-processing*) : on ré-entraîne le modèle sous
  contrainte, avec le coût métier (`ErrorRate(costs=…)`) comme objectif ; l'attribut ne sert
  qu'à l'entraînement.

```python
# Fichier : governance/fairness_mitigation.py
"""Étape 4 — atténuer les disparités : trois familles de stratégies comparées au champion.

Pour chaque attribut sensible de dataset.yaml :
  1. « sans l'attribut » (fairness through unawareness) : le même modèle ré-entraîné sans
     la colonne sensible, plus un test de proxy : peut-on deviner le groupe à partir des
     autres variables ? (si oui, retirer la colonne ne suffit pas) ;
  2. ThresholdOptimizer (post-traitement) : un seuil par groupe sous contrainte
     « equalized odds ». Son objectif par défaut est l'accuracy ; on montre ce que cela
     coûte, puis on lui fait optimiser le coût métier de dataset.yaml ;
  3. ExponentiatedGradient (réduction, in-processing) : ré-entraînement sous la même
     contrainte, avec le coût métier comme objectif (ErrorRate pondérée).
Tout est évalué sur le jeu de test, au même titre que le champion.

Usage (racine du repo) :
    uv run python -m governance.fairness_mitigation | tee reports/fairness_mitigated.txt
Sorties : le comparatif sur la sortie standard + reports/fairness_mitigated.json
"""

import dataclasses
import json
from pathlib import Path

import numpy as np
import pandas as pd
from fairlearn.postprocessing import ThresholdOptimizer
from fairlearn.reductions import EqualizedOdds, ErrorRate, ExponentiatedGradient
from sklearn.base import clone
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import StratifiedKFold, cross_val_score
from sklearn.pipeline import Pipeline

from governance.fairness_analysis import fairness_indicators, load_champion
from src.dataset_config import DatasetConfig, load_config
from src.train import TEST_CSV, TRAIN_CSV

REPORT_JSON = Path("reports/fairness_mitigated.json")


def without(cfg: DatasetConfig, column: str) -> DatasetConfig:
    """La même configuration, sans une colonne (prétraitement et features)."""
    return dataclasses.replace(
        cfg,
        numeric=[c for c in cfg.numeric if c != column],
        categorical=[c for c in cfg.categorical if c != column],
    )


def proxy_test(cfg: DatasetConfig, X: pd.DataFrame, groups: pd.Series) -> dict:
    """Peut-on retrouver le groupe sensible à partir des AUTRES variables ? (AUC en CV 5)

    AUC ~ 0,5 : aucune information ; AUC élevée : des « proxies » trahissent le groupe.
    """
    if groups.nunique() < 2:
        return {"auc": None, "top_proxies": {}}
    scoring = "roc_auc" if groups.nunique() == 2 else "roc_auc_ovr_weighted"
    cv = StratifiedKFold(n_splits=5, shuffle=True, random_state=cfg.random_state)

    def auc(features: list[str]) -> float:
        sub = dataclasses.replace(
            cfg,
            numeric=[c for c in cfg.numeric if c in features],
            categorical=[c for c in cfg.categorical if c in features],
        )
        clf = Pipeline(
            [("preprocess", sub.build_preprocessor()), ("model", LogisticRegression(max_iter=1000))]
        )
        return float(cross_val_score(clf, X[features], groups, cv=cv, scoring=scoring).mean())

    single = {f: auc([f]) for f in cfg.features}  # pouvoir révélateur de chaque variable seule
    top = dict(sorted(single.items(), key=lambda kv: kv[1], reverse=True)[:3])
    return {"auc": auc(cfg.features), "top_proxies": top}


def cost_weighted(cfg: DatasetConfig, X, y, groups):
    """Duplique les lignes pour que « accuracy » = « coût métier » (C_FN/C_FP répétitions).

    ThresholdOptimizer n'optimise que des scores prédéfinis (accuracy…) et n'accepte pas de
    poids : avec chaque mauvais payeur compté 5 fois, maximiser l'accuracy revient à
    minimiser 5 x FN + 1 x FP. Les contraintes TPR/FPR, calculées par classe, ne changent pas.
    """
    ratio = cfg.cost_false_negative / cfg.cost_false_positive
    reps = np.where(y == 1, max(round(ratio), 1), max(round(1 / ratio), 1))
    idx = X.index.repeat(reps)
    return X.loc[idx], y.loc[idx], groups.loc[idx]


def evaluate(cfg, y_true, y_pred, groups, ref_cost: float, uses_attribute: bool) -> dict:
    y_pred = np.asarray(y_pred).astype(int)
    cost = cfg.business_cost(y_true, y_pred)
    return {
        "business_cost": cost,
        "cost_change": cost / ref_cost - 1,
        "refusal_rate": float(y_pred.mean()),
        **fairness_indicators(y_true, y_pred, groups),
        "uses_attribute_at_prediction": uses_attribute,
    }


def main() -> None:
    cfg = load_config()
    model, threshold, version = load_champion()
    X_train, y_train = cfg.read_xy(TRAIN_CSV)
    X_test, y_test = cfg.read_xy(TEST_CSV)
    s_train, s_test = cfg.sensitive_frame(X_train), cfg.sensitive_frame(X_test)
    proba = model.predict_proba(X_test)[:, 1]
    base_pred = (proba >= threshold).astype(int)
    ref_cost = cfg.business_cost(y_test, base_pred)
    costs = {"fn": cfg.cost_false_negative, "fp": cfg.cost_false_positive}
    last_step = model.steps[-1][0]  # « model » : nom de l'estimateur dans le Pipeline (Lab 1)
    print(f"Champion v{version} · seuil {threshold:.3f} · coût de référence {ref_cost:.0f}")

    report = {"model_version": version, "decision_threshold": threshold, "attributes": {}}
    for attr, group_col in zip(cfg.sensitive, s_test.columns, strict=True):
        g_train, g_test = s_train[group_col], s_test[group_col]
        decisions = {"champion": (base_pred, True)}  # nom -> (décisions, attribut en prod ?)

        # 1. Fairness through unawareness : on retire la colonne et on ré-entraîne
        cfg_wo = without(cfg, attr.column)
        # « preprocess » : nom de l'étape de prétraitement dans le Pipeline du Lab 1
        unaware = clone(model).set_params(preprocess=cfg_wo.build_preprocessor())
        unaware.fit(X_train[cfg_wo.features], y_train)
        p_unaware = unaware.predict_proba(X_test[cfg_wo.features])[:, 1]
        decisions["sans_attribut"] = (p_unaware >= threshold, False)
        proxies = proxy_test(cfg_wo, X_train, g_train)

        # 2. Post-traitement : un seuil par groupe (le modèle n'est pas ré-entraîné)
        for objective, (Xf, yf, gf) in {
            "accuracy": (X_train, y_train, g_train),
            "cout": cost_weighted(cfg, X_train, y_train, g_train),
        }.items():
            to = ThresholdOptimizer(
                estimator=model,
                constraints="equalized_odds",
                objective="accuracy_score",
                prefit=True,
                predict_method="predict_proba",
            )
            to.fit(Xf, yf, sensitive_features=gf)
            y_to = to.predict(X_test, sensitive_features=g_test, random_state=cfg.random_state)
            decisions[f"threshold_optimizer_{objective}"] = (y_to, True)

        # 3. In-processing : ré-entraînement sous contrainte, objectif = coût métier.
        # Les poids de classes du champion sont neutralisés : les coûts les remplacent.
        base = clone(model)
        if f"{last_step}__class_weight" in base.get_params():
            base.set_params(**{f"{last_step}__class_weight": None})
        eg = ExponentiatedGradient(
            base,
            constraints=EqualizedOdds(),
            objective=ErrorRate(costs=costs),
            sample_weight_name=f"{last_step}__sample_weight",  # poids routés vers le modèle
        )
        eg.fit(X_train, y_train, sensitive_features=g_train)
        y_eg = eg.predict(X_test, random_state=cfg.random_state)  # classifieur randomisé
        decisions["exponentiated_gradient"] = (y_eg, False)

        results = {
            name: evaluate(cfg, y_test, y_pred, g_test, ref_cost, uses_attribute)
            for name, (y_pred, uses_attribute) in decisions.items()
        }
        table = pd.DataFrame(results).T
        shown = pd.DataFrame(
            {
                "coût": table["business_cost"].map("{:.0f}".format),
                "Δcoût": table["cost_change"].map("{:+.1%}".format),
                "refus": table["refusal_rate"].map("{:.0%}".format),
                "DP diff": table["demographic_parity_difference"].map("{:.3f}".format),
                "ratio acc.": table["acceptance_rate_ratio"].map("{:.2f}".format),
                "EO diff": table["equalized_odds_difference"].map("{:.3f}".format),
                "attribut en prod": table["uses_attribute_at_prediction"].map(
                    {True: "oui", False: "non"}
                ),
            }
        )
        print(f"\n=== Attribut sensible : {attr.column} ===")
        print(shown.to_string())
        auc = proxies["auc"]
        if auc is not None:
            top = ", ".join(f"{f} ({a:.2f})" for f, a in proxies["top_proxies"].items())
            print(f"Proxy : le groupe se devine sans la colonne avec une AUC de {auc:.2f}")
            print(f"        variables les plus révélatrices : {top}")
        report["attributes"][attr.column] = {"proxy": proxies, "strategies": results}

    REPORT_JSON.parent.mkdir(parents=True, exist_ok=True)
    REPORT_JSON.write_text(json.dumps(report, indent=2, ensure_ascii=False, default=float) + "\n")
    print(f"\n-> {REPORT_JSON}")


if __name__ == "__main__":
    main()
```

### 4.2 Le compromis coût métier / équité

```bash
uv run python -m governance.fairness_mitigation | tee reports/fairness_mitigated.txt
```

> **Sortie attendue :** (≈ 30 s)

```text
Champion v3 · seuil 0.318 · coût de référence 108

=== Attribut sensible : age ===
                             coût    Δcoût refus DP diff ratio acc. EO diff attribut en prod
champion                      108    +0.0%   63%   0.173       0.57   0.094              oui
sans_attribut                 111    +2.8%   64%   0.154       0.60   0.094              non
threshold_optimizer_accuracy  239  +121.3%    8%   0.054       0.94   0.025              oui
threshold_optimizer_cout      114    +5.6%   60%   0.083       0.80   0.012              oui
exponentiated_gradient        116    +7.4%   64%   0.065       0.83   0.118              non
Proxy : le groupe se devine sans la colonne avec une AUC de 0.77
        variables les plus révélatrices : housing (0.69), personal_status (0.67), employment (0.63)

=== Attribut sensible : personal_status ===
                             coût   Δcoût refus DP diff ratio acc. EO diff attribut en prod
champion                      108   +0.0%   63%   0.274       0.38   0.448              oui
sans_attribut                 119  +10.2%   68%   0.172       0.49   0.389              non
threshold_optimizer_accuracy  153  +41.7%   28%   0.194       0.74   0.471              oui
threshold_optimizer_cout      109   +0.9%   64%   0.278       0.44   0.333              oui
exponentiated_gradient        118   +9.3%   65%   0.140       0.64   0.333              non
Proxy : le groupe se devine sans la colonne avec une AUC de 0.71
        variables les plus révélatrices : age (0.64), housing (0.61), employment (0.61)

=== Attribut sensible : foreign_worker ===
                             coût   Δcoût refus DP diff ratio acc. EO diff attribut en prod
champion                      108   +0.0%   63%   0.134       0.73   0.126              oui
sans_attribut                 107   -0.9%   62%   0.129       0.74   0.119              non
threshold_optimizer_accuracy  162  +50.0%   21%   0.045       0.95   0.508              oui
threshold_optimizer_cout      106   -1.9%   62%   0.124       0.75   0.119              oui
exponentiated_gradient        110   +1.9%   64%   0.144       0.71   0.141              non
Proxy : le groupe se devine sans la colonne avec une AUC de 0.78
        variables les plus révélatrices : duration (0.77), property_magnitude (0.67), purpose (0.67)

-> reports/fairness_mitigated.json
```

Ce qu'il faut en retenir (attribut `age`) :

1. **Retirer la colonne ne suffit pas** : l'écart de parité passe de 0,173 à 0,154 et
   l'écart equalized odds ne bouge pas. Le test de proxy explique pourquoi : sans la colonne,
   l'âge se devine avec une AUC de 0,77 (logement, statut personnel, emploi).
2. **ThresholdOptimizer avec son objectif par défaut est un piège** : il optimise l'accuracy
   et remonte les seuils vers 0,5 ; il ne refuse plus que 8 % des demandes, laisse passer
   les mauvais payeurs et le coût métier double (+121 %).
3. **Réglé sur le coût métier**, il ramène l'écart equalized odds de 0,094 à 0,012 pour
   +5,6 % de coût. Mais il applique **un seuil différent selon l'âge** à la prédiction : un
   traitement explicitement différencié, généralement indéfendable juridiquement pour un
   crédit en Europe.
4. **ExponentiatedGradient** n'utilise pas l'âge en production et rapproche les taux
   d'acceptation (ratio 0,83, au-dessus de 0,8) pour +7,4 % de coût ; mais sur 39 jeunes,
   l'écart equalized odds mesuré en test (0,118) ne confirme pas la contrainte respectée à
   l'entraînement, et ses décisions sont **tirées au sort** entre plusieurs modèles (deux
   dossiers identiques peuvent recevoir deux réponses différentes).

> [!IMPORTANT]
> **Il n'y a pas d'atténuation gratuite**
> Chaque ligne du tableau est un compromis entre coût métier, type d'équité visé et
> faisabilité juridique (utiliser ou non l'attribut en production). En crédit, les disparités
> injustifiées sont illégales et doivent être corrigées ; mais **toujours documenter la
> décision** : quelle contrainte, pourquoi, à quel coût, validée par qui. C'est l'objet de la
> section 7 de la Model Card.

## Étape 5/9 — SHAP : explications globales et locales (25 min)

### 5.1 Importance globale

Le champion est un Pipeline : préprocesseur (one-hot de 13 colonnes catégorielles → 61
colonnes) puis modèle. SHAP explique le modèle final sur les colonnes transformées ; comme
les valeurs de Shapley sont additives, on **additionne** les contributions des colonnes
one-hot de chaque variable d'origine pour parler la langue du métier. L'explainer dépend du
modèle : `LinearExplainer` pour la régression logistique (exact, contributions en log-odds),
`TreeExplainer` pour une forêt ou un boosting.

```python
# Fichier : governance/explain.py
"""Étape 5.1 — explications SHAP globales du modèle champion.

Le champion est un Pipeline (préprocesseur de dataset.yaml + modèle). SHAP explique le
modèle final sur les colonnes produites par le préprocesseur (après one-hot), puis on
additionne les contributions des colonnes one-hot de chaque variable d'origine (les
valeurs de Shapley sont additives) pour parler la langue du métier : « checking_status »
plutôt que « cat__checking_status_<0 ».
Algorithme selon le modèle : LinearExplainer pour une régression logistique (contributions
en log-odds), TreeExplainer pour une forêt ou un boosting (calcul exact sur les arbres) ;
tout autre modèle est expliqué en « boîte noire » (plus lent).

Usage (racine du repo) : uv run python -m governance.explain
Sorties : reports/shap_summary_bar.png, reports/shap_beeswarm.png,
          reports/shap_importance.json
"""

import json
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import shap
from sklearn.pipeline import Pipeline

from governance.fairness_analysis import load_champion
from src.dataset_config import DatasetConfig, load_config
from src.train import TEST_CSV, TRAIN_CSV

REPORTS = Path("reports")
N_BACKGROUND = 100  # demandes de référence (« le demandeur moyen ») tirées du train


def origin_of_columns(model: Pipeline) -> tuple[list[str], list[str]]:
    """Pour chaque colonne en sortie du préprocesseur : son nom lisible et sa variable d'origine."""
    labels, origins = [], []
    for _, transformer, columns in model.named_steps["preprocess"].transformers_:
        if transformer == "drop":
            continue
        for out in transformer.get_feature_names_out(columns):
            src = max((c for c in columns if out == c or out.startswith(f"{c}_")), key=len)
            labels.append(src if out == src else f"{src}={out[len(src) + 1 :]}")
            origins.append(src)
    return labels, origins


def explain(cfg: DatasetConfig, model: Pipeline, X: pd.DataFrame, X_background: pd.DataFrame):
    """Valeurs SHAP de la classe positive : (par colonne one-hot, par variable d'origine)."""
    labels, origins = origin_of_columns(model)
    transform = model[:-1]  # tout le Pipeline sauf le modèle final
    background = pd.DataFrame(transform.transform(X_background), columns=labels)
    data = pd.DataFrame(transform.transform(X), columns=labels)
    masker = shap.maskers.Independent(background.sample(N_BACKGROUND, random_state=0))
    estimator = model[-1]
    if hasattr(estimator, "coef_"):  # modèle linéaire : contributions exactes en log-odds
        explainer = shap.LinearExplainer(estimator, masker)
    else:
        try:  # forêt, boosting : exact, calculé sur les chemins des arbres
            explainer = shap.TreeExplainer(estimator)
        except Exception:  # autre modèle : « boîte noire » sur P(positif), plus lent
            explainer = shap.Explainer(lambda d: estimator.predict_proba(d)[:, 1], masker)
    sv = explainer(data)
    if sv.values.ndim == 3:  # (n, colonnes, classes) pour certains modèles : classe positive
        sv = sv[..., 1]
    # Matrice colonne one-hot -> variable d'origine : la somme des contributions
    to_feature = np.array([[o == f for f in cfg.features] for o in origins], dtype=float)
    by_feature = shap.Explanation(
        values=sv.values @ to_feature,
        base_values=sv.base_values,
        data=X[cfg.features].to_numpy(dtype=object),
        feature_names=cfg.features,
    )
    return sv, by_feature, type(explainer).__name__


def output_space(model: Pipeline, X: pd.DataFrame, sv: shap.Explanation) -> str:
    """Les contributions s'additionnent-elles en probabilité ou en log-odds ?"""
    f = sv.base_values + sv.values.sum(axis=1)
    p = np.clip(model.predict_proba(X)[:, 1], 1e-9, 1 - 1e-9)
    return "probabilité" if np.allclose(f, p, atol=0.02) else "log-odds"


def main() -> None:
    plt.switch_backend("agg")  # pas de fenêtre : on écrit des PNG
    cfg = load_config()
    model, threshold, version = load_champion()
    X_train, _ = cfg.read_xy(TRAIN_CSV)
    X_test, _ = cfg.read_xy(TEST_CSV)
    sv, by_feature, algo = explain(cfg, model, X_test, X_train)
    space = output_space(model, X_test, by_feature)
    print(f"Champion v{version} ({type(model[-1]).__name__}) · {algo} · contributions en {space}")

    REPORTS.mkdir(exist_ok=True)
    # Importance globale = contribution absolue moyenne, par variable d'origine
    plt.figure()
    shap.plots.bar(by_feature, max_display=min(20, len(cfg.features)), show=False)
    plt.title("Importance globale (|SHAP| moyen par variable)")
    plt.savefig(REPORTS / "shap_summary_bar.png", dpi=150, bbox_inches="tight")
    plt.close()
    # Beeswarm : sens de l'effet de chaque colonne (rouge = valeur élevée / modalité présente)
    plt.figure()
    shap.plots.beeswarm(sv, max_display=15, show=False)
    plt.title(f"Effet de chaque colonne sur le risque ({space})")
    plt.savefig(REPORTS / "shap_beeswarm.png", dpi=150, bbox_inches="tight")
    plt.close()

    importance = pd.Series(np.abs(by_feature.values).mean(axis=0), index=cfg.features)
    importance = importance.sort_values(ascending=False)
    ranks = {f: i + 1 for i, f in enumerate(importance.index)}
    print("Importance globale (|SHAP| moyen) :")
    for feature, value in importance.items():
        flag = "  <-- attribut sensible" if feature in {s.column for s in cfg.sensitive} else ""
        print(f"  {ranks[feature]:>2}. {feature:<24} {value:.3f}{flag}")

    report = {
        "model_version": version,
        "estimator": type(model[-1]).__name__,
        "explainer": algo,
        "output_space": space,
        "decision_threshold": threshold,
        "importance": importance.round(4).to_dict(),
        "sensitive_ranks": {s.column: ranks[s.column] for s in cfg.sensitive},
    }
    (REPORTS / "shap_importance.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    )
    print(f"-> {REPORTS}/shap_summary_bar.png, shap_beeswarm.png, shap_importance.json")


if __name__ == "__main__":
    main()
```

```bash
uv run python -m governance.explain
```

> **Sortie attendue :**

```text
Champion v3 (LogisticRegression) · LinearExplainer · contributions en log-odds
Importance globale (|SHAP| moyen) :
   1. checking_status          0.534
   2. savings_status           0.278
   3. duration                 0.256
   4. installment_commitment   0.253
   5. credit_history           0.247
   6. purpose                  0.230
   7. personal_status          0.229  <-- attribut sensible
   8. credit_amount            0.214
   9. other_payment_plans      0.196
  10. own_telephone            0.139
  11. employment               0.137
  12. property_magnitude       0.133
  13. housing                  0.110
  14. existing_credits         0.056
  15. age                      0.055  <-- attribut sensible
  16. num_dependents           0.049
  17. foreign_worker           0.042  <-- attribut sensible
  18. other_parties            0.023
  19. residence_since          0.017
  20. job                      0.007
-> reports/shap_summary_bar.png, shap_beeswarm.png, shap_importance.json
```

Ouvrez `reports/shap_summary_bar.png` (importance par variable) et `reports/shap_beeswarm.png`
(sens de l'effet : `checking_status=<0` pousse vers le refus, `no checking` vers l'accord ;
plus la durée et le montant sont élevés, plus le risque augmente). Point d'audit :
**`personal_status`, un attribut sensible, est la 7e variable la plus influente** sur 20.

### 5.2 « Pourquoi cette demande est-elle refusée ? »

Une explication globale ne suffit pas au demandeur : il a droit aux motifs de **sa**
décision. Le script explique trois demandes types du jeu de test (le refus le plus net,
l'acceptation la plus nette, le cas le plus proche du seuil) ou celle de votre choix
(`--id`), rédige les principaux motifs en clair et vérifie si changer **un seul** attribut
sensible, toutes choses égales par ailleurs, ferait basculer la décision.

```python
# Fichier : governance/explain_local.py
"""Étape 5.2 — « Pourquoi cette demande est-elle refusée ? » (explications locales SHAP).

Trois demandes du jeu de test (le refus le plus net, l'acceptation la plus nette et le cas
le plus proche du seuil), ou celle passée par --id : un waterfall SHAP par variable
d'origine, avec le seuil de décision, et les motifs principaux rédigés en clair — la base
de l'explication due au demandeur (RGPD art. 22 et 15, AI Act art. 86).

Usage (racine du repo) :
    uv run python -m governance.explain_local            # les 3 cas types
    uv run python -m governance.explain_local --id 819   # une demande précise
Sorties : reports/shap_waterfall_<cas>.png + reports/explanations_local.md
"""

import argparse
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import shap
import yaml
from scipy.special import logit

from governance.explain import REPORTS, explain, output_space
from governance.fairness_analysis import load_champion
from src.dataset_config import DatasetConfig, load_config
from src.train import TEST_CSV, TRAIN_CSV

N_REASONS = 3  # nombre de motifs rédigés par décision


def pick_cases(proba: np.ndarray, threshold: float) -> dict[str, int]:
    """Positions de 3 demandes types : refus net, acceptation nette, cas limite."""
    refused = np.flatnonzero(proba >= threshold)
    accepted = np.flatnonzero(proba < threshold)
    cases = {}
    if len(refused):
        cases["refus_net"] = int(refused[np.argmax(proba[refused])])
    if len(accepted):
        cases["acceptation_nette"] = int(accepted[np.argmin(proba[accepted])])
    cases["cas_limite"] = int(np.argmin(np.abs(proba - threshold)))
    return cases


def reasons(cfg: DatasetConfig, contrib: shap.Explanation) -> tuple[list[str], list[str]]:
    """Variables qui poussent le plus vers le refus / vers l'acceptation, en clair."""
    order = np.argsort(contrib.values)
    sensitive = {s.column for s in cfg.sensitive}

    def phrase(i: int) -> str:
        name, value = contrib.feature_names[i], contrib.data[i]
        if isinstance(value, float) and value.is_integer():
            value = int(value)  # 48.0 -> 48
        flag = " [attribut sensible]" if name in sensitive else ""
        return f"{name} = {value} ({contrib.values[i]:+.2f}){flag}"

    against = [phrase(i) for i in order[::-1][:N_REASONS] if contrib.values[i] > 0]
    favour = [phrase(i) for i in order[:N_REASONS] if contrib.values[i] < 0]
    return against, favour


def counterfactual_flips(cfg, model, X_train, row: pd.DataFrame, threshold: float) -> list[str]:
    """Groupes sensibles qui feraient BASCULER la décision, toutes autres variables égales."""
    refused = model.predict_proba(row)[0, 1] >= threshold
    flips = []
    for attr in cfg.sensitive:
        train_groups, own = attr.groups(X_train), attr.groups(row).iloc[0]
        for group in sorted(set(train_groups) - {own}):
            values = X_train.loc[train_groups == group, attr.column]
            # valeur représentative du groupe : médiane (tranche d'âge…) ou la modalité
            alt = row.assign(**{attr.column: values.median() if attr.bins else values.iloc[0]})
            if (model.predict_proba(alt)[0, 1] >= threshold) != refused:
                flips.append(f"{attr.column} -> {group}")
    return flips


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--id", type=int, help="identifiant de la demande (jeu de test)")
    args = parser.parse_args()
    plt.switch_backend("agg")

    cfg = load_config()
    id_col = yaml.safe_load(Path("params.yaml").read_text(encoding="utf-8"))["prepare"]["id_column"]
    model, threshold, version = load_champion()
    X_train, _ = cfg.read_xy(TRAIN_CSV)
    X_test, _ = cfg.read_xy(TEST_CSV)
    ids = pd.read_csv(TEST_CSV, usecols=[id_col])[id_col].to_numpy()
    proba = model.predict_proba(X_test)[:, 1]

    if args.id is not None:
        if args.id not in ids:
            raise SystemExit(f"Demande {args.id} absente de {TEST_CSV}")
        cases = {f"demande_{args.id}": int(np.flatnonzero(ids == args.id)[0])}
    else:
        cases = pick_cases(proba, threshold)
    rows = X_test.iloc[list(cases.values())]
    _, by_feature, _ = explain(cfg, model, rows, X_train)
    space = output_space(model, rows, by_feature)
    # Le seuil, exprimé dans l'unité des contributions (log-odds pour une régression logistique)
    cut = threshold if space == "probabilité" else float(logit(threshold))

    REPORTS.mkdir(exist_ok=True)
    lines = [f"# Explications individuelles — {cfg.name}, modèle v{version}", ""]
    lines += [f"Seuil de refus : P({cfg.positive_class}) >= {threshold:.3f}.", ""]
    for k, (case, pos) in enumerate(cases.items()):
        contrib = by_feature[k]
        decision = "REFUS" if proba[pos] >= threshold else "ACCORD"
        against, favour = reasons(cfg, contrib)
        flips = counterfactual_flips(cfg, model, X_train, X_test.iloc[[pos]], threshold)
        flip_text = ", ".join(flips) or "aucun"
        p = proba[pos]
        title = f"{case} — demande {ids[pos]} : P({cfg.positive_class}) = {p:.3f} → {decision}"
        print(f"\n{title}")
        for label, items in (("vers le refus", against), ("vers l'accord", favour)):
            print(f"  {label:<14}: " + ("\n" + " " * 18).join(items or ["—"]))
        print(f"  bascule si l'on change seulement : {flip_text}")
        lines += [f"## {title}", "", "Principaux motifs défavorables :", ""]
        lines += [f"- {r}" for r in against] or ["- aucun"]
        lines += ["", "Principaux éléments favorables :", ""]
        lines += [f"- {r}" for r in favour] or ["- aucun"]
        lines += ["", f"Test contrefactuel (un seul attribut sensible modifié) : {flip_text}."]
        lines += ["", f"![waterfall](shap_waterfall_{case}.png)", ""]

        plt.figure()
        shap.plots.waterfall(contrib, max_display=10, show=False)
        plt.axvline(cut, color="black", linestyle="--", linewidth=1)
        plt.title(f"{case} : {decision} (seuil en pointillés, {space})")
        plt.savefig(REPORTS / f"shap_waterfall_{case}.png", dpi=150, bbox_inches="tight")
        plt.close()

    (REPORTS / "explanations_local.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"\n-> {len(cases)} waterfall(s) + {REPORTS}/explanations_local.md")


if __name__ == "__main__":
    main()
```

```bash
uv run python -m governance.explain_local
ls reports/shap_waterfall_*.png
```

> **Sortie attendue :**

```text

refus_net — demande 819 : P(bad) = 0.930 → REFUS
  vers le refus : credit_amount = 15857 (+1.18)
                  checking_status = <0 (+0.63)
                  personal_status = male div/sep (+0.40) [attribut sensible]
  vers l'accord : installment_commitment = 2 (-0.27)
                  other_payment_plans = none (-0.14)
                  purpose = other (-0.13)
  bascule si l'on change seulement : aucun

acceptation_nette — demande 160 : P(bad) = 0.033 → ACCORD
  vers le refus : num_dependents = 2 (+0.18)
                  own_telephone = none (+0.12)
                  existing_credits = 2 (+0.07)
  vers l'accord : checking_status = no checking (-0.68)
                  installment_commitment = 1 (-0.54)
                  savings_status = no known savings (-0.53)
  bascule si l'on change seulement : aucun

cas_limite — demande 278 : P(bad) = 0.317 → ACCORD
  vers le refus : checking_status = <0 (+0.63)
                  personal_status = male div/sep (+0.40) [attribut sensible]
                  credit_history = existing paid (+0.15)
  vers l'accord : savings_status = no known savings (-0.53)
                  installment_commitment = 2 (-0.27)
                  duration = 12 (-0.22)
  bascule si l'on change seulement : age -> <25

-> 3 waterfall(s) + reports/explanations_local.md
reports/shap_waterfall_acceptation_nette.png
reports/shap_waterfall_cas_limite.png
reports/shap_waterfall_refus_net.png
```

Dans chaque waterfall, la ligne pointillée est le seuil de refus (0,318, soit −0,76 en
log-odds) : la demande est refusée si la somme des contributions la fait passer à droite.
Deux constats pour l'audit : `personal_status` figure parmi les trois motifs du refus le plus
net, et pour le **cas limite** (demande 278, 49 ans, accordée de justesse), **le seul fait
d'avoir moins de 25 ans** suffirait à faire refuser le crédit. C'est un traitement
différencié direct, à justifier ou à corriger.

> [!IMPORTANT]
> **RGPD article 22 : le droit à l'explication**
> Une décision fondée exclusivement sur un traitement automatisé et produisant des effets
> juridiques (refuser un crédit) est encadrée par l'article 22 du RGPD : intervention humaine,
> droit d'exprimer son point de vue et de contester. La Cour de justice de l'UE a jugé que le
> calcul d'un score de crédit sur lequel le prêteur s'appuie de manière déterminante **est**
> une telle décision (C-634/21, SCHUFA, 7 décembre 2023), et que l'explication de la « logique
> sous-jacente » doit être compréhensible par la personne, pas une formule (C-203/22, 27
> février 2025). `explanations_local.md` est le brouillon de cette explication ; SHAP décrit
> le modèle, pas une causalité.

## Étape 6/9 — Générer la Model Card (25 min)

### 6.1 Le modèle de document

La Model Card (Mitchell et al., 2019) est la documentation standard d'un modèle : neuf
sections, chacune alimentée par vos rapports. On y ajoute deux sections exigées par le
contexte (sécurité de la chaîne, cadre réglementaire). Partez du squelette fourni :

```bash
cp labs/m8-governance/starter/model-card.md model-card/model-card.md
grep "^## " model-card/model-card.md
```

> **Sortie attendue :** les 11 titres de sections, de `## 1. Détails du modèle` à
> `## 11. Cadre réglementaire`.

| Section | Contenu attendu | Source |
|---|---|---|
| 1. Détails du modèle | nom, version, run, type, seuil, artefacts, traçabilité, licence | MLflow, `metadata.json` |
| 2. Usage prévu | usage primaire, utilisateurs, **usages interdits** | décision du binôme |
| 3. Facteurs | attributs sensibles, proxies, facteurs d'environnement | `dataset.yaml`, `fairness_mitigated.json` |
| 4. Métriques | globales au seuil + par groupe + indicateurs d'équité | `metrics.json`, `fairness_baseline.json` |
| 5. Données d'évaluation | taille, tirage, effectifs par groupe, limites | `dataset.yaml`, étape 3 |
| 6. Données d'entraînement | source, période, licence, représentativité, qualité | `dataset.yaml`, étape 3 |
| 7. Analyse quantitative | disparités, atténuations comparées, décision, SHAP | étapes 3 à 5 |
| 8. Considérations éthiques | biais historiques, discrimination, coût social | analyse du binôme |
| 9. Mises en garde | ce qu'il ne faut pas faire, prérequis d'un usage réel | analyse du binôme |
| 10. Sécurité de la chaîne | Trivy, ModelScan, RBAC, secrets | étapes 1, 2, 7, 8 |
| 11. Cadre réglementaire | AI Act, RGPD | étape 9 |

### 6.2 Des tableaux générés, pas recopiés

Recopier des chiffres à la main, c'est fabriquer une documentation fausse au prochain
entraînement. Générez les tableaux par groupe depuis le rapport JSON et collez-les en
section 4 :

```bash
uv run python - <<'EOF'
import json

report = json.load(open("reports/fairness_baseline.json"))
print(f"Modèle v{report['model_version']}, seuil {report['decision_threshold']}")
for attr, a in report["attributes"].items():
    print(f"\n#### {attr}\n")
    print("| Groupe | n | Défaut réel | Refus [IC 95 %] | TPR | FPR | Coût/demande |")
    print("|---|---|---|---|---|---|---|")
    for g, m in a["groups"].items():
        print(f"| {g} | {m['n']:.0f} | {m['taux_defaut']:.0%} | {m['taux_refus']:.0%} "
              f"[{m['refus_ic95_bas']:.0%} ; {m['refus_ic95_haut']:.0%}] | {m['TPR']:.0%} "
              f"| {m['FPR']:.0%} | {m['cout_moyen']:.2f} |")
EOF
```

> **Sortie attendue (extrait) :**

```text
Modèle v3, seuil 0.3182

#### age

| Groupe | n | Défaut réel | Refus [IC 95 %] | TPR | FPR | Coût/demande |
|---|---|---|---|---|---|---|
| <25 | 39 | 49% | 77% [63% ; 90%] | 95% | 60% | 0.44 |
| >=25 | 161 | 25% | 60% [52% ; 67%] | 85% | 51% | 0.57 |
```

Complétez ensuite chaque section (remplacez tous les `TODO`). Exemple de section 7 attendue,
extrait du corrigé :

```markdown
**Atténuation** (`reports/fairness_mitigated.txt`, attribut `age`) :

| Stratégie | Coût | Δ coût | Écart de parité | Ratio d'acceptation | Écart EO | Attribut en production |
|---|---|---|---|---|---|---|
| Champion | 108 | — | 0,173 | 0,57 | 0,094 | oui |
| Sans la colonne `age` | 111 | +2,8 % | 0,154 | 0,60 | 0,094 | non |
| ThresholdOptimizer, objectif coût | 114 | +5,6 % | 0,083 | 0,80 | 0,012 | oui |
| ExponentiatedGradient, objectif coût | 116 | +7,4 % | 0,065 | 0,83 | 0,118 | non |

- **Décision** : pas de mitigation déployée dans ce prototype ; recommandation d'un
  ré-entraînement sous contrainte (in-processing) validé sur davantage de données.
```

> [!TIP]
> **Usages interdits : soyez précis**
> « Ne pas utiliser en production » ne sert à rien. Écrivez ce qu'un utilisateur pourrait
> être tenté de faire : décider automatiquement d'un refus, fixer un taux ou un plafond,
> appliquer le modèle à une autre population (autre pays, autre époque), utiliser les
> attributs sensibles pour cibler un groupe, réutiliser le modèle pour l'assurance ou le
> logement.

### 6.3 Génération automatisée (alternative)

Le *Model Card Toolkit* de Google cité par l'énoncé d'origine n'est plus maintenu. La pratique
actuelle est de **générer** la Model Card dans la CI à chaque nouveau champion : les tableaux
de l'étape 6.2 (et ceux des métriques globales) remplissent un gabarit Markdown, le texte
d'analyse reste écrit par l'équipe. Pour ce lab, la Model Card complétée à la main à partir
des tableaux générés suffit ; l'automatisation est proposée dans « Pour aller plus loin ».

## Étape 7/9 — RBAC Kubernetes minimal (15 min)

L'API de scoring n'appelle jamais l'API Kubernetes : son identité ne doit donner **aucun**
droit superflu. Par défaut, ses pods tournent avec le ServiceAccount `default` du namespace et
reçoivent un jeton d'API monté dans `/var/run/secrets/kubernetes.io/serviceaccount` :
inutile, donc dangereux.

```yaml
# Fichier : k8s/rbac-scoring.yaml
# Identité minimale de l'API de scoring (InferenceService du Lab 5, namespace scoring).
# Principe du moindre privilège : l'API ne fait qu'exécuter un modèle ONNX ; elle n'a
# besoin de RIEN sur l'API Kubernetes. Le Role ci-dessous n'autorise que la lecture d'UN
# Secret nommé (les identifiants S3, si un composant du pod doit un jour les relire) :
# pas de list/watch (impossible d'énumérer les secrets), pas de create/delete, pas de « * ».
apiVersion: v1
kind: ServiceAccount
metadata:
  name: scoring-sa
  namespace: scoring
  labels:
    app.kubernetes.io/part-of: scoring
# Défense en profondeur : aucun jeton d'API monté dans les pods de l'API de scoring.
# Un attaquant qui prendrait le contrôle du conteneur n'aurait aucun identifiant
# Kubernetes à réutiliser. (Un pod qui en aurait besoin le réactive dans son spec.)
automountServiceAccountToken: false
# KServe lit ce Secret (via le ServiceAccount) quand un modèle est téléchargé depuis S3
# (storageUri s3://…) : c'est le Secret synchronisé par External Secrets (étape 8).
secrets:
  - name: s3-credentials
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: scoring-reader
  namespace: scoring
rules:
  # Lire SES identifiants S3, et seulement eux (resourceNames).
  # PAS de 'list', 'watch', 'create', 'update', 'delete' ni de '*'.
  - apiGroups: [""]
    resources: [secrets]
    verbs: [get]
    resourceNames: [s3-credentials]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: scoring-reader-binding
  namespace: scoring
subjects:
  - kind: ServiceAccount
    name: scoring-sa
    namespace: scoring
roleRef:
  kind: Role
  name: scoring-reader
  apiGroup: rbac.authorization.k8s.io
```

Le ServiceAccount, le Role et le RoleBinding se créent directement (ils ne font pas partie
des Applications Argo CD du Lab 6) :

```bash
kubectl apply -f k8s/rbac-scoring.yaml
kubectl get serviceaccount scoring-sa -n scoring
```

Reste à faire tourner l'API de production sous cette identité. Depuis le Lab 6,
l'InferenceService `scoring-model` est **géré par Argo CD** (Application `scoring-prod`, avec
auto-réparation) : un `kubectl patch` serait annulé à la synchronisation suivante. Le
changement passe donc par **Git**, dans l'overlay de production : pas dans `k8s/base/`, car
staging tourne dans le namespace `scoring-staging`, où `scoring-sa` n'existe pas. Ajoutez ce
second patch à la fin de `k8s/overlays/prod/kustomization.yaml`, sous `patches:` (après
`- path: canary.yaml`), sans toucher à `newName` ni à `newTag` (écrits par la CI et par
l'outil GitOps) :

```yaml
  # Lab 8 : identité minimale de l'API (ServiceAccount de k8s/rbac-scoring.yaml, appliqué
  # avant ce commit). En prod seulement : scoring-sa n'existe que dans le namespace scoring.
  # Dans Git, pas par kubectl patch : Argo CD (selfHeal) annulerait la modification.
  - target:
      kind: InferenceService
      name: scoring-model
    patch: |-
      - op: add
        path: /spec/predictor/serviceAccountName
        value: scoring-sa
```

Vérifiez le rendu (les tests du Lab 6 vérifient aussi les overlays), commitez sur la branche
du lab, et vérifiez ce que l'identité peut, et ne peut pas, faire :

```bash
kubectl kustomize k8s/overlays/prod | grep serviceAccountName
uv run pytest -q tests/test_k8s.py
git add k8s/rbac-scoring.yaml k8s/overlays/prod/kustomization.yaml
git commit -m "feat(k8s): ServiceAccount minimal scoring-sa pour l'API de prod (Lab 8)"

SA=system:serviceaccount:scoring:scoring-sa
kubectl auth can-i create pods --as=$SA -n scoring
kubectl auth can-i list secrets --as=$SA -n scoring
kubectl auth can-i get secret/s3-credentials --as=$SA -n scoring
kubectl auth can-i get secret/s3-credentials --as=$SA -n storage
```

> **Sortie attendue :** `serviceAccountName: scoring-sa` dans le rendu, les tests de
> `test_k8s.py` au vert, puis `no`, `no`, `yes`, `no`. Le ServiceAccount `scoring-sa` n'a que
> les droits stricts : lire **un** Secret nommé de son namespace. Il ne peut ni créer de pods,
> ni énumérer les secrets, ni lire ceux d'un autre namespace.

Ce commit n'est **pas encore en production** : Argo CD lit `main`, et la branche du lab n'y
arrivera qu'à la fusion de sa pull request (étape 9). C'est le GitOps : un changement de
production est relu avant d'être appliqué. L'étape 9 vérifie la nouvelle révision.

> [!NOTE]
> **Et la part du canary ?**
> Changer le ServiceAccount crée une nouvelle révision, qui reçoit la part fixée par
> `k8s/overlays/prod/canary.yaml`. À la fin du Lab 7, elle vaut `100` (dernière promotion) :
> la nouvelle révision reçoit tout le trafic. Si un canary est encore en cours
> (`uv run python -m pipelines.gitops status`), terminez-le d'abord par un commit depuis
> `main` (`gitops promote --push` ou `gitops rollback --push`). Le dossier `k8s/` ne fait pas
> partie des chemins surveillés par la CI : la fusion ne reconstruira pas d'image.

## Étape 8/9 — ExternalSecret pour les identifiants S3 (15 min)

Au Lab 5, le Secret `s3-credentials` du namespace `scoring` a été créé à la main depuis
`.env`. Ça marche, mais : qui l'a créé, avec quelle valeur, comment le faire tourner ? En
production, les secrets vivent dans un coffre (Vault, AWS Secrets Manager, GCP Secret
Manager…) et un opérateur les recopie dans Kubernetes : **External Secrets Operator** (ESO).

> [!NOTE]
> **Le nom du fichier**
> `k8s/mlflow-creds-source.yaml` garde le nom de l'énoncé d'origine, qui distribuait des
> identifiants MLflow et S3. Depuis le Lab 0, les clients MLflow n'ont plus besoin
> d'identifiants (le serveur fait proxy des artefacts) : le seul secret à distribuer est la
> paire de clés S3 (SeaweedFS).

### 8.1 Installer External Secrets Operator

```bash
make external-secrets
kubectl get pods -n external-secrets
```

> **Sortie attendue :** trois déploiements prêts : `external-secrets` (le contrôleur),
> `external-secrets-webhook` et `external-secrets-cert-controller`, puis la ligne
> `API servies : v1` : l'ancienne API `v1beta1` n'est plus servie par défaut (les manifests
> écrits pour elle doivent passer en `external-secrets.io/v1`).

### 8.2 Un « coffre » simulé : le namespace storage

Le Secret `s3-credentials` du namespace `storage` (créé au Lab 0, tenu par « l'équipe
plateforme ») joue le rôle du coffre : c'est la **source de vérité**. ESO le lit avec une
identité dédiée, autorisée à lire ce seul Secret, et le recopie dans `scoring`. Aucune valeur
secrète n'apparaît dans le manifest : vous pouvez le committer.

```yaml
# Fichier : k8s/mlflow-creds-source.yaml
# Identifiants S3 du cours synchronisés par External Secrets Operator (ESO) dans le
# namespace scoring — au lieu d'un Secret écrit en clair dans un manifest versionné.
#
# Le « coffre-fort » est simulé par le namespace storage : son Secret s3-credentials
# (Lab 0) fait office de source de vérité, tenue par l'équipe plateforme. En production,
# seul le bloc `provider` du SecretStore change (vault, aws, gcpsm, azurekv…) : les
# ExternalSecret et les applications restent identiques. AUCUNE valeur secrète ici.
#
# 1. Une identité dédiée à ESO, autorisée à LIRE un seul Secret du namespace storage.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: eso-s3-reader
  namespace: scoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: eso-s3-reader
  namespace: storage
rules:
  - apiGroups: [""]
    resources: [secrets]
    verbs: [get]
    resourceNames: [s3-credentials]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: eso-s3-reader
  namespace: storage
subjects:
  - kind: ServiceAccount
    name: eso-s3-reader
    namespace: scoring  # identité d'un autre namespace : c'est permis
roleRef:
  kind: Role
  name: eso-s3-reader
  apiGroup: rbac.authorization.k8s.io
---
# 2. Le SecretStore : « où et comment lire les secrets » (provider kubernetes).
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: course-secrets
  namespace: scoring
spec:
  provider:
    kubernetes:
      remoteNamespace: storage  # le « coffre » : seul namespace lisible par ce store
      server:
        url: https://kubernetes.default.svc
        caProvider:  # CA de l'API Kubernetes, publiée dans chaque namespace
          type: ConfigMap
          name: kube-root-ca.crt
          key: ca.crt
      auth:
        serviceAccount:
          name: eso-s3-reader  # ESO demande un jeton éphémère pour cette identité
---
# 3. L'ExternalSecret : « quelles clés copier, vers quel Secret, à quelle fréquence ».
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: s3-credentials
  namespace: scoring
spec:
  refreshInterval: 1m  # 1h en production ; court ici pour voir la resynchronisation
  secretStoreRef:
    kind: SecretStore
    name: course-secrets
  target:
    name: s3-credentials  # Secret créé (et possédé) par ESO dans le namespace scoring
    creationPolicy: Owner
    template:
      metadata:
        annotations:  # lues par KServe pour télécharger un modèle depuis SeaweedFS
          serving.kserve.io/s3-endpoint: s3.storage:8333
          serving.kserve.io/s3-usehttps: "0"
          serving.kserve.io/s3-region: us-east-1
  data:
    - secretKey: AWS_ACCESS_KEY_ID
      remoteRef:
        key: s3-credentials
        property: AWS_ACCESS_KEY_ID
    - secretKey: AWS_SECRET_ACCESS_KEY
      remoteRef:
        key: s3-credentials
        property: AWS_SECRET_ACCESS_KEY
```

```bash
kubectl apply -f k8s/mlflow-creds-source.yaml
kubectl wait --for=condition=Ready secretstore/course-secrets -n scoring --timeout=60s
kubectl wait --for=condition=Ready externalsecret/s3-credentials -n scoring --timeout=60s
kubectl get secretstore,externalsecret -n scoring
kubectl get secret s3-credentials -n scoring \
  -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}{.metadata.annotations}{"\n"}'
```

> **Sortie attendue :** le SecretStore `course-secrets` est `Valid` / `ReadWrite` /
> `True` ; l'ExternalSecret `s3-credentials` est en état **`SecretSynced`**, `READY True`. Le
> Secret `s3-credentials` du namespace `scoring` appartient désormais à l'ExternalSecret
> (`ExternalSecret`) et porte les annotations `serving.kserve.io/s3-*`. S'il existait déjà
> (créé à la main au Lab 5), ESO en a pris possession.

### 8.3 Voir l'opérateur à l'œuvre

```bash
# Les valeurs sont identiques à la source…
for ns in storage scoring; do
  kubectl get secret s3-credentials -n $ns -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' \
    | base64 -d; echo " ($ns)"
done
# … et un Secret supprimé est recréé par l'opérateur
kubectl delete secret s3-credentials -n scoring
sleep 10 && kubectl get secret s3-credentials -n scoring
kubectl get externalsecret s3-credentials -n scoring
```

> **Sortie attendue :** `mlops (storage)` puis `mlops (scoring)` ; après la suppression, le
> Secret réapparaît (`AGE` de quelques secondes ; au plus tard au prochain `refreshInterval`,
> 1 minute) et l'ExternalSecret reste `SecretSynced`. Pour une rotation, on change la valeur
> **dans le coffre** : chaque namespace consommateur est mis à jour au prochain
> `refreshInterval`.

## Étape 9/9 — Rapport de conformité AI Act (10 min)

Créez `reports/compliance-ai-act.md` à partir du squelette fourni, en cinq sections (plus les
sources) :

```bash
cp labs/m8-governance/starter/compliance-ai-act.md reports/compliance-ai-act.md
```

- **Classification du risque** : en usage pédagogique, aucune obligation (rien n'est mis sur
  le marché). Mais déployé pour décider de vrais crédits, ce système serait **à haut
  risque** : l'annexe III de l'AI Act (règlement (UE) 2024/1689, point 5 b) vise
  explicitement les systèmes destinés à évaluer la solvabilité des personnes physiques ou à
  établir leur score de crédit (sauf détection de fraude).
- **Checklist AI Act** : tableau obligation / comment on la remplit ici / preuve (gestion des
  risques, données, documentation technique, journaux, transparence, contrôle humain,
  exactitude-robustesse-cybersécurité).
- **Preuves produites** : rapports Trivy et ModelScan, rapports d'équité (avant/après),
  graphiques SHAP et explications locales, Model Card, manifests RBAC et ExternalSecret.
- **Écarts** : ce qu'on ne peut pas prouver automatiquement (supervision humaine, comité
  d'éthique, conservation de la documentation 10 ans, analyse d'impact).
- **Recommandations** : pour passer en haut risque réel, ajouter une AIPD (RGPD art. 35),
  l'analyse d'impact sur les droits fondamentaux (AI Act art. 27, obligatoire pour les
  déployeurs d'un système de scoring de crédit), l'enregistrement dans la base de l'UE, un
  audit annuel.

> [!IMPORTANT]
> **Où en est le calendrier de l'AI Act (octobre 2026) ?**
> Interdictions (art. 5) : applicables depuis le 2 février 2025. Modèles d'IA à usage général :
> 2 août 2025. Transparence (art. 50) : 2 août 2026. Le règlement « Digital Omnibus »
> (UE) 2026/1744, publié au Journal officiel le 24 juillet 2026, a **reporté** les obligations
> des systèmes à haut risque de l'annexe III — dont le scoring de crédit — au **2 décembre
> 2027** (2 août 2028 pour l'annexe I) ; voir la
> [synthèse de Cooley](https://cdp.cooley.com/digital-ai-omnibus-delays-key-deadlines-introduces-new-rules/).
> Le report ne change rien au RGPD (art. 22 applicable depuis 2018) ni à la directive
> (UE) 2023/2225 sur le crédit aux consommateurs, applicable à partir du 20 novembre 2026
> (droit à une intervention humaine en cas d'évaluation automatisée de la solvabilité).
> Vérifiez toujours les dates à la source le jour où vous écrivez le rapport.

Enfin, committez l'audit (sans les pickles de démonstration), poussez la branche et ouvrez la
pull request :

```bash
git add governance model-card k8s packaging/Dockerfile.distroless \
  packaging/Dockerfile.distroless.dockerignore reports \
  ':(exclude)packaging/scan-demo/*.pkl'
git commit -m "feat(lab8): audit de gouvernance (sécurité, équité, SHAP, Model Card, RBAC, ESO)"
git push -u origin lab/m8-governance
gh pr create
```

Votre partenaire relit la PR : la Model Card, le rapport de conformité, et le changement de
production de l'étape 7 (`k8s/overlays/prod/kustomization.yaml`). Après approbation et fusion,
Argo CD applique le nouveau ServiceAccount en moins d'une minute (Lab 6, étape 3.1) ;
l'annotation `refresh` évite d'attendre :

```bash
git switch main && git pull
kubectl annotate application scoring-prod -n argocd argocd.argoproj.io/refresh=normal \
  --overwrite
kubectl wait isvc/scoring-model -n scoring --timeout=180s \
  --for=jsonpath='{.spec.predictor.serviceAccountName}'=scoring-sa
kubectl wait --for=condition=Ready isvc/scoring-model -n scoring --timeout=180s
POD=$(kubectl get pods -n scoring -l serving.kserve.io/inferenceservice=scoring-model \
  --sort-by=.metadata.creationTimestamp -o name | tail -1)
kubectl get "$POD" -n scoring -o jsonpath='{.spec.serviceAccountName}{"\n"}'
kubectl get "$POD" -n scoring -o yaml | grep -c kube-api-access  # 0 : aucun jeton monté
```

> **Sortie attendue :** le pod de la nouvelle révision tourne avec `scoring-sa` et aucun volume
> `kube-api-access` n'est monté (`0`).

> [!NOTE]
> **Second membre du binôme (ou nouveau poste) : remettre votre cluster à niveau**
> Le ServiceAccount de la prod vous parvient par Git et Argo CD, une fois les objets RBAC
> créés sur **votre** cluster (Labs 5 à 7 à niveau). Les rapports, la Model Card et le
> rapport de conformité sont ceux du binôme, commités ; reconstruisez l'image durcie et
> installez External Secrets :
>
> ```bash
> cd ~/mlops-cours-2026 && git switch main && git pull && uv sync
> source .venv/bin/activate && set -a && source .env && set +a
> kubectl apply -f k8s/rbac-scoring.yaml
> kubectl annotate application scoring-prod -n argocd argocd.argoproj.io/refresh=normal \
>   --overwrite
> MODEL_VERSION=$(uv run python -c \
>     "import json; print(json.load(open('packaging/model/metadata.json'))['model_version'])")
> docker build -f packaging/Dockerfile.distroless -t scoring-api:distroless \
>     --build-arg VERSION=1.0.0 --build-arg MODEL_VERSION="$MODEL_VERSION" .
> uv run python packaging/scan-demo/make_pickles.py
> make external-secrets
> kubectl apply -f k8s/mlflow-creds-source.yaml
> make check-m8
> ```
>
> L'image distroless demande un compte Docker (`docker login dhi.io`, étape 1.3). Les rapports
> d'équité commités auditent le champion du MLflow de votre partenaire : sur votre cluster,
> l'item « Rapport d'équité = champion actuel » reste rouge tant que vous ne relancez pas
> `uv run python -m governance.fairness_analysis` (audit de **votre** champion, mêmes chiffres
> si le modèle est le même). Laissez alors les rapports réécrits modifiés en local, sans les
> commiter, comme le `dvc.lock` du Lab 1.

## Checklist de validation

| # | Élément | Test | Résultat attendu | OK |
|---|---|---|---|---|
| 1 | Trivy scan baseline | `grep "^Total" reports/trivy_critical.txt` | CVE listées | ☐ |
| 2 | Image distroless construite | `docker run --rm --entrypoint python scoring-api:distroless --version` | `Python 3.12.x`, sans shell | ☐ |
| 3 | Trivy distroless : CVE réduites | `grep "^Total" reports/trivy_distroless.txt` | ≪ baseline (OS) | ☐ |
| 4 | ModelScan pickle | `grep CRITICAL reports/modelscan_pickle.txt` | 1 CRITICAL (`posix.system`) | ☐ |
| 5 | ModelScan ONNX OK | `grep 'No issues' reports/modelscan_onnx.txt` | 1 occurrence | ☐ |
| 6 | Fairlearn baseline | `cat reports/fairness_baseline.txt` | 1 tableau par attribut sensible | ☐ |
| 7 | Disparités mesurées | `grep 'Demographic Parity' reports/fairness_baseline.txt` | valeurs affichées | ☐ |
| 8 | Atténuations comparées | `cat reports/fairness_mitigated.txt` | 5 stratégies + proxy par attribut | ☐ |
| 9 | SHAP importance globale | `ls reports/shap_summary_bar.png` | fichier présent | ☐ |
| 10 | SHAP beeswarm | `ls reports/shap_beeswarm.png` | fichier présent | ☐ |
| 11 | 3 explications locales | `ls reports/shap_waterfall_*.png` | 3 fichiers + `explanations_local.md` | ☐ |
| 12 | Model Card | `grep -c '^## ' model-card/model-card.md` | 11 sections, aucun `TODO` | ☐ |
| 13 | RBAC appliqué | `kubectl auth can-i create pods --as=system:serviceaccount:scoring:scoring-sa -n scoring` | `no` | ☐ |
| 14 | API de prod sous `scoring-sa` (via Git) | `kubectl get isvc scoring-model -n scoring -o jsonpath='{.spec.predictor.serviceAccountName}'` | `scoring-sa` | ☐ |
| 15 | ExternalSecret synchronisé | `kubectl get externalsecret -n scoring` | `SecretSynced`, `True` | ☐ |
| 16 | Rapport de conformité | `grep -c '^## ' reports/compliance-ai-act.md` | 5 sections + sources | ☐ |

## Critères d'évaluation (noté sur 10)

| Critère | Description | Points |
|---|---|---|
| Sécurité | Trivy avant/après, image distroless construite (Python 3.12, non-root, sans shell), ModelScan interprété (codes retour, skops), RBAC et ExternalSecret appliqués. | 2,5 |
| Équité | Mesures Fairlearn pour chaque attribut sensible de `dataset.yaml` au seuil du modèle, petits groupes signalés, atténuations comparées et compromis coût/équité argumenté (dont l'expérience « sans l'attribut »). | 2,5 |
| Explicabilité | Importance globale + 3 explications locales cohérentes, motifs rédigés en clair, test contrefactuel interprété. | 2,5 |
| Gouvernance | Model Card complète (11 sections, chiffres réels, usages interdits précis), rapport AI Act / RGPD daté et sourcé. | 2,5 |
| **Total** | | **10** |

## Annexe — Troubleshooting

| Symptôme | Cause probable | Solution |
|---|---|---|
| Trivy : `TOOMANYREQUESTS` au téléchargement de la base | Limite de débit du registre de la base de vulnérabilités. | Relancer plus tard ; la base est en cache dans le volume `trivy-cache` : `--skip-db-update` réutilise le cache local. |
| Trivy : `unable to find the specified image` | Image absente du démon Docker local (Trivy lit le démon via le socket). | `docker pull localhost:5001/scoring-api:1.0.0`, puis relancer le scan. |
| `docker build` : `unauthorized` / `pull access denied` sur `dhi.io` | Pas connecté au registre DHI. | `docker login dhi.io` avec votre identifiant Docker et un jeton d'accès personnel. |
| distroless : `ModuleNotFoundError` au démarrage | Venv non copié, ou builder et runtime avec des Python différents. | Vérifier `COPY --from=builder /opt/venv /opt/venv`, `ENV PATH` et les deux `FROM` en `3.12-debian13`. |
| `docker exec … sh` : `executable file not found` | Normal : l'image distroless n'a pas de shell. | Déboguer avec `docker run --rm --entrypoint python scoring-api:distroless -c "…"` ou une image `-dev`. |
| ModelScan : `No issues found` mais rien d'analysé | Format non pris en charge (ONNX, skops) : fichier « skipped », code retour 3. | `--show-skipped` ; pour skops, `skops.io.get_untrusted_types`. |
| ModelScan : `argument of type 'NoneType' is not iterable` | Pickle écrit par joblib (bug de ModelScan 0.8.8). | Produire le pickle avec `pickle.dump` (c'est ce que fait `make_pickles.py`). |
| `MlflowException: Registered model alias champion not found` | Lab 1 non terminé ou port-forward MLflow arrêté. | `make pf`, puis vérifier l'alias dans l'UI MLflow (`http://localhost:5000`). |
| `KeyError: 'decision_threshold'` | Champion entraîné avant l'ajout du paramètre au Lab 1. | Ré-entraîner (`dvc repro`) puis `python -m src.promote`. |
| `ModuleNotFoundError: No module named 'governance'` | Script lancé par son chemin, ou hors de la racine. | Depuis la racine : `uv run python -m governance.fairness_analysis`. |
| Fairlearn : `ValueError` sur les `sensitive_features` | Attribut sensible absent du jeu de test ou `bins` qui ne couvrent pas toutes les valeurs (NaN). | Vérifier `sensitive` dans `dataset.yaml` ; les `bins` doivent englober min et max. |
| Un groupe affiche des taux à 0 % ou 100 % | Groupe minuscule (quelques demandes). | Lire l'IC 95 % et l'alerte « moins de 30 demandes » : non concluant, à documenter. |
| ThresholdOptimizer : `not binary` ou forme inattendue | `predict_proba` ne renvoie pas `(n, 2)`. | Le modèle doit être un classifieur binaire (cible encodée 0/1 par `cfg.split_xy`). |
| SHAP : `Additivity check failed in TreeExplainer` | Explainer « interventionnel » (avec données de fond) sur des arbres scikit-learn (SHAP 0.52). | `explain.py` utilise `shap.TreeExplainer(modèle)` sans données de fond (calcul exact sur les arbres). |
| SHAP waterfall : `IndexError` ou valeurs 3D | Classifieur à deux sorties : valeurs `(n, colonnes, 2)`. | Prendre la classe positive (`sv[..., 1]`), comme dans `explain()`. |
| `RoleBinding` refusé ou sans effet | Namespace incorrect. | Le RoleBinding doit être dans le même namespace que le Role ; le sujet peut être d'un autre namespace. |
| `kubectl patch isvc` sans effet durable | Argo CD (Lab 6) ré-applique le manifest de Git. | Modifier `k8s/overlays/prod/kustomization.yaml` (étape 7) et fusionner la PR du lab (étape 9). |
| ISVC toujours sur `default` après la fusion | PR pas encore fusionnée dans `main`, Argo CD pas encore synchronisé, ou patch mal indenté (Application en erreur). | `kubectl kustomize k8s/overlays/prod \| grep serviceAccountName` ; `kubectl get application scoring-prod -n argocd` (`Synced`) ; annotation `refresh` de l'étape 9. |
| ExternalSecret : `SecretSyncedError` | SecretStore invalide ou droits de lecture manquants. | `kubectl describe externalsecret s3-credentials -n scoring` ; `kubectl describe secretstore course-secrets -n scoring` ; vérifier le Role `eso-s3-reader` du namespace `storage`. |
| SecretStore : `could not verify if client is valid` | ESO n'obtient pas de jeton pour `eso-s3-reader`, ou CA non trouvée. | Vérifier que le ServiceAccount existe dans `scoring` et la ConfigMap `kube-root-ca.crt`. |
| `no matches for kind "ExternalSecret" in version "external-secrets.io/v1beta1"` | Ancien manifest : `v1beta1` n'est plus servie. | Utiliser `apiVersion: external-secrets.io/v1`. |
| `auth can-i` : `yes` sur `create pods` | Test lancé avec votre identité, ou droits hérités d'un ClusterRoleBinding. | Tester avec `--as=system:serviceaccount:scoring:scoring-sa` ; `kubectl get clusterrolebinding -o wide \| grep scoring-sa`. |

## Pour aller plus loin

- **Documentation exécutable** : un script `governance/model_card.py` qui remplit les
  tableaux de la Model Card depuis les rapports JSON, lancé par la CI (Lab 6) à chaque
  nouveau champion ; l'audit d'équité devient une gate (échec si le ratio d'acceptation passe
  sous 0,8 pour un groupe d'au moins 30 demandes).
- **Intersectionnalité** : passer deux colonnes à `sensitive_features` (âge × statut
  personnel) — et constater que les effectifs fondent.
- **Explications contrefactuelles** : « que faudrait-il changer pour que la demande soit
  acceptée ? » (bibliothèques DiCE, alibi) — souvent plus utiles au demandeur qu'un waterfall.
- **Signature et provenance** : signer l'image distroless avec Cosign (keyless) et vérifier la
  signature avant le déploiement ; exiger un SBOM (`trivy image --format cyclonedx`).
- **Pod Security Admission** : étiqueter le namespace `scoring` en
  `pod-security.kubernetes.io/warn=restricted` et corriger le `securityContext` des pods
  (`runAsNonRoot`, `readOnlyRootFilesystem`, `capabilities.drop: [ALL]`).
- **Suivi en production** : exporter les taux d'acceptation par groupe en métriques
  Prometheus (Lab 7) et alerter sur la dérive de l'équité.

> [!NOTE]
> **Prochaine étape**
> Module 9 — LLMOps. Vous allez adapter tout ce qu'on a vu au cas des grands modèles de
> langage : serving local, base vectorielle pour le RAG, observabilité des chaînes. Les
> problématiques de gouvernance de ce module y sont encore plus critiques : hallucinations,
> injections de prompt, confidentialité des documents.

## Vérification automatique

```bash
make check-m8
```

Le script `labs/m8-governance/check.sh` vérifie, en lisant `dataset.yaml` (aucun nom de
colonne en dur) :

- **Sécurité** : rapports Trivy (baseline et distroless, CVE distroless ≤ baseline), image
  `scoring-api:distroless` présente, non-root, sans shell, en Python 3.12, et dont `/health`
  répond ; rapports ModelScan (pickle piégé détecté, ONNX sans problème).
- **Équité** : `reports/fairness_baseline.json` contient une entrée par attribut sensible de
  `dataset.yaml` avec des groupes, et correspond au champion actuel (version, seuil) ;
  `reports/fairness_mitigated.json` compare les stratégies pour chaque attribut.
- **Explicabilité** : graphiques globaux, au moins 3 waterfalls, importance couvrant toutes
  les features, explications locales rédigées.
- **Documentation** : Model Card (11 sections, aucun `TODO`, chaque attribut sensible cité,
  mention du haut risque) et rapport de conformité (5 sections, aucun `TODO`).
- **Kubernetes** : External Secrets installé (API `v1`), SecretStore prêt, ExternalSecret
  synchronisé, Secret possédé par ESO et identique à la source, aucune valeur secrète dans
  `k8s/` ; RBAC appliqué (`scoring-sa` sans jeton monté, `can-i` : `no`/`no`/`yes`),
  ServiceAccount déclaré dans l'overlay Git de production (`k8s/overlays/prod`) et
  InferenceService `scoring-model` effectivement sur `scoring-sa`.

Le code retour est le nombre de vérifications en échec (0 = tout est vert).
