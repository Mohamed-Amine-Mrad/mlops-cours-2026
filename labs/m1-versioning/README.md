---
module: 1
lab: 1
title: "Versionner un projet ML end-to-end"
subtitle: "Credit scoring avec DVC + 20 runs MLflow + Model Registry + Feast"
running_title: "Lab 1 — Versionner un projet ML end-to-end"
duree: "2 heures (atelier guidé)"
stack: "DVC · MLflow · Feast · SeaweedFS (S3) · scikit-learn · Python 3.12"
prerequis: "Lab 0 réussi : cluster kind + SeaweedFS + MLflow opérationnels (make check-m0 vert)"
livrable: "Fork avec pipeline DVC + registry MLflow (3 versions, @champion) + feature store Feast"
---

# Lab 1 — Versionner un projet ML end-to-end

*Poser le projet fil rouge de credit scoring et le versionner de bout en bout : données avec DVC,
20+ runs tracés et comparés dans MLflow, promotion d'un modèle dans le registry, features dans
Feast.*

## Objectifs du lab

> [!NOTE]
> **À la fin de ces 2 heures, vous aurez :**
>
> - Compris le **contrat de données** du projet (`dataset.yaml`) et téléchargé le dataset.
> - Un dataset versionné avec DVC et poussé sur le remote S3 du cours
>   (`s3://dvc-store/scoring`, sur SeaweedFS).
> - Au moins 20 runs d'expériences dans MLflow (expérience `scoring`) avec paramètres,
>   métriques, tags et modèle.
> - Un modèle enregistré dans le Model Registry (nom : `scoring-model`) avec au moins 3 versions.
> - Une version promue `@champion` (si elle passe le seuil de qualité), une `@challenger`.
> - Un pipeline DVC (`dvc.yaml`) reproductible avec `dvc repro` : download → prepare → train →
>   evaluate.
> - Un feature store **Feast** local : mêmes features pour l'entraînement (hors ligne) et le
>   serving (en ligne).

## Architecture cible

Au terme du lab, votre stack ressemblera à ceci :

```text
 ┌──────────────────────────┐  ┌──────────────────────────┐  ┌──────────────────────────┐
 │ Git : votre fork         │  │ SeaweedFS (S3, cluster)  │  │ MLflow (cluster)         │
 │ dataset.yaml params.yaml │  │ s3://dvc-store/scoring/  │  │ tracking + registry      │
 │ dvc.yaml dvc.lock src/   │  │   files/md5/24/b8e38b…   │  │ SQLite (PVC)             │
 │ features/ (Feast)        │  │ s3://mlflow-artifacts/ ◄─┼──┼─ artefacts (proxy S3)    │
 └────────────▲─────────────┘  └────────────▲─────────────┘  └────────────▲─────────────┘
              │ git push / clone            │ dvc push / pull             │ HTTP :5000
              └─────────────────────────────┼─────────────────────────────┘
                              ┌─────────────┴────────────┐
                              │ Votre poste (venv uv)    │
                              │ git · dvc · mlflow       │
                              │ feast : features/data/   │
                              └──────────────────────────┘
```

## Plan du lab

| # | Étape | Durée |
|---|---|---|
| 1 | Le contrat de données : le cas métier, `dataset.yaml`, téléchargement et exploration | 15 min |
| 2 | Versionner les données avec DVC (stage `download` + remote S3) | 15 min |
| 3 | Comprendre et vérifier le serveur MLflow du cours | 5 min |
| 4 | Écrire les scripts de préparation et d'entraînement instrumenté MLflow | 20 min |
| 5 | Lancer 20+ runs avec un grid search de paramètres | 10 min |
| 6 | Comparer les runs dans l'UI MLflow et sélectionner le meilleur | 10 min |
| 7 | Promouvoir des versions dans le Model Registry (alias + seuil de qualité) | 10 min |
| 8 | Construire le pipeline DVC complet (`dvc.yaml`) et tester la repro | 15 min |
| 9 | Un feature store local avec Feast | 15 min |
| 10 | Reproductibilité (même poste, autre poste) et pull request du lab | 5 min |

> [!IMPORTANT]
> **Préalable à ce lab**
> Avoir réussi le Lab 0 : cluster kind actif, SeaweedFS et MLflow en `Running`, fork cloné dans
> `~/mlops-cours-2026`, environnement Python 3.12 synchronisé avec `uv sync`. Vérification
> rapide : `make check-m0` doit être entièrement vert.

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
git switch -c lab/m1-versioning
```

## Convention de notation

Les blocs de code contiennent des commandes shell à exécuter telles quelles depuis la racine de
votre fork `~/mlops-cours-2026` : elles n'ont **pas** de préfixe `$`, vous pouvez les
copier-coller directement. Les lignes commençant par `#` sont des commentaires. Quand un bloc
commence par `# Fichier : chemin`, c'est le contenu **complet** du fichier à créer (ou à
remplacer). Les encadrés « Sortie attendue » montrent le résultat attendu, avec les chiffres réels
obtenus sur le dataset par défaut.

## Étape 1/10 — Le contrat de données : credit scoring (15 min)

Ce lab pose le **projet fil rouge** du cours : vous allez le faire grandir de module en module
(pipeline Kubeflow au Lab 2, validation au Lab 3, API au Lab 4, serving au Lab 5, CI/CD au Lab 6,
monitoring au Lab 7, gouvernance au Lab 8). On travaille directement à la racine de votre fork :
pas de nouveau repo.

### 1.1 Le cas métier

Une banque reçoit des demandes de crédit à la consommation. Pour chacune, elle veut estimer le
**risque que l'emprunteur ne rembourse pas**, et décider d'accorder ou non le crédit. Le jeu de
données par défaut est **Statlog German Credit** (UCI, licence CC BY 4.0) : 1 000 demandes, 20
variables (durée, montant, épargne, emploi, historique de crédit…) et une cible `credit_risk` qui
vaut `good` (bon payeur) ou `bad` (mauvais payeur).

Les deux erreurs possibles n'ont pas le même coût :

| Erreur | Ce qui se passe | Coût (matrice fournie avec le dataset) |
|---|---|---|
| Faux négatif | on accorde le crédit à un mauvais payeur : perte du capital | **5** |
| Faux positif | on refuse un bon payeur : perte de la marge d'intérêts | **1** |

Trois conséquences pour tout le cours :

- **L'accuracy est trompeuse** : 70 % des demandes sont `good`, un modèle qui accepte tout a
  70 % d'accuracy… et coûte le plus cher possible.
- On **sélectionne** les modèles sur leur capacité à classer les demandes du plus sûr au plus
  risqué (**ROC AUC**, indépendante du seuil de décision), et on **mesure** la décision avec le
  **coût métier** (5 × FN + 1 × FP), prise au seuil qui minimise ce coût (pas à 0,5, étape 4.4).
- Le modèle touche des **attributs sensibles** (âge, statut personnel, travailleur étranger). Le
  scoring de crédit est un système « à haut risque » au sens de l'AI Act européen : l'équité et
  l'explicabilité seront traitées au Lab 8.

### 1.2 Lire le contrat : `dataset.yaml`

Tout le pipeline (préparation, entraînement, validation, API, équité, monitoring, vérifications
automatiques) lit **un seul fichier** qui décrit les données : `dataset.yaml`, fourni à la racine
du repo. Aucun script du cours ne contient de nom de colonne en dur. Ouvrez-le :

```yaml
# Fichier : dataset.yaml
# =============================================================================
# dataset.yaml — décrit VOTRE jeu de données. Tout le pipeline le lit :
# préparation, entraînement, validation (GX), API de prédiction, équité,
# monitoring et vérifications automatiques (make check-mX).
#
# Changer de dataset = réécrire CE fichier + src/download.py, pas le pipeline.
# Garder exactement les mêmes clés ; seules les valeurs changent.
# =============================================================================
name: german-credit
description: Demandes de crédit à la consommation d'une banque allemande (données 1973-1975, publiées à l'UCI en 1994)
source:
  url: https://archive.ics.uci.edu/dataset/144/statlog+german+credit+data
  license: CC BY 4.0
  citation: >-
    Hofmann, H. (1994). Statlog (German Credit Data). UCI Machine Learning Repository.
    https://doi.org/10.24432/C5NC77

# Fichier produit par src/download.py (versionné ensuite avec DVC)
raw_path: data/raw/dataset.csv

target:
  column: credit_risk
  positive_class: bad          # la classe « à risque » que le modèle doit détecter

features:
  numeric:
    - duration                 # durée du crédit (mois)
    - credit_amount            # montant (DM)
    - installment_commitment   # mensualité en % du revenu disponible (1-4)
    - residence_since          # ancienneté dans le logement (1-4)
    - age                      # âge (années)
    - existing_credits         # crédits en cours dans la banque
    - num_dependents           # personnes à charge
  categorical:
    - checking_status
    - credit_history
    - purpose
    - savings_status
    - employment
    - personal_status
    - other_parties
    - property_magnitude
    - other_payment_plans
    - housing
    - job
    - own_telephone
    - foreign_worker

# Attributs sensibles : analysés au Lab 8 (équité) et surveillés au Lab 7.
# « bins » : découpage d'un attribut numérique en groupes (bornes, labels).
sensitive:
  - column: age
    bins: [0, 25, 120]
    labels: ["<25", ">=25"]
  - column: personal_status
  - column: foreign_worker

metrics:
  primary: roc_auc             # métrique de sélection et de promotion du modèle
  promotion_threshold: 0.70    # gate : en dessous, le modèle n'est pas promu
  # Coût métier d'une erreur (matrice de coûts fournie avec le dataset) :
  # accorder un crédit à un mauvais payeur (faux négatif) coûte 5,
  # refuser un bon payeur (faux positif) coûte 1.
  cost_matrix:
    false_negative: 5
    false_positive: 1

split:
  test_size: 0.2
  random_state: 42
```

| Clé | Rôle | Utilisée par |
|---|---|---|
| `name`, `description`, `source` | Identité et provenance (licence, citation) du dataset. | Tags MLflow, model card (Lab 8) |
| `raw_path` | Fichier brut produit par `src/download.py`, versionné par DVC. | Download, prepare, DVC |
| `target.column` / `positive_class` | La cible et la classe « à risque » à détecter (`bad`), encodée 1. | Tous les scripts |
| `features.numeric` / `categorical` | Les variables explicatives et leur type : elles déterminent le prétraitement (standardisation ou one-hot). | Prepare, train, API, Feast |
| `sensitive` | Attributs sensibles ; `bins`/`labels` regroupent l'âge en `<25` / `>=25`. | Équité (Lab 8), monitoring (Lab 7) |
| `metrics.primary` | Métrique de sélection et de promotion des modèles (`roc_auc`). | Grid search, promote, CI |
| `metrics.promotion_threshold` | Seuil de qualité : en dessous, un modèle n'est jamais promu `@champion`. | Promote, CI (Lab 6) |
| `metrics.cost_matrix` | Coût d'un faux négatif / faux positif. | Coût métier |
| `split` | Proportion de test et graine du découpage train/test. | Prepare |

### 1.3 Le lecteur du contrat : `src/dataset_config.py`

Les scripts ne lisent pas le YAML eux-mêmes : ils passent par `src/dataset_config.py` (fourni),
qui le valide et expose une API typée. Vous allez l'utiliser dans tous les labs :

| Appel | Renvoie |
|---|---|
| `cfg = load_config()` | Le contrat validé (lève une erreur claire si une clé manque ou si une colonne est à la fois numérique et catégorielle). |
| `cfg.features`, `cfg.numeric`, `cfg.categorical`, `cfg.target` | Les listes de colonnes. |
| `cfg.split_xy(df)` | `X` (features) et `y` (1 pour la classe positive, 0 sinon). |
| `cfg.build_preprocessor()` | Un `ColumnTransformer` scikit-learn : imputation + standardisation (numériques), imputation + one-hot (catégorielles). |
| `cfg.read_xy(path)` | `X`, `y` lus depuis un CSV préparé, numériques convertis en `float64` (le type attendu par le modèle). |
| `cfg.business_cost(y_true, y_pred)` | Le coût métier selon `cost_matrix`. |
| `cfg.cost_threshold(k)` | Le seuil de décision qui minimise le coût métier (étape 4.4). |
| `cfg.sensitive_frame(df)` | Le groupe de chaque ligne pour chaque attribut sensible (Lab 8). |
| `cfg.primary_metric`, `cfg.promotion_threshold` | La métrique de sélection et le seuil de promotion. |

### 1.4 Télécharger les données

`src/download.py` (fourni) télécharge le fichier UCI, décode les catégories (`A11`, `A43`… →
libellés lisibles) et écrit le CSV décrit par `raw_path` :

```bash
python -m src.download
head -3 data/raw/dataset.csv
wc -l data/raw/dataset.csv
```

> **Sortie attendue :** `1000 lignes (UCI) -> data/raw/dataset.csv · classe 'bad' : 30%`, puis
> l'en-tête `duration,credit_amount,…,foreign_worker,credit_risk` suivi de deux demandes, et
> `1001 data/raw/dataset.csv` (1 000 demandes + 1 en-tête). Si le site de l'UCI est indisponible,
> le script bascule automatiquement sur la copie OpenML (`credit-g`) : le fichier produit est
> identique.

> [!NOTE]
> **Pourquoi `python -m src.download` et pas `python src/download.py` ?**
> Les scripts du projet s'importent entre eux (`from src.dataset_config import load_config`).
> Lancés en module depuis la racine du repo (`-m`), ils trouvent le paquet `src` sans bricoler le
> `PYTHONPATH`. Toutes les commandes du cours (et de `dvc.yaml`) suivent cette convention.

### 1.5 Explorer rapidement les données

Cinq minutes d'exploration avant d'entraîner quoi que ce soit : taille, valeurs manquantes,
déséquilibre de la cible, et taux de mauvais payeurs par groupe sensible.

```bash
python - <<'EOF'
import pandas as pd

from src.dataset_config import load_config

cfg = load_config()
df = pd.read_csv(cfg.raw_path)
print(f"{df.shape[0]} lignes x {df.shape[1]} colonnes "
      f"({len(cfg.numeric)} numériques, {len(cfg.categorical)} catégorielles, 1 cible)")
print("Valeurs manquantes :", int(df.isna().sum().sum()))
print(df[cfg.target].value_counts(normalize=True).round(2).to_string())
print(df[cfg.numeric].describe().T[["mean", "min", "max"]].round(1).to_string())
# Taux de la classe positive par groupe sensible
y = cfg.encode_target(df[cfg.target])
for col, groups in cfg.sensitive_frame(df).items():
    print(y.groupby(groups).agg(["size", "mean"]).round(2).rename(
        columns={"size": "n", "mean": f"taux_{cfg.positive_class}"}).to_string(), "\n")
EOF
```

> **Sortie attendue :**

```text
1000 lignes x 21 colonnes (7 numériques, 13 catégorielles, 1 cible)
Valeurs manquantes : 0
credit_risk
good    0.7
bad     0.3
                          mean    min      max
duration                  20.9    4.0     72.0
credit_amount           3271.3  250.0  18424.0
installment_commitment     3.0    1.0      4.0
residence_since            2.8    1.0      4.0
age                       35.5   19.0     75.0
existing_credits           1.4    1.0      4.0
num_dependents             1.2    1.0      2.0
             n  taux_bad
age_group
<25        149      0.41
>=25       851      0.28

                      n  taux_bad
personal_status
female div/dep/mar  310      0.35
male div/sep         50      0.40
male mar/wid         92      0.27
male single         548      0.27

                  n  taux_bad
foreign_worker
no               37      0.11
yes             963      0.31
```

Trois constats à garder en tête : la cible est **déséquilibrée** (70/30) ; les moins de 25 ans
sont nettement plus souvent `bad` (41 % contre 28 %), un modèle risque donc de les pénaliser
(Lab 8) ; certains groupes sont **minuscules** (37 travailleurs non étrangers) : toute métrique
calculée sur eux sera très bruitée.

> [!NOTE]
> **Vous travaillez sur votre propre dataset ?**
> Si votre binôme a fait valider un autre jeu de données par l'enseignant, c'est le moment de
> l'installer. Vous ne modifiez que **deux fichiers**, tout le reste du cours fonctionne sans
> changement :
>
> 1. **`dataset.yaml`** : gardez exactement les mêmes clés, changez les valeurs (vos colonnes,
>    votre cible et sa classe positive, vos attributs sensibles, votre métrique et votre seuil).
>    Laissez `raw_path: data/raw/dataset.csv`. `metrics.primary` doit être une métrique « plus
>    grand = meilleur » calculée par `src/train.py` : `roc_auc`, `average_precision`, `f1`,
>    `precision`, `recall` ou `accuracy`. Sans matrice de coûts connue, mettez 1 et 1.
> 2. **`src/download.py`** : remplacez-le par un script qui écrit, dans `raw_path`, un CSV dont
>    les colonnes sont exactement les features + la cible déclarées (gardez la fin du `main()`
>    actuel : conversion des numériques, `cfg.validate_columns(df)`, écriture de
>    `df[cfg.columns]`).
>
> Validez avec `python -c "from src.dataset_config import load_config; print(load_config())"`,
> `python -m src.download` et `uv run pytest tests/test_dataset_config.py`. Dans ce lab, vos
> chiffres seront différents de ceux des sorties attendues, c'est normal. Point d'attention :
> si votre CSV contient déjà un identifiant de ligne, indiquez son nom dans `params.yaml`
> (`prepare.id_column`, étape 4) et ajoutez-le aux colonnes écrites par `download.py`. Le
> mini-projet exige un dataset **téléchargeable par un script** (`src/download.py`) : un fichier
> remis à la main n'est pas accepté (voir l'encadré 2.2).

## Étape 2/10 — Versionner les données avec DVC (15 min)

### 2.1 Initialiser DVC dans le fork

Votre fork est déjà un repo Git : on y ajoute DVC.

```bash
dvc init
git status --short
```

> **Sortie attendue :** `Initialized DVC repository.` puis `You can now commit the changes to
> git.` ; `git status` montre trois nouveaux fichiers ajoutés à l'index : `.dvc/.gitignore`,
> `.dvc/config` et `.dvcignore`.

Le dossier `.dvc/` contient la configuration (`config`, commitée) et, ignorés par Git, le cache
local (`cache/`) et des fichiers temporaires. `.dvcignore` liste les dossiers que DVC ne doit pas
parcourir : remplacez son contenu par celui-ci (le venv contient des dizaines de milliers de
fichiers inutiles à scanner) :

```text
# Fichier : .dvcignore
# Créé par `dvc init`. Dossiers que DVC n'a pas besoin de parcourir quand il cherche
# les dvc.yaml et les fichiers .dvc du repo (dvc status reste rapide).
.venv/
features/data/
mlruns/
```

### 2.2 `dvc add` ou stage `download` ?

Deux façons de versionner `data/raw/dataset.csv` avec DVC :

| | `dvc add data/raw/dataset.csv` | Stage `download` dans `dvc.yaml` |
|---|---|---|
| Ce que DVC enregistre | Le hash du fichier (`dataset.csv.dvc`) | Le hash du fichier **et** la commande, le code et les paramètres qui l'ont produit (`dvc.lock`) |
| Provenance | « ce fichier est arrivé là » | « ce fichier sort de `python -m src.download` avec ce contrat » |
| Changement de colonnes dans `dataset.yaml` | Invisible pour DVC | `dvc status` signale la stage à relancer |
| Données régénérables ? | Non (snapshot) | Oui : `dvc repro` re-télécharge et vérifie le hash |
| Adapté à | Fichiers remis à la main, sans source scriptable (hors mini-projet) | Données téléchargeables par un script (notre cas, et la règle du mini-projet) |

On choisit la **stage `download`** : le fichier brut est le produit d'un code versionné
(`src/download.py`) et d'un contrat versionné (`dataset.yaml`), DVC peut donc tracer sa
provenance et dire quand il faut le régénérer. Le risque d'une source externe (le site UCI
pourrait changer) est couvert de deux façons : sur votre cluster, `dvc pull` restaure
**exactement** les octets enregistrés dans `dvc.lock`, sans retélécharger ; ailleurs,
`dvc repro` retélécharge et le MD5 de `dvc.lock` révèle tout changement de la source.

> [!WARNING]
> **L'un ou l'autre, jamais les deux**
> Un même fichier ne peut pas être à la fois suivi par un `.dvc` (`dvc add`) et sortie d'une
> stage. Hors du cours, pour un fichier remis à la main, on ferait `dvc add data/raw/dataset.csv`
> (puis `git add data/raw/dataset.csv.dvc data/raw/.gitignore`) sans stage `download`. Pas dans le
> mini-projet : son dataset doit se télécharger par un script, condition de la reproductibilité
> (`dvc repro` sur un poste neuf, étape 10.4).

Déclarez la stage (DVC écrit `dvc.yaml` pour vous) :

```bash
dvc stage add -n download \
  -d src/download.py -d src/dataset_config.py \
  -p dataset.yaml:raw_path,target,features \
  -o data/raw/dataset.csv \
  python -m src.download
cat dvc.yaml
```

> **Sortie attendue :** `Added stage 'download' in 'dvc.yaml'`, puis le fichier :

```yaml
stages:
  download:
    cmd: python -m src.download
    deps:
    - src/dataset_config.py
    - src/download.py
    params:
    - dataset.yaml:
      - features
      - raw_path
      - target
    outs:
    - data/raw/dataset.csv
```

- `-d` (**deps**) : si le code de téléchargement change, la stage est à relancer.
- `-p` (**params**) : DVC surveille ici trois clés de `dataset.yaml` seulement. Changer
  `features` ou `target` relance le téléchargement ; changer `promotion_threshold` ne le relance
  pas (il ne concerne pas le fichier brut).
- `-o` (**outs**) : la sortie, stockée dans le cache DVC et ignorée par Git (DVC ajoute
  `/dataset.csv` à `data/raw/.gitignore`).

Exécutez la stage :

```bash
dvc repro
cat dvc.lock
```

> **Sortie attendue :** `Running stage 'download':`, la ligne `1000 lignes (UCI) -> …`, puis
> `Generating lock file 'dvc.lock'`. `dvc.lock` contient le hash de chaque dépendance, la valeur
> des trois paramètres et, pour la sortie, `md5: 24b8e38b9c8688d495afc8eb5cb40127` et
> `size: 139022`. C'est ce fichier, versionné par Git, qui fige la version des données.

### 2.3 Configurer le remote DVC sur SeaweedFS

Le stockage S3 du cours est SeaweedFS : il remplace MinIO, dont l'édition communautaire a été
archivée en 2026 (licence Apache 2.0, même API S3, voir Lab 0). Le bucket `dvc-store` a été créé
au Lab 0 (`make storage`) ; chaque projet y range ses données sous un préfixe, ici
`scoring/`. Vérifiez que le port-forward S3 tourne (`make pf`), puis :

```bash
dvc remote add -d storage s3://dvc-store/scoring
dvc remote modify storage endpointurl http://localhost:8333
# Identifiants : dans .dvc/config.local (ignoré par Git), jamais dans .dvc/config
dvc remote modify --local storage access_key_id mlops
dvc remote modify --local storage secret_access_key mlops-lab-secret
cat .dvc/config
cat .dvc/config.local
```

> **Sortie attendue :** `Setting 'storage' as a default remote.` ; `.dvc/config` contient
> `[core] remote = storage` et la section `['remote "storage"']` avec `url` et `endpointurl` ;
> `.dvc/config.local` contient seulement les deux identifiants.

> [!WARNING]
> **Un remote par cluster**
> `localhost:8333` est le SeaweedFS de **votre** cluster kind. Votre partenaire de binôme, le
> jury ou vous-même sur un autre poste avez un autre cluster, donc un autre remote, vide au
> départ : `dvc pull` n'y trouve rien (`missing cache files`). Ce qui se partage, c'est Git :
> le code, `dvc.yaml` et `dvc.lock`. Sur un autre cluster, on **reconstruit** avec `dvc repro`
> (le téléchargement est déterministe, et vérifié par le MD5 inscrit dans `dvc.lock`), puis on
> remplit son propre remote avec `dvc push` : c'est ce que fera le second membre du binôme
> (encadré de fin de lab) et l'étape 10.4. En entreprise, le remote serait un bucket partagé
> (S3, GCS…) : il suffirait de changer `url` et `endpointurl`.

### 2.4 Pousser les données et commiter

```bash
dvc push
aws-lab s3 ls --recursive s3://dvc-store/scoring/
git add .dvc/config .dvc/.gitignore .dvcignore dvc.yaml dvc.lock data/raw/.gitignore
git commit -m "data: stage download + remote S3 (dataset v1)"
```

> **Sortie attendue :** `1 file pushed`, puis une ligne
> `2026-10-05 14:32:10     139022 scoring/files/md5/24/b8e38b9c8688d495afc8eb5cb40127` : l'objet
> est rangé sous son empreinte MD5, la même que dans `dvc.lock`.

> [!IMPORTANT]
> **Point de validation**
> Ouvrez le filer de SeaweedFS :
> [http://localhost:8888/buckets/dvc-store/scoring/files/md5/](http://localhost:8888/buckets/dvc-store/scoring/files/md5/).
> Vous devez voir le dossier `24/` et le fichier hashé. Git ne contient que des pointeurs
> (`dvc.lock`), le contenu vit dans S3 : c'est votre premier dataset « MLOps-grade ».

## Étape 3/10 — Comprendre et vérifier le serveur MLflow du cours (5 min)

Il n'y a **pas** de serveur MLflow à lancer : celui du cours tourne dans le cluster depuis le
Lab 0, et tous les labs (votre poste, les pipelines Kubeflow, la CI) y enregistrent leurs runs.
Prenez cinq minutes pour comprendre ce que vous utilisez.

### 3.1 Backend store et artifact store

Relisez les arguments du serveur dans `infra/mlflow/mlflow.yaml` :

```yaml
# Extrait de infra/mlflow/mlflow.yaml
exec mlflow server
--backend-store-uri sqlite:////mlflow/mlflow.db
--artifacts-destination s3://mlflow-artifacts
--host 0.0.0.0 --port 5000 --workers 2
```

| Stockage | Contenu | Ici | En production |
|---|---|---|---|
| **Backend store** (`--backend-store-uri`) | Métadonnées : expériences, runs, paramètres, métriques, tags, registre de modèles (versions, alias) | SQLite sur le volume persistant `mlflow-data` | PostgreSQL / MySQL |
| **Artifact store** (`--artifacts-destination`) | Fichiers : modèles sérialisés, signatures, figures, rapports | Bucket `s3://mlflow-artifacts` (SeaweedFS) | S3, GCS, Azure Blob |

Avec `--artifacts-destination`, le serveur est en **mode proxy** : un client envoie ses artefacts
au serveur en HTTP, et c'est le serveur qui les écrit dans S3 avec **ses** identifiants (le
Secret `s3-credentials` du namespace `mlflow`). Qui a besoin de quoi :

| Client | A besoin de | Variables (`.env`) |
|---|---|---|
| DVC, boto3 (accès direct à S3) | Endpoint + identifiants S3 | `AWS_ENDPOINT_URL`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
| Client MLflow (vos scripts, pods, CI) | L'URL du serveur, **rien d'autre** | `MLFLOW_TRACKING_URI` |
| Serveur MLflow (pod) | Identifiants S3 | Secret Kubernetes `s3-credentials` |

### 3.2 Vérifier l'accès

```bash
make pf
set -a && source .env && set +a
echo $MLFLOW_TRACKING_URI
curl http://localhost:5000/health
# Le client n'a pas besoin des identifiants S3 : on les retire pour le prouver
env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY \
  python -c "import mlflow; print([e.name for e in mlflow.search_experiments()])"
```

> **Sortie attendue :** `http://localhost:5000`, puis `OK`, puis `['smoke-test', 'Default']`
> (l'expérience du Lab 0 et l'expérience par défaut).

> [!NOTE]
> **Ce qui a changé par rapport aux anciennes versions de ce lab**
> Les promotions précédentes lançaient `mlflow server` sur leur poste (et l'arrêtaient en fermant
> le terminal), avec `--default-artifact-root` : chaque client devait alors connaître l'endpoint
> S3 (`MLFLOW_S3_ENDPOINT_URL`) et les identifiants, sous peine de `NoCredentialsError` au
> `log_model`. Avec un serveur unique en mode proxy, ces trois variables disparaissent du poste.

## Étape 4/10 — Écrire les scripts de préparation et d'entraînement instrumenté (20 min)

### 4.1 Le fichier de paramètres

Les hyper-paramètres ne s'écrivent pas dans le code : ils vivent dans `params.yaml`, que DVC
suivra à l'étape 8 (`dvc params diff`). Le contrat des **données** reste dans `dataset.yaml` ;
`params.yaml` contient les choix de **modélisation**. Créez-le :

```yaml
# Fichier : params.yaml
# Paramètres du pipeline, suivis par DVC (dvc params diff).
# Le contrat des données (colonnes, cible, split, métriques, seuil) est dans dataset.yaml.
prepare:
  id_column: request_id  # identifiant de demande, créé s'il est absent (entité Feast)
  event_timestamp: "2026-01-01T00:00:00+00:00"  # date de valeur des features (Feast)

train:
  model: logistic_regression  # logistic_regression | random_forest | gradient_boosting | dummy
  C: 0.1  # régularisation (logistic_regression)
  class_weight: balanced  # balanced | none (logistic_regression, random_forest)
  n_estimators: 200  # random_forest, gradient_boosting
  max_depth: 8  # entier ou none (random_forest, gradient_boosting)
  learning_rate: 0.1  # gradient_boosting
  random_state: 42  # graine du modèle
```

### 4.2 Script de préparation des données

Créez `src/prepare.py` :

```python
# Fichier : src/prepare.py
"""Prépare les données : identifiant de demande, split stratifié, source du feature store.

Entrées : le fichier brut (raw_path de dataset.yaml) et params.yaml (section prepare).
Sorties : data/processed/train.csv, data/processed/test.csv (colonnes brutes + identifiant)
          et data/processed/features.parquet (source « offline » de Feast).
Aucun nom de colonne en dur : tout vient de dataset.yaml (load_config) et de params.yaml.
"""

from pathlib import Path

import pandas as pd
import yaml
from sklearn.model_selection import train_test_split

from src.dataset_config import load_config

PROCESSED = Path("data/processed")


def main() -> None:
    cfg = load_config()
    params = yaml.safe_load(Path("params.yaml").read_text(encoding="utf-8"))["prepare"]
    id_col = params["id_column"]

    df = pd.read_csv(cfg.raw_path)
    cfg.validate_columns(df)

    # Identifiant de demande (clé de l'entité Feast). S'il est absent du fichier brut,
    # on numérote les lignes : l'ordre du fichier est figé par DVC, donc l'identifiant
    # est reproductible.
    if id_col not in df.columns:
        df.insert(0, id_col, range(1, len(df) + 1))
    df = df[[id_col, *cfg.columns]]

    # Split stratifié sur la cible : même proportion de la classe positive des deux côtés
    y = cfg.encode_target(df[cfg.target])
    train, test = train_test_split(
        df, test_size=cfg.test_size, random_state=cfg.random_state, stratify=y
    )
    PROCESSED.mkdir(parents=True, exist_ok=True)
    train.to_csv(PROCESSED / "train.csv", index=False)
    test.to_csv(PROCESSED / "test.csv", index=False)

    # Source offline de Feast : les features seules (jamais la cible), une ligne par
    # demande, avec un horodatage fixe (params.yaml) pour que le fichier soit reproductible.
    features = df[[id_col, *cfg.features]].copy()
    features[cfg.numeric] = features[cfg.numeric].astype("float64")
    features["event_timestamp"] = pd.Timestamp(params["event_timestamp"])
    features.to_parquet(PROCESSED / "features.parquet", index=False)

    rate = cfg.encode_target(train[cfg.target]).mean(), cfg.encode_target(test[cfg.target]).mean()
    print(
        f"Train : {len(train)} / Test : {len(test)} · "
        f"classe '{cfg.positive_class}' : {rate[0]:.1%} / {rate[1]:.1%}"
    )


if __name__ == "__main__":
    main()
```

```bash
python -m src.prepare
ls data/processed/
```

> **Sortie attendue :** `Train : 800 / Test : 200 · classe 'bad' : 30.0% / 30.0%` et trois
> fichiers dans `data/processed/` : `features.parquet`, `test.csv`, `train.csv`.

Quelques choix à comprendre :

- **Pas de feature engineering ici** : le prétraitement (imputation, standardisation, one-hot)
  fait partie du **modèle** (`cfg.build_preprocessor()`, étape 4.3). Le modèle enregistré prend
  donc en entrée les colonnes **brutes** : l'API du Lab 4 n'aura rien à recoder, ce qui supprime
  une source classique de *training/serving skew*.
- **Split stratifié** : 30 % de `bad` dans le train comme dans le test.
- **`request_id`** : German Credit n'a pas d'identifiant de demande. Il en faut un pour le
  feature store (étape 9) : on numérote les lignes. Comme l'ordre du fichier brut est figé par
  DVC, l'identifiant est reproductible.
- **`features.parquet`** : la source du feature store (étape 9), avec un horodatage **fixe**
  (`params.yaml`). Un `pd.Timestamp.now()` changerait le fichier à chaque exécution : DVC
  croirait les données modifiées et la repro serait cassée.

### 4.3 Script d'entraînement instrumenté

Créez `src/train.py` :

```python
# Fichier : src/train.py
"""Entraîne un modèle de scoring et trace le run dans MLflow (expérience « scoring »).

Hyper-paramètres par défaut : params.yaml (section train) ; les options de la ligne de
commande les surchargent (utilisé par src/grid_search.py). Le modèle enregistré est un
Pipeline scikit-learn complet (prétraitement décrit par dataset.yaml + estimateur) : il
prend en entrée les colonnes brutes, exactement comme l'API de prédiction des labs 4-5.

Les métriques de décision (F1, précision, rappel, coût métier) sont calculées au seuil
qui minimise le coût métier (cfg.cost_threshold), pas à 0,5 : ce seuil est loggé en
paramètre `decision_threshold` et rangé dans les métadonnées du modèle.

Sorties : un run MLflow (params, métriques, tags, modèle) et une copie locale du modèle
au format MLflow dans models/model/ (sortie DVC, relue par src/evaluate.py).
"""

import argparse
import hashlib
import os
import shutil
from importlib.metadata import version
from pathlib import Path

import mlflow
import numpy as np
import pandas as pd
import yaml
from mlflow.models import infer_signature
from sklearn.dummy import DummyClassifier
from sklearn.ensemble import GradientBoostingClassifier, RandomForestClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import (
    accuracy_score,
    average_precision_score,
    f1_score,
    precision_score,
    recall_score,
    roc_auc_score,
)
from sklearn.pipeline import Pipeline

from src.dataset_config import DatasetConfig, load_config

EXPERIMENT = "scoring"
TRAIN_CSV = Path("data/processed/train.csv")
TEST_CSV = Path("data/processed/test.csv")
MODEL_DIR = Path("models/model")

# Type de modèle -> (classe scikit-learn, hyper-paramètres pris dans params.yaml / la CLI)
MODELS = {
    "logistic_regression": (LogisticRegression, ["C", "class_weight"]),
    "random_forest": (RandomForestClassifier, ["n_estimators", "max_depth", "class_weight"]),
    "gradient_boosting": (
        GradientBoostingClassifier,
        ["n_estimators", "max_depth", "learning_rate"],
    ),
    "dummy": (DummyClassifier, []),  # référence naïve : probabilité = taux de la classe
}
# MLflow 3 sérialise en skops (pas en pickle) : seuls les types déclarés « de confiance »
# peuvent être rechargés. Ceux-ci sont utilisés par OneHotEncoder et par les arbres.
SKOPS_TRUSTED_TYPES = ["numpy.dtype", "sklearn.tree._tree.Tree"]
# Dépendances nécessaires pour recharger le modèle (images de serving des labs 4-5).
# Sans cette liste, MLflow 3 recopie tout uv.lock (près de 300 paquets du cours).
PIP_REQUIREMENTS = [f"{p}=={version(p)}" for p in ("scikit-learn", "skops", "pandas", "numpy")]


def none_or(cast):
    """Convertisseur argparse acceptant « none » (ex. --max_depth none)."""
    return lambda value: None if str(value).lower() == "none" else cast(value)


def parse_args() -> argparse.Namespace:
    defaults = yaml.safe_load(Path("params.yaml").read_text(encoding="utf-8"))["train"]
    parser = argparse.ArgumentParser(description="Entraîne un modèle et le trace dans MLflow")
    parser.add_argument("--model", choices=list(MODELS), default=defaults["model"])
    parser.add_argument("--C", type=float, default=defaults["C"])
    parser.add_argument("--class_weight", type=none_or(str), default=defaults["class_weight"])
    parser.add_argument("--n_estimators", type=int, default=defaults["n_estimators"])
    parser.add_argument("--max_depth", type=none_or(int), default=defaults["max_depth"])
    parser.add_argument("--learning_rate", type=float, default=defaults["learning_rate"])
    parser.add_argument("--random_state", type=int, default=defaults["random_state"])
    # NB : argparse applique aussi `type` aux valeurs par défaut écrites en texte
    # (« none » dans params.yaml devient None).
    return parser.parse_args()


def build_model(cfg: DatasetConfig, model_type: str, hyperparams: dict, seed: int) -> Pipeline:
    """Pipeline complet : prétraitement de dataset.yaml + estimateur."""
    cls, _ = MODELS[model_type]
    extra = {"random_state": seed} if model_type != "dummy" else {"strategy": "prior"}
    if model_type == "logistic_regression":
        extra["max_iter"] = 1000
    return Pipeline(
        [("preprocess", cfg.build_preprocessor()), ("model", cls(**hyperparams, **extra))]
    )


def decision_threshold(cfg: DatasetConfig, class_weight, y_train: pd.Series) -> float:
    """Seuil qui minimise le coût métier de dataset.yaml (et non 0,5).

    class_weight="balanced" donne aux positifs un poids n_neg/n_pos fois plus grand :
    les probabilités du modèle sont gonflées d'autant, le seuil remonte en conséquence.
    """
    k = (y_train == 0).sum() / (y_train == 1).sum() if class_weight == "balanced" else 1.0
    return cfg.cost_threshold(float(k))


def compute_metrics(cfg: DatasetConfig, y_true, proba, threshold: float) -> dict:
    """Métriques de classement (proba) et de décision au seuil donné, dont le coût métier."""
    y_pred = (np.asarray(proba) >= threshold).astype(int)
    return {
        "roc_auc": roc_auc_score(y_true, proba),
        "average_precision": average_precision_score(y_true, proba),
        "f1": f1_score(y_true, y_pred, zero_division=0),
        "precision": precision_score(y_true, y_pred, zero_division=0),
        "recall": recall_score(y_true, y_pred, zero_division=0),
        "accuracy": accuracy_score(y_true, y_pred),
        "business_cost": cfg.business_cost(y_true, y_pred),
    }


def file_md5(path: str | Path) -> str:
    """Empreinte MD5 du fichier brut : la même que celle que DVC écrit dans dvc.lock."""
    return hashlib.md5(Path(path).read_bytes()).hexdigest()


def main() -> None:
    args = parse_args()
    cfg = load_config()
    # Numériques en float64 : la signature MLflow les déclare `double` (cfg.read_xy)
    X_train, y_train = cfg.read_xy(TRAIN_CSV)
    X_test, y_test = cfg.read_xy(TEST_CSV)

    hyperparams = {name: getattr(args, name) for name in MODELS[args.model][1]}
    threshold = decision_threshold(cfg, hyperparams.get("class_weight"), y_train)
    run_name = "-".join([args.model, *(f"{k}={v}" for k, v in hyperparams.items())])
    # Qui a lancé le run ? DVC définit DVC_STAGE ; grid_search.py définit LAUNCHED_BY.
    launched_by = "dvc" if os.getenv("DVC_STAGE") else os.getenv("LAUNCHED_BY", "manual")

    # Serveur MLflow du cours (MLFLOW_TRACKING_URI dans .env) : aucun identifiant S3 ici,
    # le serveur fait proxy des artefacts vers s3://mlflow-artifacts.
    mlflow.set_tracking_uri(os.getenv("MLFLOW_TRACKING_URI", "http://localhost:5000"))
    mlflow.set_experiment(EXPERIMENT)

    with mlflow.start_run(run_name=run_name) as run:
        mlflow.set_tags(
            {
                "model_type": args.model,
                "dataset": cfg.name,
                "data_md5": file_md5(cfg.raw_path),
                "launched_by": launched_by,
            }
        )
        mlflow.log_params({"model": args.model, "random_state": args.random_state, **hyperparams})
        mlflow.log_param("decision_threshold", round(threshold, 4))

        model = build_model(cfg, args.model, hyperparams, args.random_state)
        model.fit(X_train, y_train)

        metrics = compute_metrics(cfg, y_test, model.predict_proba(X_test)[:, 1], threshold)
        mlflow.log_metrics(metrics)

        # Signature = contrat d'entrée/sortie du modèle, vérifié au chargement / au serving
        signature = infer_signature(X_test, model.predict(X_test))
        mlflow.sklearn.log_model(
            sk_model=model,
            name="model",
            signature=signature,
            input_example=X_test.head(3),
            pip_requirements=PIP_REQUIREMENTS,
            skops_trusted_types=SKOPS_TRUSTED_TYPES,
            metadata={"decision_threshold": threshold},  # le seuil voyage avec le modèle
        )

        # Copie locale (sortie du stage DVC train, relue par src/evaluate.py)
        shutil.rmtree(MODEL_DIR, ignore_errors=True)
        mlflow.sklearn.save_model(
            model,
            MODEL_DIR,
            signature=signature,
            pip_requirements=PIP_REQUIREMENTS,
            skops_trusted_types=SKOPS_TRUSTED_TYPES,
            metadata={"mlflow_run_id": run.info.run_id, "decision_threshold": threshold},
        )

        summary = ", ".join(f"{k}={v:.3f}" for k, v in metrics.items() if k != "business_cost")
        cost = metrics["business_cost"]
        print(f"{run_name}: seuil={threshold:.3f}, {summary}, business_cost={cost:.0f}")
        print(f"run_id : {run.info.run_id}")


if __name__ == "__main__":
    main()
```

Ce qui est tracé dans chaque run MLflow :

| Élément | Contenu | Pourquoi |
|---|---|---|
| Nom du run | `logistic_regression-C=0.1-class_weight=balanced` | Lisible dans l'UI sans ouvrir le run |
| Paramètres | `model`, `random_state`, les hyper-paramètres du type de modèle et `decision_threshold` | Comparer les configurations |
| Métriques | `roc_auc`, `average_precision`, `f1`, `precision`, `recall`, `accuracy`, `business_cost` | Classement (proba) **et** décision au seuil coût-optimal (coût métier) |
| Tags | `model_type`, `dataset`, `data_md5`, `launched_by` (+ `mlflow.source.git.commit`, posé automatiquement) | Relier le run à la version des données (même hash que `dvc.lock`) et du code |
| Modèle | Pipeline complet + **signature** (schéma d'entrée/sortie) + exemple d'entrée + dépendances | Chargement et serving sans le code d'entraînement |

Trois détails propres à MLflow 3 :

- `log_model(name="model", …)` : l'ancien argument `artifact_path` est déprécié. Le modèle
  devient un *LoggedModel* (`models:/m-…`) rattaché au run.
- La sérialisation par défaut est **skops** (format sûr) et non plus pickle : au rechargement,
  seuls les types déclarés dans `skops_trusted_types` sont acceptés.
- Sans `pip_requirements`, MLflow 3 détecte le projet uv et recopie **tout** `uv.lock` (près de
  300 paquets) dans les dépendances du modèle : on déclare la liste minimale.

Enfin, les colonnes numériques sont converties en `float64` (`cfg.read_xy`) : la signature les
déclare `double`, ce qui accepte aussi les valeurs manquantes et les nombres envoyés en JSON par
l'API. Conséquence : pour prédire en Python à partir d'un CSV, passez par `cfg.read_xy`.

### 4.4 Le seuil de décision : pourquoi pas 0,5 ?

Le modèle donne une probabilité `p = P(bad)` ; il faut encore **décider** à partir de quel `p` on
refuse. Refuser coûte `(1 − p) × C_FP` (on perd peut-être un bon client), accepter coûte
`p × C_FN` (on prête peut-être à un mauvais payeur) : on refuse dès que `p ≥ C_FP / (C_FP + C_FN)`,
soit **1/6 ≈ 0,167** avec la matrice 5/1, et non 0,5. Avec `class_weight="balanced"`, les
mauvais payeurs pèsent `k = n_good / n_bad = 560/240 ≈ 2,33` fois plus à l'entraînement : les
cotes `p/(1 − p)` du modèle sont multipliées par `k` et le seuil équivalent remonte à
`C_FP·k / (C_FP·k + C_FN) ≈ 0,318`. C'est ce que calcule `decision_threshold()` avec
`cfg.cost_threshold(k)` ; le seuil est loggé (`decision_threshold`) et rangé dans les
métadonnées du modèle, pour que l'API du Lab 4 décide exactement comme l'évaluation.

### 4.5 Smoke test

```bash
python -m src.train
python -m src.train --model random_forest --n_estimators 50 --max_depth 5
```

> **Sortie attendue :** pour le premier run (paramètres de `params.yaml`),
> `logistic_regression-C=0.1-class_weight=balanced: seuil=0.318, roc_auc=0.809,
> average_precision=0.646, f1=0.570, precision=0.421, recall=0.883, accuracy=0.600,
> business_cost=108`, le `run_id` et un
> lien `View run … at: http://localhost:5000/#/experiments/2/runs/…`. Le second affiche
> `random_forest-n_estimators=50-max_depth=5-class_weight=balanced: seuil=0.318, roc_auc=0.796, …,
> business_cost=112`. Dans l'UI ([http://localhost:5000](http://localhost:5000)), l'expérience
> `scoring` contient les deux runs, avec paramètres, métriques, tags et, dans l'onglet
> *Artifacts* / *Logged models*, le modèle et sa signature.

> [!NOTE]
> **Messages sans gravité**
> `INFO mlflow.utils.uv_utils: Detected uv project…` et `WARNING … Failed to resolve installed
> pip version` s'affichent à chaque run : le venv uv ne contient pas `pip`, MLflow l'écrit sans
> numéro de version dans `conda.yaml`. Rien à corriger.

Commitez les scripts (pas les données : `data/processed/` et `models/` seront pris en charge par
DVC à l'étape 8, ne les ajoutez pas à Git) :

```bash
git add params.yaml src/prepare.py src/train.py
git commit -m "feat: préparation + entraînement instrumenté MLflow"
```

## Étape 5/10 — Lancer 20+ runs avec un grid search de paramètres (10 min)

### 5.1 Script de grid search

Créez `src/grid_search.py`, qui lance plusieurs runs en boucle :

```python
# Fichier : src/grid_search.py
"""Lance 22 runs d'entraînement (un sous-processus par run) dans l'expérience « scoring »."""

import os
import subprocess
import sys
from itertools import product

CONFIGS = [
    # Référence naïve : tout modèle utile doit faire mieux (ROC AUC = 0,5)
    ("dummy", []),
    # Régression logistique : 4 x 2 = 8 runs
    *[
        ("logistic_regression", ["--C", str(c), "--class_weight", w])
        for c, w in product([0.01, 0.1, 1.0, 10.0], ["none", "balanced"])
    ],
    # Random Forest : 3 x 3 = 9 runs
    *[
        ("random_forest", ["--n_estimators", str(n), "--max_depth", str(d)])
        for n, d in product([100, 200, 400], [4, 8, "none"])
    ],
    # Gradient Boosting : 2 x 2 = 4 runs
    *[
        ("gradient_boosting", ["--n_estimators", str(n), "--max_depth", str(d)])
        for n, d in product([100, 200], [2, 3])
    ],
]


def main() -> None:
    print(f"Lancement de {len(CONFIGS)} runs...")
    env = {**os.environ, "LAUNCHED_BY": "grid_search"}  # tag MLflow launched_by
    for i, (model, args) in enumerate(CONFIGS, 1):
        # sys.executable = le Python du venv courant (fonctionne aussi avec `uv run`)
        cmd = [sys.executable, "-m", "src.train", "--model", model, *args]
        print(f"[{i}/{len(CONFIGS)}] {' '.join(cmd[1:])}", flush=True)
        subprocess.run(cmd, check=True, env=env)
    print("✓ Tous les runs sont terminés.")


if __name__ == "__main__":
    main()
```

```bash
python -m src.grid_search
```

> **Sortie attendue :** `Lancement de 22 runs...`, puis pour chaque run sa commande
> (`[1/22] -m src.train --model dummy`…) et ses métriques, et enfin `✓ Tous les runs sont
> terminés.` Comptez 2 minutes environ. Le modèle `dummy` affiche `seuil=0.167`,
> `roc_auc=0.500`, `recall=1.000` et `business_cost=140` : sa probabilité est toujours 0,30
> (le taux de `bad`), au-dessus du seuil de 1/6, donc il refuse **tout le monde** et perd les 140
> bons clients du test. Accepter tout le monde coûterait 60 × 5 = 300 : même un modèle naïf
> choisit le refus quand l'erreur la plus chère est d'accorder.

> [!TIP]
> **Pourquoi un grid search « à la main » ?**
> Dans un vrai projet, on utiliserait Optuna, Ray Tune ou `GridSearchCV` avec l'autologging
> MLflow. Ici on fait la version « pour comprendre » : un sous-processus par run, chaque run
> clairement isolé dans MLflow. Le modèle `dummy` sert de **référence** : un modèle qui ne fait
> pas nettement mieux n'a rien appris.

### 5.2 Qui a lancé quel run ?

Le tag `launched_by` vaut `grid_search` pour ces 22 runs (variable `LAUNCHED_BY` posée par le
script), `manual` pour vos smoke tests, et vaudra `dvc` pour les runs lancés par `dvc repro`
(DVC définit la variable `DVC_STAGE`). Ce tag servira à l'étape 8 pour retrouver le modèle
produit par le pipeline.

```bash
git add src/grid_search.py && git commit -m "feat: grid search (22 runs)"
```

## Étape 6/10 — Comparer les runs dans l'UI MLflow et sélectionner le meilleur (10 min)

### 6.1 Explorer l'UI

Ouvrez [http://localhost:5000](http://localhost:5000) et sélectionnez l'expérience `scoring`.
Vous devez voir 24 runs (22 du grid search + 2 smoke tests). Ajoutez les colonnes
`metrics.roc_auc`, `metrics.business_cost` et `tags.launched_by`, et triez par `roc_auc`.

### 6.2 Comparer 3 runs

- Cochez trois runs, un de chaque type de modèle (`logistic_regression`, `random_forest`,
  `gradient_boosting`).
- Cliquez sur **Compare**.
- Explorez les vues *Parameters*, *Metrics* et le *Parallel Coordinates Plot*.
- Notez quels paramètres influencent le plus le `roc_auc`… puis le `business_cost`.

Vous devriez constater que `class_weight` ne change presque pas le ROC AUC ni le coût métier
(le seuil compense les poids), alors que la profondeur des forêts change les deux.

### 6.3 Identifier les meilleurs runs en CLI

```bash
python - <<'EOF'
import mlflow

client = mlflow.MlflowClient()  # MLFLOW_TRACKING_URI lu dans l'environnement (.env)
exp = client.get_experiment_by_name("scoring")
runs = client.search_runs(
    [exp.experiment_id], order_by=["metrics.roc_auc DESC"], max_results=5
)
for r in runs:
    m = r.data.metrics
    print(f"{r.info.run_name:50s} roc_auc={m['roc_auc']:.4f} f1={m['f1']:.3f} "
          f"cost={m['business_cost']:.0f} run_id={r.info.run_id[:8]}")
EOF
```

> **Sortie attendue :**

```text
logistic_regression-C=0.1-class_weight=None        roc_auc=0.8095 f1=0.555 cost=113 run_id=…
logistic_regression-C=0.1-class_weight=balanced    roc_auc=0.8094 f1=0.570 cost=108 run_id=…
logistic_regression-C=0.1-class_weight=balanced    roc_auc=0.8094 f1=0.570 cost=108 run_id=…
logistic_regression-C=1.0-class_weight=balanced    roc_auc=0.8058 f1=0.575 cost=109 run_id=…
logistic_regression-C=1.0-class_weight=None        roc_auc=0.8040 f1=0.578 cost=108 run_id=…
```

Sur 1 000 lignes, une régression logistique bien régularisée fait jeu égal avec les forêts
(meilleure forêt : 0,804) et le gradient boosting (0,793). Les deux runs identiques (smoke test
et grid search) ont exactement les mêmes métriques : le pipeline est **déterministe** (graines
fixées).

> [!NOTE]
> **ROC AUC ou coût métier ?**
> Le ROC AUC mesure la qualité du **classement** des demandes, indépendamment du seuil ; le coût
> métier mesure la **décision**, prise au seuil coût-optimal de chaque run. Au seuil naïf de 0,5,
> la régression logistique sans poids coûterait 162 (30 mauvais payeurs acceptés) contre 107
> avec `class_weight="balanced"` ; au seuil coût-optimal, les deux coûtent 113 et 108 : c'est le
> **seuil**, plus que les poids, qui porte la décision métier. Le run le moins coûteux est une
> forêt (`n_estimators=100`, `max_depth=None` : coût 97, ROC AUC 0,804). On garde le ROC AUC pour
> **sélectionner** (c'est `metrics.primary`), le coût sert à **justifier** le choix.

## Étape 7/10 — Promouvoir des versions dans le Model Registry (10 min)

### 7.1 Des stages aux alias

Le registry versionne les modèles **promus**, pas tous les runs : on n'y enregistre que les
candidats sérieux. Pour marquer le cycle de vie, MLflow utilisait des *stages* fixes
(`Staging`, `Production`, `Archived`), **dépréciés depuis MLflow 2.9** au profit des **alias** :
des étiquettes libres, chacune pointant sur une version.

| Ancien stage | Alias du cours | Sens |
|---|---|---|
| `Staging` | `@challenger` | Dernier candidat évalué |
| `Production` | `@champion` | La version servie en production (API, KServe…) |
| `Archived` | (pas d'alias) | Ancienne version, toujours dans l'historique |

Un consommateur demande `models:/scoring-model@champion` ; déplacer l'alias suffit à changer la
version servie, sans toucher au code du consommateur.

### 7.2 Promotion par script, avec un seuil de qualité

Créez `src/promote.py` :

```python
# Fichier : src/promote.py
"""Enregistre un run dans le Model Registry et le promeut avec des alias MLflow.

  1. choisit le meilleur run de l'expérience « scoring » selon metrics.primary
     (dataset.yaml) — ou le run donné par --run-id, ou le meilleur parmi --filter ;
  2. l'enregistre comme nouvelle version de « scoring-model » (sauf s'il l'est déjà) ;
  3. pose l'alias @challenger sur cette version ;
  4. pose l'alias @champion SEULEMENT si la métrique atteint metrics.promotion_threshold.
Les alias remplacent les « stages » (Staging/Production) dépréciés depuis MLflow 2.9.
"""

import argparse
import os

import mlflow
from mlflow import MlflowClient

from src.dataset_config import load_config
from src.train import EXPERIMENT

MODEL_NAME = "scoring-model"
# Métriques loggées par src/train.py pour lesquelles « plus grand = meilleur »
HIGHER_IS_BETTER = {"roc_auc", "average_precision", "f1", "precision", "recall", "accuracy"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--run-id", help="run à enregistrer (défaut : le meilleur run)")
    parser.add_argument(
        "--filter",
        default="",
        help="filtre MLflow sur les runs candidats, ex. \"tags.launched_by = 'dvc'\"",
    )
    return parser.parse_args()


def find_run(client: MlflowClient, metric: str, run_id: str | None, extra_filter: str):
    """Le run demandé, sinon le meilleur run terminé (à égalité : le plus récent)."""
    if run_id:
        return client.get_run(run_id)
    exp = client.get_experiment_by_name(EXPERIMENT)
    if exp is None:
        raise SystemExit(f"Expérience « {EXPERIMENT} » introuvable : lancez d'abord src.train")
    filters = ["attributes.status = 'FINISHED'"] + ([extra_filter] if extra_filter else [])
    runs = client.search_runs(
        [exp.experiment_id],
        filter_string=" and ".join(filters),
        order_by=[f"metrics.{metric} DESC", "attributes.start_time DESC"],
        max_results=1,
    )
    if not runs or metric not in runs[0].data.metrics:
        raise SystemExit(f"Aucun run avec la métrique « {metric} » ({' and '.join(filters)})")
    return runs[0]


def main() -> None:
    args = parse_args()
    cfg = load_config()
    metric, threshold = cfg.primary_metric, cfg.promotion_threshold
    if metric not in HIGHER_IS_BETTER:
        raise SystemExit(f"metrics.primary doit être l'une de {sorted(HIGHER_IS_BETTER)}")

    mlflow.set_tracking_uri(os.getenv("MLFLOW_TRACKING_URI", "http://localhost:5000"))
    client = MlflowClient()
    run = find_run(client, metric, args.run_id, args.filter)
    score = run.data.metrics[metric]

    # Une seule version par run : relancer le script ne crée pas de doublon
    existing = client.search_model_versions(
        f"name = '{MODEL_NAME}' and run_id = '{run.info.run_id}'"
    )
    if existing:
        version = existing[0].version
        print(f"Run {run.info.run_name} déjà enregistré : version {version}")
    else:
        # MLflow 3 : le modèle loggé par le run est un « LoggedModel » (models:/m-...)
        model_id = run.outputs.model_outputs[0].model_id
        mv = mlflow.register_model(f"models:/{model_id}", MODEL_NAME)
        version = mv.version
        print(f"Run {run.info.run_name} enregistré : {MODEL_NAME} version {version}")

    passed = score >= threshold
    tags = {
        metric: f"{score:.4f}",
        "validation_status": "passed" if passed else "failed",
        "data_md5": run.data.tags.get("data_md5", "unknown"),
    }
    for key, value in tags.items():
        client.set_model_version_tag(MODEL_NAME, version, key, value)

    client.set_registered_model_alias(MODEL_NAME, "challenger", version)
    print(f"  @challenger -> version {version} ({metric} = {score:.4f})")
    if passed:
        client.set_registered_model_alias(MODEL_NAME, "champion", version)
        print(f"  @champion   -> version {version} ({metric} >= seuil {threshold})")
    else:
        try:
            current = client.get_model_version_by_alias(MODEL_NAME, "champion").version
        except mlflow.exceptions.MlflowException:
            current = "aucun"
        print(f"  champion inchangé (version {current}) : {metric} < seuil {threshold}")


if __name__ == "__main__":
    main()
```

```bash
python -m src.promote
```

> **Sortie attendue :**

```text
Successfully registered model 'scoring-model'.
Created version '1' of model 'scoring-model'.
Run logistic_regression-C=0.1-class_weight=None enregistré : scoring-model version 1
  @challenger -> version 1 (roc_auc = 0.8095)
  @champion   -> version 1 (roc_auc >= seuil 0.7)
```

Relancez la même commande : le script répond `déjà enregistré : version 1` sans créer de
doublon (un script de promotion doit être **idempotent**, la CI le relancera).

### 7.3 Le seuil en action

Demandez maintenant la promotion du modèle naïf :

```bash
python -m src.promote --filter "params.model = 'dummy'"
```

> **Sortie attendue :** `Created version '2' of model 'scoring-model'.`, puis
> `@challenger -> version 2 (roc_auc = 0.5000)` et
> `champion inchangé (version 1) : roc_auc < seuil 0.7`.

Dans l'UI, onglet **Models** → `scoring-model` : deux versions, l'alias `@champion` sur la
version 1, `@challenger` sur la version 2, et pour chaque version les tags `roc_auc`,
`validation_status` (`passed` / `failed`) et `data_md5`. Le seuil vient de `dataset.yaml` : aucun
modèle sous 0,70 ne peut devenir champion, quel que soit le script qui le propose.

### 7.4 Charger le modèle champion

```bash
python - <<'EOF'
import mlflow

from src.dataset_config import load_config
from src.train import TEST_CSV

# L'alias suffit : ni run, ni numéro de version, ni code d'entraînement
uri = "models:/scoring-model@champion"
model = mlflow.sklearn.load_model(uri)
threshold = mlflow.models.get_model_info(uri).metadata["decision_threshold"]
X_test, _ = load_config().read_xy(TEST_CSV)
proba = model.predict_proba(X_test.head(5))[:, 1]
print(f"seuil de décision : {threshold:.3f}")
print("P(bad) :", proba.round(2))
print("refus  :", (proba >= threshold).astype(int))
EOF
```

> **Sortie attendue :** une barre `Downloading artifacts`, puis `seuil de décision : 0.167` (le
> champion, version 1, est entraîné sans poids), `P(bad) : [0.31 0.15 0.56 0.44 0.18]` et
> `refus  : [1 0 1 1 1]` : quatre demandes sur cinq dépassent 1/6. Le modèle **et** son seuil
> viennent du registry : c'est exactement ce que votre future API servira.

> [!IMPORTANT]
> **Point de validation clé**
> Vous venez de séparer l'entraînement (Data Science) de la consommation (Serving). Aucun
> consommateur du modèle n'a besoin de connaître le code d'entraînement ni les
> hyper-paramètres : il demande juste `models:/scoring-model@champion`. C'est le découplage le
> plus important de MLOps.

```bash
git add src/promote.py && git commit -m "feat: promotion par alias avec seuil de qualité"
```

## Étape 8/10 — Construire le pipeline DVC complet et tester la repro (15 min)

On transforme les scripts lancés à la main en un pipeline DVC reproductible : chaque étape
devient une **stage** avec ses dépendances, ses paramètres et ses sorties.

### 8.1 Script d'évaluation

`src/train.py` évalue déjà le modèle pour MLflow ; on ajoute une stage `evaluate` qui relit le
modèle local (`models/model/`) et écrit les métriques dans un fichier versionné, que DVC sait
comparer d'une version à l'autre. Créez `src/evaluate.py` :

```python
# Fichier : src/evaluate.py
"""Évalue le modèle local (models/model) sur le jeu de test -> reports/metrics.json.

Stage DVC « evaluate » : ne dépend que de fichiers versionnés (pas du serveur MLflow),
pour que `dvc metrics show` / `dvc metrics diff` comparent les versions du pipeline.
Le seuil de décision est celui choisi par src/train.py (métadonnées du modèle).
"""

import json
from pathlib import Path

import mlflow
from mlflow.models import Model
from sklearn.metrics import confusion_matrix

from src.dataset_config import load_config
from src.train import MODEL_DIR, TEST_CSV, compute_metrics

METRICS_JSON = Path("reports/metrics.json")


def main() -> None:
    cfg = load_config()
    X_test, y_test = cfg.read_xy(TEST_CSV)
    model = mlflow.sklearn.load_model(str(MODEL_DIR))
    threshold = Model.load(str(MODEL_DIR)).metadata["decision_threshold"]

    proba = model.predict_proba(X_test)[:, 1]
    metrics = compute_metrics(cfg, y_test, proba, threshold)
    tn, fp, fn, tp = confusion_matrix(y_test, (proba >= threshold).astype(int)).ravel()
    report = {
        **{k: round(float(v), 4) for k, v in metrics.items()},
        "decision_threshold": round(threshold, 4),
        "confusion": {"tn": int(tn), "fp": int(fp), "fn": int(fn), "tp": int(tp)},
        "n_test": int(len(y_test)),
    }
    METRICS_JSON.parent.mkdir(parents=True, exist_ok=True)
    METRICS_JSON.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"{cfg.primary_metric} = {report[cfg.primary_metric]} -> {METRICS_JSON}")


if __name__ == "__main__":
    main()
```

### 8.2 Le `dvc.yaml` complet

Remplacez le contenu de `dvc.yaml` (la stage `download` reste identique) :

```yaml
# Fichier : dvc.yaml
# Pipeline du projet : download -> prepare -> train -> evaluate.
# `dvc repro` ne relance que les stages dont une dépendance (deps, params) a changé.
stages:
  download:
    cmd: python -m src.download
    deps:
      - src/dataset_config.py
      - src/download.py
    params:
      - dataset.yaml:
          - features
          - raw_path
          - target
    outs:
      - data/raw/dataset.csv
  prepare:
    cmd: python -m src.prepare
    deps:
      - src/dataset_config.py
      - src/prepare.py
      - data/raw/dataset.csv
    params:
      - dataset.yaml:
          - features
          - split
          - target
      - prepare
    outs:
      - data/processed/train.csv
      - data/processed/test.csv
      - data/processed/features.parquet
  train:
    cmd: python -m src.train
    deps:
      - src/dataset_config.py
      - src/train.py
      - data/processed/train.csv
      - data/processed/test.csv
    params:
      - dataset.yaml:
          - metrics
      - train
    outs:
      - models/model
  evaluate:
    cmd: python -m src.evaluate
    deps:
      - src/evaluate.py
      - src/train.py
      - models/model
      - data/processed/test.csv
    params:
      - dataset.yaml:
          - metrics
    metrics:
      - reports/metrics.json:
          cache: false
```

- Chaque stage déclare ce qu'elle lit (`deps`, `params`) et ce qu'elle produit (`outs`,
  `metrics`) : DVC en déduit le graphe (`dvc dag` pour l'afficher).
- `params` peut viser une section de `params.yaml` (`train`) ou des clés précises d'un autre
  fichier (`dataset.yaml: metrics`) : changer le seuil de promotion relance `train` et
  `evaluate`, pas `prepare`.
- `models/model` (le dossier MLflow écrit par `train.py`) est une sortie : il va dans le cache
  et le remote DVC, comme les données.
- `reports/metrics.json` est déclaré en `metrics` avec `cache: false` : petit fichier texte,
  versionné directement par **Git**.

### 8.3 Exécuter le pipeline

```bash
dvc dag
dvc repro
dvc metrics show
```

> **Sortie attendue :** `dvc dag` dessine `download → prepare → train → evaluate`. `dvc repro`
> affiche `Stage 'download' didn't change, skipping` (déjà exécutée à l'étape 2), puis exécute
> `prepare`, `train` (un nouveau run MLflow, avec `launched_by=dvc`) et `evaluate`
> (`roc_auc = 0.8094 -> reports/metrics.json`), et met à jour `dvc.lock`. `dvc metrics show` :

```text
Path                  accuracy    average_precision    business_cost    confusion.fn    ...
reports/metrics.json  0.6         0.6463               108.0            7               ...
```

(colonnes suivantes : `confusion.fp 73`, `confusion.tn 67`, `confusion.tp 53`,
`decision_threshold 0.3182`, `f1 0.5699`, `n_test 200`, `precision 0.4206`, `recall 0.8833`,
`roc_auc 0.8094`.) Au seuil 0,318, le modèle refuse 126 demandes sur 200 et ne laisse passer que
7 mauvais payeurs sur 60 : accuracy faible (0,60), coût minimal.

### 8.4 Enregistrer le modèle produit par le pipeline

Le modèle qui doit aller en production est celui que le pipeline sait **reproduire** :

```bash
python -m src.promote --filter "tags.launched_by = 'dvc'"
```

> **Sortie attendue :** `Created version '3' of model 'scoring-model'.`,
> `@challenger -> version 3 (roc_auc = 0.8094)` et `@champion -> version 3 (roc_auc >= seuil
> 0.7)`. Le champion a maintenant une traçabilité complète : commit Git
> (`mlflow.source.git.commit`), données (`data_md5` = hash de `dvc.lock`), paramètres
> (`params.yaml`) et métriques (`reports/metrics.json`).

> [!NOTE]
> **Le seuil n'est pas une comparaison**
> La version 3 (0,8094) remplace la version 1 (0,8095) : `promote.py` vérifie un seuil
> **absolu**, il ne compare pas le candidat au champion en place. Ici c'est voulu (la version 3
> coûte 108 au lieu de 113). Au Lab 6, le pipeline d'entraînement continu ajoutera la
> comparaison challenger / champion avant toute promotion.

Commitez cet état (le commit sert de référence pour les comparaisons suivantes) :

```bash
git add dvc.yaml dvc.lock src/evaluate.py data/processed/.gitignore models/.gitignore \
  reports/metrics.json
git commit -m "feat: pipeline DVC complet (download -> prepare -> train -> evaluate)"
```

### 8.5 Changer un paramètre et comparer

```bash
sed -i 's/^  class_weight: balanced/  class_weight: none/' params.yaml
dvc status
dvc repro
dvc params diff
dvc metrics diff
```

(sur macOS, `sed -i ''` au lieu de `sed -i`.)

> **Sortie attendue :** `dvc status` signale `train: changed deps: params.yaml: modified:
> train`. `dvc repro` saute `download` et `prepare` et ne relance que `train` et `evaluate`.
> Puis :

```text
Path         Param               HEAD      workspace
params.yaml  train.class_weight  balanced  none

Path                  Metric              HEAD    workspace    Change
reports/metrics.json  accuracy            0.6     0.575        -0.025
reports/metrics.json  average_precision   0.6463  0.6639       0.0176
reports/metrics.json  business_cost       108.0   113.0        5.0
reports/metrics.json  confusion.fp        73      78           5
reports/metrics.json  confusion.tn        67      62           -5
reports/metrics.json  decision_threshold  0.3182  0.1667       -0.1515
reports/metrics.json  f1                  0.5699  0.555        -0.0149
reports/metrics.json  precision           0.4206  0.4046       -0.016
reports/metrics.json  roc_auc             0.8094  0.8095       0.0001
```

Sans poids de classes, le seuil coût-optimal tombe de 0,318 à 0,167 et compense presque
entièrement : ROC AUC identique, 5 bons clients de plus refusés, +5 de coût (DVC n'affiche que
les métriques qui ont changé : rappel et faux négatifs sont identiques). Au seuil fixe de 0,5,
le même changement aurait coûté +55. On revient à la configuration commitée :

```bash
git checkout params.yaml
dvc repro
```

> **Sortie attendue :** `Stage 'train' is cached - skipping run, checking out outputs` (et de même
> pour `evaluate`). DVC a reconnu une combinaison code + données + paramètres déjà calculée : il
> restaure les sorties depuis son **run-cache** au lieu de réentraîner. `git status` ne montre
> plus aucune modification.

Poussez les nouvelles sorties (données préparées, modèle local) vers le remote :

```bash
dvc push
```

> **Sortie attendue :** `9 files pushed` (les deux versions du modèle et les fichiers préparés).

## Étape 9/10 — Un feature store local avec Feast (15 min)

### 9.1 Pourquoi un feature store ?

Le cours l'a montré : quand l'équipe data calcule les features dans un notebook et que l'équipe
backend les recode dans l'API, les deux implémentations divergent (*training/serving skew*). Un
feature store fournit **une seule définition** des features et **deux modes d'accès** :

| Notion Feast | Dans notre projet |
|---|---|
| **Entity** (entité) | `request` : une demande de crédit, clé `request_id` |
| **Data source** | `data/processed/features.parquet`, écrit par `src/prepare.py` |
| **FeatureView** | `request_features` : les 20 features de `dataset.yaml`, typées |
| **FeatureService** | `scoring_v1` : l'ensemble de features consommé par `scoring-model` |
| **Offline store** | Les fichiers Parquet : `get_historical_features` pour construire un jeu d'entraînement |
| **Online store** | SQLite local (`features/data/online_store.db`) : `get_online_features` en quelques ms |
| **Registry** | `features/data/registry.db` : les définitions appliquées par `feast apply` |
| **Materialize** | Copie des dernières valeurs du store hors ligne vers le store en ligne |

En production, l'offline store serait BigQuery, Snowflake ou du Parquet sur S3, et l'online store
Redis ou DynamoDB : seul `feature_store.yaml` change.

### 9.2 Pourquoi un `request_id` ?

Feast indexe les features par **entité** : il lui faut une clé pour retrouver « les features de
la demande n° 829 ». Le fichier brut n'en a pas, c'est pourquoi `prepare.py` a créé `request_id`
(étape 4.2). Feast exige aussi un **horodatage** par ligne (`event_timestamp`) : il fait des
jointures temporelles (« la valeur des features telle qu'elle était à la date de la demande »),
ce qui évite d'entraîner un modèle avec des informations du futur.

### 9.3 Définir le feature store

Créez le dossier `features/` et ses deux fichiers :

```yaml
# Fichier : features/feature_store.yaml
# Feature store local du projet : registre et store en ligne dans des fichiers SQLite
# (features/data/, ignoré par Git, recréé par `feast apply`), store hors ligne = Parquet.
project: scoring
registry: data/registry.db
provider: local
offline_store:
  type: file
online_store:
  type: sqlite
  path: data/online_store.db
entity_key_serialization_version: 3
auth:
  type: no_auth
```

```python
# Fichier : features/definitions.py
"""Définitions Feast du projet : construites depuis dataset.yaml (aucune colonne en dur).

`feast apply` (lancé dans features/) importe ce fichier et enregistre dans le registre :
  - l'entité « request » (une demande, clé = params.yaml > prepare.id_column) ;
  - la source hors ligne data/processed/features.parquet (produite par src/prepare.py) ;
  - la vue « request_features » (toutes les features de dataset.yaml) ;
  - le service « scoring_v1 » (l'ensemble de features consommé par le modèle).
"""

import sys
from datetime import timedelta
from pathlib import Path

import yaml
from feast import Entity, FeatureService, FeatureView, Field, FileSource, Project, ValueType
from feast.types import Float64, String

ROOT = Path(__file__).resolve().parents[1]  # racine du repo
sys.path.insert(0, str(ROOT))  # pour importer src.dataset_config depuis features/
from src.dataset_config import load_config  # noqa: E402

cfg = load_config(ROOT / "dataset.yaml")
id_column = yaml.safe_load((ROOT / "params.yaml").read_text(encoding="utf-8"))["prepare"][
    "id_column"
]

project = Project(name="scoring", description=f"Features du projet de scoring ({cfg.name})")

# Entité = la « clé primaire » des features : une demande de crédit
request = Entity(
    name="request",
    join_keys=[id_column],
    value_type=ValueType.INT64,
    description="Une demande de crédit (identifiant créé par src/prepare.py)",
)

# Source hors ligne : le Parquet écrit par src/prepare.py (sortie DVC)
request_source = FileSource(
    name="request_source",
    path=str(ROOT / "data" / "processed" / "features.parquet"),
    timestamp_field="event_timestamp",
)

# Vue de features : schéma déduit de dataset.yaml + source + durée de validité (ttl)
request_features = FeatureView(
    name="request_features",
    entities=[request],
    ttl=timedelta(days=3650),  # une demande reste valide 10 ans (jointure temporelle)
    schema=[Field(name=c, dtype=Float64) for c in cfg.numeric]
    + [Field(name=c, dtype=String) for c in cfg.categorical],
    source=request_source,
    online=True,
    tags={"dataset": cfg.name, "owner": "mlops-cours"},
)

# Service = la liste de features consommée par le modèle scoring-model
scoring_v1 = FeatureService(name="scoring_v1", features=[request_features])
```

Le schéma de la vue est **construit depuis `dataset.yaml`** (numériques en `Float64`,
catégorielles en `String`) : changer de dataset ne demande aucune modification ici. Le registre et
le store en ligne sont des fichiers locaux, recréés par `feast apply` : ils ne vont pas dans Git.
Le `.gitignore` du template contient déjà le bloc *Lab 1* : vérifiez-le avec
`grep -A8 'Lab 1 :' .gitignore`. Il ignore `features/data/` (registre et store en ligne SQLite de
Feast) et `mlruns/` / `mlflow.db` (traces MLflow locales créées par erreur quand
`MLFLOW_TRACKING_URI` n'est pas chargé) ; les données, `models/` et les sorties de stages sont
ignorés automatiquement par DVC (fichiers `.gitignore` dans `data/raw`, `data/processed`,
`models`).

### 9.4 Appliquer les définitions

```bash
cd features
feast apply
cd ..
```

> **Sortie attendue :** `Applying changes for project scoring`, `Created project scoring`,
> `Created entity request`, `Created feature view request_features`, `Created feature service
> scoring_v1`, puis `Created sqlite table scoring_request_features`.

### 9.5 Hors ligne : construire un jeu d'entraînement

On donne à Feast les clés, la cible et l'instant de chaque demande (*entity dataframe*) ; il
renvoie les features valides à cet instant :

```bash
python - <<'EOF'
import pandas as pd
import yaml
from feast import FeatureStore

from src.dataset_config import load_config

cfg = load_config()
id_col = yaml.safe_load(open("params.yaml"))["prepare"]["id_column"]
store = FeatureStore(repo_path="features")

train = pd.read_csv("data/processed/train.csv")
entity_df = train[[id_col, cfg.target]].assign(event_timestamp=pd.Timestamp.now(tz="UTC"))
training_df = store.get_historical_features(
    entity_df=entity_df, features=store.get_feature_service("scoring_v1")
).to_df()
print("Hors ligne :", training_df.shape)
same = training_df.set_index(id_col)[cfg.numeric].sort_index().equals(
    train.set_index(id_col)[cfg.numeric].astype("float64").sort_index())
print("Mêmes valeurs que train.csv :", same)
EOF
```

> **Sortie attendue :** `Hors ligne : (800, 23)` (clé + cible + horodatage + 20 features) et
> `Mêmes valeurs que train.csv : True`.

### 9.6 En ligne : matérialiser et servir

```bash
cd features
feast materialize-incremental "$(date -u +%Y-%m-%dT%H:%M:%S)"
cd ..
python - <<'EOF'
import pandas as pd
import yaml
from feast import FeatureStore

from src.dataset_config import load_config

cfg = load_config()
id_col = yaml.safe_load(open("params.yaml"))["prepare"]["id_column"]
store = FeatureStore(repo_path="features")

first = int(pd.read_csv("data/processed/train.csv")[id_col].iloc[0])
online = store.get_online_features(
    features=store.get_feature_service("scoring_v1"), entity_rows=[{id_col: first}]
).to_dict()
print(f"En ligne ({id_col}={first}) :", {c: online[c][0] for c in cfg.features[:4]})
EOF
```

> **Sortie attendue :** `Materializing 1 feature views to 2026-10-05 … into the sqlite online
> store.` et `request_features from 2016-10-07 … to 2026-10-05 …` (fenêtre = `ttl` de 10 ans),
> puis `En ligne (request_id=829) : {'duration': 36.0, 'credit_amount': 8335.0,
> 'installment_commitment': 3.0, 'residence_since': 4.0}` : exactement la première ligne de
> `train.csv`, servie par clé depuis le store en ligne.

```bash
git add features/feature_store.yaml features/definitions.py
git commit -m "feat: feature store Feast (request_features, scoring_v1)"
```

> [!NOTE]
> **Et ensuite ?**
> Les labs suivants continuent de lire `data/processed/*.csv` pour rester simples ; ce feature
> store est votre premier contact avec Feast. Une extension du mini-projet peut le brancher
> sur l'API (Lab 4) : l'appelant n'envoie plus que `request_id`, l'API récupère les features en
> ligne.

## Étape 10/10 — Tester la reproductibilité complète (5 min)

### 10.1 Committer l'état final et ouvrir la pull request

Notez dans `NOTES.md` comment reproduire le projet (c'est un livrable du lab), poussez la
branche du lab et ouvrez la pull request :

```bash
dvc push
cat >> NOTES.md <<'EOF'

## Reproduire le projet (Lab 1)
- Cloner le repo, puis `make up`, `make pf`, `uv sync` et `source .venv/bin/activate`.
- Identifiants du remote DVC (jamais commités) :
  `dvc remote modify --local storage access_key_id mlops` et
  `dvc remote modify --local storage secret_access_key mlops-lab-secret`.
- Même cluster (remote déjà rempli) : `dvc pull` puis `dvc repro` (tout est « skipping »).
- Autre cluster (remote vide) : `dvc repro` puis `dvc push` ; ne pas commiter le `dvc.lock`
  régénéré (seul le hash du modèle change).
EOF
git add NOTES.md
git commit -m "docs: instructions de reproduction (Lab 1)"
git status            # plus rien à commiter : .env et data/ absents
git push -u origin lab/m1-versioning
gh pr create   # facultatif (GitHub CLI) : ou « Compare & pull request » sur GitHub
```

> **Sortie attendue :** `Everything is up to date.` pour `dvc push` (tout a été poussé à
> l'étape 8.5), un `git status` propre, puis la branche `lab/m1-versioning` sur GitHub et le
> lien de la pull request.

Votre partenaire relit la PR (`dvc.yaml`, `params.yaml`, les scripts de `src/`, `NOTES.md`) et
l'approuve ; vous la fusionnez, puis vous revenez sur `main` :

```bash
git switch main && git pull
```

### 10.2 Simuler un autre développeur, sur le même poste

Un clone tout frais, sur le même poste : il partage votre cluster, donc votre remote DVC, que
`dvc push` a rempli.

```bash
# Dans un autre dossier, tout frais
cd /tmp && rm -rf repro-test
git clone git@github.com:VOTRE_USER/mlops-cours-2026.git repro-test   # ou ~/mlops-cours-2026
cd repro-test

# Environnement : on réutilise le venv du cours (sinon : uv sync)
source ~/mlops-cours-2026/.venv/bin/activate

# Les identifiants S3 ne sont pas dans Git : chaque poste configure les siens
dvc remote modify --local storage access_key_id mlops
dvc remote modify --local storage secret_access_key mlops-lab-secret

# Récupérer les données et relancer le pipeline sans rien toucher
dvc pull
dvc repro
dvc metrics show
```

> **Sortie attendue :** `dvc pull` affiche `A data/raw/dataset.csv`, `A data/processed/…`,
> `A models/model/` puis `10 files fetched and 9 files added`. `dvc repro` répond
> `Stage 'download' didn't change, skipping` et de même pour `prepare`, `train` et `evaluate`,
> puis `Data and pipelines are up to date.` : tous les hashes correspondent à `dvc.lock`.
> `dvc metrics show` affiche les mêmes métriques que sur votre poste (`roc_auc 0.8094`).

### 10.3 La preuve forte : tout recalculer

`skipping` prouve que les fichiers sont identiques. Allons plus loin : on force la ré-exécution
de tout le pipeline, téléchargement compris.

```bash
dvc repro --force
dvc metrics diff --all
git diff --stat
```

> **Sortie attendue :** les quatre stages s'exécutent (un nouveau run MLflow est créé), puis
> `dvc metrics diff --all` affiche une colonne `Change` à `0` ou `0.0` pour **toutes** les
> métriques. `git diff --stat` ne montre que `dvc.lock` : seul le hash de `models/model` a changé,
> car le dossier MLflow contient l'identifiant du run et la date de création ; les données
> (mêmes MD5) et les prédictions (mêmes métriques) sont identiques. Nettoyez ensuite :
> `cd ~/mlops-cours-2026 && rm -rf /tmp/repro-test`.

> [!IMPORTANT]
> **Victoire !**
> Si `dvc repro` dit « didn't change, skipping », et si un `dvc repro --force` redonne les mêmes
> métriques, n'importe qui, n'importe où, peut régénérer votre modèle à partir de Git + le
> remote. C'est la définition opérationnelle de la reproductibilité ML : code (commit), données
> (`dvc.lock`), environnement (`uv.lock`), graines (`dataset.yaml`, `params.yaml`).

### 10.4 Sur un autre poste : reconstruire avec `dvc repro`

Sur un autre poste, le remote DVC est celui d'un autre cluster, vide (encadré « Un remote par
cluster », étape 2.3) : c'est le cas de votre partenaire de binôme, du jury, et de l'enseignant
qui reprend votre repo. La reproductibilité se prouve alors en recalculant tout. À faire en
autonomie sur une autre machine (environ 15 minutes, création du cluster comprise) ; votre
partenaire le fait de toute façon avec l'encadré ci-dessous.

```bash
cd ~ && git clone git@github.com:VOTRE_USER/mlops-cours-2026.git && cd mlops-cours-2026
cp .env.example .env && make up && make pf
uv sync && source .venv/bin/activate && set -a && source .env && set +a
dvc remote modify --local storage access_key_id "$AWS_ACCESS_KEY_ID"
dvc remote modify --local storage secret_access_key "$AWS_SECRET_ACCESS_KEY"
dvc pull                    # échoue : le remote de ce cluster est vide
dvc repro                   # download, prepare, train, evaluate : tout est recalculé
dvc metrics diff --all      # mêmes métriques que le commit
git status --short          # seul dvc.lock a changé
dvc push                    # remplit le remote de CE cluster
```

> **Sortie attendue :** `dvc pull` échoue sur des fichiers absents du remote (*missing cache
> files*) ; `dvc repro` exécute les quatre stages, et le téléchargement retrouve le MD5 inscrit
> dans `dvc.lock` (`24b8e38b…`) ; `dvc metrics diff --all` affiche `0` dans la colonne `Change`
> pour toutes les métriques ; `git status` ne montre que ` M dvc.lock` : seul le hash de
> `models/model` a changé (identifiant du run MLflow). Ne commitez **pas** ce `dvc.lock`.

> [!NOTE]
> **Second membre du binôme (ou nouveau poste) : remettre votre cluster à niveau**
> Une fois la PR du lab fusionnée, rejouez l'état de fin de lab sur **votre** cluster (Lab 0
> fait, `make pf` actif) : votre MLflow et votre remote DVC ne contiennent rien de ce lab.
>
> ```bash
> cd ~/mlops-cours-2026 && git switch main && git pull && uv sync
> source .venv/bin/activate && set -a && source .env && set +a
> dvc remote modify --local storage access_key_id "$AWS_ACCESS_KEY_ID"
> dvc remote modify --local storage secret_access_key "$AWS_SECRET_ACCESS_KEY"
> dvc repro && dvc push                       # données, modèle, métriques ; votre remote
> python -m src.grid_search                   # vos 20+ runs dans l'expérience scoring
> python -m src.promote && python -m src.promote --filter "params.model = 'dummy'"
> python -m src.promote --filter "tags.launched_by = 'dvc'"   # @champion = run DVC
> (cd features && feast apply && feast materialize-incremental "$(date -u +%Y-%m-%dT%H:%M:%S)")
> make check-m1
> ```
>
> Ne commitez pas le `dvc.lock` que `dvc repro` vient de réécrire : seul le hash de
> `models/model` change (il contient l'identifiant de **votre** run MLflow), et le commiter
> créerait un conflit avec votre partenaire à chaque lab. Laissez-le modifié en local ; avant un
> `git pull` qui le touche, `git checkout dvc.lock` puis `dvc repro`. `git status` ne doit
> montrer que `dvc.lock`. Le même principe vaut pour tous les labs suivants : on rejoue, on ne
> recommite pas ce qui ne change que d'identifiant de run.

## Checklist finale

Coché tout ? Vous avez validé le Module 1. `make check-m1` automatise ces vérifications (voir la
dernière section).

| # | Élément | Test | Résultat attendu | ☐ |
|---|---|---|---|---|
| 1 | Contrat de données | `python -c "from src.dataset_config import load_config; load_config()"` | Aucune erreur | ☐ |
| 2 | DVC initialisé | `cat .dvc/config` | Remote `storage` → `s3://dvc-store/scoring`, par défaut | ☐ |
| 3 | Identifiants hors Git | `cat .dvc/config.local` ; `git status` | Identifiants seulement dans `config.local` | ☐ |
| 4 | Dataset versionné | `cat dvc.lock` | Stage `download`, `md5` du CSV | ☐ |
| 5 | Push S3 OK | `aws-lab s3 ls --recursive s3://dvc-store/scoring/` | Objets sous `files/md5/` | ☐ |
| 6 | MLflow joignable | `curl http://localhost:5000/health` | `OK` | ☐ |
| 7 | 20+ runs tracés | UI MLflow, expérience `scoring` | ≥ 20 runs, 3 types de modèles + `dummy` | ☐ |
| 8 | Registry peuplé | UI → Models → `scoring-model` | ≥ 3 versions | ☐ |
| 9 | Alias posés | UI → Models → `scoring-model` | `@champion` (≥ seuil) et `@challenger` | ☐ |
| 10 | Pipeline DVC OK | `dvc repro` ; `dvc status` | Skip complet, `up to date` | ☐ |
| 11 | Métriques versionnées | `dvc metrics show` | `roc_auc`, `business_cost`, `decision_threshold`… | ☐ |
| 12 | Feast | `cd features && feast feature-views list` | `request_features` | ☐ |
| 13 | Reproductibilité | Clone + `dvc pull` + `dvc repro` (même poste) | « didn't change, skipping » | ☐ |
| 14 | Pull request fusionnée | `git log --oneline origin/main` | Fusion de `lab/m1-versioning` sur GitHub | ☐ |

## Critères d'évaluation (noté sur 20)

| Critère | Description | Points |
|---|---|---|
| Reproductibilité | `dvc repro` depuis un clone frais fonctionne sans modification ; `dvc.lock` est commité ; `dvc repro --force` redonne les mêmes métriques. | 6 |
| Qualité du tracking | Tous les runs ont paramètres (dont `decision_threshold`) + métriques (dont le coût métier) + tags explicites (`data_md5`, `launched_by`). Noms de run clairs. Expérience `scoring` organisée. | 6 |
| Pertinence du modèle | Le champion passe le seuil de `dataset.yaml` et est justifié (ROC AUC, coût métier). Au moins 3 types de modèles comparés + la référence naïve. | 4 |
| Propreté du code | Code modulaire (`prepare.py`, `train.py`, `promote.py`, `evaluate.py`). PEP 8 (`make lint`). Aucun nom de colonne ni chemin en dur hors `dataset.yaml` / `params.yaml`. | 4 |
| **Total** | | **20** |

## Rendu

- **Format** : votre fork `VOTRE_USER/mlops-cours-2026` sur GitHub (public, ou partagé avec
  l'enseignant), avec une capture de `make check-m1` entièrement vert.
- **Deadline** : avant le début du Module 2.
- **Ce qui doit être dans le repo** : tout le code (`src/`, `features/`), `dataset.yaml`,
  `params.yaml`, `dvc.yaml`, `dvc.lock`, `.dvc/config`, `reports/metrics.json`, `pyproject.toml`,
  `uv.lock`, et dans `NOTES.md` vos instructions de repro (étape 10.1), le tout fusionné dans
  `main` par la pull request du lab.
- **Ce qui ne doit PAS être dans le repo** : les données (gérées par DVC), le modèle local
  `models/` (DVC) et les artefacts (MLflow), `.venv/`, `.env`, `.dvc/config.local`,
  `features/data/`, `mlflow.db`, `mlruns/`.

## Annexe — Troubleshooting

| Symptôme | Cause probable | Solution |
|---|---|---|
| `dvc push` : `NoSuchBucket` | Bucket `dvc-store` absent (Job `create-buckets` du Lab 0 non terminé). | `make storage` (idempotent), puis `aws-lab s3 ls`. |
| `dvc push` : `Could not connect to the endpoint URL: "http://localhost:8333/…"` | Port-forward S3 arrêté. | `make pf`. |
| `dvc push` : `Unable to locate credentials` | Identifiants non configurés (clone frais, autre poste). | `dvc remote modify --local storage access_key_id mlops` (et `secret_access_key`). |
| `dvc push` : `SSL: WRONG_VERSION_NUMBER` | Endpoint en `https://` alors que SeaweedFS écoute en HTTP. | `dvc remote modify storage endpointurl http://localhost:8333`. |
| `dvc repro` (download) : `UCI indisponible … repli sur OpenML`, puis erreur réseau | Pas d'accès Internet. | Récupérer `german.data` (clé USB, autre poste) et lancer `python -m src.download --from-file german.data`, puis `dvc commit download`. |
| `ModuleNotFoundError: No module named 'src'` | Script lancé par son chemin ou hors de la racine. | Depuis `~/mlops-cours-2026` : `python -m src.train` (pas `python src/train.py`). |
| `ModuleNotFoundError: mlflow / dvc / feast` (ou dans `dvc repro`) | Venv non activé : `dvc.yaml` appelle `python`. | `source .venv/bin/activate` ou `uv run dvc repro`. |
| `dvc repro` ne fait rien après modification | Le fichier modifié n'est ni dans `deps` ni dans `params` de la stage. | Vérifier `dvc.yaml` ; `dvc status` dit ce que DVC surveille. |
| `dvc add` : `ERROR: cannot update 'dataset.csv': overlaps with an output of stage: 'download'` | Fichier à la fois `dvc add` et sortie de stage. | Garder une seule méthode (encadré 2.2) : `dvc remove data/raw/dataset.csv.dvc` ou supprimer la stage. |
| MLflow : `Connection refused` sur `localhost:5000` | Port-forward MLflow arrêté. | `make pf` ; `curl http://localhost:5000/health`. |
| MLflow UI vide après un run | `MLFLOW_TRACKING_URI` non chargé : runs écrits dans `./mlruns` local. | `set -a && source .env && set +a` ; supprimer `mlruns/`. |
| `log_model` : `The saved sklearn model references untrusted types` | Un type sérialisé par skops n'est pas dans `skops_trusted_types`. | Ajouter le type cité dans l'erreur à `SKOPS_TRUSTED_TYPES` (vérifier qu'il vient de scikit-learn ou numpy). |
| `predict` : `Can not safely convert int64 to float64` | DataFrame lu par `pd.read_csv` passé tel quel : la signature attend des `double`. | Charger les données avec `cfg.read_xy(chemin)`, qui convertit les numériques. |
| `promote` : `Aucun run avec la métrique « … »` | `metrics.primary` de `dataset.yaml` n'est pas une métrique loggée, ou expérience vide. | Utiliser une métrique de `compute_metrics` ; lancer `python -m src.grid_search`. |
| `MlflowException: Registered model alias champion not found` | Aucun modèle n'a encore passé le seuil. | `python -m src.promote` ; vérifier `metrics.promotion_threshold`. |
| Ancien code : `transition_model_version_stage` déprécié / `models:/…/Production` introuvable | Stages remplacés par les alias depuis MLflow 2.9. | `set_registered_model_alias(...)` et `models:/scoring-model@champion`. |
| `feast apply` : `ModuleNotFoundError: No module named 'src'` | `definitions.py` modifié sans la ligne `sys.path.insert(...)`. | Garder les deux lignes `ROOT = …` et `sys.path.insert(0, str(ROOT))`. |
| Feast : valeurs `None` en ligne | Store en ligne non matérialisé, ou fenêtre trop courte. | `feast materialize-incremental "$(date -u +%Y-%m-%dT%H:%M:%S)"` depuis `features/`. |
| `dvc pull` : `KeyError: remote` / `no remote specified` | `.dvc/config` non commité. | `git add .dvc/config && git commit` dans le repo d'origine, puis `git pull`. |

## Pour aller plus loin

- **Calibration et seuil empirique** : la formule du seuil suppose des probabilités bien
  calibrées. Tracez la courbe de calibration (`sklearn.calibration.CalibrationDisplay`), essayez
  `CalibratedClassifierCV`, ou balayez les seuils de 0 à 1 sur une validation croisée et comparez
  le seuil empirique à `cfg.cost_threshold(k)` avec `dvc metrics diff`.
- **`dvc exp run`** : lancer le grid search comme des *expériences DVC*
  (`dvc exp run -S train.C=1.0`) et les comparer avec `dvc exp show`.
- **Autologging** : `mlflow.sklearn.autolog()` et `GridSearchCV` (un run parent, des runs
  enfants).
- **Datasets MLflow** : `mlflow.log_input(mlflow.data.from_pandas(...))` pour afficher la version
  des données dans l'UI.
- Documentation : [DVC — pipelines](https://dvc.org/doc/user-guide/pipelines),
  [DVC — remotes S3](https://dvc.org/doc/user-guide/data-management/remote-storage/amazon-s3),
  [MLflow — Model Registry et alias](https://mlflow.org/docs/latest/ml/model-registry/),
  [MLflow — signatures](https://mlflow.org/docs/latest/ml/model/signatures/),
  [Feast — quickstart](https://docs.feast.dev/getting-started/quickstart),
  [German Credit (UCI)](https://archive.ics.uci.edu/dataset/144/statlog+german+credit+data).

> [!NOTE]
> **Prochaine étape**
> Module 2 — Pipelines ML & orchestration. Vous allez transformer le pipeline DVC de ce lab en un
> pipeline Kubeflow natif Kubernetes (`scoring-pipeline`), avec des composants, des artefacts
> typés et un enregistrement dans la même expérience MLflow `scoring`. Gardez ce repo en état :
> il est votre point de départ.

## Vérification automatique

Depuis la racine du repo, port-forwards actifs (`make pf`) :

```bash
make check-m1
```

Le script `labs/m1-versioning/check.sh` lit `dataset.yaml` (cible, métrique primaire, seuil) et
vérifie, sans rien modifier :

- le contrat : `dataset.yaml` valide (`src.dataset_config`) et fichier brut conforme ;
- DVC : remote par défaut `storage` → `s3://dvc-store/scoring` avec un endpoint, identifiants
  uniquement dans `.dvc/config.local`, stages `download`, `prepare`, `train`, `evaluate` +
  `params.yaml` + `dvc.lock`, code et pointeurs commités sans les données, `dvc status` à jour,
  données poussées (`dvc status --cloud` : remote joignable et synchronisé),
  `reports/metrics.json` contenant la métrique primaire ;
- MLflow : `/health`, au moins 20 runs terminés dans `scoring` avec la métrique primaire et le
  paramètre `decision_threshold`, au moins 3 types de modèles (hors
  `dummy`), un run lancé par DVC dont le `data_md5` est celui de `dvc.lock` ;
- Registry : `scoring-model` avec au moins 3 versions, `@champion` dont la métrique primaire
  atteint `promotion_threshold`, `@challenger` présent, modèle champion chargé et utilisé pour
  prédire 5 lignes du jeu de test ;
- Feast : registre contenant `request_features`, store en ligne matérialisé (features non nulles
  pour une demande).

Chaque item affiche ✅ ou ❌ (avec l'étape à revoir) ; le code retour est le nombre d'échecs.

> **Sortie attendue :** `🎉 18/18 vérifications OK — Lab 1 validé.`
