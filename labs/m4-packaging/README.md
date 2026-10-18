---
module: 4
lab: 4
title: "Packager le modèle de scoring en image Docker"
subtitle: "Du modèle MLflow à l'image optimisée et scannée"
running_title: "Lab 4 — Packaging du modèle"
duree: "2 heures (atelier guidé)"
stack: "Docker · ONNX · FastAPI · Trivy · ModelScan · BentoML"
prerequis: "Lab 1 réussi : modèle scoring-model@champion dans le Registry MLflow"
livrable: "Image Docker < 500 Mo dans le registry local + benchmark + rapports de scan"
---

# Lab 4 — Packager le modèle de scoring en image Docker

*Transformer le modèle MLflow du Lab 1 en image Docker portable, optimisée, scannée et prête
pour la production.*

## Objectifs

> [!NOTE]
> **À la fin du lab, vous aurez :**
>
> - Un **modèle exporté en ONNX** depuis le Registry MLflow (`scoring-model@champion`), dont on
>   a vérifié qu'il prédit exactement comme le modèle scikit-learn.
> - Une **API FastAPI générique** : son schéma d'entrée est construit à partir de `dataset.yaml`,
>   aucune colonne n'est écrite dans le code.
> - Une **image Docker multi-stage** < 500 Mo, non-root, servant le modèle via FastAPI.
> - Un **benchmark** de latence (P50/P95/P99) : pipeline scikit-learn vs ONNX.
> - Une **variante BentoML** pour comparaison.
> - Un **rapport de scan** Trivy (OS/libs) + ModelScan (modèle).
> - L'image **poussée sur le registry local** `localhost:5001` et récupérable, par vous comme par
>   le cluster.

## Plan du lab

| # | Étape | Durée |
|---|---|---|
| 1 | Récupérer le modèle MLflow et exporter en ONNX | 15 min |
| 2 | Écrire le serveur FastAPI | 15 min |
| 3 | Dockerfile naïf (baseline) | 10 min |
| 4 | Dockerfile multi-stage optimisé | 20 min |
| 5 | Benchmark latence : scikit-learn vs ONNX | 20 min |
| 6 | Variante BentoML | 15 min |
| 7 | Scan sécurité : Trivy + ModelScan | 10 min |
| 8 | Push sur registry local + test pull | 10 min |
| 9 | Rédiger le rapport de benchmark | 5 min |

> [!WARNING]
> **Prérequis actifs**
> Docker Engine démarré, cluster du Lab 0 actif (`kubectl get nodes`) et port-forwards lancés
> (`make pf`) : le serveur MLflow du cluster répond sur `http://localhost:5000`. Le Lab 1 a
> enregistré le modèle `scoring-model` avec l'alias `champion` et produit
> `data/processed/test.csv`.

> [!NOTE]
> **Vous travaillez sur votre propre dataset ?**
> Rien ne change dans le code : les entrées ONNX, le schéma de l'API, la requête d'exemple, le
> seuil de décision et les vérifications sont tous dérivés de `dataset.yaml`. Les chiffres
> (taille du modèle, probabilités, latences) seront différents de ceux de l'énoncé. Trois points
> d'attention : (1) les colonnes **catégorielles** doivent contenir du texte dans
> `data/processed/test.csv` — si ce sont des codes numériques (`1`, `2`, `3`), convertissez-les en
> chaînes dans `src/download.py`, sinon `verify_onnx.py` détectera une divergence ; (2) le
> classifieur doit être convertible par skl2onnx (tous ceux de scikit-learn le sont ; XGBoost et
> LightGBM demanderaient `onnxmltools`, absent du socle) ; (3) dans les commandes `curl` qui
> écrivent une requête à la main (étape 2.2), remplacez `duration` par une de vos colonnes.

## Branche de travail

Comme chaque lab (convention du Lab 0, étape 8.1), celui-ci se fait sur sa propre branche,
créée depuis `main` à jour, et se termine par une pull request relue par le partenaire du
binôme :

```bash
cd ~/mlops-cours-2026
git switch main && git pull
git switch -c lab/m4-packaging
```

## Convention de notation

Les blocs de code contiennent des commandes shell à exécuter telles quelles depuis la racine de
votre fork (`~/mlops-cours-2026`) : elles n'ont **pas** de préfixe `$`, vous pouvez les
copier-coller directement. Les lignes commençant par `#` sont des commentaires. Un bloc dont la
première ligne est `# Fichier : chemin` est le contenu **complet** de ce fichier. Les encadrés
« Sortie attendue » montrent le résultat attendu.

## Étape 1/9 — Récupérer le modèle et exporter en ONNX (15 min)

### 1.1 Structure du projet

Tout le lab se passe dans votre fork ; le code vit dans le dossier `packaging/`. Rien à
installer : `skl2onnx` 1.20.0, `onnxruntime` 1.30.0, `fastapi` 0.142.2, `bentoml` 1.4.39,
`modelscan` 0.8.8 et `locust` 2.46.6 font partie du socle installé par `uv sync`.

```bash
cd ~/mlops-cours-2026
set -a && source .env && set +a
make pf
uv sync
mkdir -p packaging/app packaging/model packaging/bento packaging/scan-demo reports
```

Créez ensuite `packaging/app/__init__.py`, qui fait de `app/` un paquet Python :

```python
# Fichier : packaging/app/__init__.py
"""Paquet ``app`` : importé par uvicorn sous le nom ``app.serve`` (``--app-dir packaging``).

Ne PAS créer de ``packaging/__init__.py`` : le dossier masquerait le paquet PyPI
``packaging`` dont dépendent pip, MLflow, BentoML…
"""
```

Vérifiez que le modèle du Lab 1 est bien là :

```bash
uv run python -c "from mlflow import MlflowClient; \
mv = MlflowClient().get_model_version_by_alias('scoring-model', 'champion'); \
print(mv.name, mv.version, mv.run_id)"
```

> **Sortie attendue :** `scoring-model <N> 0ebb5feb4e4148f7aec9a9064654fc1a`. `<N>` est le numéro
> de version de votre champion actuel : au moins 7, puisque les Labs 2 et 3 enregistrent une
> version à chaque run de pipeline ; votre `run_id` est différent. Le modèle, lui, est toujours
> la régression logistique de `params.yaml` (seuil de décision 0,318). Partout dans ce lab et le
> suivant, `<N>` désigne ce numéro.

Arborescence à la fin du lab :

```text
packaging/
├── app/
│   ├── __init__.py        # fait de app/ un paquet : uvicorn le charge sous le nom app.serve
│   ├── export_onnx.py     # étape 1 : MLflow -> ONNX
│   ├── verify_onnx.py     # étape 1 : ONNX prédit-il comme scikit-learn ?
│   ├── serve.py           # étape 2 : l'API (seul script embarqué dans l'image)
│   └── benchmark.py       # étape 5
├── model/                 # produit par export_onnx.py : model.onnx + metadata.json
├── sample_request.py      # étape 2 : corps JSON d'exemple tiré de test.csv
├── Dockerfile.naive       # étape 3 (+ Dockerfile.naive.dockerignore)
├── Dockerfile             # étape 4 (+ Dockerfile.dockerignore, requirements.txt)
├── locustfile.py          # étape 5
├── bento/                 # étape 6 : save_model.py, service.py, bentofile.yaml
└── scan-demo/             # étape 7 : make_pickles.py
```

> [!WARNING]
> **Ne créez jamais `packaging/__init__.py`**
> Le dossier `packaging/` porte le même nom que le paquet PyPI `packaging`, utilisé par pip,
> MLflow, BentoML… S'il devenait un paquet Python, il le masquerait et plus rien ne
> s'importerait. C'est pourquoi les scripts se lancent **par leur chemin**
> (`uv run python packaging/app/export_onnx.py`) et non avec `python -m packaging...`, et
> pourquoi chacun ajoute la racine du repo au `sys.path` pour pouvoir faire
> `from src.dataset_config import load_config`.

### 1.2 Exporter le modèle en ONNX

Le script récupère `models:/scoring-model@champion` et le convertit avec `skl2onnx`. Points à
comprendre avant de le lancer :

- **Une seule variable d'environnement** : `MLFLOW_TRACKING_URI`. Le serveur MLflow du cluster
  fait proxy des artefacts stockés dans S3 (SeaweedFS) : contrairement à l'ancienne version de
  ce lab, qui passait les identifiants MinIO (remplacé par SeaweedFS depuis le Lab 0), le client
  n'a besoin d'aucun identifiant S3 ni de `MLFLOW_S3_ENDPOINT_URL`.
- **Les entrées ONNX sont dérivées de `dataset.yaml`** : un tenseur `[N, 1]` par colonne, nommé
  comme elle, `DoubleTensorType` pour les numériques et `StringTensorType` pour les
  catégorielles. Le modèle du Lab 1 est un `Pipeline` qui contient le prétraitement
  (imputation, standardisation, one-hot) : le graphe ONNX le contient aussi, et l'API recevra
  donc les **valeurs brutes** (`"purpose": "radio/tv"`). Aucun code de prétraitement n'est
  dupliqué entre entraînement et serving.
- **`onnx_ready()`** convertit une copie légèrement réécrite du pipeline (le modèle MLflow n'est
  pas modifié), pour deux limites de la conversion expliquées dans le code et dans l'encadré
  ci-dessous.
- **Le seuil de décision vient du run d'entraînement** : au Lab 1, `src/train.py` l'a calculé
  avec `cfg.cost_threshold()` (le seuil qui minimise le coût métier de `dataset.yaml`, corrigé
  des poids de classes ; voir l'explication du Lab 1) et l'a loggé en paramètre MLflow
  `decision_threshold` : 0,318 pour le modèle par défaut (`class_weight="balanced"`).
  `export_onnx.py` le recopie dans `metadata.json`, pour que l'API décide exactement comme
  l'évaluation du Lab 1. Pour un run plus ancien, sans ce paramètre, il refait le même calcul.
- **`metadata.json`** accompagne le modèle : version du Registry, `run_id`, seuil, colonnes,
  empreinte SHA-256. L'API l'expose sur `/metadata` et l'image le reprend en `LABEL`.

```python
# Fichier : packaging/app/export_onnx.py
"""Étape 1 — récupère scoring-model@champion dans MLflow et l'exporte en ONNX.

Usage (depuis la racine du repo, après `set -a && source .env && set +a`) :
    uv run python packaging/app/export_onnx.py
Produit packaging/model/model.onnx et packaging/model/metadata.json.
"""

import copy
import hashlib
import json
import os
import sys
from datetime import UTC, datetime
from pathlib import Path

import mlflow
import numpy as np
from mlflow import MlflowClient
from skl2onnx import to_onnx
from skl2onnx.common.data_types import DoubleTensorType, StringTensorType
from skl2onnx.sklapi import CastTransformer
from sklearn.compose import ColumnTransformer

ROOT = Path(__file__).resolve().parents[2]  # racine du repo
sys.path.append(str(ROOT))  # rend « src » importable quel que soit le dossier courant
from src.dataset_config import load_config  # noqa: E402

MODEL_NAME = os.getenv("MODEL_NAME", "scoring-model")
MODEL_ALIAS = os.getenv("MODEL_ALIAS", "champion")
MODEL_DIR = ROOT / "packaging" / "model"
TARGET_OPSET = 17

cfg = load_config(ROOT / "dataset.yaml")

# Seule variable nécessaire : le serveur MLflow fait proxy des artefacts S3
# (aucun identifiant S3 côté client).
mlflow.set_tracking_uri(os.getenv("MLFLOW_TRACKING_URI", "http://localhost:5000"))
client = MlflowClient()
mv = client.get_model_version_by_alias(MODEL_NAME, MODEL_ALIAS)
model = mlflow.sklearn.load_model(f"models:/{MODEL_NAME}/{mv.version}")  # MLflow 3 : skops
print(
    f"Loaded models:/{MODEL_NAME}@{MODEL_ALIAS} -> version {mv.version} "
    f"({type(model).__name__}: {' -> '.join(type(s).__name__ for _, s in model.steps)})"
)

# 1. Types d'entrée dérivés de dataset.yaml : un tenseur [N, 1] par colonne, nommé comme
#    la colonne (le ColumnTransformer sélectionne les colonnes par leur nom).
#    float64 pour les numériques : voir onnx_ready(), point (b).
initial_types = [(c, DoubleTensorType([None, 1])) for c in cfg.numeric] + [
    (c, StringTensorType([None, 1])) for c in cfg.categorical
]


# 2. Copie du pipeline réécrite pour une conversion fidèle (le modèle MLflow n'est pas modifié).
def onnx_ready(pipeline):
    pipeline = copy.deepcopy(pipeline)
    pre = next(step for _, step in pipeline.steps if isinstance(step, ColumnTransformer))
    if cfg.categorical:
        # (a) skl2onnx ne convertit pas un imputer de chaînes dont la valeur manquante est
        #     NaN : dans le graphe ONNX, « manquant » sera la chaîne vide "".
        pre.named_transformers_["cat"].named_steps["impute"].missing_values = ""
    if cfg.numeric:
        # (b) Les arbres de scikit-learn comparent des float32 à des seuils situés SUR des
        #     valeurs observées : standardiser en float32 (au lieu de float64 puis float32)
        #     décale d'un arrondi et change de branche. On standardise donc en float64,
        #     on convertit en float32, puis on impute avec la médiane standardisée.
        num = pre.named_transformers_["num"]
        imputer, scaler = num.named_steps["impute"], num.named_steps["scale"]
        imputer.statistics_ = (imputer.statistics_ - scaler.mean_) / scaler.scale_
        to_float32 = CastTransformer(dtype=np.float32).fit(np.zeros((1, len(cfg.numeric))))
        num.steps = [("scale", scaler), ("float32", to_float32), ("impute", imputer)]
    return pipeline


onnx_model = to_onnx(
    onnx_ready(model),
    initial_types=initial_types,
    target_opset=TARGET_OPSET,
    options={"zipmap": False},  # probabilités en tenseur [N, 2] plutôt qu'en liste de dicts
)


# 3. Seuil de décision : celui calculé et loggé par l'entraînement (Lab 1, param MLflow
#    `decision_threshold`). Repli pour un run plus ancien : le même calcul, cfg.cost_threshold(k).
def decision_threshold() -> tuple[float, str]:
    logged = client.get_run(mv.run_id).data.params.get("decision_threshold")
    if logged is not None:
        return float(logged), "param decision_threshold du run"
    k = 1.0
    if getattr(model.steps[-1][1], "class_weight", None) == "balanced":
        _, y = cfg.read_xy(ROOT / "data/processed/train.csv")
        k = (y == 0).sum() / (y == 1).sum()  # poids des positifs / poids des négatifs
    return cfg.cost_threshold(float(k)), "cfg.cost_threshold (repli)"


threshold, threshold_source = decision_threshold()

MODEL_DIR.mkdir(parents=True, exist_ok=True)
onnx_path = MODEL_DIR / "model.onnx"
onnx_bytes = onnx_model.SerializeToString()
onnx_path.write_bytes(onnx_bytes)

# 4. Métadonnées lues par l'API (/metadata) et reprises en LABEL de l'image.
metadata = {
    "dataset": cfg.name,
    "model_name": MODEL_NAME,
    "model_alias": MODEL_ALIAS,
    "model_version": str(mv.version),
    "run_id": mv.run_id,
    "target": cfg.target,
    "positive_class": str(cfg.positive_class),
    "threshold": round(threshold, 6),
    "threshold_source": threshold_source,
    "features": {"numeric": cfg.numeric, "categorical": cfg.categorical},
    "onnx_opset": TARGET_OPSET,
    "onnx_sha256": hashlib.sha256(onnx_bytes).hexdigest(),
    "exported_at": datetime.now(UTC).isoformat(timespec="seconds"),
}
(MODEL_DIR / "metadata.json").write_text(json.dumps(metadata, indent=2, ensure_ascii=False))

size_kb = onnx_path.stat().st_size / 1024
print(f"ONNX exported: {size_kb:.1f} kB -> {onnx_path.relative_to(ROOT)}")
print(
    f"Inputs: {len(cfg.numeric)} numeric + {len(cfg.categorical)} categorical "
    f"· threshold={threshold:.3f} ({threshold_source})"
)
```

```bash
uv run python packaging/app/export_onnx.py
```

> **Sortie attendue :** après la barre de progression `Downloading artifacts`, trois lignes :
> `Loaded models:/scoring-model@champion -> version <N> (Pipeline: ColumnTransformer ->
> LogisticRegression)`, `ONNX exported: 11.1 kB -> packaging/model/model.onnx` et
> `Inputs: 7 numeric + 13 categorical · threshold=0.318 (param decision_threshold du run)`.
> Taille typique : ≈ 11 kB pour une régression logistique, quelques Mo pour une forêt aléatoire.

> [!WARNING]
> **float32 ou float64 : le piège des arbres**
> L'ancienne version de ce lab convertissait tout en `FloatTensorType` (float32). Testé avec une
> `RandomForestClassifier`, cela donne des probabilités qui s'écartent de scikit-learn jusqu'à
> 0,02 sur un tiers des lignes de test. Cause : les arbres de scikit-learn comparent des float32
> à des seuils situés exactement **sur** des valeurs observées ; scikit-learn standardise en
> float64 puis arrondit en float32, alors qu'un graphe tout en float32 standardise en float32 :
> l'arrondi diffère d'un cheveu, et l'échantillon part dans l'autre branche. D'où les entrées
> numériques en float64 et le point (b) de `onnx_ready()` : standardisation en float64, conversion
> en float32, puis imputation (la médiane est standardisée elle aussi, ce qui revient au même).
> Écart obtenu : < 10⁻⁶ pour les trois modèles du Lab 1 (régression logistique, forêt aléatoire,
> gradient boosting) comme pour un `HistGradientBoostingClassifier`.

### 1.3 Vérifier que ONNX = sklearn

Le script charge **la version exacte** exportée (lue dans `metadata.json`, l'alias a pu bouger
depuis) et compare les probabilités de la classe positive sur tout `data/processed/test.csv`,
avec une tolérance de 10⁻⁴, puis les décisions au seuil.

```python
# Fichier : packaging/app/verify_onnx.py
"""Étape 1.3 — vérifie que le modèle ONNX prédit comme le modèle scikit-learn.

Usage (racine du repo) : uv run python packaging/app/verify_onnx.py
"""

import json
import os
import sys
from pathlib import Path

import mlflow
import numpy as np
import onnxruntime as ort

ROOT = Path(__file__).resolve().parents[2]
sys.path.append(str(ROOT))
from src.dataset_config import load_config  # noqa: E402

TOL = 1e-4  # écart absolu toléré sur les probabilités (float32 vs float64)

cfg = load_config(ROOT / "dataset.yaml")
meta = json.loads((ROOT / "packaging/model/metadata.json").read_text())
X, _ = cfg.read_xy(ROOT / "data/processed/test.csv")  # numériques en float64

mlflow.set_tracking_uri(os.getenv("MLFLOW_TRACKING_URI", "http://localhost:5000"))
# La version exacte qui a été exportée (et non l'alias, qui a pu bouger depuis)
skm = mlflow.sklearn.load_model(f"models:/{meta['model_name']}/{meta['model_version']}")
sess = ort.InferenceSession(str(ROOT / "packaging/model/model.onnx"))

feed = {c: X[[c]].astype(np.float64).to_numpy() for c in cfg.numeric}
feed |= {c: X[[c]].fillna("").astype(str).to_numpy(dtype=object) for c in cfg.categorical}

p1 = skm.predict_proba(X)[:, 1]
p2 = sess.run(["probabilities"], feed)[0][:, 1]
t = meta["threshold"]
max_diff = float(np.abs(p1 - p2).max())
same = float(((p1 >= t) == (p2 >= t)).mean())
print(
    f"{len(X)} rows · max |p_sklearn - p_onnx| = {max_diff:.2e} · "
    f"same decision (threshold {t:.3f}) : {same:.1%}"
)
assert max_diff < TOL, "Divergence detected!"
print("OK: predictions match.")
```

```bash
uv run python packaging/app/verify_onnx.py
```

> **Sortie attendue :** `200 rows · max |p_sklearn - p_onnx| = 8.73e-08 · same decision
> (threshold 0.318) : 100.0%` puis `OK: predictions match.` Pas d'`AssertionError`.

> [!NOTE]
> **Choix d'architecture : le modèle est figé dans l'image au build**
> On aurait pu laisser l'API télécharger `models:/scoring-model@champion` au démarrage. On
> préfère exporter le modèle **avant** le `docker build` et le copier dans l'image : (1) une image
> = une version du modèle, immuable — le tag `1.0.0` désigne toujours le même modèle et le
> rollback du Lab 5 consiste à redéployer l'image précédente ; (2) le conteneur démarre sans
> réseau ni MLflow, donc vite et même si MLflow est en panne (crucial quand l'autoscaling crée
> des pods à la volée) ; (3) aucun accès au Registry à donner aux pods ; (4) ce que Trivy et
> ModelScan analysent est exactement ce qui tourne ; (5) l'image n'embarque ni MLflow ni
> scikit-learn (plusieurs centaines de Mo). Contrepartie : il faut reconstruire l'image à chaque
> nouveau modèle — c'est précisément ce qu'automatisera la CI/CD du Module 6.

## Étape 2/9 — Écrire le serveur FastAPI (15 min)

### 2.1 Serveur d'inférence

L'API charge le graphe ONNX avec ONNX Runtime ; elle n'a besoin ni de scikit-learn ni de MLflow.
Ce qui change par rapport à une API écrite pour un dataset précis :

- **Schéma généré** : `create_model()` de Pydantic construit le modèle `Instance` à partir des
  listes `numeric` et `categorical` de `dataset.yaml`. FastAPI en tire la validation et la
  documentation OpenAPI (`/docs`).
- **Validation stricte** : une colonne absente, une colonne inconnue (`extra="forbid"`), du texte
  dans une colonne numérique ou un nombre dans une colonne catégorielle donnent une erreur
  **422** détaillée. `null` est accepté : c'est une valeur manquante, que le graphe ONNX impute
  comme l'aurait fait le pipeline (médiane ou modalité la plus fréquente).
- **Une ou plusieurs demandes** : le corps est `{"instances": [ ... ]}` (jusqu'à `MAX_BATCH`
  demandes, 1 000 par défaut), comme le protocole v1 de KServe que vous verrez au Lab 5.
- **Réponse** : pour chaque demande, la probabilité de la classe positive (`bad` ici) et la
  décision au seuil (`prediction` = 1 si `probability >= threshold`), plus la version du modèle.
- **numpy plutôt que pandas** dans `score()` : construire un DataFrame par requête coûtait
  ≈ 5 ms, contre 0,07 ms pour l'inférence ONNX elle-même.

```python
# Fichier : packaging/app/serve.py
"""API de scoring : sert le modèle ONNX exporté à l'étape 1.

Le schéma d'entrée est construit à partir de dataset.yaml : aucune colonne n'est écrite
ici, changer de dataset ne demande aucune modification de ce fichier.

Lancement local (depuis la racine du repo) :
    uv run python -m uvicorn app.serve:app --app-dir packaging --port 8000
"""

import json
import os
import sys
from pathlib import Path
from typing import Annotated, Any

import numpy as np
import onnxruntime as ort
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, ConfigDict, Field, create_model

ROOT = Path(__file__).resolve().parents[2]  # racine du repo (/app dans l'image)
sys.path.append(str(ROOT))  # rend « src » importable quel que soit le lanceur
from src.dataset_config import load_config  # noqa: E402

API_VERSION = "1.0.0"
MAX_BATCH = int(os.getenv("MAX_BATCH", "1000"))
MODEL_PATH = Path(os.getenv("MODEL_PATH", ROOT / "packaging" / "model" / "model.onnx"))

cfg = load_config(os.getenv("DATASET_CONFIG", ROOT / "dataset.yaml"))
session = ort.InferenceSession(str(MODEL_PATH), providers=["CPUExecutionProvider"])
meta_path = MODEL_PATH.with_name("metadata.json")
metadata: dict[str, Any] = json.loads(meta_path.read_text()) if meta_path.exists() else {}
# Seuil : variable d'environnement > metadata.json (seuil du run d'entraînement) > coût métier
THRESHOLD = float(os.getenv("DECISION_THRESHOLD", metadata.get("threshold", cfg.cost_threshold())))
MODEL_VERSION = str(metadata.get("model_version", "unknown"))
MODEL_KEYS = ("model_name", "model_alias", "model_version", "run_id", "onnx_sha256", "exported_at")

# --- Schéma d'entrée généré depuis dataset.yaml ---------------------------------------
# strict : "12" (chaîne) est refusé pour une colonne numérique, 3 pour une catégorielle.
# null est accepté : valeur manquante, imputée par le pipeline (médiane / mode).
Numeric = Annotated[float | None, Field(strict=True, allow_inf_nan=False)]
Categorical = Annotated[str | None, Field(strict=True, min_length=1)]
Instance = create_model(
    "Instance",
    __config__=ConfigDict(extra="forbid"),  # colonne inconnue = erreur 422
    **{c: (Numeric, ...) for c in cfg.numeric},  # ... = colonne obligatoire
    **{c: (Categorical, ...) for c in cfg.categorical},
)


class PredictRequest(BaseModel):
    instances: list[Instance] = Field(..., min_length=1, max_length=MAX_BATCH)


class Prediction(BaseModel):
    probability: float  # probabilité de la classe positive (target.positive_class)
    prediction: int  # 1 si probability >= threshold, sinon 0


class PredictResponse(BaseModel):
    model_version: str
    positive_class: str
    threshold: float
    predictions: list[Prediction]


app = FastAPI(title=f"Scoring API — {cfg.name}", version=API_VERSION)


def score(rows: list[dict[str, Any]]) -> np.ndarray:
    """Probabilité de la classe positive pour chaque demande (une entrée ONNX par colonne).

    numpy plutôt que pandas : construire un DataFrame coûte ~50x plus cher que l'inférence.
    """
    # null -> NaN (numérique) ou "" (catégoriel) : imputés dans le graphe ONNX
    feed = {c: np.array([[r[c]] for r in rows], dtype=np.float64) for c in cfg.numeric}
    feed |= {c: np.array([[r[c] or ""] for r in rows], dtype=object) for c in cfg.categorical}
    (proba,) = session.run(["probabilities"], feed)
    return proba[:, 1]


@app.get("/health")
def health():
    return {"status": "ok", "model_loaded": True}


@app.get("/metadata")
def get_metadata():
    return {
        "api_version": API_VERSION,
        "dataset": cfg.name,
        "target": cfg.target,
        "positive_class": str(cfg.positive_class),
        "threshold": THRESHOLD,
        "features": {"numeric": cfg.numeric, "categorical": cfg.categorical},
        "model": {k: metadata.get(k) for k in MODEL_KEYS},
    }


@app.post("/predict", response_model=PredictResponse)
def predict(req: PredictRequest):
    try:
        proba = score([i.model_dump() for i in req.instances])
    except Exception as e:
        raise HTTPException(500, str(e)) from e
    return PredictResponse(
        model_version=MODEL_VERSION,
        positive_class=str(cfg.positive_class),
        threshold=THRESHOLD,
        predictions=[
            Prediction(probability=float(p), prediction=int(p >= THRESHOLD)) for p in proba
        ],
    )
```

### 2.2 Test local

Pour ne pas écrire 20 colonnes à la main, ce petit script fabrique le corps JSON à partir de
vraies lignes de `data/processed/test.csv` (colonnes lues dans `dataset.yaml`) :

```python
# Fichier : packaging/sample_request.py
"""Construit un corps JSON pour POST /predict à partir de vraies lignes de test.

Usage (racine du repo) :
    uv run python packaging/sample_request.py > /tmp/request.json        # 1 demande
    uv run python packaging/sample_request.py -n 3 > /tmp/batch.json     # 3 demandes
"""

import argparse
import json
import sys
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
sys.path.append(str(ROOT))
from src.dataset_config import load_config  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("-n", type=int, default=1, help="nombre de demandes")
parser.add_argument("--csv", default=str(ROOT / "data/processed/test.csv"))
args = parser.parse_args()

cfg = load_config(ROOT / "dataset.yaml")
rows = pd.read_csv(args.csv)[cfg.features].head(args.n)
rows = rows.astype(object).where(rows.notna(), None)  # NaN -> null (JSON n'a pas de NaN)
print(json.dumps({"instances": rows.to_dict("records")}, ensure_ascii=False))
```

```bash
uv run python packaging/sample_request.py > /tmp/request.json
cat /tmp/request.json
uv run python -m uvicorn app.serve:app --app-dir packaging --port 8000 &
sleep 3
curl -s http://localhost:8000/health
curl -s -X POST http://localhost:8000/predict -H "Content-Type: application/json" \
    -d @/tmp/request.json
```

> **Sortie attendue :** `{"status":"ok","model_loaded":true}` puis
> `{"model_version":"<N>","positive_class":"bad","threshold":0.3182,"predictions":[{"probability":0.5091253519058228,"prediction":1}]}`
> (valeurs indicatives : avec un score de risque de 0,51, au-dessus du seuil de 0,318, la
> demande est classée à risque).

`--app-dir packaging` ajoute `packaging/` au chemin d'import (le module s'appelle donc
`app.serve`) ; `python -m uvicorn` garde la racine du repo dans ce chemin. Essayez maintenant
des requêtes invalides, puis plusieurs demandes d'un coup :

```bash
# Mauvais type + colonnes manquantes -> 422 avec le détail de chaque erreur
curl -s -X POST http://localhost:8000/predict -H "Content-Type: application/json" \
    -d '{"instances": [{"duration": "douze"}]}' | python3 -m json.tool | head -12
# Trois demandes en une requête
uv run python packaging/sample_request.py -n 3 | curl -s -X POST \
    http://localhost:8000/predict -H "Content-Type: application/json" -d @-
```

> **Sortie attendue :** pour la première requête, un objet `detail` listant
> `"type": "float_type"` sur `["body", "instances", 0, "duration"]` (« Input should be a valid
> number ») puis une erreur `"type": "missing"` par colonne absente ; pour la seconde, trois
> éléments dans `predictions`.

Ouvrez `http://localhost:8000/docs` : le schéma `Instance` liste les 20 colonnes de
`dataset.yaml`, avec leur type. Arrêtez ensuite le serveur :

```bash
kill %1
```

### 2.3 Le contrat de l'API

Les Labs 5 (KServe, Locust), 6 (CI/CD) et 7 (monitoring) s'appuient sur ce contrat : gardez-le
stable.

| Élément | Valeur |
|---|---|
| Port du conteneur | `8000` |
| `GET /health` | `{"status": "ok", "model_loaded": true}` (sonde de vie et de disponibilité) |
| `GET /metadata` | dataset, cible, classe positive, seuil, colonnes, version et `run_id` du modèle |
| `POST /predict` | corps `{"instances": [{<colonne>: <valeur>, …}, …]}` (1 à `MAX_BATCH` demandes) |
| Réponse 200 | `{"model_version", "positive_class", "threshold", "predictions": [{"probability", "prediction"}]}` |
| Réponse 422 | requête invalide : colonne manquante ou inconnue, mauvais type, liste vide ou trop longue |
| `MODEL_PATH` | chemin du `model.onnx` (défaut `packaging/model/model.onnx`, `metadata.json` à côté) |
| `DATASET_CONFIG` | chemin de `dataset.yaml` (défaut : racine du repo, `/app` dans l'image) |
| `DECISION_THRESHOLD` | surcharge du seuil (défaut : `metadata.json`, donc le seuil du run d'entraînement) |
| `MAX_BATCH` | nombre maximal de demandes par requête (défaut 1000) |

## Étape 3/9 — Dockerfile naïf (baseline) (10 min)

Le contexte de build est la **racine du repo** (le `.` final) : l'image a besoin de
`dataset.yaml` et de `src/dataset_config.py`, qui ne sont pas dans `packaging/`. Le Dockerfile
est désigné avec `-f`. BuildKit (le builder par défaut de Docker) lit alors le fichier
`<Dockerfile>.dockerignore` placé à côté du Dockerfile, de préférence au `.dockerignore` de la
racine : chaque image a ainsi sa propre liste d'exclusions.

```dockerfile
# Fichier : packaging/Dockerfile.naive
# Baseline volontairement naïve. Contexte de build = racine du repo :
#   docker build -f packaging/Dockerfile.naive -t scoring-api:naive .
FROM python:3.12

WORKDIR /app
COPY . /app
RUN pip install fastapi "uvicorn[standard]" onnxruntime numpy pandas pyyaml

EXPOSE 8000
CMD ["python", "-m", "uvicorn", "app.serve:app", "--app-dir", "packaging", \
     "--host", "0.0.0.0", "--port", "8000"]
```

```text
# Fichier : packaging/Dockerfile.naive.dockerignore
# Même la baseline naïve exclut l'environnement virtuel : avec lui, le contexte de build
# (et l'image) prendrait plusieurs Go. Tout le reste du repo est copié (.git, data/, …).
.venv/
```

```bash
docker build -f packaging/Dockerfile.naive -t scoring-api:naive .
docker images scoring-api:naive --format "{{.Size}}"
```

> **Sortie attendue :** taille 1,3 à 1,6 Go. Notez la valeur pour le rapport.

Deux autres défauts, plus graves que la taille :

```bash
docker run --rm scoring-api:naive id
docker run --rm scoring-api:naive cat .env
```

> [!CAUTION]
> **L'image naïve embarque vos secrets**
> `COPY . /app` copie tout le repo : `.git`, `data/`… et votre `.env` avec les identifiants S3.
> Quiconque peut tirer l'image peut lire ces secrets, même si vous supprimez le fichier dans une
> couche ultérieure. Et le serveur tourne en `uid=0(root)`. Ne poussez jamais cette image.

## Étape 4/9 — Dockerfile multi-stage optimisé (20 min)

### 4.1 Créer le .dockerignore

Plutôt qu'une liste d'exclusions qu'on oublie de tenir à jour, une **liste blanche** : on
exclut tout, puis on ré-autorise les seuls fichiers que l'image copie.

```text
# Fichier : packaging/Dockerfile.dockerignore
# .dockerignore propre à packaging/Dockerfile (BuildKit le lit à la place de celui de la
# racine). Liste blanche : on exclut TOUT, puis on ré-inclut ce que l'image copie.
# Le contexte envoyé au démon passe de plusieurs centaines de Mo (.venv, .git, data/,
# mlruns/…) à quelques centaines de ko, et aucun secret (.env) ne peut fuiter.
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

### 4.2 Dockerfile multi-stage

Les dépendances de l'image sont figées dans leur propre fichier, aux versions de `uv.lock` :

```text
# Fichier : packaging/requirements.txt
# Dépendances de l'image de serving UNIQUEMENT (pas de MLflow, scikit-learn ni skl2onnx :
# l'image ne fait qu'exécuter le graphe ONNX). Versions alignées sur uv.lock.
fastapi==0.142.2
pydantic==2.13.5
uvicorn[standard]==0.54.0
onnxruntime==1.30.0
numpy==2.5.3
pandas==2.3.3
pyyaml==6.0.3
```

```dockerfile
# Fichier : packaging/Dockerfile
# Image de serving optimisée. Contexte de build = RACINE du repo :
#   docker build -f packaging/Dockerfile -t scoring-api:optimized .
# Le modèle est exporté AVANT le build (étape 1, packaging/model/) puis copié :
# l'image est autonome, ni le build ni le conteneur n'ont besoin d'accéder à MLflow.

# --- Stage 1 : builder — installe les dépendances dans /deps ---------------------------
FROM python:3.12-slim AS builder
WORKDIR /build
COPY packaging/requirements.txt .
RUN pip install --no-cache-dir --target=/deps -r requirements.txt

# --- Stage 2 : runtime — uniquement ce qui sert à répondre aux requêtes ---------------
FROM python:3.12-slim AS runtime
# UID fixe : Kubernetes (runAsNonRoot) exige un USER numérique pour vérifier le non-root.
RUN groupadd --gid 10001 ml \
    && useradd --uid 10001 --gid ml --no-create-home --shell /usr/sbin/nologin ml

WORKDIR /app
COPY --from=builder /deps /deps
ENV PYTHONPATH=/deps \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Même arborescence que le repo : serve.py trouve dataset.yaml, src/ et le modèle sans
# configuration. Les fichiers restent à root : l'utilisateur ml ne peut que les lire.
COPY dataset.yaml ./
COPY src/__init__.py src/dataset_config.py src/
COPY packaging/app/__init__.py packaging/app/serve.py packaging/app/
# Le modèle change plus souvent que le code : dernière couche, pour profiter du cache.
COPY packaging/model/model.onnx packaging/model/metadata.json packaging/model/

USER 10001:10001
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --start-interval=2s \
    CMD ["python", "-c", \
         "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"]

# Métadonnées (docker inspect) : passées au build, voir l'étape 4.2.
ARG VERSION=1.0.0
ARG MODEL_VERSION=unknown
LABEL org.opencontainers.image.title="scoring-api" \
      org.opencontainers.image.version="${VERSION}" \
      mlflow.model_name="scoring-model" \
      mlflow.model_alias="champion" \
      mlflow.model_version="${MODEL_VERSION}"

CMD ["python", "-m", "uvicorn", "app.serve:app", "--app-dir", "packaging", \
     "--host", "0.0.0.0", "--port", "8000"]
```

Les choix, dans l'ordre du fichier : `python:3.12-slim` comme base (pas de compilateurs ni
d'outils Debian inutiles) ; un stage `builder` qui installe les dépendances dans `/deps`, seul
dossier copié dans le stage final ; un utilisateur `ml` à UID fixe ; la **même arborescence que
le repo** sous `/app`, si bien que `serve.py` fonctionne sans configuration ; le modèle copié en
dernier (un nouveau modèle ne reconstruit que la dernière couche) ; un `HEALTHCHECK` ; des
`LABEL` qui relient l'image au Registry MLflow.

```bash
MODEL_VERSION=$(uv run python -c \
    "import json; print(json.load(open('packaging/model/metadata.json'))['model_version'])")
docker build -f packaging/Dockerfile -t scoring-api:optimized \
    --build-arg VERSION=1.0.0 --build-arg MODEL_VERSION="$MODEL_VERSION" .
docker images scoring-api:optimized --format "{{.Size}}"
docker run -d --rm -p 8000:8000 --name scoring scoring-api:optimized
sleep 5 && curl -s http://localhost:8000/health
curl -s -X POST http://localhost:8000/predict -H "Content-Type: application/json" \
    -d @/tmp/request.json
docker run --rm scoring-api:optimized id
docker inspect --format '{{.State.Health.Status}}' scoring
docker inspect --format '{{json .Config.Labels}}' scoring-api:optimized
docker stop scoring
```

> **Sortie attendue :** taille < 500 Mo (≈ 330 Mo : ≈ 125 Mo pour `python:3.12-slim` et ≈ 206 Mo
> de dépendances, dont ONNX Runtime 62 Mo, pandas 45 Mo et numpy 57 Mo). Gain de ≈ 4× sur la
> baseline. `/health` répond `{"status":"ok","model_loaded":true}`, `/predict` renvoie la même
> probabilité qu'à l'étape 2, `id` affiche `uid=10001(ml) gid=10001(ml) groups=10001(ml)`,
> l'état de santé est `healthy` et les labels contiennent `"mlflow.model_version":"<N>"`.

> [!TIP]
> **Linter le Dockerfile**
> `docker run --rm -i hadolint/hadolint < packaging/Dockerfile` ne signale rien ; sur
> `packaging/Dockerfile.naive`, hadolint relève les versions non épinglées (DL3013) et le cache
> pip conservé dans l'image (DL3042).

## Étape 5/9 — Benchmark latence (20 min)

### 5.1 Script de benchmark

On compare trois backends sur de vraies lignes de test : le pipeline scikit-learn tel que chargé
depuis MLflow (MLflow 3 le stocke au format skops, plus en pickle), ONNX Runtime sur une ligne,
et ONNX Runtime sur un lot de 100 lignes. Le tableau est aussi écrit dans `reports/benchmark.md`.

```python
# Fichier : packaging/app/benchmark.py
"""Étape 5 — latence d'inférence : pipeline scikit-learn vs ONNX Runtime.

Usage (racine du repo) : uv run python packaging/app/benchmark.py
Écrit aussi le tableau dans reports/benchmark.md.
"""

import json
import os
import platform
import sys
import time
from pathlib import Path

import mlflow
import numpy as np
import onnxruntime as ort
import pandas as pd

ROOT = Path(__file__).resolve().parents[2]
sys.path.append(str(ROOT))
from src.dataset_config import load_config  # noqa: E402

N = 1000

cfg = load_config(ROOT / "dataset.yaml")
meta = json.loads((ROOT / "packaging/model/metadata.json").read_text())
X, _ = cfg.read_xy(ROOT / "data/processed/test.csv")  # numériques en float64


def onnx_feed(df: pd.DataFrame) -> dict:
    feed = {c: df[[c]].astype(np.float64).to_numpy() for c in cfg.numeric}
    feed |= {c: df[[c]].fillna("").astype(str).to_numpy(dtype=object) for c in cfg.categorical}
    return feed


def bench(name, fn):
    for _ in range(10):
        fn()  # warmup
    times = []
    for _ in range(N):
        t0 = time.perf_counter()
        fn()
        times.append((time.perf_counter() - t0) * 1000)
    a = np.array(times)
    return {
        "name": name,
        "p50": np.percentile(a, 50),
        "p95": np.percentile(a, 95),
        "p99": np.percentile(a, 99),
    }


mlflow.set_tracking_uri(os.getenv("MLFLOW_TRACKING_URI", "http://localhost:5000"))
sk = mlflow.sklearn.load_model(f"models:/{meta['model_name']}/{meta['model_version']}")
ox = ort.InferenceSession(
    str(ROOT / "packaging/model/model.onnx"), providers=["CPUExecutionProvider"]
)

x1, x100 = X.head(1), X.head(100)
f1, f100 = onnx_feed(x1), onnx_feed(x100)
results = [
    bench("sklearn_pipeline", lambda: sk.predict_proba(x1)),
    bench("onnx_python", lambda: ox.run(None, f1)),
    bench(f"onnx_batch_{len(x100)}", lambda: ox.run(None, f100)),
]

lines = [f"{'Backend':<20} {'P50':>8} {'P95':>8} {'P99':>8} (ms)"]
lines += [f"{r['name']:<20} {r['p50']:>8.3f} {r['p95']:>8.3f} {r['p99']:>8.3f}" for r in results]
print("\n".join(lines))
speedup = results[0]["p50"] / results[1]["p50"]
print(f"ONNX vs sklearn (P50, 1 row): x{speedup:.1f}")

report = ROOT / "reports" / "benchmark.md"
report.parent.mkdir(exist_ok=True)
rows = "\n".join(
    f"| {r['name']} | {r['p50']:.3f} | {r['p95']:.3f} | {r['p99']:.3f} |" for r in results
)
report.write_text(
    f"# Benchmark de latence — {cfg.name}, modèle v{meta['model_version']}\n\n"
    f"{N} appels par backend, après 10 appels de chauffe · "
    f"{platform.processor() or platform.machine()} · Python {platform.python_version()}\n\n"
    "| Backend | P50 (ms) | P95 (ms) | P99 (ms) |\n|---|---|---|---|\n"
    f"{rows}\n\nAccélération ONNX vs scikit-learn (P50, 1 ligne) : x{speedup:.1f}\n"
)
print(f"Report written: {report.relative_to(ROOT)}")
```

```bash
uv run python packaging/app/benchmark.py
```

> **Sortie attendue :** un tableau de 3 lignes, par exemple :

```text
Backend                   P50      P95      P99 (ms)
sklearn_pipeline        4.143    6.015    6.734
onnx_python             0.069    0.092    0.098
onnx_batch_100          0.320    0.462    0.558
ONNX vs sklearn (P50, 1 row): x60.5
Report written: reports/benchmark.md
```

ONNX est typiquement **50 à 60× plus rapide** que scikit-learn en prédiction unitaire : pour une
seule ligne, le temps du pipeline scikit-learn est dominé par son surcoût fixe (validation du
DataFrame, sélection des colonnes par leur nom, un appel Python par transformateur).

### 5.2 Test de charge avec Locust (optionnel)

Le scénario rejoue des lignes tirées au hasard dans `data/processed/test.csv` :

```python
# Fichier : packaging/locustfile.py
"""Test de charge de l'API (étape 5.2) — rejoue des lignes réelles de data/processed/test.csv.

Usage (racine du repo) :
    uv run locust -f packaging/locustfile.py --host http://localhost:8000 \
        --users 100 --spawn-rate 10 --run-time 30s --headless
"""

import random
import sys
from pathlib import Path

import pandas as pd
from locust import HttpUser, between, task

ROOT = Path(__file__).resolve().parents[1]
sys.path.append(str(ROOT))
from src.dataset_config import load_config  # noqa: E402

cfg = load_config(ROOT / "dataset.yaml")
test = pd.read_csv(ROOT / "data/processed/test.csv")[cfg.features]
# NaN -> None : JSON n'a pas de NaN, l'API attend null pour une valeur manquante
ROWS = test.astype(object).where(test.notna(), None).to_dict("records")


class PredictUser(HttpUser):
    wait_time = between(0.01, 0.05)

    @task
    def predict(self):
        self.client.post("/predict", json={"instances": [random.choice(ROWS)]})
```

```bash
docker run -d --rm -p 8000:8000 --name scoring scoring-api:optimized
uv run locust -f packaging/locustfile.py --host http://localhost:8000 \
    --users 100 --spawn-rate 10 --run-time 30s --headless
docker stop scoring
```

> **Sortie attendue :** résumé sans échec (`0(0.00%)`), de quelques centaines à environ 1 000
> requêtes/s sur un laptop. La latence P95 (de l'ordre de 10 à 50 ms selon la machine) vient
> surtout de la file d'attente de l'unique worker uvicorn, pas du modèle (0,07 ms) : c'est ce que
> l'autoscaling du Lab 5 permettra d'absorber.

## Étape 6/9 — Variante BentoML (15 min)

BentoML 1.4.39 est déjà dans le socle. Son API a beaucoup changé depuis la version 1.2 de
l'ancien énoncé : `bentoml.Service`, les *runners* et `bentoml.io` ont laissé place à une classe
décorée par `@bentoml.service`, dont les méthodes `@bentoml.api` sont typées comme une fonction
FastAPI, et à `bentoml.models.BentoModel` pour référencer un modèle du *model store*.

### 6.1 Enregistrer le modèle dans BentoML

On copie dans le model store BentoML la **même version** que celle de l'image FastAPI, avec le
contrat d'entrée en métadonnées : le service construira son schéma à partir d'elles.

```python
# Fichier : packaging/bento/save_model.py
"""Étape 6.1 — copie le modèle MLflow exporté à l'étape 1 dans le model store BentoML.

Usage (racine du repo) : uv run python packaging/bento/save_model.py
"""

import json
import os
import sys
from pathlib import Path

import bentoml
import mlflow

ROOT = Path(__file__).resolve().parents[2]
sys.path.append(str(ROOT))
from src.dataset_config import load_config  # noqa: E402

cfg = load_config(ROOT / "dataset.yaml")
# Même version et même seuil que l'image FastAPI (écrits par export_onnx.py)
meta = json.loads((ROOT / "packaging/model/metadata.json").read_text())

mlflow.set_tracking_uri(os.getenv("MLFLOW_TRACKING_URI", "http://localhost:5000"))
model = mlflow.sklearn.load_model(f"models:/{meta['model_name']}/{meta['model_version']}")

saved = bentoml.sklearn.save_model(
    "scoring_model",  # nom BentoML : identifiant Python, pas de tiret
    model,
    labels={"mlflow_model": meta["model_name"], "mlflow_version": meta["model_version"]},
    # Le contrat d'entrée voyage AVEC le modèle : le service construit son schéma à partir
    # de ces métadonnées, le Bento n'a donc pas besoin de dataset.yaml.
    metadata={
        "dataset": cfg.name,
        "numeric": cfg.numeric,
        "categorical": cfg.categorical,
        "positive_class": str(cfg.positive_class),
        "threshold": meta["threshold"],
        "model_version": meta["model_version"],
    },
)
print(f"Saved to BentoML model store: {saved.tag}")
```

```bash
uv run python packaging/bento/save_model.py
```

> **Sortie attendue :** `Saved to BentoML model store: scoring_model:<version>`.

### 6.2 Service BentoML

```python
# Fichier : packaging/bento/service.py
"""Étape 6.2 — variante BentoML de l'API : même route /predict, même JSON, port 3000."""

from typing import Annotated

import bentoml
import numpy as np
import pandas as pd
from pydantic import ConfigDict, Field, create_model

MODEL_TAG = "scoring_model:latest"
# Schéma lu dans les métadonnées du modèle (écrites par save_model.py depuis dataset.yaml)
META = bentoml.models.get(MODEL_TAG).info.metadata
FEATURES = [*META["numeric"], *META["categorical"]]
THRESHOLD = float(META["threshold"])

Numeric = Annotated[float | None, Field(strict=True, allow_inf_nan=False)]
Categorical = Annotated[str | None, Field(strict=True, min_length=1)]
Instance = create_model(
    "Instance",
    __config__=ConfigDict(extra="forbid"),
    **{c: (Numeric, ...) for c in META["numeric"]},
    **{c: (Categorical, ...) for c in META["categorical"]},
)


@bentoml.service(name="scoring_bento", resources={"cpu": "1"}, traffic={"timeout": 10})
class ScoringBento:
    # Référence au model store : le modèle est embarqué dans le Bento au build.
    bento_model = bentoml.models.BentoModel(MODEL_TAG)

    def __init__(self) -> None:
        self.model = bentoml.sklearn.load_model(self.bento_model)

    @bentoml.api
    def predict(self, instances: Annotated[list[Instance], Field(min_length=1)]) -> dict:
        df = pd.DataFrame([i.model_dump() for i in instances], columns=FEATURES)
        df = df.replace({None: np.nan})  # null -> NaN : valeur manquante pour scikit-learn
        proba = self.model.predict_proba(df)[:, 1]
        return {
            "model_version": META["model_version"],
            "positive_class": META["positive_class"],
            "threshold": THRESHOLD,
            "predictions": [
                {"probability": float(p), "prediction": int(p >= THRESHOLD)} for p in proba
            ],
        }
```

```yaml
# Fichier : packaging/bento/bentofile.yaml
service: "service:ScoringBento"
labels:
  project: scoring
  owner: mlops-cours
include:
  - "service.py"
python:
  packages:
    - scikit-learn==1.9.1
    - pandas==2.3.3
    - numpy==2.5.3
docker:
  python_version: "3.12"
```

```bash
cd packaging/bento
uv run bentoml build
# Test sans Docker : sert le Bento construit, sur le port 3000
uv run bentoml serve scoring_bento:latest --port 3000 &
sleep 10
curl -s -X POST http://localhost:3000/predict -H "Content-Type: application/json" \
    -d @/tmp/request.json
kill %1
uv run bentoml containerize scoring_bento:latest -t scoring-api:bentoml
cd ../..
docker images scoring-api --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}"
```

> **Sortie attendue :** `Successfully built Bento(tag="scoring_bento:<version>")` ; la même
> réponse JSON que FastAPI, à 10⁻⁷ près (le Bento exécute le pipeline scikit-learn, pas l'ONNX) ;
> 3 images `scoring-api` listées : `naive`, `optimized`, `bentoml`. L'image BentoML (≈ 500 Mo,
> `python:3.12-slim`, utilisateur non-root `bentoml`) se situe entre les deux autres : elle
> embarque BentoML et scikit-learn (avec SciPy).

> [!NOTE]
> **Deux différences à noter pour le rapport**
> Le Bento renvoie **400** (et non 422) sur une requête invalide, et son modèle est un **pickle**
> (`saved_model.pkl`, écrit avec joblib par `bentoml.sklearn`) : on y revient à l'étape 7.

## Étape 7/9 — Scan sécurité : Trivy + ModelScan (10 min)

### 7.1 Scan des images Docker avec Trivy

Trivy tourne dans un conteneur, à la version épinglée dans `infra/versions.env` (`v0.75.0`,
image `aquasec/trivy:0.75.0`) plutôt que `latest`, pour des résultats reproductibles. Le volume
`trivy-cache` garde la base de vulnérabilités entre deux scans : elle n'est téléchargée qu'une
fois.

```bash
trivy() {
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
    -v trivy-cache:/root/.cache/ aquasec/trivy:0.75.0 "$@"
}
trivy image --severity HIGH,CRITICAL scoring-api:optimized > reports/trivy_optimized.txt
trivy image --severity HIGH,CRITICAL scoring-api:naive > reports/trivy_naive.txt
trivy image --severity HIGH,CRITICAL scoring-api:bentoml > reports/trivy_bentoml.txt

# Compter les vulnérabilités
grep -c "CVE-" reports/trivy_*.txt
grep "^Total" reports/trivy_*.txt
```

> **Sortie attendue :** une ligne `Total: N (HIGH: x, CRITICAL: y)` par cible scannée (paquets
> Debian, puis paquets Python). L'image `optimized` (slim) a significativement moins de CVE que la
> `naive` (`python:3.12` complet, qui traîne plein de paquets Debian inutiles). Les nombres exacts
> changent chaque semaine avec la base de vulnérabilités.

### 7.2 Scan du modèle avec ModelScan

Trois artefacts, trois comportements différents. D'abord le modèle ONNX :

```bash
uv run modelscan -p packaging/model/model.onnx > reports/modelscan_onnx.txt
cat reports/modelscan_onnx.txt
uv run modelscan -p packaging/model/model.onnx --show-skipped | tail -3
```

> **Sortie attendue :** `No issues found! 🎉` puis `Total skipped: 1`. Le détail montre
> « Model Scan did not scan file » : ModelScan ne **lit** pas l'ONNX. Il est sûr par construction
> (un graphe protobuf déclaratif, sans code), pas parce qu'il a été analysé.

Ensuite, le vrai danger : un pickle. MLflow 3 n'en produit plus (skops), on en fabrique donc
deux, dont un piégé — de façon inoffensive : sa charge n'est qu'un `echo`.

```python
# Fichier : packaging/scan-demo/make_pickles.py
"""Étape 7.2 — fabrique deux pickles pour la démo ModelScan. NE PAS LES CHARGER.

- model.pkl     : le modèle sérialisé avec pickle (MLflow 2 utilisait cloudpickle) ;
- malicious.pkl : le même modèle + une charge cachée. Au chargement (pickle.load,
                  joblib.load), elle exécuterait une commande shell : ici un simple
                  `echo` inoffensif, mais ce pourrait être n'importe quoi.

Usage (racine du repo) : uv run python packaging/scan-demo/make_pickles.py
"""

import json
import os
import pickle
from pathlib import Path

import mlflow

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]

meta = json.loads((ROOT / "packaging/model/metadata.json").read_text())
mlflow.set_tracking_uri(os.getenv("MLFLOW_TRACKING_URI", "http://localhost:5000"))
model = mlflow.sklearn.load_model(f"models:/{meta['model_name']}/{meta['model_version']}")


class Payload:
    """__reduce__ dit à pickle comment « reconstruire » l'objet : ici, appeler os.system."""

    def __reduce__(self):
        return (os.system, ("echo '[pickle piégé] ce code vient de s exécuter'",))


with open(HERE / "model.pkl", "wb") as f:
    pickle.dump(model, f)
with open(HERE / "malicious.pkl", "wb") as f:
    pickle.dump({"model": model, "metadata": Payload()}, f)
print(f"Written: {HERE.relative_to(ROOT)}/model.pkl, {HERE.relative_to(ROOT)}/malicious.pkl")
```

```bash
uv run python packaging/scan-demo/make_pickles.py
uv run modelscan -p packaging/scan-demo/ > reports/modelscan_pickle.txt
grep -A4 -- "--- CRITICAL ---" reports/modelscan_pickle.txt
```

> **Sortie attendue :** `Total Issues: 1`, `CRITICAL: 1` :
> `Unsafe operator found: … Use of unsafe operator 'system' from module 'posix'` dans
> `malicious.pkl`. `model.pkl` est scanné sans problème : ModelScan détecte les appels dangereux
> (`os.system`, `eval`, `subprocess`…), il ne juge pas le modèle lui-même.

> [!CAUTION]
> **Ne chargez jamais `malicious.pkl`**
> `pickle.load()` ou `joblib.load()` exécuteraient la commande au chargement. Ne commitez pas non
> plus ces deux fichiers (ils se régénèrent en une commande ; voir l'étape 9).

Enfin, le modèle tel qu'il est stocké dans le Registry :

```bash
uv run mlflow artifacts download -u models:/scoring-model@champion -d /tmp/champion
ls /tmp/champion
uv run modelscan -p /tmp/champion
uv run python -c "from skops.io import get_untrusted_types; \
print(get_untrusted_types(file='/tmp/champion/model.skops'))"
```

> **Sortie attendue :** `model.skops` dans la liste des fichiers ; ModelScan l'ignore
> (« skipped », ce n'est pas un pickle) ; skops liste les types que le fichier demande à
> instancier hors de sa liste de confiance : `['numpy.dtype']`, un type inoffensif que le Lab 1 a
> explicitement autorisé (`skops_trusted_types`).

> [!NOTE]
> **Pourquoi ONNX plutôt que pickle en prod**
> Charger un pickle = exécuter du code Python arbitraire. Un pickle malveillant peut ouvrir un
> shell sur votre machine. ONNX est un format statique (protobuf) : aucun code, juste des
> opérations déclaratives. skops, le format de MLflow 3, est un compromis : il reconstruit des
> objets Python, mais seulement ceux d'une liste de types autorisés. Règle de sécurité : en prod,
> ONNX partout où c'est possible ; jamais de pickle d'origine non maîtrisée.

## Étape 8/9 — Push sur registry local + test pull (10 min)

### 8.1 Le registry local existe déjà

L'ancien énoncé lançait ici `docker run -d -p 5001:5000 registry:2`. **Ne le faites pas** : le
registry du cours tourne depuis le Lab 0. `make cluster` a démarré le conteneur `kind-registry`
(image `registry:3`, la version actuelle du registry de référence) sur `localhost:5001`, avec
`--restart=always`, et l'a **branché au cluster** : les nœuds kind savent tirer les images
`localhost:5001/...`. Un second registry échouerait de toute façon (`port is already allocated`).

```bash
docker ps --filter name=kind-registry --format "{{.Names}}  {{.Image}}  {{.Ports}}"
curl -s http://localhost:5001/v2/_catalog
```

> **Sortie attendue :** `kind-registry  registry:3  127.0.0.1:5001->5000/tcp` puis
> `{"repositories":["scoring-pipeline"]}` : le registry est opérationnel et contient déjà
> l'image du pipeline du Lab 2.

### 8.2 Tag + push

```bash
docker tag scoring-api:optimized localhost:5001/scoring-api:1.0.0
docker push localhost:5001/scoring-api:1.0.0

# Vérifier
curl -s http://localhost:5001/v2/_catalog
curl -s http://localhost:5001/v2/scoring-api/tags/list
```

> **Sortie attendue :** `{"repositories":["scoring-api","scoring-pipeline"]}` puis
> `{"name":"scoring-api","tags":["1.0.0"]}`.

### 8.3 Simuler un autre environnement : suppression + pull

```bash
docker rmi scoring-api:optimized localhost:5001/scoring-api:1.0.0
docker pull localhost:5001/scoring-api:1.0.0
docker run -d --rm -p 8000:8000 --name scoring-from-reg localhost:5001/scoring-api:1.0.0
sleep 5 && curl -s http://localhost:8000/health
docker stop scoring-from-reg
```

> **Sortie attendue :** `{"status":"ok","model_loaded":true}`. L'image est taggée par version,
> traçable (labels MLflow) et réutilisable par n'importe qui ayant accès au registry. C'est la
> base du workflow CD du Module 6.

### 8.4 Le cluster voit l'image (optionnel, 2 min)

```bash
kubectl run scoring-smoke --image=localhost:5001/scoring-api:1.0.0 --restart=Never
kubectl wait --for=condition=Ready pod/scoring-smoke --timeout=90s
kubectl logs scoring-smoke | tail -2
kubectl delete pod scoring-smoke
```

> **Sortie attendue :** `pod/scoring-smoke condition met` et les logs d'uvicorn
> (`Uvicorn running on http://0.0.0.0:8000`) : le cluster a tiré l'image depuis le registry
> local, sans `kind load`. C'est ainsi que le Lab 5 la déploiera avec KServe.

## Étape 9/9 — Rédiger le rapport (5 min)

Partez du modèle fourni et complétez ses 5 sections :

```bash
cp labs/m4-packaging/starter/rapport-m4.md reports/rapport-m4.md
```

- **Comparatif des tailles** : tableau (image / taille / nb CVE HIGH+CRITICAL) pour naive,
  optimized, bentoml.
- **Comparatif des latences** : tableau (backend / P50 / P95 / P99) pour les 3 backends du
  benchmark.
- **Interprétation** : pourquoi optimized est plus petite ? Pourquoi ONNX est plus rapide que
  scikit-learn ? Que montrent les scans ?
- **Choix recommandé** : laquelle retenir en prod pour ce cas d'usage ? Justifier.
- **Pistes d'amélioration** : quantization INT8, image distroless, préchargement du modèle dans
  un Init Container…

Commitez ensuite le travail. `packaging/model/` (quelques ko à quelques Mo) est versionné : la CI
du Module 6 pourra reconstruire l'image sans accès à votre MLflow. Les pickles de démonstration
sont exclus :

```bash
git add packaging reports ':(exclude)packaging/scan-demo/*.pkl'
git status        # ni .pkl, ni .env
git commit -m "Lab 4: packaging du modèle"
git push -u origin lab/m4-packaging
gh pr create   # facultatif (GitHub CLI) : ou « Compare & pull request » sur GitHub
```

Votre partenaire relit la PR (Dockerfiles, API, rapport) et l'approuve ; vous la fusionnez,
puis vous revenez sur `main` : `git switch main && git pull`.

> [!NOTE]
> **Second membre du binôme (ou nouveau poste) : remettre votre cluster à niveau**
> Une fois la PR fusionnée, reconstruisez les images sur **votre** poste à partir des fichiers
> commités : le modèle ONNX (`packaging/model/`) est celui du binôme, versionné dans Git.
>
> ```bash
> cd ~/mlops-cours-2026 && git switch main && git pull && uv sync
> docker build -f packaging/Dockerfile.naive -t scoring-api:naive .
> MODEL_VERSION=$(uv run python -c \
>     "import json; print(json.load(open('packaging/model/metadata.json'))['model_version'])")
> docker build -f packaging/Dockerfile -t scoring-api:optimized \
>     --build-arg VERSION=1.0.0 --build-arg MODEL_VERSION="$MODEL_VERSION" .
> docker tag scoring-api:optimized localhost:5001/scoring-api:1.0.0
> docker push localhost:5001/scoring-api:1.0.0
> uv run python packaging/bento/save_model.py
> (cd packaging/bento && uv run bentoml build)
> uv run bentoml containerize scoring_bento:latest -t scoring-api:bentoml
> uv run python packaging/scan-demo/make_pickles.py
> make check-m4
> ```
>
> Ne relancez pas `export_onnx.py` pour « rattraper » : il exporterait **votre** champion (autre
> numéro de version) et modifierait `packaging/model/`. Un nouveau modèle ne se commite que pour
> être publié, par une PR (Lab 6). Rapports et pickles régénérés ne se commitent pas non plus.

### Checklist de validation

| # | Élément | Test | Résultat attendu | ☐ |
|---|---|---|---|---|
| 1 | ONNX exporté | `ls -l packaging/model/` | `model.onnx` (≈ 11 kB à quelques Mo) + `metadata.json` | ☐ |
| 2 | ONNX = sklearn | `uv run python packaging/app/verify_onnx.py` | `OK: predictions match.` | ☐ |
| 3 | FastAPI local OK | `curl localhost:8000/health` | `"status":"ok"` | ☐ |
| 4 | Requête invalide refusée | `curl … -d '{"instances": [{}]}'` | HTTP 422 | ☐ |
| 5 | Image naive built | `docker images scoring-api:naive` | > 1 Go | ☐ |
| 6 | Image optimized built | `docker images scoring-api:optimized` | < 500 Mo | ☐ |
| 7 | User non-root | `docker run --rm scoring-api:optimized id` | `uid=10001(ml)` | ☐ |
| 8 | Healthcheck | `docker inspect … \| grep Health` | `healthy` | ☐ |
| 9 | Benchmark run | `uv run python packaging/app/benchmark.py` | Table 3 lignes P50/P95/P99 | ☐ |
| 10 | BentoML build | `docker images scoring-api:bentoml` | Image présente | ☐ |
| 11 | Trivy scan | `cat reports/trivy_optimized.txt` | Rapport généré | ☐ |
| 12 | ModelScan ONNX | `cat reports/modelscan_onnx.txt` | `No issues found` | ☐ |
| 13 | ModelScan pickle | `cat reports/modelscan_pickle.txt` | `CRITICAL: 1` (`posix.system`) | ☐ |
| 14 | Registry local | `curl localhost:5001/v2/scoring-api/tags/list` | `1.0.0` présent | ☐ |
| 15 | Pull depuis registry | `docker run localhost:5001/scoring-api:1.0.0` | Container healthy | ☐ |
| 16 | Rapport rédigé | `cat reports/rapport-m4.md` | 5 sections présentes | ☐ |

```bash
make check-m4
```

## Critères d'évaluation (noté sur 20)

| Critère | Description | Points |
|---|---|---|
| Image fonctionnelle | Image optimized build + healthcheck OK + prédictions cohérentes (= scikit-learn), schéma d'entrée généré depuis `dataset.yaml`, 422 sur requête invalide. | 6 |
| Optimisation taille | Image < 500 Mo, multi-stage, `.dockerignore`, user non-root. | 4 |
| Benchmark | Script de benchmark + table P50/P95/P99 sur 3 backends. | 4 |
| Scan sécurité | Trivy + ModelScan lancés, rapports dans `reports/`. | 3 |
| Rapport | 5 sections rédigées, analyse et recommandation claires. | 3 |
| **Total** | | **20** |

## Annexe — Troubleshooting

| Symptôme | Cause probable | Solution |
|---|---|---|
| `skl2onnx: unsupported operator` (ou `MissingShapeCalculator`) | Le modèle utilise une classe non supportée (ex. `CustomTransformer`, XGBoost, LightGBM). | Vérifier la liste des converters supportés. Rester sur un classifieur scikit-learn, ou écrire / installer un converter (`onnxmltools`). |
| `NotImplementedError: The converter is implemented when the missing values are string not <class 'float'>` | `SimpleImputer` sur des colonnes texte avec `NaN` comme valeur manquante. | Convertir via `onnx_ready()` (point (a) : `missing_values = ""`). |
| ONNX outputs != sklearn (`Divergence detected!`) | Entrées numériques en float32 : les arbres changent de branche. | `DoubleTensorType` + point (b) de `onnx_ready()`, et passer des `float64` à `session.run`. |
| `INVALID_ARGUMENT : Unexpected input data type. Actual: (tensor(float)), expected: (tensor(double))` | Données envoyées en float32 au graphe float64. | `astype(np.float64)` / `dtype=np.float64` pour les colonnes numériques. |
| `MlflowException: Registered model alias champion not found` | Lab 1 non terminé, ou port-forward MLflow arrêté. | `make pf`, puis vérifier l'alias dans l'UI MLflow (`http://localhost:5000`). |
| `ModuleNotFoundError: No module named 'src'` | API lancée avec le script `uvicorn` au lieu de `python -m uvicorn`, ou hors de la racine du repo. | `uv run python -m uvicorn app.serve:app --app-dir packaging` depuis la racine du repo. |
| `ImportError` sur `packaging.version`, pip ou MLflow cassés | Un `packaging/__init__.py` a été créé et masque le paquet PyPI `packaging`. | Supprimer `packaging/__init__.py` (voir l'encadré de l'étape 1.1). |
| `422 Unprocessable Entity` | Corps invalide : colonne manquante (`missing`), inconnue (`extra_forbidden`), mauvais type, ou pas d'enveloppe `instances`. | Lire `detail` ; générer un corps valide avec `packaging/sample_request.py`. |
| `docker build: no space left` | Cache Docker trop gros. | `docker system prune -af --volumes` (attention : supprime tout, y compris le volume `trivy-cache`). |
| `"/packaging/model/model.onnx": not found` au `COPY` | Modèle pas exporté, ou build lancé depuis `packaging/` au lieu de la racine. | `uv run python packaging/app/export_onnx.py`, puis `docker build -f packaging/Dockerfile … .` depuis la racine. |
| Image bloque sur `pip install` | Pas d'accès réseau depuis le build. | Vérifier le proxy Docker Desktop. Pré-télécharger avec `docker pull python:3.12-slim`. |
| `uvicorn: address already in use` | Port 8000 déjà utilisé (serveur de l'étape 2 ou conteneur encore actif). | `lsof -i:8000` + `kill`, `docker ps` + `docker stop`, ou changer de port (`--port 8001`, `-p 8001:8000`). |
| Trivy : `unable to connect to Docker` | Socket Docker non monté. | Ajouter `-v /var/run/docker.sock:/var/run/docker.sock` au `docker run` (Docker Desktop : option « Allow the default Docker socket to be used »). |
| Trivy : `TOOMANYREQUESTS` / téléchargement de la base très long | Limite de débit sur la base de vulnérabilités. | Garder le volume `trivy-cache` ; une fois la base en cache, ajouter `--skip-db-update`. |
| BentoML : `model not found` / `NotFound: Item 'scoring_model'` | `save_model.py` jamais exécuté. | Relancer `uv run python packaging/bento/save_model.py` avant `bentoml build`. |
| BentoML : `AttributeError` sur `bentoml.Service` ou `bentoml.io` | Code écrit pour BentoML 1.2. | API 1.4 : `@bentoml.service` + `@bentoml.api` (voir 6.2). |
| `bentoml containerize` : `buildx` introuvable | Plugin Docker buildx absent. | Installer `docker-buildx-plugin` (inclus dans Docker Desktop). |
| `docker run … registry:2` : `port is already allocated` | Le registry du cours occupe déjà le port 5001. | Ne pas lancer de second registry : utiliser `kind-registry` (étape 8.1). |
| `docker push` : `connection refused` sur `localhost:5001` | Conteneur `kind-registry` arrêté. | `docker start kind-registry` (ou `make cluster`, idempotent). |
| Registry push : `http: server gave HTTP response to HTTPS client` | Registry désigné par un autre nom que `localhost` (IP, `kind-registry:5000`…). | Utiliser `localhost:5001` (Docker l'autorise en HTTP), sinon ajouter `"insecure-registries"` dans `/etc/docker/daemon.json` puis redémarrer Docker. |
| Container exit code 137 | OOM killer : pas assez de RAM. | Augmenter la RAM Docker Desktop (Settings > Resources). |
| Conteneur arrêté au démarrage : `NO_SUCHFILE` / `FileNotFoundError` sur `model.onnx` ou `dataset.yaml` | Fichier absent de l'image. | Vérifier les `COPY` du Dockerfile et la liste blanche de `packaging/Dockerfile.dockerignore`. |
| ModelScan : `argument of type 'NoneType' is not iterable` | ModelScan 0.8.8 ne sait pas lire les pickles écrits par `joblib`. | Pour la démo, sérialiser avec `pickle` (c'est ce que fait `make_pickles.py`). |
| ModelScan : `skipped` / code retour 3 | Format non pris en charge (ONNX, skops). | Normal : ce n'est pas une erreur (voir 7.2). |

> [!NOTE]
> **Prochaine étape**
> Module 5 — Serving & inférence à l'échelle. Vous allez déployer l'image
> `localhost:5001/scoring-api:1.0.0` sur Kubernetes avec KServe (InferenceService
> `scoring-model` dans le namespace `scoring`), configurer l'autoscaling, et mesurer les
> performances sous charge réelle.

## Vérification automatique

Depuis la racine du repo, Docker démarré et registry actif :

```bash
make check-m4
```

Le script `labs/m4-packaging/check.sh` vérifie, sans rien modifier d'autre qu'un conteneur de
test qu'il supprime :

- le modèle exporté : `packaging/model/model.onnx` et `metadata.json` ;
- le registry local : tag `1.0.0` présent dans `localhost:5001/v2/scoring-api/tags/list`, image
  récupérable par `docker pull` ;
- l'image : taille < 500 Mo, `USER` non-root, `HEALTHCHECK` déclaré ;
- un conteneur lancé depuis l'image (port 18480, `CHECK_PORT` pour en changer) : `/health`
  répond, l'état passe à `healthy`, `/predict` renvoie une probabilité dans [0, 1] et une
  décision 0/1 pour une vraie ligne de `data/processed/test.csv` (colonnes lues dans
  `dataset.yaml`), une requête sans l'une des colonnes est refusée en 422, `/metadata` annonce le
  bon dataset ;
- les livrables : `reports/benchmark.md` (3 backends), `reports/trivy_optimized.txt` et
  `reports/trivy_naive.txt`, `reports/modelscan_onnx.txt` (`No issues found`),
  `reports/modelscan_pickle.txt` (au moins un problème CRITICAL), images `scoring-api:naive` et
  `scoring-api:bentoml`, `reports/rapport-m4.md` (5 sections `##`).

Variables optionnelles : `IMAGE` (défaut `localhost:5001/scoring-api`), `TAG` (défaut `1.0.0`).
Code retour = nombre de vérifications en échec.
