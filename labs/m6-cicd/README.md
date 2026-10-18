---
module: 6
lab: 6
title: "CI/CD/CT de bout en bout sur K8s"
subtitle: "GitHub Actions + Argo CD + ré-entraînement sur dérive"
running_title: "Lab 6 — CI/CD/CT de bout en bout"
duree: "3 heures (atelier guidé)"
stack: "GitHub Actions · Argo CD · KFP · KServe · Evidently"
prerequis: "Labs 2, 4 et 5 réussis (Lab 3 conseillé)"
livrable: "Démo : dérive détectée → ré-entraînement → prod sans humain"
---

# Lab 6 — CI/CD/CT de bout en bout

*Connecter GitHub Actions, Argo CD et Kubeflow Pipelines pour construire un cycle ML qui se
ferme tout seul : dérive détectée → ré-entraînement → nouveau modèle en prod sans
intervention humaine.*

## Objectifs

> [!NOTE]
> **À la fin du lab, vous aurez :**
>
> - Dans votre fork, un workflow GitHub Actions : lint + tests + build de l'image + test de
>   fumée + publication sur GHCR + déploiement en staging par un commit.
> - Argo CD installé sur kind, qui synchronise deux environnements (staging et prod) depuis Git.
> - Un webhook qui reçoit un rapport de dérive Evidently et déclenche un pipeline KFP.
> - Un pipeline CT qui ré-entraîne, valide, enregistre et promeut le modèle par des gates.
> - Un déploiement canary KServe piloté par des commits : promotion et retour arrière.
> - Une démo complète dérive → ré-entraînement → prod, et un rapport sur le temps du cycle et
>   les points d'attention.

## Plan du lab

| # | Étape | Durée |
|---|---|---|
| 1 | Structurer le repo : tests et manifests de déploiement | 25 min |
| 2 | Pipeline CI : lint + tests + build + push GHCR | 25 min |
| 3 | Installer Argo CD sur kind | 20 min |
| 4 | Créer les Applications Argo CD (staging et prod) | 20 min |
| 5 | Déclencher un déploiement par git push | 10 min |
| 6 | Simuler une dérive : rapport Evidently et webhook | 15 min |
| 7 | Pipeline CT : webhook → KFP → nouveau modèle (gates) | 30 min |
| 8 | Canary KServe piloté par Git : promotion, retour arrière | 20 min |
| 9 | Démo de bout en bout + rapport | 15 min |

> [!WARNING]
> **Pré-requis techniques**
> Le cluster `mlops-lab` du Lab 0 avec Kubeflow Pipelines (Lab 2), KServe et
> l'InferenceService `scoring-model` du Lab 5, et le registry `localhost:5001`. Argo CD ajoute
> ≈ 500 Mo : allouez au moins 10 Go de RAM à Docker et arrêtez Airflow
> (`(cd infra/airflow && docker compose down)`). Ne mettez **pas** KFP en pause : le
> ré-entraînement en a besoin. Côté GitHub : votre fork `VOTRE_USER/mlops-cours-2026` avec
> l'onglet **Actions** activé (Lab 0). La CLI `gh` est pratique mais facultative.

> [!NOTE]
> **Vous travaillez sur votre propre dataset ?**
> Rien ne change dans le code ni dans les manifests : les tests fabriquent leurs données et
> leur mini-modèle depuis `dataset.yaml`, la dérive simulée porte sur les variables numériques
> « continues » (plus de 20 valeurs distinctes), le corps des requêtes de test est construit
> depuis `dataset.yaml`, et la gate lit `metrics.primary`, `metrics.promotion_threshold` et la
> matrice de coûts. Les chiffres (part de variables en dérive, métriques de la gate) seront
> différents. Points d'attention : (1) si votre dataset n'a aucune variable numérique
> continue, `simulate` ne crée pas de dérive : passez un vrai lot récent à `detect --current` ;
> (2) le modèle voyage dans Git (`packaging/model/`, étape 2) : au-delà de quelques dizaines
> de Mo, utilisez Git LFS ; (3) une gate n'a de sens que si le lot récent est étiqueté.

## Convention de notation

Les blocs de code contiennent des commandes shell à exécuter telles quelles depuis la racine de
votre fork (`~/mlops-cours-2026`) : elles n'ont **pas** de préfixe `$`, vous pouvez les
copier-coller directement. Les lignes commençant par `#` sont des commentaires. Un bloc dont la
première ligne est `# Fichier : chemin` est le contenu **complet** de ce fichier. Les encadrés
« Sortie attendue » montrent le résultat attendu.

## Avant de commencer : l'architecture du lab

Trois chaînes tournent en parallèle et ne communiquent que par Git :

```text
 CI (GitHub)     git push ──► GitHub Actions : ruff, pytest, build, test de fumée
                                └─► ghcr.io/<vous>/mlops-cours-2026/scoring-api:2.1.N
                                └─► commit : k8s/overlays/staging (nouveau tag)
 CD (cluster)    Argo CD lit k8s/overlays/* toutes les 60 s et applique :
                   staging -> namespace scoring-staging (InferenceService scoring-model)
                   prod    -> namespace scoring (l'InferenceService du Lab 5, canary KServe)
 CT (poste)      rapport Evidently ──► webhook ──► KFP ct-pipeline ──► @champion (MLflow)
                   └─► bot GitOps : commit du modèle ──► CI ──► staging ──► canary prod
```

Les décisions qui structurent le lab :

| Question | Choix du lab | Pourquoi |
|---|---|---|
| Qui construit l'image ? | GitHub Actions (runners hébergés) | Reproductible, journal public, aucun outil sur votre poste. |
| Comment le modèle entre dans l'image ? | `packaging/model/` versionné dans Git depuis le Lab 4 | La CI GitHub ne peut pas joindre le MLflow de votre cluster (voir 2.2). |
| Où vit l'image ? | GHCR (`ghcr.io`) | Gratuit pour un repo public ; les nœuds kind la tirent par Internet. |
| Qui déploie ? | Argo CD (il tire Git) | GitHub ne peut pas atteindre un cluster kind ; et en GitOps la CI n'a aucun accès au cluster. |
| Comment se fait le canary ? | Celui de KServe (`canaryTrafficPercent`, Lab 5), fixé par un commit | Argo Rollouts pilote des Deployments, pas un InferenceService. |
| Où tourne le webhook CT ? | Sur votre poste | Il a déjà vos accès : MLflow (`make pf`), KFP (`make kfp-ui`), droits Git. |

> [!IMPORTANT]
> **Branches, pull requests… et commits automatiques sur `main`**
> Comme dans chaque lab, le code passe par une branche et une pull request relue (Lab 0,
> étape 8.1). Mais à partir d'ici, `main` est aussi **ce qui est déployé** : une PR fait
> tourner la CI (tests, construction de l'image, sans publication) ; sa **fusion** est un push
> sur `main`, qui publie l'image puis la déploie. Ensuite, des outils poussent eux-mêmes des
> commits de déploiement sur `main` : le job `deploy-staging` de la CI (nouveau tag de staging),
> `pipelines/gitops.py` (part du canary, promotion, retour arrière) et le bot de
> ré-entraînement (modèle). Ce sont les seuls commits qui arrivent sur `main` sans PR (guide du
> mini-projet), et c'est pour eux qu'on n'active pas *Require a pull request* sur `main`. Ils
> n'existent qu'**après** la fusion de la PR qui installe la CI (étape 2.3). En pratique :
>
> - le lab se fait en quatre PR courtes : `lab/m6-cicd` (étapes 1-2 : tests, CI, manifests),
>   `lab/m6-argocd` (étapes 4-5 : Applications Argo CD et premier déploiement par fusion),
>   `lab/m6-ct` (étapes 6-7 : ré-entraînement continu) et `lab/m6-rapport` (étape 9.4) ;
> - après chaque fusion, `git switch main && git pull` récupère aussi les commits des outils ;
> - les commandes `gitops … --push` se lancent depuis `main` à jour : l'outil refuse de partir
>   d'une branche `lab/*` ou `ext/*`, dont il pousserait les commits sur `main` sans relecture.

> [!NOTE]
> **Et Argo Rollouts ?**
> L'ancien énoncé faisait le canary avec Argo Rollouts. Rollouts remplace un *Deployment*
> (ressource `Rollout`) : il ne sait pas piloter un InferenceService. Pour un modèle servi par
> KServe, le canary natif (`canaryTrafficPercent`, mode Knative) fait le même travail. Argo
> Rollouts reste la référence pour un service déployé en Deployment classique.

## Étape 1/9 — Structurer le repo : tests et manifests de déploiement (25 min)

### 1.1 Repartir de votre fork

L'ancien énoncé créait un nouveau dossier et y recopiait l'application du Lab 4. Inutile :
tout est déjà dans votre fork, que la CI va tester et déployer tel quel.

```bash
cd ~/mlops-cours-2026
git switch main && git pull
git switch -c lab/m6-cicd
uv sync
set -a && source .env && set +a
make pf
git ls-files packaging/model
```

> **Sortie attendue :** `packaging/model/metadata.json` et `packaging/model/model.onnx` : le
> modèle exporté au Lab 4 est versionné. C'est lui que la CI mettra dans l'image.

Un seul fichier est fourni : l'outil GitOps du lab, `pipelines/gitops.py`. Long et sans
difficulté particulière, il fait UNE chose : transformer une décision de déploiement en
commit. On le détaille au fil des étapes.

```bash
mkdir -p .github/workflows k8s/base k8s/overlays/staging k8s/overlays/prod
cp labs/m6-cicd/starter/gitops.py pipelines/gitops.py
uv run python -m pipelines.gitops --help
```

> **Sortie attendue :** l'aide liste les sous-commandes `status`, `payload`, `deploy`,
> `canary`, `promote`, `rollback` et `release`.

### 1.2 Tester l'API sans MLflow ni cluster

La CI tournera sur une machine GitHub qui n'a ni votre MLflow, ni vos données DVC, ni votre
cluster. Les tests de l'API utilisent donc un **mini-modèle** : quelques centaines de lignes
synthétiques construites depuis `dataset.yaml`, un petit pipeline scikit-learn, un export ONNX
avec les mêmes entrées (une par colonne) et la même sortie (`probabilities`) que le modèle du
Lab 4. Les fixtures partagées vont dans `tests/conftest.py` :

```python
# Fichier : tests/conftest.py
"""Fixtures communes aux tests (Lab 6). Les tests tournent SANS MLflow, sans données DVC
et sans cluster : c'est ce que voit la CI GitHub. L'API est donc testée avec un
mini-modèle ONNX, entraîné à la volée sur des données synthétiques construites depuis
dataset.yaml (mêmes entrées et mêmes sorties que le modèle exporté au Lab 4).
"""

import importlib
import json
import os
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

ROOT = Path(__file__).resolve().parents[1]
# « src » et « pipelines » importables, ainsi que l'API (app.serve, dans packaging/)
for path in (ROOT, ROOT / "packaging"):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))
os.environ.setdefault("DATASET_CONFIG", str(ROOT / "dataset.yaml"))

from src.dataset_config import load_config  # noqa: E402


@pytest.fixture(autouse=True)
def _racine_du_repo(monkeypatch):
    """Les scripts du projet lisent dataset.yaml et params.yaml depuis la racine."""
    monkeypatch.chdir(ROOT)


@pytest.fixture(scope="session")
def contract():
    return load_config(ROOT / "dataset.yaml")


def synthetic_frame(cfg, n: int = 300, seed: int = 0) -> pd.DataFrame:
    """Données factices conformes au contrat : numériques continues, 3 modalités par colonne."""
    rng = np.random.default_rng(seed)
    data = {c: rng.normal(50, 10, n) for c in cfg.numeric}
    data |= {c: rng.choice(["a", "b", "c"], n) for c in cfg.categorical}
    df = pd.DataFrame(data)
    signal = df[cfg.numeric[0]] if cfg.numeric else pd.Series(rng.normal(50, 10, n))
    df[cfg.target] = np.where(signal > 50, str(cfg.positive_class), "autre")
    return df


@pytest.fixture(scope="session")
def make_frame():
    """La fabrique de données synthétiques, pour les tests qui en ont besoin."""
    return synthetic_frame


@pytest.fixture(scope="session")
def mini_model(contract, tmp_path_factory) -> Path:
    """model.onnx + metadata.json : même contrat d'entrées/sorties que le modèle du Lab 4."""
    from skl2onnx import to_onnx
    from skl2onnx.common.data_types import DoubleTensorType, StringTensorType
    from skl2onnx.sklapi import CastTransformer
    from sklearn.compose import ColumnTransformer
    from sklearn.impute import SimpleImputer
    from sklearn.linear_model import LogisticRegression
    from sklearn.pipeline import Pipeline
    from sklearn.preprocessing import OneHotEncoder, StandardScaler

    cfg = contract
    X, y = cfg.split_xy(synthetic_frame(cfg))
    # Comme export_onnx.py (Lab 4) : l'imputer ONNX n'existe qu'en float32
    numeric = Pipeline(
        [
            ("scale", StandardScaler()),
            ("float32", CastTransformer(dtype=np.float32)),
            ("impute", SimpleImputer(strategy="median")),
        ]
    )
    categorical = Pipeline(
        [
            ("impute", SimpleImputer(missing_values="", strategy="constant", fill_value="?")),
            ("onehot", OneHotEncoder(handle_unknown="ignore")),
        ]
    )
    pre = ColumnTransformer([("num", numeric, cfg.numeric), ("cat", categorical, cfg.categorical)])
    model = Pipeline([("preprocess", pre), ("model", LogisticRegression())]).fit(X, y)
    types = [(c, DoubleTensorType([None, 1])) for c in cfg.numeric]
    types += [(c, StringTensorType([None, 1])) for c in cfg.categorical]
    onx = to_onnx(model, initial_types=types, target_opset=17, options={"zipmap": False})

    folder = tmp_path_factory.mktemp("model")
    (folder / "model.onnx").write_bytes(onx.SerializeToString())
    metadata = {"model_name": "scoring-model", "model_version": "test", "threshold": 0.4}
    (folder / "metadata.json").write_text(json.dumps(metadata))
    return folder / "model.onnx"


@pytest.fixture(scope="session")
def api(mini_model):
    """Client de test de l'API du Lab 4-5, servant le mini-modèle (aucun serveur lancé)."""
    from fastapi.testclient import TestClient

    patch = pytest.MonkeyPatch()
    patch.setenv("MODEL_PATH", str(mini_model))  # lu par serve.py à l'import
    patch.setenv("APP_VERSION", "9.9.9")
    patch.delenv("DECISION_THRESHOLD", raising=False)
    sys.modules.pop("app.serve", None)
    serve = importlib.import_module("app.serve")
    with TestClient(serve.app) as client:
        yield client
    patch.undo()
    sys.modules.pop("app.serve", None)
```

Les tests de l'API (`TestClient` de FastAPI : aucun serveur lancé) vérifient le contrat du
Lab 4 : santé, métadonnées, `/version` du Lab 5, cohérence décision/seuil, et refus des
requêtes invalides (422). Le dernier test vérifie le **vrai** modèle versionné, celui qui
partira dans l'image.

```python
# Fichier : tests/test_serve.py
"""Tests de l'API de scoring (packaging/app/serve.py), avec le mini-modèle de conftest.py."""

import json
from pathlib import Path

import onnxruntime as ort
import pytest

from pipelines.gitops import payload

ROOT = Path(__file__).resolve().parents[1]


def test_health(api):
    r = api.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok", "model_loaded": True}


def test_metadata_et_version(api, contract):
    meta = api.get("/metadata").json()
    assert meta["api_version"] == "9.9.9"  # APP_VERSION, posée au build de l'image
    assert meta["threshold"] == 0.4  # seuil lu dans metadata.json
    assert meta["features"] == {"numeric": contract.numeric, "categorical": contract.categorical}
    assert api.get("/version").json() == {"version": "9.9.9", "model_version": "test"}


def test_predict_coherent_avec_le_seuil(api, contract):
    r = api.post("/predict", json=payload(n=3))
    assert r.status_code == 200
    body = r.json()
    assert body["positive_class"] == str(contract.positive_class)
    assert len(body["predictions"]) == 3
    for p in body["predictions"]:
        assert 0.0 <= p["probability"] <= 1.0
        assert p["prediction"] == int(p["probability"] >= body["threshold"])


def test_valeur_manquante_acceptee(api, contract):
    row = payload()["instances"][0] | {contract.features[0]: None}
    assert api.post("/predict", json={"instances": [row]}).status_code == 200


def _invalid_bodies():
    """Requêtes invalides : une colonne manquante, un mauvais type, une colonne en trop…"""
    row = payload()["instances"][0]
    first = next(iter(row))
    return {
        "colonne manquante": {"instances": [{k: v for k, v in row.items() if k != first}]},
        "nombre en texte": {"instances": [row | {first: "12"}]},
        "colonne inconnue": {"instances": [row | {"colonne_inconnue": 1}]},
        "liste vide": {"instances": []},
        "objet nu": row,
    }


@pytest.mark.parametrize("case", list(_invalid_bodies()))
def test_requete_invalide_refusee(api, case):
    assert api.post("/predict", json=_invalid_bodies()[case]).status_code == 422


def test_modele_versionne_conforme_au_contrat(contract):
    """Le modèle de packaging/model/ (celui que la CI met dans l'image) suit dataset.yaml."""
    folder = ROOT / "packaging" / "model"
    if not (folder / "model.onnx").exists():
        pytest.skip("packaging/model/ absent : modèle exporté au Lab 4 (export_onnx.py)")
    meta = json.loads((folder / "metadata.json").read_text())
    assert meta["features"] == {"numeric": contract.numeric, "categorical": contract.categorical}
    assert meta["positive_class"] == str(contract.positive_class)
    assert 0.0 < meta["threshold"] < 1.0
    session = ort.InferenceSession(str(folder / "model.onnx"), providers=["CPUExecutionProvider"])
    assert sorted(i.name for i in session.get_inputs()) == sorted(contract.features)
    assert "probabilities" in [o.name for o in session.get_outputs()]
```

> [!TIP]
> **Le corps de requête « synthétique »**
> `payload()` (dans `pipelines/gitops.py`) fabrique une demande valide pour n'importe quel
> dataset : `1.0` pour chaque variable numérique, `"inconnu"` pour chaque catégorielle (le
> one-hot du modèle ignore les modalités inconnues). Il sert aux tests, au test de fumée de la
> CI et aux vérifications du bot. Essayez : `uv run python -m pipelines.gitops payload`.

### 1.3 Décrire le déploiement : une base, deux environnements

Ce que le cluster doit faire tourner sera désormais décrit dans Git, avec Kustomize : une
**base** commune (l'InferenceService du Lab 5) et un **overlay** par environnement.

```yaml
# Fichier : k8s/base/isvc.yaml
# L'InferenceService du Lab 5, désormais décrit dans Git et déployé par Argo CD.
# Commun à staging et prod : ni namespace, ni image réelle, ni part du canary ici ;
# chaque overlay (k8s/overlays/<env>) les fixe.
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: scoring-model
  annotations:
    serving.kserve.io/deploymentMode: Knative        # canary natif (canaryTrafficPercent)
    serving.kserve.io/enable-tag-routing: "true"     # routes latest-… et prev-… (canary)
    autoscaling.knative.dev/window: "60s"
    autoscaling.knative.dev/scale-down-delay: "30s"
spec:
  predictor:
    minReplicas: 1
    maxReplicas: 5
    scaleMetric: rps
    scaleTarget: 200
    containers:
      - name: kserve-container
        image: scoring-api      # nom logique : remplacé par l'overlay (bloc images:)
        imagePullPolicy: IfNotPresent
        ports:
          - containerPort: 8000
            protocol: TCP
        resources:
          requests: {cpu: "200m", memory: "256Mi"}
          limits: {cpu: "1", memory: "512Mi"}
        readinessProbe:
          httpGet: {path: /health, port: 8000}
```

```yaml
# Fichier : k8s/base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - isvc.yaml
# Pas de bloc « configurations: » : le transformateur images: de Kustomize (v4+) réécrit
# l'image de toute liste « containers », y compris spec.predictor.containers d'un
# InferenceService (vérifié avec Kustomize 5.8.1, la version embarquée par Argo CD 3.5).
```

Staging reçoit automatiquement chaque image construite sur `main`, sans canary, et descend à
zéro pod quand personne ne l'appelle (la RAM de votre poste est comptée) :

```yaml
# Fichier : k8s/overlays/staging/kustomization.yaml
# Staging : la dernière image construite par la CI sur main, sans canary.
# newTag (et newName) sont réécrits par le job deploy-staging de la CI : ne pas éditer
# à la main (python -m pipelines.gitops deploy --env staging … fait la même chose).
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: scoring-staging
resources:
  - ../../base
images:
  - name: scoring-api
    newName: ghcr.io/votre_user/mlops-cours-2026/scoring-api
    newTag: "0.0.0"
patches:
  # Économie de RAM : zéro pod quand personne n'appelle (scale-to-zero), un seul au plus
  - target:
      kind: InferenceService
      name: scoring-model
    patch: |-
      - op: replace
        path: /spec/predictor/minReplicas
        value: 0
      - op: replace
        path: /spec/predictor/maxReplicas
        value: 1
```

La prod, c'est l'InferenceService du Lab 5 (namespace `scoring`), qu'Argo CD va **reprendre** :
au départ, l'overlay décrit exactement l'état de fin du Lab 5 (image `2.0.0`, 100 % du
trafic).

```yaml
# Fichier : k8s/overlays/prod/kustomization.yaml
# Prod : l'InferenceService du Lab 5 (namespace scoring), repris par Argo CD.
# Une mise en production = UN commit qui change newName/newTag ci-dessous ET la part du
# canary dans canary.yaml (python -m pipelines.gitops deploy --env prod --canary 10).
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: scoring
resources:
  - ../../base
images:
  - name: scoring-api
    newName: localhost:5001/scoring-api
    newTag: "2.0.0"
patches:
  - path: canary.yaml
```

```yaml
# Fichier : k8s/overlays/prod/canary.yaml
# Part du trafic envoyée à la NOUVELLE révision (image de kustomization.yaml) :
#   10 = canary · 100 = promotion · 0 = retour arrière vers la révision précédente.
# Modifié par commit (python -m pipelines.gitops canary|promote|rollback), jamais par
# kubectl patch : Argo CD (selfHeal) annulerait la modification.
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: scoring-model
spec:
  predictor:
    canaryTrafficPercent: 100
```

> [!NOTE]
> **Pourquoi un fichier `canary.yaml` séparé ?**
> Deux clés suffisent pour piloter la prod : l'image (`newName`/`newTag` dans
> `kustomization.yaml`) et la part du canary (`canaryTrafficPercent` dans `canary.yaml`). Un
> fichier = une décision : un `git log -- k8s/overlays/prod/canary.yaml` raconte l'historique
> des promotions et des retours arrière. Le Lab 7 modifiera ce même fichier après analyse des
> métriques.

Enfin les deux Applications Argo CD (on les appliquera à l'étape 4 ; ne remplacez
`VOTRE_USER` qu'à ce moment-là) :

```yaml
# Fichier : k8s/argocd-app.yaml
# Deux Applications Argo CD : chacune synchronise un overlay Kustomize de votre fork
# vers un namespace. Remplacez VOTRE_USER (2 occurrences), puis :
#   kubectl apply -f k8s/argocd-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: scoring-staging
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/VOTRE_USER/mlops-cours-2026.git
    targetRevision: main
    path: k8s/overlays/staging
  destination:
    server: https://kubernetes.default.svc
    namespace: scoring-staging
  syncPolicy:
    automated:
      prune: true        # une ressource retirée de Git est supprimée du cluster
      selfHeal: true     # une modification à la main (kubectl patch/edit) est annulée
    syncOptions:
      - CreateNamespace=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: scoring-prod
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/VOTRE_USER/mlops-cours-2026.git
    targetRevision: main
    path: k8s/overlays/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: scoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Les tests des manifests construisent les deux overlays (avec `kubectl kustomize` sur votre
poste comme sur les runners GitHub, ou un rendu Python minimal à défaut) et vérifient ce
qu'Argo CD appliquera :

```python
# Fichier : tests/test_k8s.py
"""Tests des manifests GitOps (k8s/) : ce qu'Argo CD appliquera, sans cluster.

Rendu par Kustomize (binaire kustomize, ou kubectl kustomize : présents sur les runners
GitHub) ; sans eux, un rendu Python minimal (namespace, images, patches) vérifie les mêmes
propriétés, pour que les tests tournent aussi sur un poste sans outils Kubernetes.
"""

import copy
import shutil
import subprocess
from pathlib import Path

import pytest
import yaml

from pipelines import gitops

ROOT = Path(__file__).resolve().parents[1]
OVERLAYS = ROOT / "k8s" / "overlays"


def _merge(target: dict, patch: dict) -> None:
    for key, value in patch.items():
        if isinstance(value, dict) and isinstance(target.get(key), dict):
            _merge(target[key], value)
        else:
            target[key] = copy.deepcopy(value)


def render_python(folder: Path) -> list[dict]:
    """Sous-ensemble de Kustomize utilisé par ce repo : resources, namespace, images, patches."""
    kust = yaml.safe_load((folder / "kustomization.yaml").read_text(encoding="utf-8"))
    docs = []
    for res in kust.get("resources", []):
        path = (folder / res).resolve()
        assert path.exists(), f"{folder}: ressource introuvable {res}"
        if path.is_dir():
            docs += render_python(path)
        else:
            docs += [d for d in yaml.safe_load_all(path.read_text(encoding="utf-8")) if d]
    for doc in docs:
        if "namespace" in kust:
            doc["metadata"]["namespace"] = kust["namespace"]
        for container in doc.get("spec", {}).get("predictor", {}).get("containers", []):
            for image in kust.get("images", []):
                if container["image"] == image["name"]:
                    container["image"] = f"{image['newName']}:{image['newTag']}"
    for patch in kust.get("patches", []):
        if "path" in patch:  # patch stratégique : même kind et même nom que la cible
            body = yaml.safe_load((folder / patch["path"]).read_text(encoding="utf-8"))
            targets = [d for d in docs if (d["kind"], d["metadata"]["name"]) ==
                       (body["kind"], body["metadata"]["name"])]  # fmt: skip
            assert targets, f"{patch['path']} ne cible aucune ressource"
            for doc in targets:
                _merge(doc, {k: v for k, v in body.items() if k != "metadata"})
        else:  # patch JSON 6902 en ligne (op replace / add)
            sel = patch["target"]
            targets = [d for d in docs if d["kind"] == sel["kind"]
                       and d["metadata"]["name"] == sel["name"]]  # fmt: skip
            assert targets, f"patch en ligne : aucune cible {sel}"
            for doc in targets:
                for op in yaml.safe_load(patch["patch"]):
                    *parents, last = op["path"].strip("/").split("/")
                    node = doc
                    for key in parents:
                        node = node[key]
                    assert op["op"] in ("replace", "add") and (op["op"] == "add" or last in node)
                    node[last] = op["value"]
    return docs


def render(env: str) -> list[dict]:
    folder = OVERLAYS / env
    if shutil.which("kustomize"):
        cmd = ["kustomize", "build", str(folder)]
    elif shutil.which("kubectl"):
        cmd = ["kubectl", "kustomize", str(folder)]
    else:
        return render_python(folder)
    out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
    return [d for d in yaml.safe_load_all(out) if d]


@pytest.mark.parametrize("env", ["staging", "prod"])
def test_overlay(env):
    docs = render(env)
    assert [(d["kind"], d["metadata"]["name"]) for d in docs] == [
        ("InferenceService", "scoring-model")
    ]
    isvc = docs[0]
    assert isvc["metadata"]["namespace"] == gitops.NAMESPACES[env]
    # mode Knative : le seul où canaryTrafficPercent existe (Lab 5) ; fixé à la création
    assert isvc["metadata"]["annotations"]["serving.kserve.io/deploymentMode"] == "Knative"
    predictor = isvc["spec"]["predictor"]
    name, tag = gitops.read_image(ROOT, env)
    assert predictor["containers"][0]["image"] == f"{name}:{tag}"  # images: bien appliqué
    if env == "prod":
        assert predictor["canaryTrafficPercent"] == gitops.read_canary(ROOT)
        assert 0 <= predictor["canaryTrafficPercent"] <= 100
        assert predictor["minReplicas"] >= 1
    else:
        assert "canaryTrafficPercent" not in predictor
        assert predictor["minReplicas"] == 0  # staging : scale-to-zero


def test_rendu_python_identique_a_kustomize():
    """Le rendu de secours dit la même chose que Kustomize (quand il est installé)."""
    if not (shutil.which("kustomize") or shutil.which("kubectl")):
        pytest.skip("ni kustomize ni kubectl sur ce poste")
    for env in ("staging", "prod"):
        assert render(env) == render_python(OVERLAYS / env)


def test_applications_argocd():
    apps = list(yaml.safe_load_all((ROOT / "k8s" / "argocd-app.yaml").read_text()))
    assert sorted(a["metadata"]["name"] for a in apps) == ["scoring-prod", "scoring-staging"]
    for app in apps:
        assert app["apiVersion"] == "argoproj.io/v1alpha1" and app["kind"] == "Application"
        env = app["metadata"]["name"].removeprefix("scoring-")
        assert app["spec"]["source"]["path"] == f"k8s/overlays/{env}"
        assert app["spec"]["source"]["targetRevision"] == "main"
        assert app["spec"]["destination"]["namespace"] == gitops.NAMESPACES[env]
        assert app["spec"]["syncPolicy"]["automated"] == {"prune": True, "selfHeal": True}


def test_gitops_modifie_sans_casser(tmp_path):
    """set_image / set_canary : seules les valeurs changent, commentaires conservés."""
    shutil.copytree(ROOT / "k8s", tmp_path / "k8s")
    before = (tmp_path / gitops.CANARY).read_text().splitlines()
    gitops.set_image(tmp_path, "prod", "ghcr.io/etudiant/mlops-cours-2026/scoring-api", "2.1.7")
    gitops.set_canary(tmp_path, 10)
    assert gitops.read_image(tmp_path, "prod") == (
        "ghcr.io/etudiant/mlops-cours-2026/scoring-api",
        "2.1.7",
    )
    assert gitops.read_canary(tmp_path) == 10
    after = (tmp_path / gitops.CANARY).read_text().splitlines()
    changed = [(a, b) for a, b in zip(before, after, strict=True) if a != b]
    assert len(changed) == 1 and "canaryTrafficPercent" in changed[0][1]
    isvc = render_python(tmp_path / "k8s" / "overlays" / "prod")[0]
    assert isvc["spec"]["predictor"]["canaryTrafficPercent"] == 10
    with pytest.raises(SystemExit):
        gitops.set_canary(tmp_path, 120)
```

### 1.4 Lancer les tests

```bash
uv run ruff check . && uv run ruff format --check .
uv run pytest -q
```

> **Sortie attendue :** `All checks passed!`, puis `24 passed` en quelques secondes (9 tests
> du contrat, 10 de l'API, 5 des manifests), plus ceux que le Lab 3 a ajoutés le cas échéant.
> Un avertissement `StarletteDeprecationWarning` (httpx) est sans conséquence.

## Étape 2/9 — Pipeline CI : lint + tests + build + push (25 min)

### 2.1 Le workflow GitHub Actions

```yaml
# Fichier : .github/workflows/ci.yml
# CI du projet de scoring (Lab 6) : lint + tests -> image testée puis publiée sur GHCR
# -> commit du nouveau tag dans k8s/overlays/staging (Argo CD déploie). Les workflows du
# cours lui-même s'appellent course-*.yml : ne pas les modifier.
name: CI scoring

on:  # yamllint disable-line rule:truthy
  push:
    branches: [main]
    paths:
      - "src/**"
      - "packaging/**"
      - "pipelines/**"
      - "tests/**"
      - "dataset.yaml"
      - "params.yaml"
      - "pyproject.toml"
      - "uv.lock"
      - ".github/workflows/ci.yml"
  pull_request:
    branches: [main]
    paths:
      - "src/**"
      - "packaging/**"
      - "pipelines/**"
      - "tests/**"
      - "dataset.yaml"
      - "params.yaml"
      - "pyproject.toml"
      - "uv.lock"
      - ".github/workflows/ci.yml"
  workflow_dispatch:

permissions:
  contents: read

env:
  API_VERSION: "2.1"  # MAJEUR.MINEUR de l'API ; tag de l'image = 2.1.<numéro du run>

jobs:
  test:
    name: Lint + tests
    runs-on: ubuntu-latest
    env:
      UV_LOCKED: "1"  # uv.lock fait foi : erreur s'il ne correspond plus à pyproject.toml
    steps:
      - uses: actions/checkout@v7
      # Action tierce : épinglée par SHA de commit (Astral ne publie plus de tag majeur)
      - uses: astral-sh/setup-uv@c18668ad3cf93ea998bef934396af7bb5c839dc7  # v10.2.0
        with:
          enable-cache: true
      - name: Installer l'environnement du cours (uv.lock)
        run: uv sync
      - name: Lint (ruff)
        run: |
          uv run ruff check .
          uv run ruff format --check .
      - name: Tests (pytest) — API, contrat, manifests, pipelines KFP, webhook CT
        run: uv run pytest -v

  build:
    name: Image scoring-api
    needs: test
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write  # publier sur ghcr.io avec le GITHUB_TOKEN
    outputs:
      image: ${{ steps.meta.outputs.image }}
      tag: ${{ steps.meta.outputs.tag }}
    steps:
      - uses: actions/checkout@v7
      - uses: astral-sh/setup-uv@c18668ad3cf93ea998bef934396af7bb5c839dc7  # v10.2.0
      - name: Nom, tag et version du modèle
        id: meta
        run: |
          OWNER="${GITHUB_REPOSITORY_OWNER,,}"  # GHCR exige des minuscules
          REPO="${GITHUB_REPOSITORY#*/}"
          TAG="${API_VERSION}.${GITHUB_RUN_NUMBER}"
          # « Re-run » d'un même run : nouveau tag, on ne réécrit jamais une image publiée
          [ "$GITHUB_RUN_ATTEMPT" = "1" ] || TAG="${TAG}-${GITHUB_RUN_ATTEMPT}"
          {
            echo "image=ghcr.io/${OWNER}/${REPO,,}/scoring-api"
            echo "tag=${TAG}"
            echo "model_version=$(jq -r .model_version packaging/model/metadata.json)"
          } >> "$GITHUB_OUTPUT"
      - uses: docker/setup-buildx-action@v4
      - name: Construire l'image (sans la publier)
        uses: docker/build-push-action@v7
        with:
          context: .
          file: packaging/Dockerfile
          build-args: |
            VERSION=${{ steps.meta.outputs.tag }}
            MODEL_VERSION=${{ steps.meta.outputs.model_version }}
          labels: |
            org.opencontainers.image.source=${{ github.server_url }}/${{ github.repository }}
            org.opencontainers.image.revision=${{ github.sha }}
          tags: ${{ steps.meta.outputs.image }}:${{ steps.meta.outputs.tag }}
          load: true  # dans le Docker du runner, pour le test de fumée
          cache-from: type=gha
          cache-to: type=gha,mode=max
      - name: Test de fumée (le conteneur démarre et prédit)
        env:
          IMAGE: ${{ steps.meta.outputs.image }}:${{ steps.meta.outputs.tag }}
          TAG: ${{ steps.meta.outputs.tag }}
        run: |
          docker run -d --name api -p 8000:8000 "$IMAGE"
          for _ in $(seq 1 30); do curl -fsS localhost:8000/health && break; sleep 1; done
          curl -fsS localhost:8000/version | tee /dev/stderr | grep -q "\"version\":\"${TAG}\""
          uv run --no-project --with pyyaml==6.0.3 --with pandas==2.3.3 \
            python -m pipelines.gitops payload > request.json
          curl -fsS -X POST localhost:8000/predict -H "Content-Type: application/json" \
            -d @request.json
          docker rm -f api
      - name: Connexion à GHCR
        if: github.event_name != 'pull_request'
        uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Publier l'image testée
        if: github.event_name != 'pull_request'
        uses: docker/build-push-action@v7
        with:
          context: .
          file: packaging/Dockerfile
          build-args: |
            VERSION=${{ steps.meta.outputs.tag }}
            MODEL_VERSION=${{ steps.meta.outputs.model_version }}
          labels: |
            org.opencontainers.image.source=${{ github.server_url }}/${{ github.repository }}
            org.opencontainers.image.revision=${{ github.sha }}
          tags: ${{ steps.meta.outputs.image }}:${{ steps.meta.outputs.tag }}
          push: true
          cache-from: type=gha  # mêmes couches que l'image testée : rien n'est reconstruit

  deploy-staging:
    name: Déployer en staging (commit GitOps)
    needs: build
    if: github.event_name != 'pull_request' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    permissions:
      contents: write  # pousser le commit du nouveau tag
    concurrency:
      group: deploy-staging  # deux runs ne modifient jamais l'overlay en même temps
      cancel-in-progress: false
    steps:
      - uses: actions/checkout@v7
        with:
          ref: main
      - uses: astral-sh/setup-uv@c18668ad3cf93ea998bef934396af7bb5c839dc7  # v10.2.0
      - name: Nouveau tag dans k8s/overlays/staging (Argo CD fera le reste)
        env:
          IMAGE: ${{ needs.build.outputs.image }}
          TAG: ${{ needs.build.outputs.tag }}
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          uv run --no-project --with pyyaml==6.0.3 python -m pipelines.gitops deploy \
            --env staging --image "$IMAGE" --tag "$TAG" --note "[${GITHUB_SHA::7}]" --push
```

Ce qui a changé par rapport à l'ancien énoncé, et pourquoi :

- **`paths`** : la CI ne tourne que si le code, le modèle, les tests ou les dépendances changent.
  Un commit qui ne touche que `k8s/` (ceux d'Argo CD… et du job `deploy-staging` lui-même) ne
  relance rien : pas de boucle infinie.
- **Actions à jour** : `actions/checkout@v7`, `docker/setup-buildx-action@v4`,
  `docker/login-action@v4`, `docker/build-push-action@v7` (dernières versions majeures,
  octobre 2026). Une action **tierce** est épinglée par SHA de commit, avec la version en
  commentaire : un tag peut être déplacé par un attaquant, un SHA non (le Lab 8 revient sur
  l'incident `trivy-action` de mars 2026). Astral ne publie d'ailleurs plus de tag majeur
  (`v10`) pour `setup-uv`.
- **`uv sync` avec `UV_LOCKED=1`** : la CI installe exactement `uv.lock` et échoue s'il n'est
  plus à jour (plus de `pip install uv`, ni de Python 3.11).
- **Un tag par build, jamais `latest`** : `2.1.<numéro du run>`. Le Lab 5 l'a montré : un
  tag désigne une image immuable. `API_VERSION` (2.1) est la version de l'API, que vous
  augmentez quand le contrat change ; `/version` répondra `2.1.N`.
- **Test de fumée avant publication** : l'image est construite, démarrée, interrogée
  (`/health`, `/version`, `/predict`) ; elle n'est poussée que si elle répond. Le second
  `build-push-action` ne reconstruit rien : toutes les couches sont dans le cache.
- **GHCR et minuscules** : `ghcr.io/<propriétaire>/<repo>/scoring-api`, tout en minuscules
  (`${VAR,,}`), sinon le push échoue. Le `GITHUB_TOKEN` suffit (`packages: write`), aucun
  secret à créer.
- **`deploy-staging`** : le job écrit le nouveau tag dans `k8s/overlays/staging` avec
  `pipelines.gitops` et pousse ce commit. La CI ne touche jamais au cluster : Argo CD fera le
  reste. `concurrency` empêche deux runs d'écrire l'overlay en même temps.

### 2.2 Le modèle dans l'image : comment la CI le récupère-t-elle ?

Depuis le Lab 4, le modèle est **figé dans l'image** au build. La CI GitHub doit donc avoir le
modèle. Trois façons de faire :

| Option | Principe | Pour un cluster kind sur votre poste |
|---|---|---|
| (a) La CI télécharge `@champion` depuis MLflow | `export_onnx.py` dans le job `build` | Impossible : un runner GitHub ne peut pas joindre `localhost:5000` ni votre cluster. |
| (b) Runner auto-hébergé sur votre poste | Le job tourne chez vous et voit MLflow | Dangereux sur un repo **public** : n'importe quelle PR exécuterait du code sur votre machine (GitHub le déconseille). |
| (c) Modèle chargé au démarrage | Image = code seul ; un init container télécharge le modèle depuis S3 | Possible, mais l'image ne dit plus quel modèle elle sert, et changer d'alias dans MLflow change la prod **sans commit**. |
| **(d) Modèle versionné dans Git** | `packaging/model/` (≈ 11 ko d'ONNX + métadonnées) est commité | **Choix du lab** : runners GitHub standards, image immuable (code + modèle), chaque modèle en prod correspond à un commit. |

Conséquence : mettre un nouveau modèle en production, c'est **commiter** `packaging/model/`
(exporté par `export_onnx.py`, Lab 4). C'est ce que fera le bot du ré-entraînement (étape 9),
exactement comme vous à l'étape 8. Limite assumée : au-delà de quelques dizaines de Mo, on
passe à Git LFS ou à l'option (c) avec un `storageUri` KServe.

### 2.3 Pousser et suivre la CI

```bash
git add .github k8s tests pipelines/gitops.py
git commit -m "Lab 6: tests, CI GitHub Actions, manifests Kustomize"
git push -u origin lab/m6-cicd
gh pr create     # ou « Compare & pull request » sur GitHub
gh pr checks --watch    # ou l'onglet Checks de la PR
```

> **Sortie attendue :** sur la PR, le workflow « CI scoring » passe au vert en 6 à 9 minutes au
> premier run : `Lint + tests` (24 tests) et `Image scoring-api` (construction et test de
> fumée, **sans publication** : une PR ne publie rien) ; `Déployer en staging` est sauté.

Votre partenaire relit la PR, attend la CI verte et l'approuve ; fusionnez-la. La fusion est un
push sur `main` : la CI repart, et cette fois publie et déploie.

```bash
gh run watch    # le run de main (ou l'onglet Actions de votre fork)
```

> **Sortie attendue :** 2 à 4 minutes grâce aux caches : `Lint + tests`, `Image scoring-api`
> (test de fumée, puis push de `ghcr.io/<vous>/mlops-cours-2026/scoring-api:2.1.2`),
> `Déployer en staging (commit GitOps)`. Le dernier nombre du tag est le numéro du run : le
> run n° 1 était celui de la PR. Dans votre profil GitHub > Packages, le package
> `mlops-cours-2026/scoring-api` apparaît avec le tag `2.1.2`.

> [!TIP]
> **Gagner du temps**
> Le premier run de la CI est le plus long (installation de l'environnement, couches Docker) :
> lancez l'installation d'Argo CD (étape 3.1, `make argocd`) dans un autre terminal pendant
> qu'il tourne.

```bash
git switch main && git pull     # la fusion, et le commit du job deploy-staging
git log --oneline -3
```

> **Sortie attendue :** `gitops(staging): ghcr.io/<vous>/mlops-cours-2026/scoring-api:2.1.2
> [abc1234]` (le SHA entre crochets est celui du commit que la CI a construit), au-dessus du
> commit de fusion de la PR et de votre commit : le premier commit d'un outil sur `main`.

### 2.4 Rendre l'image accessible au cluster

Un package GHCR est **privé** à sa création, même pour un repo public : les nœuds kind ne
pourraient pas le tirer (`ImagePullBackOff`). Deux solutions :

1. **Le rendre public** (recommandé ici : le code et le modèle sont déjà publics dans votre
   fork) : GitHub > votre profil > Packages > `mlops-cours-2026/scoring-api` > Package
   settings > Danger Zone > Change visibility > Public. Irréversible.
2. **Le garder privé** et donner au cluster un identifiant de lecture : un *personal access
   token* (classic) avec le seul droit `read:packages`, rangé dans un Secret de chaque
   namespace (jamais dans Git), puis référencé par l'InferenceService :

```bash
for ns in scoring-staging scoring; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret docker-registry ghcr-pull -n "$ns" --docker-server=ghcr.io \
    --docker-username=VOTRE_USER --docker-password="$GHCR_READ_TOKEN"
done
```

et, dans `patches:` des deux overlays :

```yaml
  - target:
      kind: InferenceService
      name: scoring-model
    patch: |-
      - op: add
        path: /spec/predictor/imagePullSecrets
        value: [{name: ghcr-pull}]
```

Knative résout chaque tag en *digest* avant de créer une révision : son contrôleur interroge
lui aussi GHCR, avec le même Secret. Vérifiez l'accès anonyme d'un package public :

```bash
OWNER=$(git remote get-url origin | sed -E 's#.*[:/]([^/]+)/[^/]+$#\1#' | tr 'A-Z' 'a-z')
REPO="${OWNER}/mlops-cours-2026/scoring-api"
TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:${REPO}:pull" |
  python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")
curl -s -H "Authorization: Bearer $TOKEN" "https://ghcr.io/v2/${REPO}/tags/list"
```

> **Sortie attendue :** `{"name":"<vous>/mlops-cours-2026/scoring-api","tags":["2.1.2"]}`.
> Une erreur `DENIED` signifie que le package est encore privé.

> [!TIP]
> **Alternative locale : sans GitHub Actions**
> Pas d'accès à GitHub dans votre salle ? `pipelines/gitops.py` sait remplacer la CI :
> `uv run python -m pipelines.gitops local-ci --push` construit l'image avec votre Docker, la
> pousse sur `localhost:5001` et commite le tag de staging (les jobs `build` et
> `deploy-staging`) ; `CT_LOCAL_CI=1` fait de même pour le bot de l'étape 9. Il faut alors un
> dépôt Git qu'Argo CD puisse lire, servi dans le cluster, comme le fait la CI du cours :
> `kubectl apply -f labs/m6-cicd/starter/git-server.yaml` (un `git daemon`), puis
> `kubectl -n gitops-e2e port-forward svc/git-server 19418:9418 &`,
> `git remote add local git://localhost:19418/mlops-cours-2026.git`,
> `git push local main` et `export GITOPS_REMOTE=local` ; dans `k8s/argocd-app.yaml`,
> `repoURL: git://git-server.gitops-e2e.svc.cluster.local/mlops-cours-2026.git`. Lecture et
> écriture anonymes : à réserver à un cluster de TP.

## Étape 3/9 — Installer Argo CD sur kind (20 min)

### 3.1 Installation

```bash
make argocd
```

Le script `infra/argocd/install.sh` installe Argo CD `v3.5.3` (version de
`infra/versions.env`) :

- le manifest officiel non-HA du tag, appliqué avec `kubectl apply --server-side
  --force-conflicts` : c'est la procédure d'Argo CD 3, le CRD `ApplicationSet` dépasse la
  taille maximale de l'annotation d'un `kubectl apply` classique ;
- une réconciliation toutes les **60 s** au lieu de 120 s (+ jusqu'à 60 s de gigue) :
  GitHub ne peut pas appeler un cluster kind sur votre poste (pas de webhook), Argo CD
  interroge donc Git régulièrement ;
- Dex (SSO), les notifications et le contrôleur d'ApplicationSets passent à 0 réplique :
  inutiles ici, ≈ 150 Mo rendus à votre poste.

Extrait du script :

```bash
retry 3 k apply -n "${NS}" --server-side --force-conflicts -f "${URL}"

log "Réconciliation toutes les 60 s ; composants inutiles au cours à 0 réplique"
k -n "${NS}" patch configmap argocd-cm --type merge \
  -p '{"data":{"timeout.reconciliation":"60s","timeout.reconciliation.jitter":"10s"}}'
```

> **Sortie attendue :** 2 à 5 minutes de téléchargements, puis quatre pods `Running` :

```text
NAME                                  READY   STATUS    RESTARTS   AGE
argocd-application-controller-0       1/1     Running   0          45s
argocd-redis-6d8b9c7f5-x2kqp          1/1     Running   0          2m
argocd-repo-server-7c9d5b8d6-9wz4l    1/1     Running   0          45s
argocd-server-5f6b8c9d7d-kq7mn        1/1     Running   0          2m
```

> suivis de l'adresse de l'interface et du mot de passe `admin` initial.

### 3.2 Interface web et CLI (optionnelle)

```bash
kubectl port-forward -n argocd svc/argocd-server 8443:443 &
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

> **Sortie attendue :** interface sur `https://localhost:8443` (acceptez le certificat
> auto-signé), utilisateur `admin`, mot de passe affiché par la commande.

La CLI `argocd` est pratique mais facultative : tout ce lab se fait aussi avec `kubectl`
(les Applications sont des ressources Kubernetes). Pour l'installer, prenez la **même
version** que le serveur :

```bash
# Linux x86_64 (Mac : argocd-darwin-arm64 ou brew install argocd)
curl -sSL -o /tmp/argocd \
  https://github.com/argoproj/argo-cd/releases/download/v3.5.3/argocd-linux-amd64
sudo install -m 555 /tmp/argocd /usr/local/bin/argocd
argocd login localhost:8443 --username admin --insecure
```

## Étape 4/9 — Créer les Applications Argo CD (20 min)

### 4.1 Ce qu'Argo CD va appliquer

Avant de confier un overlay à Argo CD, regardez ce qu'il produit :

```bash
kubectl kustomize k8s/overlays/prod
```

> **Sortie attendue :** un seul objet, l'InferenceService `scoring-model` du namespace
> `scoring`, avec `canaryTrafficPercent: 100` et `image: localhost:5001/scoring-api:2.0.0` :
> exactement l'état de fin du Lab 5. Pour `k8s/overlays/staging` : namespace
> `scoring-staging`, `minReplicas: 0`, `maxReplicas: 1`, l'image GHCR construite par la CI.

> [!NOTE]
> **`images:` et un InferenceService**
> Le bloc `images:` de Kustomize remplace le champ `image` de **toute** liste `containers`
> (ou `initContainers`), quel que soit le type de ressource : celui d'un InferenceService
> (`spec.predictor.containers`) est donc réécrit sans configuration supplémentaire (vérifié
> avec Kustomize 5.8.1, la version embarquée par Argo CD 3.5). Une section `configurations:`
> ne serait nécessaire que pour une image rangée ailleurs que dans une liste `containers`.

### 4.2 Les deux Applications

Deuxième PR du lab : depuis `main` à jour, une branche `lab/m6-argocd`. Remplacez
`VOTRE_USER` par votre compte GitHub dans `k8s/argocd-app.yaml` (2 occurrences), puis :

```bash
git switch main && git pull && git switch -c lab/m6-argocd
sed -i "s#VOTRE_USER#$(git remote get-url origin | sed -E 's#.*[:/]([^/]+)/[^/]+$#\1#')#" \
  k8s/argocd-app.yaml      # macOS : sed -i ''
grep repoURL k8s/argocd-app.yaml
git commit -am "Lab 6: Applications Argo CD"
kubectl apply -f k8s/argocd-app.yaml
kubectl get applications -n argocd -w     # Ctrl-C quand tout est Synced / Healthy
```

> **Sortie attendue :** après 30 s à 2 min :

```text
NAME              SYNC STATUS   HEALTH STATUS
scoring-prod      Synced        Healthy
scoring-staging   Synced        Healthy
```

> Votre fork est public : Argo CD le lit sans identifiant. Pour un dépôt privé, il faudrait
> déclarer un *repository* avec un jeton (Secret `argocd.argoproj.io/secret-type: repository`).

### 4.3 Qu'est-ce qui a changé dans le cluster ?

```bash
kubectl get isvc -A
kubectl get isvc scoring-model -n scoring \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{"\n"}'
kubectl get revisions -n scoring
```

> **Sortie attendue :** deux InferenceServices `scoring-model`, l'un dans `scoring` (celui du
> Lab 5), l'autre dans `scoring-staging` (créé par Argo CD, avec son namespace :
> `CreateNamespace=true`). L'annotation
> `scoring-prod:serving.kserve.io/InferenceService:scoring/scoring-model` prouve qu'Argo CD
> suit désormais l'ISVC de prod (suivi par annotation, le défaut d'Argo CD 3).
> En prod, au plus une révision de plus : l'état décrit dans Git était déjà celui du cluster.

Argo CD sait si un InferenceService va bien : son contrôle de santé intégré pour
`serving.kserve.io/InferenceService` lit les conditions de KServe (`Healthy` quand tout est
`True`, `Progressing` pendant le démarrage d'une révision, `Degraded` si une révision échoue,
par exemple sur `ImagePullBackOff`).

### 4.4 L'auto-réparation (selfHeal)

Quelqu'un modifie la prod « à la main », comme au Lab 5 :

```bash
kubectl patch isvc scoring-model -n scoring --type merge \
  -p '{"spec":{"predictor":{"canaryTrafficPercent":50}}}'
kubectl get isvc scoring-model -n scoring -w      # Ctrl-C après le retour à 100
```

> **Sortie attendue :** `PREV 50` / `LATEST 50` quelques secondes, puis, en moins de 70 s,
> retour à `LATEST 100` : Argo CD a constaté l'écart avec Git et l'a annulé. Désormais, **tout
> changement passe par un commit** (le Lab 8 le rappellera pour le ServiceAccount de l'API).

## Étape 5/9 — Déclencher un déploiement par git push (10 min)

Modifiez un fichier de l'application, par exemple la docstring de `packaging/app/serve.py`,
puis poussez la branche et ouvrez la PR (elle contient aussi le commit de l'étape 4.2) :

```bash
git commit -am "Lab 6: déploiement par git push"
git push -u origin lab/m6-argocd
gh pr create
```

La CI teste la PR. Le `git push` qui déploie, c'est la **fusion** : une fois la PR relue,
approuvée et fusionnée, suivez le run de `main` (`gh run watch`) et observez, dans l'ordre :

- le workflow GitHub Actions se déclenche (`packaging/**` est dans les `paths`), passe les
  tests, construit et publie l'image `2.1.4` (le run n° 3 était celui de la PR) ;
- le job `deploy-staging` pousse un commit qui change `newTag` dans
  `k8s/overlays/staging/kustomization.yaml` ;
- Argo CD le voit à sa réconciliation suivante (≤ 70 s) et applique l'overlay : KServe crée une
  révision `scoring-model-predictor-00002` dans `scoring-staging` ;
- la révision devient prête ; l'ancienne ne reçoit plus de trafic.

```bash
git switch main && git pull
kubectl get applications -n argocd
uv run python -m pipelines.gitops status
```

> **Sortie attendue :** `status` affiche pour staging `Git : ghcr.io/<vous>/…/scoring-api:2.1.4`
> et `servi : {'version': '2.1.4', 'model_version': '…'}`. Le premier appel peut prendre
> quelques secondes : staging était à zéro pod (scale-to-zero). La prod n'a pas bougé :
> elle ne change que par une décision explicite (étape 8).

> [!TIP]
> **Accélérer la synchronisation**
> Argo CD interroge Git toutes les 60 s. Pour ne pas attendre, demandez un rafraîchissement :
> `kubectl annotate app scoring-staging -n argocd argocd.argoproj.io/refresh=normal`
> (ou `argocd app sync scoring-staging`). En production, un webhook GitHub → Argo CD rend la
> synchronisation instantanée ; impossible ici, GitHub ne voit pas votre poste.

## Étape 6/9 — Simuler une dérive : rapport Evidently et webhook (15 min)

Les étapes 6 et 7 écrivent le code du ré-entraînement continu : troisième PR du lab, sur une
nouvelle branche.

```bash
git switch main && git pull && git switch -c lab/m6-ct
```

### 6.1 Le principe

Dans un vrai déploiement, un job de monitoring (Lab 7) compare régulièrement les données
reçues en production aux données d'entraînement et émet un événement quand elles dérivent.
Ici, on fabrique un lot « récent » avec une dérive, on le compare à la référence avec
**Evidently 0.7**, et on envoie l'événement à un **webhook** qui décide de ré-entraîner.

Le lot récent est **étiqueté** (on connaît déjà l'issue des crédits) : sans étiquettes, pas de
ré-entraînement possible. Il est rangé dans MLflow avec le rapport (expérience
`scoring-drift`) : le pipeline CT, dans le cluster, l'y lira sans identifiant S3 (le serveur
MLflow fait proxy des artefacts, Lab 0).

### 6.2 Un jeton pour le webhook, et l'accès à KFP

Un webhook qui lance des entraînements ne doit pas répondre à n'importe qui : il exige un
jeton, rangé dans `.env` (jamais commité). Le webhook parle à l'API KFP par le port-forward
de l'UI (Lab 2).

```bash
echo "CT_WEBHOOK_TOKEN=$(openssl rand -hex 16)" >> .env
set -a && source .env && set +a
make kfp-ui
curl -s localhost:8080/apis/v2beta1/healthz
```

> **Sortie attendue :** `{"commit_sha":…,"multi_user":false,…}` : l'API KFP répond.

Les fichiers produits par le CT ne vont pas dans Git : le pipeline compilé `ct_pipeline.yaml` se
regénère, et les lots et rapports de dérive (`data/drift/`, `reports/drift/`) sont rangés dans
MLflow (expérience `scoring-drift`). Le `.gitignore` du template contient déjà le bloc *Lab 6* :
vérifiez-le avec `grep -A5 'Lab 6 :' .gitignore`. (La ligne commentée `# CT_WEBHOOK_TOKEN=` de
`.env.example` rappelle où vit le jeton.)

### 6.3 Le déclencheur

```python
# Fichier : pipelines/trigger_ct.py
"""Ré-entraînement continu (Lab 6) : dérive Evidently -> webhook -> pipeline KFP -> GitOps.

Depuis la racine du repo, .env chargé, `make pf` et port-forward de KFP (8080) actifs :
  simulate   fabrique un lot récent étiqueté, avec une dérive (data/drift/current.csv)
  detect     rapport Evidently 0.7 (référence = train.csv), rangé dans MLflow, puis POST
             de l'événement au webhook
  send       POST d'un événement déjà calculé (fichier JSON, ex. produit par le Lab 7)
  serve      le webhook : décide, lance ct-pipeline dans KFP, suit le run et, si la gate
             a promu un nouveau @champion, lance la mise en production (pipelines/gitops.py)
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

import pandas as pd
from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

from src.dataset_config import load_config

REFERENCE = Path("data/processed/train.csv")  # données d'entraînement du champion (Lab 1)
CURRENT = Path("data/drift/current.csv")  # lot « récent » simulé (non versionné)
REPORT_DIR = Path("reports/drift")
DRIFT_EXPERIMENT = "scoring-drift"  # expérience MLflow des rapports de dérive
MODEL_NAME = "scoring-model"
KFP_HOST = os.getenv("KFP_HOST", "http://localhost:8080")  # port-forward de ml-pipeline-ui
KFP_EXPERIMENT = "scoring-ct"
PORT = int(os.getenv("CT_WEBHOOK_PORT", "8095"))
WEBHOOK_URL = os.getenv("CT_WEBHOOK_URL", f"http://localhost:{PORT}/drift")
MIN_DRIFT_SHARE = float(os.getenv("CT_MIN_DRIFT_SHARE", "0.1"))  # >= 10 % des variables
COOLDOWN_SECONDS = int(os.getenv("CT_COOLDOWN_SECONDS", "600"))
AUTO_RELEASE = os.getenv("CT_AUTO_RELEASE", "1") == "1"  # mise en prod après promotion
AUTO_PROMOTE = os.getenv("CT_AUTO_PROMOTE", "1") == "1"  # 0 : canary laissé au Lab 7
LOCAL_CI = os.getenv("CT_LOCAL_CI", "0") == "1"  # 1 : build local au lieu de GitHub

cfg = load_config()


# --- 1. Un lot récent, avec une dérive ---------------------------------------------------
def make_drifted_batch(df: pd.DataFrame, factor: float = 1.5) -> tuple[pd.DataFrame, list[str]]:
    """Variables numériques continues (> 20 valeurs distinctes) multipliées par factor.

    Simule un changement de population (montants, durées… plus élevés). Les étiquettes
    restent celles d'origine : un lot récent dont on connaît déjà l'issue des crédits.
    """
    columns = [c for c in cfg.numeric if df[c].nunique() > 20]
    drifted = df.copy()
    drifted[columns] = drifted[columns].astype("float64") * factor
    return drifted, columns


# --- 2. Détection avec Evidently 0.7 -----------------------------------------------------
def drift_summary(reference: pd.DataFrame, current: pd.DataFrame, html: Path | None = None):
    """Rapport DataDriftPreset résumé en un événement : part et liste des variables en dérive."""
    from evidently import DataDefinition, Dataset, Report
    from evidently.presets import DataDriftPreset

    definition = DataDefinition(numerical_columns=cfg.numeric, categorical_columns=cfg.categorical)
    snapshot = Report([DataDriftPreset()]).run(
        current_data=Dataset.from_pandas(current[cfg.features], data_definition=definition),
        reference_data=Dataset.from_pandas(reference[cfg.features], data_definition=definition),
    )
    if html:
        html.parent.mkdir(parents=True, exist_ok=True)
        snapshot.save_html(str(html))
    share, drifted = 0.0, []
    for metric in snapshot.dict()["metrics"]:
        conf = metric["config"]
        if conf["type"].endswith("DriftedColumnsCount"):
            share = float(metric["value"]["share"])
        elif conf["type"].endswith("ValueDrift"):
            value, threshold = float(metric["value"]), float(conf["threshold"])
            # p-value (K-S, chi²…) : dérive si < seuil ; distance (Wasserstein…) : si >= seuil
            is_drift = value < threshold if "p_value" in conf["method"] else value >= threshold
            if is_drift:
                drifted.append(conf["column"])
    return {"drift_share": round(share, 4), "drifted_features": drifted}


def log_drift_run(summary: dict, current: Path, html: Path) -> dict:
    """Range le rapport ET le lot dans MLflow : le pipeline CT y lira ses données."""
    import mlflow

    mlflow.set_experiment(DRIFT_EXPERIMENT)
    with mlflow.start_run(run_name=f"drift-{time.strftime('%Y%m%d-%H%M%S')}") as run:
        mlflow.set_tag("dataset", cfg.name)
        mlflow.set_tag("drifted_features", ",".join(summary["drifted_features"]))
        mlflow.log_metric("drift_share", summary["drift_share"])
        mlflow.log_artifact(str(html))
        mlflow.log_artifact(str(current), artifact_path="batch")
    base = f"runs:/{run.info.run_id}"
    return {"data_uri": f"{base}/batch/{current.name}", "report_uri": f"{base}/{html.name}"}


def post(url: str, event: dict) -> dict:
    token = os.getenv("CT_WEBHOOK_TOKEN", "")
    req = urllib.request.Request(
        url,
        data=json.dumps(event).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as err:  # 401 (jeton), 422 (événement), 502 (KFP)…
        return {"http_status": err.code, **json.loads(err.read() or b"{}")}


# --- 3. Le webhook -------------------------------------------------------------------------
class DriftEvent(BaseModel):
    """Événement de dérive ; les champs inconnus sont ignorés (producteurs variés)."""

    model_config = ConfigDict(extra="ignore")
    source: str = "evidently"
    model: str = MODEL_NAME
    dataset: str | None = None
    drift_share: float = Field(ge=0.0, le=1.0)
    drifted_features: list[str] = []
    reference: str | None = None
    window_minutes: int | None = None
    timestamp: str | None = None
    data_uri: str = ""  # lot étiqueté à apprendre (vide : la source, src.download)
    report_uri: str | None = None


app = FastAPI(title="Déclencheur du ré-entraînement (Lab 6)")
STATE: dict = {"busy": False, "last_trigger": 0.0, "last_run_id": None, "history": []}
LOCK = threading.Lock()


def check_token(authorization: str | None) -> None:
    expected = os.getenv("CT_WEBHOOK_TOKEN")
    if not expected:
        raise HTTPException(503, "CT_WEBHOOK_TOKEN n'est pas défini côté serveur")
    given = (authorization or "").removeprefix("Bearer ").strip()
    if not secrets.compare_digest(given, expected):
        raise HTTPException(401, "jeton absent ou invalide")


def decide(event: DriftEvent) -> tuple[bool, str]:
    if event.dataset not in (None, cfg.name):
        raise HTTPException(422, f"dataset « {event.dataset} » : ce service gère « {cfg.name} »")
    if event.model != MODEL_NAME:
        return False, f"modèle « {event.model} » non géré"
    if event.drift_share < MIN_DRIFT_SHARE:
        return False, f"drift_share {event.drift_share} < {MIN_DRIFT_SHARE}"
    if STATE["busy"]:
        return False, f"un ré-entraînement est déjà en cours ({STATE['last_run_id']})"
    elapsed = time.time() - STATE["last_trigger"]
    if elapsed < COOLDOWN_SECONDS:
        return False, f"dernier ré-entraînement il y a {elapsed:.0f} s (< {COOLDOWN_SECONDS} s)"
    features = ", ".join(event.drifted_features) or "non précisées"
    return True, f"dérive sur {event.drift_share:.0%} des variables ({features})"


def submit(event: DriftEvent) -> str:
    """Compile ct-pipeline avec le code du repo et crée un run KFP ; renvoie son id."""
    import kfp

    from pipelines.ct_pipeline import ct_pipeline

    run = kfp.Client(host=KFP_HOST).create_run_from_pipeline_func(
        ct_pipeline,
        arguments={
            "data_uri": event.data_uri,
            "trigger_source": event.source,
            "drift_share": event.drift_share,
        },
        run_name=f"ct-{event.source}-{time.strftime('%Y%m%d-%H%M%S')}",
        experiment_name=KFP_EXPERIMENT,
        enable_caching=False,
    )
    return run.run_id


def promoted_version(run_id: str) -> str | None:
    """La version @champion si c'est CE run KFP qui l'a produite (tag de register_challenger)."""
    from mlflow import MlflowClient

    champion = MlflowClient().get_model_version_by_alias(MODEL_NAME, "champion")
    return champion.version if champion.tags.get("kfp_run_id") == run_id else None


def follow(run_id: str, event: DriftEvent) -> None:
    """En arrière-plan : attend la fin du run, puis met en production si promotion."""
    import kfp

    from pipelines import gitops

    entry = {"run_id": run_id, "source": event.source, "state": "RUNNING"}
    STATE["history"].append(entry)
    try:
        run = kfp.Client(host=KFP_HOST).wait_for_run_completion(run_id, timeout=3600)
        entry["state"] = str(run.state)
        version = promoted_version(run_id) if entry["state"] == "SUCCEEDED" else None
        entry["promoted_version"] = version
        print(f"Run {run_id} : {entry['state']}, nouveau @champion : {version}", flush=True)
        if version and AUTO_RELEASE:
            note = f"(run KFP {run_id[:8]}, drift_share={event.drift_share})"
            gitops.release(LOCAL_CI, AUTO_PROMOTE, percent=10, timeout=1800, note=note)
            entry["released"] = True
    except BaseException as exc:  # SystemExit des attentes de gitops compris
        entry["error"] = repr(exc)
        print(f"Run {run_id} : échec du suivi ou de la mise en prod : {exc!r}", flush=True)
    finally:
        STATE["busy"] = False


def handle(event: DriftEvent) -> JSONResponse:
    with LOCK:  # deux alertes simultanées ne lancent qu'un seul run
        retrain, reason = decide(event)
        if not retrain:
            return JSONResponse({"status": "skipped", "reason": reason}, status_code=200)
        try:
            run_id = submit(event)
        except Exception as exc:  # KFP injoignable (port-forward arrêté ?), refus de l'API…
            body = {"status": "error", "reason": f"soumission à KFP ({KFP_HOST}) : {exc!r}"}
            return JSONResponse(body, status_code=502)
        STATE.update(busy=True, last_trigger=time.time(), last_run_id=run_id)
    threading.Thread(target=follow, args=(run_id, event), daemon=True).start()
    body = {"status": "triggered", "reason": reason, "run_id": run_id}
    return JSONResponse(body, status_code=202)


@app.get("/health")
def health():
    return {"status": "ok", "busy": STATE["busy"], "last_run_id": STATE["last_run_id"]}


@app.get("/runs")
def runs():
    return STATE["history"]


@app.post("/drift")
def drift(event: DriftEvent, authorization: str | None = Header(None)):
    check_token(authorization)
    return handle(event)


@app.post("/alertmanager")
def alertmanager(payload: dict, authorization: str | None = Header(None)):
    """Format webhook d'Alertmanager : alertes « firing » portant le label ct_trigger="true"."""
    check_token(authorization)
    alerts = [
        a
        for a in payload.get("alerts", [])
        if a.get("status") == "firing" and a.get("labels", {}).get("ct_trigger") == "true"
    ]
    if not alerts:
        return JSONResponse({"status": "skipped", "reason": "aucune alerte ct_trigger"}, 200)

    def value(alert: dict, key: str, default=None):
        return alert.get("annotations", {}).get(key) or alert.get("labels", {}).get(key) or default

    event = DriftEvent(
        source="alertmanager",
        drift_share=max(float(value(a, "drift_share", 1.0)) for a in alerts),
        drifted_features=sorted({value(a, "feature") for a in alerts} - {None}),
        data_uri=next((value(a, "data_uri") for a in alerts if value(a, "data_uri")), ""),
    )
    return handle(event)


# --- Ligne de commande -------------------------------------------------------------------
def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_sim = sub.add_parser("simulate")
    p_sim.add_argument("--factor", type=float, default=1.5)
    p_sim.add_argument("--shuffle-labels", action="store_true", help="étiquettes corrompues")
    p_det = sub.add_parser("detect")
    p_det.add_argument("--reference", type=Path, default=REFERENCE)
    p_det.add_argument("--current", type=Path, default=CURRENT)
    p_det.add_argument("--no-send", action="store_true", help="rapport seulement")
    p_send = sub.add_parser("send")
    p_send.add_argument("--event", type=Path, required=True, help="fichier JSON")
    sub.add_parser("serve")
    args = parser.parse_args(argv)

    if args.cmd == "simulate":
        drifted, columns = make_drifted_batch(pd.read_csv(cfg.raw_path), args.factor)
        if args.shuffle_labels:  # test de la gate : un lot aux étiquettes mélangées
            drifted[cfg.target] = drifted[cfg.target].sample(frac=1, random_state=0).to_numpy()
        CURRENT.parent.mkdir(parents=True, exist_ok=True)
        drifted.to_csv(CURRENT, index=False)
        print(f"{CURRENT} : {len(drifted)} demandes, {', '.join(columns)} x {args.factor:g}")
    elif args.cmd == "detect":
        html = REPORT_DIR / "drift_report.html"
        summary = drift_summary(pd.read_csv(args.reference), pd.read_csv(args.current), html)
        event = {"source": "evidently-drift", "model": MODEL_NAME, "dataset": cfg.name,
                 **summary, "reference": str(args.reference),
                 "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z")}  # fmt: skip
        event |= log_drift_run(summary, args.current, html)
        (REPORT_DIR / "drift_event.json").write_text(json.dumps(event, indent=2) + "\n")
        print(json.dumps(event, indent=2, ensure_ascii=False))
        if not args.no_send:
            print("Webhook :", json.dumps(post(WEBHOOK_URL, event), ensure_ascii=False))
    elif args.cmd == "send":
        event = json.loads(args.event.read_text(encoding="utf-8"))
        print("Webhook :", json.dumps(post(WEBHOOK_URL, event), ensure_ascii=False))
    else:
        import uvicorn

        if not os.getenv("CT_WEBHOOK_TOKEN"):
            sys.exit("Définissez CT_WEBHOOK_TOKEN dans .env (voir l'étape 6.2)")
        uvicorn.run(app, host="127.0.0.1", port=PORT)  # le poste seulement, pas le réseau


if __name__ == "__main__":
    main()
```

Points clés :

- **`detect`** produit l'événement (part et liste des variables en dérive) à partir du
  rapport Evidently, range rapport et lot dans MLflow (`data_uri = runs:/…`), puis l'envoie.
  Le Lab 7 enverra le même événement depuis son job de monitoring.
- **Le webhook décide** : seuil (`CT_MIN_DRIFT_SHARE`, 10 % des variables), un seul
  ré-entraînement à la fois, 10 min minimum entre deux (une alerte qui boucle ne lance pas
  dix pipelines). Le producteur rapporte, le webhook décide.
- **`submit`** compile `ct-pipeline` avec le code du repo et crée un run dans l'expérience KFP
  `scoring-ct` (plus d'identifiant de pipeline à recopier depuis l'UI).
- **`follow`** attend la fin du run, regarde dans MLflow si ce run a produit un nouveau
  `@champion`, et si oui lance la mise en production (`gitops.release`, étape 9).
- Le serveur n'écoute que sur `127.0.0.1` : il n'est pas exposé au réseau de la salle.

### 6.4 Lancer le webhook et produire un rapport

Dans un **terminal dédié** (gardez-le ouvert jusqu'à la fin du lab), sans mise en production
automatique pour l'instant :

```bash
cd ~/mlops-cours-2026 && set -a && source .env && set +a
CT_AUTO_RELEASE=0 uv run python -m pipelines.trigger_ct serve
```

Dans votre terminal principal :

```bash
curl -s localhost:8095/health
curl -s -X POST localhost:8095/drift -H "Content-Type: application/json" -d '{"drift_share": 1}'
uv run python -m pipelines.trigger_ct simulate
uv run python -m pipelines.trigger_ct detect --no-send
```

> **Sortie attendue :** `{"status":"ok","busy":false,"last_run_id":null}` ; puis
> `{"detail":"jeton absent ou invalide"}` (401 : pas de jeton) ; puis
> `data/drift/current.csv : 1000 demandes, duration, credit_amount, age x 1.5` ; enfin
> l'événement :

```json
{
  "source": "evidently-drift",
  "model": "scoring-model",
  "dataset": "german-credit",
  "drift_share": 0.15,
  "drifted_features": [
    "duration",
    "credit_amount",
    "age"
  ],
  "reference": "data/processed/train.csv",
  "timestamp": "2026-10-12T14:03:21+0200",
  "data_uri": "runs:/ae1edd5b21b04190b0d0b34c8b17b1f5/batch/current.csv",
  "report_uri": "runs:/ae1edd5b21b04190b0d0b34c8b17b1f5/drift_report.html"
}
```

> Trois variables sur vingt dérivent (test de Kolmogorov-Smirnov, p-value < 0,05) : 15 %,
> au-dessus du seuil de 10 %. Ouvrez `reports/drift/drift_report.html` : distributions de
> référence et récentes, variable par variable. Le même rapport est dans MLflow (expérience
> `scoring-drift`).

## Étape 7/9 — Pipeline CT : webhook → KFP → nouveau modèle (30 min)

### 7.1 Le pipeline de ré-entraînement

```python
# Fichier : pipelines/ct_pipeline.py
"""Pipeline KFP « ct-pipeline » du Lab 6 : ré-entraînement déclenché par une dérive.

ingest (lot récent) -> validate -> prepare -> train -> evaluate      composants du Lab 2
                    -> register_challenger -> promotion_gate         nouveaux (Lab 6)

Le pipeline ne touche PAS au cluster : il produit un @champion dans MLflow, et la mise en
production passe par Git (pipelines/gitops.py), comme pour un humain.
Compilation : python -m pipelines.ct_pipeline   (écrit ct_pipeline.yaml)
Les hyper-paramètres sont ceux de params.yaml, lus à la compilation : le CT ré-entraîne
la configuration validée, sur des données plus récentes.
"""

from pathlib import Path

import yaml
from kfp import compiler, dsl, kubernetes
from kfp.dsl import Dataset, Input, Markdown, Metrics, Output

from pipelines.components import (
    MLFLOW_URI,
    PIPELINE_IMAGE,
    evaluate_model,
    prepare_features,
    train_model,
    validate_data,
)

TRAIN = yaml.safe_load(Path("params.yaml").read_text(encoding="utf-8"))["train"]


@dsl.component(base_image=PIPELINE_IMAGE, install_kfp_package=False)
def ingest_ct_data(data_uri: str, mlflow_uri: str, raw_data: Output[Dataset]) -> None:
    """Le lot de données étiquetées à apprendre : data_uri (artefact MLflow), sinon la source."""
    import shutil

    import mlflow
    import pandas as pd

    from pipelines.stage import run_stage
    from src.dataset_config import load_config
    from src.train import file_md5

    cfg = load_config()
    if data_uri:
        # Lot déposé avec le rapport de dérive (runs:/<id>/…) : le serveur MLflow fait
        # proxy des artefacts, le pod n'a besoin d'aucun identifiant S3.
        local = mlflow.artifacts.download_artifacts(artifact_uri=data_uri, tracking_uri=mlflow_uri)
        shutil.copyfile(local, raw_data.path)
    else:
        run_stage("src.download", outputs={cfg.raw_path: raw_data.path})
    raw_data.metadata["dataset"] = cfg.name
    raw_data.metadata["source"] = data_uri or "src.download"
    raw_data.metadata["rows"] = len(pd.read_csv(raw_data.path))
    raw_data.metadata["md5"] = file_md5(raw_data.path)


@dsl.component(base_image=PIPELINE_IMAGE, install_kfp_package=False)
def register_challenger(
    run_id: str,
    mlflow_uri: str,
    kfp_run_id: str,
    trigger_source: str,
    drift_share: float,
    data_uri: str,
) -> str:
    """Enregistre le modèle du run comme nouvelle version, alias @challenger SEULEMENT.

    Contrairement à src.promote (Lab 1), aucun @champion ici : c'est le rôle de la gate.
    """
    import mlflow
    from mlflow import MlflowClient

    from src.promote import MODEL_NAME

    mlflow.set_tracking_uri(mlflow_uri)
    client = MlflowClient()
    # Pourquoi ce run existe : traçabilité du ré-entraînement (lu par make check-m6)
    context = {"ct_trigger": trigger_source, "ct_drift_share": f"{drift_share:.4f}",
               "ct_data_uri": data_uri or "src.download"}  # fmt: skip
    for key, value in context.items():
        client.set_tag(run_id, key, value)

    model_id = client.get_run(run_id).outputs.model_outputs[0].model_id  # MLflow 3
    version = mlflow.register_model(f"models:/{model_id}", MODEL_NAME).version
    for key, value in {**context, "kfp_run_id": kfp_run_id, "promotion": "pending"}.items():
        client.set_model_version_tag(MODEL_NAME, version, key, value)
    client.set_registered_model_alias(MODEL_NAME, "challenger", version)
    print(f"{MODEL_NAME} version {version} -> @challenger")
    return str(version)


@dsl.component(base_image=PIPELINE_IMAGE, install_kfp_package=False)
def promotion_gate(
    version: str,
    test_data: Input[Dataset],
    mlflow_uri: str,
    max_cost_increase: float,
    gate_metrics: Output[Metrics],
    report: Output[Markdown],
) -> str:
    """Gate challenger -> champion, sur les MÊMES données récentes pour les deux modèles.

    1. métrique primaire du challenger >= metrics.promotion_threshold (dataset.yaml) ;
    2. coût métier du challenger <= coût du champion actuel x (1 + max_cost_increase).
    Chaque modèle décide à SON seuil (param decision_threshold de son run, Lab 1).
    Renvoie « promoted » ou « rejected » : un refus n'est pas une erreur du pipeline.
    """
    import mlflow
    from mlflow import MlflowClient
    from mlflow.exceptions import MlflowException

    from src.dataset_config import load_config
    from src.promote import MODEL_NAME
    from src.train import compute_metrics

    cfg = load_config()
    mlflow.set_tracking_uri(mlflow_uri)
    client = MlflowClient()
    X, y = cfg.read_xy(test_data.path)

    def evaluate(v: str) -> dict:
        run_id = client.get_model_version(MODEL_NAME, v).run_id
        model = mlflow.sklearn.load_model(f"models:/{MODEL_NAME}/{v}")
        threshold = float(client.get_run(run_id).data.params["decision_threshold"])
        return compute_metrics(cfg, y, model.predict_proba(X)[:, 1], threshold)

    try:
        champion = client.get_model_version_by_alias(MODEL_NAME, "champion").version
    except MlflowException:
        champion = None  # premier modèle : seule la règle 1 s'applique
    new = evaluate(version)
    old = evaluate(champion) if champion else None

    metric, cost = cfg.primary_metric, "business_cost"
    checks = {f"{metric} >= {cfg.promotion_threshold}": new[metric] >= cfg.promotion_threshold}
    if old is not None:
        limit = old[cost] * (1 + max_cost_increase)
        checks[f"{cost} <= {limit:g} (champion v{champion})"] = new[cost] <= limit
    passed = all(checks.values())

    for name, value in new.items():
        gate_metrics.log_metric(f"challenger_{name}", float(value))
    for name, value in (old or {}).items():
        gate_metrics.log_metric(f"champion_{name}", float(value))
    lines = [f"## Gate de promotion : version {version} {'PROMUE' if passed else 'REFUSÉE'}", "",
             "| Règle | Résultat |", "|---|---|"]  # fmt: skip
    lines += [f"| {rule} | {'OK' if ok else 'ÉCHEC'} |" for rule, ok in checks.items()]
    lines += ["", "| Modèle | " + metric + " | coût métier |", "|---|---|---|",
              f"| challenger v{version} | {new[metric]:.4f} | {new[cost]:g} |"]  # fmt: skip
    if old is not None:
        lines.append(f"| champion v{champion} | {old[metric]:.4f} | {old[cost]:g} |")
    with open(report.path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print("\n".join(lines))

    tags = {"promotion": "passed" if passed else "rejected",
            "validation_status": "passed" if passed else "failed",
            metric: f"{new[metric]:.4f}", cost: f"{new[cost]:g}"}  # fmt: skip
    if passed:
        # Retour arrière possible (gitops.py rollback) : on note le champion remplacé
        tags["previous_champion"] = champion or "none"
        client.set_registered_model_alias(MODEL_NAME, "champion", version)
    for key, value in tags.items():
        client.set_model_version_tag(MODEL_NAME, version, key, value)
    return "promoted" if passed else "rejected"


@dsl.pipeline(
    name="ct-pipeline",
    description="CT : ingest -> validate -> prepare -> train -> evaluate -> challenger -> gate",
)
def ct_pipeline(
    data_uri: str = "",  # artefact MLflow du lot récent ; vide = source (src.download)
    trigger_source: str = "manual",  # evidently-drift, alertmanager, manual…
    drift_share: float = 0.0,  # part des variables en dérive (rapport Evidently)
    max_cost_increase: float = 0.0,  # tolérance de la gate sur le coût métier (0 = aucune)
    mlflow_uri: str = MLFLOW_URI,
):
    ingest_task = ingest_ct_data(data_uri=data_uri, mlflow_uri=mlflow_uri)
    ingest_task.set_retry(num_retries=3, backoff_duration="30s")
    ingest_task.set_cpu_limit("500m").set_memory_limit("512Mi")
    kubernetes.set_timeout(ingest_task, 600)
    ingest_task.set_caching_options(enable_caching=False)  # le lot change à chaque dérive

    # Lab 2 (et Lab 3) : la même gate de données que le pipeline d'entraînement
    validate_task = validate_data(raw_data=ingest_task.outputs["raw_data"])
    validate_task.set_memory_limit("512Mi")

    prep_task = prepare_features(raw_data=ingest_task.outputs["raw_data"])
    prep_task.after(validate_task)
    prep_task.set_memory_limit("1Gi")

    train_task = train_model(
        raw_data=ingest_task.outputs["raw_data"],
        train_data=prep_task.outputs["train_data"],
        test_data=prep_task.outputs["test_data"],
        model_type=TRAIN["model"],
        C=TRAIN["C"],
        class_weight=str(TRAIN["class_weight"]),
        n_estimators=TRAIN["n_estimators"],
        max_depth=str(TRAIN["max_depth"]),
        learning_rate=TRAIN["learning_rate"],
        random_state=TRAIN["random_state"],
        mlflow_uri=mlflow_uri,
        kfp_run_id=dsl.PIPELINE_JOB_ID_PLACEHOLDER,
    )
    train_task.set_cpu_request("500m").set_cpu_limit("2")
    train_task.set_memory_request("512Mi").set_memory_limit("2Gi")
    kubernetes.set_timeout(train_task, 1800)
    train_task.set_caching_options(enable_caching=False)

    eval_task = evaluate_model(
        model=train_task.outputs["model"],
        test_data=prep_task.outputs["test_data"],
        run_id=train_task.outputs["Output"],
        mlflow_uri=mlflow_uri,
    )
    eval_task.set_memory_limit("1Gi")

    register_task = register_challenger(
        run_id=train_task.outputs["Output"],
        mlflow_uri=mlflow_uri,
        kfp_run_id=dsl.PIPELINE_JOB_ID_PLACEHOLDER,
        trigger_source=trigger_source,
        drift_share=drift_share,
        data_uri=data_uri,
    )
    register_task.after(eval_task)  # on n'enregistre qu'un modèle évalué
    register_task.set_memory_limit("1Gi")
    register_task.set_caching_options(enable_caching=False)

    gate_task = promotion_gate(
        version=register_task.output,
        test_data=prep_task.outputs["test_data"],
        mlflow_uri=mlflow_uri,
        max_cost_increase=max_cost_increase,
    )
    gate_task.set_memory_limit("1Gi")
    gate_task.set_caching_options(enable_caching=False)


if __name__ == "__main__":
    compiler.Compiler().compile(ct_pipeline, package_path="ct_pipeline.yaml")
```

Ce qu'il faut retenir :

- **Réutilisation** : `validate_data`, `prepare_features`, `train_model` et `evaluate_model`
  sont les composants du Lab 2, dans la même image projet : le code d'entraînement n'est
  jamais recopié. Si le Lab 3 a durci `validate_data` (Great Expectations), le CT en profite
  sans changement. Seuls trois composants sont nouveaux.
- **`register_challenger`** n'utilise pas `src.promote` : celui-ci posait `@champion` dès que
  le seuil était atteint. Ici, le nouveau modèle n'est d'abord que `@challenger`.
- **`promotion_gate`** compare challenger et champion **sur les mêmes données récentes**, chacun
  à son propre seuil de décision : métrique primaire ≥ `promotion_threshold`
  (`dataset.yaml`) ET coût métier non dégradé. Elle note `previous_champion` sur la version
  promue (pour un retour arrière) et publie un rapport Markdown visible dans l'UI KFP.
- **Le pipeline ne touche pas au cluster** : l'ancien énoncé patchait l'InferenceService
  depuis KFP ; Argo CD annulerait ce patch (selfHeal). La mise en prod passe par Git.

> [!IMPORTANT]
> **Sécurité des CT automatiques**
> Un pipeline CT qui met à jour directement la prod est dangereux : une étiquette corrompue,
> et un mauvais modèle part en production. Les garde-fous de ce lab : (1) la gate refuse un
> modèle sous le seuil ou plus coûteux que le champion ; (2) la mise en prod passe par Git,
> donc par la CI (tests, test de fumée) puis par staging ; (3) la prod ne reçoit d'abord que
> 10 % du trafic (étape 8). En production réelle, et pour un modèle de crédit (haut risque au
> sens de l'AI Act, Lab 8), on ajouterait une validation humaine : le bot ouvre une PR au lieu
> de pousser sur `main`.

### 7.2 Compiler et tester

Les tests du ré-entraînement (sans KFP ni MLflow : la soumission du run est remplacée par un
faux) :

```python
# Fichier : tests/test_ct.py
"""Tests du ré-entraînement continu : pipelines KFP compilables, détection Evidently,
décisions du webhook. Sans KFP ni MLflow : la soumission du run est remplacée par un faux."""

import pytest
import yaml
from fastapi.testclient import TestClient
from kfp import compiler


def test_pipelines_kfp_compilent(tmp_path):
    """Les deux pipelines (Lab 2-3 et Lab 6) se compilent avec le code du repo."""
    from pipelines.ct_pipeline import ct_pipeline
    from pipelines.scoring_pipeline import scoring_pipeline

    compiler.Compiler().compile(scoring_pipeline, str(tmp_path / "scoring.yaml"))
    compiler.Compiler().compile(ct_pipeline, str(tmp_path / "ct.yaml"))
    spec = next(yaml.safe_load_all((tmp_path / "ct.yaml").read_text()))  # 1er document
    tasks = spec["root"]["dag"]["tasks"]
    for name in ("ingest-ct-data", "validate-data", "train-model", "promotion-gate"):
        assert name in tasks
    assert tasks["train-model"]["cachingOptions"] == {}  # cache désactivé : toujours ré-entraîner
    assert "register-challenger" in tasks["promotion-gate"]["dependentTasks"]


def test_drift_evidently(contract, make_frame):
    from pipelines.trigger_ct import drift_summary, make_drifted_batch

    reference = make_frame(contract)
    same = drift_summary(reference, reference.sample(frac=1.0, random_state=1))
    assert same == {"drift_share": 0.0, "drifted_features": []}
    drifted, columns = make_drifted_batch(reference, factor=1.5)
    summary = drift_summary(reference, drifted)
    assert columns and set(summary["drifted_features"]) == set(columns)
    assert summary["drift_share"] == pytest.approx(len(columns) / len(contract.features), 0.01)


@pytest.fixture
def webhook(monkeypatch):
    from pipelines import trigger_ct

    monkeypatch.setenv("CT_WEBHOOK_TOKEN", "secret-de-test")
    # réglages par défaut, quel que soit l'environnement (.env, CI)
    monkeypatch.setattr(trigger_ct, "MIN_DRIFT_SHARE", 0.1)
    monkeypatch.setattr(trigger_ct, "COOLDOWN_SECONDS", 600)
    monkeypatch.setattr(trigger_ct, "submit", lambda event: "run-42")  # pas de KFP
    monkeypatch.setattr(trigger_ct, "follow", lambda run_id, event: None)  # pas de suivi
    monkeypatch.setattr(trigger_ct, "STATE", {"busy": False, "last_trigger": 0.0,
                                              "last_run_id": None, "history": []})  # fmt: skip
    return TestClient(trigger_ct.app), trigger_ct


AUTH = {"Authorization": "Bearer secret-de-test"}


def test_webhook_authentification(webhook, monkeypatch):
    client, _ = webhook
    event = {"drift_share": 0.5}
    assert client.post("/drift", json=event).status_code == 401
    bad = {"Authorization": "Bearer mauvais"}
    assert client.post("/drift", json=event, headers=bad).status_code == 401
    monkeypatch.delenv("CT_WEBHOOK_TOKEN")
    assert client.post("/drift", json=event, headers=AUTH).status_code == 503


def test_webhook_decisions(webhook, contract):
    client, trigger_ct = webhook
    assert client.post("/drift", json={"drift_share": 2}, headers=AUTH).status_code == 422
    wrong = {"drift_share": 0.5, "dataset": "autre-dataset"}
    assert client.post("/drift", json=wrong, headers=AUTH).status_code == 422
    r = client.post("/drift", json={"drift_share": 0.01}, headers=AUTH)
    assert r.status_code == 200 and r.json()["status"] == "skipped"

    event = {"source": "evidently-drift", "dataset": contract.name, "drift_share": 0.43,
             "drifted_features": ["x"], "champ_inconnu": "ignoré"}  # fmt: skip
    r = client.post("/drift", json=event, headers=AUTH)
    assert r.status_code == 202 and r.json() == {
        "status": "triggered",
        "reason": "dérive sur 43% des variables (x)",
        "run_id": "run-42",
    }
    assert client.get("/health").json()["last_run_id"] == "run-42"
    # un seul ré-entraînement à la fois, puis délai minimal entre deux
    r = client.post("/drift", json=event, headers=AUTH)
    assert r.json()["status"] == "skipped" and "en cours" in r.json()["reason"]
    trigger_ct.STATE["busy"] = False
    r = client.post("/drift", json=event, headers=AUTH)
    assert r.json()["status"] == "skipped" and "dernier ré-entraînement" in r.json()["reason"]


def test_webhook_alertmanager(webhook):
    client, _ = webhook
    alert = {"status": "firing", "labels": {"alertname": "ScoringDataDrift", "ct_trigger": "true",
             "feature": "x"}, "annotations": {"drift_share": "0.4"}}  # fmt: skip
    resolved = alert | {"status": "resolved"}
    r = client.post("/alertmanager", json={"alerts": [resolved]}, headers=AUTH)
    assert r.json()["status"] == "skipped"
    r = client.post("/alertmanager", json={"alerts": [alert]}, headers=AUTH)
    assert r.status_code == 202 and r.json()["run_id"] == "run-42"
```

```bash
uv run python -m pipelines.ct_pipeline && grep -c "^    exec-" ct_pipeline.yaml
uv run pytest -q
```

> **Sortie attendue :** `7` (sept exécuteurs : un par composant), puis `29 passed` (24 + 5).

### 7.3 Déclencher le ré-entraînement

Le webhook tourne toujours (`CT_AUTO_RELEASE=0`). Envoyez l'événement de dérive :

```bash
uv run python -m pipelines.trigger_ct send --event reports/drift/drift_event.json
```

> **Sortie attendue :** `Webhook : {"status": "triggered", "reason": "dérive sur 15% des
> variables (duration, credit_amount, age)", "run_id": "…"}` et, dans le terminal du webhook,
> `202 Accepted`.

Ouvrez l'UI KFP (`http://localhost:8080`), expérience **scoring-ct** : le run `ct-evidently-drift-…`
enchaîne `ingest-ct-data` → `validate-data` → `prepare-features` → `train-model` →
`evaluate-model` → `register-challenger` → `promotion-gate`, en 3 à 5 minutes. Le rapport de la
gate est l'artefact `report` de `promotion-gate` (Markdown, affiché par l'UI) :

```text
## Gate de promotion : version 5 PROMUE

| Règle | Résultat |
|---|---|
| roc_auc >= 0.7 | OK |
| business_cost <= 124 (champion v4) | OK |

| Modèle | roc_auc | coût métier |
|---|---|---|
| challenger v5 | 0.8094 | 108 |
| champion v4 | 0.8050 | 124 |
```

> Vos numéros de version dépendent de votre historique. Le champion, appris sur l'ancienne
> population, coûte 124 sur les données récentes ; le modèle ré-entraîné retrouve 108, le coût
> du Lab 1. Dans le terminal du webhook : `Run … : SUCCEEDED, nouveau @champion : 5`.

```bash
uv run python -c "from mlflow import MlflowClient; c = MlflowClient(); \
mv = c.get_model_version_by_alias('scoring-model', 'champion'); \
print(mv.version, {k: mv.tags[k] for k in ('promotion', 'previous_champion', 'ct_trigger')})"
```

> **Sortie attendue :** `5 {'promotion': 'passed', 'previous_champion': '4', 'ct_trigger':
> 'evidently-drift'}` (numéros relevés sur un Registry réduit au Lab 1 : chez vous, après les
> runs des Labs 2 et 3, ils sont plus élevés ; ce qui compte est `previous_champion` = l'ancien
> champion). Le Registry a un nouveau champion… mais la prod sert toujours l'ancien modèle :
> rien n'est en production tant que rien n'est dans Git.

### 7.4 Commiter le ré-entraînement

```bash
git add pipelines tests
git commit -m "Lab 6: ré-entraînement continu (webhook, pipeline CT, gate)"
git push -u origin lab/m6-ct
gh pr create
```

Relecture, approbation, fusion, puis `git switch main && git pull`.

> **Sortie attendue :** `pipelines/**` et `tests/**` sont dans les `paths` : la CI teste la PR
> (29 tests), puis, à la fusion, déploie l'image `2.1.6` en staging. Le modèle n'a pas changé :
> il est toujours dans `packaging/model/`, celui du Lab 4. Le webhook, lui, continue de tourner
> dans son terminal : il exécute le code de votre copie de travail.

## Étape 8/9 — Canary KServe piloté par Git (20 min)

### 8.1 Publier le modèle comme un humain le ferait

D'abord à la main, pour comprendre ce que le bot fera à l'étape 9 : exporter le champion
(Lab 4), commiter le modèle, laisser la CI construire l'image et la déployer en staging. Ce
commit de publication est celui que le bot poussera lui-même (`ct: scoring-model v…`) : comme
lui, il part de `main` à jour (fusion de l'étape 7.4) et va directement sur `main`.

```bash
git switch main && git pull
uv run python packaging/app/export_onnx.py
git add packaging/model && git commit -m "Lab 6: modèle ré-entraîné" && git push
gh run watch
git pull
uv run python -m pipelines.gitops status
```

> **Sortie attendue :** après la CI, staging sert `2.1.7` avec `model_version` = le nouveau
> champion ; la prod sert toujours l'ancienne image.

### 8.2 Canary à 10 %

Mettre en production = un commit qui change l'image de prod ET la part du canary.
`gitops deploy --env prod` prend l'image que staging a validée :

```bash
uv run python -m pipelines.gitops deploy --env prod --canary 10 --push
git show --stat HEAD
```

> **Sortie attendue :** `[…] gitops(prod): canary 10% 2.1.7 -> origin/main (Argo CD
> l'appliquera)`, un commit qui modifie `kustomization.yaml` (newName, newTag) et
> `canary.yaml` (10).

La fonction qui écrit ce commit (extrait de `pipelines/gitops.py`) :

```python
    if env == "prod":
        set_canary(root, canary)
        paths.append(CANARY)
        message = f"gitops(prod): canary {canary}% {tag}"
```

Moins de 70 s plus tard :

```bash
kubectl get isvc scoring-model -n scoring
ISVC_HOST=scoring-model-predictor.scoring.example.com
for i in $(seq 1 200); do
  curl -s -H "Host: ${ISVC_HOST}" http://localhost:30080/version | grep -oE '"version":"[^"]+"'
done | sort | uniq -c
```

> **Sortie attendue :** `PREV 90` / `LATEST 10`, puis environ `180 "version":"2.0.0"` et
> `20 "version":"2.1.7"` (de 12 à 28 reste normal).

### 8.3 Promouvoir, ou revenir en arrière

```bash
# Le canary se comporte bien : 100 % du trafic vers la nouvelle révision
uv run python -m pipelines.gitops promote --push

# Sinon, retour arrière instantané : 0 % pour le canary (la révision précédente est chaude)
# uv run python -m pipelines.gitops canary 0 --push
# rollback = canary 0 + @champion restauré (si le canary servait le @champion)
# uv run python -m pipelines.gitops rollback --push
```

> **Sortie attendue :** `gitops(prod): promote 100% 2.1.7`, puis `LATEST 100` dans
> `kubectl get isvc` et 200 réponses sur 200 en `2.1.7`. `git log --oneline --
> k8s/overlays/prod` raconte toute l'histoire de la prod : qui, quoi, quand.

| Décision | Fichier | Clé | Valeur |
|---|---|---|---|
| Nouvelle image en prod | `k8s/overlays/prod/kustomization.yaml` | `newName`, `newTag` | image de staging |
| Canary | `k8s/overlays/prod/canary.yaml` | `canaryTrafficPercent` | 10 (ou 50…) |
| Promotion | `k8s/overlays/prod/canary.yaml` | `canaryTrafficPercent` | 100 |
| Retour arrière | `k8s/overlays/prod/canary.yaml` | `canaryTrafficPercent` | 0 |

> [!NOTE]
> **Ce que le Lab 7 ajoutera**
> Ici, c'est vous qui décidez de promouvoir. Au Lab 7, une analyse automatique comparera les
> métriques Prometheus de la nouvelle révision et de la précédente (erreurs, latence,
> distribution des scores), puis appellera les mêmes commandes : `canary 50`, `promote` ou
> `rollback`. La décision reste un commit.

## Étape 9/9 — Démo de bout en bout + rapport (15 min)

### 9.1 Le bot en mode automatique

Arrêtez le webhook (Ctrl-C dans son terminal) et relancez-le avec la mise en production
automatique (le défaut) :

```bash
uv run python -m pipelines.trigger_ct serve
```

Après une promotion par la gate, le webhook appelle `gitops.release` : export du champion,
commit de `packaging/model/` (dans une copie de travail jetable, la vôtre n'est pas touchée),
attente de la CI, vérification de staging (`/version` + prédiction), canary de 10 % en prod,
**analyse naïve** (50 prédictions sur la nouvelle révision, aucune erreur tolérée), puis
promotion à 100 % ou retour arrière. Le Lab 7 remplacera cette analyse naïve par une vraie
comparaison de métriques (`CT_AUTO_PROMOTE=0` laisse alors le canary à 10 %).

### 9.2 Quatre terminaux

- Terminal 1 : `gh run watch` (ou l'onglet Actions).
- Terminal 2 : `kubectl get applications -n argocd -w`.
- Terminal 3 : l'UI KFP (`http://localhost:8080`), expérience `scoring-ct`.
- Terminal 4 : `watch -n 5 kubectl get isvc -A`.

### 9.3 Déclencher le cycle

Une dérive plus forte (variables continues × 2). Le webhook vient de redémarrer : le délai
minimal entre deux ré-entraînements repart de zéro.

```bash
uv run python -m pipelines.trigger_ct simulate --factor 2
date && uv run python -m pipelines.trigger_ct detect
```

> **Sortie attendue :** le cycle complet en 10 à 20 minutes, sans aucune commande de votre part :
> run KFP réussi (gate : PROMUE), puis dans le terminal du webhook
> `[…] ct: scoring-model v6 (run KFP …, drift_share=0.15) -> origin/main`, l'attente de la CI,
> `Image 2.1.8 (modèle v6) en staging`, `gitops(prod): canary 10% 2.1.8`,
> `gitops(prod): promote 100% 2.1.8` et `2.1.8 promue à 100 %`.

```bash
git pull
git log --format='%ci %an | %s' -6
curl -s localhost:8095/runs
```

> **Sortie attendue :** quatre commits signés de vous (le bot pousse avec vos droits) ou de
> `github-actions[bot]` : `ct: scoring-model v6…`, `gitops(staging): …:2.1.8 […]`,
> `gitops(prod): canary 10% 2.1.8`, `gitops(prod): promote 100% 2.1.8`. Leurs horodatages
> donnent le temps de chaque étape du cycle.

### 9.4 Rapport

```bash
cp labs/m6-cicd/starter/rapport-m6.md reports/rapport-m6.md
```

Complétez les sections :

- **Architecture** : schéma des composants (GitHub Actions, GHCR, Git, Argo CD, KServe,
  Evidently, webhook, KFP, MLflow) ; pour chaque flèche, qui pousse et qui tire.
- **Temps du cycle** : dérive → déclenchement → ré-entraînement → image → staging → prod.
  Typiquement 10 à 20 min en local, bien plus avec un vrai modèle.
- **Gates et décisions** : chiffres de la gate, décision du canary.
- **Points d'attention** : sécurité du webhook, gate humaine sur le CT, retour arrière.
- **Différences avec la prod** : ce qu'il faudrait ajouter (secrets managés, bot dans le
  cluster, PR, audit, métriques métier…).
- **Captures d'écran** : Argo CD Synced, run KFP réussi, onglet Actions, canary.

```bash
git switch main && git pull && git switch -c lab/m6-rapport
git add reports/rapport-m6.md && git commit -m "Lab 6: rapport"
git push -u origin lab/m6-rapport
gh pr create
```

Relecture, approbation, fusion, puis `git switch main && git pull` : `main` contient le lab
complet, et `make check-m6` se lance de là.

> [!NOTE]
> **Second membre du binôme (ou nouveau poste) : remettre votre cluster à niveau**
> Le dépôt Git est commun : une fois Argo CD installé sur **votre** cluster (Lab 5 à niveau),
> staging et prod y suivent `main`, comme chez votre partenaire, avec les mêmes images GHCR.
> Le ré-entraînement, lui, se rejoue dans votre MLflow et votre KFP :
>
> ```bash
> cd ~/mlops-cours-2026 && git switch main && git pull && uv sync
> source .venv/bin/activate && set -a && source .env && set +a
> make argocd
> kubectl apply -f k8s/argocd-app.yaml
> kubectl get applications -n argocd -w     # Ctrl-C quand tout est Synced / Healthy
> grep -q '^CT_WEBHOOK_TOKEN=' .env || echo "CT_WEBHOOK_TOKEN=$(openssl rand -hex 16)" >> .env
> make kfp-ui
> # dans un second terminal : set -a && source .env && set +a puis
> #   CT_AUTO_RELEASE=0 uv run python -m pipelines.trigger_ct serve
> uv run python -m pipelines.trigger_ct simulate
> uv run python -m pipelines.trigger_ct detect
> make check-m6
> ```
>
> `CT_AUTO_RELEASE=0` : votre ré-entraînement s'arrête au Registry de **votre** MLflow et ne
> pousse rien sur `main`. Conséquence assumée : l'item « Promotion : @champion … servi en
> prod » reste rouge sur votre cluster, car le modèle servi (commun, puisque `main` est
> commun) vient du MLflow de votre partenaire, dont les numéros de version diffèrent des
> vôtres. La démo se fait sur le cluster dont le MLflow a produit le modèle servi ; pour
> reprendre la main, l'un de vous publie un nouveau modèle depuis son cluster
> (`uv run python -m pipelines.gitops release`, étape 9). Rien à commiter.

### Checklist de validation

| # | Élément | Test | Résultat attendu | ☐ |
|---|---|---|---|---|
| 1 | Repo structuré | `ls .github/workflows k8s/overlays tests pipelines` | `ci.yml`, `staging`, `prod`, 4 fichiers de tests, `gitops.py` | ☐ |
| 2 | Workflow CI écrit | `cat .github/workflows/ci.yml` | 3 jobs : test, build, deploy-staging | ☐ |
| 3 | Tests locaux | `uv run pytest -q` | 29 passed | ☐ |
| 4 | PR fusionnées | `git log --oneline origin/main` | fusions des branches `lab/m6-…`, commits de `github-actions[bot]` et de `gitops` | ☐ |
| 5 | CI au vert | `gh run list` | dernier run : success | ☐ |
| 6 | Image poussée | GitHub > Packages | tags `2.1.N`, package public | ☐ |
| 7 | Argo CD installé | `kubectl get pods -n argocd` | 4 pods `Running` | ☐ |
| 8 | Applications | `kubectl get applications -n argocd` | `scoring-staging` et `scoring-prod` Synced / Healthy | ☐ |
| 9 | Déploiement par git push | `gitops status` | staging sert le nouveau tag | ☐ |
| 10 | Webhook CT | `curl localhost:8095/health` | `"status":"ok"` | ☐ |
| 11 | Pipeline CT complet | UI KFP, expérience `scoring-ct` | 7 étapes en succès, gate PROMUE | ☐ |
| 12 | Canary | `kubectl get isvc -n scoring` | `PREV 90` / `LATEST 10`, puis promotion | ☐ |
| 13 | Démo de bout en bout | journal du webhook, `git log` | cycle complet sans intervention | ☐ |
| 14 | Rapport | `reports/rapport-m6.md` | 5 sections, temps du cycle mesurés | ☐ |

```bash
make check-m6
```

## Critères d'évaluation (noté sur 20)

| Critère | Description | Points |
|---|---|---|
| CI GitHub Actions | Workflow au vert : lint, tests (API avec mini-modèle, manifests, CT), build, test de fumée, push GHCR, déploiement de staging par commit. | 6 |
| CD avec Argo CD | Deux Applications synchronisées automatiquement (selfHeal), prod reprise sans rupture, canary et promotion par commits. | 6 |
| CT fonctionnel | Webhook déclenché par un rapport Evidently, pipeline KFP avec gate (métrique + coût), nouveau modèle en prod sans intervention, rapport avec le temps du cycle. | 8 |
| **Total** | | **20** |

## Annexe — Troubleshooting

| Symptôme | Cause probable | Solution |
|---|---|---|
| Actions : `denied: permission_denied: write_package` au push GHCR | Permissions du `GITHUB_TOKEN` restreintes dans le repo ou l'organisation. | Settings > Actions > General > Workflow permissions : *Read and write permissions* ; vérifier `permissions: packages: write` du job. |
| Actions : `repository name must be lowercase` | Propriétaire avec des majuscules. | Le workflow met le nom en minuscules (`${VAR,,}`) : ne pas écrire le nom de l'image à la main. |
| Actions : `uv sync` échoue, `The lockfile needs to be updated` | `pyproject.toml` modifié sans `uv lock`. | `uv lock` en local, commiter `uv.lock`. |
| Actions : le job `deploy-staging` échoue au push | Commit concurrent, ou branche `main` protégée. | Relancer le job (il fait `git pull --rebase`) ; autoriser `github-actions[bot]` à contourner la règle, ou passer par une PR. |
| La CI ne se déclenche pas | Fichier hors des `paths`, ou Actions désactivées sur le fork. | Onglet Actions > activer ; `workflow_dispatch` pour un lancement manuel. |
| `git push` refusé : `fetch first` | La CI ou le bot ont poussé entre-temps. | `git pull --rebase --autostash` puis `git push`. |
| Argo CD : Application `Unknown`, `repository not found` | `repoURL` encore à `VOTRE_USER`, ou fork privé. | Corriger `k8s/argocd-app.yaml` et réappliquer ; fork public. |
| Argo CD : `OutOfSync` mais aucune différence visible | Réconciliation pas encore passée, ou ressource modifiée hors Git. | Attendre 60 s ; `kubectl annotate application <app> -n argocd argocd.argoproj.io/refresh=hard --overwrite`. |
| Argo CD : `Degraded`, ISVC `RevisionFailed` | Image introuvable ou privée (`ImagePullBackOff`). | `kubectl describe pod -n scoring-staging` ; package GHCR public ou `imagePullSecrets` (2.4). |
| Kustomize : image non remplacée | `name:` du bloc `images:` différent de l'image de la base (`scoring-api`). | `kubectl kustomize k8s/overlays/prod \| grep image`. |
| `kubectl patch isvc` sans effet durable | Argo CD (selfHeal) remet l'état de Git. | Faire le changement dans Git (`pipelines/gitops.py`). |
| `gitops` : `k8s/overlays/ a des modifications non commitées` | Édition manuelle d'un overlay en cours. | Commiter ou annuler (`git checkout k8s/overlays`) puis relancer. |
| `gitops … --push` : `Branche lab/… : les opérations GitOps poussées partent de main` | Commande lancée depuis la branche d'un lab. | `git switch main && git pull` puis relancer (les fichiers non commités suivent `git switch`). |
| Webhook : `503 CT_WEBHOOK_TOKEN n'est pas défini` / `401` | `.env` non chargé dans le terminal du webhook, ou jeton différent. | `set -a && source .env && set +a` dans les deux terminaux. |
| Webhook : `502 soumission à KFP … Connection refused` | Port-forward KFP arrêté. | `make kfp-ui`. |
| Webhook : `skipped`, `dernier ré-entraînement il y a … s` | Délai minimal entre deux ré-entraînements. | Attendre, ou `CT_COOLDOWN_SECONDS=0` au lancement du webhook (démo seulement). |
| KFP : `ingest-ct-data` en erreur `RESOURCE_DOES_NOT_EXIST` | `data_uri` d'un run MLflow supprimé. | Relancer `detect` (nouveau lot, nouveau run `scoring-drift`). |
| KFP : `ImagePullBackOff` sur les étapes | Image du pipeline (Lab 2/3) absente du registry. | `curl localhost:5001/v2/scoring-pipeline/tags/list` ; reconstruire (`make pipeline-image`, Lab 2, étape 2.4). |
| Gate : `REFUSÉE` | Le challenger fait moins bien que le champion sur les données récentes (c'est son rôle). | Lire le rapport Markdown de la gate ; le champion reste en place. |
| `release` : `Délai dépassé : CI GitHub Actions du commit …` | CI rouge ou très lente. | `gh run view --log-failed` ; corriger puis relancer `uv run python -m pipelines.gitops release`. |
| Staging ne répond pas (`servi : None`) | Scale-to-zero : premier démarrage, ou révision en échec. | Relancer `gitops status` ; `kubectl get isvc -n scoring-staging`. |

> [!NOTE]
> **Prochaine étape**
> Module 7 — Monitoring et observabilité ML. Vous allez instrumenter l'API avec Prometheus et
> Grafana, surveiller la dérive avec Evidently en continu, et analyser automatiquement le
> canary pour décider de la promotion ou du retour arrière. La dérive de ce lab sera alors
> mesurée sur le trafic, et non simulée.

## Pour aller plus loin

- **Tester la gate** : `simulate --shuffle-labels` mélange les étiquettes du lot récent ;
  relancez `detect` (avec `CT_COOLDOWN_SECONDS=0` pour le webhook) : la gate doit **refuser**
  le modèle (ROC AUC ≈ 0,44 < 0,70) et le champion reste en place. Remarquez que la règle de
  coût seule l'aurait laissé passer : le champion aussi se trompe sur des étiquettes fausses.
- **PR plutôt que commit** : faire ouvrir une pull request par le bot (`gh pr create`), avec
  le rapport de la gate en description ; la prod n'avance qu'au merge.
- **App of apps** : une Application Argo CD qui gère `k8s/argocd-app.yaml` lui-même.
- **Bot dans le cluster** : le webhook en Deployment, avec une GitHub App limitée au dépôt.
- **Promotion progressive** : 10 → 50 → 100 % avec une pause et une analyse à chaque palier
  (Lab 7).
- **Extensions du mini-projet** liées à ce lab : `retrain-planifie` (ré-entraînement planifié),
  `shadow`, `ab-test`, `drift-predictions` (catalogue : `labs/m10-capstone/README.md`).

## Vérification automatique

Depuis la racine du repo, cluster actif, port-forwards lancés (`make pf`, KFP sur 8080) et
webhook en marche :

```bash
make check-m6
```

Le script `labs/m6-cicd/check.sh` vérifie, sans rien modifier :

- les fichiers du lab, la validité de `.github/workflows/ci.yml` (schéma officiel avec
  `check-jsonschema` si `uvx` est disponible, et présence de lint, tests, build, GHCR,
  déploiement de staging), et le dernier run de la CI sur `main` si `gh` est authentifié
  (sinon SKIP) ;
- `ruff` et `pytest` en local, et la construction des deux overlays Kustomize ;
- Argo CD prêt ; les Applications `scoring-staging` et `scoring-prod` `Synced` et `Healthy`,
  en synchronisation automatique avec `prune` et `selfHeal`, pointant vers votre fork ;
- staging servi par une image `ghcr.io/…/scoring-api` ; en prod, un InferenceService suivi par
  Argo CD dont l'image et le canary sont ceux de `origin/main`, et une nouvelle révision qui
  sert le tag de Git ;
- le webhook CT joignable ; un run MLflow tagué `ct_trigger` et un rapport de dérive ; le run
  KFP correspondant réussi ; un `@champion` promu par la gate du CT et servi en prod ;
- l'historique Git (commits de la CI, du bot CT et de la prod), aucun nom de colonne en dur,
  le jeton du webhook dans `.env` mais pas dans Git, et le rapport complet.

Variables optionnelles : `NS_PROD`, `NS_STAGING`, `GATEWAY`, `KFP_HOST`, `CT_WEBHOOK_PORT`,
`GITOPS_REMOTE`. Code retour = nombre de vérifications en échec.
