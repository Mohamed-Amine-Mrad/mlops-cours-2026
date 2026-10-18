---
module: 7
lab: 7
title: "Monitoring en production du modèle de scoring"
subtitle: "Stack complète : Prometheus, Grafana, Evidently, Loki, alerting, canary analysé"
running_title: "Lab 7 — Monitoring production"
duree: "3 heures (atelier guidé)"
stack: "Prometheus · Grafana · Evidently · Loki · Alloy · Alertmanager"
prerequis: "Labs 4, 5 et 6 réussis : scoring-model servi par KServe, piloté par Argo CD"
livrable: "Dashboard Grafana + alertes + démo drift → alerte → retrain + analyse de canary"
---

# Lab 7 — Monitoring en production du modèle de scoring

*Instrumenter l'API de scoring avec Prometheus, construire un dashboard Grafana production,
détecter le drift avec Evidently, agréger les logs avec Loki, configurer des alertes basées sur
SLO, démontrer le cycle drift → alerte → ré-entraînement et décider de la promotion d'un canary
à partir des métriques.*

Un modèle de scoring qui se dégrade ne plante pas : il continue de répondre `200 OK`, avec
des probabilités plausibles, pendant que la population des demandeurs change sous ses pieds.
La vérité terrain (« ce crédit a-t-il été remboursé ? ») n'arrive que des mois plus tard. Ce lab
installe les signaux avant-coureurs : santé du service, distribution des scores, taux de refus
(global et par groupe sensible), dérive des variables d'entrée, et les utilise pour décider.

## Objectifs

> [!NOTE]
> **À la fin du lab, vous aurez :**
>
> - Une API de scoring instrumentée avec des métriques ML (décisions, scores, latence,
>   erreurs, décisions par groupe sensible) et un journal JSON des prédictions.
> - kube-prometheus-stack déployé sur kind, scrapant automatiquement chaque révision de
>   l'InferenceService `scoring-model`.
> - Un dashboard Grafana versionné dans Git : RPS, latence P95/P99, taux de succès, scores,
>   taux de refus, drift, ressources, logs.
> - Un CronJob Evidently qui calcule le drift (PSI) sur les demandes réelles et le publie dans
>   Prometheus.
> - Loki + Grafana Alloy pour l'agrégation des logs, visibles dans Grafana.
> - Des alertes Alertmanager basées sur les SLO (burn rate) + webhook Slack, chacune avec un
>   runbook.
> - Une démo de bout en bout : drift injecté → alerte → ré-entraînement (Lab 6) lancé.
> - Un canary KServe analysé par les métriques : promotion ou rollback décidé et appliqué
>   par Git.

## Plan du lab

| # | Étape | Durée |
|---|---|---|
| 1 | Instrumenter l'API : `/metrics` et métriques métier | 20 min |
| 2 | Déployer l'API instrumentée par GitOps | 10 min |
| 3 | Installer la stack d'observabilité via Helm | 15 min |
| 4 | Configurer un PodMonitor pour l'InferenceService | 15 min |
| 5 | Construire le dashboard Grafana production | 25 min |
| 6 | CronJob Evidently : drift dans Prometheus | 30 min |
| 7 | Loki + Alloy pour les logs | 15 min |
| 8 | Alertmanager : alertes SLO + webhook Slack | 20 min |
| 9 | Démo : drift → alerte → ré-entraînement | 15 min |
| 10 | Analyser un canary par les métriques : promouvoir ou annuler | 15 min |

> [!WARNING]
> **Ressources requises**
> kube-prometheus-stack consomme ≈ 2 Go de RAM, Loki et Alloy ≈ 0,5 Go de plus. Combiné à
> KServe (Lab 5) et Argo CD (Lab 6), il faut au moins 10 Go alloués à Docker. Ne recréez
> **pas** le cluster : libérez plutôt la mémoire des labs précédents. Airflow (Lab 2)
> s'arrête avec `(cd infra/airflow && docker compose down)` ; Kubeflow Pipelines se met en
> pause avec `kubectl -n kubeflow scale deploy --all --replicas=0`, mais remettez-le à 1
> (`--replicas=1`) avant l'étape 9, qui lance un ré-entraînement.

> [!NOTE]
> **Vous travaillez sur votre propre dataset ?**
> Rien ne change dans le code ni dans les manifests : l'API, le générateur de trafic, le job
> de drift et `make check-m7` lisent les variables, la classe positive et les attributs
> sensibles dans `dataset.yaml`. Les chiffres (taux de refus, scores, PSI) seront différents.
> Points d'attention : (1) à l'étape 9, choisissez les variables à déformer (`--drift
> COLONNE=FACTEUR`) parmi les vôtres ; sans option, toutes les variables numériques sont
> multipliées par 1,5 ; (2) un attribut sensible déclaré « d'audit seulement » (absent des
> features) n'est pas envoyé à l'API : il ne peut pas être suivi par groupe en production ;
> (3) la classe positive (`outcome="1"`) n'est un « refus » que pour le crédit : relisez les
> libellés du dashboard et des alertes ; (4) le seuil de PSI (0,25) suppose un jeu de
> référence de quelques centaines de lignes au moins.

## Branche de travail

Comme chaque lab (convention du Lab 0, étape 8.1), celui-ci se fait sur sa propre branche,
créée depuis `main` à jour, et se termine par une pull request relue par le partenaire du
binôme :

```bash
cd ~/mlops-cours-2026
git switch main && git pull
git switch -c lab/m7-monitoring
```

Comme au Lab 6, `main` est ce qui est déployé, d'où deux PR. La première, `lab/m7-monitoring`
(étapes 1 et 2), contient l'API instrumentée : sa fusion la déploie en staging. Les étapes 3
à 10 se font ensuite sur `main` à jour, **sans commit** : les opérations GitOps des étapes 2.2,
9.4 et 10 (`gitops … --push`, `canary_analysis.py --apply --push`) partent de `main`, et l'outil
refuse de partir d'une branche `lab/*`. Les fichiers des étapes 3 à 10 se commitent à la fin
sur une seconde branche, `lab/m7-observabilite`, créée au moment du commit (étape 10.3).

## Convention de notation

Les blocs de code contiennent des commandes shell à exécuter telles quelles depuis la racine de
votre fork (`~/mlops-cours-2026`) : elles n'ont **pas** de préfixe `$`, vous pouvez les
copier-coller directement. Les lignes commençant par `#` sont des commentaires. Un bloc dont la
première ligne est `# Fichier : chemin` est le contenu **complet** de ce fichier. Les encadrés
« Sortie attendue » montrent le résultat attendu.

## Étape 1/10 — Instrumenter l'API : `/metrics` et métriques métier (20 min)

### 1.1 Partir de l'API des Labs 4 à 6

On travaille dans le fork, sur l'API telle que le Lab 6 la construit et la déploie :
`packaging/app/serve.py` (schéma tiré de `dataset.yaml`, modèle ONNX, seuil métier, `/version`).
La bibliothèque `prometheus-client` est déjà dans l'environnement du cours (`uv sync`) ; il
faut l'ajouter aux dépendances **de l'image**, qui ne contient que le strict nécessaire :

```bash
cd ~/mlops-cours-2026
set -a && source .env && set +a
uv sync
uv run python -c "from importlib.metadata import version; print(version('prometheus-client'))"
```

> **Sortie attendue :** `0.24.1`.

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
# Lab 7 : métriques Prometheus (/metrics)
prometheus-client==0.24.1
```

> [!NOTE]
> **Pourquoi 0.24 et pas la toute dernière version ?**
> Le projet n'a qu'un environnement Python (`uv.lock`) : Feast (Lab 1) exige
> `prometheus-client<0.25`. L'image de l'API reprend la version résolue par le verrou, pour
> que les tests locaux et l'image exécutent le même code.

### 1.2 Quelles métriques, pour quelles questions ?

Les « 4 signaux d'or » (latence, trafic, erreurs, saturation) disent si le **service** va
bien. Ils ne disent rien du **modèle** : un modèle qui refuse soudain 90 % des demandes reste
rapide et sans erreur. On ajoute donc des métriques métier :

| Métrique | Type | Labels | Question |
|---|---|---|---|
| `http_requests_total` | Counter | `method`, `handler`, `code` | Combien de requêtes, combien en erreur 5xx, combien rejetées (422) ? |
| `ml_inference_latency_seconds` | Histogram | — | Quelle latence P95/P99 pour `/predict` ? |
| `ml_predictions_total` | Counter | `model`, `version`, `outcome` | Combien de décisions, et quelle part positive (`outcome="1"`, ici un refus) ? |
| `ml_prediction_score` | Histogram | — | Comment se distribuent les scores servis (probabilité de `bad`) ? |
| `ml_predictions_by_group_total` | Counter | `attribute`, `group`, `outcome` | Le taux de refus dérive-t-il pour un groupe sensible (âge, statut, nationalité) ? |
| `ml_model_info` | Info | `model`, `model_version`, `api_version`, `threshold` | Quelle version, quel seuil sert chaque pod ? |

Deux règles guident ces choix :

- **La cardinalité.** Chaque combinaison de valeurs de labels est une série temporelle
  stockée par Prometheus. Un label ne doit jamais contenir une valeur libre (identifiant de
  demande, montant, âge exact). Les groupes sensibles viennent des `bins`/`labels` de
  `dataset.yaml` (`<25`, `>=25`), et l'API plafonne à 20 groupes par attribut (le reste va
  dans `other`) : un client ne peut pas créer de séries à volonté.
- **Le bon outil pour la bonne question.** L'ancienne version de ce lab exposait un
  histogramme des valeurs de deux features. Un histogramme Prometheus a les mêmes bornes pour
  toutes ses séries : impossible de bien découper à la fois une durée (4 à 72 mois) et un
  montant (250 à 18 000 DM). La dérive des variables d'entrée est confiée à Evidently
  (étape 6), qui compare des distributions complètes ; Prometheus suit ce qui est agrégeable
  en temps réel : volumes, scores, décisions.

Enfin, l'API **journalise chaque prédiction** en une ligne JSON (variables reçues, score,
décision) sur sa sortie standard. Alloy les enverra à Loki (étape 7) et le job de drift les
relira (étape 6) : c'est le « 4e pilier » de l'observabilité ML, les événements.

> [!CAUTION]
> **Ces journaux sont des données personnelles**
> Une demande de crédit décrit une personne (âge, situation familiale, nationalité). La
> journaliser est légitime pour surveiller le modèle, à condition de le limiter : rétention
> courte (72 h dans Loki, étape 7), accès restreint, pas d'identifiant direct (l'API n'en
> reçoit pas). `LOG_PREDICTIONS=false` coupe le journal. Le Lab 8 revient sur le RGPD.

### 1.3 Modifier `packaging/app/serve.py`

Version complète. Nouveautés du Lab 7 : la section « Métriques Prometheus », le journal des
prédictions, le middleware `count_requests`, `observe()`, la route `/metrics` et leur appel
dans `predict()` :

```python
# Fichier : packaging/app/serve.py
"""API de scoring : sert le modèle ONNX exporté à l'étape 1.

Le schéma d'entrée est construit à partir de dataset.yaml : aucune colonne n'est écrite
ici, changer de dataset ne demande aucune modification de ce fichier.

Lab 7 : l'API est instrumentée. GET /metrics expose des métriques Prometheus (trafic,
latence, erreurs, scores, décisions, décisions par groupe sensible) et chaque prédiction
est journalisée en JSON sur la sortie standard (collectée par Alloy -> Loki, relue par le
job de drift).

Lancement local (depuis la racine du repo) :
    uv run python -m uvicorn app.serve:app --app-dir packaging --port 8000
"""

import bisect
import json
import logging
import os
import sys
from pathlib import Path
from typing import Annotated, Any

import numpy as np
import onnxruntime as ort
from fastapi import FastAPI, HTTPException, Request, Response
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    GC_COLLECTOR,
    PLATFORM_COLLECTOR,
    PROCESS_COLLECTOR,
    CollectorRegistry,
    Counter,
    Histogram,
    Info,
    disable_created_metrics,
    generate_latest,
)
from pydantic import BaseModel, ConfigDict, Field, create_model

ROOT = Path(__file__).resolve().parents[2]  # racine du repo (/app dans l'image)
sys.path.append(str(ROOT))  # rend « src » importable quel que soit le lanceur
from src.dataset_config import load_config  # noqa: E402

# Version de l'image : ENV APP_VERSION posée au build (Lab 5) ; 1.0.0 pour l'image du Lab 4
API_VERSION = os.getenv("APP_VERSION", "1.0.0")
MAX_BATCH = int(os.getenv("MAX_BATCH", "1000"))
MODEL_PATH = Path(os.getenv("MODEL_PATH", ROOT / "packaging" / "model" / "model.onnx"))

cfg = load_config(os.getenv("DATASET_CONFIG", ROOT / "dataset.yaml"))
session = ort.InferenceSession(str(MODEL_PATH), providers=["CPUExecutionProvider"])
meta_path = MODEL_PATH.with_name("metadata.json")
metadata: dict[str, Any] = json.loads(meta_path.read_text()) if meta_path.exists() else {}
# Seuil : variable d'environnement > metadata.json (seuil du run d'entraînement) > coût métier
THRESHOLD = float(os.getenv("DECISION_THRESHOLD", metadata.get("threshold", cfg.cost_threshold())))
MODEL_VERSION = str(metadata.get("model_version", "unknown"))
MODEL_NAME = str(metadata.get("model_name", "scoring-model"))
MODEL_KEYS = ("model_name", "model_alias", "model_version", "run_id", "onnx_sha256", "exported_at")

# --- Métriques Prometheus (Lab 7) ------------------------------------------------------
# Règle d'or : des labels à valeurs PEU nombreuses et connues à l'avance. Jamais un
# identifiant, un montant ou une valeur saisie par le client (chaque valeur distincte
# crée une nouvelle série temporelle dans Prometheus).
disable_created_metrics()  # pas de séries *_created : moitié moins de séries à stocker
# Registre propre au module (+ métriques du processus) : réimporter serve.py, comme le font
# les tests, ne provoque pas d'erreur « Duplicated timeseries in CollectorRegistry ».
REGISTRY = CollectorRegistry()
for collector in (PROCESS_COLLECTOR, PLATFORM_COLLECTOR, GC_COLLECTOR):
    REGISTRY.register(collector)
PREDICTIONS = Counter(
    "ml_predictions_total",
    "Décisions rendues (outcome=1 : classe positive de dataset.yaml, ici un refus)",
    ["model", "version", "outcome"],
    registry=REGISTRY,
)
LATENCY = Histogram(
    "ml_inference_latency_seconds",
    "Durée de traitement d'une requête /predict (validation exclue)",
    buckets=[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5],
    registry=REGISTRY,
)
SCORES = Histogram(
    "ml_prediction_score",
    "Score servi : probabilité de la classe positive",
    buckets=[round(0.05 * i, 2) for i in range(1, 20)],  # 0.05, 0.10, ..., 0.95
    registry=REGISTRY,
)
GROUP_PREDICTIONS = Counter(
    "ml_predictions_by_group_total",
    "Décisions par groupe d'un attribut sensible de dataset.yaml (équité, Lab 8)",
    ["attribute", "group", "outcome"],
    registry=REGISTRY,
)
HTTP_REQUESTS = Counter(
    "http_requests_total",
    "Requêtes HTTP par route (modèle de chemin) et code de réponse",
    ["method", "handler", "code"],
    registry=REGISTRY,
)
MODEL_INFO = Info("ml_model", "Modèle servi par cette instance de l'API", registry=REGISTRY)
MODEL_INFO.info(
    {
        "model": MODEL_NAME,
        "model_version": MODEL_VERSION,
        "api_version": API_VERSION,
        "threshold": f"{THRESHOLD:.4f}",
    }
)

# Attributs sensibles reçus par l'API (un attribut « d'audit » absent des features n'est
# pas envoyé par le client : il ne peut pas être suivi ici).
SENSITIVE = [s for s in cfg.sensitive if s.column in cfg.features]
# Garde-fou de cardinalité : au plus N groupes par attribut et par instance, le reste
# est compté dans « other » (un client ne peut pas créer des séries à volonté).
MAX_GROUPS = int(os.getenv("MAX_GROUPS_PER_ATTRIBUTE", "20"))
_known_groups: dict[str, set[str]] = {s.column: set() for s in SENSITIVE}


def group_of(s, value: Any) -> str:
    """Groupe d'une valeur, avec le découpage du Lab 8 (SensitiveAttribute.groups).

    Réécrit sans pandas : pd.cut coûte ~0,6 ms par appel, six fois l'inférence ONNX.
    bins=[0, 25, 120] et right=False : [0, 25) -> labels[0], [25, 120) -> labels[1].
    """
    if value is None:
        return "missing"
    if s.bins is None:
        group = str(value)
    else:
        i = bisect.bisect_right(s.bins, value) - 1
        if not 0 <= i < len(s.bins) - 1:
            return "missing"  # hors des bornes : pd.cut renvoie aussi NaN
        group = s.labels[i] if s.labels else f"[{s.bins[i]}, {s.bins[i + 1]})"
    known = _known_groups[s.column]
    if group not in known and len(known) >= MAX_GROUPS:
        return "other"
    known.add(group)
    return group


# --- Journal des prédictions (une ligne JSON par demande) ---------------------------------
# Ce sont des données personnelles (demandes de crédit) : rétention courte dans Loki,
# accès restreint, désactivable avec LOG_PREDICTIONS=false.
LOG_PREDICTIONS = os.getenv("LOG_PREDICTIONS", "true").lower() in ("1", "true", "yes")
prediction_log = logging.getLogger("scoring.predictions")
if not prediction_log.handlers:
    _handler = logging.StreamHandler(sys.stdout)
    _handler.setFormatter(logging.Formatter("%(message)s"))
    prediction_log.addHandler(_handler)
    prediction_log.setLevel(logging.INFO)
    prediction_log.propagate = False

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


@app.middleware("http")
async def count_requests(request: Request, call_next):
    """Compte chaque requête par route et code HTTP (taux d'erreur, requêtes rejetées)."""
    code = 500  # une exception non gérée devient une 500
    try:
        response = await call_next(request)
        code = response.status_code
        return response
    finally:
        route = request.scope.get("route")  # renseignée par le routeur après call_next
        # Modèle de chemin (/predict), jamais l'URL brute : cardinalité bornée
        handler = getattr(route, "path", "other")
        HTTP_REQUESTS.labels(request.method, handler, str(code)).inc()


def score(rows: list[dict[str, Any]]) -> np.ndarray:
    """Probabilité de la classe positive pour chaque demande (une entrée ONNX par colonne).

    numpy plutôt que pandas : construire un DataFrame coûte ~50x plus cher que l'inférence.
    """
    # null -> NaN (numérique) ou "" (catégoriel) : imputés dans le graphe ONNX
    feed = {c: np.array([[r[c]] for r in rows], dtype=np.float64) for c in cfg.numeric}
    feed |= {c: np.array([[r[c] or ""] for r in rows], dtype=object) for c in cfg.categorical}
    (proba,) = session.run(["probabilities"], feed)
    return proba[:, 1]


def observe(rows: list[dict[str, Any]], proba: np.ndarray, decisions: list[int]) -> None:
    """Lab 7 : métriques métier + journal JSON des prédictions."""
    for outcome in (0, 1):
        n = decisions.count(outcome)
        if n:
            PREDICTIONS.labels(MODEL_NAME, MODEL_VERSION, str(outcome)).inc(n)
    for p in proba:
        SCORES.observe(float(p))
    for s in SENSITIVE:
        for row, outcome in zip(rows, decisions, strict=True):
            GROUP_PREDICTIONS.labels(s.column, group_of(s, row[s.column]), str(outcome)).inc()
    if LOG_PREDICTIONS:
        for row, p, outcome in zip(rows, proba, decisions, strict=True):
            prediction_log.info(
                json.dumps(
                    {
                        "event": "prediction",
                        "model_version": MODEL_VERSION,
                        "api_version": API_VERSION,
                        "probability": round(float(p), 6),
                        "prediction": outcome,
                        "features": row,
                    },
                    ensure_ascii=False,
                    separators=(",", ":"),
                )
            )


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


@app.get("/version")
def version():
    # Lab 5 : quelle version a répondu ? (canary, rollback, tests de fumée du Lab 6)
    return {"version": API_VERSION, "model_version": MODEL_VERSION}


@app.get("/metrics", include_in_schema=False)
def metrics():
    # Route explicite plutôt que app.mount("/metrics", make_asgi_app()) : le montage
    # répond 307 sur /metrics (redirection vers /metrics/), déroutant avec curl.
    return Response(generate_latest(REGISTRY), media_type=CONTENT_TYPE_LATEST)


@app.post("/predict", response_model=PredictResponse)
def predict(req: PredictRequest):
    with LATENCY.time():
        rows = [i.model_dump() for i in req.instances]
        try:
            proba = score(rows)
        except Exception as e:
            raise HTTPException(500, str(e)) from e
        decisions = [int(p >= THRESHOLD) for p in proba]
        observe(rows, proba, decisions)
        return PredictResponse(
            model_version=MODEL_VERSION,
            positive_class=str(cfg.positive_class),
            threshold=THRESHOLD,
            predictions=[
                Prediction(probability=float(p), prediction=d)
                for p, d in zip(proba, decisions, strict=True)
            ],
        )
```

Ce qui a changé par rapport au Lab 6 :

- **`GET /metrics`** est une route ordinaire qui renvoie `generate_latest()`. Le classique
  `app.mount("/metrics", make_asgi_app())` répond `307` à `/metrics` (redirection vers
  `/metrics/`) : Prometheus suit la redirection, mais `curl` n'affiche rien et on croit à une
  panne.
- **Le middleware** `count_requests` compte toutes les requêtes avec le **modèle de chemin**
  (`/predict`, jamais l'URL brute) et le code de réponse : les erreurs de validation (`422`)
  sont un signal de qualité de données, les `5xx` un signal de disponibilité.
- **`observe()`** alimente les métriques métier et le journal. Le découpage par groupe
  (`group_of`) reproduit exactement celui du Lab 8 (`SensitiveAttribute.groups`) mais sans
  pandas : `pd.cut` coûte 0,6 ms par appel, six fois l'inférence ONNX.
- **Un registre propre au module** (`REGISTRY`, avec les métriques du processus : mémoire,
  CPU, version de Python) plutôt que le registre global de `prometheus-client` : les tests du
  Lab 6 réimportent `serve.py` avec un mini-modèle, ce qui, avec le registre global, lèverait
  `Duplicated timeseries in CollectorRegistry`.
- `disable_created_metrics()` supprime les séries `*_created` que `prometheus-client` ajoute
  à chaque compteur : moitié moins de séries pour Prometheus.

### 1.4 Test local

Lancez l'API, envoyez 20 requêtes de 20 demandes réelles (`packaging/sample_request.py` du
Lab 4 lit `test.csv` et `dataset.yaml`), puis lisez `/metrics` :

```bash
uv run python -m uvicorn app.serve:app --app-dir packaging --port 8000 > /tmp/api.log 2>&1 &
sleep 3
uv run python packaging/sample_request.py -n 20 > /tmp/request.json
for i in $(seq 1 20); do
  curl -s -X POST http://localhost:8000/predict \
      -H "Content-Type: application/json" -d @/tmp/request.json > /dev/null
done
curl -s http://localhost:8000/metrics | grep -E "^(ml_|http_requests)" | grep -v _bucket
grep -m1 '"event":"prediction"' /tmp/api.log
kill %1
```

> **Sortie attendue :** 400 décisions (20 × 20), autant de refus que d'acceptations sur ces
> 20 lignes, une série par groupe sensible, et une ligne JSON par prédiction :

```text
ml_predictions_total{model="scoring-model",outcome="0",version="1"} 200.0
ml_predictions_total{model="scoring-model",outcome="1",version="1"} 200.0
ml_inference_latency_seconds_count 20.0
ml_inference_latency_seconds_sum 0.02648652399693674
ml_prediction_score_count 400.0
ml_prediction_score_sum 151.2487405538559
ml_predictions_by_group_total{attribute="age",group=">=25",outcome="1"} 140.0
ml_predictions_by_group_total{attribute="age",group=">=25",outcome="0"} 160.0
ml_predictions_by_group_total{attribute="age",group="<25",outcome="1"} 60.0
ml_predictions_by_group_total{attribute="age",group="<25",outcome="0"} 40.0
ml_predictions_by_group_total{attribute="personal_status",group="male mar/wid",outcome="1"} 40.0
...
ml_predictions_by_group_total{attribute="foreign_worker",group="yes",outcome="0"} 200.0
http_requests_total{code="200",handler="/predict",method="POST"} 20.0
ml_model_info{api_version="1.0.0",model="scoring-model",model_version="1",threshold="0.3182"} 1.0
{"event":"prediction","model_version":"1","api_version":"1.0.0","probability":0.509125,"prediction":1,"features":{"duration":18.0,"credit_amount":1913.0,...,"foreign_worker":"yes"}}
```

Le taux de refus de ces 20 lignes (50 %) est un hasard du tirage : sur tout le jeu de test,
le modèle refuse ≈ 63 % des demandes (seuil 0,318, choisi au Lab 1 pour un faux négatif cinq
fois plus coûteux qu'un faux positif). Retenez cet ordre de grandeur : c'est la référence du
taux de refus en production.

### 1.5 Tests automatisés

Copiez les fichiers fournis (tests, générateur de trafic, analyse du canary, dashboard,
runbooks) depuis le dossier `starter/` du lab :

```bash
cp -r labs/m7-monitoring/starter/monitoring .
cp labs/m7-monitoring/starter/tests/test_monitoring.py tests/
uv run pytest tests/test_monitoring.py -v
```

> **Sortie attendue :** `13 passed`. Les trois premiers tests interrogent l'API en mémoire
> (`TestClient`) : `/metrics` répond `200` (pas de redirection), les métriques métier sont
> présentes, une requête invalide est comptée en `422`, et les groupes de l'API sont ceux du
> Lab 8. Ils servent le vrai modèle (`packaging/model/`), ou le mini-modèle des tests du
> Lab 6 si ceux-ci ont déjà importé l'API (`uv run pytest` lance tout : une quarantaine de
> tests). Les suivants testent le générateur de trafic et l'analyse de canary (étapes 5 et
> 10). Ils tournent aussi dans la CI du Lab 6 : une régression d'observabilité bloque désormais
> le déploiement.

Extrait du test principal :

```python
def test_metrics_endpoint_exposes_business_metrics(monitored):
    _, client = monitored
    r = client.post("/predict", json={"instances": [a_request(), a_request()]})
    assert r.status_code == 200
    metrics = client.get("/metrics")
    assert metrics.status_code == 200  # route directe : pas de redirection 307
    text = metrics.text
    for name in (
        "ml_predictions_total",
        "ml_inference_latency_seconds_bucket",
        "ml_prediction_score_bucket",
        "http_requests_total",
        "ml_model_info",
    ):
        assert name in text, name
    assert 'handler="/predict"' in text
```

## Étape 2/10 — Déployer l'API instrumentée par GitOps (10 min)

### 2.1 Pousser : la CI construit l'image et la déploie en staging

Depuis le Lab 6, on ne fait plus de `docker build` ni de `kubectl apply` à la main : la PR
fait tourner la CI (lint, tests — dont ceux de l'étape 1.5 —, construction de l'image), et sa
fusion sur `main` publie l'image sur GHCR puis la déploie en **staging** par Argo CD.

```bash
git add packaging/app/serve.py packaging/requirements.txt monitoring tests/test_monitoring.py
git commit -m "feat(api): métriques Prometheus et journal des prédictions (Lab 7)"
git push -u origin lab/m7-monitoring
gh pr create
gh pr checks --watch                          # quelques minutes
```

Relecture, approbation et fusion par le binôme, puis :

```bash
gh run watch                                  # le run de main : publication + staging
git switch main && git pull
uv run python -m pipelines.gitops status
```

> **Sortie attendue :** le workflow passe au vert sur la PR puis sur `main` ; `status` montre
> en staging un nouveau tag `2.x.y` (numéro de run de la CI) et en prod l'ancien. Vous êtes
> sur `main`, à jour : c'est de là que partent les opérations GitOps de la suite du lab.

### 2.2 Passer en production : un premier canary, contrôlé à la main

La production ne reçoit une image que par un commit de canary (Lab 6) :

```bash
uv run python -m pipelines.gitops deploy --env prod --canary 10 --push
kubectl get isvc scoring-model -n scoring -w          # Ctrl-C quand READY=True, LATEST=10
ISVC_HOST=$(kubectl get isvc scoring-model -n scoring -o jsonpath='{.status.url}' | cut -d/ -f3)
export ISVC_HOST
curl -s -H "Host: latest-${ISVC_HOST}" http://localhost:30080/metrics | grep ^ml_model_info
curl -s -H "Host: prev-${ISVC_HOST}" -o /dev/null -w "%{http_code}\n" \
    http://localhost:30080/metrics
```

> **Sortie attendue :** la nouvelle révision (route `latest-`) expose
> `ml_model_info{api_version="2.x.y",...} 1.0` ; l'ancienne (route `prev-`) répond `404` :
> elle n'a pas de `/metrics`.

C'est précisément pourquoi ce premier canary ne peut pas être analysé par les métriques : la
version stable est muette, il n'y a rien à comparer. On se contente d'un contrôle de fumée
(la nouvelle version répond et expose ses métriques), puis on promeut :

```bash
uv run python -m pipelines.gitops promote --push
kubectl get isvc scoring-model -n scoring       # LATEST=100
```

> [!IMPORTANT]
> **Point de validation**
> À partir d'ici, toutes les révisions de production sont instrumentées. Le prochain canary
> (étape 10) sera comparé à la version stable **métrique par métrique**, et la décision de
> promotion sera prise par un script, pas « à l'œil ».

## Étape 3/10 — Installer la stack d'observabilité via Helm (15 min)

### 3.1 Helm et les charts

Helm est installé depuis le Lab 0 (`helm version` : v4.x ; Helm 3 convient aussi). Le script
`infra/monitoring/install.sh` ajoute lui-même les dépôts de charts et épingle les versions :

| Brique | Chart (dépôt) | Version | Rôle |
|---|---|---|---|
| kube-prometheus-stack | `prometheus-community/kube-prometheus-stack` | 91.9.0 (`infra/versions.env`) | Prometheus v3.15, Alertmanager v0.34, Grafana 13.2, operator v0.94, kube-state-metrics, node-exporter |
| Pushgateway | `prometheus-community/prometheus-pushgateway` | 3.9.0 | reçoit les métriques du job de drift (étape 6) |
| Loki | `grafana-community/loki` | 18.13.8 (Loki 3.7) | stockage des logs, mode monolithique |
| Grafana Alloy | `grafana/alloy` | 1.13.0 (Alloy v1.20) | collecte des logs des pods vers Loki |

> [!NOTE]
> **Pourquoi Loki et Alloy plutôt que `loki-stack` et Promtail ?**
> Le chart `grafana/loki-stack` de l'ancienne version de ce lab n'est plus maintenu, et
> Promtail est en fin de vie depuis mars 2026 : son successeur est Grafana Alloy. Le chart Loki
> lui-même est maintenu depuis 2026 par la communauté (`grafana-community`), et son mode
> monolithique (un seul pod) est fait pour les petits clusters comme le nôtre.

### 3.2 Les values de kube-prometheus-stack

```yaml
# Fichier : monitoring/values-monitoring.yaml
# Values de kube-prometheus-stack 91.9.0 pour le cluster kind du cours :
# pas de persistance, ressources réduites, et Prometheus qui découvre TOUS les
# PodMonitor / ServiceMonitor / PrometheusRule du cluster (pas seulement ceux du chart).
prometheus:
  prometheusSpec:
    retention: 24h
    resources:
      requests: {cpu: 200m, memory: 512Mi}
      limits: {cpu: "1", memory: 1Gi}
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
grafana:
  adminPassword: admin            # lab uniquement
  # Pas de NodePort : le port 30080 du poste est déjà celui de Kourier (Lab 5).
  # Accès par port-forward (kubectl -n monitoring port-forward svc/kube-prom-stack-grafana 3000:80)
  additionalDataSources:
    - name: Loki
      uid: loki
      type: loki
      access: proxy
      url: http://loki.monitoring:3100
      jsonData:
        maxLines: 1000
  resources:
    requests: {cpu: 50m, memory: 128Mi}
    limits: {memory: 384Mi}
alertmanager:
  alertmanagerSpec:
    # Les AlertmanagerConfig (étape 8) s'appliquent à toutes les alertes, quel que soit
    # leur namespace (par défaut : seulement celles du namespace de l'AlertmanagerConfig).
    alertmanagerConfigMatcherStrategy:
      type: None
    resources:
      requests: {memory: 64Mi}
      limits: {memory: 128Mi}
# Sur kind, ces composants n'exposent leurs métriques que sur 127.0.0.1 : cibles DOWN
# et alertes permanentes. On ne les surveille pas.
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeEtcd:
  enabled: false
kubeProxy:
  enabled: false
# Docker Desktop (macOS, Windows) : la racine du nœud kind n'est pas un montage partagé et
# node-exporter refuse de démarrer (« path / is mounted on / but it is not a shared or slave
# mount »). On renonce aux métriques de disques du nœud, inutiles ici.
prometheus-node-exporter:
  hostRootFsMount:
    enabled: false
```

Quatre réglages méritent une explication :

- **`*SelectorNilUsesHelmValues: false`** : sans cela, Prometheus ne prend en compte que les
  PodMonitor, ServiceMonitor et PrometheusRule portant le label `release: kube-prom-stack`. On
  lui demande de les découvrir tous (nos manifests portent quand même ce label).
- **Pas de NodePort pour Grafana** : l'ancienne version exposait Grafana sur le port 30080.
  Ce port de votre poste est celui de la passerelle KServe depuis le Lab 5. On passera par un
  port-forward.
- **Contrôleur, scheduler, etcd, kube-proxy désactivés** : sur kind, ils n'exposent leurs
  métriques que sur `127.0.0.1` ; les laisser, c'est quatre cibles `DOWN` et des alertes
  permanentes dès l'installation.
- **`hostRootFsMount` de node-exporter désactivé** : sous Docker Desktop, la racine d'un nœud
  kind n'est pas un montage partagé et node-exporter refuse de démarrer. On perd les
  métriques de disque des nœuds, sans intérêt ici.

### 3.3 Installer

```bash
make monitoring
kubectl get pods -n monitoring
```

> **Sortie attendue :** après 3 à 5 minutes, tous les pods `Running` et prêts :

```text
NAME                                                     READY   STATUS
alertmanager-kube-prom-stack-kube-prome-alertmanager-0   2/2     Running
alloy-7c9d8b6f5-xk2lp                                    2/2     Running
kube-prom-stack-grafana-6d8f7c9b4-q8zrt                  3/3     Running
kube-prom-stack-kube-prome-operator-5b8f9d7c6-2xkqp      1/1     Running
kube-prom-stack-kube-state-metrics-7f6c8d9b5-l4mwn       1/1     Running
kube-prom-stack-prometheus-node-exporter-4tx8r           1/1     Running
kube-prom-stack-prometheus-node-exporter-9kq2d           1/1     Running
kube-prom-stack-prometheus-node-exporter-r7m5w           1/1     Running
loki-0                                                   1/1     Running
prometheus-kube-prom-stack-kube-prome-prometheus-0       2/2     Running
prometheus-pushgateway-6b7c9d8f4-h5jzs                   1/1     Running
```

Le script est idempotent : relancez `make monitoring` après toute modification de
`monitoring/values-monitoring.yaml` (`helm upgrade --install`). Extrait :

```bash
install_kps() {
  echo ">>> kube-prometheus-stack ${KUBE_PROMETHEUS_STACK_VERSION} (values : ${KPS_VALUES})"
  helm_up kube-prom-stack prometheus-community/kube-prometheus-stack \
    --version "${KUBE_PROMETHEUS_STACK_VERSION}" \
    --values "${KPS_VALUES}" --wait --timeout 10m
}
```

### 3.4 Accéder aux interfaces

```bash
./infra/monitoring/port-forward.sh
```

> **Sortie attendue :** Grafana sur `http://localhost:3000` (`admin` / `admin`), Prometheus
> sur `http://localhost:9090`, Alertmanager sur `http://localhost:9093`, plus l'API de Loki
> (`:3100`) et le Pushgateway (`:9091`). Les port-forwards tournent en arrière-plan (journaux
> dans `/tmp/mlops-port-forward/`) ; `./infra/monitoring/port-forward.sh stop` les arrête.

## Étape 4/10 — Configurer un PodMonitor pour l'InferenceService (15 min)

### 4.1 ServiceMonitor ou PodMonitor ?

Un ServiceMonitor dit à Prometheus « scrape les pods derrière ce Service ». C'est le choix
naturel pour un Deployment classique, mais pas pour un InferenceService en mode Knative :
les Services de chaque révision (`scoring-model-predictor-00004-private`…) n'exposent que le
**queue-proxy** de Knative, jamais le port 8000 de votre API. On vise donc directement les
pods avec un **PodMonitor**, la ressource de Prometheus Operator prévue pour cela.

Deux détails Knative comptent :

- le port 8000 de votre conteneur est renommé `user-port` par Knative : on le désigne par
  son numéro (`portNumber: 8000`), ce qui marche aussi en mode Standard ;
- chaque pod porte le label `serving.knative.dev/revision`. On le recopie dans un label
  `revision` de **toutes** les séries : c'est ce qui permettra de comparer une version
  stable et un canary (étape 10).

```yaml
# Fichier : monitoring/scoring-podmonitor.yaml
# « Scrape les pods de l'InferenceService scoring-model sur le port 8000, chemin /metrics. »
# PodMonitor plutôt que ServiceMonitor : en mode Knative, les Services de la révision
# n'exposent que le queue-proxy, jamais le port 8000 de l'API ; on vise donc les pods.
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: scoring-api
  namespace: monitoring
  labels:
    release: kube-prom-stack
spec:
  namespaceSelector:
    matchNames: [scoring, scoring-staging]     # prod (Lab 5) et staging (Lab 6)
  selector:
    matchLabels:
      serving.kserve.io/inferenceservice: scoring-model
  podMetricsEndpoints:
    - portNumber: 8000       # port du conteneur kserve-container (Knative le nomme user-port)
      path: /metrics
      interval: 15s
      relabelings:
        # Labels ajoutés à toutes les séries : quelle révision (canary !) et quel ISVC
        - sourceLabels: [__meta_kubernetes_pod_label_serving_knative_dev_revision]
          targetLabel: revision
        - sourceLabels: [__meta_kubernetes_pod_label_serving_kserve_io_inferenceservice]
          targetLabel: isvc
```

```bash
kubectl apply -f monitoring/scoring-podmonitor.yaml
kubectl get podmonitor -n monitoring
```

### 4.2 Vérifier la cible

Dans Prometheus (`http://localhost:9090`), menu **Status > Target health** : une cible
`podMonitor/monitoring/scoring-api/0` apparaît en moins d'une minute.

> **Sortie attendue :** `podMonitor/monitoring/scoring-api/0 (1/1 up)` : un pod de la
> révision de production (deux pendant un canary, aucun en staging tant que le service est à
> zéro pod).

Premières requêtes dans l'onglet **Query** :

```promql
up{namespace="scoring", isvc="scoring-model"}
ml_model_info{namespace="scoring"}
sum by (outcome) (ml_predictions_total{namespace="scoring"})
```

> **Sortie attendue :** `up` vaut `1`, avec les labels `revision`, `isvc`, `pod`,
> `namespace` ; `ml_model_info` montre la version servie et le seuil.

## Étape 5/10 — Construire le dashboard Grafana production (25 min)

### 5.1 Générer du trafic

`monitoring/traffic.py` (copié à l'étape 1.5) rejoue des lignes réelles de
`data/processed/test.csv`, tirées au hasard, à débit constant ; à l'étape 9, il saura
déformer les données pour simuler un drift. Le cœur de la boucle :

```python
while args.duration <= 0 or time.monotonic() - start < args.duration:
    tick = time.monotonic()
    batch = pool.iloc[rng.integers(0, len(pool), size=args.batch)]
    batch = apply_drift(cfg, batch, spec)
    try:
        r = client.post(url, json={"instances": to_instances(batch)})
        r.raise_for_status()
        preds = r.json()["predictions"]
        sent += len(preds)
        positives += sum(p["prediction"] for p in preds)
        scores += [p["probability"] for p in preds]
        if args.save:
            saved.append(batch)
    except (httpx.HTTPError, KeyError, ValueError) as e:
        errors += 1
        if errors <= 3:
            print(f"  erreur : {e}")
    if time.monotonic() - last_report >= 10:
        last_report = time.monotonic()
        print(
            f"  {time.monotonic() - start:5.0f} s · {sent} demandes · {errors} erreurs"
            f" · « {cfg.positive_class} » {positives / max(sent, 1):.1%}"
        )
    time.sleep(max(0.0, period - (time.monotonic() - tick)))
```

Dans un **terminal dédié**, laissez tourner du trafic normal (20 requêtes/s, sans limite de
durée) jusqu'à l'étape 9 :

```bash
cd ~/mlops-cours-2026
ISVC_HOST=$(kubectl get isvc scoring-model -n scoring -o jsonpath='{.status.url}' | cut -d/ -f3)
uv run python monitoring/traffic.py --url http://localhost:30080 --host-header "$ISVC_HOST" \
    --duration 0
```

> **Sortie attendue :** un point d'étape toutes les 10 secondes, par exemple
> `50 s · 999 demandes · 0 erreurs · « bad » 63.9%`. Le taux de décisions `bad` (refus) se
> stabilise autour de 63 %, celui du jeu de test.

### 5.2 Trois panneaux à la main

Dans Grafana (`http://localhost:3000`) : **Dashboards > New > New dashboard > Add
visualization**, source **Prometheus**. Construisez ces trois panneaux pour comprendre les
requêtes (vous les retrouverez dans le dashboard versionné) :

1. **RPS** (Stat puis Time series) :

```promql
sum(rate(http_requests_total{namespace="scoring", isvc="scoring-model", handler="/predict"}[1m]))
```

2. **Latence P95** (Time series, unité `milliseconds (ms)`) :

```promql
histogram_quantile(0.95,
  sum by (le) (rate(ml_inference_latency_seconds_bucket{namespace="scoring"}[5m]))) * 1000
```

3. **Décisions par outcome** (Time series, *Stack series : Normal*) :

```promql
sum by (outcome) (rate(ml_predictions_total{namespace="scoring"}[1m]))
```

> [!TIP]
> **`rate()` et la fenêtre**
> Prometheus scrape l'API toutes les 15 s : une fenêtre `[1m]` contient 4 points, le minimum
> raisonnable pour `rate()`. Pour des quantiles (`histogram_quantile`), prenez `[5m]` : sur
> une fenêtre courte, quelques requêtes lentes suffisent à faire sauter le P95.

### 5.3 Le dashboard versionné dans Git

Un dashboard construit à la souris disparaît avec le pod Grafana (pas de persistance) et ne se
relit pas en revue de code. On versionne donc son JSON dans `monitoring/dashboards/` et on le
charge par une ConfigMap : le *sidecar* de Grafana surveille les ConfigMaps labellisées
`grafana_dashboard: "1"` et charge leur contenu.

```yaml
# Fichier : monitoring/dashboards/kustomization.yaml
# Les dashboards versionnés dans Git deviennent une ConfigMap labellisée
# grafana_dashboard: "1" : le sidecar de Grafana la détecte et charge les JSON.
#   kubectl apply -k monitoring/dashboards
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: monitoring
configMapGenerator:
  - name: scoring-dashboards
    files:
      - scoring-overview.json
    options:
      disableNameSuffixHash: true      # nom stable : une seule ConfigMap, mise à jour en place
      labels:
        grafana_dashboard: "1"
```

```bash
kubectl apply -k monitoring/dashboards
kubectl get configmap -n monitoring -l grafana_dashboard=1 | grep scoring
```

> **Sortie attendue :** `scoring-dashboards`, puis, dans Grafana, **Dashboards >
> scoring-overview** (chargé en moins d'une minute).

Le dashboard `scoring-overview` (fourni : `monitoring/dashboards/scoring-overview.json`)
regroupe 18 panneaux en cinq rangées, avec deux variables : le namespace (`scoring` ou
`scoring-staging`) et la révision.

| Rangée | Ce qu'elle montre | Panneaux |
|---|---|---|
| SLO — ce que ressent l'utilisateur | trafic, latence, disponibilité | RPS, RPS par révision, latence P95/P99, taux de succès (non-5xx) |
| Modèle — ce que dit le modèle | décisions et scores | décisions par outcome, taux de décisions positives par révision, distribution des scores (heatmap), score médian, taux de refus par groupe sensible, versions servies |
| Drift — Evidently | dernier calcul du job de drift (étape 6) | PSI par variable, variables en dérive, demandes analysées, âge du dernier run |
| Infra — la machinerie | saturation | CPU et mémoire par pod, pods scrapés par révision |
| Logs — Loki | journal de l'API (étape 7) | logs de `kserve-container` |

Pour modifier le dashboard : éditez-le dans Grafana, **Export > Export as JSON**, remplacez
le fichier, `kubectl apply -k monitoring/dashboards`, commit. Le JSON de Git reste la
référence (`allowUiUpdates: false` : Grafana refuse d'enregistrer par-dessus).

## Étape 6/10 — CronJob Evidently : drift dans Prometheus (30 min)

### 6.1 Le principe : la référence versionnée contre les demandes réelles

Le drift compare deux jeux de données :

- **la référence** : les données d'entraînement du modèle en production,
  `data/processed/train.csv`, **exactement** la version poussée par DVC sur le S3 du cours
  (Lab 1). DVC range chaque fichier sous son empreinte MD5 : l'adresse S3 change si les
  données changent, et `dvc.api.get_url` la donne sans rien télécharger ;
- **les données courantes** : les demandes réellement reçues par l'API, relues dans Loki
  (le journal JSON de l'étape 1). Pas de fichier `current.parquet` fabriqué à la main : ce
  sont les vraies entrées de production.

Evidently 0.7 calcule un score par variable. On choisit le **PSI** (*Population Stability
Index*), l'indicateur historique du risque de crédit, avec ses seuils usuels : < 0,1 stable,
0,1 à 0,25 à surveiller, > 0,25 dérive significative.

> [!WARNING]
> **Pourquoi pas les tests statistiques par défaut ?**
> Avec la configuration par défaut (Kolmogorov-Smirnov, khi-deux : des p-values), Evidently
> déclare en dérive 9 à 13 variables sur 20 pour du trafic **normal** rejoué depuis
> `test.csv` (mesuré pour 300 à 3 000 demandes). Avec des milliers de lignes, un test
> statistique détecte la moindre différence, même sans importance pratique. Le PSI mesure une
> **ampleur** : sur 20 tirages de trafic normal, son maximum ne dépasse pas 0,22 (montant du
> crédit, variable la plus instable), alors qu'un vrai changement de population le fait
> passer au-dessus de 1. Le seuil 0,25 et le minimum de 500 demandes (`MIN_ROWS`) viennent de
> ces mesures.

### 6.2 Le script de calcul

```python
# Fichier : monitoring/evidently-job/calc_drift.py
"""Job de drift : compare les demandes reçues par l'API aux données d'entraînement.

1. Référence : data/processed/train.csv VERSIONNÉ, lu dans le S3 du cours à l'adresse
   que DVC lui a donnée (REFERENCE_URI, voir l'étape 6), ou un fichier local.
2. Données courantes : les prédictions journalisées par l'API (une ligne JSON par demande),
   lues dans Loki sur les WINDOW_MINUTES dernières minutes (ou CURRENT_PATH, un CSV).
3. Evidently 0.7 (DataDriftPreset) calcule un score de drift par variable.
4. Les métriques sont poussées au Pushgateway (scrapé par Prometheus), le rapport HTML est
   déposé sur S3 et, au-delà d'un seuil, le webhook de ré-entraînement (Lab 6) est appelé.

Aucun nom de colonne ici : les variables viennent de dataset.yaml.
Configuration par variables d'environnement (valeurs par défaut = CronJob du cluster).
"""

import io
import json
import os
import sys
import time
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import urlparse

import boto3
import httpx
import pandas as pd
from evidently import DataDefinition, Dataset, Report
from evidently.presets import DataDriftPreset
from prometheus_client import CollectorRegistry, Gauge, push_to_gateway

ROOT = Path(__file__).resolve().parents[2]  # racine du repo (/app dans l'image)
sys.path.append(str(ROOT))
from src.dataset_config import load_config  # noqa: E402

env = os.environ.get
MODEL_NAME = env("MODEL_NAME", "scoring-model")
REFERENCE_URI = env("REFERENCE_URI", str(ROOT / "data" / "processed" / "train.csv"))
LOKI_URL = env("LOKI_URL", "http://loki.monitoring:3100")
LOKI_QUERY = env(
    "LOKI_QUERY", '{namespace="scoring", container="kserve-container"} |= `"event":"prediction"`'
)
CURRENT_PATH = env("CURRENT_PATH", "")  # si renseigné : CSV local au lieu de Loki
WINDOW_MINUTES = int(env("WINDOW_MINUTES", "60"))
MIN_ROWS = int(env("MIN_ROWS", "500"))  # en dessous, le test n'est pas fiable : on attend
MAX_ROWS = int(env("MAX_ROWS", "5000"))  # les demandes les plus récentes de la fenêtre
# PSI : l'indicateur historique du crédit (< 0,1 stable, 0,1-0,25 à surveiller, > 0,25 dérive)
DRIFT_METHOD = env("DRIFT_METHOD", "psi")
DRIFT_THRESHOLD = float(env("DRIFT_THRESHOLD", "0.25"))
PUSHGATEWAY_URL = env("PUSHGATEWAY_URL", "prometheus-pushgateway.monitoring:9091")
PUSH_JOB = env("PUSH_JOB", "scoring-drift")
REPORTS_URI = env("REPORTS_URI", "s3://monitoring/drift-reports")
CT_WEBHOOK_URL = env("CT_WEBHOOK_URL", "")  # ex. http://localhost:8095/drift (Lab 6)
CT_WEBHOOK_TOKEN = env("CT_WEBHOOK_TOKEN", "")
CT_DRIFT_SHARE = float(env("CT_DRIFT_SHARE", "0.1"))  # part de variables en dérive

cfg = load_config(env("DATASET_CONFIG", str(ROOT / "dataset.yaml")))


def s3_client():
    # Endpoint et identifiants lus dans l'environnement : AWS_ENDPOINT_URL,
    # AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY (Secret s3-credentials dans le cluster).
    return boto3.client("s3")


def read_table(uri: str) -> pd.DataFrame:
    """CSV ou Parquet, local ou s3://bucket/clé (DVC stocke sans extension : CSV)."""
    if uri.startswith("s3://"):
        u = urlparse(uri)
        body = s3_client().get_object(Bucket=u.netloc, Key=u.path.lstrip("/"))["Body"].read()
        data = io.BytesIO(body)
        return pd.read_parquet(data) if body[:4] == b"PAR1" else pd.read_csv(data)
    return pd.read_parquet(uri) if uri.endswith(".parquet") else pd.read_csv(uri)


def features_only(df: pd.DataFrame) -> pd.DataFrame:
    missing = [c for c in cfg.features if c not in df.columns]
    if missing:
        raise SystemExit(f"Colonnes de dataset.yaml absentes : {missing}")
    out = df[cfg.features].copy()
    out[cfg.numeric] = out[cfg.numeric].apply(pd.to_numeric, errors="coerce")
    out[cfg.categorical] = out[cfg.categorical].astype("string")
    return out


def fetch_from_loki() -> pd.DataFrame:
    """Demandes journalisées par l'API : les MAX_ROWS plus récentes de la fenêtre.

    Loki renvoie au plus 5 000 lignes par requête (max_entries_limit_per_query) : on
    lit de la plus récente à la plus ancienne, page par page, en reculant la borne de fin.
    """
    end_ns = time.time_ns()
    start_ns = end_ns - WINDOW_MINUTES * 60 * 10**9
    rows: list[dict] = []
    with httpx.Client(base_url=LOKI_URL, timeout=30.0) as client:
        while len(rows) < MAX_ROWS:
            r = client.get(
                "/loki/api/v1/query_range",
                params={
                    "query": LOKI_QUERY,
                    "start": start_ns,
                    "end": end_ns,
                    "limit": 5000,
                    "direction": "backward",
                },
            )
            r.raise_for_status()
            entries = [v for s in r.json()["data"]["result"] for v in s["values"]]
            if not entries:
                break
            for _, line in entries:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue  # ligne qui n'est pas du JSON (log d'accès...)
                if event.get("event") == "prediction":
                    rows.append(event["features"])
            end_ns = min(int(ts) for ts, _ in entries)  # page suivante : plus ancienne
            if len(entries) < 5000:
                break
    return pd.DataFrame(rows[:MAX_ROWS], columns=cfg.features)


def compute_drift(reference: pd.DataFrame, current: pd.DataFrame):
    """Score et verdict par variable (verdict = test Evidently, valable pour toute méthode)."""
    definition = DataDefinition(numerical_columns=cfg.numeric, categorical_columns=cfg.categorical)
    report = Report(
        [DataDriftPreset(method=DRIFT_METHOD, threshold=DRIFT_THRESHOLD)], include_tests=True
    )
    snapshot = report.run(
        Dataset.from_pandas(current, data_definition=definition),
        Dataset.from_pandas(reference, data_definition=definition),
    )
    result = snapshot.dict()
    scores = {
        m["config"]["column"]: float(m["value"])
        for m in result["metrics"]
        if m["config"]["type"].endswith(":ValueDrift")
    }
    drifted = {
        t["metric_config"]["params"]["column"]
        for t in result["tests"]
        if t["metric_config"]["params"]["type"].endswith(":ValueDrift") and t["status"] == "FAIL"
    }
    return scores, drifted, snapshot


def push_metrics(rows: int, scores: dict[str, float], drifted: set[str]) -> None:
    registry = CollectorRegistry()
    labels = {"model": MODEL_NAME}
    Gauge("ml_drift_current_rows", "Demandes analysées", ["model"], registry=registry).labels(
        **labels
    ).set(rows)
    if scores:
        score = Gauge(
            "ml_drift_score",
            f"Score de drift ({DRIFT_METHOD}) par variable",
            ["model", "feature"],
            registry=registry,
        )
        detected = Gauge(
            "ml_drift_detected",
            "1 si la variable dérive (seuil dépassé)",
            ["model", "feature"],
            registry=registry,
        )
        for feature, value in scores.items():
            score.labels(feature=feature, **labels).set(value)
            detected.labels(feature=feature, **labels).set(int(feature in drifted))
        Gauge(
            "ml_drift_share", "Part des variables en dérive", ["model"], registry=registry
        ).labels(**labels).set(len(drifted) / len(scores))
        Gauge("ml_drift_threshold", "Seuil de drift utilisé", ["model"], registry=registry).labels(
            **labels
        ).set(DRIFT_THRESHOLD)
    # PUT : remplace toutes les métriques du groupe (pas de reste d'une exécution précédente)
    push_to_gateway(PUSHGATEWAY_URL, job=PUSH_JOB, registry=registry)
    print(f"Métriques poussées vers {PUSHGATEWAY_URL} (job={PUSH_JOB})")


def save_report(snapshot, stamp: str) -> str | None:
    if not REPORTS_URI:
        return None
    name = f"drift-{stamp}.html"
    if REPORTS_URI.startswith("s3://"):
        u = urlparse(REPORTS_URI)
        s3 = s3_client()
        try:
            s3.head_bucket(Bucket=u.netloc)
        except s3.exceptions.ClientError:
            s3.create_bucket(Bucket=u.netloc)  # premier run : le bucket n'existe pas encore
        key = f"{u.path.strip('/')}/{name}".lstrip("/")
        s3.put_object(
            Bucket=u.netloc,
            Key=key,
            Body=snapshot.get_html_str(as_iframe=False),
            ContentType="text/html; charset=utf-8",
        )
        uri = f"s3://{u.netloc}/{key}"
    else:
        Path(REPORTS_URI).mkdir(parents=True, exist_ok=True)
        snapshot.save_html(str(Path(REPORTS_URI) / name))
        uri = str(Path(REPORTS_URI) / name)
    print(f"Rapport Evidently : {uri}")
    return uri


def trigger_ct(share: float, drifted: set[str], report_uri: str | None) -> None:
    """Appelle le webhook de ré-entraînement continu du Lab 6 (POST /drift)."""
    body = {
        "source": "evidently-drift",
        "model": MODEL_NAME,
        "dataset": cfg.name,
        "drift_share": round(share, 4),
        "drifted_features": sorted(drifted),
        "reference": REFERENCE_URI,
        "window_minutes": WINDOW_MINUTES,
        "timestamp": datetime.now(UTC).isoformat(timespec="seconds"),
        "report_uri": report_uri,
    }
    headers = {"Authorization": f"Bearer {CT_WEBHOOK_TOKEN}"} if CT_WEBHOOK_TOKEN else {}
    r = httpx.post(CT_WEBHOOK_URL, json=body, headers=headers, timeout=30.0)
    print(f"Webhook CT {CT_WEBHOOK_URL} -> HTTP {r.status_code} {r.text[:300]}")
    r.raise_for_status()


def main() -> int:
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    reference = features_only(read_table(REFERENCE_URI))
    if CURRENT_PATH:
        current = features_only(read_table(CURRENT_PATH)).tail(MAX_ROWS)  # les plus récentes
        source = CURRENT_PATH
    else:
        current = features_only(fetch_from_loki())
        source = f"Loki, {WINDOW_MINUTES} dernières minutes"
    print(f"Référence : {len(reference)} lignes ({REFERENCE_URI})")
    print(f"Courant   : {len(current)} demandes ({source})")

    if len(current) < MIN_ROWS:
        print(f"Moins de {MIN_ROWS} demandes : drift non calculé (relancez avec plus de trafic).")
        if PUSHGATEWAY_URL:
            push_metrics(len(current), {}, set())
        return 0

    scores, drifted, snapshot = compute_drift(reference, current)
    share = len(drifted) / len(scores)
    print(f"\n{'variable':28s} {DRIFT_METHOD:>8s}  dérive (seuil {DRIFT_THRESHOLD:g})")
    for feature, value in sorted(scores.items(), key=lambda kv: -kv[1]):
        print(f"{feature:28s} {value:8.3f}  {'OUI' if feature in drifted else '-'}")
    print(f"\n{len(drifted)}/{len(scores)} variables en dérive (part {share:.2f})")

    if PUSHGATEWAY_URL:
        push_metrics(len(current), scores, drifted)
    report_uri = save_report(snapshot, stamp)
    if CT_WEBHOOK_URL and share >= CT_DRIFT_SHARE:
        trigger_ct(share, drifted, report_uri)
    elif CT_WEBHOOK_URL:
        print(f"Part {share:.2f} < {CT_DRIFT_SHARE} : pas de ré-entraînement demandé.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

Points à remarquer :

- **Aucun nom de colonne** : la liste des variables vient de `dataset.yaml`.
- **Loki par pages** : Loki renvoie au plus 5 000 lignes par requête ; on lit de la plus
  récente à la plus ancienne et on garde les `MAX_ROWS` (5 000) demandes les plus récentes de
  la dernière heure.
- **Le verdict par variable vient des tests d'Evidently** (statut `FAIL`), pas d'une
  comparaison écrite à la main : il reste juste si l'on change de méthode (`DRIFT_METHOD`),
  qu'un grand score signifie une dérive (PSI) ou au contraire une stabilité (p-value).
- **Le Pushgateway** : un CronJob vit quelques secondes, Prometheus ne peut pas le scraper.
  Le job **pousse** ses métriques au Pushgateway (`PUT` : elles remplacent celles du run
  précédent), que Prometheus scrape. Le Pushgateway ajoute `push_time_seconds` : l'heure du
  dernier passage, que l'on surveillera.
- **Le rapport HTML** d'Evidently est déposé sur le S3 du cours (`s3://monitoring/…`) : c'est
  lui que l'on ouvre pour comprendre une alerte.
- **Le webhook de ré-entraînement** n'est appelé que si `CT_WEBHOOK_URL` est défini (étape 9).

### 6.3 L'image du job

Même logique que l'image de l'API (Lab 4) : contexte de build = racine du repo, dépendances
épinglées, utilisateur non-root, liste blanche du contexte.

```text
# Fichier : monitoring/evidently-job/requirements.txt
# Dépendances de l'image du job de drift UNIQUEMENT. Versions alignées sur uv.lock.
evidently==0.7.23
pandas==2.3.3
numpy==2.5.3
boto3==1.43.106
httpx==0.28.1
prometheus-client==0.24.1
pyyaml==6.0.3
```

```dockerfile
# Fichier : monitoring/evidently-job/Dockerfile
# Image du job de drift (CronJob). Contexte de build = RACINE du repo, comme l'API :
#   docker build -f monitoring/evidently-job/Dockerfile -t localhost:5001/scoring-drift:1.0.0 .
# Elle embarque dataset.yaml et src/dataset_config.py : la liste des variables vient du contrat.

FROM python:3.12-slim AS builder
WORKDIR /build
COPY monitoring/evidently-job/requirements.txt .
RUN pip install --no-cache-dir --target=/deps -r requirements.txt

FROM python:3.12-slim AS runtime
RUN groupadd --gid 10001 ml \
    && useradd --uid 10001 --gid ml --no-create-home --shell /usr/sbin/nologin ml
WORKDIR /app
COPY --from=builder /deps /deps
# DO_NOT_TRACK : désactive la télémétrie d'Evidently ; HOME : caches dans /tmp (non-root)
ENV PYTHONPATH=/deps \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    DO_NOT_TRACK=1 \
    HOME=/tmp
COPY dataset.yaml ./
COPY src/__init__.py src/dataset_config.py src/
COPY monitoring/evidently-job/calc_drift.py monitoring/evidently-job/
USER 10001:10001
CMD ["python", "monitoring/evidently-job/calc_drift.py"]
```

```text
# Fichier : monitoring/evidently-job/Dockerfile.dockerignore
# Liste blanche du contexte de build (BuildKit lit <Dockerfile>.dockerignore) : seuls les
# fichiers copiés par l'image partent au démon Docker, jamais .env ni data/.
*
!dataset.yaml
!src/__init__.py
!src/dataset_config.py
!monitoring/evidently-job/requirements.txt
!monitoring/evidently-job/calc_drift.py
```

```bash
docker build -f monitoring/evidently-job/Dockerfile -t localhost:5001/scoring-drift:1.0.0 .
docker push localhost:5001/scoring-drift:1.0.0
curl -s http://localhost:5001/v2/scoring-drift/tags/list
```

> **Sortie attendue :** `{"name":"scoring-drift","tags":["1.0.0"]}`. L'image est lourde
> (≈ 850 Mo : Evidently embarque SciPy, statsmodels, Plotly…) : construisez-la pendant la
> lecture de la suite.

> [!NOTE]
> **Télémétrie**
> Evidently peut envoyer des statistiques d'usage anonymes. L'image pose `DO_NOT_TRACK=1`, la
> variable que la bibliothèque consulte pour les désactiver.

### 6.4 Configurer et déployer le CronJob

Le job a besoin, dans le namespace `monitoring`, des identifiants S3 (le Secret
`s3-credentials`, recréé depuis `.env` comme au Lab 5) et de l'adresse de la référence :

```bash
kubectl create secret generic s3-credentials -n monitoring \
    --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -

dvc push                                     # la référence doit être sur le S3
REFERENCE_URI=$(uv run python -c \
    "import dvc.api; print(dvc.api.get_url('data/processed/train.csv'))")
echo "$REFERENCE_URI"
kubectl create configmap scoring-drift-reference -n monitoring \
    --from-literal=REFERENCE_URI="$REFERENCE_URI" \
    --dry-run=client -o yaml | kubectl apply -f -
```

> **Sortie attendue :** `s3://dvc-store/scoring/files/md5/77/f6be6148e414198654bf8ff4e12d13`
> (l'empreinte dépend de vos données ; c'est celle de `dvc.lock`).

```yaml
# Fichier : monitoring/evidently-cronjob.yaml
# Job de drift toutes les 15 minutes (en production : toutes les heures ou chaque jour).
# Pré-requis dans le namespace monitoring (étape 6) :
#   - Secret s3-credentials (identifiants du S3 du cours, recréé depuis .env) ;
#   - ConfigMap scoring-drift-reference (REFERENCE_URI : train.csv versionné par DVC).
apiVersion: batch/v1
kind: CronJob
metadata:
  name: scoring-drift
  namespace: monitoring
spec:
  schedule: "*/15 * * * *"
  concurrencyPolicy: Forbid          # jamais deux analyses en même temps
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 600
      template:
        metadata:
          labels:
            app: scoring-drift
        spec:
          restartPolicy: Never
          securityContext:
            runAsNonRoot: true
            runAsUser: 10001
            seccompProfile: {type: RuntimeDefault}
          containers:
            - name: drift
              image: localhost:5001/scoring-drift:1.0.0
              imagePullPolicy: IfNotPresent
              envFrom:
                - configMapRef:
                    name: scoring-drift-reference   # REFERENCE_URI
              env:
                - name: AWS_ENDPOINT_URL
                  value: http://s3.storage:8333
                - name: AWS_DEFAULT_REGION
                  value: us-east-1
                # S3 compatible (SeaweedFS) : pas de sommes de contrôle CRC32 imposées par boto3
                - name: AWS_REQUEST_CHECKSUM_CALCULATION
                  value: when_required
                - name: AWS_ACCESS_KEY_ID
                  valueFrom:
                    secretKeyRef: {name: s3-credentials, key: AWS_ACCESS_KEY_ID}
                - name: AWS_SECRET_ACCESS_KEY
                  valueFrom:
                    secretKeyRef: {name: s3-credentials, key: AWS_SECRET_ACCESS_KEY}
                - name: LOKI_URL
                  value: http://loki.monitoring:3100
                - name: PUSHGATEWAY_URL
                  value: prometheus-pushgateway.monitoring:9091
                - name: REPORTS_URI
                  value: s3://monitoring/drift-reports
                - name: WINDOW_MINUTES
                  value: "60"
                - name: MIN_ROWS
                  value: "500"
                - name: MAX_ROWS
                  value: "5000"
                - name: DRIFT_THRESHOLD
                  value: "0.25"
              resources:
                requests: {cpu: 200m, memory: 384Mi}
                limits: {cpu: "1", memory: 1Gi}
              securityContext:
                allowPrivilegeEscalation: false
                capabilities: {drop: [ALL]}
```

```bash
kubectl apply -f monitoring/evidently-cronjob.yaml
kubectl create job --from=cronjob/scoring-drift manual-run-1 -n monitoring
kubectl logs -n monitoring job/manual-run-1 -f
```

> **Sortie attendue** (trafic normal depuis l'étape 5 ; chiffres indicatifs, ils dépendent
> du tirage) :

```text
Référence : 800 lignes (s3://dvc-store/scoring/files/md5/77/f6be6148e414198654bf8ff4e12d13)
Courant   : 5000 demandes (Loki, 60 dernières minutes)

variable                          psi  dérive (seuil 0.25)
credit_amount                   0.141  -
purpose                         0.069  -
age                             0.064  -
employment                      0.055  -
duration                        0.054  -
...
housing                         0.001  -

0/20 variables en dérive (part 0.00)
Métriques poussées vers prometheus-pushgateway.monitoring:9091 (job=scoring-drift)
Rapport Evidently : s3://monitoring/drift-reports/drift-20261005T221204Z.html
```

### 6.5 Vérifier dans Prometheus et sur S3

```promql
ml_drift_score{model="scoring-model"}
time() - push_time_seconds{job="scoring-drift"}
```

> **Sortie attendue :** une série `ml_drift_score` par variable de `dataset.yaml` (20), avec
> les labels `feature` et `model` ; l'âge du dernier passage en secondes.

```bash
aws-lab s3 ls s3://monitoring/drift-reports/
```

Ouvrez le dernier rapport dans un navigateur : histogrammes référence / courant de chaque
variable. Soit par le filer de SeaweedFS (`http://localhost:8888/buckets/monitoring/drift-reports/`,
`make pf`), soit en le copiant sur le poste (`aws-lab` tourne dans un conteneur : on passe par
la sortie standard) :

```bash
aws-lab s3 cp s3://monitoring/drift-reports/<fichier>.html - > /tmp/drift.html
```

## Étape 7/10 — Loki + Alloy pour les logs (15 min)

### 7.1 Ce que `make monitoring` a installé

Loki tourne en mode monolithique (un pod `loki-0`, stockage éphémère : les logs disparaissent
au redémarrage du pod, comme dans l'ancienne version avec `persistence.enabled=false`). Les
journaux de prédictions étant des données personnelles, Loki les supprime après 72 h :

```yaml
# Les prédictions journalisées sont des données personnelles : 72 h de rétention.
limits_config:
  retention_period: 72h
compactor:
  retention_enabled: true
  delete_request_store: filesystem
```

Alloy lit les logs de **tous les pods** par l'API Kubernetes (un seul pod, pas de DaemonSet)
et les envoie à Loki avec des labels lisibles. Sa configuration est écrite dans le langage
d'Alloy :

```text
// Labels Loki lisibles : namespace, pod, container (+ révision Knative si présente)
discovery.relabel "pods" {
  targets = discovery.kubernetes.pods.targets
  rule {
    source_labels = ["__meta_kubernetes_namespace"]
    target_label  = "namespace"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_name"]
    target_label  = "pod"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_container_name"]
    target_label  = "container"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_label_serving_knative_dev_revision"]
    target_label  = "revision"
  }
}

// Lecture des logs via l'API Kubernetes
loki.source.kubernetes "pods" {
  targets    = discovery.relabel.pods.output
  forward_to = [loki.write.default.receiver]
}
```

### 7.2 La source Loki dans Grafana

La source de données Loki est déclarée par `values-monitoring.yaml` (`additionalDataSources`) :
**Connections > Data sources > Loki** existe déjà ; **Save & test**.

> **Sortie attendue :** `Data source successfully connected.`

Dans **Explore**, source Loki, essayez ces requêtes LogQL :

```text
{namespace="scoring", container="kserve-container"}
{namespace="scoring", container="kserve-container"} |= `"event":"prediction"` | json | prediction = "1"
sum by (revision) (count_over_time({namespace="scoring", container="kserve-container"} |= `"event":"prediction"` [1m]))
```

La deuxième ne garde que les refus (le filtre `|=` puis le parseur `json`) ; la troisième
compte les prédictions par révision, comme une métrique : utile quand on n'a pas instrumenté
l'API.

### 7.3 Panneau de logs dans le dashboard

Le dashboard `scoring-overview` contient déjà la rangée **Logs — Loki** (visualisation *Logs*,
requête `{namespace="$namespace", container="kserve-container"}`, *Time* et *Unique labels*
affichés).

> **Sortie attendue :** un panneau qui affiche en continu les prédictions JSON et les logs
> d'accès d'uvicorn ; cliquez sur une ligne pour voir ses labels (`pod`, `revision`).

## Étape 8/10 — Alertmanager : alertes SLO + webhook Slack (20 min)

### 8.1 Les règles d'alerte

```yaml
# Fichier : monitoring/scoring-alerts.yaml
# Règles Prometheus du service de scoring : règles d'enregistrement (agrégats réutilisés
# par les alertes et le dashboard) puis alertes. Chaque alerte : sévérité, équipe, runbook.
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: scoring-alerts
  namespace: monitoring
  labels:
    release: kube-prom-stack
spec:
  groups:
    - name: scoring.rules
      interval: 30s
      rules:
        - record: scoring:predict_requests:rate5m
          expr: |
            sum by (namespace) (rate(http_requests_total{isvc="scoring-model",handler="/predict"}[5m]))
        # Part des requêtes /predict en erreur 5xx, sur 4 fenêtres (alerte « burn rate »).
        # Tant qu'aucune 5xx n'a eu lieu, la série n'existe pas : pas de données = pas d'alerte.
        - record: scoring:predict_errors:ratio_rate5m
          expr: |
            sum by (namespace) (rate(http_requests_total{isvc="scoring-model",handler="/predict",code=~"5.."}[5m]))
            / sum by (namespace) (rate(http_requests_total{isvc="scoring-model",handler="/predict"}[5m]))
        - record: scoring:predict_errors:ratio_rate30m
          expr: |
            sum by (namespace) (rate(http_requests_total{isvc="scoring-model",handler="/predict",code=~"5.."}[30m]))
            / sum by (namespace) (rate(http_requests_total{isvc="scoring-model",handler="/predict"}[30m]))
        - record: scoring:predict_errors:ratio_rate1h
          expr: |
            sum by (namespace) (rate(http_requests_total{isvc="scoring-model",handler="/predict",code=~"5.."}[1h]))
            / sum by (namespace) (rate(http_requests_total{isvc="scoring-model",handler="/predict"}[1h]))
        - record: scoring:predict_errors:ratio_rate6h
          expr: |
            sum by (namespace) (rate(http_requests_total{isvc="scoring-model",handler="/predict",code=~"5.."}[6h]))
            / sum by (namespace) (rate(http_requests_total{isvc="scoring-model",handler="/predict"}[6h]))
        - record: scoring:latency_p95:5m
          expr: |
            histogram_quantile(0.95,
              sum by (namespace, le) (rate(ml_inference_latency_seconds_bucket{isvc="scoring-model"}[5m])))
        # Taux de décisions positives (classe positive de dataset.yaml : ici, refus du crédit)
        - record: scoring:positive_rate:ratio_rate5m
          expr: |
            sum by (namespace) (rate(ml_predictions_total{isvc="scoring-model",outcome="1"}[5m]))
            / sum by (namespace) (rate(ml_predictions_total{isvc="scoring-model"}[5m]))
        - record: scoring:positive_rate:ratio_rate6h
          expr: |
            sum by (namespace) (rate(ml_predictions_total{isvc="scoring-model",outcome="1"}[6h]))
            / sum by (namespace) (rate(ml_predictions_total{isvc="scoring-model"}[6h]))

    - name: scoring.alerts
      interval: 30s
      rules:
        - alert: ScoringHighLatency
          expr: scoring:latency_p95:5m{namespace="scoring"} > 0.2
          for: 5m
          labels: {severity: warning, team: ml-platform}
          annotations:
            summary: "Scoring : latence P95 > 200 ms"
            description: "P95 actuelle : {{ $value | humanizeDuration }} (SLO : 95 % < 200 ms)."
            runbook: "monitoring/runbooks.md#scoringhighlatency"

        # SLO de disponibilité : 99,5 % des requêtes /predict sans 5xx (budget : 0,5 %).
        # Burn rate multi-fenêtres : budget brûlé 14,4x trop vite sur 1 h (et encore sur
        # les 5 dernières minutes), ou 6x trop vite sur 6 h (et sur 30 min).
        - alert: ScoringErrorBudgetBurn
          expr: |
            (scoring:predict_errors:ratio_rate1h{namespace="scoring"} > (14.4 * 0.005)
              and scoring:predict_errors:ratio_rate5m{namespace="scoring"} > (14.4 * 0.005))
            or
            (scoring:predict_errors:ratio_rate6h{namespace="scoring"} > (6 * 0.005)
              and scoring:predict_errors:ratio_rate30m{namespace="scoring"} > (6 * 0.005))
          for: 2m
          labels: {severity: critical, team: ml-platform}
          annotations:
            summary: "Scoring : le budget d'erreur du SLO 99,5 % brûle trop vite"
            description: "{{ $value | humanizePercentage }} de requêtes /predict en erreur 5xx."
            runbook: "monitoring/runbooks.md#scoringerrorbudgetburn"

        # Valeur de l'alerte = part des variables en dérive (lue par le webhook CT du Lab 6)
        - alert: ScoringDataDrift
          expr: |
            (ml_drift_detected{model="scoring-model"} == 1)
              * on (model) group_left () ml_drift_share{model="scoring-model"}
          for: 5m          # en production : 30 min ou plus (éviter les faux positifs)
          labels: {severity: warning, team: ml-platform, ct_trigger: "true"}
          annotations:
            summary: "Drift sur la variable {{ $labels.feature }}"
            description: >-
              La distribution de {{ $labels.feature }} s'écarte des données d'entraînement
              ({{ $value | humanizePercentage }} des variables en dérive). Ré-entraînement
              à évaluer.
            drift_share: "{{ $value }}"
            runbook: "monitoring/runbooks.md#scoringdatadrift"

        # Taux de refus anormal : 5 dernières minutes comparées aux 6 dernières heures
        - alert: ScoringPositiveRateShift
          expr: |
            abs(scoring:positive_rate:ratio_rate5m{namespace="scoring"}
                - scoring:positive_rate:ratio_rate6h{namespace="scoring"}) > 0.10
            and scoring:predict_requests:rate5m{namespace="scoring"} > 0.1
          for: 5m
          labels: {severity: warning, team: ml-platform}
          annotations:
            summary: "Scoring : taux de décisions positives anormal"
            description: "Écart de {{ $value | humanizePercentage }} avec les 6 dernières heures."
            runbook: "monitoring/runbooks.md#scoringpositiverateshift"

        - alert: ScoringNoReplicaAvailable
          expr: |
            (sum(kube_deployment_status_replicas_available{namespace="scoring",
                 deployment=~"scoring-model-predictor-.*"}) or vector(0)) < 1
          for: 2m
          labels: {severity: critical, team: ml-platform}
          annotations:
            summary: "Aucun pod de scoring-model disponible en production"
            description: "Aucune révision de l'InferenceService n'a de pod prêt."
            runbook: "monitoring/runbooks.md#scoringnoreplicaavailable"

        # Qui surveille le surveillant ? Le job de drift tourne toutes les 15 min.
        - alert: ScoringDriftJobStale
          expr: time() - max(push_time_seconds{job="scoring-drift"}) > 2700
          for: 5m
          labels: {severity: warning, team: ml-platform}
          annotations:
            summary: "Le job de drift n'a rien publié depuis 45 min"
            description: "Dernière publication il y a {{ $value | humanizeDuration }}."
            runbook: "monitoring/runbooks.md#scoringdriftjobstale"
```

```bash
kubectl apply -f monitoring/scoring-alerts.yaml
```

Le fichier contient deux groupes :

- **`scoring.rules`** : des *recording rules*, des requêtes calculées toutes les 30 s et
  enregistrées comme de nouvelles séries (`scoring:predict_errors:ratio_rate1h`…). Les alertes
  et les dashboards relisent ces agrégats au lieu de recalculer des `rate()` sur 6 h.
- **`scoring.alerts`** : six alertes, toutes avec une sévérité, l'équipe `ml-platform` et un
  runbook.

| Alerte | Condition | Sévérité |
|---|---|---|
| `ScoringHighLatency` | P95 de `/predict` > 200 ms pendant 5 min | warning |
| `ScoringErrorBudgetBurn` | budget d'erreur du SLO 99,5 % brûlé 14,4× trop vite (1 h et 5 min) ou 6× (6 h et 30 min) | critical |
| `ScoringDataDrift` | au moins une variable en dérive (PSI > 0,25) pendant 5 min | warning |
| `ScoringPositiveRateShift` | taux de refus des 5 dernières minutes à plus de 10 points de celui des 6 dernières heures | warning |
| `ScoringNoReplicaAvailable` | aucun pod prêt en production pendant 2 min | critical |
| `ScoringDriftJobStale` | job de drift sans publication depuis 45 min | warning |

> [!IMPORTANT]
> **Alerter sur le budget d'erreur, pas sur le taux brut**
> « Alerter si plus de 1 % d'erreurs » réveille l'astreinte pour un pic d'une minute. Le SLO
> dit : 99,5 % des requêtes réussies sur 30 jours, soit un budget de 0,5 % d'erreurs. Un
> *burn rate* de 14,4 consomme 2 % de ce budget mensuel en une heure : ça mérite une page. La
> double fenêtre (1 h **et** 5 min) évite de rester en alerte une heure après la fin de
> l'incident. Les taux de refus et de drift, eux, n'ont pas de SLO : on compare à une
> référence (6 h glissantes, données d'entraînement).

> [!NOTE]
> **Le taux de refus anormal compare à 6 heures, pas « à hier »**
> Les slides comparent à `offset 1d` : sur un cluster de TP âgé de quelques heures, il n'y a
> pas de veille. La fenêtre de 6 h en tient lieu, à condition d'avoir laissé tourner le trafic
> normal depuis l'étape 5.

Vérifiez dans Prometheus, menu **Alerts** : les six alertes apparaissent (vertes : `Inactive`).

> **Sortie attendue :** `scoring.alerts` avec 6 règles `Inactive`, et dans **Status > Rule
> health** les deux groupes en état `ok`.

### 8.2 Configurer le webhook Slack

> [!TIP]
> **Webhook de test**
> Pour le lab, utilisez **webhook.site** : copiez l'URL unique générée par le site, il
> affiche tout ce qu'il reçoit. Pour un vrai Slack : **api.slack.com/apps > Create New App >
> Incoming Webhooks**, puis copiez l'URL `https://hooks.slack.com/services/…`.

L'URL d'un webhook est un secret (quiconque la connaît peut écrire dans votre canal) : elle va
dans un Secret Kubernetes, pas dans Git.

```bash
kubectl create secret generic slack-webhook -n monitoring \
    --from-literal=url="https://webhook.site/VOTRE-UUID" \
    --dry-run=client -o yaml | kubectl apply -f -
```

Le routage est décrit par une ressource **AlertmanagerConfig** (Prometheus Operator) :
l'operator la fusionne dans la configuration d'Alertmanager. Fini le Secret
`alertmanager-…` réécrit à la main de l'ancienne version : Helm le régénérait à chaque
`helm upgrade`.

```yaml
# Fichier : monitoring/alertmanager-config.yaml
# Routage des alertes de l'équipe ml-platform vers Slack, par sévérité.
# L'URL du webhook Slack n'est PAS dans Git : elle est lue dans le Secret slack-webhook
# (clé url), créé à la main dans le namespace monitoring (étape 8.2).
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: scoring-slack
  namespace: monitoring
spec:
  route:
    receiver: slack-ml
    matchers:
      - name: team
        value: ml-platform
        matchType: "="
    groupBy: [alertname, severity]
    groupWait: 10s
    groupInterval: 5m
    repeatInterval: 1h
    routes:
      - receiver: slack-ml-critical
        matchers:
          - name: severity
            value: critical
            matchType: "="
  receivers:
    - name: slack-ml
      slackConfigs:
        - apiURL: {name: slack-webhook, key: url}
          channel: "#ml-alerts"
          sendResolved: true
          title: '[{{ .Status | toUpper }}] {{ .GroupLabels.alertname }}'
          text: |-
            {{ range .Alerts }}• {{ .Annotations.summary }}
            {{ .Annotations.description }} (runbook : {{ .Annotations.runbook }})
            {{ end }}
    - name: slack-ml-critical
      slackConfigs:
        - apiURL: {name: slack-webhook, key: url}
          channel: "#ml-alerts-critical"
          sendResolved: true
          title: 'CRITIQUE : {{ .GroupLabels.alertname }}'
          text: |-
            {{ range .Alerts }}• {{ .Annotations.summary }} (runbook : {{ .Annotations.runbook }})
            {{ end }}
```

```bash
kubectl apply -f monitoring/alertmanager-config.yaml
sleep 30
curl -s http://localhost:9093/api/v2/status | grep -o 'monitoring/scoring-slack/slack-ml[a-z-]*' | sort -u
```

> **Sortie attendue :** `monitoring/scoring-slack/slack-ml` et
> `monitoring/scoring-slack/slack-ml-critical` : l'operator a préfixé les receivers par le
> namespace et le nom de l'AlertmanagerConfig. Pas besoin de redémarrer Alertmanager : son
> *config-reloader* recharge la configuration.

### 8.3 Tester la chaîne sans attendre une vraie panne

Une alerte de test, envoyée directement à l'API d'Alertmanager :

```bash
curl -s -X POST http://localhost:9093/api/v2/alerts -H "Content-Type: application/json" -d '[{
  "labels": {"alertname": "ScoringTestSlack", "team": "ml-platform", "severity": "warning"},
  "annotations": {"summary": "Test de la route Slack", "description": "Envoyée à la main.",
                  "runbook": "monitoring/runbooks.md"}}]'
```

> **Sortie attendue :** après `groupWait` (10 s), webhook.site reçoit un POST JSON dont le
> champ `attachments[0].title` vaut `[FIRING] ScoringTestSlack`. L'alerte de test expire
> d'elle-même après 5 minutes (`resolve_timeout`), d'où un second message `[RESOLVED]`.

### 8.4 Un runbook par alerte

Chaque alerte pointe vers une section de `monitoring/runbooks.md` (copié à l'étape 1.5) :
signification, comment confirmer, que faire. Lisez celle de `ScoringDataDrift` avant
l'étape 9 : c'est elle que vous suivrez.

## Étape 9/10 — Démo : drift → alerte → ré-entraînement (15 min)

### 9.1 Injecter du drift

Scénario : une campagne publicitaire attire des demandeurs **plus jeunes** qui empruntent
**plus**. Dans le terminal du trafic, arrêtez le trafic normal (Ctrl-C) et lancez un trafic
dérivé : âges multipliés par 0,6, montants par 2,5.

```bash
uv run python monitoring/traffic.py --url http://localhost:30080 --host-header "$ISVC_HOST" \
    --mode drift --drift age=0.6 --drift credit_amount=2.5 --duration 1200
```

> **Sortie attendue :** `Trafic drift -> … · dérive : {'age': '0.6', 'credit_amount': '2.5'}`,
> puis un taux de refus qui monte vers 78-80 % (contre 63 %) : le modèle juge cette
> population plus risquée. Le panneau « taux de décisions positives » du dashboard le montre
> en 1 à 2 minutes ; l'alerte `ScoringPositiveRateShift` suivra.

### 9.2 Lancer l'analyse de drift

Laissez tourner au moins 5 minutes (≈ 6 000 demandes dérivées), puis relancez le job sans
attendre le prochain quart d'heure :

```bash
kubectl create job --from=cronjob/scoring-drift manual-run-2 -n monitoring
kubectl logs -n monitoring job/manual-run-2 -f
```

> **Sortie attendue :** les deux variables déformées dépassent largement le seuil, les
> autres restent stables :

```text
Courant   : 5000 demandes (Loki, 60 dernières minutes)

variable                          psi  dérive (seuil 0.25)
age                             4.192  OUI
credit_amount                   1.438  OUI
purpose                         0.078  -
...

2/20 variables en dérive (part 0.10)
```

Dans Prometheus, 15 secondes plus tard : `ml_drift_detected{feature="age"}` vaut `1`.

### 9.3 Observer l'alerte

- **Prometheus > Alerts** : `ScoringDataDrift` passe `Pending` (une alerte par variable :
  `age`, `credit_amount`), puis `Firing` après 5 minutes. `ScoringPositiveRateShift` suit le
  même chemin.
- **Alertmanager** (`http://localhost:9093`) : les alertes actives, groupées par `alertname`.
- **webhook.site** : la notification, avec le résumé, la description et le runbook.
- **Grafana** : rangée Drift (PSI en rouge), heatmap des scores décalée vers le haut, taux
  de refus des moins de 25 ans en hausse dans le panneau par groupe.

### 9.4 Déclencher le ré-entraînement (Lab 6)

Le webhook de ré-entraînement continu du Lab 6 tourne **sur votre poste**
(`localhost:8095`) : il a besoin de MLflow (`make pf`), de KFP (`make kfp-ui`, port 8080) et
de vos droits `git push`. Le CronJob du cluster ne peut donc pas l'appeler ; on
relance le **même** calcul depuis le poste, en lui donnant l'adresse du webhook. Dans un
deuxième terminal :

```bash
set -a && source .env && set +a
CT_AUTO_PROMOTE=0 uv run python -m pipelines.trigger_ct serve     # webhook du Lab 6
```

`CT_AUTO_PROMOTE=0` : au Lab 6, le webhook promouvait le nouveau modèle à 100 % après un
simple test de fumée. Il s'arrête désormais au canary à 10 % : la décision revient à l'analyse
par les métriques de l'étape 10.

Puis, dans le premier :

```bash
set -a && source .env && set +a                     # CT_WEBHOOK_TOKEN, AWS_* (make pf actif)
REFERENCE_URI=$(uv run python -c \
    "import dvc.api; print(dvc.api.get_url('data/processed/train.csv'))") \
LOKI_URL=http://localhost:3100 PUSHGATEWAY_URL="" REPORTS_URI="" \
CT_WEBHOOK_URL=http://localhost:8095/drift \
uv run python monitoring/evidently-job/calc_drift.py
```

> **Sortie attendue :** le même tableau qu'en 9.2, puis
> `Webhook CT http://localhost:8095/drift -> HTTP 202 {"status":"triggered","run_id":"…"}`. Le
> webhook a lancé le pipeline `ct-pipeline` dans KFP (`http://localhost:8080`) : à la fin du
> run, si la gate du Lab 6 promeut le nouveau modèle, il pousse un commit de canary à 10 % en
> production. C'est ce canary que l'on analysera à l'étape 10.

> [!NOTE]
> **Le vrai cycle, en production**
> Ici, un humain relance le calcul. En production, le service de ré-entraînement tourne dans
> le cluster et Alertmanager l'appelle directement (récepteur `webhookConfigs` : l'alerte
> `ScoringDataDrift` porte le label `ct_trigger="true"` et la part de variables en dérive dans
> l'annotation `drift_share`, que l'endpoint `/alertmanager` du Lab 6 sait lire). Une alerte
> mise en silence dans Alertmanager suspend alors aussi le ré-entraînement.

### 9.5 Rapport

Créez `reports/rapport-m7.md` à partir du squelette :

```bash
cp labs/m7-monitoring/starter/rapport-m7.md reports/rapport-m7.md
```

Six sections : architecture déployée (composants et flux) ; instrumentation et dashboard
(captures en charge normale et pendant le drift) ; alertes (nom, condition, sévérité,
runbook) ; démo drift avec horodatages (avant → pendant → après) ; analyse du canary
(étape 10) ; améliorations à prévoir (fenêtres de burn rate, ré-entraînement automatique,
labels réels retardés, dashboards par équipe).

## Étape 10/10 — Analyser un canary par les métriques : promouvoir ou annuler (15 min)

### 10.1 Le principe

Au Lab 5, la promotion du canary était décidée à l'œil ; au Lab 6, elle passe par Git. Il
reste à la **décider sur des faits**. Pendant un canary, deux révisions Knative servent le
trafic (`kubectl get isvc` : colonnes `PREV` et `LATEST`), et grâce au label `revision` du
PodMonitor, chaque métrique existe pour chacune. On compare donc la nouvelle version à la
stable, sur la même fenêtre, avec six garde-fous :

| Garde-fou | Règle | Pourquoi |
|---|---|---|
| observabilité | le canary est scrapé (`up == 1`) | une version muette ne peut pas être jugée |
| volume | ≥ 100 requêtes `/predict` de chaque côté | sinon, attendre (`WAIT`) |
| erreurs | 5xx du canary ≤ max(1 %, 2 × stable) | disponibilité |
| latence | P95 ≤ SLO (200 ms) et pas nettement plus lent que la stable | performance |
| scores | PSI des distributions de scores < 0,25 | le modèle se comporte comme prévu |
| décisions | taux de décisions positives à ±10 points de la stable | impact métier (refus) |

Décision : `ROLLBACK` si un garde-fou échoue, `WAIT` s'il manque des données, sinon palier
suivant (10 → 50 → 100 %). C'est ce que font Flagger ou les `AnalysisTemplate` d'Argo
Rollouts ; ici, en 350 lignes de Python lisibles, et appliqué par Git avec l'outil GitOps du
Lab 6. Le cœur du script (`monitoring/canary_analysis.py`, copié à l'étape 1.5) :

```python
def decide(checks: list[dict], percent: int | None, steps: list[int]) -> tuple[str, list[str]]:
    if any(c["status"] == "FAIL" for c in checks):
        return "ROLLBACK", ["rollback"]
    if any(c["status"] == "WAIT" for c in checks):
        return "WAIT", []
    nxt = next((s for s in steps if percent is None or s > percent), 100)
    return ("PROMOTE", ["promote"]) if nxt >= 100 else ("CONTINUE", ["canary", str(nxt)])
```

Les requêtes PromQL sont toutes du type « par révision » :

```promql
sum by (revision) (increase(ml_predictions_total{namespace="scoring",isvc="scoring-model",outcome="1"}[5m]))
histogram_quantile(0.95, sum by (revision, le) (rate(ml_inference_latency_seconds_bucket{namespace="scoring",isvc="scoring-model"}[5m])))
```

### 10.2 Analyser le canary du nouveau modèle

Si l'étape 9.4 a produit une nouvelle version, Argo CD l'a déployée en canary à 10 %. Sinon
(gate refusée, run trop long), déployez en canary la dernière image de staging :
`uv run python -m pipelines.gitops deploy --env prod --canary 10 --push`.

```bash
kubectl get isvc scoring-model -n scoring           # PREV 90, LATEST 10
```

Relancez du trafic **normal** (le canary doit être jugé sur les demandes habituelles), attendez
2 à 3 minutes, puis analysez :

```bash
uv run python monitoring/traffic.py --url http://localhost:30080 --host-header "$ISVC_HOST" \
    --duration 180
uv run python monitoring/canary_analysis.py
```

> **Sortie attendue** (même modèle et même seuil des deux côtés, chiffres indicatifs) :

```text
Stable : scoring-model-predictor-00004 · Canary : scoring-model-predictor-00005 (10 % du trafic) · fenêtre 5m
  [PASS] observabilité métriques du canary scrapées (up=1)
  [PASS] volume     stable 1161 / canary 339 requêtes /predict (minimum 100)
  [PASS] erreurs    5xx canary 0.00% (stable 0.00%, max 1.00%)
  [PASS] latence    P95 canary 4.8 ms (stable 4.8 ms, max 30 ms)
  [PASS] scores     PSI des scores canary/stable 0.057 (max 0.25)
  [PASS] décisions  taux de décision positive canary 60.8% vs stable 62.2% (écart -1.4%, max ±10%)
Décision : CONTINUE -> uv run python -m pipelines.gitops canary 50
Rapport : reports/m7/canary-analysis.md
```

Les scores et le taux de refus des deux révisions diffèrent un peu alors que le modèle est le
même : ce sont deux échantillons différents de demandes. Les seuils des garde-fous laissent
cette marge.

Appliquez la décision (commit + push, Argo CD synchronise en moins d'une minute), refaites
une analyse au palier de 50 %, puis promouvez :

```bash
uv run python monitoring/canary_analysis.py --apply --push       # -> canary 50
uv run python monitoring/traffic.py --url http://localhost:30080 --host-header "$ISVC_HOST" \
    --duration 120
uv run python monitoring/canary_analysis.py --apply --push       # -> promote (100 %)
git log --oneline -3
```

> **Sortie attendue :** deux commits `gitops(prod): …` (50 %, puis 100 %), et
> `kubectl get isvc scoring-model -n scoring` affiche `LATEST 100`.

> [!WARNING]
> **Un canary de 5 minutes n'est pas une preuve**
> Avec 10 % de 20 requêtes/s, le canary voit ≈ 120 demandes en une minute : assez pour
> attraper une version qui plante ou qui refuse tout le monde, pas pour mesurer un écart de
> 2 points de taux de refus. En production, on garde chaque palier des heures, sur le vrai
> trafic.

### 10.3 Un canary défectueux : la machine dit non

Simulez une erreur de release : quelqu'un déploie en production l'image du Lab 5, qui n'a pas
de métriques.

```bash
uv run python -m pipelines.gitops deploy --env prod --canary 10 \
    --image localhost:5001/scoring-api --tag 2.0.0 --push
kubectl get isvc scoring-model -n scoring -w       # Ctrl-C quand LATEST=10
uv run python monitoring/traffic.py --url http://localhost:30080 --host-header "$ISVC_HOST" \
    --duration 90
uv run python monitoring/canary_analysis.py --apply --push
```

> **Sortie attendue :** `[FAIL] observabilité canary non scrapé (up=0)`, les autres
> garde-fous en `WAIT`, puis `Décision : ROLLBACK` et un commit
> `gitops(prod): rollback 0% 2.0.0` : tout le trafic revient sur la révision stable, encore
> chaude.
> L'outil du Lab 6 ne restaure `@champion` que si le canary servait le modèle champion (une
> release de modèle) ; ici, l'ancienne image sert un ancien modèle : seul le trafic change.
> Code retour du script : `1` (utilisable tel quel dans une CI).

Git décrit maintenant fidèlement la production (image 2.0.0 à 0 %, la révision précédente sert
tout le trafic), mais ce n'est pas un état à laisser traîner : redéployez la bonne version, celle
de staging, directement à 100 % :

```bash
uv run python -m pipelines.gitops deploy --env prod --canary 100 --push
kubectl get isvc scoring-model -n scoring -w       # Ctrl-C quand LATEST=100
```

Le même mécanisme attrape une régression bien plus sournoise : une version qui sert
**les mêmes scores** mais un seuil erroné. Le garde-fou « scores » passe, « décisions »
échoue (`taux de décision positive canary 85.5% vs stable 62.2%`) : c'est le seuil, pas le
modèle. Vérifiez enfin l'état final et la trace écrite :

```bash
kubectl get isvc scoring-model -n scoring
cat reports/m7/canary-analysis.md
git switch -c lab/m7-observabilite            # vos fichiers non commités vous suivent
git add reports monitoring && git commit -m "docs(m7): stack d'observabilité, rapport et canary"
git push -u origin lab/m7-observabilite
gh pr create
```

Relecture, approbation, fusion (aucun fichier de la CI n'est touché : pas de nouvelle image),
puis `git switch main && git pull` : `make check-m7` se lance de là.

> [!NOTE]
> **Second membre du binôme (ou nouveau poste) : remettre votre cluster à niveau**
> L'API instrumentée vous parvient déjà par Git et Argo CD (Lab 6 à niveau). Reste la stack
> d'observabilité de **votre** cluster, et le job de drift dans votre registry :
>
> ```bash
> cd ~/mlops-cours-2026 && git switch main && git pull && uv sync
> source .venv/bin/activate && set -a && source .env && set +a
> make monitoring
> kubectl apply -f monitoring/scoring-podmonitor.yaml
> kubectl apply -k monitoring/dashboards
> docker build -f monitoring/evidently-job/Dockerfile -t localhost:5001/scoring-drift:1.0.0 .
> docker push localhost:5001/scoring-drift:1.0.0
> kubectl create secret generic s3-credentials -n monitoring \
>     --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
>     --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
>     --dry-run=client -o yaml | kubectl apply -f -
> REFERENCE_URI=$(uv run python -c \
>     "import dvc.api; print(dvc.api.get_url('data/processed/train.csv'))")
> kubectl create configmap scoring-drift-reference -n monitoring \
>     --from-literal=REFERENCE_URI="$REFERENCE_URI" \
>     --dry-run=client -o yaml | kubectl apply -f -
> kubectl apply -f monitoring/evidently-cronjob.yaml
> kubectl apply -f monitoring/scoring-alerts.yaml
> kubectl create secret generic slack-webhook -n monitoring \
>     --from-literal=url="https://webhook.site/VOTRE-UUID" \
>     --dry-run=client -o yaml | kubectl apply -f -
> kubectl apply -f monitoring/alertmanager-config.yaml
> ISVC_HOST=$(kubectl get isvc scoring-model -n scoring -o jsonpath='{.status.url}' | cut -d/ -f3)
> uv run python monitoring/traffic.py --url http://localhost:30080 --host-header "$ISVC_HOST" \
>     --duration 300
> kubectl create job --from=cronjob/scoring-drift rattrapage-1 -n monitoring
> make check-m7
> ```
>
> Les rapports de `reports/m7/` (analyse de canary comprise) sont ceux du binôme, commités :
> ne rejouez pas le canary, qui pousserait des commits sur la prod commune. Rien à commiter.

## Checklist de validation

| # | Élément | Test | Résultat attendu | OK |
|---|---|---|---|---|
| 1 | `/metrics` exposé | `curl localhost:8000/metrics` | lignes `ml_*` et `http_requests_total` | ☐ |
| 2 | Tests du Lab 7 | `uv run pytest tests/test_monitoring.py` | `13 passed` | ☐ |
| 3 | Image instrumentée en production | `curl -H "Host: $ISVC_HOST" localhost:30080/metrics` | `ml_model_info` | ☐ |
| 4 | Stack Running | `kubectl get pods -n monitoring` | tous `Running` | ☐ |
| 5 | Grafana accessible | `localhost:3000`, admin / admin | page Dashboards | ☐ |
| 6 | PodMonitor trouvé | `kubectl get podmonitor -n monitoring` | `scoring-api` listé | ☐ |
| 7 | Cible UP | Prometheus > Target health | `scoring-api` up | ☐ |
| 8 | Dashboard chargé | Grafana > Dashboards | `scoring-overview`, toutes les rangées avec données | ☐ |
| 9 | CronJob Evidently | `kubectl get cronjob -n monitoring` | `scoring-drift`, `*/15 * * * *`, dernier run réussi | ☐ |
| 10 | Drift dans Prometheus | `ml_drift_score{model="scoring-model"}` | une valeur par variable | ☐ |
| 11 | Loki installé | `kubectl get pods -n monitoring \| grep -E "loki\|alloy"` | Running | ☐ |
| 12 | Logs dans Grafana | rangée Logs du dashboard | prédictions JSON en continu | ☐ |
| 13 | Alertes configurées | Prometheus > Alerts | 6 alertes `scoring.alerts` | ☐ |
| 14 | Démo drift réussie | webhook.site + `trigger_ct` | notification reçue, run CT lancé | ☐ |
| 15 | Canary analysé | `reports/m7/canary-analysis.md` | décision appliquée par commit | ☐ |
| 16 | Rapport | `reports/rapport-m7.md` | 6 sections remplies | ☐ |

## Critères d'évaluation (noté sur 20)

| Critère | Description | Points |
|---|---|---|
| Instrumentation API | Endpoint `/metrics`, compteurs + 2 histogrammes, labels pertinents et bornés, groupes sensibles, tests | 4 |
| Stack Prometheus/Grafana | Stack installée, PodMonitor scrape chaque révision, dashboard versionné et complet | 4 |
| Evidently en continu | CronJob fonctionnel sur les vraies demandes, référence DVC, métriques dans Prometheus | 4 |
| Alertes SLO | Alertes pertinentes (burn rate, drift, taux de refus) avec runbook, routage par sévérité | 3 |
| Canary analysé | Garde-fous compris, décision appliquée par Git, rollback démontré | 2 |
| Rapport + démo | Captures, analyse, démo drift → alerte → ré-entraînement complète | 3 |
| **Total** | | **20** |

## Annexe — Troubleshooting

| Symptôme | Cause probable | Solution |
|---|---|---|
| Pods de kube-prom-stack `OOMKilled` | RAM insuffisante. | Réduire `retention` de Prometheus à 6h, mettre KFP en pause, augmenter la RAM de Docker à 12 Go. Ne pas recréer le cluster. |
| node-exporter en `CreateContainerError` : `not a shared or slave mount` | Docker Desktop : racine du nœud kind non partagée. | `prometheus-node-exporter.hostRootFsMount.enabled: false` (déjà dans `values-monitoring.yaml`), puis `make monitoring`. |
| `make monitoring` : `context deadline exceeded` | Images longues à tirer (première installation). | Relancer `make monitoring` (idempotent) ; `kubectl get pods -n monitoring -w`. |
| PodMonitor non pris en compte | `podMonitorSelectorNilUsesHelmValues` resté à `true` (label `release` exigé) ou mauvais namespace. | Vérifier `values-monitoring.yaml` puis `make monitoring` ; le PodMonitor vise `scoring` et `scoring-staging`. |
| Cible `scoring-api` absente | Aucun pod : service à zéro pod (staging) ou ISVC pas prêt. | `kubectl get pods -n scoring -l serving.kserve.io/inferenceservice=scoring-model`. |
| Cible `scoring-api` DOWN, `server returned HTTP status 404` | Révision non instrumentée (image d'avant le Lab 7). | Déployer l'image construite à l'étape 2 ; normal pendant un canary vers une ancienne image. |
| `/metrics` : 307, rien ne s'affiche | `app.mount("/metrics", make_asgi_app())` redirige vers `/metrics/`. | Utiliser la route `GET /metrics` de l'étape 1.3 (ou `curl -L`). |
| `Duplicated timeseries in CollectorRegistry` | Métriques créées dans le registre global et module `serve.py` importé deux fois (tests du Lab 6). | Registre propre au module (`registry=REGISTRY`, étape 1.3) et `generate_latest(REGISTRY)`. |
| Compteurs incohérents avec plusieurs workers uvicorn | Chaque processus a ses propres compteurs. | Un worker par pod (Knative ajoute des pods) ; sinon mode multiprocess de `prometheus-client`. |
| Grafana : *No data* | Fenêtre de `rate()` trop courte, ou pas de trafic. | Passer de `[1m]` à `[5m]` au démarrage ; relancer `monitoring/traffic.py`. |
| Dashboard absent de Grafana | ConfigMap sans le label `grafana_dashboard: "1"`, ou JSON invalide. | `kubectl get cm -n monitoring -l grafana_dashboard=1` ; logs du conteneur `grafana-sc-dashboard`. |
| Job de drift : `NoSuchKey` sur la référence | `train.csv` pas poussé sur le S3, ou empreinte de `dvc.lock` différente. | `dvc push`, puis recréer la ConfigMap `scoring-drift-reference` (étape 6.4). |
| Job de drift : `Moins de 500 demandes` | Pas assez de trafic dans la dernière heure, ou Loki vide. | Relancer le trafic (étape 5.1) ; requête LogQL de l'étape 7.2. |
| Job de drift : `CreateContainerConfigError` | Secret `s3-credentials` ou ConfigMap absent du namespace `monitoring`. | Étape 6.4 ; `kubectl describe pod -n monitoring -l app=scoring-drift`. |
| Evidently : `KeyError` dans le résultat | API d'Evidently 0.4 (`as_dict()`, `drift_by_columns`) avec Evidently 0.7. | Utiliser `snapshot.dict()` comme `calc_drift.py` et épingler `evidently==0.7.23`. |
| Pushgateway : `404` ou `connection refused` | URL incorrecte. | Nom complet : `prometheus-pushgateway.monitoring:9091`. |
| Loki : pods `Pending` | Volume persistant demandé sans classe de stockage adaptée. | `singleBinary.persistence.enabled: false` (déjà dans `values-loki.yaml`). |
| Loki : `max entries limit per query exceeded` | `limit` > 5 000 dans une requête. | Paginer comme `calc_drift.py`. |
| Alertmanager : `config reload failed` | Erreur dans l'AlertmanagerConfig (Secret introuvable, matcher invalide). | `kubectl logs -n monitoring deploy/kube-prom-stack-kube-prome-operator` ; vérifier le Secret `slack-webhook` (clé `url`). |
| Slack : `invalid_payload` | Format de message incorrect (template). | Simplifier le texte du template ; tester d'abord avec webhook.site. |
| Webhook CT : `401` | `CT_WEBHOOK_TOKEN` absent ou différent entre le serveur et l'appel. | `set -a && source .env && set +a` dans les deux terminaux. |
| `canary_analysis.py` : `WAIT` en boucle | Pas assez de trafic sur le canary (10 %). | Relancer `traffic.py` plus longtemps ou monter le palier ; vérifier `kubectl get isvc`. |
| `canary_analysis.py --apply` : code 2 | L'outil GitOps refuse un arbre de travail modifié dans `k8s/overlays/`, ou une branche `lab/*` (les opérations partent de `main`). | `git status` ; committer ou annuler ; `git switch main && git pull` ; relancer. |

## Pour aller plus loin

- **Traces** : OpenTelemetry pour suivre une requête de la passerelle au modèle ; Alloy sait
  recevoir de l'OTLP et l'envoyer à Tempo ou Jaeger (extension `tracing` du projet).
- **SLO générés** : Sloth ou Pyrra génèrent les recording rules et les alertes multi-fenêtres
  à partir d'une déclaration de SLO de quelques lignes.
- **Canary automatique** : Flagger ou les `AnalysisTemplate` d'Argo Rollouts exécutent le
  même type d'analyse en continu, dans le cluster ; KServe garde la répartition du trafic.
- **Drift des prédictions et performance** : surveiller la distribution des scores avec
  Evidently, puis joindre les labels réels quand ils arrivent (des mois plus tard) pour
  mesurer la performance (extension `drift-predictions` du projet).
- **Histogrammes natifs** (Prometheus 3) : des quantiles précis sans choisir les bornes à
  l'avance.
- **Grafana Alerting** : une alternative à Alertmanager, pratique pour alerter sur des requêtes
  Loki (taux d'erreurs dans les logs).

## Vérification automatique

Depuis la racine du repo, cluster actif :

```bash
make check-m7
```

Le script `labs/m7-monitoring/check.sh` vérifie, sans rien modifier et sans port-forward
(Prometheus, Alertmanager et Loki sont interrogés via le proxy de l'API Kubernetes) :

- les fichiers du lab dans `monitoring/` et `prometheus-client` dans
  `packaging/requirements.txt` ; les tests `tests/test_monitoring.py` ;
- la stack : Prometheus, Alertmanager, Grafana, operator, kube-state-metrics, Pushgateway,
  Loki et Alloy prêts ;
- le scraping : PodMonitor `scoring-api` présent, cible `scoring-model` en `up == 1` ;
- les métriques métier : décisions, scores, latence, requêtes `/predict`, `ml_model_info`, et
  une série par attribut sensible de `dataset.yaml` reçu par l'API ;
- le dashboard `scoring-overview` chargé par Grafana ; le groupe `scoring.alerts` chargé (au
  moins 4 alertes, santé `ok`) ; l'AlertmanagerConfig et le Secret `slack-webhook` chargés ;
- le drift : image `scoring-drift` dans le registry, CronJob `scoring-drift` avec une
  exécution réussie, une série `ml_drift_score` par variable de `dataset.yaml`, prédictions
  journalisées présentes dans Loki ;
- les livrables : `reports/m7/canary-analysis.{md,json}` (décision, garde-fous) et
  `reports/rapport-m7.md` (5 sections au moins, sans `TODO`).

Variables optionnelles : `NS`, `ISVC`, `MON_NS`, `REGISTRY`. Code retour = nombre de
vérifications en échec.

> [!NOTE]
> **Prochaine étape**
> Module 8 — Gouvernance, sécurité, fairness. Vous allez scanner votre image avec Trivy et
> votre modèle avec ModelScan, mesurer les disparités de décision par groupe sensible avec
> Fairlearn (celles que le dashboard suit déjà en production), expliquer les refus avec SHAP
> et produire une Model Card complète.
