# Dataset card — Statlog German Credit

<!--
Fiche descriptive du jeu de données (inspirée de « Datasheets for Datasets », Gebru et al., 2021).
Elle est PRÉ-REMPLIE pour le fil rouge German Credit : si vous gardez ce dataset, relisez-la,
complétez les champs [À compléter] et ajoutez ce que vous avez découvert vous-mêmes (Lab 3 :
validation, Lab 8 : équité). Si vous changez de dataset, réécrivez-la entièrement en gardant
les mêmes sections. Les chiffres doivent être ceux de VOS données (data/raw/dataset.csv).
Le pré-contrôle de rendu (make check-m10) refuse une fiche qui contient encore « [À compléter ».
-->

| Champ | Valeur |
|---|---|
| Nom (`dataset.yaml` → `name`) | `german-credit` |
| Source | [UCI ML Repository, dataset 144](https://archive.ics.uci.edu/dataset/144/statlog+german+credit+data) |
| Licence | CC BY 4.0 (attribution obligatoire, voir « Citation ») |
| Obtention | `python -m src.download` → `data/raw/dataset.csv` (libellés décodés comme OpenML `credit-g`) |
| Version suivie | DVC, remote `storage` (`s3://dvc-store/scoring`), hash : [À compléter : `md5` de `data/raw/dataset.csv` dans `dvc.lock`] |
| Taille | 1 000 lignes × 21 colonnes (20 variables + cible), ≈ 140 Ko en CSV |
| Tâche | Classification binaire supervisée |
| Cible | `credit_risk` ∈ {`good`, `bad`} ; classe positive (à détecter) : `bad` |
| Responsables de la fiche | [À compléter : @pseudo-1, @pseudo-2] |
| Dernière mise à jour | [À compléter : AAAA-MM-JJ] |

## 1. Motivation

- **Pourquoi ce jeu de données ?** Fil rouge du cours : petit (entraînement en quelques
  secondes sur un portable), tabulaire, à enjeu réel (décision de crédit) et doté
  d'attributs sensibles, ce qui permet de travailler l'équité (Lab 8) et la conformité.
- **Qui l'a créé ?** Prof. Hans Hofmann (Université de Hambourg), diffusé en 1994 dans le
  cadre du projet européen Statlog, puis sur le dépôt UCI.
- **Pour quel usage ?** Benchmark académique de classification. Il n'a **pas** été conçu
  pour entraîner un système de décision réel.

## 2. Composition

- **Une ligne = une demande de crédit à la consommation** accordée par une banque du sud de
  l'Allemagne, avec le comportement de remboursement observé ensuite.
- **Variables** (déclarées dans `dataset.yaml`) :
  - 7 numériques : `duration` (mois, 4 à 72), `credit_amount` (DM, 250 à 18 424, médiane
    2 320), `installment_commitment` (1-4), `residence_since` (1-4), `age` (19 à 75 ans),
    `existing_credits`, `num_dependents` ;
  - 13 catégorielles : `checking_status`, `credit_history`, `purpose` (10 modalités),
    `savings_status`, `employment`, `personal_status`, `other_parties`,
    `property_magnitude`, `other_payment_plans`, `housing`, `job`, `own_telephone`,
    `foreign_worker`.
- **Répartition de la cible :** 700 `good` (70 %), 300 `bad` (30 %).
- **Qualité :** aucune valeur manquante, aucun doublon exact (vérifié par
  [À compléter : la suite GX du Lab 3, ex. `gx/…`]).
- **Données personnelles :** pas d'identifiant direct (nom, adresse, numéro). Les lignes
  décrivent néanmoins des personnes physiques (âge, situation familiale, emploi,
  nationalité) : un jeu équivalent issu d'une vraie banque serait soumis au RGPD.

## 3. Attributs sensibles

Déclarés dans `dataset.yaml` → `sensitive`, analysés au Lab 8 et surveillés au Lab 7.

| Attribut | Groupes | Effectifs | Taux de `bad` observé |
|---|---|---|---|
| `age` (découpé) | `<25` / `>=25` | 149 / 851 | 41 % / 28 % |
| `personal_status` | `male single` / `female div/dep/mar` / `male mar/wid` / `male div/sep` | 548 / 310 / 92 / 50 | 27 % / 35 % / 27 % / 40 % |
| `foreign_worker` | `yes` / `no` | 963 / 37 | 31 % / 11 % |

> [!WARNING]
> **`personal_status` ne permet pas de retrouver le sexe de façon fiable.** La modalité
> `female div/dep/mar` (code UCI `A92`) regroupe en réalité des femmes non célibataires **et**
> des hommes célibataires (Grömping, 2019). Toute conclusion « par sexe » tirée de cette
> colonne est fragile : l'écrire dans la model card plutôt que de l'ignorer.

## 4. Collecte et biais connus

- **Période :** demandes de crédit de **1973 à 1975** (diffusion 1994). Les montants sont en
  Deutsche Mark ; le contexte économique et réglementaire n'a plus rien d'actuel.
- **Échantillonnage :** les mauvais payeurs ont été **sur-échantillonnés** pour équilibrer
  les classes : 30 % de `bad` ici, bien plus que dans le portefeuille réel. Les
  probabilités prédites ne sont donc pas calibrées sur une population réelle.
- **Biais de sélection :** seules les demandes **accordées** figurent dans les données (on ne
  sait pas comment auraient remboursé les personnes refusées : *reject inference*).
- **Erreurs de codage documentées :** la documentation UCI d'origine contient des codages
  erronés (Grömping, 2019, à l'origine du jeu corrigé « South German Credit », UCI 522). En
  particulier, le codage de `foreign_worker` serait **inversé** (moins de 5 % de demandeurs
  allemands serait invraisemblable). On garde la version Statlog pour rester comparable à la
  littérature, mais ces limites doivent apparaître dans la model card.
- **Petit volume :** 1 000 lignes, 37 travailleurs « non étrangers » : les métriques par
  sous-groupe ont de larges intervalles de confiance.

## 5. Prétraitement

- `src/download.py` décode les codes UCI (`A11`, `A43`…) en libellés lisibles (ceux du jeu
  OpenML `credit-g`) et renomme la cible en `credit_risk` ; aucune ligne n'est supprimée.
- Le prétraitement d'entraînement est défini une seule fois dans
  `src/dataset_config.py` (`build_preprocessor`) : imputation (médiane / modalité la plus
  fréquente), standardisation des numériques, encodage one-hot des catégorielles
  (`handle_unknown="ignore"`). Il est embarqué dans le modèle servi (pas de *skew*
  entraînement / service).
- Découpage : 80 / 20 stratifié, `random_state` 42 (`dataset.yaml` → `split`).
- [À compléter : vos transformations supplémentaires éventuelles, ou « aucune ».]

## 6. Usages

- **Prévus :** apprentissage du MLOps (pipeline, validation, déploiement, monitoring,
  analyse d'équité et d'explicabilité).
- **Déconseillés :** toute décision réelle d'octroi de crédit ; toute conclusion sur le
  comportement de remboursement selon le sexe, l'âge ou la nationalité.
- **Matrice de coûts** (`dataset.yaml` → `metrics.cost_matrix`) : accorder un crédit à un
  mauvais payeur (faux négatif) coûte **5**, refuser un bon payeur (faux positif) coûte
  **1**. C'est ce coût, plus que l'accuracy, qui guide le choix du seuil de décision.
- **Cadre réglementaire :** le scoring de crédit de personnes physiques est un système
  d'IA **à haut risque** au sens de l'AI Act (annexe III) ; l'article 22 du RGPD encadre
  les décisions entièrement automatisées.

## 7. Distribution et maintenance

- Licence CC BY 4.0 : réutilisation libre avec attribution. Les données brutes ne sont pas
  commitées dans Git : elles sont versionnées par DVC sur le remote S3 du cours.
- Le jeu source n'évolue plus. Toute modification locale (nettoyage, enrichissement) passe
  par `src/download.py` ou une étape `dvc.yaml`, jamais par une édition à la main.
- [À compléter : écarts constatés pendant le projet — anomalies trouvées par GX, drift simulé
  au Lab 7, etc.]

## Citation

Hofmann, H. (1994). *Statlog (German Credit Data)* [jeu de données]. UCI Machine Learning
Repository. https://doi.org/10.24432/C5NC77

Grömping, U. (2019). *South German Credit Data: Correcting a Widely Used Data Set*. Reports in
Mathematics, Physics and Chemistry 4/2019, Beuth University of Applied Sciences Berlin.
