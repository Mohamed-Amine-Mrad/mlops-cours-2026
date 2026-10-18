---
module: 3
lab: 3
title: "Gate de validation dans le pipeline"
subtitle: "Ajouter Great Expectations, la détection de drift et les tests de modèle au pipeline KFP"
running_title: "Lab 3 — Validation données & modèle"
duree: "2 heures (atelier guidé)"
stack: "Great Expectations 1.23 · Evidently 0.7 · scipy · pytest · KFP 2.17"
prerequis: "Lab 2 réussi : pipeline KFP scoring-pipeline fonctionnel"
livrable: "Pipeline KFP avec gates bloquants + rapports HTML"
---

# Lab 3 — Gate de validation dans le pipeline

*Ajouter des étapes de validation qui bloquent l'entraînement si les données ne respectent pas
le contrat. Simuler un drift, le détecter automatiquement, et tester le modèle (rapport
Evidently, tests comportementaux) avant de l'enregistrer.*

## Objectifs

> [!NOTE]
> **À la fin de ce lab, vous aurez :**
>
> - Une **suite Great Expectations** complète pour votre dataset, générée depuis `dataset.yaml`
>   et versionnée dans `gx/`.
> - Un **composant KFP de validation** qui bloque le pipeline en cas de violation du contrat.
> - Une **simulation de drift** (une nouvelle clientèle, plus jeune, qui emprunte plus et plus
>   longtemps) et sa détection automatique (KS, χ², PSI, Wasserstein), avec un rapport
>   Evidently.
> - Une **validation du modèle** avant son enregistrement : rapport Evidently avec tests et
>   **tests comportementaux** pytest (performance minimale, invariance, directionnels).
> - Des **rapports HTML** générés à chaque run et visibles dans l'UI KFP.
> - La preuve que le pipeline **échoue proprement** sur données corrompues.

## Architecture cible

```text
 scoring-pipeline (image localhost:5001/scoring-pipeline:1.2.0)

 ingest ─► validate_data ─► prepare ─► detect_drift ─► train ─┬─► evaluate ───────┐
           GATE 1            │          GATE 2                └─► validate_model ─┴─► register
           contrat de        │          train vs test             GATE 3
           données (GX)      │          (KS/χ² + PSI,             Evidently + tests
           rapport HTML      │          rapport Evidently)        comportementaux

 Pipelines de test : test_bad_data.py (doit ÉCHOUER au gate 1)
                     drift_demo.py    (drift simulé, détecté par le gate 2)
```

Un gate est un step comme un autre : s'il échoue, KFP n'exécute aucun des steps qui en
dépendent (*fail-fast*). On ne prépare pas, on n'entraîne pas et surtout on n'enregistre pas de
modèle à partir de données ou d'un modèle qui ne respectent pas le contrat.

## Plan du lab

| # | Étape | Durée |
|---|---|---|
| 1 | Créer la suite Great Expectations depuis `dataset.yaml` | 20 min |
| 2 | Mettre à jour le composant KFP `validate_data` (image 1.1.0) | 20 min |
| 3 | Insérer le gate dans le pipeline existant | 15 min |
| 4 | Tester : données propres passent, corrompues échouent | 15 min |
| 5 | Ajouter un composant `detect_drift` (KS + PSI, Evidently) | 20 min |
| 6 | Ajouter un composant `validate_model` (Evidently + tests comportementaux) | 20 min |
| 7 | Exporter les rapports HTML comme artifacts KFP | 10 min |

> [!IMPORTANT]
> **Préalable**
> Le cluster `mlops-lab` doit tourner, KFP doit être déployé et votre pipeline
> `scoring-pipeline` du Lab 2 doit exister dans KFP : `make check-m2` entièrement vert. Vérifier :
> `kubectl -n kubeflow get pods`, tous `Running`. Il faut aussi les données et le modèle du
> Lab 1 sur votre poste (`data/processed/`, `models/model/`) : `dvc pull` s'ils manquent, ou
> `dvc repro` si le remote DVC de votre cluster ne les a jamais reçus (second membre du binôme,
> nouveau poste : voir le Lab 1, étape 10.4).

Au début de chaque séance :

```bash
cd ~/mlops-cours-2026
kubectl get nodes          # 3 nœuds Ready
make pf                    # port-forwards S3 :8333 et MLflow :5000
source .venv/bin/activate  # venv du cours
set -a && source .env && set +a
dvc pull                   # données et modèle du Lab 1 s'ils manquent (remote vide : dvc repro)
make kfp-ui                # UI et API KFP sur http://localhost:8080 (comme au Lab 2)
```

Dans un **nouveau terminal** de la même séance, seules les deux lignes `source .venv/bin/activate`
et `set -a && source .env && set +a` sont nécessaires (après `cd ~/mlops-cours-2026`) : les
port-forwards tournent déjà en arrière-plan.

## Branche de travail

Comme chaque lab (convention du Lab 0, étape 8.1), celui-ci se fait sur sa propre branche,
créée depuis `main` à jour, et se termine par une pull request relue par le partenaire du
binôme :

```bash
cd ~/mlops-cours-2026
git switch main && git pull
git switch -c lab/m3-validation
```

## Convention de notation

Les blocs de code contiennent des commandes shell à exécuter telles quelles depuis la racine de
votre fork `~/mlops-cours-2026` : elles n'ont **pas** de préfixe `$`, vous pouvez les
copier-coller directement. Les lignes commençant par `#` sont des commentaires. Quand un bloc
commence par `# Fichier : chemin`, c'est le contenu **complet** du fichier à créer (ou à
remplacer). Les encadrés « Sortie attendue » montrent le résultat attendu, avec les chiffres
réels obtenus sur le dataset par défaut (German Credit).

## Étape 1/7 — Créer la suite Great Expectations depuis `dataset.yaml` (20 min)

### 1.1 Great Expectations dans l'environnement du cours

Great Expectations (GX) est déjà installé : il fait partie de l'environnement unique du cours
(`uv sync` du Lab 0), avec Evidently, scipy et pytest qui serviront aux étapes 5 et 6.

```bash
python -c "import great_expectations as gx; print(gx.__version__)"
```

> **Sortie attendue :** `1.23.2`, après environ 3 secondes : l'import de GX est lent, ce n'est
> pas un bug.

GX 1.x a profondément changé d'API par rapport aux versions 0.x que l'on trouve encore dans
beaucoup de tutoriels. Si vous croisez du code ancien :

| GX 0.18 (ancien) | GX 1.x (ce lab) |
|---|---|
| `ExpectationConfiguration(expectation_type="expect_…", kwargs=…)` | une classe par expectation : `gx.expectations.ExpectColumnValuesToNotBeNull(column=…)` |
| `context.sources.add_pandas(…)` | `context.data_sources.add_pandas(…)` |
| `context.add_or_update_expectation_suite(…)` | `context.suites.add_or_update(…)` |
| `validator = context.get_validator(…)` puis `validator.validate()` | `gx.ValidationDefinition(data=…, suite=…)` |
| `context.add_or_update_checkpoint(validations=[…])` | `gx.Checkpoint(validation_definitions=[…], actions=[…])` |
| `context.run_checkpoint(…)` | `checkpoint.run(batch_parameters={"dataframe": df})` |

Le vocabulaire, une fois pour toutes :

| Objet GX | Rôle | Dans ce lab |
|---|---|---|
| *Data Context* | le projet GX : configuration et stockage de tout le reste | le dossier `gx/` à la racine du repo |
| *Data Source* / *Data Asset* | d'où viennent les données | source `scoring` (pandas), asset `dataframe` |
| *Batch Definition* | quelle partie des données valider | `full` : tout le DataFrame fourni |
| *Expectation Suite* | le contrat : une liste d'expectations | `scoring_contract` |
| *Validation Definition* | « cette suite sur ces données » | `scoring_contract` |
| *Checkpoint* | ce qu'on exécute, et les actions qui suivent | `scoring_gate` (met à jour les Data Docs) |
| *Data Docs* | site HTML : la suite et l'historique des validations | `gx/uncommitted/data_docs/` |

### 1.2 Écrire la suite d'expectations

Plutôt que d'utiliser l'UI interactive (plus lourde), on écrit la suite en Python pur, ce qui
est plus proche de la pratique en CI. Et plutôt que de lister les colonnes à la main, on la
**génère** : les colonnes, leurs types et la cible viennent de `dataset.yaml` ; les bornes et
les modalités viennent des **données d'entraînement** (`data/processed/train.csv`), ce que le
modèle a réellement vu. Le script garde l'interface du Lab 2 (même commande, même JSON, même
code retour) : le composant KFP, le DAG Airflow et `make check-m2` continuent de fonctionner.

```python
# Fichier : src/validate_data.py
"""Valide un fichier de données contre le contrat Great Expectations du projet (gx/).

Gate du pipeline (Labs 2 et 3) : si une expectation échoue, le script sort avec le code 1
et l'orchestrateur (DVC, Kubeflow, Airflow, CI) s'arrête AVANT l'entraînement. Le Lab 3
remplace les contrôles simples du Lab 2 par une suite Great Expectations, sans changer la
façon de lancer le script :

    python -m src.validate_data [fichier.csv]     (défaut : raw_path de dataset.yaml)
    python -m src.validate_data --build-suite     ((ré)écrit la suite dans gx/)

La suite est GÉNÉRÉE depuis dataset.yaml et les données d'entraînement (domaines observés),
puis versionnée dans Git : elle ne change que si on la régénère volontairement.
Sorties : résumé JSON (sortie standard et reports/validation.json), rapport HTML autonome
(reports/validation.html) et Data Docs (gx/uncommitted/data_docs/local_site/index.html).
"""

import argparse
import html
import json
import sys
from pathlib import Path

import great_expectations as gx
import pandas as pd
from great_expectations.data_context.types.base import ProgressBarsConfig

from src.dataset_config import DatasetConfig, load_config

PROJECT_ROOT = Path(__file__).resolve().parents[1]  # gx/ est à la racine du projet
SUITE = "scoring_contract"  # gx/expectations/scoring_contract.json
CHECKPOINT = "scoring_gate"  # gx/checkpoints/scoring_gate.json
REFERENCE_CSV = Path("data/processed/train.csv")  # données d'entraînement (src/prepare.py)
REPORT_JSON = Path("reports/validation.json")
REPORT_HTML = Path("reports/validation.html")
MOSTLY = 0.99  # tolérance des contrôles de valeurs : jusqu'à 1 % hors domaine
NUMERIC_TYPES = ["int64", "int32", "float64", "float32", "Int64", "Float64"]
TEXT_TYPES = ["object", "str", "string", "category"]


# --------------------------------------------------------------- construire la suite
def build_expectations(cfg: DatasetConfig, ref: pd.DataFrame) -> list:
    """Le contrat de données, déduit de dataset.yaml et des données de référence."""
    E = gx.expectations
    expectations = []
    add = expectations.append
    numeric = [c for c in cfg.columns if c != cfg.target and pd.api.types.is_numeric_dtype(ref[c])]
    categorical = [c for c in cfg.columns if c not in numeric and c != cfg.target]

    # 1. Structure : les colonnes du contrat sont présentes ; le lot n'est pas tronqué
    add(E.ExpectTableColumnsToMatchSet(column_set=cfg.columns, exact_match=False))
    add(E.ExpectTableRowCountToBeBetween(min_value=max(1, len(ref) // 10)))

    # 2. Chaque colonne : remplie comme à l'entraînement, et du bon type
    for col in cfg.columns:
        null_rate = float(ref[col].isna().mean())  # 0 : aucune valeur manquante tolérée
        mostly = {"mostly": round(max(0.0, 1 - 2 * null_rate), 3)} if null_rate else {}
        add(E.ExpectColumnValuesToNotBeNull(column=col, **mostly))
        types = NUMERIC_TYPES if pd.api.types.is_numeric_dtype(ref[col]) else TEXT_TYPES
        add(E.ExpectColumnValuesToBeInTypeList(column=col, type_list=types))

    # 3. Numériques : bornes larges (même signe, au plus deux fois l'étendue observée).
    #    Elles attrapent les erreurs grossières (signe, unité) ; les variations naturelles
    #    relèvent de la détection de drift.
    for col in numeric:
        lo, hi = float(ref[col].min()), float(ref[col].max())
        span = hi - lo
        add(
            E.ExpectColumnValuesToBeBetween(
                column=col,
                min_value=0.0 if lo >= 0 else lo - span,
                max_value=hi + span,
                mostly=MOSTLY,
            )
        )

    # 4. Catégorielles : modalités vues à l'entraînement (une autre est inconnue du modèle)
    for col in categorical:
        observed = sorted(ref[col].dropna().unique().tolist(), key=str)
        add(E.ExpectColumnValuesToBeInSet(column=col, value_set=observed, mostly=MOSTLY))

    # 5. Cible : classes connues ; part de la classe positive entre la moitié et le double
    #    de celle de l'entraînement (« mostly » = part minimale des valeurs dans l'ensemble)
    classes = sorted(ref[cfg.target].dropna().unique().tolist(), key=str)
    positive = [c for c in classes if str(c) == str(cfg.positive_class)]
    others = [c for c in classes if str(c) != str(cfg.positive_class)]
    rate = float(cfg.encode_target(ref[cfg.target]).mean())
    add(E.ExpectColumnValuesToBeInSet(column=cfg.target, value_set=classes))
    add(
        E.ExpectColumnValuesToBeInSet(
            column=cfg.target,
            value_set=positive,
            mostly=round(rate / 2, 3),
            description=f"Au moins {rate / 2:.0%} de « {cfg.positive_class} »",
        )
    )
    add(
        E.ExpectColumnValuesToBeInSet(
            column=cfg.target,
            value_set=others,
            mostly=round(max(0.0, 1 - 2 * rate), 3),
            description=f"Au plus {min(1.0, 2 * rate):.0%} de « {cfg.positive_class} »",
        )
    )
    return expectations


def save_suite(expectations: list) -> gx.ExpectationSuite:
    """Écrit dans gx/ la suite, ses données (pandas), la validation et le checkpoint."""
    context = gx.get_context(mode="file", project_root_dir=PROJECT_ROOT)  # crée gx/
    context.enable_analytics(False)  # aucune télémétrie envoyée à GX
    context.variables.progress_bars = ProgressBarsConfig(globally=False)
    context.variables.save()
    # Source « pandas » : le DataFrame est fourni à chaque exécution (batch_parameters)
    batch = (
        context.data_sources.add_or_update_pandas("scoring")
        .add_dataframe_asset("dataframe")
        .add_batch_definition_whole_dataframe("full")
    )
    suite = context.suites.add_or_update(gx.ExpectationSuite(name=SUITE, expectations=expectations))
    definition = context.validation_definitions.add_or_update(
        gx.ValidationDefinition(name=SUITE, data=batch, suite=suite)
    )
    context.checkpoints.add_or_update(
        gx.Checkpoint(
            name=CHECKPOINT,
            validation_definitions=[definition],
            actions=[gx.checkpoint.UpdateDataDocsAction(name="data_docs")],
            result_format={"result_format": "SUMMARY"},
        )
    )
    return suite


# --------------------------------------------------------------------- valider
def validate(cfg: DatasetConfig, df: pd.DataFrame):
    """Lance le checkpoint versionné sur df ; renvoie le résultat de la validation."""
    if not (PROJECT_ROOT / "gx" / "checkpoints" / f"{CHECKPOINT}.json").exists():
        raise SystemExit("Suite absente : lancez python -m src.validate_data --build-suite")
    missing = [c for c in cfg.columns if c not in df.columns]
    if missing:
        print(f"Colonnes déclarées dans dataset.yaml absentes des données : {missing}",
              file=sys.stderr)  # fmt: skip
    context = gx.get_context(mode="file", project_root_dir=PROJECT_ROOT)
    result = context.checkpoints.get(CHECKPOINT).run(batch_parameters={"dataframe": df})
    return next(iter(result.run_results.values()))


def check_name(r) -> str:
    """Nom lisible d'une expectation : type(colonne), et sa description s'il y en a une."""
    config = r.expectation_config
    name = config.type + (f"({config.kwargs['column']})" if "column" in config.kwargs else "")
    return f"{name} : {config.description}" if config.description else name


def run_checks(cfg: DatasetConfig, df: pd.DataFrame) -> dict[str, bool]:
    """Un booléen par expectation de la suite (True = conforme au contrat)."""
    return {check_name(r): bool(r.success) for r in validate(cfg, df).results}


def expected(r) -> str:
    """Les paramètres de l'expectation : bornes, ensemble de valeurs, tolérance…"""
    kwargs = r.expectation_config.kwargs
    return ", ".join(
        f"{k}={str(v)[:80]}" for k, v in kwargs.items() if k not in ("column", "batch_id")
    )


def observed(r) -> str:
    """Ce que GX a observé : valeur, ou nombre et exemples de valeurs hors contrat."""
    if not r.success and r.exception_info.get("raised_exception"):
        return "erreur : " + str(r.exception_info.get("exception_message"))[:150]
    res = r.result or {}
    if "unexpected_count" in res:
        sample = ", ".join(map(str, (res.get("partial_unexpected_list") or [])[:5]))
        text = f"{res['unexpected_count']} hors contrat ({res['unexpected_percent']:.1f} %)"
        return f"{text} : {sample}…" if sample and not r.success else text
    return str(res.get("observed_value", ""))


def write_html(results, summary: dict, path: Path) -> None:
    """Rapport HTML autonome (un seul fichier) : affiché par l'UI Kubeflow."""
    rows = "".join(
        f"<tr class='{'ok' if r.success else 'ko'}'><td>{html.escape(check_name(r))}</td>"
        f"<td>{html.escape(expected(r))}</td><td>{html.escape(observed(r))}</td>"
        f"<td>{'OK' if r.success else 'ÉCHEC'}</td></tr>\n"
        for r in sorted(results, key=lambda r: r.success)  # les échecs en premier
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        f"""<!DOCTYPE html>
<html lang="fr"><head><meta charset="utf-8"><title>Validation des données</title>
<style>body{{font-family:sans-serif;margin:2em}} table{{border-collapse:collapse}}
td,th{{border:1px solid #ccc;padding:4px 8px;text-align:left}}
.ok td:last-child{{color:#1a7f37}} .ko td:last-child{{color:#cf222e;font-weight:bold}}</style>
</head><body><h1>Suite {SUITE} : {summary["n_failed"]} échec(s) sur {summary["n_checks"]}</h1>
<p>{summary["rows"]} lignes, part de la classe positive : {summary["positive_rate"]}</p>
<table><tr><th>Expectation</th><th>Attendu</th><th>Observé</th><th>Statut</th></tr>
{rows}</table>
</body></html>
""",
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("csv", nargs="?", help="fichier à valider (défaut : raw_path)")
    parser.add_argument(
        "--build-suite",
        action="store_true",
        help=f"(ré)écrit la suite depuis dataset.yaml et csv (défaut : {REFERENCE_CSV})",
    )
    args = parser.parse_args()
    cfg = load_config()

    if args.build_suite:
        suite = save_suite(build_expectations(cfg, pd.read_csv(args.csv or REFERENCE_CSV)))
        print(f"Suite {SUITE} : {len(suite.expectations)} expectations -> gx/expectations/")
        return 0

    df = pd.read_csv(args.csv or cfg.raw_path)
    results = validate(cfg, df).results
    failed = [check_name(r) for r in results if not r.success]
    has_target = cfg.target in df.columns and len(df) > 0
    summary = {
        "success": not failed,
        "n_checks": len(results),
        "n_failed": len(failed),
        "failed": failed,
        "rows": len(df),
        "positive_rate": round(float(cfg.encode_target(df[cfg.target]).mean()), 4)
        if has_target
        else None,
        "suite": SUITE,
    }
    REPORT_JSON.parent.mkdir(parents=True, exist_ok=True)
    REPORT_JSON.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", "utf-8")
    write_html(results, summary, REPORT_HTML)
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0 if summary["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
```

Ce que contient la suite, famille par famille :

| Famille | Expectations | D'où vient la valeur attendue | Ce qu'elle attrape |
|---|---|---|---|
| Structure | `ExpectTableColumnsToMatchSet`, `ExpectTableRowCountToBeBetween` | `dataset.yaml` ; 10 % du volume d'entraînement | colonne disparue, fichier tronqué |
| Complétude | `ExpectColumnValuesToNotBeNull` (chaque colonne) | taux de manquants à l'entraînement (0 : strict ; sinon jusqu'au double) | « le nombre de NaN double » |
| Types | `ExpectColumnValuesToBeInTypeList` | type observé (nombre ou texte) | un nombre devenu texte |
| Numériques | `ExpectColumnValuesToBeBetween` | min/max d'entraînement, élargis | signe inversé, changement d'unité |
| Catégorielles | `ExpectColumnValuesToBeInSet` | modalités vues à l'entraînement | « un nouveau code pays apparaît » |
| Cible | `ExpectColumnValuesToBeInSet` (×3) | classes et taux de la classe positive | étiquette inconnue, cible quasi constante |

Points clés :

- Les bornes numériques sont **volontairement larges** (même signe, au plus deux fois
  l'étendue observée) : la suite attrape les erreurs grossières, pas les variations naturelles.
  Une population qui se déplace en restant plausible, c'est un **drift**, traité à l'étape 5.
- `mostly=0.99` : jusqu'à 1 % de valeurs hors domaine est toléré (une modalité rare absente du
  jeu d'entraînement, un montant exceptionnel). Au-delà, l'expectation échoue.
- La part de la classe positive est contrôlée par deux `ExpectColumnValuesToBeInSet` avec
  `mostly` : « au moins 15 % de `bad` » et « au moins 40 % de non-`bad` », c'est-à-dire au plus
  60 % de `bad`. Leur `description` s'affiche dans les rapports.
- Le checkpoint met à jour les **Data Docs** à chaque validation, et le script écrit en plus un
  rapport HTML **autonome** (`reports/validation.html`, un seul fichier) : c'est lui que l'UI
  Kubeflow affichera (les Data Docs sont un site de plusieurs fichiers).

### 1.3 Générer la suite et la tester sur le dataset propre

```bash
python -m src.validate_data --build-suite
python -m src.validate_data; echo "Code retour : $?"
```

> **Sortie attendue :** `Suite scoring_contract : 67 expectations -> gx/expectations/`, puis le
> résumé JSON de la validation des données brutes : `"success": true`, `"n_checks": 67`,
> `"n_failed": 0`, `"failed": []`, `"rows": 1000`, `"positive_rate": 0.3`,
> `"suite": "scoring_contract"` et `Code retour : 0`.

Ouvrez les deux rapports dans votre navigateur :

```bash
xdg-open gx/uncommitted/data_docs/local_site/index.html   # macOS : open ; WSL : wslview
xdg-open reports/validation.html
```

Les **Data Docs** listent la suite `scoring_contract` (chaque expectation en clair : « values
must belong to this set: … ») et l'historique des validations, une ligne par exécution du
checkpoint. Le rapport `reports/validation.html` tient en un tableau : expectation, valeurs
attendues, valeur observée, statut.

### 1.4 Tester sur des données corrompues

Premier test, comme une erreur de saisie : 20 durées négatives.

```bash
python - <<'EOF'
import pandas as pd

from src.dataset_config import load_config

cfg = load_config()
df = pd.read_csv(cfg.raw_path)
df.loc[df.index[:20], cfg.numeric[0]] *= -1  # 20 valeurs négatives (duration)
df.to_csv("/tmp/dataset_bad.csv", index=False)
EOF
python -m src.validate_data /tmp/dataset_bad.csv; echo "Code retour : $?"
```

> **Sortie attendue :** `"success": false`, `"n_failed": 1`,
> `"failed": ["expect_column_values_to_be_between(duration)"]` et `Code retour : 1`. 20 lignes
> sur 1000, c'est 2 % : au-delà de la tolérance de 1 %. C'est ce qu'on veut : la CI verra le
> code retour non nul et bloquera la suite.

Second test, plus réaliste : les bugs de données « qui ne crient pas » du cours (partie 1). Ce
petit outil fabrique des données de test à partir des vraies ; il resservira dans le pipeline
(étape 4) et pour simuler un drift (étape 5).

```python
# Fichier : src/simulate.py
"""Fabrique des données de test à partir de vraies données (Lab 3).

    python -m src.simulate corrupt entree.csv sortie.csv   # bugs de données silencieux
    python -m src.simulate drift entree.csv sortie.csv     # nouvelle population

corrupt : trois bugs « qui ne crient pas » (cours, partie 1), déduits de dataset.yaml :
  - la première variable numérique change d'unité (valeurs x 100) ;
  - la première variable catégorielle reçoit un code inconnu sur 10 % des lignes ;
  - la cible manque sur 5 % des lignes.
drift : données valides mais déplacées, selon le scénario de params.yaml
  (drift.simulation) : facteurs multiplicatifs (scale) et décalages (shift).
"""

import argparse
from pathlib import Path

import pandas as pd
import yaml

from src.dataset_config import DatasetConfig, load_config


def corrupt(cfg: DatasetConfig, df: pd.DataFrame) -> pd.DataFrame:
    """Les bugs typiques d'un fournisseur de données : unité, nouveau code, trous."""
    df = df.copy()
    seed = cfg.random_state
    df[cfg.numeric[0]] = df[cfg.numeric[0]] * 100  # ex. des euros devenus des centimes
    df.loc[df.sample(frac=0.10, random_state=seed).index, cfg.categorical[0]] = "INCONNU"
    df.loc[df.sample(frac=0.05, random_state=seed + 1).index, cfg.target] = None
    return df


def drift(df: pd.DataFrame, scenario: dict) -> pd.DataFrame:
    """Population déplacée : x facteur, + décalage (borné aux valeurs observées)."""
    out = df.copy()
    for col, factor in (scenario.get("scale") or {}).items():
        out[col] = df[col] * factor
    for col, delta in (scenario.get("shift") or {}).items():
        out[col] = (out[col] + delta).clip(df[col].min(), df[col].max())
    for col in out.columns:  # les entiers restent entiers (âge, durée en mois…)
        if pd.api.types.is_integer_dtype(df[col]) and not pd.api.types.is_integer_dtype(out[col]):
            out[col] = out[col].round().astype(df[col].dtype)
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("kind", choices=["corrupt", "drift"])
    parser.add_argument("input")
    parser.add_argument("output")
    args = parser.parse_args()

    cfg = load_config()
    df = pd.read_csv(args.input)
    if args.kind == "corrupt":
        out = corrupt(cfg, df)
    else:
        params = yaml.safe_load(Path("params.yaml").read_text(encoding="utf-8"))
        out = drift(df, params["drift"]["simulation"])
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    out.to_csv(args.output, index=False)
    print(f"{args.kind} : {len(out)} lignes -> {args.output}")


if __name__ == "__main__":
    main()
```

```bash
python -m src.simulate corrupt data/raw/dataset.csv /tmp/dataset_corrupted.csv
python -m src.validate_data /tmp/dataset_corrupted.csv; echo "Code retour : $?"
```

> **Sortie attendue :** `corrupt : 1000 lignes -> /tmp/dataset_corrupted.csv`, puis
> `"n_failed": 3` avec `expect_column_values_to_be_between(duration)` (unité ×100),
> `expect_column_values_to_be_in_set(checking_status)` (code `INCONNU`) et
> `expect_column_values_to_not_be_null(credit_risk)` (cible manquante), `Code retour : 1`.
> Ouvrez `reports/validation.html` : les échecs sont en tête, avec des exemples de valeurs
> fautives.

> [!IMPORTANT]
> **Point de validation**
> Vous avez maintenant un script exécutable en CLI qui retourne zéro ou non-zéro selon la
> validité des données. C'est exactement ce qu'il nous faut pour un composant KFP… et le
> composant existe déjà depuis le Lab 2.

### 1.5 Ce qu'on versionne

`--build-suite` a créé le dossier `gx/` :

```text
gx/
├── great_expectations.yml                 # le projet : stores, source « scoring », Data Docs
├── expectations/scoring_contract.json     # LE contrat : les 67 expectations
├── validation_definitions/scoring_contract.json   # cette suite sur ces données
├── checkpoints/scoring_gate.json          # ce qu'on exécute, et les actions (Data Docs)
├── plugins/custom_data_docs/…             # personnalisation des Data Docs (inchangée)
├── .gitignore                             # contient « uncommitted/ »
└── uncommitted/                           # NON versionné : résultats, Data Docs, secrets
```

Tout est versionné dans Git **sauf** `gx/uncommitted/` : les résultats de validation et les
Data Docs se regénèrent, et `config_variables.yml` est l'endroit prévu pour des identifiants.
La suite, elle, est du **code** : elle passe en revue de code (PR) comme le reste. Elle n'est
regénérée que volontairement, quand le contrat change (nouvelle colonne, nouveau jeu
d'entraînement validé) : la regénérer à chaque run ferait suivre les données par le contrat,
au lieu de contrôler les données avec le contrat. Après un `--build-suite`, `git diff gx/`
montre exactement ce qui a changé.

Les rapports regénérés à chaque exécution (`reports/validation.html`, `reports/drift.*`,
`reports/model_validation.*`, `reports/model_behavior.xml`, `reports/kfp/`) et les pipelines de
test compilés (`test_bad_data.yaml`, `drift_demo.yaml`, étapes 4 et 5) n'ont rien à faire dans
Git non plus. Le `.gitignore` du template contient déjà le bloc *Lab 3* : vérifiez-le avec
`grep -A10 'Lab 3 :' .gitignore`.

```bash
git add gx/ src/validate_data.py src/simulate.py
git status --short    # ni gx/uncommitted/, ni reports/validation.*
git commit -m "feat: contrat de données Great Expectations (gx/)"
```

> [!TIP]
> **Alternative légère : Pandera**
> Pour un contrôle de schéma rapide dans un test unitaire (Lab 6), Pandera exprime le même
> type de contrat en quelques lignes, lui aussi généré depuis `dataset.yaml` :
> ```bash
> python - <<'EOF'
> import pandas as pd
> import pandera.pandas as pa
>
> from src.dataset_config import load_config
>
> cfg = load_config()
> ref = pd.read_csv("data/processed/train.csv")
> schema = pa.DataFrameSchema(
>     {c: pa.Column(float, pa.Check.ge(min(0, ref[c].min())), coerce=True) for c in cfg.numeric}
>     | {c: pa.Column(str, pa.Check.isin(ref[c].unique())) for c in cfg.categorical}
>     | {cfg.target: pa.Column(str, pa.Check.isin(ref[cfg.target].unique()))}
> )
> schema.validate(pd.read_csv(cfg.raw_path))
> print("Données brutes : conformes")
> try:
>     schema.validate(pd.read_csv("/tmp/dataset_bad.csv"), lazy=True)
> except pa.errors.SchemaErrors as err:
>     print(err.failure_cases[["column", "check", "failure_case"]].head(3))
> EOF
> ```
> Sortie : `Données brutes : conformes`, puis trois durées négatives refusées par
> `greater_than_or_equal_to(0)`. Pandera pour les schémas simples en CI ; GX pour un contrat
> riche, documenté (Data Docs) et partagé avec les équipes données.

## Étape 2/7 — Mettre à jour le composant KFP `validate_data` (20 min)

### 2.1 Ajouter le rapport HTML au composant

Le composant `validate_data` du Lab 2 lance déjà `python -m src.validate_data` dans l'image du
projet : comme le script a gardé son interface, le gate fonctionne avec la suite GX sans
changer sa logique. On lui ajoute une sortie : le rapport HTML, que l'UI KFP affiche. Dans
`pipelines/components.py`, remplacez la ligne d'import de `kfp.dsl` par ce bloc (`Markdown`
servira à l'étape 5) :

```python
# pipelines/components.py — nouvel import
from kfp.dsl import (
    HTML,
    Artifact,
    ClassificationMetrics,
    Dataset,
    Input,
    Markdown,
    Metrics,
    Model,
    Output,
)
```

puis remplacez la fonction `validate_data` :

```python
# pipelines/components.py — fonction validate_data (Lab 3)
@dsl.component(base_image=PIPELINE_IMAGE, install_kfp_package=False)
def validate_data(
    raw_data: Input[Dataset],
    report: Output[Artifact],
    html: Output[HTML],
    checks: Output[Metrics],
) -> None:
    """Gate : suite Great Expectations (python -m src.validate_data) ; un échec arrête le run."""
    import json
    from pathlib import Path

    from pipelines.stage import run_stage
    from src.dataset_config import load_config
    from src.validate_data import REPORT_HTML, REPORT_JSON

    cfg = load_config()
    run_stage(
        "src.validate_data",
        inputs={cfg.raw_path: raw_data.path},
        outputs={str(REPORT_JSON): report.path, str(REPORT_HTML): html.path},
    )
    summary = json.loads(Path(report.path).read_text())
    for name in ("n_checks", "n_failed", "rows", "positive_rate"):
        checks.log_metric(name, summary[name])
```

### 2.2 Points clés du code

- Le composant a 3 sorties : le résumé JSON (`report`, un `Artifact`), le rapport HTML
  (`html`, un artifact typé `HTML` que KFP affiche directement dans l'UI) et les métriques
  (`checks`, visibles dans l'onglet **Input/Output** du step).
- Si la validation échoue, `src.validate_data` sort avec le code 1 : `run_stage` lève une
  exception, le composant échoue, KFP l'interprète comme un échec du step et n'exécute pas les
  steps qui en dépendent.
- Tous les imports sont DANS la fonction (obligatoire pour KFP : seul le code de la fonction
  part dans le pod) ; ils sont résolus dans l'image, qui contient `src/` **et** `gx/`.

> [!WARNING]
> **Pas de rapport HTML pour un step en échec**
> Le lanceur KFP (2.17) ne publie les sorties d'un step **que s'il réussit** : en cas d'échec,
> seul le journal d'exécution est conservé. Quand le gate bloque, le diagnostic se lit donc dans
> les **logs** du step (le JSON liste les expectations en échec), pas dans le rapport HTML. En
> test local (`kfp.local`), le rapport reste disponible : on en profitera à l'étape 4.

### 2.3 Une nouvelle image : 1.1.0

`src/validate_data.py`, `src/simulate.py` et `gx/` vivent dans l'image : il faut la
reconstruire, avec un **nouveau tag** (règle du Lab 2 : nouveau code = nouveau tag, jamais le
même). On ajoute d'un coup les dépendances de tout le lab (GX, Evidently, scipy, pytest) : la
couche la plus lourde ne sera construite qu'une fois, et la reconstruction de l'étape 6 ne
prendra que quelques secondes.

```text
# Fichier : pipelines/requirements.txt
# Dépendances de l'image du pipeline (pipelines/Dockerfile) : de quoi exécuter src/
# (download, validate_data, prepare, train, evaluate, promote, detect_drift,
# validate_model) et parler au serveur MLflow du cours. Versions alignées sur uv.lock.
# kfp est installé à part (Dockerfile).
mlflow-skinny==3.16.1  # client MLflow seul : le serveur tourne dans le cluster
scikit-learn==1.9.1
skops==0.16.0  # format de sérialisation des modèles scikit-learn par MLflow 3
pandas==2.3.3
numpy==2.5.3
pyarrow==25.0.1  # data/processed/features.parquet (src/prepare.py)
pyyaml==6.0.3
boto3==1.43.106  # dossier de travail S3 des tasks Airflow (pipelines/stage.py)
# Lab 3 : gates de validation
great-expectations==1.23.2  # contrat de données (gx/)
evidently==0.7.23  # rapports de drift et de classification
scipy==1.18.1  # tests KS, chi2, Wasserstein (src/detect_drift.py)
pytest==9.1.1  # tests comportementaux du modèle (tests/test_model_behavior.py)
```

```dockerfile
# Fichier : pipelines/Dockerfile
# Image « projet » du pipeline : le code du projet (src/), le contrat dataset.yaml,
# params.yaml, la suite Great Expectations (gx/) et les tests comportementaux du modèle,
# avec leurs dépendances figées. TOUS les composants KFP (et les tasks Airflow) tournent
# dans cette image : le code est réutilisé tel quel, jamais recopié.
# Contexte de build = RACINE du repo (même tag que PIPELINE_IMAGE de components.py) :
#   docker build -f pipelines/Dockerfile --build-arg VERSION=<tag> \
#       -t localhost:5001/scoring-pipeline:<tag> .
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
COPY gx/ gx/
COPY tests/ tests/
COPY pipelines/__init__.py pipelines/stage.py pipelines/

# src et pipelines importables depuis n'importe quel dossier, dataset.yaml trouvé partout.
# Pas d'utilisateur non-root ici : le lanceur KFP écrit les artefacts sous /minio, /s3…
# à la racine du conteneur (le Lab 4 durcira l'image de serving).
# DO_NOT_TRACK : ni MLflow ni Evidently n'envoient de télémétrie (GX : gx/*.yml).
ENV PYTHONPATH=/app \
    DATASET_CONFIG=/app/dataset.yaml \
    PYTHONUNBUFFERED=1 \
    DO_NOT_TRACK=true

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
!gx/
gx/uncommitted/
!tests/
!pipelines/requirements.txt
!pipelines/__init__.py
!pipelines/stage.py
**/__pycache__
```

Ce qui change par rapport au Lab 2 : la suite `gx/` est copiée dans l'image (le pipeline
valide avec le contrat **versionné**, jamais avec un contrat regénéré à la volée), sans
`gx/uncommitted/` ; le dossier `tests/` aussi (étape 6) ; `DO_NOT_TRACK=true` coupe la
télémétrie de MLflow et d'Evidently (celle de GX est coupée dans `gx/great_expectations.yml`).

Passez au tag `1.1.0` dans les composants **et** dans le DAG Airflow (`make check-m2` vérifie
que les deux utilisent la même image), puis construisez et poussez :

```bash
sed -i 's/scoring-pipeline:1.0.0/scoring-pipeline:1.1.0/' \
    pipelines/components.py dags/scoring_dag.py
grep -n "scoring-pipeline:" pipelines/components.py dags/scoring_dag.py
docker build -f pipelines/Dockerfile --build-arg VERSION=1.1.0 \
    -t localhost:5001/scoring-pipeline:1.1.0 .
docker push localhost:5001/scoring-pipeline:1.1.0
docker run --rm localhost:5001/scoring-pipeline:1.1.0 python -c \
    "import great_expectations as gx, evidently; print(gx.__version__, evidently.__version__)"
docker run --rm localhost:5001/scoring-pipeline:1.1.0 ls gx
```

> **Sortie attendue :** les deux lignes `grep` affichent `scoring-pipeline:1.1.0`. Le build
> prend 2 à 3 minutes (nouvelles dépendances). Puis `1.23.2 0.7.23`, et `checkpoints`,
> `expectations`, `great_expectations.yml`, `plugins`, `validation_definitions` (pas
> d'`uncommitted`). L'image passe d'environ 650 Mo à environ 950 Mo : GX et Evidently
> apportent plotly, statsmodels, altair…

> [!NOTE]
> **macOS**
> `sed -i` attend un argument d'extension sur macOS : `sed -i '' 's/…/…/' fichiers`.

## Étape 3/7 — Insérer le gate dans le pipeline existant (15 min)

### 3.1 Le gate du Lab 2, avec plus de mémoire

Le gate est déjà en place dans `pipelines/scoring_pipeline.py` depuis le Lab 2 : la
préparation attend la validation. Une seule modification : GX consomme plus de mémoire que les
contrôles simples du Lab 2. Mesuré : environ 250 Mo pour le composant (qui importe
`src.validate_data`, donc GX) et autant pour le sous-processus qui exécute la suite. La limite
de 512 Mi du Lab 2 provoquerait un `OOMKilled`. Dans `scoring_pipeline()`, remplacez les
deux lignes de `validate_task` par :

```python
    # Gate 1 : le contrat de données (suite Great Expectations versionnée dans gx/)
    validate_task = validate_data(raw_data=ingest_task.outputs["raw_data"])
    validate_task.set_memory_limit("1Gi")
```

Les lignes suivantes, inchangées, font le travail du gate :

```python
    prep_task = prepare_features(raw_data=ingest_task.outputs["raw_data"])
    prep_task.after(validate_task)  # gate : pas de préparation sans validation réussie
```

> [!NOTE]
> **Le pattern .after()**
> `prep_task.after(validate_task)` est crucial. Sans lui, KFP verrait que `prepare_features`
> n'a pas besoin des sorties de `validate_data` et les lancerait en parallèle. Avec `.after()`,
> on force l'ordre : si `validate_data` échoue, `prepare_features` (et `train`, `evaluate`,
> `register`) ne tournent jamais.

### 3.2 Compiler et tester en local

```bash
python -m pipelines.scoring_pipeline
wc -l scoring_pipeline.yaml
grep -c "image: localhost:5001/scoring-pipeline:1.1.0" scoring_pipeline.yaml
python - <<'EOF'
from kfp import local

from pipelines.scoring_pipeline import scoring_pipeline

local.init(runner=local.SubprocessRunner(use_venv=False))
scoring_pipeline(mlflow_uri="http://localhost:5000")
EOF
```

> **Sortie attendue :** `568 scoring_pipeline.yaml`, puis `6` (un exécuteur par composant). En
> une cinquantaine de secondes, les 6 tâches passent en `SUCCESS` ; le log de `validate-data`
> affiche le résumé JSON (`"n_checks": 67`, `"n_failed": 0`) et `register-model` crée une
> nouvelle version de `scoring-model`. Le rapport HTML du gate est dans
> `local_outputs/scoring-pipeline-<horodatage>/validate-data/html` : ouvrez-le dans le
> navigateur.

## Étape 4/7 — Tester : données propres passent, corrompues échouent (15 min)

### 4.1 Uploader et lancer le pipeline normal

- Dans l'UI KFP (`http://localhost:8080`) : **Pipelines → scoring-pipeline → Upload version**,
  fichier `scoring_pipeline.yaml`.
- **Create run** (experiment `scoring`) avec les paramètres par défaut.
- Observer : les 6 steps passent tous en vert (ingest, validate, prepare, train, evaluate,
  register).
- Cliquer sur `validate-data` → onglet **Visualization** : le rapport HTML s'affiche, avec les
  67 expectations `OK`. Onglet **Input/Output** : `n_checks 67`, `n_failed 0`.

### 4.2 Forcer un échec de validation

On ne touche pas au pipeline de production : un **pipeline de test** fait passer de vraies
données, corrompues par `src.simulate`, dans le même composant `validate_data`.

D'abord, une retouche de `pipelines/stage.py` pour le test local : quand l'étape échoue, on
recopie quand même les rapports qu'elle a écrits (ils expliquent l'échec). Remplacez la
fonction `run_stage` :

```python
# pipelines/stage.py — fonction run_stage (Lab 3)
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
        try:
            execute(module, args, work, env)
        except subprocess.CalledProcessError:
            # Gate en échec (Lab 3) : on recopie quand même les rapports déjà écrits,
            # ils expliquent l'échec (kfp.local les garde dans local_outputs/)
            for rel, dst in (outputs or {}).items():
                if (work / rel).exists():
                    copy(work / rel, dst)
            raise
        for rel, dst in (outputs or {}).items():
            copy(work / rel, dst)
```

Sur le cluster, cela ne change rien (KFP ne publie pas les sorties d'un step en échec, voir
2.2) : inutile de reconstruire l'image maintenant, la retouche partira avec l'image de
l'étape 6.

```python
# Fichier : pipelines/test_bad_data.py
"""Pipeline de test du gate (Lab 3) : sur des données corrompues, il doit ÉCHOUER.

ingest -> corrupt_data -> validate_data (échec attendu) -> prepare_features (jamais lancé)
Compilation : python -m pipelines.test_bad_data   (écrit test_bad_data.yaml)
"""

from kfp import compiler, dsl
from kfp.dsl import Dataset, Input, Output

from pipelines.components import (
    PIPELINE_IMAGE,
    ingest_data,
    prepare_features,
    validate_data,
)


@dsl.component(base_image=PIPELINE_IMAGE, install_kfp_package=False)
def corrupt_data(raw_data: Input[Dataset], corrupted: Output[Dataset]) -> None:
    """Injecte trois bugs « silencieux » (python -m src.simulate corrupt)."""
    from pipelines.stage import run_stage

    clean, bad = "data/raw/clean.csv", "data/raw/corrupted.csv"
    run_stage(
        "src.simulate",
        args=["corrupt", clean, bad],
        inputs={clean: raw_data.path},
        outputs={bad: corrupted.path},
    )


@dsl.pipeline(name="scoring-bad-data-test", description="Le gate doit refuser ces données")
def bad_data_pipeline():
    ingest_task = ingest_data()
    corrupt_task = corrupt_data(raw_data=ingest_task.outputs["raw_data"])
    validate_task = validate_data(raw_data=corrupt_task.outputs["corrupted"])
    prep_task = prepare_features(raw_data=corrupt_task.outputs["corrupted"])
    prep_task.after(validate_task)  # ne doit jamais s'exécuter


if __name__ == "__main__":
    compiler.Compiler().compile(bad_data_pipeline, package_path="test_bad_data.yaml")
```

```bash
python -m pipelines.test_bad_data
python - <<'EOF'
from kfp import local

from pipelines.test_bad_data import bad_data_pipeline

# raise_on_error=False : un échec est affiché, sans interrompre ce script
local.init(runner=local.SubprocessRunner(use_venv=False), raise_on_error=False)
bad_data_pipeline()
EOF
ls local_outputs/scoring-bad-data-test-*/validate-data/
```

> **Sortie attendue :** `ingest-data` et `corrupt-data` en `SUCCESS`, puis le JSON de
> `validate-data` (`"n_failed": 3` et les trois expectations de l'étape 1.4), `Task
> 'validate-data' finished with status FAILURE` et `Pipeline 'scoring-bad-data-test' finished
> with status FAILURE. Inner task failed: 'validate-data'.` `prepare-features` n'a jamais été
> exécuté. Le `ls` montre `html` et `report` : ouvrez `html`, les 3 échecs sont en tête.

Sur le cluster, maintenant :

- **Pipelines → Upload pipeline**, nom `scoring-bad-data-test`, fichier `test_bad_data.yaml`.
- **Create run** (experiment `scoring`).

> **Sortie attendue :** `ingest-data` et `corrupt-data` passent en vert. `validate-data` passe
> en rouge (échec). `prepare-features` n'est jamais lancé : il reste absent ou grisé dans le
> graphe, et le run est `Failed`. Les logs de `validate-data` (onglet **Logs**) montrent le
> JSON avec les 3 expectations en échec.

> [!IMPORTANT]
> **Le gate fonctionne**
> Vous venez de prouver que votre pipeline refuse d'entraîner un modèle sur des données qui ne
> respectent pas le contrat. C'est le pattern *fail-fast* : l'erreur est détectée au plus tôt,
> on économise des minutes de calcul et on protège le Model Registry.

## Étape 5/7 — Ajouter un composant `detect_drift` : KS + PSI (20 min)

Le gate Great Expectations détecte les violations de contrat. Mais il ne détecte pas un drift
progressif, où les données restent valides mais s'éloignent de la distribution
d'entraînement. On ajoute donc un composant spécifique.

### 5.1 Mesurer un drift : significativité ET magnitude

Les seuils vont dans `params.yaml`, avec le scénario de drift simulé de l'étape 5.2 :

```bash
cat >> params.yaml <<'EOF'

# Lab 3 : détection de drift (src/detect_drift.py, pipelines KFP)
drift:
  ks_alpha: 0.05  # significativité : p-value du test (KS numérique, chi2 catégorielle)
  psi_threshold: 0.25  # magnitude : PSI à partir duquel le déplacement compte
  drift_share: 0.1  # gate : le lot dérive dès que 10 % des colonnes dérivent
  # Scénario simulé (src/simulate.py, pipelines/drift_demo.py), propre au dataset :
  # une clientèle plus jeune, qui emprunte plus et plus longtemps.
  simulation:
    scale:  # facteurs multiplicatifs
      credit_amount: 1.4
      duration: 1.3
    shift:  # décalages, bornés au domaine observé
      age: -8
EOF
```

```python
# Fichier : src/detect_drift.py
"""Détecte un drift entre des données de référence et des données courantes (Lab 3).

    python -m src.detect_drift [reference.csv courant.csv] [--no-fail]
    (défaut : data/processed/train.csv et data/processed/test.csv)

Pour chaque colonne de dataset.yaml (features et cible) :
- significativité : p-value du test de Kolmogorov-Smirnov (numérique) ou du chi2 (catégorielle) ;
- magnitude : PSI (Population Stability Index) et, pour une numérique, distance de
  Wasserstein normalisée (en écarts-types de la référence).
Une colonne dérive si p-value < ks_alpha ET PSI >= psi_threshold : significatif ET important.
Gate : le lot dérive si la part de colonnes en drift atteint drift_share ; code retour 1
(sauf --no-fail). Seuils par défaut : section drift de params.yaml.
Sorties : reports/drift.json, reports/drift.md (tableau) et reports/drift.html (Evidently).
"""

import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd
import yaml
from scipy.stats import chi2_contingency, ks_2samp, wasserstein_distance

from src.dataset_config import DatasetConfig, load_config

REFERENCE_CSV = Path("data/processed/train.csv")
CURRENT_CSV = Path("data/processed/test.csv")
REPORT_JSON = Path("reports/drift.json")
REPORT_MD = Path("reports/drift.md")
REPORT_HTML = Path("reports/drift.html")
BINS = 10  # PSI : déciles de la référence


def psi(ref: pd.Series, cur: pd.Series) -> float:
    """Population Stability Index : < 0,1 stable ; 0,1-0,25 modéré ; > 0,25 drift."""
    ref, cur = ref.dropna(), cur.dropna()
    if pd.api.types.is_numeric_dtype(ref) and ref.nunique() > BINS:
        # Intervalles = déciles de la référence (10 % de la référence dans chacun)
        edges = np.unique(np.quantile(ref, np.linspace(0, 1, BINS + 1)))
        edges[0], edges[-1] = -np.inf, np.inf
        r = np.histogram(ref, edges)[0] / len(ref)
        c = np.histogram(cur, edges)[0] / len(cur)
    else:  # catégorielle, ou numérique à peu de valeurs : une case par modalité
        values = sorted(set(ref) | set(cur), key=str)
        r = ref.value_counts(normalize=True).reindex(values, fill_value=0).to_numpy()
        c = cur.value_counts(normalize=True).reindex(values, fill_value=0).to_numpy()
    r, c = np.clip(r, 1e-4, None), np.clip(c, 1e-4, None)  # éviter log(0)
    return float(np.sum((c - r) * np.log(c / r)))


def column_drift(ref: pd.Series, cur: pd.Series, numeric: bool) -> dict:
    """Test de significativité et mesures de magnitude pour une colonne."""
    if numeric:
        p_value = ks_2samp(ref.dropna(), cur.dropna()).pvalue
        scale = ref.std() or 1.0
        wasserstein = wasserstein_distance(ref.dropna(), cur.dropna()) / scale
        test = "KS"
    else:  # table de contingence modalités x (référence, courant)
        sample = np.repeat(["reference", "courant"], [len(ref), len(cur)])
        table = pd.crosstab(pd.concat([ref, cur]).astype(str).to_numpy(), sample)
        p_value = chi2_contingency(table)[1] if len(table) > 1 else 1.0
        wasserstein, test = None, "chi2"
    return {
        "test": test,
        "p_value": float(p_value),
        "psi": psi(ref, cur),
        "wasserstein": None if wasserstein is None else float(wasserstein),
    }


def numeric_columns(cfg: DatasetConfig, ref: pd.DataFrame) -> list:
    """Colonnes traitées comme numériques : numériques du contrat (et sensibles numériques)."""
    return [
        c for c in cfg.columns
        if c not in (cfg.target, *cfg.categorical) and pd.api.types.is_numeric_dtype(ref[c])
    ]  # fmt: skip


def detect(cfg: DatasetConfig, ref, cur, ks_alpha: float, psi_threshold: float) -> list:
    """Une ligne par colonne du contrat : statistiques et verdict."""
    numeric = numeric_columns(cfg, ref)
    rows = []
    for col in cfg.columns:
        stats = column_drift(ref[col], cur[col], col in numeric)
        drift = stats["p_value"] < ks_alpha and stats["psi"] >= psi_threshold
        rows.append({"column": col, **stats, "drift": drift})
    return rows


def evidently_report(cfg: DatasetConfig, ref, cur, drift_share: float, path: Path) -> dict:
    """Rapport HTML Evidently (DataDriftPreset) ; renvoie son propre verdict pour comparer."""
    from evidently import DataDefinition, Dataset, Report
    from evidently.presets import DataDriftPreset

    numeric = numeric_columns(cfg, ref)
    definition = DataDefinition(
        numerical_columns=numeric,
        categorical_columns=[c for c in cfg.columns if c not in numeric],
    )
    report = Report([DataDriftPreset(columns=cfg.columns, drift_share=drift_share)])
    snapshot = report.run(
        Dataset.from_pandas(cur[cfg.columns], data_definition=definition),
        Dataset.from_pandas(ref[cfg.columns], data_definition=definition),
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    snapshot.save_html(str(path))
    count = snapshot.dict()["metrics"][0]["value"]  # DriftedColumnsCount
    return {"drifted_columns": int(count["count"]), "share": round(float(count["share"]), 4)}


def markdown(rows: list, summary: dict) -> str:
    """Tableau des statistiques par colonne (affiché par l'UI Kubeflow)."""
    lines = [
        f"### Drift : {summary['n_drifted']}/{summary['n_columns']} colonnes "
        f"({'DRIFT' if summary['drift_detected'] else 'pas de drift'})",
        "",
        "| Colonne | Test | p-value | PSI | Wasserstein | Verdict |",
        "|---|---|---|---|---|---|",
    ]
    for r in sorted(rows, key=lambda r: -r["psi"]):
        w = "" if r["wasserstein"] is None else f"{r['wasserstein']:.3f}"
        lines.append(
            f"| {r['column']} | {r['test']} | {r['p_value']:.4f} | {r['psi']:.3f} | {w} "
            f"| {'DRIFT' if r['drift'] else 'OK'} |"
        )
    return "\n".join(lines) + "\n"


def main() -> int:
    defaults = yaml.safe_load(Path("params.yaml").read_text(encoding="utf-8"))["drift"]
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("reference", nargs="?", default=str(REFERENCE_CSV))
    parser.add_argument("current", nargs="?", default=str(CURRENT_CSV))
    parser.add_argument("--ks-alpha", type=float, default=defaults["ks_alpha"])
    parser.add_argument("--psi-threshold", type=float, default=defaults["psi_threshold"])
    parser.add_argument("--drift-share", type=float, default=defaults["drift_share"])
    parser.add_argument("--no-fail", action="store_true", help="drift signalé, code retour 0")
    args = parser.parse_args()

    cfg = load_config()
    ref, cur = pd.read_csv(args.reference), pd.read_csv(args.current)
    rows = detect(cfg, ref, cur, args.ks_alpha, args.psi_threshold)
    drifted = [r["column"] for r in rows if r["drift"]]
    share = len(drifted) / len(rows)
    summary = {
        "drift_detected": share >= args.drift_share,
        "n_columns": len(rows),
        "n_drifted": len(drifted),
        "share_drifted": round(share, 4),
        "drifted": drifted,
        "thresholds": {
            "ks_alpha": args.ks_alpha,
            "psi_threshold": args.psi_threshold,
            "drift_share": args.drift_share,
        },
        "rows": {"reference": len(ref), "current": len(cur)},
        "evidently": evidently_report(cfg, ref, cur, args.drift_share, REPORT_HTML),
        "columns": rows,
    }
    REPORT_JSON.parent.mkdir(parents=True, exist_ok=True)
    REPORT_JSON.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", "utf-8")
    REPORT_MD.write_text(markdown(rows, summary), encoding="utf-8")
    print(markdown(rows, summary))
    print(f"Evidently (p-value seule) : {summary['evidently']['drifted_columns']} colonne(s)")
    verdict = "DRIFT DÉTECTÉ" if summary["drift_detected"] else "pas de drift"
    print(f"{verdict} : {drifted} ({share:.0%} des colonnes, seuil {args.drift_share:.0%})")
    return 1 if summary["drift_detected"] and not args.no_fail else 0


if __name__ == "__main__":
    raise SystemExit(main())
```

Points clés :

- **Deux questions par colonne.** Est-ce significatif ? (p-value du test de
  Kolmogorov-Smirnov pour une numérique, du χ² pour une catégorielle). Est-ce important ?
  (PSI : < 0,1 stable, 0,1 à 0,25 modéré, > 0,25 drift ; et la distance de Wasserstein en
  écarts-types, pour se représenter le déplacement). Une colonne n'est déclarée en drift que si
  les **deux** réponses sont oui : un test statistique donne la significativité, pas
  l'importance (cours, diapo 12).
- Le PSI découpe une numérique en **déciles de la référence** (10 % de la référence dans chaque
  case) ; une catégorielle, ou une numérique à quelques valeurs, a une case par modalité.
- **Gate :** le lot dérive dès que 10 % des colonnes dérivent (`drift_share`, même règle que
  l'option du même nom d'Evidently) ; code retour 1, sauf `--no-fail`.
- **Evidently 0.7** produit le rapport HTML : `Report([DataDriftPreset(…)])`, des `Dataset`
  construits avec une `DataDefinition` (numériques, catégorielles), `report.run(courant,
  référence)` qui renvoie un *snapshot*, et `snapshot.save_html(…)`. Son propre verdict (une
  p-value par colonne, sans magnitude) est rangé dans le JSON pour comparer.

```bash
python -m src.detect_drift; echo "Code retour : $?"
```

> **Sortie attendue :** le tableau des 21 colonnes (entraînement contre test), toutes `OK`, la
> plus déplacée étant `purpose` (p-value 0,1163, PSI 0,073), puis
> `Evidently (p-value seule) : 2 colonne(s)`, `pas de drift : [] (0% des colonnes, seuil 10%)` et
> `Code retour : 0`.

> [!WARNING]
> **Le piège des p-values, en vrai**
> Le split du Lab 1 est aléatoire et stratifié : il n'y a, par construction, aucun drift entre
> entraînement et test. Evidently signale pourtant `purpose` et `employment` (ouvrez
> `reports/drift.html`). Son test du χ² compare les effectifs du lot courant aux proportions de
> la référence, tenues pour exactes ; avec des modalités rares (`purpose` en a 10), la p-value
> s'effondre (0,003). Notre test compare les deux échantillons (p-value 0,12) et, surtout,
> exige un PSI d'au moins 0,25 : ici 0,07. Toujours accompagner un test d'une mesure de
> magnitude.

### 5.2 Simuler un drift et le détecter

Le scénario de `params.yaml` (`drift.simulation`) décrit une nouvelle clientèle : montants
×1,4, durées ×1,3, et 8 ans de moins (sans sortir des âges observés). Appliquons-le au jeu de
test et comparons-le à l'entraînement :

```bash
python -m src.simulate drift data/processed/test.csv /tmp/test_drifted.csv
python -m src.validate_data /tmp/test_drifted.csv | grep -E '"(success|n_failed)"'
python -m src.detect_drift data/processed/train.csv /tmp/test_drifted.csv; echo "Code retour : $?"
```

> **Sortie attendue :** `drift : 200 lignes -> /tmp/test_drifted.csv`, puis `"success": true`
> et `"n_failed": 0` : les données déplacées respectent toujours le contrat ! Puis
> `### Drift : 3/21 colonnes (DRIFT)` avec, en tête du tableau, `duration` (PSI 0,889),
> `age` (0,781) et `credit_amount` (0,398), p-values à 0,0000 ;
> `Evidently (p-value seule) : 5 colonne(s)` ;
> `DRIFT DÉTECTÉ : ['duration', 'credit_amount', 'age'] (14% des colonnes, seuil 10%)` et
> `Code retour : 1`. Ouvrez `reports/drift.html` : les histogrammes de référence et courant
> sont nettement décalés pour ces trois colonnes.

### 5.3 Le composant `detect_drift` et le pipeline de démonstration

Ajoutez ce composant dans `pipelines/components.py`, après `prepare_features` :

```python
# pipelines/components.py — à ajouter après prepare_features
@dsl.component(base_image=PIPELINE_IMAGE, install_kfp_package=False)
def detect_drift(
    reference_data: Input[Dataset],
    current_data: Input[Dataset],
    report: Output[Artifact],
    table: Output[Markdown],
    html: Output[HTML],
    drift: Output[Metrics],
    ks_alpha: float,
    psi_threshold: float,
    drift_share: float,
    fail_on_drift: bool,
) -> bool:
    """Gate : python -m src.detect_drift ; renvoie True si les données courantes dérivent."""
    import json
    from pathlib import Path

    from pipelines.stage import run_stage
    from src.detect_drift import REPORT_HTML, REPORT_JSON, REPORT_MD

    reference, current = "data/drift/reference.csv", "data/drift/current.csv"
    run_stage(
        "src.detect_drift",
        args=[reference, current, "--ks-alpha", ks_alpha, "--psi-threshold", psi_threshold,
              "--drift-share", drift_share, *([] if fail_on_drift else ["--no-fail"])],
        inputs={reference: reference_data.path, current: current_data.path},
        outputs={str(REPORT_JSON): report.path, str(REPORT_MD): table.path,
                 str(REPORT_HTML): html.path},
    )  # fmt: skip
    summary = json.loads(Path(report.path).read_text())
    for name in ("n_columns", "n_drifted", "share_drifted"):
        drift.log_metric(name, summary[name])
    drift.log_metric("evidently_drifted_columns", summary["evidently"]["drifted_columns"])
    return bool(summary["drift_detected"])
```

- 4 sorties : le résumé JSON, le tableau des statistiques (`Markdown`, affiché par l'UI), le
  rapport Evidently (`HTML`) et les métriques.
- Les seuils sont des paramètres **sans valeur par défaut** : chaque pipeline les lit dans
  `params.yaml` à la compilation (comme les hyper-paramètres au Lab 2).
- `fail_on_drift` choisit entre gate bloquant et simple signalement ; le composant **renvoie**
  le verdict (`True` si drift) : le Lab 6 s'en servira pour déclencher un ré-entraînement.

```python
# Fichier : pipelines/drift_demo.py
"""Démonstration de drift (Lab 3) : une nouvelle clientèle comparée à celle d'entraînement.

ingest -> prepare -> simulate_drift (test déplacé) -> detect_drift (train vs test déplacé)
Le scénario est dans params.yaml (drift.simulation). Par défaut le drift est signalé sans
bloquer (fail_on_drift=False) : le run réussit et le rapport montre le drift.
Compilation : python -m pipelines.drift_demo   (écrit drift_demo.yaml)
"""

from pathlib import Path

import yaml
from kfp import compiler, dsl
from kfp.dsl import Dataset, Input, Output

from pipelines.components import PIPELINE_IMAGE, detect_drift, ingest_data, prepare_features

DRIFT = yaml.safe_load(Path("params.yaml").read_text(encoding="utf-8"))["drift"]


@dsl.component(base_image=PIPELINE_IMAGE, install_kfp_package=False)
def simulate_drift(data: Input[Dataset], drifted: Output[Dataset]) -> None:
    """Déplace les données selon le scénario de params.yaml (python -m src.simulate drift)."""
    from pipelines.stage import run_stage

    clean, shifted = "data/drift/clean.csv", "data/drift/drifted.csv"
    run_stage(
        "src.simulate",
        args=["drift", clean, shifted],
        inputs={clean: data.path},
        outputs={shifted: drifted.path},
    )


@dsl.pipeline(name="scoring-drift-demo", description="Drift simulé détecté par detect_drift")
def drift_pipeline(
    ks_alpha: float = DRIFT["ks_alpha"],
    psi_threshold: float = DRIFT["psi_threshold"],
    drift_share: float = DRIFT["drift_share"],
    fail_on_drift: bool = False,  # True : le drift fait échouer le run (gate)
):
    ingest_task = ingest_data()
    prep_task = prepare_features(raw_data=ingest_task.outputs["raw_data"])
    drifted_task = simulate_drift(data=prep_task.outputs["test_data"])
    drift_task = detect_drift(
        reference_data=prep_task.outputs["train_data"],
        current_data=drifted_task.outputs["drifted"],
        ks_alpha=ks_alpha,
        psi_threshold=psi_threshold,
        drift_share=drift_share,
        fail_on_drift=fail_on_drift,
    )
    drift_task.set_memory_limit("1Gi")


if __name__ == "__main__":
    compiler.Compiler().compile(drift_pipeline, package_path="drift_demo.yaml")
```

```bash
python -m pipelines.drift_demo
python - <<'EOF'
from kfp import local

from pipelines.drift_demo import drift_pipeline

local.init(runner=local.SubprocessRunner(use_venv=False))
drift_pipeline()
EOF
```

> **Sortie attendue :** les 4 tâches en `SUCCESS` en une quinzaine de secondes ; le log de
> `detect-drift` affiche le tableau et `DRIFT DÉTECTÉ : ['duration', 'credit_amount', 'age']`,
> puis `Pipeline 'scoring-drift-demo' finished with status SUCCESS` : le drift est signalé sans
> bloquer (`fail_on_drift=False`). Le run sur le cluster viendra avec l'image 1.2.0 (6.4).

Dans le pipeline principal, le même composant devient un **gate** entre la préparation et
l'entraînement : il compare le jeu de test au jeu d'entraînement (`fail_on_drift=True`). Si le
test ne ressemble pas à l'entraînement, l'évaluation ne dirait rien du modèle. On le branche à
l'étape 6, avec le pipeline final.

## Étape 6/7 — Ajouter un composant `validate_model` : Evidently et tests comportementaux (20 min)

Après l'entraînement, on veut vérifier que le modèle lui-même se comporte bien : pas
d'overfit majeur, une performance suffisante partout (pas seulement en moyenne), et des
réactions cohérentes quand on modifie une demande.

> [!NOTE]
> **Pourquoi pas Deepchecks ?**
> Le cours (diapo 16) présente Deepchecks. Sa dernière version (0.19.1) ne fonctionne plus avec
> les bibliothèques du cours : scikit-learn ≥ 1.8 a supprimé le scorer `max_error` qu'elle
> utilise, et NumPy 2 la constante `np.Inf`. On la remplace par Evidently (rapport et tests de
> classification) et par des tests comportementaux écrits en pytest, plus explicites.

### 6.1 Les tests comportementaux

Les tests du cours (diapo 15, d'après CheckList) s'écrivent très bien en pytest. Ce qui est
propre au dataset (quelles colonnes, dans quel sens) va dans un petit fichier de configuration,
à côté des tests :

```yaml
# Fichier : tests/behavior.yaml
# Attentes comportementales du modèle, PROPRES AU DATASET, lues par
# tests/test_model_behavior.py. Changer de dataset = réécrire ce fichier.

# Invariance : changer cet attribut ne devrait pas changer la décision (aucun
# effet attendu sur le risque). Tolérance : part maximale de décisions qui
# changent, parmi les demandes dont on a modifié la valeur.
invariance:
  - column: residence_since  # ancienneté dans le logement actuel (1 à 4)
    max_flip_rate: 0.05

# Directionnels : augmenter la variable (x factor) ne doit pas déplacer le
# risque prédit (probabilité de la classe positive) dans le mauvais sens.
directional:
  - column: credit_amount  # emprunter 50 % de plus ne rend pas plus sûr
    factor: 1.5
    expect: increase
  - column: duration  # rembourser 50 % plus longtemps non plus
    factor: 1.5
    expect: increase
# Une variation de probabilité plus petite que `tolerance` est ignorée (bruit des
# modèles à arbres) ; au plus `max_violation_rate` des demandes peuvent violer l'attente.
tolerance: 0.05
max_violation_rate: 0.05

# Sous-groupes sensibles de dataset.yaml : chaque groupe d'au moins
# `min_group_size` demandes doit lui aussi atteindre promotion_threshold.
# (L'équité au sens strict, écarts entre groupes et mitigation, est l'objet du Lab 8.)
min_group_size: 30
```

```python
# Fichier : tests/test_model_behavior.py
"""Tests comportementaux du modèle (Lab 3), à la manière de CheckList (Ribeiro et al., 2020).

On teste ce que fait le modèle, pas seulement sa métrique globale :
- performance minimale (MFT) : métrique primaire au seuil de dataset.yaml, coût métier
  inférieur à celui des politiques naïves, performance par sous-groupe sensible ;
- invariance (INV) : changer un attribut sans effet attendu ne change pas la décision ;
- directionnels (DIR) : augmenter une variable ne déplace le risque que dans le bon sens.
Modèle testé : models/model (dvc repro, ou step train du pipeline), sur data/processed/test.csv,
au seuil de décision du modèle. Les attentes propres au dataset sont dans tests/behavior.yaml.
Sans modèle local (CI du Lab 6), les tests sont ignorés.
"""

from pathlib import Path

import numpy as np
import pandas as pd
import pytest
import yaml

from src.dataset_config import load_config
from src.train import MODEL_DIR, TEST_CSV, compute_metrics

CFG = load_config()
EXPECT = yaml.safe_load(Path(__file__).with_name("behavior.yaml").read_text(encoding="utf-8"))

pytestmark = pytest.mark.skipif(
    not (MODEL_DIR / "MLmodel").exists() or not TEST_CSV.exists(),
    reason="pas de modèle local : dvc pull ou dvc repro (Lab 1)",
)


@pytest.fixture(scope="module")
def model():
    """Le modèle (Pipeline scikit-learn) et son seuil de décision (métadonnées MLflow)."""
    import mlflow
    from mlflow.models import Model

    threshold = Model.load(str(MODEL_DIR)).metadata["decision_threshold"]
    return mlflow.sklearn.load_model(str(MODEL_DIR)), threshold


@pytest.fixture(scope="module")
def data():
    """Features, cible 0/1 et fichier brut du jeu de test (pour les groupes sensibles)."""
    X, y = CFG.read_xy(TEST_CSV)
    return X, y, pd.read_csv(TEST_CSV)


def risk(model, X: pd.DataFrame) -> np.ndarray:
    """Le risque prédit : probabilité de la classe positive de dataset.yaml."""
    return model[0].predict_proba(X)[:, 1]


# --- Performance minimale (MFT) -------------------------------------------------------------
def test_metrique_primaire_au_seuil(model, data):
    X, y, _ = data
    value = compute_metrics(CFG, y, risk(model, X), model[1])[CFG.primary_metric]
    assert value >= CFG.promotion_threshold, (
        f"{CFG.primary_metric} = {value:.3f} < {CFG.promotion_threshold}"
    )


def test_cout_metier_inferieur_aux_politiques_naives(model, data):
    """Mieux que « tout accorder » et que « tout refuser » (matrice de coûts)."""
    X, y, _ = data
    cost = CFG.business_cost(y, risk(model, X) >= model[1])
    naive = min(CFG.business_cost(y, np.zeros(len(y))), CFG.business_cost(y, np.ones(len(y))))
    assert cost < naive, f"coût {cost:.0f} >= coût de la meilleure politique naïve {naive:.0f}"


@pytest.mark.parametrize("attribute", CFG.sensitive, ids=lambda s: s.column)
def test_performance_par_sous_groupe(model, data, attribute):
    X, y, raw = data
    proba, groups = risk(model, X), attribute.groups(raw).to_numpy()
    scores = {}
    for group in np.unique(groups):
        mask = groups == group
        if mask.sum() >= EXPECT["min_group_size"] and y[mask].nunique() == 2:
            metrics = compute_metrics(CFG, y[mask], proba[mask], model[1])
            scores[group] = round(metrics[CFG.primary_metric], 3)
    if not scores:
        pytest.skip(f"aucun groupe d'au moins {EXPECT['min_group_size']} demandes")
    below = {g: s for g, s in scores.items() if s < CFG.promotion_threshold}
    assert not below, f"{CFG.primary_metric} < {CFG.promotion_threshold} : {below}"


# --- Invariance (INV) -----------------------------------------------------------------------
@pytest.mark.parametrize("case", EXPECT.get("invariance") or [], ids=lambda c: c["column"])
def test_invariance(model, data, case):
    X, _, _ = data
    col, decision = case["column"], risk(model, X) >= model[1]
    flips = changed = 0
    for value in X[col].unique():  # chaque demande reçoit chacune des autres valeurs
        modified = X.assign(**{col: value})
        mask = (X[col] != value).to_numpy()
        flips += int(((risk(model, modified) >= model[1]) != decision)[mask].sum())
        changed += int(mask.sum())
    rate = flips / changed
    assert rate <= case["max_flip_rate"], f"{rate:.1%} des décisions changent avec {col}"


# --- Directionnels (DIR) --------------------------------------------------------------------
@pytest.mark.parametrize("case", EXPECT.get("directional") or [], ids=lambda c: c["column"])
def test_directionnel(model, data, case):
    X, _, _ = data
    modified = X.assign(**{case["column"]: X[case["column"]] * case["factor"]})
    delta = risk(model, modified) - risk(model, X)
    sign = 1 if case["expect"] == "increase" else -1
    violations = float(np.mean(sign * delta < -EXPECT["tolerance"]))
    assert violations <= EXPECT["max_violation_rate"], (
        f"{violations:.1%} des demandes : risque dans le mauvais sens"
    )
```

| Famille (CheckList) | Test | Ce qu'il vérifie sur German Credit |
|---|---|---|
| Performance minimale (MFT) | `test_metrique_primaire_au_seuil` | ROC AUC de test ≥ 0,70 (`promotion_threshold`) |
| | `test_cout_metier_inferieur_aux_politiques_naives` | coût 5×FN + 1×FP < coût de « tout refuser » (140) et de « tout accorder » (300) |
| | `test_performance_par_sous_groupe` | ROC AUC ≥ 0,70 pour chaque groupe d'au moins 30 demandes de `age`, `personal_status`, `foreign_worker` |
| Invariance (INV) | `test_invariance[residence_since]` | au plus 5 % de décisions changent avec l'ancienneté dans le logement |
| Directionnels (DIR) | `test_directionnel[credit_amount]`, `[duration]` | ×1,5 ne fait pas baisser le risque (tolérance 0,05) |

```bash
python -m pytest -q tests/test_model_behavior.py
```

> **Sortie attendue :** `8 passed` en 3 secondes environ.

> [!NOTE]
> **Équité : ce test n'est qu'un plancher**
> `test_performance_par_sous_groupe` vérifie que chaque groupe sensible atteint le seuil ; il
> ne mesure ni les écarts entre groupes ni leurs causes. L'équité au sens strict (parité
> démographique, égalité des chances, mitigation) est l'objet du Lab 8. Les groupes de moins de
> 30 demandes (`foreign_worker = no` : 6 demandes au test) ne sont pas évalués.

### 6.2 Le rapport Evidently et le gate du modèle

```python
# Fichier : src/validate_model.py
"""Valide le modèle entraîné avant son enregistrement (gate du Lab 3).

    python -m src.validate_model      (models/model, data/processed/train.csv et test.csv)

1. Evidently (ClassificationPreset) sur le jeu de test, au seuil de décision du modèle,
   avec le jeu d'entraînement en référence et deux tests explicites :
   - la métrique primaire de dataset.yaml atteint promotion_threshold ;
   - la ROC AUC de test ne s'écarte pas de plus de 20 % de celle d'entraînement
     (sur-apprentissage).
2. Les tests comportementaux de tests/test_model_behavior.py (pytest).
Code retour 1 si un test échoue. Sorties : reports/model_validation.json, .md, .html.
"""

import json
from pathlib import Path
from xml.etree import ElementTree

import mlflow
import pandas as pd
import pytest
from mlflow.models import Model

from src.dataset_config import DatasetConfig, load_config
from src.train import MODEL_DIR, TEST_CSV, TRAIN_CSV, compute_metrics

ROOT = Path(__file__).resolve().parents[1]
BEHAVIOR_TESTS = ROOT / "tests" / "test_model_behavior.py"
REPORT_JSON = Path("reports/model_validation.json")
REPORT_MD = Path("reports/model_validation.md")
REPORT_HTML = Path("reports/model_validation.html")
JUNIT_XML = Path("reports/model_behavior.xml")
MAX_TRAIN_TEST_GAP = 0.2  # écart relatif de ROC AUC toléré entre entraînement et test
# Métriques de dataset.yaml que le preset sait tester (nom de l'argument « <x>_tests »)
EVIDENTLY_NAMES = {
    "roc_auc": "rocauc",
    "f1": "f1score",
    "precision": "precision",
    "recall": "recall",
    "accuracy": "accuracy",
}
PRESET_METRICS = ["accuracy", "precision", "recall", "f1score", "rocauc", "logloss",
                  "tpr", "tnr", "fpr", "fnr"]  # fmt: skip


def evidently_checks(cfg: DatasetConfig, model, threshold: float) -> list:
    """Rapport Evidently (HTML) et résultat de ses tests."""
    from evidently import BinaryClassification, DataDefinition, Dataset, Report
    from evidently.presets import ClassificationPreset
    from evidently.tests import Reference, eq, gte

    definition = DataDefinition(
        classification=[BinaryClassification(target="target", prediction_probas="proba",
                                             pos_label=1)]
    )  # fmt: skip

    def dataset(path: Path) -> Dataset:
        X, y = cfg.read_xy(path)
        frame = pd.DataFrame({"target": y.to_numpy(), "proba": model.predict_proba(X)[:, 1]})
        return Dataset.from_pandas(frame, data_definition=definition)

    # Tests explicites seulement. Une liste vide désactive le test par défaut d'Evidently
    # (« mieux qu'un modèle naïf »), inadapté au seuil coût-optimal : accuracy, TNR et FPR
    # y sont volontairement moins bonnes que celles d'un modèle qui accorde tout.
    tests = {f"{name}_tests": [] for name in PRESET_METRICS}
    tests["rocauc_tests"] = [eq(Reference(relative=MAX_TRAIN_TEST_GAP))]  # vs entraînement
    if cfg.primary_metric in EVIDENTLY_NAMES:
        name = EVIDENTLY_NAMES[cfg.primary_metric]
        tests[f"{name}_tests"].append(gte(cfg.promotion_threshold))

    report = Report([ClassificationPreset(probas_threshold=threshold, **tests)])
    snapshot = report.run(dataset(TEST_CSV), dataset(TRAIN_CSV))  # courant, référence
    REPORT_HTML.parent.mkdir(parents=True, exist_ok=True)
    snapshot.save_html(str(REPORT_HTML))
    return [
        {"name": t["name"], "success": getattr(t["status"], "value", t["status"]) == "SUCCESS"}
        for t in snapshot.dict()["tests"]
    ]


def behavior_checks() -> list:
    """Lance pytest sur les tests comportementaux ; un résultat par test (rapport JUnit)."""
    JUNIT_XML.parent.mkdir(parents=True, exist_ok=True)
    quiet = ["-q", "-p", "no:cacheprovider", "-W", "ignore::pytest.PytestAssertRewriteWarning"]
    code = pytest.main([*quiet, str(BEHAVIOR_TESTS), f"--junitxml={JUNIT_XML}"])
    if code not in (pytest.ExitCode.OK, pytest.ExitCode.TESTS_FAILED):
        return [{"name": f"pytest : code retour {int(code)}", "success": False}]
    return [
        {
            "name": case.get("name"),
            "success": case.find("failure") is None and case.find("error") is None,
            "skipped": case.find("skipped") is not None,
        }
        for case in ElementTree.parse(JUNIT_XML).getroot().iter("testcase")
    ]


def markdown(summary: dict) -> str:
    """Tableau des tests (affiché par l'UI Kubeflow)."""
    lines = [
        f"### Validation du modèle : {summary['n_failed']} échec(s) sur {summary['n_checks']}",
        "",
        "| Famille | Test | Statut |",
        "|---|---|---|",
    ]
    for family in ("evidently", "behavior"):
        for c in summary[family]:
            status = "ignoré" if c.get("skipped") else ("OK" if c["success"] else "ÉCHEC")
            lines.append(f"| {family} | {c['name']} | {status} |")
    return "\n".join(lines) + "\n"


def main() -> int:
    cfg = load_config()
    model = mlflow.sklearn.load_model(str(MODEL_DIR))
    threshold = Model.load(str(MODEL_DIR)).metadata["decision_threshold"]
    X, y = cfg.read_xy(TEST_CSV)
    metrics = compute_metrics(cfg, y, model.predict_proba(X)[:, 1], threshold)

    evidently, behavior = evidently_checks(cfg, model, threshold), behavior_checks()
    failed = [c["name"] for c in [*evidently, *behavior] if not c["success"]]
    summary = {
        "success": not failed,
        "n_checks": len(evidently) + len(behavior),
        "n_failed": len(failed),
        "failed": failed,
        cfg.primary_metric: round(float(metrics[cfg.primary_metric]), 4),
        "decision_threshold": round(threshold, 4),
        "evidently": evidently,
        "behavior": behavior,
    }
    REPORT_JSON.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", "utf-8")
    REPORT_MD.write_text(markdown(summary), encoding="utf-8")
    print(markdown(summary))
    print("Modèle VALIDÉ" if not failed else f"Modèle REFUSÉ : {failed}")
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
```

Points clés :

- Le preset `ClassificationPreset` d'Evidently 0.7 calcule les métriques **au seuil de décision
  du modèle** (`probas_threshold`, le seuil coût-optimal du Lab 1), sur le jeu de test, avec le
  jeu d'entraînement en référence : le rapport les montre côte à côte (matrices de confusion,
  courbes ROC et précision-rappel).
- Les tests s'attachent aux métriques : `gte(0.7)` (la ROC AUC atteint le seuil de
  `dataset.yaml`) et `eq(Reference(relative=0.2))` (elle reste à ±20 % de celle
  d'entraînement : pas de sur-apprentissage majeur). Ils figurent dans `snapshot.dict()["tests"]`.
- Les **tests par défaut** d'Evidently (« mieux qu'un modèle naïf » sans référence, ±20 % sur
  chaque métrique avec référence) sont désactivés par des listes vides : avec un seuil qui
  minimise le coût métier, l'accuracy, le TNR et le FPR sont volontairement moins bons que ceux
  d'un modèle qui accorde tout, et ces tests échoueraient.

```bash
python -m src.validate_model; echo "Code retour : $?"
```

> **Sortie attendue :** d'abord la sortie de pytest (`8 passed`), puis
> `### Validation du modèle : 0 échec(s) sur 10`, le tableau (deux tests
> `evidently` : `RocAuc metric: Equal 0.827 ± 0.165` et `RocAuc metric: Greater or Equal 0.700`,
> puis les 8 tests `behavior`, tous `OK`), `Modèle VALIDÉ` et `Code retour : 0`. Ouvrez
> `reports/model_validation.html`.

> [!TIP]
> **Ce que le gate refuse**
> Mesuré sur German Credit : le modèle `dummy` échoue à 6 tests (ROC AUC 0,50, coût égal à
> celui de « tout refuser », sous-groupes) ; une forêt sans limite de profondeur
> (`random_forest`, `n_estimators=100`, `max_depth=none`, `class_weight=none`) échoue au test de
> sur-apprentissage (ROC AUC 1,000 à l'entraînement, 0,762 au test) ; le gradient boosting des
> paramètres par défaut (`n_estimators=200`, `max_depth=8`) échoue à 4 tests
> (sur-apprentissage, coût, invariance, directionnel). À essayer en 6.4 : un run avec
> `model_type=dummy` ; `validate-model` échoue et `register-model` n'est jamais lancé.

### 6.3 Le composant `validate_model` et le pipeline final

Ajoutez ce composant dans `pipelines/components.py`, après `evaluate_model` :

```python
# pipelines/components.py — à ajouter après evaluate_model
@dsl.component(base_image=PIPELINE_IMAGE, install_kfp_package=False)
def validate_model(
    model: Input[Model],
    train_data: Input[Dataset],
    test_data: Input[Dataset],
    report: Output[Artifact],
    table: Output[Markdown],
    html: Output[HTML],
    checks: Output[Metrics],
) -> None:
    """Gate : python -m src.validate_model (Evidently + tests comportementaux pytest)."""
    import json
    from pathlib import Path

    from pipelines.stage import run_stage
    from src.dataset_config import load_config
    from src.train import MODEL_DIR, TEST_CSV, TRAIN_CSV
    from src.validate_model import REPORT_HTML, REPORT_JSON, REPORT_MD

    cfg = load_config()
    run_stage(
        "src.validate_model",
        inputs={str(MODEL_DIR): model.path, str(TRAIN_CSV): train_data.path,
                str(TEST_CSV): test_data.path},
        outputs={str(REPORT_JSON): report.path, str(REPORT_MD): table.path,
                 str(REPORT_HTML): html.path},
    )  # fmt: skip
    summary = json.loads(Path(report.path).read_text())
    for name in ("n_checks", "n_failed", cfg.primary_metric):
        checks.log_metric(name, summary[name])
```

Version finale de `pipelines/scoring_pipeline.py`, avec les trois gates :

```python
# Fichier : pipelines/scoring_pipeline.py
"""Pipeline KFP « scoring-pipeline » (Labs 2 et 3).

ingest -> validate_data -> prepare -> detect_drift -> train -> evaluate
                                                            -> validate_model -> register
Trois gates (Lab 3) : contrat de données (Great Expectations), drift entre entraînement et
test, validation du modèle (Evidently + tests comportementaux). Un gate en échec arrête le run.
Compilation : python -m pipelines.scoring_pipeline   (écrit scoring_pipeline.yaml)
Les valeurs par défaut sont lues dans params.yaml AU MOMENT DE LA COMPILATION :
params.yaml reste la seule source des valeurs par défaut, comme pour dvc repro.
"""

from pathlib import Path

import yaml
from kfp import compiler, dsl, kubernetes

from pipelines.components import (
    MLFLOW_URI,
    detect_drift,
    evaluate_model,
    ingest_data,
    prepare_features,
    register_model,
    train_model,
    validate_data,
    validate_model,
)

PARAMS = yaml.safe_load(Path("params.yaml").read_text(encoding="utf-8"))
TRAIN, DRIFT = PARAMS["train"], PARAMS["drift"]


@dsl.pipeline(
    name="scoring-pipeline",
    description="Credit scoring : ingest -> validate -> prepare -> drift -> train -> evaluate"
    " -> validate_model -> register",
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
    ks_alpha: float = DRIFT["ks_alpha"],
    psi_threshold: float = DRIFT["psi_threshold"],
    drift_share: float = DRIFT["drift_share"],
):
    # Source externe (réseau) : 3 nouvelles tentatives, et jamais plus de 10 min
    ingest_task = ingest_data()
    ingest_task.set_retry(num_retries=3, backoff_duration="30s")
    ingest_task.set_cpu_limit("500m").set_memory_limit("512Mi")
    kubernetes.set_timeout(ingest_task, 600)

    # Gate 1 : le contrat de données (suite Great Expectations versionnée dans gx/)
    validate_task = validate_data(raw_data=ingest_task.outputs["raw_data"])
    validate_task.set_memory_limit("1Gi")

    prep_task = prepare_features(raw_data=ingest_task.outputs["raw_data"])
    prep_task.after(validate_task)  # gate : pas de préparation sans validation réussie
    prep_task.set_memory_limit("1Gi")

    # Gate 2 : le jeu de test ressemble-t-il à celui d'entraînement ?
    drift_task = detect_drift(
        reference_data=prep_task.outputs["train_data"],
        current_data=prep_task.outputs["test_data"],
        ks_alpha=ks_alpha,
        psi_threshold=psi_threshold,
        drift_share=drift_share,
        fail_on_drift=True,
    )
    drift_task.set_memory_limit("1Gi")

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
    train_task.after(drift_task)  # gate : pas d'entraînement sur des données qui dérivent
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

    # Gate 3 : le modèle lui-même (Evidently + tests comportementaux)
    model_task = validate_model(
        model=train_task.outputs["model"],
        train_data=prep_task.outputs["train_data"],
        test_data=prep_task.outputs["test_data"],
    )
    model_task.set_memory_limit("1Gi")

    register_task = register_model(run_id=train_task.outputs["Output"], mlflow_uri=mlflow_uri)
    register_task.after(eval_task, model_task)  # on n'enregistre qu'un modèle validé
    register_task.set_memory_limit("1Gi")


if __name__ == "__main__":
    compiler.Compiler().compile(scoring_pipeline, package_path="scoring_pipeline.yaml")
```

- `train_task.after(drift_task)` : pas d'entraînement si le test ne ressemble pas à
  l'entraînement ; `register_task.after(eval_task, model_task)` : on n'enregistre (même en
  `@challenger`) qu'un modèle évalué **et** validé.
- Les seuils de drift deviennent des paramètres du pipeline, lus dans `params.yaml` à la
  compilation, modifiables au lancement d'un run.
- Mémoire mesurée (composant + sous-processus) : environ 450 Mo pour `detect-drift`, 580 Mo pour
  `validate-model`, d'où les limites à 1 Gi.

```bash
python -m pipelines.scoring_pipeline
wc -l scoring_pipeline.yaml
python - <<'EOF'
from kfp import local

from pipelines.scoring_pipeline import scoring_pipeline

local.init(runner=local.SubprocessRunner(use_venv=False))
scoring_pipeline(mlflow_uri="http://localhost:5000")
EOF
```

> **Sortie attendue :** `795 scoring_pipeline.yaml`. En une minute environ, les 8 tâches passent
> en `SUCCESS` : `validate-data` (67 expectations), `detect-drift` (`pas de drift`),
> `validate-model` (`Modèle VALIDÉ`), puis `register-model` (`@champion -> version …`).

### 6.4 Image 1.2.0 et runs sur le cluster

```bash
sed -i 's/scoring-pipeline:1.1.0/scoring-pipeline:1.2.0/' \
    pipelines/components.py dags/scoring_dag.py
docker build -f pipelines/Dockerfile --build-arg VERSION=1.2.0 \
    -t localhost:5001/scoring-pipeline:1.2.0 .
docker push localhost:5001/scoring-pipeline:1.2.0
python -m pipelines.scoring_pipeline
python -m pipelines.drift_demo
grep -c "image: localhost:5001/scoring-pipeline:1.2.0" scoring_pipeline.yaml
```

> **Sortie attendue :** un build de quelques secondes (la couche des dépendances est en
> cache), puis `8`.

Dans l'UI KFP :

- **scoring-pipeline → Upload version** (`scoring_pipeline.yaml`), puis **Create run**.
- **Upload pipeline**, nom `scoring-drift-demo`, fichier `drift_demo.yaml`, puis **Create run**.

> **Sortie attendue :** le run de `scoring-pipeline` affiche 8 steps verts en 5 à 6 minutes ; le
> log de `register-model` annonce une nouvelle version de `scoring-model`. Le run
> `scoring-drift-demo` est vert lui aussi : `detect-drift` signale le drift sans bloquer, sa
> sortie `Output` vaut `true`.

> [!TIP]
> **Sans l'UI**
> Comme au Lab 2, le SDK fait la même chose, par exemple pour la démonstration de drift :
> ```bash
> python - <<'EOF'
> import kfp
>
> client = kfp.Client(host="http://localhost:8080")
> run = client.create_run_from_pipeline_package(
>     "drift_demo.yaml", experiment_name="scoring", run_name="drift-demo-cli"
> )
> print(client.wait_for_run_completion(run.run_id, timeout=1800).state)
> EOF
> ```

> [!NOTE]
> **Vous travaillez sur votre propre dataset ?**
> Le code ne change pas : la suite GX, le drift, Evidently et les tests lisent tout dans
> `dataset.yaml`. Trois choses sont à vous : regénérer la suite (`--build-suite`) et la
> relire (bornes, modalités, taux de la classe positive : est-ce bien votre contrat ?) ;
> réécrire `tests/behavior.yaml` (un attribut sans effet attendu pour l'invariance, les
> variables dont vous connaissez le sens d'effet pour les tests directionnels) ; réécrire le
> scénario `drift.simulation` de `params.yaml` avec vos colonnes. Si votre première variable
> numérique peut être négative, choisissez une autre valeur impossible au test 1.4. Vos
> chiffres seront différents (nombre d'expectations, colonnes en drift, tests par sous-groupe :
> un groupe de moins de 30 lignes est ignoré). Et chaque modification de `gx/`, `tests/` ou
> `params.yaml` demande une nouvelle image : ils sont copiés dedans.

## Étape 7/7 — Exporter les rapports HTML comme artifacts KFP (10 min)

Les rapports HTML sont déjà produits comme `Output[HTML]` (et les tableaux comme
`Output[Markdown]`), donc KFP les affiche dans l'UI. On va vérifier qu'ils sont bien
accessibles.

### 7.1 Naviguer dans les artifacts

- Dans l'UI KFP, ouvrir le run complet de `scoring-pipeline` (étape 6.4).
- Cliquer sur `validate-data` → **Visualization** : le rapport GX (67 expectations).
- Cliquer sur `detect-drift` → **Visualization** : le tableau des statistiques (`table`) et le
  rapport Evidently (`html`) ; onglet **Input/Output** : `n_drifted`, `share_drifted`,
  `evidently_drifted_columns`.
- Cliquer sur `validate-model` → **Visualization** : le tableau des 10 tests et le rapport
  Evidently (matrice de confusion, courbe ROC, entraînement contre test).
- Faire de même sur le run `scoring-drift-demo` : `detect-drift` montre les 3 colonnes en drift.

### 7.2 Télécharger un rapport via le SeaweedFS interne de KFP

Chaque artifact est stocké dans le SeaweedFS interne de KFP (bucket `mlpipeline`), sous
`v2/artifacts/<nom du pipeline>/<id du run>/<step>/…`. Depuis KFP 2.15, SeaweedFS remplace
MinIO : même API S3, licence Apache 2.0, alors que l'édition communautaire de MinIO a été
archivée et ses images retirées de Docker Hub en 2026. Pour y accéder par programme, on ouvre
un port-forward et on lit les identifiants dans le secret de KFP (son nom,
`mlpipeline-minio-artifact`, est un reste de l'époque MinIO) :

```bash
kubectl -n kubeflow port-forward svc/seaweedfs 9090:8333 >/tmp/kfp-s3.log 2>&1 &
KFP_S3_KEY=$(kubectl -n kubeflow get secret mlpipeline-minio-artifact \
    -o jsonpath='{.data.accesskey}' | base64 -d)
KFP_S3_SECRET=$(kubectl -n kubeflow get secret mlpipeline-minio-artifact \
    -o jsonpath='{.data.secretkey}' | base64 -d)
kfp-s3() {
  mkdir -p reports/kfp
  docker run --rm --network host --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$PWD/reports/kfp:/data" -e AWS_ACCESS_KEY_ID="$KFP_S3_KEY" \
    -e AWS_SECRET_ACCESS_KEY="$KFP_S3_SECRET" -e AWS_DEFAULT_REGION=us-east-1 \
    amazon/aws-cli:2.37.9 --endpoint-url http://localhost:9090 "$@"
}
kfp-s3 s3 ls s3://mlpipeline/v2/artifacts/scoring-pipeline/
```

> **Sortie attendue :** une ligne `PRE <id du run>/` par run de `scoring-pipeline`.

Copiez l'identifiant du run de l'étape 6.4 (il est aussi dans l'URL de l'UI :
`…/#/runs/details/<id>`), listez ses rapports HTML et téléchargez celui du drift :

```bash
RUN_ID=<id du run>
kfp-s3 s3 ls --recursive "s3://mlpipeline/v2/artifacts/scoring-pipeline/$RUN_ID/" | grep /html
KEY=$(kfp-s3 s3 ls --recursive "s3://mlpipeline/v2/artifacts/scoring-pipeline/$RUN_ID/" \
    | awk '/detect-drift\/.*\/html$/ {print $4}')
kfp-s3 s3 cp "s3://mlpipeline/$KEY" /data/drift.html
ls -lh reports/kfp/drift.html
```

> **Sortie attendue :** trois clés se terminant par `/html` (`validate-data`, `detect-drift`,
> `validate-model`, chacune sous un dossier intermédiaire propre à l'exécution du step), puis
> `download: s3://mlpipeline/v2/artifacts/scoring-pipeline/<id>/detect-drift/…/html to
> /data/drift.html` et un fichier d'environ 4 Mo, à ouvrir dans le navigateur.

Pour tout récupérer d'un coup (les fichiers s'appellent comme les sorties : `html`, `report`,
`table`…), puis arrêter le port-forward :

```bash
kfp-s3 s3 cp --recursive "s3://mlpipeline/v2/artifacts/scoring-pipeline/$RUN_ID/" "/data/$RUN_ID/"
pkill -f "port-forward svc/seaweedfs"
```

> [!TIP]
> **Pour aller plus loin : Evidently en continu**
> Dans le Module 7 (Monitoring), on complétera cette détection de drift ponctuelle par
> Evidently qui tourne en continu sur le trafic de production, avec des tableaux de bord dans
> Grafana. Le composant KFP d'aujourd'hui reste utile en mode batch : valider un lot de données
> avant un ré-entraînement (Lab 6).

Commitez le travail du lab (le bloc *Lab 3* du `.gitignore`, vu à l'étape 1.5, écarte les
pipelines compilés et les rapports regénérés) :

```bash
git add params.yaml gx/ src/ tests/ pipelines/ dags/scoring_dag.py
git status --short    # ni rapports, ni YAML compilés, ni gx/uncommitted/
git commit -m "feat: gates de validation (GX, drift, modèle) dans scoring-pipeline"
git push -u origin lab/m3-validation
gh pr create   # facultatif (GitHub CLI) : ou « Compare & pull request » sur GitHub
```

Votre partenaire relit la PR (la suite GX en particulier : c'est le contrat de données) et
l'approuve ; vous la fusionnez, puis vous revenez sur `main` : `git switch main && git pull`.

> [!NOTE]
> **Second membre du binôme (ou nouveau poste) : remettre votre cluster à niveau**
> Une fois la PR fusionnée, rejouez l'état de fin de lab sur **votre** cluster (Lab 2 à niveau) :
> la nouvelle image du pipeline et les trois runs n'existent que chez votre partenaire. Les
> vérifications de la suite GX, du drift et des tests comportementaux, elles, sont recalculées
> par `make check-m3` à partir des fichiers commités.
>
> ```bash
> cd ~/mlops-cours-2026 && git switch main && git pull && uv sync
> source .venv/bin/activate && set -a && source .env && set +a
> make kfp-ui
> make pipeline-image                # nouveau tag de l'image (pipelines/components.py)
> for p in scoring_pipeline test_bad_data drift_demo; do python -m "pipelines.$p"; done
> python - <<'EOF'
> import kfp
>
> client = kfp.Client(host="http://localhost:8080")
> for package in ("scoring_pipeline.yaml", "test_bad_data.yaml", "drift_demo.yaml"):
>     run = client.create_run_from_pipeline_package(package, experiment_name="scoring")
>     print(package, client.wait_for_run_completion(run.run_id, timeout=1800).state)
> EOF
> make check-m3
> ```
>
> `test_bad_data.yaml` doit finir en `FAILED` (le gate bloque les données corrompues), les deux
> autres en `SUCCEEDED`. Ne commitez rien de régénéré : les YAML compilés et les rapports sont
> ignorés, `dvc.lock` reste modifié en local (Lab 1).

## Checklist de validation

| # | Élément | Test | Résultat attendu | OK |
|---|---|---|---|---|
| 1 | Suite GE écrite | `python -m src.validate_data` | JSON `success=true`, 67 checks, exit 0 | ☐ |
| 2 | Suite échoue sur corrompu | `python -m src.validate_data /tmp/dataset_bad.csv` | JSON `success=false`, exit 1 | ☐ |
| 3 | Suite versionnée | `git ls-files gx/` | suite, validation, checkpoint ; pas d'`uncommitted/` | ☐ |
| 4 | Composant `validate_data` | `grep -A6 'def validate_data' pipelines/components.py` | sortie `html: Output[HTML]` | ☐ |
| 5 | Images construites | `curl -s localhost:5001/v2/scoring-pipeline/tags/list` | tags `1.1.0` et `1.2.0` | ☐ |
| 6 | Run propre : tout vert | UI KFP | 8 steps en vert | ☐ |
| 7 | Run corrompu : arrêt | UI KFP (`scoring-bad-data-test`) | `validate-data` rouge, `prepare-features` jamais lancé | ☐ |
| 8 | Rapport GE dans l'UI | KFP → `validate-data` → Visualization | tableau des 67 expectations | ☐ |
| 9 | `detect_drift` fonctionne | Run `scoring-drift-demo` | drift sur `duration`, `age`, `credit_amount` | ☐ |
| 10 | Tests comportementaux | `python -m pytest -q tests/test_model_behavior.py` | `8 passed` | ☐ |
| 11 | `validate_model` présent | `grep 'def validate_model' pipelines/components.py` | Fonction présente | ☐ |
| 12 | Rapport Evidently du modèle | KFP → `validate-model` → Visualization | rapport HTML (confusion, ROC) | ☐ |
| 13 | Metrics KFP loguées | KFP → step → Input/Output | `n_failed`, `n_drifted`, `roc_auc` visibles | ☐ |
| 14 | Rapport téléchargé | `ls reports/kfp/` | `drift.html` récupéré depuis SeaweedFS | ☐ |

## Critères d'évaluation (noté sur 20)

| Critère | Description | Points |
|---|---|---|
| Pertinence des expectations | Les checks GE couvrent structure, types, contraintes métier ; générés depuis `dataset.yaml`, pas seulement 2-3 triviaux ; suite versionnée et relue. | 6 |
| Gate bloquant fonctionnel | Le pipeline échoue réellement sur données corrompues (pas juste un warning) : `prepare-features` n'est jamais lancé. | 5 |
| Détection de drift | `detect_drift` utilise KS/χ² + PSI (significativité et magnitude), rapport HTML lisible, seuils configurables (`params.yaml`). | 4 |
| Validation du modèle | `validate_model` dans le pipeline (Evidently avec tests + tests comportementaux) bloque l'enregistrement ; rapport HTML visible dans KFP. | 3 |
| Propreté du code | Code réutilisé dans l'image (pas recopié), imports dans les fonctions, HTML bien formé, metrics logées, aucun nom de colonne en dur. | 2 |
| **Total** | | **20** |

## Annexe — Troubleshooting

| Symptôme | Cause probable | Solution |
|---|---|---|
| `import great_expectations` très lent | GX 1.x s'importe en 3 s environ. Pas un bug. | Normal. Juste attendre. |
| `AttributeError: … has no attribute 'sources'` (ou `add_or_update_expectation_suite`, `run_checkpoint`) | Code écrit pour GX 0.x. | API 1.x : `context.data_sources`, `context.suites`, `ValidationDefinition`, `Checkpoint.run()` (tableau de 1.1). |
| `DataContextRequiredError` en construisant une suite | GX 1.x exige un contexte actif pour `suite.add_expectation()`. | Appeler `gx.get_context()` d'abord (comme `save_suite`, qui crée la suite après le contexte). |
| `Suite absente : lancez python -m src.validate_data --build-suite` | `gx/` pas généré, pas commité, ou absent de l'image. | `--build-suite` (étape 1.3) ; `git add gx/` ; `COPY gx/ gx/` et nouveau tag. |
| `FileNotFoundError: data/processed/train.csv` | Données du Lab 1 absentes. | `dvc pull` (ou `dvc repro`). |
| La suite valide des données corrompues | Moins de 1 % de lignes touchées (`mostly=0.99`), ou suite regénérée depuis les données corrompues. | Corrompre plus de lignes ; ne jamais regénérer la suite depuis les données à valider. |
| `expect_column_values_to_be_in_set` échoue sur de nouvelles données | Une modalité inconnue de l'entraînement est apparue. | Décision humaine : corriger la source, ou faire évoluer le contrat (`--build-suite` sur un nouveau jeu d'entraînement validé, revue du `git diff gx/`). |
| Step `validate-data` en `OOMKilled` | Limite du Lab 2 (512 Mi) trop basse pour GX. | `validate_task.set_memory_limit("1Gi")` (étape 3.1). |
| `ModuleNotFoundError: great_expectations` (ou `evidently`) dans un pod | Le pipeline utilise encore l'image `1.0.0`. | Tag mis à jour dans `components.py`, image poussée, pipeline recompilé et nouvelle version uploadée. |
| `pytest` : `ModuleNotFoundError: No module named 'src'` | `pytest` lancé hors de la racine du repo : le `pythonpath` déclaré dans `pyproject.toml` ne s'applique pas. | Depuis la racine du repo : `python -m pytest …` (ou `uv run pytest …`). |
| Tous les tests comportementaux `skipped` | Pas de modèle local (`models/model`). | `dvc pull` ou `dvc repro` (Lab 1). |
| Evidently : `AttributeError: 'list' object has no attribute 'items'` | `ClassificationPreset(include_tests=False)` : bogue d'Evidently 0.7.23. | Désactiver les tests métrique par métrique avec des listes vides, comme `src/validate_model.py`. |
| Evidently : `TNR metric: Greater …` ou `FPR metric: Less …` en `FAIL` | Tests par défaut (« mieux qu'un modèle naïf »), inadaptés au seuil coût-optimal. | Tests explicites seulement (étape 6.2). |
| Erreurs de Deepchecks (`np.Inf`, `max_error`) | Deepchecks 0.19 incompatible avec NumPy 2 et scikit-learn ≥ 1.8. | Abandonné : Evidently + pytest (étape 6). |
| `prep_task` démarre avant `validate` | `.after()` oublié. | Ajouter explicitement `prep_task.after(validate_task)`. |
| Un `sys.exit(1)` ne bloque pas le step | L'erreur a été attrapée dans le composant (`try/except` sans `raise`). | Laisser l'exception remonter : `run_stage` lève `CalledProcessError`, le step échoue. |
| HTML artifact ne s'affiche pas | Plusieurs fichiers (Data Docs), encodage, ou fichier très lourd. | Un seul fichier qui commence par `<!DOCTYPE html>`, en UTF-8 ; le rapport Evidently (≈ 4 Mo) met quelques secondes à s'afficher. |
| Pas de rapport HTML sur le step `validate-data` en échec | KFP ne publie les sorties que des steps réussis. | Lire les logs du step ; ou rejouer en local (`kfp.local`, rapport dans `local_outputs/`). |
| KS p-value toujours très basse | Gros dataset (100k+ lignes) : KS est très sensible. | Normal : c'est pourquoi le verdict exige aussi un PSI ≥ 0,25. |
| PSI donne des valeurs extrêmes | Cases vides ou trop fines. | Cases = déciles de la référence ; ε = 1e-4 pour les cases vides ; une case par modalité pour les variables discrètes. |
| Evidently signale un drift que le tableau ne confirme pas | Verdict d'Evidently sur la seule p-value. | Comparer avec la colonne PSI ; `DataDriftPreset(method="psi")` pour un verdict par magnitude. |
| `detect-drift` échoue dans `scoring-pipeline` | Le test ne ressemble pas à l'entraînement (petit dataset, split non stratifié). | Lire le tableau (`table`) ; revoir le split ; ajuster les seuils de `params.yaml` en le justifiant. |
| `aws` : `Could not connect to the endpoint URL` | Port-forward vers SeaweedFS absent. | `kubectl -n kubeflow port-forward svc/seaweedfs 9090:8333 &` |
| `aws` : `InvalidAccessKeyId` | Identifiants du S3 du cours (`mlops`) au lieu de ceux de KFP. | Lire le secret `mlpipeline-minio-artifact` (étape 7.2). |
| `aws s3 ls` ne renvoie rien | Mauvais préfixe. | `v2/artifacts/<nom du pipeline>/<id du run>/` ; vérifier l'id dans l'URL de l'UI. |

## Pour aller plus loin

- **Un rapport même quand le gate bloque** : séparer contrôle et décision. Le composant de
  validation réussit toujours, publie son rapport et renvoie `passed: bool` ; la suite du
  pipeline est placée sous `with dsl.If(validate_task.output == True):` et une branche
  `dsl.Else()` lance un petit composant qui échoue avec le motif. Le run est rouge, et le
  rapport HTML reste visible.
- **Sévérité des expectations** : GX 1.x accepte `severity="warning"` sur une expectation ;
  `ExpectationSuiteValidationResult.get_max_severity_failure()` permet de ne bloquer que sur
  les échecs `critical`.
- **L'invariance qui échoue** : ajoutez `own_telephone` (avec `max_flip_rate: 0.05`) dans
  `tests/behavior.yaml` : 9 % des décisions changent. Le modèle utilise un indicateur de
  richesse des années 1970 ; faut-il le garder ? (Le Lab 8 outillera ce genre de discussion.)
- **Le gate dans DVC** : ajouter une stage `validate` à `dvc.yaml` (`python -m
  src.validate_data`, dépendances `data/raw/dataset.csv` et `gx/`) et faire dépendre
  `prepare` de son rapport : `dvc repro` refusera lui aussi les données corrompues.
- **Pandera en CI** : transformer l'encadré Pandera de 1.5 en test pytest du Lab 6.
- Documentation :
  [GX Core](https://docs.greatexpectations.io/docs/core/introduction/),
  [Evidently — Reports](https://docs.evidentlyai.com/docs/library/report),
  [KFP — artifacts](https://www.kubeflow.org/docs/components/pipelines/user-guides/data-handling/artifacts/),
  [CheckList (Ribeiro et al., ACL 2020)](https://aclanthology.org/2020.acl-main.442/).

> [!NOTE]
> **Prochaine étape**
> Module 4 — Conteneurisation & packaging des modèles. Vous allez prendre le modèle validé
> aujourd'hui, le convertir en ONNX, le packager dans une image Docker optimisée (< 500 Mo) et
> benchmarker sa latence. C'est le préalable au serving du Module 5.

## Vérification automatique

Depuis la racine du repo, port-forwards actifs (`make pf`) :

```bash
make check-m3
```

Le script `labs/m3-validation/check.sh` lit `dataset.yaml` (et `params.yaml`,
`tests/behavior.yaml`) et vérifie, sans modifier le repo (les contrôles locaux tournent dans des
dossiers temporaires) :

- Great Expectations : la suite `gx/` (suite, validation, checkpoint) couvre toutes les colonnes
  de `dataset.yaml`, elle est versionnée (sans `gx/uncommitted/`), verte sur les données
  courantes, et refuse les données corrompues de `src/simulate.py` ;
- drift : aucun drift entre entraînement et test (rapport Evidently produit), drift détecté sur
  le scénario de `params.yaml` ;
- modèle : `tests/behavior.yaml` porte sur des colonnes de `dataset.yaml`,
  `pytest tests/test_model_behavior.py` est vert, `src/validate_model.py` aussi ;
- code : image `PIPELINE_IMAGE` (un tag postérieur au Lab 2) présente dans le registry local,
  8 composants sur cette image dont 3 gates avec rapport HTML, pipelines compilés avec les
  gates aux bons endroits et des limites mémoire, aucun identifiant S3 ni nom de colonne en
  dur ;
- KFP : un run réussi de `scoring-pipeline` avec les 3 gates, un run de
  `scoring-bad-data-test` en échec bloqué par `validate-data`, un run réussi de
  `scoring-drift-demo` ;
- MLflow : une version de `scoring-model` enregistrée par un run à gates (`kfp_run_id`).

Chaque item affiche ✅ ou ❌ (avec l'étape à revoir) ; le code retour est le nombre d'échecs.

> **Sortie attendue :** `🎉 20/20 vérifications OK — Lab 3 validé.`
