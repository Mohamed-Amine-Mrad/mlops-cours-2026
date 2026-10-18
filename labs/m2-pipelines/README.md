---
module: 2
lab: 2
title: "Pipeline ML sur Kubeflow + Airflow"
subtitle: "Migrer le pipeline du Lab 1 vers un DAG production-ready"
running_title: "Lab 2 — Pipeline Kubeflow + Airflow"
duree: "3 heures (atelier guidé)"
stack: "KFP 2.17 · Airflow 3.3 · MLflow 3 · Docker · Kubernetes"
prerequis: "Lab 0 + Lab 1 réussis, cluster kind actif"
livrable: "2 pipelines fonctionnels + rapport comparatif"
---

# Lab 2 — Pipeline Kubeflow + variante Airflow

*Transformer le pipeline DVC du Lab 1 en un DAG Kubeflow Pipelines production-ready, puis en
écrire une variante Airflow. Comparer les deux en termes de developer experience, scaling et
debugging.*

## Objectifs

> [!NOTE]
> **À la fin de ce lab, vous aurez :**
>
> - Kubeflow Pipelines (KFP) installé et opérationnel sur le cluster kind du Lab 0.
> - Une **image « projet »** (`localhost:5001/scoring-pipeline`) qui embarque le code du
>   Lab 1 : les composants du pipeline le **réutilisent** au lieu de le recopier.
> - Un pipeline KFP complet, `scoring-pipeline` : ingest → validate → prepare → train →
>   evaluate → register.
> - Des artefacts typés (Dataset, Model, Metrics) passés entre composants via le stockage
>   S3 interne de KFP (SeaweedFS), et des métriques visibles dans l'UI.
> - Une intégration MLflow : chaque run KFP produit un run dans l'expérience `scoring`
>   (tag `launched_by=kfp`) et une nouvelle version de `scoring-model` (`@challenger`, et
>   `@champion` si elle passe le seuil de `dataset.yaml`).
> - Un pipeline Airflow équivalent, `scoring_dag`, qui utilise le KubernetesPodOperator
>   avec la même image.
> - Un rapport comparatif (1 page) : KFP vs Airflow sur ce cas d'usage.

## Architecture cible

```text
 Votre poste (~/mlops-cours-2026)          Cluster kind « mlops-lab »
 ┌─────────────────────────────┐          ┌──────────────────────────────────────────────┐
 │ src/ dataset.yaml (Lab 1)   │  docker  │ registry localhost:5001                      │
 │ pipelines/Dockerfile ───────┼─build───►│   scoring-pipeline:1.0.0  (image « projet ») │
 │                             │   push   │                                              │
 │ pipelines/components.py     │          │ ns kubeflow : KFP (API, UI, Argo, MySQL,     │
 │ pipelines/scoring_pipeline  │  upload  │   SeaweedFS interne, bucket mlpipeline)      │
 │   -> scoring_pipeline.yaml ─┼─────────►│   1 step = 1 pod (image scoring-pipeline)    │
 │                             │          │                                              │
 │ dags/scoring_dag.py         │   KPO    │ ns airflow : 1 task = 1 pod (même image)     │
 │ Airflow (Docker Compose) ───┼─────────►│                                              │
 │                             │          │ ns mlflow  : MLflow (runs + registry)        │
 │ kfp.local (tests locaux)    │          │ ns storage : SeaweedFS du cours (S3)         │
 └─────────────────────────────┘          └──────────────────────────────────────────────┘
```

## Plan du lab

| # | Étape | Durée |
|---|---|---|
| 1 | Installer Kubeflow Pipelines sur le cluster kind | 20 min |
| 2 | Convertir les scripts du Lab 1 en composants KFP (image « projet ») | 35 min |
| 3 | Écrire le pipeline orchestrant ces composants (et le tester en local) | 15 min |
| 4 | Uploader et exécuter le pipeline sur le cluster | 15 min |
| 5 | Intégrer MLflow : traçabilité et Model Registry | 20 min |
| 6 | Configurer retries, ressources et caching | 15 min |
| 7 | Installer Airflow (Docker Compose) et écrire le DAG équivalent | 25 min |
| 8 | Tester et comparer : DX, scaling, debugging | 20 min |
| 9 | Rédiger le rapport comparatif (1 page) | 15 min |

> [!WARNING]
> **Point de ressources**
> Kubeflow Pipelines est gourmand : comptez **6 Go de RAM minimum** pour le cluster kind
> pendant ce lab, plus environ 4 Go pour Airflow à l'étape 7. Si votre machine est juste,
> fermez VS Code, Chrome et tout ce qui traîne, et arrêtez Airflow dès que vous n'en avez plus
> besoin. Vérifiez avec `docker stats` une fois KFP installé : les pods `ml-pipeline-*`
> doivent être `Running`.

> [!IMPORTANT]
> **Préalable à ce lab**
> Avoir réussi le Lab 1 : `make check-m1` doit être entièrement vert (pipeline DVC, runs
> MLflow, versions 1 à 3 de `scoring-model`). On travaille dans votre fork,
> `~/mlops-cours-2026`, sur le cluster `mlops-lab` du Lab 0 : on ne le recrée **pas**.

Au début de chaque séance :

```bash
cd ~/mlops-cours-2026
kubectl get nodes          # 3 nœuds Ready
make pf                    # port-forwards S3 :8333 et MLflow :5000
source .venv/bin/activate  # venv du cours
set -a && source .env && set +a
```

Dans un **nouveau terminal** de la même séance, seules les deux dernières lignes sont
nécessaires (après `cd ~/mlops-cours-2026`) : les port-forwards tournent déjà en arrière-plan.

## Branche de travail

Comme chaque lab (convention du Lab 0, étape 8.1), celui-ci se fait sur sa propre branche,
créée depuis `main` à jour, et se termine par une pull request relue par le partenaire du
binôme :

```bash
cd ~/mlops-cours-2026
git switch main && git pull
git switch -c lab/m2-pipelines
```

## Convention de notation

Les blocs de code contiennent des commandes shell à exécuter telles quelles depuis la racine de
votre fork `~/mlops-cours-2026` : elles n'ont **pas** de préfixe `$`, vous pouvez les
copier-coller directement. Les lignes commençant par `#` sont des commentaires. Quand un bloc
commence par `# Fichier : chemin`, c'est le contenu **complet** du fichier à créer (ou à
remplacer). Les encadrés « Sortie attendue » montrent le résultat attendu, avec les chiffres
réels obtenus sur le dataset par défaut.

## Étape 1/9 — Installer Kubeflow Pipelines sur le cluster kind (20 min)

On utilise le manifest *standalone* (pas la stack Kubeflow complète avec Notebook, Katib,
KServe — trop lourde pour kind). Le standalone installe : l'API server, l'UI, Argo Workflows
(le moteur qui exécute les DAG), MySQL (métadonnées), ML Metadata et un **SeaweedFS interne**
qui stocke les artefacts des runs. Depuis KFP 2.15, SeaweedFS remplace MinIO comme stockage
par défaut : même API S3, licence Apache 2.0, alors que l'édition communautaire de MinIO a été
archivée et ses images retirées de Docker Hub en 2026.

> [!NOTE]
> **Deux stockages S3 dans le cluster : ne pas les confondre**
>
> | | SeaweedFS **du cours** (Lab 0) | SeaweedFS **interne de KFP** |
> |---|---|---|
> | Namespace, service | `storage`, `http://s3.storage:8333` | `kubeflow`, `http://seaweedfs.kubeflow:8333` |
> | Buckets | `mlflow-artifacts`, `dvc-store` (+ les vôtres) | `mlpipeline` |
> | Identifiants | secret `s3-credentials` (`mlops` / …) | secret `mlpipeline-minio-artifact` (`minio` / `minio123`) |
> | Qui s'en sert | MLflow (proxy), DVC, Airflow (étape 7) | KFP seul : artefacts passés entre composants |
>
> Vous n'avez jamais à manipuler le second : KFP y range et y relit lui-même les artefacts
> de chaque step. Le nom du secret et le préfixe `minio://` des URI d'artefacts sont des
> restes historiques de l'époque MinIO.

### 1.1 Appliquer les manifests KFP

```bash
source infra/versions.env          # KFP_VERSION=2.17.2
KFP_MANIFESTS="github.com/kubeflow/pipelines/manifests/kustomize"
kubectl apply -k "$KFP_MANIFESTS/cluster-scoped-resources?ref=$KFP_VERSION"
kubectl wait --for condition=established --timeout=120s \
    crd/applications.app.k8s.io crd/workflows.argoproj.io
kubectl apply -k "$KFP_MANIFESTS/env/platform-agnostic?ref=$KFP_VERSION"
```

> **Sortie attendue :** beaucoup de ressources créées : CRD (dont `workflows.argoproj.io`,
> fournie par Argo Workflows 4.0), deployments, services, RBAC… L'installation prend 5 à
> 10 min la première fois (le temps de tirer les images).

> [!TIP]
> **Une seule commande**
> `make kfp` exécute exactement ces commandes (script `infra/kfp/install.sh`, version lue dans
> `infra/versions.env`) puis attend que tous les déploiements soient disponibles.

### 1.2 Vérifier l'installation

```bash
kubectl -n kubeflow get pods -w
```

> **Sortie attendue :** au bout de quelques minutes, les 14 pods passent en `Running`. Les
> principaux : `ml-pipeline`, `ml-pipeline-ui`, `seaweedfs`, `mysql`, `workflow-controller`,
> `metadata-grpc-deployment`. Les autres : `cache-server`, `cache-deployer-deployment`,
> `metadata-envoy-deployment`, `metadata-writer`, `ml-pipeline-persistenceagent`,
> `ml-pipeline-scheduledworkflow`, `ml-pipeline-viewer-crd`, `ml-pipeline-visualizationserver`.
> Quelques `CrashLoopBackOff` au début sur `ml-pipeline` et `metadata-grpc-deployment` sont
> normaux (ils attendent MySQL). Ctrl-C quand tout est stable.

### 1.3 Accéder à l'UI KFP

La cible `make kfp-ui` lance le port-forward de l'UI en arrière-plan (journal dans
`/tmp/mlops-port-forward/kfp-ui.log`), comme `make pf` pour MLflow et S3 :

```bash
make kfp-ui
```

Puis ouvrez `http://localhost:8080` dans votre navigateur. Relancez `make kfp-ui` à chaque
séance, comme `make pf` (et après une mise en veille du poste).

> [!NOTE]
> **L'UI KFP**
> L'interface montre les **Pipelines** (définitions), les **Experiments** (groupements de
> runs), les **Runs** (exécutions) et les **Artifacts**. Familiarisez-vous avec la navigation :
> vous y reviendrez souvent pour débogger. Le même port-forward sert d'accès à l'API pour le
> SDK Python (`kfp.Client(host="http://localhost:8080")`).

### 1.4 Le SDK KFP

Le SDK est déjà dans l'environnement du cours (`uv sync` du Lab 0 : `kfp` et `kfp-kubernetes`
2.17.0). Vérifiez la version et l'accès à l'API :

```bash
python -c "import kfp; print(kfp.__version__)"
curl -s http://localhost:8080/apis/v2beta1/healthz
```

> **Sortie attendue :** `2.17.0`, puis un petit JSON contenant `"multi_user":false` (mode
> standalone, un seul utilisateur).

## Étape 2/9 — Convertir les scripts du Lab 1 en composants KFP (35 min)

Stratégie : chaque étape du pipeline DVC devient un composant KFP. On garde la même logique
métier, mais on l'enveloppe dans un décorateur `@dsl.component` qui expose les entrées/sorties
typées. Reste une question décisive : **où vit le code ?**

### 2.1 Recopier ou réutiliser ?

Un composant KFP « léger » est une fonction Python dont KFP envoie le **code source** dans un
conteneur (`base_image`). Le conteneur ne voit rien d'autre de votre repo. Deux façons de
s'en accommoder :

| | (a) Composants autonomes | (b) Image « projet » |
|---|---|---|
| Image de base | `python:3.12-slim` | `localhost:5001/scoring-pipeline:1.0.0` |
| Code métier | **recopié** dans chaque fonction | **importé** : `python -m src.train`, comme `dvc repro` |
| Dépendances | `packages_to_install`, installées à chaque démarrage de pod (30 à 60 s, accès à PyPI requis) | figées une fois pour toutes dans l'image |
| `dataset.yaml` | à recopier ou à passer en paramètre | dans l'image |
| Changer le code | recompiler le pipeline | reconstruire l'image avec un **nouveau tag** |
| Risque principal | deux versions du code qui divergent | oublier de changer le tag |

On choisit **(b)**. Le code du Lab 1 existe déjà, il est testé et piloté par
`dataset.yaml` : le recopier dans des composants créerait une deuxième version à maintenir
(un `prepare.py` pour DVC, un autre pour KFP), qui divergerait au premier changement. Avec une
image projet, DVC, KFP, Airflow et plus tard la CI (Lab 6) exécutent **le même code**, et
l'image versionnée (`:1.0.0`) devient l'unité de livraison, comme au Lab 4 pour l'API.

Chaque composant fait alors exactement ce que fait une stage de `dvc.yaml` : récupérer ses
entrées, lancer une commande, publier ses sorties. Seul le transport change :

```text
 dvc.yaml (Lab 1)                         composant KFP (Lab 2)
 stage prepare                            prepare_features(
   deps : data/raw/dataset.csv   ───►        raw_data:   Input[Dataset],
   cmd  : python -m src.prepare  ───►        run_stage("src.prepare", …)
   outs : data/processed/*.csv   ───►        train_data: Output[Dataset], test_data: …)
```

Quatre fichiers à écrire : un script de validation (2.2), le pont entre orchestrateur et code
(2.3), l'image (2.4), les composants (2.5).

### 2.2 Un nouveau script : la validation des données

Le pipeline du cours commence par un **gate** : si le fichier brut ne respecte pas le contrat
`dataset.yaml`, on s'arrête avant d'entraîner quoi que ce soit (fail-fast). Pour l'instant,
des contrôles de schéma simples ; le Lab 3 les remplacera par une suite Great Expectations,
sans changer la façon de lancer le script.

```python
# Fichier : src/validate_data.py
"""Valide un fichier de données brutes contre le contrat dataset.yaml.

Gate du pipeline (Lab 2) : si un contrôle échoue, le script sort avec le code 1 et
l'orchestrateur (DVC, Kubeflow, Airflow, CI) s'arrête AVANT l'entraînement. Les contrôles
sont des contrôles de schéma simples, tous déduits de dataset.yaml (aucun nom de colonne
en dur). Le Lab 3 les remplacera par une suite Great Expectations, sans changer
l'interface :

    python -m src.validate_data [fichier.csv]      (défaut : raw_path de dataset.yaml)

Sortie : un résumé JSON sur la sortie standard et dans reports/validation.json.
"""

import argparse
import json
import sys
from pathlib import Path

import pandas as pd

from src.dataset_config import DatasetConfig, load_config

REPORT_JSON = Path("reports/validation.json")


def run_checks(cfg: DatasetConfig, df: pd.DataFrame) -> dict[str, bool]:
    """Un booléen par contrôle (True = conforme au contrat)."""
    try:
        cfg.validate_columns(df)  # toutes les colonnes déclarées sont présentes
    except ValueError as exc:
        print(exc, file=sys.stderr)
        return {"colonnes_du_contrat": False}  # inutile d'aller plus loin
    target = df[cfg.target]
    classes = set(target.dropna().astype(str))
    return {
        "colonnes_du_contrat": True,
        "table_non_vide": len(df) > 0,
        "cible_sans_valeur_manquante": bool(target.notna().all()),
        "cible_avec_classe_positive_et_autre": str(cfg.positive_class) in classes
        and len(classes) >= 2,
        "numeriques_de_type_nombre": all(
            pd.api.types.is_numeric_dtype(df[col]) for col in cfg.numeric
        ),
        "aucune_variable_entierement_vide": not any(df[col].isna().all() for col in cfg.features),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("csv", nargs="?", help="fichier à valider (défaut : raw_path)")
    args = parser.parse_args()

    cfg = load_config()
    df = pd.read_csv(args.csv or cfg.raw_path)
    checks = run_checks(cfg, df)
    failed = [name for name, ok in checks.items() if not ok]
    has_target = cfg.target in df.columns and len(df) > 0
    summary = {
        "success": not failed,
        "n_checks": len(checks),
        "n_failed": len(failed),
        "failed": failed,
        "rows": len(df),
        "positive_rate": round(float(cfg.encode_target(df[cfg.target]).mean()), 4)
        if has_target
        else None,
    }
    REPORT_JSON.parent.mkdir(parents=True, exist_ok=True)
    REPORT_JSON.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", "utf-8")
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0 if summary["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
```

Testez sur les données du Lab 1, puis sur une copie corrompue (une colonne supprimée) :

```bash
python -m src.validate_data; echo "Code retour : $?"
python - <<'EOF'
import pandas as pd

from src.dataset_config import load_config

cfg = load_config()
df = pd.read_csv(cfg.raw_path)
df.drop(columns=cfg.numeric[:1]).to_csv("/tmp/dataset_bad.csv", index=False)
EOF
python -m src.validate_data /tmp/dataset_bad.csv; echo "Code retour : $?"
```

> **Sortie attendue :** pour les vraies données, `"success": true`, `"n_checks": 6`,
> `"n_failed": 0`, `"rows": 1000`, `"positive_rate": 0.3` et `Code retour : 0`. Pour la copie,
> `Colonnes déclarées dans dataset.yaml absentes des données : ['duration']`, puis
> `"success": false`, `"failed": ["colonnes_du_contrat"]` et `Code retour : 1`. C'est ce code
> retour non nul qui fera échouer le step du pipeline.

### 2.3 Le pont entre l'orchestrateur et le code : `pipelines/stage.py`

```bash
mkdir -p pipelines
touch pipelines/__init__.py
```

Ce module exécute une étape du projet comme le fait DVC : il prépare un dossier de travail
temporaire qui reproduit l'arborescence du repo (`params.yaml`, `data/`, `models/`,
`reports/`), y copie les entrées, lance `python -m src.<étape>`, puis récupère les sorties.
Le code du Lab 1, écrit avec des chemins relatifs, tourne ainsi **sans aucune modification**.
La seconde moitié du fichier (dossier de travail S3, XCom) ne servira qu'à Airflow, à
l'étape 7.

```python
# Fichier : pipelines/stage.py
"""Exécute une étape du projet (python -m src.<étape>) pour un orchestrateur.

Une étape = une stage de dvc.yaml : des entrées (deps), une commande, des sorties (outs).
Elle tourne dans un dossier de travail temporaire qui reproduit l'arborescence du projet
(params.yaml, data/, models/, reports/) : le code du Lab 1, écrit avec des chemins
relatifs, s'exécute SANS modification, que l'orchestrateur soit DVC, Kubeflow Pipelines
ou Airflow. Ce module est copié dans l'image du pipeline (pipelines/Dockerfile).

- Kubeflow (pipelines/components.py) : run_stage() avec les chemins des artefacts typés.
- Airflow (dags/scoring_dag.py) : python -m pipelines.stage src.<étape> --workspace s3://…
  recopie l'arborescence du run depuis/vers S3 ; --xcom publie les petites valeurs utiles
  aux tasks suivantes (run MLflow, métriques).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]  # racine du projet (/app dans l'image)
OUTPUT_DIRS = ("data", "models", "reports")  # là où les étapes écrivent leurs sorties
XCOM_FILE = Path("/airflow/xcom/return.json")  # lu par le KubernetesPodOperator


def copy(src: str | Path, dst: str | Path) -> None:
    """Copie un fichier ou un dossier, en créant les dossiers parents."""
    src, dst = Path(src), Path(dst)
    dst.parent.mkdir(parents=True, exist_ok=True)
    if src.is_dir():
        shutil.copytree(src, dst, dirs_exist_ok=True)
    else:
        shutil.copyfile(src, dst)


def execute(module: str, args, workdir: Path, env: dict | None = None) -> None:
    """Lance python -m <module> <args> dans workdir, avec le code et le contrat du projet."""
    shutil.copyfile(ROOT / "params.yaml", workdir / "params.yaml")
    run_env = {**os.environ, **(env or {})}
    run_env["PYTHONPATH"] = os.pathsep.join(filter(None, [str(ROOT), os.getenv("PYTHONPATH")]))
    config = Path(os.getenv("DATASET_CONFIG", ROOT / "dataset.yaml")).resolve()
    run_env["DATASET_CONFIG"] = str(config)
    cmd = [sys.executable, "-m", module, *map(str, args)]
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, cwd=workdir, env=run_env, check=True)


def run_stage(module: str, args=(), inputs=None, outputs=None, env=None) -> None:
    """Copie les entrées, lance l'étape, copie les sorties (composants KFP).

    inputs  : {chemin dans le projet : fichier ou dossier à y copier avant l'étape}
    outputs : {chemin dans le projet : destination où le recopier après l'étape}
    env     : variables d'environnement en plus (ex. LAUNCHED_BY=kfp)
    """
    with tempfile.TemporaryDirectory(prefix="stage-") as tmp:
        work = Path(tmp)
        for rel, src in (inputs or {}).items():
            copy(src, work / rel)
        execute(module, args, work, env)
        for rel, dst in (outputs or {}).items():
            copy(work / rel, dst)


# --- Airflow : dossier de travail du run, sur S3 (ou en local pour tester) ---------------
def _s3(workspace: str):
    """Client S3 (endpoint et identifiants lus dans l'environnement), bucket, préfixe."""
    import boto3

    bucket, _, prefix = workspace.removeprefix("s3://").partition("/")
    prefix = re.sub(r"[^A-Za-z0-9._/-]", "_", prefix).strip("/")  # run_id Airflow : « : + »
    return boto3.client("s3"), bucket, prefix


def pull(workspace: str, work: Path) -> None:
    """Récupère les sorties des étapes précédentes du run."""
    if not workspace.startswith("s3://"):
        if Path(workspace).is_dir():
            copy(workspace, work)
        return
    s3, bucket, prefix = _s3(workspace)
    if bucket not in [b["Name"] for b in s3.list_buckets()["Buckets"]]:
        s3.create_bucket(Bucket=bucket)  # premier run : le bucket n'existe pas encore
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=f"{prefix}/"):
        for obj in page.get("Contents", []):
            target = work / obj["Key"].removeprefix(f"{prefix}/")
            target.parent.mkdir(parents=True, exist_ok=True)
            s3.download_file(bucket, obj["Key"], str(target))


def snapshot(work: Path) -> dict[Path, int]:
    """Fichiers de sortie présents et leur date de modification."""
    return {
        p: p.stat().st_mtime_ns for d in OUTPUT_DIRS for p in (work / d).rglob("*") if p.is_file()
    }


def push(work: Path, workspace: str, before: dict[Path, int]) -> None:
    """Publie les fichiers créés ou modifiés par l'étape."""
    changed = [p for p, mtime in snapshot(work).items() if before.get(p) != mtime]
    if workspace.startswith("s3://"):
        s3, bucket, prefix = _s3(workspace)
        for p in changed:
            s3.upload_file(str(p), bucket, f"{prefix}/{p.relative_to(work).as_posix()}")
    else:
        for p in changed:
            copy(p, Path(workspace) / p.relative_to(work))
    print(f"{len(changed)} fichier(s) publié(s) dans {workspace}", flush=True)


def xcom_summary(work: Path) -> dict:
    """Petites valeurs pour les tasks suivantes : run MLflow du modèle, métriques."""
    from mlflow.models import Model

    from src.evaluate import METRICS_JSON
    from src.train import MODEL_DIR

    summary = {}
    if (work / MODEL_DIR / "MLmodel").exists():
        summary["mlflow_run_id"] = Model.load(work / MODEL_DIR).metadata["mlflow_run_id"]
    if (work / METRICS_JSON).exists():
        summary["metrics"] = json.loads((work / METRICS_JSON).read_text())
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Exécute une étape du projet (task Airflow)", allow_abbrev=False
    )
    parser.add_argument("module", help="étape à lancer, ex. src.prepare")
    parser.add_argument("--workspace", required=True, help="s3://bucket/préfixe ou dossier")
    parser.add_argument("--xcom", action="store_true", help=f"résumé écrit dans {XCOM_FILE}")
    opts, args = parser.parse_known_args()
    args = [a for a in args if a != "--"]  # arguments de l'étape, après « -- »

    with tempfile.TemporaryDirectory(prefix="stage-") as tmp:
        work = Path(tmp)
        pull(opts.workspace, work)
        before = snapshot(work)
        execute(opts.module, args, work)
        push(work, opts.workspace, before)
        if opts.xcom:
            summary = xcom_summary(work)
            XCOM_FILE.parent.mkdir(parents=True, exist_ok=True)
            XCOM_FILE.write_text(json.dumps(summary), encoding="utf-8")
            print("XCom :", summary, flush=True)


if __name__ == "__main__":
    main()
```

Essayez-le sur votre poste :

```bash
python - <<'EOF'
from pipelines.stage import run_stage
from src.dataset_config import load_config
from src.validate_data import REPORT_JSON

cfg = load_config()
run_stage(
    "src.validate_data",
    inputs={cfg.raw_path: cfg.raw_path},
    outputs={str(REPORT_JSON): "/tmp/validation.json"},
)
EOF
cat /tmp/validation.json
```

> **Sortie attendue :** la commande lancée
> (`+ …/.venv/bin/python -m src.validate_data`), son résumé JSON, puis le même JSON relu dans
> `/tmp/validation.json`. L'étape a tourné dans un dossier temporaire : votre repo n'a pas été
> modifié.

### 2.4 L'image du pipeline

Trois fichiers : les dépendances (alignées sur `uv.lock`, mais seulement ce que les étapes
utilisent), le Dockerfile, et la liste de ce qui part dans le contexte de build.

```text
# Fichier : pipelines/requirements.txt
# Dépendances de l'image du pipeline (pipelines/Dockerfile) : de quoi exécuter src/
# (download, validate_data, prepare, train, evaluate, promote) et parler au serveur
# MLflow du cours. Versions alignées sur uv.lock. kfp est installé à part (Dockerfile).
mlflow-skinny==3.16.1  # client MLflow seul : le serveur tourne dans le cluster
scikit-learn==1.9.1
skops==0.16.0  # format de sérialisation des modèles scikit-learn par MLflow 3
pandas==2.3.3
numpy==2.5.3
pyarrow==25.0.1  # data/processed/features.parquet (src/prepare.py)
pyyaml==6.0.3
boto3==1.43.106  # dossier de travail S3 des tasks Airflow (pipelines/stage.py)
```

```dockerfile
# Fichier : pipelines/Dockerfile
# Image « projet » du pipeline : le code du Lab 1 (src/), le contrat dataset.yaml,
# params.yaml et leurs dépendances figées. TOUS les composants KFP (et les tasks Airflow)
# tournent dans cette image : le code est réutilisé tel quel, jamais recopié.
# Contexte de build = RACINE du repo :
#   docker build -f pipelines/Dockerfile -t localhost:5001/scoring-pipeline:1.0.0 .
FROM python:3.12-slim

WORKDIR /app

# 1. Les dépendances d'abord : cette couche, la plus lourde, reste en cache tant que
#    requirements.txt ne change pas (reconstruire après une modification de src/ = 2 s).
#    kfp sans ses dépendances suffit à exécuter un composant : c'est ce que KFP
#    installerait au démarrage de CHAQUE pod (install_kfp_package=False dans components.py).
COPY pipelines/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --root-user-action=ignore -r /tmp/requirements.txt \
    && pip install --no-cache-dir --root-user-action=ignore --no-deps kfp==2.17.0

# 2. Le code et le contrat, avec la même arborescence que le repo
COPY dataset.yaml params.yaml ./
COPY src/ src/
COPY pipelines/__init__.py pipelines/stage.py pipelines/

# src et pipelines importables depuis n'importe quel dossier, dataset.yaml trouvé partout.
# Pas d'utilisateur non-root ici : le lanceur KFP écrit les artefacts sous /minio, /s3…
# à la racine du conteneur (le Lab 4 durcira l'image de serving).
ENV PYTHONPATH=/app \
    DATASET_CONFIG=/app/dataset.yaml \
    PYTHONUNBUFFERED=1

ARG VERSION=dev
LABEL org.opencontainers.image.title="scoring-pipeline" \
      org.opencontainers.image.version="${VERSION}"
```

```text
# Fichier : pipelines/Dockerfile.dockerignore
# .dockerignore propre à pipelines/Dockerfile (BuildKit le lit à la place de celui de la
# racine). Liste blanche : on exclut TOUT, puis on ré-inclut ce que l'image copie.
# Ni .venv/, ni data/, ni .git/, ni .env (secrets) ne partent dans le contexte de build.
*
!dataset.yaml
!params.yaml
!src/
!pipelines/requirements.txt
!pipelines/__init__.py
!pipelines/stage.py
**/__pycache__
```

Construisez l'image, poussez-la dans le registry local créé au Lab 0 (`make cluster`), et
vérifiez qu'elle contient bien le code et le contrat :

```bash
docker build -f pipelines/Dockerfile --build-arg VERSION=1.0.0 \
    -t localhost:5001/scoring-pipeline:1.0.0 .
docker push localhost:5001/scoring-pipeline:1.0.0
curl -s http://localhost:5001/v2/scoring-pipeline/tags/list
docker run --rm localhost:5001/scoring-pipeline:1.0.0 python -c \
    "from src.dataset_config import load_config; c = load_config(); print(c.name, len(c.features))"
```

> **Sortie attendue :** un build de 1 à 2 minutes la première fois (installation des
> dépendances), quelques secondes ensuite tant que `requirements.txt` ne change pas. Puis
> `{"name":"scoring-pipeline","tags":["1.0.0"]}` et `german-credit 20`. L'image pèse environ
> 650 Mo (`docker images localhost:5001/scoring-pipeline`) : on n'a pas cherché à la réduire,
> le Lab 4 le fera pour l'image de serving.

> [!NOTE]
> **Pourquoi pousser dans le registry ?**
> Les pods ne sont pas lancés par votre Docker mais par le kubelet des nœuds kind, qui tirent
> les images d'un registry. `make cluster` a configuré chaque nœud pour joindre
> `localhost:5001` (le conteneur `kind-registry`). Une image seulement construite sur le poste
> donnerait `ImagePullBackOff`.

### 2.5 Écrire les composants dans `pipelines/components.py`

```python
# Fichier : pipelines/components.py
"""Composants KFP du pipeline de scoring (Lab 2).

Chaque composant tourne dans l'image « projet » PIPELINE_IMAGE (pipelines/Dockerfile), qui
contient le code du Lab 1. Un composant ne recopie AUCUNE logique métier : il relie ses
artefacts typés (Dataset, Model, Metrics) aux fichiers d'une stage de dvc.yaml, puis lance
la même commande que DVC (python -m src.<étape>) grâce à pipelines/stage.py.

Rappel KFP : seul le CODE de chaque fonction est envoyé au pod. Les imports se font donc
DANS la fonction (ils sont résolus dans l'image) et aucune valeur par défaut d'un
paramètre ne doit dépendre d'une constante de ce module.
"""

import os

from kfp import dsl
from kfp.dsl import Artifact, ClassificationMetrics, Dataset, Input, Metrics, Model, Output

# Image construite et poussée à l'étape 2.4. Nouveau code dans l'image = nouveau tag.
# Surcharge possible à la compilation : PIPELINE_IMAGE=… python -m pipelines.scoring_pipeline
PIPELINE_IMAGE = os.getenv("PIPELINE_IMAGE", "localhost:5001/scoring-pipeline:1.0.0")
# Serveur MLflow du cours vu depuis un pod (DNS interne <service>.<namespace>)
MLFLOW_URI = "http://mlflow.mlflow:5000"


@dsl.component(base_image=PIPELINE_IMAGE, install_kfp_package=False)
def ingest_data(raw_data: Output[Dataset]) -> None:
    """Stage « download » : python -m src.download produit le fichier brut."""
    import pandas as pd

    from pipelines.stage import run_stage
    from src.dataset_config import load_config
    from src.train import file_md5

    cfg = load_config()
    run_stage("src.download", outputs={cfg.raw_path: raw_data.path})
    raw_data.metadata["dataset"] = cfg.name
    raw_data.metadata["rows"] = len(pd.read_csv(raw_data.path))
    raw_data.metadata["md5"] = file_md5(raw_data.path)  # le même hash que dans dvc.lock


@dsl.component(base_image=PIPELINE_IMAGE, install_kfp_package=False)
def validate_data(
    raw_data: Input[Dataset],
    report: Output[Artifact],
    checks: Output[Metrics],
) -> None:
    """Gate : python -m src.validate_data ; un contrôle en échec fait échouer le step."""
    import json
    from pathlib import Path

    from pipelines.stage import run_stage
    from src.dataset_config import load_config
    from src.validate_data import REPORT_JSON

    cfg = load_config()
    run_stage(
        "src.validate_data",
        inputs={cfg.raw_path: raw_data.path},
        outputs={str(REPORT_JSON): report.path},  # reports/validation.json
    )
    summary = json.loads(Path(report.path).read_text())
    for name in ("n_checks", "n_failed", "rows", "positive_rate"):
        checks.log_metric(name, summary[name])


@dsl.component(base_image=PIPELINE_IMAGE, install_kfp_package=False)
def prepare_features(
    raw_data: Input[Dataset],
    train_data: Output[Dataset],
    test_data: Output[Dataset],
) -> None:
    """Stage « prepare » : python -m src.prepare (split stratifié décrit par dataset.yaml)."""
    import pandas as pd

    from pipelines.stage import run_stage
    from src.dataset_config import load_config
    from src.train import TEST_CSV, TRAIN_CSV

    cfg = load_config()
    run_stage(
        "src.prepare",
        inputs={cfg.raw_path: raw_data.path},
        outputs={str(TRAIN_CSV): train_data.path, str(TEST_CSV): test_data.path},
    )
    for split in (train_data, test_data):
        y = cfg.encode_target(pd.read_csv(split.path)[cfg.target])
        split.metadata["rows"] = len(y)
        split.metadata["positive_rate"] = round(float(y.mean()), 4)


@dsl.component(base_image=PIPELINE_IMAGE, install_kfp_package=False)
def train_model(
    raw_data: Input[Dataset],
    train_data: Input[Dataset],
    test_data: Input[Dataset],
    model: Output[Model],
    model_type: str,
    C: float,
    class_weight: str,
    n_estimators: int,
    max_depth: str,
    learning_rate: float,
    random_state: int,
    mlflow_uri: str,
    kfp_run_id: str,
) -> str:
    """Stage « train » : python -m src.train ; renvoie l'identifiant du run MLflow."""
    from mlflow import MlflowClient
    from mlflow.models import Model as MlflowModel

    from pipelines.stage import run_stage
    from src.dataset_config import load_config
    from src.train import MODEL_DIR, TEST_CSV, TRAIN_CSV

    cfg = load_config()
    run_stage(
        "src.train",
        args=["--model", model_type, "--C", C, "--class_weight", class_weight,
              "--n_estimators", n_estimators, "--max_depth", max_depth,
              "--learning_rate", learning_rate, "--random_state", random_state],
        # le fichier brut sert au tag data_md5 (le même hash que dans dvc.lock)
        inputs={cfg.raw_path: raw_data.path, str(TRAIN_CSV): train_data.path,
                str(TEST_CSV): test_data.path},
        outputs={str(MODEL_DIR): model.path},
        env={"MLFLOW_TRACKING_URI": mlflow_uri, "LAUNCHED_BY": "kfp"},
    )  # fmt: skip
    metadata = MlflowModel.load(model.path).metadata  # écrites par src/train.py
    run_id = metadata["mlflow_run_id"]
    # Lineage : depuis le run MLflow, on retrouve le run KFP qui l'a produit
    MlflowClient(mlflow_uri).set_tag(run_id, "kfp_run_id", kfp_run_id)
    model.metadata["mlflow_run_id"] = run_id
    model.metadata["model_type"] = model_type
    model.metadata["decision_threshold"] = round(metadata["decision_threshold"], 4)
    return run_id


@dsl.component(base_image=PIPELINE_IMAGE, install_kfp_package=False)
def evaluate_model(
    model: Input[Model],
    test_data: Input[Dataset],
    report: Output[Artifact],
    metrics: Output[Metrics],
    confusion: Output[ClassificationMetrics],
    run_id: str,
    mlflow_uri: str,
) -> float:
    """Stage « evaluate » : python -m src.evaluate ; métriques dans l'UI KFP et MLflow."""
    import json
    from pathlib import Path

    import pandas as pd
    from mlflow import MlflowClient

    from pipelines.stage import run_stage
    from src.dataset_config import load_config
    from src.evaluate import METRICS_JSON
    from src.train import MODEL_DIR, TEST_CSV

    cfg = load_config()
    run_stage(
        "src.evaluate",
        inputs={str(MODEL_DIR): model.path, str(TEST_CSV): test_data.path},
        outputs={str(METRICS_JSON): report.path},  # reports/metrics.json
    )
    results = json.loads(Path(report.path).read_text())
    for name, value in results.items():
        if isinstance(value, int | float):
            metrics.log_metric(name, value)

    # Matrice de confusion au seuil de décision, avec les libellés réels de la cible
    positive = str(cfg.positive_class)
    others = sorted(set(pd.read_csv(test_data.path)[cfg.target].astype(str)) - {positive})
    negative = others[0] if len(others) == 1 else f"non {positive}"
    c = results["confusion"]
    confusion.log_confusion_matrix([negative, positive], [[c["tn"], c["fp"]], [c["fn"], c["tp"]]])
    # Le même rapport que reports/metrics.json de DVC, rangé avec le run MLflow
    MlflowClient(mlflow_uri).log_dict(run_id, results, str(METRICS_JSON))
    return float(results[cfg.primary_metric])


@dsl.component(base_image=PIPELINE_IMAGE, install_kfp_package=False)
def register_model(run_id: str, mlflow_uri: str) -> str:
    """python -m src.promote --run-id : @challenger toujours, @champion si métrique ≥ seuil."""
    from mlflow import MlflowClient

    from pipelines.stage import run_stage
    from src.promote import MODEL_NAME

    run_stage("src.promote", args=["--run-id", run_id], env={"MLFLOW_TRACKING_URI": mlflow_uri})
    versions = MlflowClient(mlflow_uri).search_model_versions(
        f"name = '{MODEL_NAME}' and run_id = '{run_id}'"
    )
    return str(versions[0].version)
```

Points clés :

- `base_image=PIPELINE_IMAGE` : chaque composant tourne dans l'image de l'étape 2.4, où
  `src/`, `pipelines/stage.py` et `dataset.yaml` sont importables. `install_kfp_package=False` :
  KFP n'a pas besoin d'installer son propre paquet au démarrage du pod, il est déjà dans
  l'image.
- Les imports sont **dans** les fonctions : ils s'exécutent dans le pod, pas sur votre poste.
- Chaque composant réutilise le code du Lab 1 : les commandes (`src.download`, `src.prepare`,
  `src.train`…) et même les chemins (`TRAIN_CSV`, `MODEL_DIR`, `METRICS_JSON` importés de
  `src.train` et `src.evaluate`). **Aucun nom de colonne** n'apparaît : tout vient de
  `dataset.yaml`.
- `train_model` passe `LAUNCHED_BY=kfp` à `src.train` (le Lab 1 avait prévu cette variable) :
  le run MLflow sera tagué `launched_by=kfp`, avec le paramètre `decision_threshold`. Il
  renvoie (`-> str`) l'identifiant du run MLflow, accessible dans le pipeline par
  `train_task.outputs["Output"]`.
- `evaluate_model` publie trois sorties : le rapport `reports/metrics.json` (`Artifact`), les
  métriques (`Metrics`, affichées dans l'UI) et la matrice de confusion
  (`ClassificationMetrics`), avec les vrais libellés de la cible (`good`, `bad`).
- Les métadonnées des artefacts (`raw_data.metadata["md5"]`, `model.metadata[…]`) apparaissent
  dans l'UI : le md5 du fichier brut est **le même** que dans `dvc.lock`.
- `register_model` (en fin de fichier) ne sera branché qu'à l'étape 5.

> [!NOTE]
> **Le pattern Input/Output**
> Avec KFP v2, on déclare explicitement `Input[Dataset]` ou `Output[Model]`. KFP gère
> automatiquement le stockage dans son SeaweedFS interne (bucket `mlpipeline`), le passage
> entre composants et l'affichage dans l'UI. Le champ `.path` donne un chemin local dans le
> conteneur : un fichier, ou un dossier (le modèle MLflow `models/model` en est un).

> [!WARNING]
> **Ce qui voyage dans le YAML, ce qui voyage dans l'image**
> Le corps des fonctions de `components.py` est recopié dans le pipeline compilé : le modifier
> demande seulement de recompiler. Tout ce qu'elles importent (`src/`, `pipelines/stage.py`,
> `dataset.yaml`, les dépendances) vient de l'image : le modifier demande de **reconstruire
> l'image avec un nouveau tag** (`1.0.1`…) et de mettre ce tag dans `PIPELINE_IMAGE`. C'est le
> prix de la réutilisation, et la garantie que chaque run sait exactement quel code il a
> exécuté.

## Étape 3/9 — Écrire le pipeline orchestrant ces composants (15 min)

### 3.1 Créer `pipelines/scoring_pipeline.py`

```python
# pipelines/scoring_pipeline.py — version de l'étape 3 (complétée aux étapes 5 et 6)
"""Pipeline KFP « scoring-pipeline » du Lab 2.

ingest -> validate -> prepare -> train -> evaluate
Compilation : python -m pipelines.scoring_pipeline   (écrit scoring_pipeline.yaml)
Les hyper-paramètres par défaut sont lus dans params.yaml AU MOMENT DE LA COMPILATION :
params.yaml reste la seule source des valeurs par défaut, comme pour dvc repro.
"""

from pathlib import Path

import yaml
from kfp import compiler, dsl

from pipelines.components import (
    MLFLOW_URI,
    evaluate_model,
    ingest_data,
    prepare_features,
    train_model,
    validate_data,
)

TRAIN = yaml.safe_load(Path("params.yaml").read_text(encoding="utf-8"))["train"]


@dsl.pipeline(
    name="scoring-pipeline",
    description="Credit scoring : ingest -> validate -> prepare -> train -> evaluate",
)
def scoring_pipeline(
    model_type: str = TRAIN["model"],
    C: float = TRAIN["C"],
    class_weight: str = str(TRAIN["class_weight"]),  # « none » accepté, comme au Lab 1
    n_estimators: int = TRAIN["n_estimators"],
    max_depth: str = str(TRAIN["max_depth"]),  # « none » accepté, comme au Lab 1
    learning_rate: float = TRAIN["learning_rate"],
    random_state: int = TRAIN["random_state"],
    mlflow_uri: str = MLFLOW_URI,
):
    ingest_task = ingest_data()

    validate_task = validate_data(raw_data=ingest_task.outputs["raw_data"])

    prep_task = prepare_features(raw_data=ingest_task.outputs["raw_data"])
    prep_task.after(validate_task)  # gate : pas de préparation sans validation réussie

    train_task = train_model(
        raw_data=ingest_task.outputs["raw_data"],
        train_data=prep_task.outputs["train_data"],
        test_data=prep_task.outputs["test_data"],
        model_type=model_type,
        C=C,
        class_weight=class_weight,
        n_estimators=n_estimators,
        max_depth=max_depth,
        learning_rate=learning_rate,
        random_state=random_state,
        mlflow_uri=mlflow_uri,
        kfp_run_id=dsl.PIPELINE_JOB_ID_PLACEHOLDER,  # remplacé par l'id du run KFP
    )

    evaluate_model(
        model=train_task.outputs["model"],
        test_data=prep_task.outputs["test_data"],
        run_id=train_task.outputs["Output"],
        mlflow_uri=mlflow_uri,
    )


if __name__ == "__main__":
    compiler.Compiler().compile(scoring_pipeline, package_path="scoring_pipeline.yaml")
```

- Les paramètres du pipeline (formulaire de l'UI au lancement d'un run) reprennent les
  hyper-paramètres du Lab 1. Leurs valeurs par défaut sont **lues dans `params.yaml` à la
  compilation** : une seule source, comme pour `dvc repro`. Le split, la cible, la métrique et
  le seuil restent dans `dataset.yaml`, embarqué dans l'image.
- `prep_task.after(validate_task)` est crucial : `prepare_features` n'a pas besoin des sorties
  de `validate_data`, KFP les lancerait donc **en parallèle**. Avec `.after()`, la préparation
  attend que la validation ait réussi ; si elle échoue, rien ne s'exécute après.
- `dsl.PIPELINE_JOB_ID_PLACEHOLDER` est remplacé à l'exécution par l'identifiant du run KFP :
  `train_model` le range dans un tag MLflow (`kfp_run_id`), pour remonter d'un run MLflow au
  run KFP qui l'a produit.

### 3.2 Compiler

```bash
python -m pipelines.scoring_pipeline
ls -l scoring_pipeline.yaml   # le fichier compilé
grep -c "image: localhost:5001/scoring-pipeline:1.0.0" scoring_pipeline.yaml
```

> **Sortie attendue :** un fichier `scoring_pipeline.yaml` d'environ 460 lignes : c'est la
> définition du DAG au format IR (*Intermediate Representation*) que KFP comprend. Le `grep`
> compte `5` : un exécuteur par composant utilisé, tous sur l'image du projet.

Ce fichier se regénère à volonté : on ne le commite pas, pas plus que les exécutions locales
(étape 3.3) ni le rapport `reports/validation.json` de l'étape 2.2. (Les fichiers qu'Airflow
créera à l'étape 7, dont un `kubeconfig` qui donne les droits d'administration du cluster, sont
déjà ignorés par `infra/airflow/.gitignore`, fourni avec le repo.) Le `.gitignore` du template
contient déjà le bloc *Lab 2* (`scoring_pipeline.yaml`, `local_outputs/`,
`reports/validation.json`) : vérifiez-le avec `grep -A4 'Lab 2 :' .gitignore`.

### 3.3 Tester en local avant de déployer

KFP sait exécuter un pipeline **sans cluster** : avec le `SubprocessRunner`, chaque composant
tourne dans un sous-processus de votre venv, dans l'ordre du DAG, avec de vrais artefacts sur
disque. `use_venv=False` réutilise le venv du cours, qui contient déjà toutes les dépendances
de l'image ; le code du projet est importé depuis la racine du repo (lancez donc la commande
depuis `~/mlops-cours-2026`). MLflow est joint par le port-forward de `make pf`.

```bash
python - <<'EOF'
from kfp import local

from pipelines.scoring_pipeline import scoring_pipeline

# Chaque composant tourne dans un sous-processus du venv courant (pas dans l'image)
local.init(runner=local.SubprocessRunner(use_venv=False))
scoring_pipeline(mlflow_uri="http://localhost:5000")
EOF
```

> **Sortie attendue :** en une trentaine de secondes, les 5 tâches passent en `SUCCESS`
> (`ingest-data`, `validate-data`, `prepare-features`, `train-model`, `evaluate-model`), avec
> au passage `roc_auc = 0.8094 -> reports/metrics.json` et
> `Pipeline 'scoring-pipeline' finished with status SUCCESS`. Deux avertissements sont normaux :
> `custom or non-Python base image` (le runner local n'utilise pas l'image) et
> `settings … have no effect in the current local runner` (ressources, à l'étape 6). Les
> artefacts sont dans `local_outputs/`.

> [!TIP]
> **Le bon réflexe**
> Une erreur dans un composant (import oublié, faute de frappe) se voit ici en 30 secondes,
> au lieu de 3 minutes sur le cluster. Ce test ne valide pas l'image elle-même (Dockerfile,
> `requirements.txt`) : c'est le run sur le cluster qui le fera.

## Étape 4/9 — Uploader et exécuter le pipeline sur le cluster (15 min)

### 4.1 Upload via l'UI KFP

- Ouvrez l'UI KFP sur `http://localhost:8080`.
- Cliquez **Pipelines → Upload pipeline**.
- Nom : `scoring-pipeline` (exactement : `make check-m2` le cherche), fichier :
  `scoring_pipeline.yaml`.
- Cliquez **Create**.

### 4.2 Créer un run

- Sur la page du pipeline, cliquez **Create run**.
- Choisissez ou créez une experiment `scoring` (le même nom que l'expérience MLflow).
- Laissez les paramètres par défaut : vous reconnaissez ceux de `params.yaml`, plus
  `mlflow_uri` (`http://mlflow.mlflow:5000`).
- Cliquez **Start**. Le DAG s'affiche avec les 5 composants.

### 4.3 Suivre l'exécution

Les composants passent de `Pending` à `Running` puis `Succeeded`. Chaque step prend une
vingtaine de secondes : plus aucun `pip install` au démarrage, tout est dans l'image. Le
premier est un peu plus long, le temps que le nœud tire l'image depuis le registry.

```bash
# En parallèle dans un terminal : regarder les pods
kubectl -n kubeflow get pods -w | grep scoring
```

> **Sortie attendue :** pour chaque step, des pods *driver*
> (`scoring-pipeline-xxxxx-system-dag-driver-…`, `…-system-container-driver-…`) puis un pod
> d'exécution (`…-system-container-impl-…`) : ingest, validate, prepare, train, evaluate, l'un
> après l'autre. Chacun `Completed` en moins d'une minute ; le run complet dure 3 à 4 min.

> [!TIP]
> **Soumettre un run sans l'UI**
> Le SDK pilote la même API que l'UI (à travers le port-forward de l'étape 1.3). C'est ce
> qu'utilisera la CI au Lab 6 :
> ```bash
> python - <<'EOF'
> import kfp
>
> client = kfp.Client(host="http://localhost:8080")
> run = client.create_run_from_pipeline_package(
>     "scoring_pipeline.yaml", experiment_name="scoring", run_name="scoring-cli"
> )
> print(client.wait_for_run_completion(run.run_id, timeout=1800).state)
> EOF
> ```

### 4.4 Explorer les artefacts

- Dans l'UI : cliquez sur un step terminé, onglet **Input/Output**.
- `ingest-data` → `raw_data` : métadonnées `rows: 1000`, `dataset: german-credit` et
  `md5: 24b8e38b9c8688d495afc8eb5cb40127`, le même hash que dans votre `dvc.lock`.
- `validate-data` → `checks` : `n_checks 6`, `n_failed 0`, `positive_rate 0.3`.
- `train-model` → `model` : `mlflow_run_id`, `decision_threshold: 0.3182`, `model_type`.
- `evaluate-model` → `metrics` : `roc_auc 0.8094`, `business_cost 108`, `recall 0.8833`… et
  `confusion` : la matrice de confusion au seuil de décision (good/bad :
  `67 73 / 7 53`), visible dans l'onglet **Visualization**.
- Chaque artefact a un lien vers son stockage dans le SeaweedFS interne de KFP
  (`minio://mlpipeline/v2/artifacts/scoring-pipeline/<run>/…` : KFP garde le préfixe
  historique `minio://`, mais c'est bien SeaweedFS qui répond, via son API S3).

> [!IMPORTANT]
> **Point de validation**
> Vous avez un pipeline qui tourne de bout en bout sur Kubernetes. Chaque step = un pod, avec
> le **même code** que `dvc repro`. Les artefacts circulent via le stockage interne de KFP.
> Les métriques sont visibles dans l'UI, et les chiffres sont exactement ceux du Lab 1
> (même split, même modèle, même seuil). C'est la base de tout ce qu'on va faire jusqu'à la
> fin du cours.

> [!NOTE]
> **Vous travaillez sur votre propre dataset ?**
> Rien à changer dans le code de ce lab : composants, pipeline et DAG lisent tout dans
> `dataset.yaml`. Deux points d'attention : votre `dataset.yaml` et votre `src/download.py`
> sont **copiés dans l'image**, donc reconstruisez-la (nouveau tag) après chaque modification ;
> le step `ingest` exécute votre `src/download.py` dans un pod : s'il a besoin d'un accès
> réseau particulier ou d'identifiants, le pod doit les avoir aussi (secret Kubernetes injecté
> avec `kubernetes.use_secret_as_env`, à voir avec l'enseignant). Vos chiffres (md5, métriques,
> matrice de confusion avec vos libellés) seront différents. Pour un gros dataset, augmentez
> les `set_memory_limit` de l'étape 6.

## Étape 5/9 — Intégrer MLflow : traçabilité et Model Registry (20 min)

Les métriques natives KFP sont utiles pour le debugging. Pour le tracking à long terme et la
comparaison de runs entre pipelines, on s'appuie sur le MLflow du Lab 1. Bonne nouvelle : le
code du Lab 1 trace déjà tout dans MLflow, et le run de l'étape 4 y a écrit.

### 5.1 Ce que le run KFP a écrit dans MLflow

Ouvrez `http://localhost:5000`, expérience `scoring`. Le run le plus récent,
`logistic_regression-C=0.1-class_weight=balanced`, vient du pipeline :

- tags `launched_by=kfp`, `kfp_run_id` (l'identifiant du run KFP, celui de l'URL de l'UI KFP),
  `data_md5`, `dataset`, `model_type` ;
- paramètres, dont `decision_threshold = 0.3182` ; métriques (`roc_auc 0.8094`,
  `business_cost 108`…) ; le modèle (`skops`) et, dans **Artifacts**,
  `reports/metrics.json` déposé par `evaluate_model`.

Dans la liste des runs, ajoutez la colonne `launched_by` : `manual`, `grid_search`, `dvc` et
maintenant `kfp` cohabitent dans la même expérience, comparables entre eux.

### 5.2 Pourquoi ça marche : MLflow vu depuis un pod

Jusqu'au Lab 1, vos scripts parlaient à MLflow via `http://localhost:5000`, c'est-à-dire à
travers le port-forward de `make pf`. Les pods KFP ne voient pas votre `localhost`. Mais le
serveur MLflow du cours tourne **déjà dans le cluster** depuis le Lab 0 (`make mlflow`,
namespace `mlflow`) : rien à déployer. Un pod le joint par le DNS interne de Kubernetes
(`<service>.<namespace>`), d'où la valeur par défaut de `mlflow_uri`. Vérifiez-le depuis un
pod du namespace `kubeflow`, avec l'image du pipeline :

```bash
kubectl -n mlflow get pods,svc
kubectl -n kubeflow run mlflow-check --rm -i --restart=Never \
    --image=localhost:5001/scoring-pipeline:1.0.0 -- python -c \
    "import urllib.request as u; print(u.urlopen('http://mlflow.mlflow:5000/health').read())"
```

> **Sortie attendue :** le pod `mlflow-…` est `Running` et le service `mlflow` expose le port
> 5000. Le pod de test affiche `b'OK'` puis `pod "mlflow-check" deleted`.

Le serveur MLflow est lancé avec `--artifacts-destination s3://mlflow-artifacts` : il fait
**proxy** des artefacts vers le SeaweedFS du cours. Conséquence directe : les composants n'ont
besoin **d'aucun identifiant S3**. Seul le serveur MLflow détient le secret `s3-credentials` ;
un pod KFP envoie ses modèles en HTTP à `http://mlflow.mlflow:5000`. Pas de
`AWS_SECRET_ACCESS_KEY` écrite en dur dans un composant (anti-pattern n°4 du cours).

### 5.3 Le composant `register_model`

Le dernier composant de `components.py`, écrit à l'étape 2.5, enregistre le modèle :

- il lance `python -m src.promote --run-id <run>`, le script du Lab 1 : nouvelle version de
  `scoring-model`, alias `@challenger` toujours, `@champion` **seulement** si la métrique
  primaire de `dataset.yaml` (`roc_auc`) atteint `promotion_threshold` (0,70) ;
- il renvoie le numéro de version créé, visible dans l'UI KFP.

Les *stages* (`Staging`/`Production`) sont dépréciés depuis MLflow 2.9 : on utilise des
**alias**, comme au Lab 1. Le seuil n'est écrit nulle part dans le pipeline : il vient de
`dataset.yaml`.

### 5.4 Brancher le composant, recompiler et relancer

Dans `pipelines/scoring_pipeline.py`, importez `register_model`, nommez la tâche d'évaluation
et ajoutez l'enregistrement à la fin de la fonction :

```python
    eval_task = evaluate_model(
        model=train_task.outputs["model"],
        test_data=prep_task.outputs["test_data"],
        run_id=train_task.outputs["Output"],
        mlflow_uri=mlflow_uri,
    )

    register_task = register_model(run_id=train_task.outputs["Output"], mlflow_uri=mlflow_uri)
    register_task.after(eval_task)  # on n'enregistre qu'un modèle évalué
```

(La version complète du fichier est donnée à l'étape 6.)

```bash
python -m pipelines.scoring_pipeline    # recompile le YAML
# UI KFP : page du pipeline scoring-pipeline -> Upload version, puis Create run
```

> **Sortie attendue :** le DAG affiche 6 composants. Le log de `register-model` se termine
> par `Created version '4' of model 'scoring-model'`, `@challenger -> version 4 (roc_auc =
> 0.8094)` et `@champion   -> version 4 (roc_auc >= seuil 0.7)` (les versions 1 à 3 viennent
> du Lab 1). Sa sortie `Output` vaut `4`.

Vérifiez depuis votre poste qui a produit le champion :

```bash
python - <<'EOF'
from mlflow import MlflowClient

client = MlflowClient()
for alias in ("challenger", "champion"):
    mv = client.get_model_version_by_alias("scoring-model", alias)
    tags = client.get_run(mv.run_id).data.tags
    print(f"@{alias}: version {mv.version}, launched_by={tags['launched_by']}, "
          f"kfp_run_id={tags.get('kfp_run_id')}")
EOF
```

> **Sortie attendue :** `@challenger: version 4, launched_by=kfp, kfp_run_id=<uuid>` et la
> même ligne pour `@champion`. Le lineage est complet dans les deux sens : du modèle au run
> MLflow, du run MLflow au run KFP (`kfp_run_id`), du run KFP aux artefacts et au md5 des
> données (= `dvc.lock`).

## Étape 6/9 — Configurer retries, ressources et caching (15 min)

### 6.1 Ajouter la configuration dans le pipeline

Version finale de `pipelines/scoring_pipeline.py` :

```python
# Fichier : pipelines/scoring_pipeline.py
"""Pipeline KFP « scoring-pipeline » du Lab 2.

ingest -> validate -> prepare -> train -> evaluate -> register
Compilation : python -m pipelines.scoring_pipeline   (écrit scoring_pipeline.yaml)
Les hyper-paramètres par défaut sont lus dans params.yaml AU MOMENT DE LA COMPILATION :
params.yaml reste la seule source des valeurs par défaut, comme pour dvc repro.
"""

from pathlib import Path

import yaml
from kfp import compiler, dsl, kubernetes

from pipelines.components import (
    MLFLOW_URI,
    evaluate_model,
    ingest_data,
    prepare_features,
    register_model,
    train_model,
    validate_data,
)

TRAIN = yaml.safe_load(Path("params.yaml").read_text(encoding="utf-8"))["train"]


@dsl.pipeline(
    name="scoring-pipeline",
    description="Credit scoring : ingest -> validate -> prepare -> train -> evaluate -> register",
)
def scoring_pipeline(
    model_type: str = TRAIN["model"],
    C: float = TRAIN["C"],
    class_weight: str = str(TRAIN["class_weight"]),  # « none » accepté, comme au Lab 1
    n_estimators: int = TRAIN["n_estimators"],
    max_depth: str = str(TRAIN["max_depth"]),  # « none » accepté, comme au Lab 1
    learning_rate: float = TRAIN["learning_rate"],
    random_state: int = TRAIN["random_state"],
    mlflow_uri: str = MLFLOW_URI,
):
    # Source externe (réseau) : 3 nouvelles tentatives, et jamais plus de 10 min
    ingest_task = ingest_data()
    ingest_task.set_retry(num_retries=3, backoff_duration="30s")
    ingest_task.set_cpu_limit("500m").set_memory_limit("512Mi")
    kubernetes.set_timeout(ingest_task, 600)

    validate_task = validate_data(raw_data=ingest_task.outputs["raw_data"])
    validate_task.set_memory_limit("512Mi")

    prep_task = prepare_features(raw_data=ingest_task.outputs["raw_data"])
    prep_task.after(validate_task)  # gate : pas de préparation sans validation réussie
    prep_task.set_memory_limit("1Gi")

    train_task = train_model(
        raw_data=ingest_task.outputs["raw_data"],
        train_data=prep_task.outputs["train_data"],
        test_data=prep_task.outputs["test_data"],
        model_type=model_type,
        C=C,
        class_weight=class_weight,
        n_estimators=n_estimators,
        max_depth=max_depth,
        learning_rate=learning_rate,
        random_state=random_state,
        mlflow_uri=mlflow_uri,
        kfp_run_id=dsl.PIPELINE_JOB_ID_PLACEHOLDER,  # remplacé par l'id du run KFP
    )
    # Une limit seule vaut aussi request : on demande peu, on autorise plus
    train_task.set_cpu_request("500m").set_cpu_limit("2")
    train_task.set_memory_request("512Mi").set_memory_limit("2Gi")
    kubernetes.set_timeout(train_task, 1800)
    # Toujours ré-entraîner : chaque run KFP doit produire un nouveau run MLflow
    train_task.set_caching_options(enable_caching=False)

    eval_task = evaluate_model(
        model=train_task.outputs["model"],
        test_data=prep_task.outputs["test_data"],
        run_id=train_task.outputs["Output"],
        mlflow_uri=mlflow_uri,
    )
    eval_task.set_memory_limit("1Gi")

    register_task = register_model(run_id=train_task.outputs["Output"], mlflow_uri=mlflow_uri)
    register_task.after(eval_task)  # on n'enregistre qu'un modèle évalué
    register_task.set_memory_limit("1Gi")


if __name__ == "__main__":
    compiler.Compiler().compile(scoring_pipeline, package_path="scoring_pipeline.yaml")
```

- `set_retry` : 3 nouvelles tentatives avec backoff exponentiel à partir de 30 s, sur le seul
  step qui dépend d'une source externe (une erreur 503 de l'UCI ne tue plus le run). Retenter
  la validation ou l'entraînement n'aurait aucun sens : l'erreur serait la même.
- `set_cpu_limit` / `set_memory_limit` / `set_cpu_request` / `set_memory_request` : ressources
  du pod. Une *limit* seule vaut aussi *request* pour Kubernetes : la request explicite de
  `500m` évite qu'un train à « 2 CPU » reste `Pending` sur kind. Les valeurs viennent de
  mesures : l'entraînement culmine vers 550 Mo, les autres steps entre 200 et 500 Mo.
- `kubernetes.set_timeout` (paquet `kfp-kubernetes`) : un step bloqué sur un appel réseau est
  tué au bout de 10 min, un entraînement au bout de 30 (anti-pattern n°5 du cours : toujours
  un timeout).
- `set_caching_options(enable_caching=False)` : le train est toujours ré-exécuté, chaque run
  KFP produit un nouveau run MLflow.

```bash
python -m pipelines.scoring_pipeline
grep -nE "maxRetryCount|resourceMemoryLimit|activeDeadlineSeconds" scoring_pipeline.yaml
```

> **Sortie attendue :** `maxRetryCount: 3`, six `resourceMemoryLimit` (`1Gi`, `512Mi`, `1Gi`,
> `1Gi`, `2Gi`, `512Mi`, dans l'ordre alphabétique des exécuteurs) et deux
> `activeDeadlineSeconds` (`'600'`, `'1800'`).

### 6.2 Tester le caching

- Recompilez et uploadez la nouvelle version (**Upload version**).
- Lancez un run, attendez qu'il finisse.
- Relancez un run avec exactement les mêmes paramètres.
- **Observation attendue :** `ingest-data`, `validate-data` et `prepare-features` affichent
  l'icône de cache (statut *Cached*, pas de pod). `train-model` est ré-exécuté (caching
  désactivé), et donc aussi `evaluate-model` et `register-model`, dont les entrées (nouveau
  modèle, nouveau run MLflow) ont changé : versions 5 puis 6 de `scoring-model`.

> [!TIP]
> **Le caching KFP change la donne**
> Sur un pipeline ML typique, les étapes data sont coûteuses mais rarement modifiées. Le
> caching KFP est basé sur le hash (inputs + image + commande). Quand on fait du tuning
> d'hyper-paramètres, seul le step train est relancé. Gain typique : 80 % de temps en moins
> par itération.

> [!WARNING]
> **Même tag, nouveau code = résultats périmés**
> Le cache se fonde sur le **nom** de l'image, pas sur son contenu : si vous reconstruisez
> `scoring-pipeline:1.0.0` après avoir modifié `src/prepare.py`, KFP resservira l'ancien
> résultat. Et les nœuds qui ont déjà l'image `1.0.0` ne la retéléchargent pas
> (`imagePullPolicy: IfNotPresent`). Règle : **tout changement de code dans l'image = nouveau
> tag** (`1.0.1`), reporté dans `PIPELINE_IMAGE`. Jamais `latest`.

> [!NOTE]
> **Un pipeline idempotent**
> Relancer le pipeline ne casse rien : `ingest` réécrit le même fichier (même md5), `promote`
> ne crée pas deux versions pour un même run MLflow. C'est ce qui rend les retries et les
> relances sûrs (cours, partie 4). Ici `ingest` n'a aucun paramètre, donc il est toujours en
> cache après le premier run : en production, on lui passerait une date de partition, pour
> que le cache et l'idempotence se fassent « par date ».

## Étape 7/9 — Installer Airflow et écrire le DAG équivalent (25 min)

Pour la comparaison, on n'installe pas Airflow sur Kubernetes (trop lourd pour un TP). On
utilise le Docker Compose officiel : plus rapide, mêmes concepts visibles. En revanche, les
**tasks** tournent dans le cluster kind grâce au **KubernetesPodOperator** (KPO), avec la
**même image** que KFP : un step = un pod, le même code, ce qui rend la comparaison équitable.

### 7.1 Airflow en Docker Compose

```bash
source infra/versions.env                 # AIRFLOW_VERSION=3.3.2
cd infra/airflow
curl -LfO "https://airflow.apache.org/docs/apache-airflow/${AIRFLOW_VERSION}/docker-compose.yaml"
mkdir -p ./logs ./plugins ./config ../../dags
echo "AIRFLOW_UID=$(id -u)" > .env
echo "AIRFLOW_IMAGE_NAME=apache/airflow:${AIRFLOW_VERSION}-python3.12" >> .env

# Accès au cluster depuis les conteneurs Airflow (réseau Docker « kind »)
kind get kubeconfig --internal --name mlops-lab > kubeconfig
chmod 600 kubeconfig

# Namespace des pods de tasks + identifiants du S3 du cours (même secret qu'au Lab 0).
# --dry-run=client | kubectl apply : relançable sans erreur AlreadyExists (comme make airflow)
kubectl create namespace airflow --dry-run=client -o yaml | kubectl apply -f -
kubectl -n airflow create secret generic s3-credentials \
    --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -

# Démarrer
docker compose up airflow-init
docker compose up -d
docker compose ps
cd ~/mlops-cours-2026
```

Le repo fournit `infra/airflow/docker-compose.override.yaml`, que Docker Compose fusionne
automatiquement avec le fichier officiel (qu'on ne modifie pas) :

```yaml
# Fichier : infra/airflow/docker-compose.override.yaml
# Adaptations du docker-compose.yaml OFFICIEL d'Airflow (téléchargé par
# install.sh, non modifié) pour le cours. Docker Compose fusionne
# automatiquement ce fichier avec docker-compose.yaml.
#   - UI/API sur http://localhost:8081 (le 8080 est pris par l'UI KFP)
#   - pas des ~80 DAGs d'exemple
#   - DAGs lus dans le dossier dags/ à la racine du repo
#   - conteneurs branchés sur le réseau Docker « kind » + kubeconfig interne :
#     le KubernetesPodOperator lance ses pods dans le cluster mlops-lab
x-cours-mlops: &cours-mlops
  environment:
    AIRFLOW__CORE__LOAD_EXAMPLES: "false"
    AIRFLOW_CONN_KUBERNETES_DEFAULT: >-
      {"conn_type": "kubernetes",
      "extra": {"kube_config_path": "/opt/airflow/kube/config"}}
  volumes:
    - ../../dags:/opt/airflow/dags
    - ./kubeconfig:/opt/airflow/kube/config:ro

services:
  airflow-apiserver:
    <<: *cours-mlops
    ports: !override
      - "8081:8080"
  airflow-scheduler: *cours-mlops
  airflow-dag-processor: *cours-mlops
  airflow-worker: *cours-mlops
  airflow-triggerer: *cours-mlops
  airflow-cli: *cours-mlops

networks:
  default:
    name: kind
    external: true
```

> **Sortie attendue :** les services `postgres`, `redis`, `airflow-apiserver`,
> `airflow-scheduler`, `airflow-dag-processor`, `airflow-worker` et `airflow-triggerer` en
> état `Up (healthy)` (`airflow-init` s'est terminé avec le code 0). L'UI est sur
> `http://localhost:8081` (user/pass : `airflow`/`airflow`).

> [!TIP]
> **Une seule commande**
> `make airflow` (script `infra/airflow/install.sh`) fait toute cette étape 7.1, en recopiant
> le secret `s3-credentials` du namespace `storage`. Pour arrêter Airflow et libérer la RAM :
> `cd infra/airflow && docker compose down`.

### 7.2 Créer le DAG dans `dags/scoring_dag.py`

```python
# Fichier : dags/scoring_dag.py
"""DAG Airflow « scoring_dag » : la variante Airflow du pipeline KFP du Lab 2.

Même image (localhost:5001/scoring-pipeline), mêmes commandes que dvc.yaml et que les
composants KFP : chaque task est un pod lancé dans le cluster kind par le
KubernetesPodOperator. Différence clé avec KFP : Airflow ne transporte AUCUN fichier.
Chaque task recopie l'arborescence du projet depuis/vers un préfixe S3 propre au run
(pipelines/stage.py --workspace) ; seules de petites valeurs passent par XCom
(identifiant du run MLflow, métriques).
"""

from datetime import UTC, datetime, timedelta

from airflow.providers.cncf.kubernetes.operators.pod import KubernetesPodOperator
from airflow.sdk import DAG
from kubernetes.client import models as k8s

IMAGE = "localhost:5001/scoring-pipeline:1.0.0"  # même tag que pipelines/components.py
WORKSPACE = "s3://airflow-data/scoring/{{ run_id }}"  # dossier de travail du run (S3)
ENV = {
    "MLFLOW_TRACKING_URI": "http://mlflow.mlflow:5000",  # aucun identifiant S3 pour MLflow
    "LAUNCHED_BY": "airflow",  # tag launched_by des runs MLflow
    "AWS_ENDPOINT_URL": "http://s3.storage:8333",  # S3 du cours, pour le dossier de travail
    "AWS_DEFAULT_REGION": "us-east-1",
}
S3_CREDENTIALS = k8s.V1EnvFromSource(secret_ref=k8s.V1SecretEnvSource(name="s3-credentials"))


def stage(task_id: str, module: str, *args: str, xcom=False, memory="1Gi", retries=0):
    """Une task = un pod qui exécute « python -m pipelines.stage <module> » (une stage DVC)."""
    return KubernetesPodOperator(
        task_id=task_id,
        name=f"scoring-{task_id}",
        namespace="airflow",  # créé par make airflow, avec le secret s3-credentials
        image=IMAGE,
        cmds=["python", "-m", "pipelines.stage", module, "--workspace", WORKSPACE],
        arguments=[*(["--xcom"] if xcom else []), "--", *args],
        env_vars=ENV,
        env_from=[S3_CREDENTIALS],
        container_resources=k8s.V1ResourceRequirements(
            requests={"cpu": "250m", "memory": "512Mi"}, limits={"memory": memory}
        ),
        do_xcom_push=xcom,  # lit /airflow/xcom/return.json écrit par --xcom
        retries=retries,
        get_logs=True,
        on_finish_action="delete_succeeded_pod",
    )


with DAG(
    dag_id="scoring_dag",
    description="Credit scoring : ingest -> validate -> prepare -> train -> evaluate -> register",
    schedule=None,  # déclenchement manuel (cron possible : "0 3 * * *")
    start_date=datetime(2026, 1, 1, tzinfo=UTC),
    catchup=False,
    default_args={"owner": "mlops-student", "retry_delay": timedelta(seconds=30)},
    tags=["mlops", "lab2"],
) as dag:
    ingest = stage("ingest", "src.download", retries=3)  # source externe : retries
    validate = stage("validate", "src.validate_data", memory="512Mi")
    prepare = stage("prepare", "src.prepare")
    train = stage("train", "src.train", xcom=True, memory="2Gi")
    evaluate = stage("evaluate", "src.evaluate", xcom=True)
    register = stage(
        "register",
        "src.promote",
        "--run-id",
        "{{ ti.xcom_pull(task_ids='train')['mlflow_run_id'] }}",
    )

    ingest >> validate >> prepare >> train >> evaluate >> register
```

Points clés :

- Airflow 3 : les objets d'écriture de DAG viennent du **Task SDK** (`from airflow.sdk import
  DAG`) ; le KubernetesPodOperator vient du provider `apache-airflow-providers-cncf-kubernetes`,
  déjà inclus dans l'image officielle.
- Chaque task lance `python -m pipelines.stage <étape>` dans l'image du pipeline : c'est la
  seconde moitié de `stage.py` (étape 2.3) qui sert ici.
- **Aucun artefact typé** : Airflow ne transporte pas de fichiers entre pods. Chaque task
  recopie l'arborescence du run depuis S3 (`s3://airflow-data/scoring/<run_id>/`, bucket
  créé au premier run), exécute son étape et republie ses sorties. Seules de **petites
  valeurs** passent par **XCom** : avec `--xcom`, `train` et `evaluate` écrivent
  `/airflow/xcom/return.json` (identifiant du run MLflow, métriques), que `register` relit
  par un template Jinja (`ti.xcom_pull(...)`).
- Les identifiants S3 viennent du secret Kubernetes `s3-credentials` (`env_from`), jamais du
  code ; MLflow, lui, n'en a toujours pas besoin.
- Les runs MLflow sont tagués `launched_by=airflow` : dans la même expérience `scoring`, vous
  comparerez les runs des trois orchestrateurs (DVC, KFP, Airflow).

### 7.3 Déclencher le DAG

- Ouvrir `http://localhost:8081`.
- Chercher `scoring_dag` dans la liste **Dags** (attendre jusqu'à 30 s le scan du dossier
  `dags/`).
- Cliquer sur le toggle pour activer le DAG.
- Cliquer sur **Trigger** (▶) pour déclencher un run manuel.
- Suivre dans **Graph** : les tasks passent de *queued* à *running* puis *success* (vert).

```bash
# En parallèle : les pods des tasks dans le cluster
kubectl -n airflow get pods -w
```

> **Sortie attendue :** 6 pods `scoring-ingest-…`, `scoring-validate-…`, `scoring-prepare-…`,
> `scoring-train-…`, `scoring-evaluate-…`, `scoring-register-…` créés l'un après l'autre
> (avec le sidecar XCom pour `train` et `evaluate`), supprimés une fois réussis. Le log de
> `evaluate` (onglet **Logs** de la task) affiche `roc_auc = 0.8094 -> reports/metrics.json`
> puis `XCom : {'mlflow_run_id': '…', 'metrics': {…}}` ; celui de `register`,
> `@champion   -> version 7 (roc_auc >= seuil 0.7)` (le numéro dépend de vos runs KFP).
> L'onglet **XCom** de `evaluate` montre les métriques.

## Étape 8/9 — Tester et comparer : DX, scaling, debugging (20 min)

Pour chaque dimension ci-dessous, testez explicitement dans les deux outils et notez vos
observations.

| Dimension | À tester | KFP | Airflow |
|---|---|---|---|
| Installation | Temps et complexité d'install de zéro | KFP : __ min | Airflow : __ min |
| Premier pipeline | Temps jusqu'au premier DAG qui tourne | KFP : __ min | Airflow : __ min |
| Passage d'artifacts | Comment passer un DataFrame entre deux steps proprement | Input/Output typés | XCom (petits objets) + S3 à la main |
| Lineage | Retrouver l'input qui a généré un artifact | UI : 1 clic | Logs et préfixe S3 à parcourir |
| Caching | Relancer un run avec mêmes params : temps d'exécution | KFP : __ | Airflow : __ |
| Parallélisme | `train_A` et `train_B` lancés en parallèle | Natif (pods) | Parallélisme des tasks (1 pod par task) |
| Ressources | Comment donner 4 Go à un step | `set_memory_limit` | `container_resources` (KPO) |
| Dev. local | Tester un step sans redéployer | `kfp.local` (étape 3.3) | `python -m pipelines.stage … --workspace <dossier>` |
| Logs | Trouver le stdout d'un step planté | UI : onglet Logs | UI : onglet Logs |
| Secrets | Injecter une clé API dans un step | Secret K8s (`kfp-kubernetes`) | Connexion / Variable Airflow, ou Secret K8s |

> [!TIP]
> **Conseils pour des tests équitables**
> Testez le hot-reload : modifiez une ligne d'un step et relancez. Combien de temps avant de
> voir le résultat ? (Une ligne de `components.py` : recompiler ; une ligne de `src/` :
> nouvelle image dans les deux cas.) Testez le debugging : faites exprès de faire planter un
> step (par exemple une division par zéro dans `evaluate_model`) et observez comment chaque
> outil surface l'erreur. Testez le parallélisme : ajoutez un deuxième train en parallèle.

Quelques mesures utiles :

```bash
docker stats --no-stream                       # mémoire : nœuds kind vs conteneurs Airflow
wc -l pipelines/components.py pipelines/scoring_pipeline.py dags/scoring_dag.py
# Rejouer une task Airflow sur votre poste, dans un dossier local au lieu de S3
python -m pipelines.stage src.download --workspace /tmp/ws
python -m pipelines.stage src.validate_data --workspace /tmp/ws
ls -R /tmp/ws
```

> **Sortie attendue :** pour chacune des deux dernières commandes,
> `1 fichier(s) publié(s) dans /tmp/ws` ; `/tmp/ws` contient alors `data/raw/dataset.csv` et
> `reports/validation.json` : exactement ce qu'une task Airflow lit et écrit sur S3.

## Étape 9/9 — Rédiger le rapport comparatif (1 page) (15 min)

Produisez un document `reports/rapport-m2.md` d'une page (environ 500 mots). Un modèle à
compléter est fourni :

```bash
cp labs/m2-pipelines/starter/rapport-m2.md reports/rapport-m2.md
```

Structure :

- **Contexte** (1 paragraphe) : quel pipeline, combien de steps, quel dataset.
- **Résultats quantitatifs** (un tableau) : remplir les colonnes « Temps » et « Taille » de
  votre grille de test.
- **Analyse qualitative** (2-3 paragraphes) : sur la DX (developer experience), sur le
  scaling, sur le debugging.
- **Recommandation** (1 paragraphe) : dans quel contexte choisiriez-vous KFP ? Dans quel
  contexte Airflow ? Avec quelles conditions ?
- **Limites de votre comparaison** (1 paragraphe) : qu'est-ce que ce lab ne dit PAS (ex : vous
  n'avez pas testé KFP sur un vrai cluster GKE, vous n'avez pas utilisé le KubernetesExecutor
  d'Airflow, etc.).

Commitez le travail du lab (le pipeline compilé et les exécutions locales sont ignorés par le
bloc *Lab 2* du `.gitignore`, `kubeconfig` et les fichiers téléchargés d'Airflow par
`infra/airflow/.gitignore`) :

```bash
git add src/validate_data.py pipelines/ dags/ reports/rapport-m2.md
git status --short     # ni kubeconfig, ni scoring_pipeline.yaml, ni local_outputs/
git commit -m "feat: pipeline KFP scoring-pipeline + DAG Airflow scoring_dag"
git push -u origin lab/m2-pipelines
gh pr create    # facultatif (GitHub CLI) : ou « Compare & pull request » sur GitHub
```

Votre partenaire relit la PR (composants, pipeline, DAG, rapport) et l'approuve ; vous la
fusionnez, puis vous revenez sur `main` : `git switch main && git pull`.

> [!NOTE]
> **Second membre du binôme (ou nouveau poste) : remettre votre cluster à niveau**
> Une fois la PR fusionnée, rejouez l'état de fin de lab sur **votre** cluster (Lab 1 à niveau,
> `make pf` actif) : KFP, l'image du pipeline et les runs n'existent que chez votre partenaire.
>
> ```bash
> cd ~/mlops-cours-2026 && git switch main && git pull && uv sync
> source .venv/bin/activate && set -a && source .env && set +a
> make kfp && make kfp-ui            # Kubeflow Pipelines, UI et API sur :8080
> make pipeline-image                # image du pipeline dans VOTRE registry localhost:5001
> python -m pipelines.scoring_pipeline
> python - <<'EOF'
> import kfp
>
> client = kfp.Client(host="http://localhost:8080")
> client.upload_pipeline("scoring_pipeline.yaml", pipeline_name="scoring-pipeline")
> for i in (1, 2):  # le second run sert les premières étapes depuis le cache (étape 6.2)
>     run = client.create_run_from_pipeline_package(
>         "scoring_pipeline.yaml", experiment_name="scoring", run_name=f"rattrapage-{i}")
>     print(client.wait_for_run_completion(run.run_id, timeout=1800).state)
> EOF
> make airflow                       # puis déclencher scoring_dag (étape 7.3)
> make check-m2
> ```
>
> Ne commitez rien de ce que ces commandes régénèrent (`scoring_pipeline.yaml`, `kubeconfig`
> sont ignorés ; `dvc.lock` reste modifié en local, voir Lab 1) : `git status` ne doit montrer
> que `dvc.lock`.

## Checklist de validation

| # | Élément | Test | Résultat attendu | OK |
|---|---|---|---|---|
| 1 | KFP installé | `kubectl -n kubeflow get pods` | 14 pods `Running` (dont `seaweedfs`) | ☐ |
| 2 | UI KFP accessible | Ouvrir `localhost:8080` | L'interface Kubeflow se charge | ☐ |
| 3 | Image du pipeline | `curl localhost:5001/v2/scoring-pipeline/tags/list` | Tag `1.0.0` présent | ☐ |
| 4 | Composants écrits | Fichier `pipelines/components.py` | 6 composants `@dsl.component` sur l'image du projet | ☐ |
| 5 | Pipeline compilé | `python -m pipelines.scoring_pipeline` | `scoring_pipeline.yaml` généré | ☐ |
| 6 | Pipeline uploadé | UI KFP onglet Pipelines | `scoring-pipeline` visible | ☐ |
| 7 | Run KFP réussi | UI KFP onglet Runs | 6 steps en vert, metrics et matrice de confusion | ☐ |
| 8 | MLflow joignable du cluster | Pod de test de l'étape 5.2 | `b'OK'` | ☐ |
| 9 | MLflow intégré | UI MLflow après run KFP | Run `launched_by=kfp`, version `@challenger` | ☐ |
| 10 | Retries/ressources | YAML compilé contient les policies | `maxRetryCount`, `resourceMemoryLimit`, `activeDeadlineSeconds` | ☐ |
| 11 | Caching testé | Relancer un run identique | Steps data en cache (*Cached*) | ☐ |
| 12 | Airflow tourne | `docker compose ps` (dans `infra/airflow`) | Tous les services `Up (healthy)` | ☐ |
| 13 | Run Airflow réussi | UI Airflow : Graph | `scoring_dag` activé, 6 tasks success | ☐ |
| 14 | Rapport rédigé | `cat reports/rapport-m2.md` | ~500 mots avec les 5 sections | ☐ |

## Critères d'évaluation (noté sur 20)

| Critère | Description | Points |
|---|---|---|
| Pipeline KFP fonctionnel | Run end-to-end réussi, 6 composants, artifacts typés, code du Lab 1 réutilisé (image projet, aucun nom de colonne en dur). | 6 |
| Intégration MLflow | Chaque run KFP produit un run MLflow (`launched_by=kfp`, `kfp_run_id`, `decision_threshold`, métriques, modèle) et une version de `scoring-model`. | 3 |
| Robustesse | Retries, ressources, timeouts, caching configurés de manière pertinente ; gate de validation. | 3 |
| Pipeline Airflow | DAG fonctionnel, tasks ordonnées, XCom utilisé correctement (petites valeurs seulement). | 3 |
| Rapport comparatif | Les 5 sections présentes. Analyse honnête, pas un copier/coller. | 5 |
| **Total** | | **20** |

## Annexe — Troubleshooting

| Symptôme | Cause probable | Solution |
|---|---|---|
| KFP pods bloqués en `Pending` | Ressources K8s insuffisantes. | Augmenter la RAM de Docker Desktop à 8 Go. Arrêter Airflow (`docker compose down`) et les autres pods inutiles. |
| `metadata-grpc-deployment` en `CrashLoopBackOff` (`exec format error`) sur Mac Apple Silicon | Image ML Metadata publiée pour amd64 seulement. | Docker Desktop : activer « Use Rosetta for x86_64/amd64 emulation », puis `kubectl -n kubeflow rollout restart deploy/metadata-grpc-deployment`. |
| `kubectl apply -k github.com/...` : erreur de clonage | Pas de `git` ou pas d'accès à GitHub. | Installer `git` ; vérifier le proxy de l'école ; relancer `make kfp` (idempotent). |
| Pod de step en `ImagePullBackOff` sur `localhost:5001/scoring-pipeline:…` | Image non poussée, ou tag différent de `PIPELINE_IMAGE`. | `docker push localhost:5001/scoring-pipeline:1.0.0` ; `curl localhost:5001/v2/scoring-pipeline/tags/list` ; comparer avec `components.py`. |
| Pod `train-model` en `Pending` (*Insufficient cpu*) | Une limit sans request vaut request : 2 CPU demandés. | Garder `set_cpu_request("500m")` ou baisser `set_cpu_limit`. |
| Step `OOMKilled` | Limite mémoire trop basse pour votre dataset. | Augmenter le `set_memory_limit` du step (étape 6). |
| `ModuleNotFoundError: No module named 'src'` (dans un pod) | Image construite sans `src/`, ou mauvais `PYTHONPATH`. | Vérifier le Dockerfile et `Dockerfile.dockerignore`, reconstruire avec un nouveau tag. |
| `ModuleNotFoundError: No module named 'src'` (avec `kfp.local`) | Commande lancée hors de la racine du repo. | `cd ~/mlops-cours-2026` avant le test local. |
| `components.py` : `NameError` à l'exécution | Valeur par défaut ou code de la fonction qui utilise une constante du module, non recopiée dans le pod. | Tout ce dont la fonction a besoin est importé **dans** la fonction ; pas de constante du module dans les signatures. |
| Le pipeline tourne avec l'ancien code | Image reconstruite sous le même tag (cache KFP, `IfNotPresent`). | Nouveau tag (`1.0.1`), le reporter dans `PIPELINE_IMAGE`, recompiler (étape 6.2). |
| `validate-data` en échec | Les données ne respectent pas `dataset.yaml`. | Lire le JSON dans les logs du step (`failed`) ; corriger les données ou le contrat. C'est le gate qui fonctionne. |
| Composant train : `ConnectionError` vers `mlflow.mlflow:5000` | Serveur MLflow arrêté ou mauvais URI. | `kubectl -n mlflow get pods` ; refaire le test de l'étape 5.2 ; `make mlflow` si besoin. |
| MLflow : `Invalid Host header` | `mlflow_uri` avec un nom d'hôte non autorisé par le serveur. | Garder `http://mlflow.mlflow:5000` (autorisé par `--allowed-hosts`, Lab 0). |
| Pipeline KFP : erreur d'upload/téléchargement d'artifact | SeaweedFS interne de KFP pas prêt (bucket `mlpipeline`). | `kubectl -n kubeflow rollout restart deployment/seaweedfs` puis attendre `Running`. |
| UI KFP ne charge pas / 502 | Port-forward interrompu. | Relancer `make kfp-ui` (journal : `/tmp/mlops-port-forward/kfp-ui.log`). |
| `kfp.local` : `Connection refused` sur `localhost:5000` | Port-forward MLflow arrêté. | `make pf`. |
| Airflow : DAG not found | Fichier hors de `dags/` à la racine du repo, ou erreur d'import. | Le fichier doit être dans `dags/`. Attendre 30 s le scan. Voir les erreurs : `docker compose exec airflow-scheduler airflow dags list-import-errors` (dans `infra/airflow`). |
| Airflow XCom : object too large | XCom ne supporte que les petits objets. | Passer des chemins/clés S3 via XCom, pas des DataFrames complets. |
| KPO : `Connection refused` ou `Invalid kube-config` | kubeconfig non « internal » ou conteneurs hors du réseau `kind`. | Régénérer `kind get kubeconfig --internal ...` (étape 7.1) puis `docker compose up -d`. |
| KPO : `InvalidAccessKeyId` / `NoCredentialsError` | Secret `s3-credentials` absent du namespace `airflow`. | Le recréer (étape 7.1) ou relancer `make airflow`. |
| `register` (Airflow) : `KeyError` / `None` dans `--run-id` | La task `train` n'a pas poussé de XCom. | Vérifier `xcom=True` sur `train` (`do_xcom_push`) et le log `XCom : {...}`. |
| `docker compose up` : port already used | Un autre Airflow ou service sur 8081. | Modifier le port dans `docker-compose.override.yaml` ou stopper l'autre service. |
| `docker compose` : `unknown tag !override` | Docker Compose trop ancien. | Mettre à jour Docker Compose (≥ 2.24.4). |
| `dsl.component` pas reconnu | Mauvaise version de kfp. | `uv sync` (kfp 2.17, pas kfp 1.x qui a une syntaxe différente). |

## Pour aller plus loin

- **Le gate visible dans le DAG** : remplacer la promotion conditionnelle de `src.promote`
  par une branche KFP, `with dsl.If(eval_task.output >= seuil): …`, pour voir la décision
  dans l'UI (le Lab 6 comparera challenger et champion).
- **Parallélisme** : entraîner plusieurs modèles en parallèle avec
  `dsl.ParallelFor(["logistic_regression", "random_forest"])`, puis garder le meilleur.
- **Planification** : un *Recurring run* KFP (cron `0 3 * * *`) ou `schedule="0 3 * * *"`
  dans le DAG.
- **Tester l'image elle-même en local** : `local.DockerRunner()` exécute chaque composant dans
  son image (MLflow doit alors être joignable depuis le conteneur).
- **Paramètres Airflow** : exposer les hyper-paramètres du DAG avec `params=` et les passer à
  `src.train` par template Jinja, comme les paramètres du pipeline KFP.
- Documentation : [KFP — composants Python](https://www.kubeflow.org/docs/components/pipelines/user-guides/components/lightweight-python-components/),
  [KFP — exécution locale](https://www.kubeflow.org/docs/components/pipelines/user-guides/core-functions/execute-kfp-pipelines-locally/),
  [Airflow — Docker Compose](https://airflow.apache.org/docs/apache-airflow/stable/howto/docker-compose/index.html),
  [KubernetesPodOperator](https://airflow.apache.org/docs/apache-airflow-providers-cncf-kubernetes/stable/operators.html).

> [!NOTE]
> **Prochaine étape**
> Module 3 — Validation des données et des modèles. Vous remplacerez les contrôles simples de
> `src/validate_data.py` par une suite Great Expectations (même interface, même gate dans le
> pipeline), puis vous ajouterez une détection de drift et des tests du modèle (Evidently et
> tests comportementaux) comme nouveaux steps de `scoring-pipeline`. Nouvelle étape = nouvelle
> version de l'image.

## Vérification automatique

Depuis la racine du repo, port-forwards actifs (`make pf`) :

```bash
make check-m2
```

Le script `labs/m2-pipelines/check.sh` lit `dataset.yaml` et vérifie, sans rien modifier :

- KFP : déploiements du namespace `kubeflow` disponibles, SeaweedFS interne présent, API
  joignable (via `localhost:8080`, ou un port-forward temporaire) ;
- le code : `src/validate_data.py` valide le fichier brut ; l'image `scoring-pipeline` au tag
  de `PIPELINE_IMAGE` est dans le registry local ; les 6 composants utilisent cette image ; le
  pipeline compile avec retries, limites mémoire, timeouts et cache désactivé sur le train ;
  aucun identifiant S3 ni nom de colonne de `dataset.yaml` en dur dans `pipelines/` et
  `dags/` ;
- les runs : pipeline `scoring-pipeline` uploadé, au moins deux runs réussis (test du cache) ;
- MLflow : `/health`, un run `launched_by=kfp` dont le `kfp_run_id` est un run KFP réussi
  (avec `decision_threshold` et la métrique primaire), une version de `scoring-model`
  produite par ce pipeline ;
- Airflow : `dags/scoring_dag.py` présent (DAG `scoring_dag`, même image que KFP), un run
  MLflow `launched_by=airflow` terminé ; si Airflow tourne, DAG chargé sans erreur, activé,
  avec au moins un run réussi ;
- `reports/rapport-m2.md` : environ 500 mots, les 5 sections, aucun `TODO`.

Chaque item affiche ✅ ou ❌ (avec l'étape à revoir) ; le code retour est le nombre d'échecs.

> **Sortie attendue :** `🎉 19/19 vérifications OK — Lab 2 validé.` (18/18 si Airflow est
> arrêté : la vérification « live » du DAG est alors ignorée).
