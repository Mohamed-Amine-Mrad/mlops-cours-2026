---
doc_type: syllabus
cover_kicker: "COURS MLOps"
title: "Machine Learning Operations"
subtitle: "Syllabus, plan de cours et labs — 36 heures"
cover_fields:
  - ["Public", "Cycle Ingénieur Informatique — 3e année"]
  - ["Volume", "36 heures · 11 modules · 14h cours + 22h labs"]
  - ["Prérequis", "ML, DL, Docker, Kubernetes, Cloud, DevOps"]
  - ["Pédagogie", "Ateliers, labs guidés, mini-projet en binôme construit lab après lab"]
  - ["Cas d'usage", "Credit scoring (German Credit) ou dataset libre validé"]
  - ["Évaluation", "Labs (30 %) · Mini-projet (40 %) · Examen final (30 %)"]
  - ["Stack", "Kubernetes · SeaweedFS · MLflow · DVC · Kubeflow · KServe · Argo CD · Prometheus"]
running_title: "Cours MLOps — Syllabus & Index Global"
footer_left: "Cycle Ingénieur Informatique — 36h"
cover_footer_title: "Document maître du cours"
cover_footer_text: "Version 2.0 · octobre 2026 · À utiliser avec les supports par module (PPTX + labs PDF)"
---

# Préface — à qui s'adresse ce cours

*De l'expérimentation en notebook au système ML en production, d'un modèle isolé à une
plateforme ML industrialisée.*

## Positionnement

Ce cours s'adresse à des élèves ingénieurs de cycle informatique ayant déjà suivi des
enseignements en Machine Learning, Deep Learning, Cloud, Kubernetes, Docker et DevOps. Il ne
reprend donc pas les bases de ces disciplines — il se concentre sur ce qui les relie :
l'ingénierie système des applications de Machine Learning en production, communément appelée
« MLOps ». L'objectif n'est pas de former des Data Scientists supplémentaires, mais des
ingénieurs capables de rendre opérationnels, fiables et maintenables les modèles produits par
les Data Scientists.

## Philosophie pédagogique

Trois partis pris structurent ce cours. **Premièrement**, le ratio labs/cours est
volontairement élevé : 22h de labs pour 14h de cours magistraux, car les concepts MLOps ne se
retiennent qu'au contact des outils. **Deuxièmement**, l'ensemble des labs s'articule autour
d'une même stack Open Source de référence (Kubernetes, SeaweedFS, MLflow, DVC, Kubeflow,
KServe, Argo CD, Prometheus, Evidently) et d'un même cas d'usage, plutôt que de multiplier les
technologies : maîtriser une chaîne d'outils cohérente vaut mieux que survoler dix
écosystèmes. **Troisièmement**, le mini-projet (Module 10) n'est pas un projet à part : c'est
le repo que chaque binôme construit lab après lab sur un même cas d'usage (credit scoring par
défaut, ou dataset libre validé), vérifié automatiquement à la fin de chaque lab, complété par
une extension personnelle par étudiant et défendu en soutenance face à un incident provoqué en
direct.

## Le fil rouge : un modèle de credit scoring

Tous les labs s'appliquent au même problème : décider d'accorder ou non un crédit à la
consommation. Un modèle simple (une régression logistique fait très bien l'affaire) traverse
tout le cours : versionné, orchestré, validé, packagé, servi, déployé en continu, surveillé,
audité.

| Élément | Valeur par défaut |
|---|---|
| Dataset | Statlog German Credit (UCI), licence CC BY 4.0 — 1 000 demandes, 20 variables (7 numériques, 13 catégorielles) |
| Cible | `credit_risk` ∈ {`good`, `bad`}, classe positive `bad` (30 %) |
| Coûts métier | faux négatif (accorder un crédit à un mauvais payeur) = 5, faux positif (refuser un bon payeur) = 1 |
| Décision | seuil coût-optimal déduit de la matrice de coûts (≈ 0,17 sans poids de classes, ≈ 0,32 avec des poids équilibrés), et non 0,5 |
| Promotion d'un modèle | métrique primaire ROC AUC, seuil de promotion 0,70 ; baseline : régression logistique, ROC AUC ≈ 0,80 |
| Attributs sensibles | âge (`<25` / `>=25`), statut personnel (`personal_status`), travailleur étranger (`foreign_worker`) |

C'est un cas d'usage **à haut risque** au sens de l'AI Act (annexe III : évaluation de la
solvabilité des personnes physiques) : l'équité, l'explicabilité et la traçabilité y sont des
exigences, pas des options. Le projet est entièrement piloté par un fichier de contrat,
`dataset.yaml` : aucun nom de colonne, de cible, de classe ou de seuil n'est écrit en dur dans
le code, les manifests, les tests ou les vérifications. Changer de jeu de données, c'est
réécrire `dataset.yaml` et `src/download.py`, rien d'autre.

> [!IMPORTANT]
> **Dataset libre : validé avant le Lab 1**
> Un binôme peut remplacer le credit scoring par son propre jeu de données, à condition qu'il
> soit validé par l'enseignant **avant la séance du Lab 1 (S2)**. Conditions : tabulaire et
> classification supervisée (binaire de préférence), 1 000 à 100 000 lignes, moins de 50 Mo,
> licence ouverte, téléchargeable par un script (`src/download.py`), au moins un attribut
> sensible, aucune donnée identifiante. La proposition se fait par une issue sur le repo du
> cours. Le retour au credit scoring reste possible à tout moment, sans pénalité.

## Un repo, un binôme, un cluster par étudiant

Le cours est livré sous la forme d'un repo GitHub modèle, `mlops-cours-2026` : infrastructure
(`infra/`, pilotée par un `Makefile`), énoncés des labs (`labs/mX-*/README.md`), fichiers de
départ, vérifications automatiques et gabarits du mini-projet. Au Lab 0, chaque binôme en crée
**une** copie et y travaille jusqu'à la soutenance : chaque lab ajoute une brique au même
système. Chaque membre fait tourner le système complet sur son propre cluster kind, le travail
se fait par branches (`lab/mX-…` pour un lab, `ext/<nom>` pour une extension) et pull requests
relues par le partenaire, en alternant pilote et copilote d'un lab à l'autre ; chaque énoncé se
termine par les commandes qui remettent à niveau le cluster du membre qui n'a pas piloté. Un
poste à **16 Go de RAM** est requis à partir du Lab 2 (8 Go suffisent pour les Labs 0 et 1) :
un étudiant moins équipé le signale dès la première séance, pour qu'une solution de repli
(poste de l'école, machine virtuelle, poste du partenaire) soit en place avant la semaine 4.

Chaque lab se termine par `make check-mX`, qui vérifie l'état attendu item par item : l'étudiant
sait où il en est, et les mêmes vérifications servent à noter le socle du mini-projet. Après
chaque date de rendu, la correction du lab X est publiée dans le repo du cours (branche
`solution/mX`, et tag `start/m(X+1)` qui marque l'état de départ du lab suivant) : un binôme en
retard peut remettre son socle à niveau, de façon traçable.

## Ce que ce cours est — et ce qu'il n'est pas

> [!IMPORTANT]
> **Ce cours couvre**
>
> - Le cycle de vie complet d'un projet ML en production, de la donnée brute au modèle servi
> - Les pratiques d'ingénierie : versioning, CI/CD, orchestration, monitoring, observabilité
> - Le déploiement à l'échelle avec Kubernetes et les standards de l'industrie
> - Les enjeux spécifiques au ML : drift, reproductibilité, continuous training, governance
> - Les patterns spécialisés : LLMOps, Edge MLOps, Responsible AI
> - Un cas d'usage réel à haut risque (credit scoring), traité de bout en bout du Lab 0 à la
>   soutenance

> [!WARNING]
> **Ce cours ne couvre pas**
>
> - La théorie des modèles ML / DL — elle est supposée acquise (cours antérieurs)
> - L'administration avancée de Kubernetes — bases supposées acquises
> - Le développement Python avancé — niveau de base requis
> - Les fondamentaux DevOps (Git, CI, conteneurs) — supposés acquis
> - L'entraînement sur GPU et le fine-tuning de LLM — présentés en cours, aucun GPU n'est requis
>   en lab

## Comment utiliser ce document

Ce document maître se lit en amont du semestre par l'enseignant pour préparer son intervention,
et en début de semestre par les étudiants pour visualiser la progression. Chaque module dispose
par ailleurs de ses propres livrables détaillés : un support de cours (*PPTX*), un énoncé de lab
pas-à-pas (Markdown dans le repo du cours, *PDF* généré), le code de départ et la vérification
automatique (`make check-mX`) dans ce même repo, et les solutions correctives. Le mini-projet
(Module 10) est accompagné d'un énoncé détaillé (règles, catalogue de 16 extensions, jalons,
grille) et d'un pré-contrôle de rendu automatique (`make check-m10`). En cas de divergence,
l'énoncé de chaque lab fait foi pour son barème, et l'énoncé du Module 10 pour l'évaluation du
mini-projet.

# Nouveautés de la version 2.0

*Ce qui a changé depuis la version 1.0, et pourquoi.*

La version 2.0 reconstruit l'ensemble des labs à partir des supports de la version 1.0 : le
code annoncé est désormais fourni, vérifié et rejoué chaque semaine, et les briques devenues
obsolètes en 2026 ont été remplacées. Les objectifs, les volumes horaires, la progression des
modules et les compétences visées sont conservés.

| Domaine | Version 1.0 | Version 2.0 | Pourquoi |
|---|---|---|---|
| Organisation | Un dossier par lab, code annoncé mais non fourni, cluster recréé selon les labs | Un repo de cours modèle dans lequel le binôme travaille du Lab 0 à la soutenance ; infra par `make` ; `make check-mX` en fin de lab ; corrections publiées (branche `solution/mX`, tag `start/m(X+1)`) | Reproductibilité, rattrapage possible, notation outillée |
| Cas d'usage | Titanic | Credit scoring (German Credit) piloté par `dataset.yaml`, dataset libre validé avant le Lab 1, seuil de décision coût-optimal | Cas réel à coûts asymétriques et à haut risque : donne un objet aux labs d'équité, de monitoring par groupe et de gouvernance |
| Stockage S3 | MinIO | SeaweedFS (Apache 2.0, même API S3) | MinIO communautaire archivé, images retirées de Docker Hub en septembre 2026 ; SeaweedFS est le stockage par défaut de KFP depuis 2.15 |
| Tracking | Serveur MLflow lancé sur le poste, stages Staging / Production | Un seul serveur MLflow dans le cluster, proxy d'artefacts, alias `@champion` / `@challenger`, sérialisation skops | Stages dépréciés depuis MLflow 2.9 ; plus d'identifiants S3 côté clients |
| Tests de modèles | Deepchecks | Evidently + tests comportementaux en pytest | Deepchecks 0.19 est incompatible avec scikit-learn ≥ 1.8 et NumPy 2 |
| Packaging (Lab 4) | Syllabus : modèle PyTorch, image GPU ; lab : export ONNX de features déjà encodées | Pipeline scikit-learn complet exporté en ONNX (prétraitement dans le graphe), API FastAPI générique | Syllabus aligné sur le lab ; l'API reçoit les valeurs brutes ; aucun GPU |
| Serving (Lab 5) | Istio, mode RawDeployment, HPA sur le CPU | Kourier, mode Knative : autoscaling sur le débit, scale-to-zero, canary | Le canary de KServe n'existe qu'en mode Knative |
| Canary | Argo Rollouts (Lab 6, annoncé au Lab 7 par le syllabus) | Canary KServe piloté par Git (Lab 6), analysé par les métriques (Lab 7) | Argo Rollouts pilote des Deployments, pas un InferenceService |
| Observabilité | Promtail, ServiceMonitor, 3 alertes | Loki + Grafana Alloy, PodMonitor, alertes SLO (burn rate) avec runbooks | Promtail en fin de vie depuis le 2 mars 2026 ; les Services Knative n'exposent pas le port de l'API |
| Sécurité | Secret source en clair, distroless Python 3.11 | External Secrets (API v1), image durcie Python 3.12, RBAC minimal, ModelScan (pickle, ONNX, skops) | Aucun secret dans Git ; MLflow 3 ne produit plus de pickle |
| LLMOps (Lab 9) | Syllabus : modèle 7B servi par vLLM dans le cluster ; lab : Ollama (Llama 3 8B) ou vLLM | Ollama sur CPU (Qwen 3.5 4B) par défaut, vLLM sur GPU en option, sur le poste ; RAG isolé du socle ; Ragas 0.4, Phoenix, guardrails | Aucun GPU requis ; Qwen 3.5 4B fait mieux que Llama 3 8B pour deux fois moins de mémoire |
| Python | 3.11, installations par lab | 3.12, un environnement `uv` verrouillé pour le socle | Versions cohérentes, rejouées chaque semaine par la CI |
| Projet final | Capstone par équipes de 3-4, quatre sujets au choix | Mini-projet en binôme : socle M0-M8 + extension personnelle (catalogue de 16) + soutenance avec défi en direct, grille /40 refondue | Évaluer l'exploitation d'un système plutôt qu'une démo ; individualiser la note |

> [!NOTE]
> **Qui fait foi ?**
> En cas de divergence entre un support de cours (PPTX) et un énoncé de lab, l'énoncé fait foi :
> c'est lui qui est rejoué chaque semaine par la CI du cours, sur un cluster neuf.

# Table des matières synoptique

*Vue d'ensemble des 11 modules sur 36 heures.*

| # | Titre du module | Thème | Volume | Cours / Lab | Énoncé du lab | Noté sur |
|---|---|---|---|---|---|---|
| 0 | Introduction au MLOps | Fondamentaux | 2h | 1h / 1h | 1 h (+ 1 h de préparation avant la séance) | non noté |
| 1 | Versioning données, code & expériences | Reproductibilité | 4h | 2h / 2h | 2 h | 20 |
| 2 | Pipelines ML & orchestration | Automatisation | 5h | 2h / 3h | 3 h | 20 |
| 3 | Validation données & modèle | Qualité | 3h | 1h / 2h | 2 h | 20 |
| 4 | Conteneurisation & packaging des modèles | Packaging | 3h | 1h / 2h | 2 h | 20 |
| 5 | Serving & inférence à l'échelle | Déploiement | 5h | 2h / 3h | 3 h | 20 |
| 6 | CI/CD pour le ML (CT inclus) | Automatisation | 4h | 1h / 3h | 3 h | 20 |
| 7 | Monitoring & observabilité ML | Opération | 4h | 2h / 2h | 3 h | 20 |
| 8 | Sécurité, gouvernance & Responsible AI | Gouvernance | 2h | 1h / 1h | 3 h | 10 |
| 9 | LLMOps & Edge MLOps | Spécialisation | 2h | 1h / 1h | 2 h | 10 |
| 10 | Mini-projet & soutenances | Intégration | 2h | 0h / 2h | travail continu S1-S12 | 40 |

## Répartition du volume horaire

| Catégorie | Heures | Part |
|---|---|---|
| Cours magistraux | 14 h | 39 % |
| Labs guidés | 22 h | 61 % |
| **Total** | **36 h** | **100 %** |

> [!NOTE]
> **Pourquoi 22h de labs pour 14h de cours ?**
> Le MLOps est par nature une discipline d'ingénierie système : elle ne se réduit pas à des
> concepts. On ne « comprend » pas véritablement une pipeline Kubeflow en la lisant sur une
> slide ; on la comprend en la faisant casser, en l'orchestrant, et en déboguant les erreurs de
> permissions. Les 61 % de volume consacrés aux labs reflètent cette réalité.

> [!WARNING]
> **Trois énoncés dépassent leur séance**
> Les énoncés des Labs 7, 8 et 9 sont écrits pour 3 h, 3 h et 2 h, alors que le volume encadré
> leur réserve 2 h, 1 h et 1 h : environ 4 h de travail personnel s'ajoutent aux 22 h de labs.
> La fin de ces labs (interprétation, rapport) se termine en autonomie avant la séance suivante,
> et `make check-mX` permet à chacun de vérifier son état sans attendre l'enseignant. Le Lab 9
> tourne entièrement sur le poste, sans cluster.

# Objectifs généraux et compétences visées

*Les six compétences ciblées par le cours, et leur travail dans chaque module.*

## Compétences transversales (Learning Outcomes)

À l'issue du cours, l'élève est capable de :

| Code | Compétence |
|---|---|
| **C1** | Concevoir et mettre en œuvre un pipeline ML reproductible, de la donnée brute au modèle entraîné, en versionnant code, données et expériences. |
| **C2** | Orchestrer l'ensemble du cycle de vie ML à l'aide d'outils de workflow (Kubeflow, Airflow) sur infrastructure Kubernetes. |
| **C3** | Déployer des modèles ML en production selon différents patterns (online, batch, streaming, edge) en maîtrisant latence, throughput et coûts. |
| **C4** | Mettre en place des pipelines CI/CD/CT pour les systèmes ML, incluant tests de données, tests de modèles et promotion automatique entre environnements. |
| **C5** | Instrumenter, monitorer et maintenir des modèles en production : détection de drift, alerting, rollback, déploiement canary. |
| **C6** | Appliquer les principes de sécurité, gouvernance, équité et explicabilité aux systèmes ML en tenant compte des contraintes réglementaires (RGPD, EU AI Act). |

## Matrice compétences × modules

Chaque compétence est travaillée dans plusieurs modules. Niveau : ● introduction ·
●● approfondissement · ●●● maîtrise.

| Compétence | M0 | M1 | M2 | M3 | M4 | M5 | M6 | M7 | M8 | M9 | M10 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **C1** | ● | ●●● | ●● | ●● | | | | | | | ●●● |
| **C2** | ● | | ●●● | | | | ●● | | | | ●● |
| **C3** | | | | | ● | ●●● | | | | ●● | ●● |
| **C4** | | | ● | ●● | | | ●●● | | | | ●● |
| **C5** | | | | | | ● | ●● | ●●● | | ● | ●●● |
| **C6** | | | | | ● | | | | ●●● | ● | ● |

Au Module 10, le niveau atteint dépend aussi de l'extension choisie par chaque étudiant (le
catalogue couvre les six compétences) ; le défi en direct de la soutenance porte sur C5.

# Fiches des modules

*Pour chaque module : objectifs, plan du cours et du lab, outils, livrables et évaluation.*

Chaque fiche suit la même structure. Le volume indiqué en tête est le volume **encadré** ; la
durée de l'énoncé du lab, son dossier dans le repo du cours et la commande de vérification
figurent sous le plan. Tous les labs s'enchaînent dans le même repo et sur le même cluster :
on ne recrée jamais le cluster du Lab 0.

| Module | Énoncé (repo du cours) | Étapes | Durée de l'énoncé | Vérification |
|---|---|---|---|---|
| M0 | `labs/m0-setup/` | 8 | 1 h en séance + 1 h avant | `make check-m0` |
| M1 | `labs/m1-versioning/` | 10 | 2 h | `make check-m1` |
| M2 | `labs/m2-pipelines/` | 9 | 3 h | `make check-m2` |
| M3 | `labs/m3-validation/` | 7 | 2 h | `make check-m3` |
| M4 | `labs/m4-packaging/` | 9 | 2 h | `make check-m4` |
| M5 | `labs/m5-serving/` | 9 | 3 h | `make check-m5` |
| M6 | `labs/m6-cicd/` | 9 | 3 h | `make check-m6` |
| M7 | `labs/m7-monitoring/` | 10 | 3 h | `make check-m7` |
| M8 | `labs/m8-governance/` | 9 | 3 h | `make check-m8` |
| M9 | `labs/m9-llmops/` | 9 | 2 h | `make check-m9` |
| M10 | `labs/m10-capstone/` | — | travail continu S1-S12 | `make check-m10` (pré-contrôle de rendu) |

## Module 0 — Introduction au MLOps

| Thème | Volume | Cours / Lab | Prérequis |
|---|---|---|---|
| Fondamentaux | 2 h | 1h / 1h | ML, DL, Docker, K8s, DevOps ; poste à 16 Go de RAM (8 Go : Labs 0-1 seulement) |

### Objectifs pédagogiques

- Définir le MLOps et son périmètre vs DevOps et DataOps
- Identifier les sources spécifiques de dette technique des systèmes ML
- Décrire le cycle de vie complet d'un projet ML en production
- Positionner une organisation sur l'échelle de maturité Google (0 / 1 / 2)
- Préparer l'environnement de travail commun à tous les modules : cluster, stockage S3, MLflow,
  repo du binôme

### Plan du cours et du lab

| Plan du cours magistral | Plan du lab guidé |
|---|---|
| Pourquoi le MLOps : constat industriel, stats d'échec des projets ML | *Avant la séance* : vérifier Docker Engine + Docker Compose (10 min) |
| Dette technique ML (Sculley et al.) et différences avec le logiciel classique | *Avant la séance* : installer kubectl, helm, k9s et kind (10 min) |
| Définition et périmètre — MLOps vs DevOps vs DataOps | *Avant la séance* : créer le repo du binôme depuis le repo du cours (fork ou *Use this template*) et le cloner (10 min) |
| Cycle de vie ML end-to-end : des données au modèle servi | *Avant la séance* : Python 3.12 + uv, `uv sync`, `make prefetch` (25 min, dont 20 min de téléchargements) |
| Maturité MLOps : niveaux 0 / 1 / 2 | Créer le cluster kind (1 control-plane + 2 workers) et le registry local `localhost:5001` (10 min) |
| Rôles d'équipe : Data Engineer, Data Scientist, ML Engineer, MLOps Engineer | Déployer SeaweedFS (S3) et MLflow dans le cluster (15 min) |
| Stack & toolchain du cours | Smoke tests MLflow et DVC (10 min) |
| | Checklist de validation en 14 items + première pull request `lab/m0-setup` (10 min) ; 15 min de marge |

**Lab :** `labs/m0-setup/` · 8 étapes · 1 h en séance, précédée d'environ 1 h de préparation
(installations et téléchargements, environ 4 Go, à faire chez soi : trente postes qui
téléchargent en même temps sur le réseau de la salle ne tiennent pas dans l'heure) ·
vérification `make check-m0`.

### Outils & technologies

Docker, Kubernetes (kind), kubectl, helm, k9s, registry local, SeaweedFS (S3), MLflow, DVC,
Python 3.12, uv, Git / GitHub, make

### Livrables étudiant

- Capture de `make check-m0` entièrement vert (checklist de validation complète)
- Repo du binôme créé depuis le repo du cours, première pull request (`lab/m0-setup`)
  fusionnée

### Évaluation du module

Non noté — lab de setup obligatoire pour la suite du cours. La checklist validée
(`make check-m0` vert) conditionne l'accès au Module 1.

## Module 1 — Versioning données, code & expériences

| Thème | Volume | Cours / Lab | Prérequis |
|---|---|---|---|
| Reproductibilité | 4 h | 2h / 2h | Lab 0 réussi (`make check-m0` vert) |

### Objectifs pédagogiques

- Versionner des datasets avec DVC et un remote S3
- Tracker systématiquement les expériences ML avec MLflow
- Comprendre la notion de feature store et le rôle du feature engineering reproductible
- Mettre en place un model registry et promouvoir les modèles par alias (`@challenger`,
  `@champion`) derrière un seuil de qualité
- Choisir un seuil de décision à partir des coûts métier, et non par défaut à 0,5
- Assurer la reproductibilité bout-en-bout : code + données + env + seeds

### Plan du cours et du lab

| Plan du cours magistral | Plan du lab guidé |
|---|---|
| Pourquoi versionner les données ? Limites de Git pour le ML | Le contrat de données : cas métier, `dataset.yaml`, téléchargement et exploration (15 min) |
| DVC : architecture, cache, remotes, fichiers `.dvc`, pipelines `dvc.yaml` | Versionner les données avec DVC : stage `download` + remote `s3://dvc-store/scoring` (15 min) |
| LakeFS et alternatives pour les volumes massifs | Comprendre et vérifier le serveur MLflow du cours (5 min) |
| MLflow : Tracking, Projects, Models, Registry (versions et alias) | Scripts de préparation et d'entraînement instrumentés, seuil coût-optimal (20 min) |
| Weights & Biases : comparaison et complémentarité | Lancer 20+ runs avec un grid search (10 min) |
| Feature stores : Feast, concept d'online / offline store | Comparer les runs dans l'UI MLflow, sélectionner le meilleur (10 min) |
| Reproductibilité : seeds, déterminisme, lock files, environnements | Promouvoir des versions dans le Model Registry : alias + seuil de qualité (10 min) |
| | Pipeline DVC complet download → prepare → train → evaluate (15 min) |
| | Un feature store local avec Feast (15 min) |
| | Démontrer la reproductibilité : clone + `dvc pull` (même cluster), puis `dvc repro` + `dvc push` sur un autre poste (5 min + en autonomie) |

**Lab :** `labs/m1-versioning/` · 10 étapes · 2 h · vérification `make check-m1`.

### Outils & technologies

DVC, MLflow (registry à alias, sérialisation skops), Feast, SeaweedFS (S3), scikit-learn,
`dataset.yaml`, `pyproject.toml` + `uv.lock`

### Livrables étudiant

- Repo Git contenant le pipeline versionné (`dataset.yaml`, `params.yaml`, `dvc.yaml`,
  `dvc.lock`, `src/`, `features/`), sans données ni secrets
- MLflow Registry `scoring-model` avec au moins 3 versions, `@champion` et `@challenger`
- 20+ runs comparés dans l'expérience `scoring` (ROC AUC et coût métier), instructions de
  reproduction dans `NOTES.md`

### Évaluation du module

Noté sur 20 — critères : reproductibilité (6 pts), qualité du tracking (6 pts), pertinence du
modèle final (4 pts), propreté du code (4 pts). Remise : repo Git du binôme.

## Module 2 — Pipelines ML & orchestration

| Thème | Volume | Cours / Lab | Prérequis |
|---|---|---|---|
| Automatisation | 5 h | 2h / 3h | Labs 0 et 1 réussis |

### Objectifs pédagogiques

- Concevoir un pipeline ML sous forme de DAG
- Choisir un orchestrateur adapté au contexte (Kubeflow, Airflow, Prefect, Metaflow)
- Implémenter un pipeline complet sur Kubernetes avec Kubeflow Pipelines
- Gérer l'idempotence, les retries, le scheduling et le lineage
- Comparer plusieurs orchestrateurs sur le même cas d'usage

### Plan du cours et du lab

| Plan du cours magistral | Plan du lab guidé |
|---|---|
| Du script ad-hoc au DAG : pourquoi orchestrer ? | Installer Kubeflow Pipelines sur le cluster kind (20 min) |
| Comparatif Airflow / Prefect / Kubeflow / Metaflow / ZenML / Flyte | Convertir les scripts du Lab 1 en composants KFP, sur une image « projet » qui réutilise le code (35 min) |
| Kubeflow Pipelines en profondeur : composants, artifacts, caching | Pipeline ingest → validate → prepare → train → evaluate → register, testé en local (15 min) |
| Schématisation, idempotence, retries, scheduling | Uploader et exécuter sur le cluster ; artifacts typés via le S3 interne de KFP (15 min) |
| Lineage et traçabilité des données | Intégration MLflow : chaque run KFP produit un run et une version de `scoring-model` (20 min) |
| Patterns : fan-out / fan-in, branches conditionnelles, sous-DAGs | Retries, ressources, timeouts et caching (15 min) |
| | Variante Airflow : le même pipeline en KubernetesPodOperator, avec la même image (25 min) |
| | Bench : comparaison DX, scaling, debugging (20 min) |
| | Rapport comparatif d'une page (15 min) |

**Lab :** `labs/m2-pipelines/` · 9 étapes · 3 h · vérification `make check-m2`.

### Outils & technologies

Kubeflow Pipelines (SDK `kfp` et `kfp-kubernetes`), Airflow 3 (KubernetesPodOperator),
Kubernetes, MLflow, Docker, registry local

### Livrables étudiant

- Pipeline Kubeflow `scoring-pipeline` complet et reproductible
- Pipeline Airflow équivalent (`scoring_dag`)
- Rapport comparatif d'une page (`reports/rapport-m2.md`)

### Évaluation du module

Noté sur 20 — pipeline KFP fonctionnel (6 pts), intégration MLflow (3 pts), robustesse :
retries, ressources, caching, gate de validation (3 pts), pipeline Airflow (3 pts), rapport
comparatif (5 pts).

## Module 3 — Validation données & modèle

| Thème | Volume | Cours / Lab | Prérequis |
|---|---|---|---|
| Qualité | 3 h | 1h / 2h | Lab 2 réussi (pipeline KFP fonctionnel) |

### Objectifs pédagogiques

- Valider systématiquement les données entrant dans le pipeline, par un contrat généré depuis
  `dataset.yaml`
- Détecter différents types de drift (données, concept, label) en combinant significativité et
  magnitude
- Écrire des tests spécifiques aux modèles ML : performance minimale, invariance, directionnels
- Intégrer la validation comme étape bloquante du pipeline

### Plan du cours et du lab

| Plan du cours magistral | Plan du lab guidé |
|---|---|
| Pourquoi tester les données équivaut à tester le code en ML | Créer la suite Great Expectations depuis `dataset.yaml`, versionnée dans `gx/` (20 min) |
| Great Expectations, Pandera : contrats de données | Mettre à jour le composant KFP `validate_data`, avec rapport HTML (20 min) |
| Types de drift : covariate, concept, label — tests statistiques (KS, PSI, Wasserstein) | Insérer le gate dans le pipeline existant (15 min) |
| Tests de modèle : invariance, directional, behavioral (Evidently, pytest) | Tester : données propres passent, corrompues échouent (15 min) |
| Behavioral testing NLP (CheckList) et CV | Composant `detect_drift` : KS/χ² + PSI, rapport Evidently, drift simulé (20 min) |
| Stratégies de validation : unit, integration, shadow | Composant `validate_model` : Evidently + tests comportementaux pytest (20 min) |
| | Exporter les rapports HTML comme artifacts KFP (10 min) |

**Lab :** `labs/m3-validation/` · 7 étapes · 2 h · vérification `make check-m3`.

### Outils & technologies

Great Expectations, Pandera, Evidently, scipy (KS, χ², Wasserstein), pytest, Kubeflow Pipelines.
Deepchecks n'est plus utilisé : sa dernière version est incompatible avec scikit-learn ≥ 1.8 et
NumPy 2.

### Livrables étudiant

- Suite Great Expectations versionnée
- Rapport Evidently de validation du modèle et tests comportementaux
  (`tests/test_model_behavior.py`)
- Pipeline Kubeflow à trois gates (données, drift, modèle) qui bloque en cas d'erreur

### Évaluation du module

Noté sur 20 — pertinence des expectations (6 pts), gate bloquant fonctionnel (5 pts), détection
de drift (4 pts), validation du modèle (3 pts), propreté du code (2 pts).

## Module 4 — Conteneurisation & packaging des modèles

| Thème | Volume | Cours / Lab | Prérequis |
|---|---|---|---|
| Packaging | 3 h | 1h / 2h | Lab 1 réussi (`scoring-model@champion`) |

### Objectifs pédagogiques

- Packager un modèle ML dans un conteneur Docker optimisé
- Convertir un modèle vers un format portable (ONNX) et situer les autres formats (TorchScript,
  SavedModel, TensorRT)
- Optimiser la taille des images et la latence d'inférence
- Choisir entre BentoML, MLflow Models et une image custom

### Plan du cours et du lab

| Plan du cours magistral | Plan du lab guidé |
|---|---|
| Docker pour ML : multi-stage builds, images slim, base GPU | Récupérer le champion et l'exporter en ONNX, prétraitement inclus, vérifié contre scikit-learn (15 min) |
| Formats de modèles : ONNX, TorchScript, SavedModel, TensorRT | Serveur FastAPI générique : schéma d'entrée construit depuis `dataset.yaml` (15 min) |
| Outils de packaging : BentoML, MLflow Models, Cog | Dockerfile naïf (baseline) (10 min) |
| Optimisation : distillation, quantization (INT8), pruning | Dockerfile multi-stage optimisé : < 500 Mo, non-root, healthcheck (20 min) |
| Sécurité des images : scan Trivy, minimisation de la surface | Benchmark latence P50/P95/P99 : scikit-learn vs ONNX (20 min) |
| | Variante BentoML : packaging + service REST (15 min) |
| | Scan sécurité : Trivy + ModelScan, pickle piégé vs ONNX (10 min) |
| | Push sur le registry local + test pull (10 min) |
| | Rapport de benchmark (5 min) |

**Lab :** `labs/m4-packaging/` · 9 étapes · 2 h · vérification `make check-m4`.

### Outils & technologies

Docker, ONNX, ONNX Runtime, skl2onnx, FastAPI, BentoML, MLflow Models, Trivy, ModelScan

### Livrables étudiant

- Image Docker `scoring-api` publiée sur le registry local
- Rapport de benchmark (latence P50/P95/P99, taille image) et rapports de scan Trivy /
  ModelScan

### Évaluation du module

Noté sur 20 — image fonctionnelle (6 pts), optimisation de la taille (4 pts), benchmark
(4 pts), scan sécurité (3 pts), rapport (3 pts).

## Module 5 — Serving & inférence à l'échelle

| Thème | Volume | Cours / Lab | Prérequis |
|---|---|---|---|
| Déploiement | 5 h | 2h / 3h | Lab 4 réussi (image `scoring-api` dans le registry) |

### Objectifs pédagogiques

- Comparer les patterns de serving : online, batch, streaming, edge
- Déployer un modèle sur Kubernetes avec KServe
- Configurer l'autoscaling horizontal basé sur les métriques pertinentes, jusqu'au
  scale-to-zero
- Optimiser la latence via batching dynamique et partage GPU
- Déployer une nouvelle version en canary et vérifier la répartition du trafic

### Plan du cours et du lab

| Plan du cours magistral | Plan du lab guidé |
|---|---|
| Patterns : online sync, async, batch, streaming, edge | Installer KServe (Knative + Kourier + cert-manager) dans le cluster du cours (30 min) |
| Serveurs de modèles : TorchServe, TF Serving, Triton, BentoML, vLLM | Rendre l'image `scoring-api` disponible pour le cluster (10 min) |
| KServe (modes Knative et Standard) et Seldon Core sur Kubernetes | Créer l'InferenceService `scoring-model` (15 min) |
| Autoscaling : HPA, KPA, KEDA, scale-to-zero | Tester via la passerelle ; seuil servi = seuil du champion (10 min) |
| GPU en prod : MIG, time-slicing, CUDA sharing | Autoscaling sur le RPS + scale-to-zero (20 min) |
| Dynamic batching : théorie et configuration | Test de charge Locust à 100 / 500 / 1 000 utilisateurs : P50/P95/P99 ; bonus : scoring par lots (40 min) |
| | Canary v2.0.0 à 90/10, promotion ou rollback (25 min) |
| | Optionnel : Triton et BentoML sur le même banc d'essai (20 min) |
| | Rapport (10 min) |

**Lab :** `labs/m5-serving/` · 9 étapes · 3 h · vérification `make check-m5`.

### Outils & technologies

KServe, Knative, Kourier, cert-manager, Triton Inference Server, BentoML, Kubernetes, KEDA
(option), Locust

### Livrables étudiant

- InferenceService KServe `scoring-model` déployé et accessible via REST
- Rapport de charge : P50/P95/P99 sous différentes charges, scale-up observé, analyse du canary

### Évaluation du module

Noté sur 20 — déploiement fonctionnel (6 pts), autoscaling (4 pts), benchmark (4 pts), canary
(3 pts), rapport (3 pts).

## Module 6 — CI/CD pour le ML (CT inclus)

| Thème | Volume | Cours / Lab | Prérequis |
|---|---|---|---|
| Automatisation | 4 h | 1h / 3h | Labs 2, 4 et 5 réussis (Lab 3 conseillé) |

### Objectifs pédagogiques

- Construire une pipeline CI complète pour un projet ML
- Automatiser le déploiement avec GitOps (Argo CD)
- Déclencher un ré-entraînement continu (CT) sur détection de drift
- Gérer la promotion entre environnements staging → canary → prod, par des gates et des commits

### Plan du cours et du lab

| Plan du cours magistral | Plan du lab guidé |
|---|---|
| CI/CD vs CI/CD/CT : spécificités du ML | Structurer le repo : tests (API, manifests, CT) et manifests staging / prod (25 min) |
| Tests spécifiques : données, modèle, fairness, performance | Pipeline GitHub Actions : lint → tests → build → test de fumée → push GHCR → staging (25 min) |
| GitHub Actions, GitLab CI, Jenkins : comparatif pour le ML | Installer Argo CD sur kind (20 min) |
| GitOps : Argo CD, Flux — principes et workflows | Créer les Applications Argo CD staging et prod (20 min) |
| Gates qualité : seuils de métriques, validation humaine | Déclencher un déploiement par `git push` (10 min) |
| Patterns de promotion : blue/green, canary, shadow | Simuler une dérive : rapport Evidently et webhook (15 min) |
| | Pipeline CT : webhook → KFP → nouveau modèle, gate métrique + coût métier (30 min) |
| | Canary KServe piloté par Git : promotion, retour arrière (20 min) |
| | Démo de bout en bout + rapport (15 min) |

**Lab :** `labs/m6-cicd/` · 9 étapes · 3 h · vérification `make check-m6`.

### Outils & technologies

GitHub Actions, GHCR, Argo CD, Kustomize, KServe (canary), Kubeflow Pipelines, Evidently,
FastAPI (webhook de ré-entraînement)

### Livrables étudiant

- Pipeline `.github/workflows/ci.yml` fonctionnelle
- Applications Argo CD synchronisées et auto-déployantes (staging et prod)
- Démo : drift simulé → nouveau modèle en prod sans intervention, rapport avec le temps du cycle

### Évaluation du module

Noté sur 20 — CI (6 pts), CD (6 pts), CT (8 pts).

## Module 7 — Monitoring & observabilité ML

| Thème | Volume | Cours / Lab | Prérequis |
|---|---|---|---|
| Opération | 4 h | 2h / 2h | Labs 4, 5 et 6 réussis |

### Objectifs pédagogiques

- Instrumenter un système ML avec métriques système et métriques ML (scores, décisions, groupes
  sensibles)
- Détecter drift et dégradation de qualité en production
- Implémenter alerting, logging et tracing distribué
- Déployer un canary et décider sa promotion ou son rollback à partir des métriques

### Plan du cours et du lab

| Plan du cours magistral | Plan du lab guidé |
|---|---|
| Métriques : système (lat/thr/err) + ML (précision, drift) | Instrumenter l'API : `/metrics` et métriques métier (20 min) |
| Prometheus + Grafana : setup et dashboards | Déployer l'API instrumentée par GitOps (10 min) |
| Détection de drift : Evidently, Arize, WhyLabs — comparatif | Installer Prometheus, Grafana, Pushgateway, Loki et Alloy (15 min) |
| Logging structuré (Loki, Alloy) et tracing (OpenTelemetry, Jaeger) | PodMonitor pour chaque révision de l'InferenceService (15 min) |
| Alerting : Alertmanager, SLO, seuils et escalade | Dashboard Grafana production versionné : latence, débit, scores, refus, drift (25 min) |
| Déploiements progressifs : shadow, canary, A/B testing | CronJob Evidently : drift (PSI) des demandes réelles dans Prometheus (30 min) |
| | Loki + Alloy pour les logs (15 min) |
| | Alertmanager : alertes SLO (burn rate), runbooks, webhook Slack (20 min) |
| | Démo : drift → alerte → ré-entraînement (15 min) |
| | Analyser un canary par les métriques : promouvoir ou annuler par Git (15 min) |

**Lab :** `labs/m7-monitoring/` · 10 étapes · énoncé de 3 h pour 2 h de séance (fin en
autonomie) · vérification `make check-m7`.

### Outils & technologies

Prometheus, Grafana, Pushgateway, Loki, Grafana Alloy, Evidently, Alertmanager, Argo CD et
KServe (canary) ; OpenTelemetry et Jaeger en cours (extension `tracing` du mini-projet)

### Livrables étudiant

- Dashboard Grafana exporté (JSON) et versionné dans Git
- CronJob Evidently + alertes avec runbooks et notification Slack (ou webhook) fonctionnelle
- Analyse de canary démontrée et rapport (`reports/rapport-m7.md`)

### Évaluation du module

Noté sur 20 — instrumentation de l'API (4 pts), stack Prometheus/Grafana (4 pts), Evidently en
continu (4 pts), alertes SLO (3 pts), canary analysé (2 pts), rapport et démo (3 pts).

## Module 8 — Sécurité, gouvernance & Responsible AI

| Thème | Volume | Cours / Lab | Prérequis |
|---|---|---|---|
| Gouvernance | 2 h | 1h / 1h | Labs 4 et 5 réussis |

### Objectifs pédagogiques

- Identifier les vulnérabilités spécifiques de la supply chain ML
- Mesurer l'équité et l'explicabilité des modèles, et chiffrer le compromis coût / équité d'une
  atténuation
- Produire une Model Card complète
- Appliquer les exigences RGPD et EU AI Act à un système à haut risque
- Durcir le déploiement : image minimale, RBAC, secrets externalisés

### Plan du cours et du lab

| Plan du cours magistral | Plan du lab guidé |
|---|---|
| Supply chain ML : pickle, model theft, Sigstore, ModelScan | Scanner l'image `scoring-api` avec Trivy et construire une image durcie (25 min) |
| Adversarial attacks : exemples et contre-mesures | ModelScan : pickle piégé vs ONNX vs skops (15 min) |
| Privacy : differential privacy, federated learning (survol) | Fairlearn : disparités par attribut sensible de `dataset.yaml`, au seuil du modèle (25 min) |
| Explicabilité : SHAP, LIME, intégration en prod | Atténuer : retirer l'attribut, ThresholdOptimizer, ExponentiatedGradient (25 min) |
| Fairness : Fairlearn, AIF360 — métriques et techniques | SHAP : importance globale + 3 explications locales, test contrefactuel (25 min) |
| Model Cards et Datasheets | Générer la Model Card du modèle du projet, livrable du mini-projet (25 min) |
| Cadre réglementaire : RGPD, EU AI Act, risques et obligations | RBAC Kubernetes minimal pour l'InferenceService (15 min) |
| | ExternalSecret pour les identifiants S3 (15 min) |
| | Rapport de conformité AI Act / RGPD (10 min) |

**Lab :** `labs/m8-governance/` · 9 étapes · énoncé de 3 h pour 1 h de séance (fin en
autonomie) · vérification `make check-m8`.

### Outils & technologies

Trivy, Docker Hardened Images, ModelScan, skops, Fairlearn, SHAP, External Secrets Operator,
RBAC Kubernetes, gabarit de Model Card ; Sigstore, AIF360 et LIME en cours

### Livrables étudiant

- Model Card prête à publier (`model-card/model-card.md`)
- Rapport de scan sécurité image + modèle, rapports d'équité et d'explicabilité
- Rapport de conformité AI Act / RGPD ; RBAC et ExternalSecret appliqués

### Évaluation du module

Noté sur 10 — sécurité (2,5 pts), équité (2,5 pts), explicabilité (2,5 pts), gouvernance :
Model Card et rapport de conformité (2,5 pts).

## Module 9 — LLMOps & Edge MLOps

| Thème | Volume | Cours / Lab | Prérequis |
|---|---|---|---|
| Spécialisation | 2 h | 1h / 1h | Python, Docker ; 16 Go de RAM (8 Go avec le modèle léger) |

### Objectifs pédagogiques

- Servir un LLM open source léger en local (Ollama sur CPU, option vLLM sur GPU)
- Construire un système RAG minimal avec base vectorielle, évalué sur un golden set (Ragas)
- Comprendre les spécificités de l'Edge MLOps
- Observer et protéger un LLM en production (Phoenix, LangSmith, guardrails)

### Plan du cours et du lab

| Plan du cours magistral | Plan du lab guidé |
|---|---|
| LLMOps : RAG, fine-tuning (LoRA, QLoRA), évaluation | Servir le LLM : Ollama + Qwen 3.5 sur CPU, ou vLLM sur GPU (15 min) |
| Vector DBs : Qdrant, Weaviate, Milvus, pgvector | Lancer Qdrant en Docker (10 min) |
| Serveurs LLM : vLLM, TGI, Ollama — comparatif | Ingérer les documents du cours dans Qdrant (15 min) |
| Guardrails : NeMo Guardrails, sécurité LLM | Chaîne RAG LangChain : retrieval top-5, sources citées (15 min) |
| Observabilité LLM : LangSmith, Phoenix, Helicone | Golden set de 20-30 questions (15 min) |
| Edge MLOps : TF Lite, ONNX Runtime Mobile, OTA updates | Évaluer avec Ragas : faithfulness, answer relevancy, context precision / recall (15 min) |
| | Tracing Phoenix + API avec métriques Prometheus (10 min) |
| | Prompt injection + guardrails d'entrée et de sortie (15 min) |
| | Rapport final (10 min) |

**Lab :** `labs/m9-llmops/` · 9 étapes · énoncé de 2 h pour 1 h de séance (fin en autonomie) ·
vérification `make check-m9`. Tout tourne sur le poste, sans cluster ; le projet `rag/` a son
propre environnement Python, séparé du socle.

### Outils & technologies

Ollama (Qwen 3.5), vLLM (option GPU), Qdrant, LangChain, fastembed, Ragas, Phoenix, LangSmith
(option), FastAPI, ONNX Runtime

### Livrables étudiant

- Service RAG accessible via API, avec au moins 5 documents indexés et des réponses sourcées
- Rapport Ragas et traces Phoenix d'une session utilisateur
- Tests d'injection avant / après guardrail et rapport (`rag/RAPPORT.md`)

### Évaluation du module

Noté sur 10 — pipeline RAG (3 pts), évaluation Ragas (3 pts), observabilité (2 pts), sécurité
(1 pt), rapport (1 pt). Le Lab 9 est noté comme les autres labs mais ne fait pas partie du socle
du mini-projet : il sert de base à l'extension `rag-projet`.

## Module 10 — Mini-projet & soutenances

| Thème | Volume | Cours / Lab | Prérequis |
|---|---|---|---|
| Intégration | 2 h classe + travail continu S1-S12 | 0h / 2h + perso | Labs 0 à 8 (le socle) ; Lab 9 pour l'extension `rag-projet` |

### Objectifs pédagogiques

- Intégrer l'ensemble des briques MLOps sur un cas d'usage complet
- Travailler en binôme : pilote / copilote alternés, PR relues, journal de bord, ADR
- Étendre le socle par une extension personnelle, testée et documentée
- Présenter une démonstration end-to-end devant un jury
- Défendre des choix d'architecture et justifier les trade-offs
- Diagnostiquer et corriger en direct un incident de production (données, drift, service,
  déploiement, modèle, secret)

### Plan du cours et du lab

| Plan du cours magistral | Plan du lab guidé |
|---|---|
| Pas de cours magistral — suivi du projet à chaque séance | Socle = Labs 0 à 8 appliqués au cas d'usage, vérifiés par `make check-m0` … `make check-m8` |
| Dataset libre validé avant le Lab 1 (S2), sinon credit scoring | Une extension par étudiant : catalogue de 16, niveaux ★ à ★★★, ou hors catalogue validée avant la fin de S8 |
| Jalons taggés : J0 Setup (fin S3), J1 MVP (fin S8, extensions déclarées), J2 Production (fin S11), `final` 48 h avant la soutenance | Travail par branches `lab/…` et `ext/<nom>`, fusionnées par PR relue par le partenaire |
| Préparation du défi : « jeu du chaos » hebdomadaire en binôme à partir de J1 | Soutenance de 25 min par binôme : démo du socle 5 min, extensions 2 × 5 min, défi en direct 2 × 4 min, questions 2 min |
| | Défi tiré au sort parmi six familles d'incidents : données invalides, drift, service qui ne répond plus, déploiement bloqué, modèle dégradé, secret manquant |

**Énoncé :** `labs/m10-capstone/` · pré-contrôle de rendu `make check-m10` (aussi par jalon :
`make check-m10 JALON=j1`).

### Outils & technologies

Toute la stack du cours ; GitHub (formulaires d'issue de déclaration, PR relues, protection de
`main`, tags de jalon) ; pré-contrôle `make check-m10`

### Catalogue des extensions

| Branche `ext/…` | Extension | Niveau | Compétences |
|---|---|---|---|
| `feature-store` | Feature store en ligne | ★★ | C1, C3 |
| `hpo` | Optimisation d'hyperparamètres orchestrée (Optuna/Katib, MLflow) | ★★ | C1, C2 |
| `retrain-planifie` | Ré-entraînement planifié | ★★ | C2, C4 |
| `batch-scoring` | Scoring batch | ★★ | C3 |
| `onnx-quantifie` | Inférence optimisée ONNX quantifié | ★★ | C3 |
| `scale-to-zero` | Scale-to-zero | ★★ | C3 |
| `shadow` | Déploiement shadow | ★★★ | C3, C5 |
| `ab-test` | Test A/B | ★★★ | C3, C5 |
| `tests-comportementaux` | Tests comportementaux en CI | ★★ | C4 |
| `gate-equite` | Gate d'équité Fairlearn en CI | ★★ | C4, C6 |
| `drift-predictions` | Drift sur les prédictions | ★★★ | C5 |
| `tracing` | Tracing de bout en bout OpenTelemetry/Jaeger | ★★ | C5 |
| `explain-api` | Explicabilité en production `/explain` (SHAP) | ★★ | C6 |
| `supply-chain` | Chaîne de confiance cosign + admission | ★★★ | C6 |
| `model-card-auto` | Model card automatique | ★ | C6 |
| `rag-projet` | Assistant RAG du projet + Ragas en CI | ★★★ | C4, C6 |

Les deux membres d'un binôme choisissent deux extensions différentes ; au plus 3 binômes par
extension et par groupe (premier déclaré, premier servi). Le niveau plafonne la note
d'extension : ★ → 8/12, ★★ → 11/12, ★★★ → 12/12.

### Livrables étudiant

- Repo taggé `j0` / `j1` / `j2` / `final`, avec le README du projet
- Socle déployé et démontrable sur cluster kind
- Model card, dataset card, au moins 3 ADR, journal de bord
- Rapport technique (10 pages max)
- Slides et vidéo de démo de 3 min

### Évaluation du module

Noté sur 40 — socle 12 (binôme : `make check-m0` → `make check-m8` verts 6, reproductibilité 3,
adaptation au cas d'usage 3), extension 12 (individuel : fonctionne et intégrée 5, tests / ADR /
documentation 3, maîtrise orale 4 ; plafond selon le niveau), défi et questions 10 (individuel :
diagnostic 4, démarche et outils 3, correction et réponses 3), livrables écrits 6 (binôme :
README + dataset card + model card 3, rapport 2, journal et historique Git 1). Poids : 40 % de
la note finale, avec un minimum de 8/20 sans compensation.

# Stack technique du cours

*Vue synthétique des technologies utilisées, de leur version épinglée et de leur rôle.*

| Couche | Outil principal | Version | Rôle | Modules |
|---|---|---|---|---|
| Plateforme | `Kubernetes (kind)` | kind v0.33.0, nœuds Kubernetes 1.37 | Infrastructure de base pour tous les déploiements | Tous |
| Registry d'images | `registry local + GHCR` | `registry:3` sur `localhost:5001` | Images du pipeline et de l'API ; GHCR pour la CI | M2-M8 |
| Stockage objet | `SeaweedFS` | 4.48 | Stockage S3 du cours (remote DVC, artefacts MLflow), remplace MinIO | M0-M8 |
| Versioning données | `DVC` | 3.67.1 | Versionnement de datasets et pipeline `dvc.yaml`, remote S3 | M0, M1 |
| Tracking | `MLflow` | 3.16.1 | Suivi d'expériences, model registry à alias, proxy d'artefacts | M0-M8 |
| Feature store | `Feast` | 0.66.0 | Stockage et service unifié des features | M1 |
| Orchestration | `Kubeflow Pipelines` | 2.17.2 (SDK 2.17.0) | DAGs ML natifs Kubernetes | M2, M3, M6 |
| Alt. orchestration | `Airflow` | 3.3.2 | Comparaison pédagogique | M2 |
| Validation données | `Great Expectations` | 1.23.2 (+ Pandera 0.34.0) | Contrats de qualité pour les données | M3 |
| Tests modèles | `Evidently + pytest` | 0.7.23 · pytest 9.1.1 | Tests de classification et tests comportementaux | M3, M6 |
| Drift | `Evidently` | 0.7.23 | Détection de drift (KS, PSI) et rapports automatisés | M3, M6, M7 |
| Packaging | `Docker + ONNX` | onnx 1.23.1 · onnxruntime 1.30.0 · skl2onnx 1.20.0 | Conteneurisation et formats portables | M4 |
| API de scoring | `FastAPI` | 0.142.2 (uvicorn 0.54.0) | API générique, schéma tiré de `dataset.yaml` | M4-M8 |
| Alt. packaging | `BentoML` | 1.4.39 | Framework dédié au packaging ML | M4, M5 |
| Test de charge | `Locust` | 2.46.6 | Latence P50/P95/P99 et débit sous charge | M4, M5 |
| Serving online | `KServe` | v0.21.0 (Knative 1.23, Kourier, cert-manager v1.21.2) | Inférence REST autoscalable, scale-to-zero, canary | M5-M8 |
| Autoscaling | `Knative KPA + KEDA` | KEDA v2.21.0 (option), metrics-server v0.9.0 | Mise à l'échelle sur le débit, scale-to-zero | M5 |
| Alt. serving | `Triton Inference Server` | runtime fourni par KServe 0.21 | Serveur haute performance NVIDIA (étape optionnelle) | M5 |
| CI | `GitHub Actions` | actions épinglées dans `ci.yml` | Intégration continue, image publiée sur GHCR | M6 |
| CD / GitOps | `Argo CD` | v3.5.3 | Déploiement continu staging / prod, canary piloté par Git | M6, M7 |
| Métriques | `Prometheus + Grafana` | kube-prometheus-stack 91.9.0 (Prometheus 3.15, Grafana 13.2) | Observabilité système et ML | M7 |
| Alerting | `Alertmanager` | 0.34 (kube-prometheus-stack) | Alertes SLO (burn rate), routage, webhook Slack | M7 |
| Logging | `Loki + Grafana Alloy` | charts 18.13.8 (Loki 3.7) · 1.13.0 | Agrégation et collecte des logs | M7 |
| Tracing | `OpenTelemetry + Jaeger` | — | Distributed tracing (cours ; extension `tracing`) | M7, M10 |
| Sécurité images | `Trivy` | v0.75.0 | Scan de vulnérabilités conteneurs, image durcie | M4, M8 |
| Sécurité modèles | `ModelScan` | 0.8.8 | Scan de modèles sérialisés (pickle, etc.) | M4, M8 |
| Secrets | `External Secrets Operator` | v2.11.0 (API `v1`) | Secrets synchronisés, aucun secret dans Git | M8 |
| Fairness | `Fairlearn` | 0.14.0 | Mesure et atténuation des biais | M8 |
| Explicabilité | `SHAP` | 0.52.0 (0.50.0 sur Mac Intel) | Interprétabilité des prédictions | M8 |
| LLM serving | `Ollama / vLLM` | Ollama v0.35.1 (Qwen 3.5, CPU) · vLLM 0.31.0 (GPU, option) | Serveur d'inférence LLM | M9 |
| Vector DB | `Qdrant` | v1.19.2 (client 1.19.1) | Base vectorielle pour RAG | M9 |
| Chaîne RAG | `LangChain + fastembed` | langchain-core 1.6.6 · fastembed 0.8.1 | Retrieval, prompt, appel du LLM | M9 |
| Évaluation LLM | `Ragas` | 0.4.3 | Évaluation du RAG par un LLM juge | M9 |
| LLM observability | `Phoenix / LangSmith` | arize-phoenix 20.19.0 | Traces et éval de LLMs en prod | M9 |
| Environnement | `Python + uv` | Python 3.12, `uv.lock` | Un environnement verrouillé pour le socle ; projet `rag/` séparé | Tous |

> [!NOTE]
> **Où sont épinglées les versions ?**
> Infrastructure : `infra/versions.env`, source unique lue par le `Makefile` et les scripts
> `infra/*/install.sh` (les versions des charts Pushgateway, Loki et Alloy sont dans
> `infra/monitoring/install.sh`). Python du socle (Labs 0 à 8) : `pyproject.toml` + `uv.lock`,
> installés par `uv sync`. Lab 9 : projet séparé `rag/` (son propre `pyproject.toml` et son
> `uv.lock`). Monter une version, c'est modifier une ligne et laisser la CI du cours rejouer les
> labs.

> [!NOTE]
> **Choix pédagogiques de la stack**
> Tous les outils sont Open Source. Le parti pris est d'enseigner des **concepts** plutôt que
> des **produits** : un étudiant qui maîtrise Kubeflow saura se retrouver sur AWS SageMaker
> Pipelines, Azure ML ou Vertex AI. Les outils commerciaux (SageMaker, Databricks, W&B) sont
> mentionnés en cours comme alternatives mais non utilisés en lab — évitant les contraintes de
> comptes et de coûts individuels. Deux comptes gratuits suffisent : GitHub (repo, Actions,
> GHCR) et Docker (images durcies du Lab 8).

# Planning indicatif sur un semestre

*Répartition proposée sur 12 semaines (3h/semaine) ou format bloc intensif.*

## Format semestriel (12 semaines × 3h)

Chaque séance dure 3 h ; un module commence dès que le précédent est fini, dans la même séance
s'il le faut (le volume de chaque module est celui de la table synoptique).

| Semaine | Contenu de la séance (3 h) | Mini-projet |
|---|---|---|
| S1 | Module 0 : cours 1 h + lab 1 h (préparé avant la séance) · Module 1 : cours (1/2), 1 h | Binômes formés, repo du binôme créé ; postes à moins de 16 Go repérés, solution de repli décidée |
| S2 | Module 1 : cours (2/2) 1 h + lab 2 h | Dataset libre validé **avant** la séance, sinon credit scoring |
| S3 | Module 2 : cours 2 h + lab (1/3) 1 h | **J0 Setup** : tag `j0` en fin de semaine |
| S4 | Module 2 : lab (2/3 et 3/3) 2 h · Module 3 : cours 1 h | — |
| S5 | Module 3 : lab 2 h · Module 4 : cours 1 h | — |
| S6 | Module 4 : lab 2 h · Module 5 : cours (1/2) 1 h | — |
| S7 | Module 5 : cours (2/2) 1 h + lab (1/2) 2 h | — |
| S8 | Module 5 : lab (2/2) 1 h · Module 6 : cours 1 h + lab (1/3) 1 h | Extensions déclarées (date limite) · **J1 MVP** : tag `j1` |
| S9 | Module 6 : lab (2/3 et 3/3) 2 h · Module 7 : cours (1/2) 1 h | Extensions en développement ; jeu du chaos hebdomadaire |
| S10 | Module 7 : cours (2/2) 1 h + lab 2 h | Extensions en développement |
| S11 | Module 8 : cours 1 h + lab 1 h · Module 9 : cours 1 h | Extensions fusionnées · **J2 Production** : tag `j2` |
| S12 | Module 10 : soutenances du mini-projet (3 h) | Tag `final` 48 h avant la soutenance |

> [!NOTE]
> **Reports par rapport au découpage « un module par semaine »**
> Les Modules 6, 7 et 8 + 9 demandent chacun 4 h : ils commencent dans la séance précédente
> (cours du Module 6 en S8, cours du Module 7 en S9), grâce aux marges de S1 (Module 0 = 2 h)
> et de S8 (fin du Module 5). Les soutenances occupent toute la S12 (3 h pour 7 binômes) : l'heure
> de lab encadrée du Module 9, qui tourne entièrement sur le poste sans cluster, se fait en
> autonomie, comme la fin des Labs 7 et 8.

> [!NOTE]
> **Durée des soutenances**
> 25 minutes par binôme : un créneau de 3 h accueille 7 binômes. Au-delà, prévoir deux jurys en
> parallèle ou un créneau supplémentaire.

## Format bloc intensif (4 jours × 9h)

Format alternatif pour une formation continue ou une session de rattrapage concentrée.

| Jour | Modules | Mini-projet | Volume |
|---|---|---|---|
| Jour 1 | Modules 0, 1, 2 — Fondamentaux et pipelines | Dataset libre validé avant le premier jour · tag `j0` en fin de journée | 9 h |
| Jour 2 | Modules 3, 4, 5 — Qualité, packaging, serving | Extensions déclarées · tag `j1` en fin de journée | 9 h |
| Jour 3 | Modules 6, 7, 8, 9 — CI/CD, monitoring, spécialisations | Socle complet · tag `j2` en fin de journée | 9 h |
| Jour 4 | Module 10 — Mini-projet accompagné | Extensions, préparation du défi, livrables | 9 h |

> [!WARNING]
> **Format intensif : attention au mini-projet**
> Le format bloc 4 jours est efficace pour la transmission mais laisse peu de temps pour la
> maturation du mini-projet. Si ce format est retenu, prévoir une période de 2 à 3 semaines
> après la formation pendant laquelle les binômes finalisent socle, extensions et livrables,
> avec soutenance à distance (défi en direct sur le cluster de l'étudiant ou, à défaut, sur
> celui de l'enseignant). Les journées 1 à 3 regroupent 11 à 12 h de contenu nominal : les fins
> de labs (variante Airflow, étapes optionnelles, rapports) se terminent en autonomie.

# Évaluation et barème

*Trois composantes pondérées : labs, mini-projet, examen écrit.*

## Répartition globale

| Composante | Format | Poids |
|---|---|---|
| Labs notés | 9 labs notés : M1 à M7 sur 20, M8 et M9 sur 10. Note de labs = total des points obtenus sur 160, ramené sur 20. Remise sur le repo Git du binôme, avant la séance suivante. | **30 %** |
| Mini-projet | Module 10. Binômes. Repo construit lab après lab (socle M0-M8) + une extension par étudiant + soutenance de 25 min avec défi en direct. Grille ci-dessous. | **40 %** |
| Examen écrit | 2h en fin de semestre. QCM (1/3), analyse d'architecture (1/3), questions ouvertes sur cas d'usage (1/3). | **30 %** |

## Barème des labs

Chaque énoncé se termine par sa grille ; le tableau en reprend les critères. Les labs sont notés
à leur date de rendu ; le socle du mini-projet, lui, est évalué au tag `final`.

| Lab | Noté sur | Critères (points) | Part de la note de labs |
|---|---|---|---|
| M0 — Setup | non noté | `make check-m0` vert : condition d'accès au Module 1 | — |
| M1 — Versioning | 20 | reproductibilité 6 · tracking 6 · pertinence du modèle 4 · propreté du code 4 | 12,5 % |
| M2 — Pipelines | 20 | pipeline KFP 6 · intégration MLflow 3 · robustesse 3 · pipeline Airflow 3 · rapport comparatif 5 | 12,5 % |
| M3 — Validation | 20 | expectations 6 · gate bloquant 5 · drift 4 · validation du modèle 3 · propreté du code 2 | 12,5 % |
| M4 — Packaging | 20 | image fonctionnelle 6 · optimisation taille 4 · benchmark 4 · scan sécurité 3 · rapport 3 | 12,5 % |
| M5 — Serving | 20 | déploiement KServe 6 · autoscaling 4 · benchmark 4 · canary 3 · rapport 3 | 12,5 % |
| M6 — CI/CD/CT | 20 | CI 6 · CD 6 · CT 8 | 12,5 % |
| M7 — Monitoring | 20 | instrumentation 4 · Prometheus/Grafana 4 · Evidently en continu 4 · alertes SLO 3 · canary analysé 2 · rapport et démo 3 | 12,5 % |
| M8 — Gouvernance | 10 | sécurité 2,5 · équité 2,5 · explicabilité 2,5 · gouvernance 2,5 | 6,25 % |
| M9 — LLMOps | 10 | pipeline RAG 3 · évaluation Ragas 3 · observabilité 2 · sécurité 1 · rapport 1 | 6,25 % |
| **Total** | **160** | | **100 %** |

> [!NOTE]
> **Pourquoi deux labs sur 10 ?**
> Les Labs 8 et 9 ont les séances encadrées les plus courtes du cours (1 h de lab chacun) : ils
> pèsent deux fois moins que les autres. Leurs énoncés gardent leur barème sur 10, et la note de
> labs se calcule sur le total des points. Exemple : 112 points sur 140 aux Labs 1 à 7, 8/10 au
> Lab 8 et 6/10 au Lab 9 donnent 126/160, soit 15,75/20.

> [!TIP]
> **Un check vert n'est pas une note maximale**
> `make check-mX` vérifie que les livrables existent et fonctionnent. La note porte aussi sur la
> qualité : analyse des rapports, justification des choix, propreté du code.

## Critères d'évaluation du mini-projet

| Bloc | Qui | Critère | Points |
|---|---|---|---|
| **Socle** (12) | Binôme | `make check-m0` → `make check-m8` verts au tag `final` | 6 |
| | | Reproductibilité : `git clone`, `make up`, `uv sync`, `dvc repro` (+ `dvc push`), pipeline | 3 |
| | | Adaptation au cas d'usage : seuils et coûts, équité, alertes, rien en dur | 3 |
| **Extension** (12) | Individuel | Fonctionne et est intégrée au socle (attendus minimaux) | 5 |
| | | Tests, ADR, documentation (page du rapport) | 3 |
| | | Maîtrise à l'oral : démo, questions sur les choix | 4 |
| **Défi et questions** (10) | Individuel | Diagnostic de l'incident | 4 |
| | | Démarche et outils | 3 |
| | | Correction et réponses aux questions | 3 |
| **Livrables écrits** (6) | Binôme | README, dataset card, model card | 3 |
| | | Rapport technique (10 pages max) | 2 |
| | | Journal de bord et historique Git | 1 |
| **Total** | | | **40** |

Le niveau de l'extension plafonne son bloc : ★ → 8/12, ★★ → 11/12, ★★★ → 12/12. Les blocs
« socle » et « livrables écrits » sont communs au binôme ; l'historique Git et le journal de bord
permettent de les individualiser si un membre n'a visiblement pas contribué.

## Jalons du mini-projet

| Tag | Quand | Contenu attendu | Vérifié par |
|---|---|---|---|
| `j0` | fin S3 | `dataset.yaml` (validé si dataset libre), données versionnées par DVC, runs dans MLflow, `make check-m0` et `make check-m1` verts | `make check-m10 JALON=j0` |
| `j1` | fin S8 | pipeline avec gate de validation, modèle servi par KServe, `make check-m2` à `make check-m5` verts, extensions déclarées | `make check-m10 JALON=j1` |
| `j2` | fin S11 | CI/CD, monitoring, model card, `make check-m6` à `make check-m8` verts, extensions fusionnées | `make check-m10 JALON=j2` |
| `final` | 48 h avant la soutenance | tout ce qui précède + rapport PDF, slides, vidéo de démo de 3 min, journal, ADR | `make check-m10` |

Seul l'état au tag `final` est évalué. Les jalons intermédiaires servent à repérer tôt les
binômes en difficulté : un tag absent ou un pré-contrôle très rouge déclenche un point avec
l'enseignant, pas une pénalité.

## Conditions de réussite

- **Note finale ≥ 10 / 20** pour valider l'ECTS.
- **Note du mini-projet ≥ 8 / 20** (16 / 40) obligatoire (pas de compensation possible).
- **Tous les labs rendus**, même non notés (Lab 0 compris) — condition de droit à l'examen
  final.
- **Présence obligatoire** à la soutenance du mini-projet.

# Ressources & références

*Biblio et veille pour aller plus loin que le cours.*

## Ouvrages de référence

- **Designing Machine Learning Systems**, Chip Huyen, O'Reilly 2022 — *la référence*.
- **Machine Learning Engineering**, Andriy Burkov, 2020 — épuré et concret.
- **Introducing MLOps**, Treveil et al., O'Reilly 2020 — vision Dataiku.
- **Reliable Machine Learning**, Chen et al., O'Reilly 2022 — focus SRE pour ML.
- **Building Machine Learning Pipelines**, Hapke & Nelson, O'Reilly 2020.

## Articles fondateurs

- **Hidden Technical Debt in Machine Learning Systems**, Sculley et al., NeurIPS 2015 — lecture
  obligatoire avant le cours.
- **The ML Test Score**, Breck et al., IEEE 2017 — rubrique de maturité système.
- **Continuous Delivery for Machine Learning**, Sato, Wider, Windheuser, 2019 — Martin Fowler.
- **MLOps : Continuous delivery and automation pipelines in ML**, Google Cloud, 2021.
- **Beyond Accuracy: Behavioral Testing of NLP Models with CheckList**, Ribeiro et al., ACL
  2020 — à l'origine des tests comportementaux du Lab 3.
- **Model Cards for Model Reporting**, Mitchell et al., FAT* 2019 — structure de la Model Card
  du Lab 8.
- **Datasheets for Datasets**, Gebru et al., Communications of the ACM, 2021 — structure de la
  dataset card du mini-projet.
- **Efficient Memory Management for Large Language Model Serving with PagedAttention**, Kwon et
  al., SOSP 2023 — le principe de vLLM (Module 9).

## Le cas d'usage et ses données

- **Statlog (German Credit Data)**, H. Hofmann, 1994, UCI Machine Learning Repository, licence
  CC BY 4.0 — https://doi.org/10.24432/C5NC77
- **South German Credit Data: Correcting a Widely Used Data Set**, U. Grömping, Beuth
  University of Applied Sciences Berlin, 2019 — les erreurs de codage connues du dataset, à
  lire avant d'interpréter l'équité.

## Cadre réglementaire

- **Règlement (UE) 2024/1689 sur l'intelligence artificielle (AI Act)** — le scoring de crédit
  figure à l'annexe III (point 5 b), systèmes à haut risque.
- **Règlement « Digital Omnibus » (UE) 2026/1744** — report des obligations des systèmes à haut
  risque de l'annexe III au 2 décembre 2027.
- **RGPD**, article 22 (décision individuelle automatisée) et article 35 (analyse d'impact).
- **Directive (UE) 2023/2225** sur le crédit aux consommateurs — droit à une intervention
  humaine en cas d'évaluation automatisée de la solvabilité, applicable à partir du 20 novembre
  2026.

Dates vérifiées en octobre 2026 : toujours les revérifier à la source.

## Documentations & ressources en ligne

- **Google MLOps Guide** —
  cloud.google.com/architecture/mlops-continuous-delivery-and-automation-pipelines-in-machine-learning
- **Made With ML** (Goku Mohandas) — madewithml.com (MOOC libre)
- **Full Stack Deep Learning** — fullstackdeeplearning.com
- **ml-ops.org** (collectif) — principes MLOps et comparaisons d'outils
- **Awesome MLOps** — github.com/visenger/awesome-mlops
- **Documentation des outils** — liens à jour dans la section « Pour aller plus loin » de
  chaque énoncé de lab

## Communautés & conférences

- **MLOps Community** — mlops.community (Slack + podcast + conf)
- **apply(conf)** — conférence annuelle par Tecton
- **Ray Summit**, **KubeCon + CloudNativeCon** (tracks IA)
- **PyData** et meetups locaux Paris / Lyon / Toulouse

## Outils de veille à suivre

- Newsletter **MLOps Newsletter** (Demetrios Brinkmann)
- **ChipRO** (Chip Huyen) — posts long format
- **Eugene Yan's blog** — eugeneyan.com
- **Hacker News** tags *mlops*, *kubernetes*, *ml-engineering*

> [!NOTE]
> **Principe de veille**
> Le MLOps évolue vite (tous les 6 mois un nouvel outil s'impose — et d'autres disparaissent :
> entre les deux versions de ce cours, MinIO communautaire, Promtail et Deepchecks sont sortis
> de la stack). La stratégie recommandée aux étudiants : suivre 2-3 sources régulières,
> s'abstenir d'être exhaustif, et noter les outils qui apparaissent plusieurs fois dans des
> contextes différents — c'est le signal qu'ils vont s'imposer. Ignorer 95 % du bruit.

# Colophon

*Sources, maintenance et contributions.*

Ce syllabus est un document vivant. Chaque retour étudiant, chaque bug rencontré en lab, chaque
évolution de la stack open source MLOps contribue à améliorer les prochaines versions. Les
sources du cours (énoncés, scripts d'infrastructure, vérifications, corrigés) sont versées dans
deux repos Git.

## Les repos du cours

| Repo | Visibilité | Contenu |
|---|---|---|
| `mlops-cours-2026` | public, *GitHub Template* | Infrastructure (`infra/`, `Makefile`, `infra/versions.env`), énoncés des labs (`labs/mX-*/README.md`) avec leurs `check.sh` et fichiers de départ, gabarits du mini-projet (`docs/`, formulaires d'issue), ce syllabus (`docs/syllabus.md`). Chaque binôme en crée sa copie au Lab 0 et y travaille jusqu'à la soutenance. |
| `mlops-cours-2026-solutions` | privé, enseignant | Corrigés cumulatifs (`solution/mX` : état du repo à la fin du lab X, labs précédents inclus) et scripts de rejeu automatique (`e2e.sh`). Après chaque date de rendu, la correction est publiée dans le repo du cours : branche `solution/mX` et tag `start/m(X+1)` (état de départ du lab suivant). |

## Comment le cours est maintenu

- **PDF générés depuis les Markdown** : les énoncés de labs et ce syllabus sont écrits en
  Markdown dans le repo du cours, et les PDF en sont générés. Un vérificateur
  (`tools/check_sync.py`) garantit que le code montré dans les énoncés est exactement celui des
  corrigés.
- **CI hebdomadaire `course-e2e`** : chaque semaine, la CI du cours crée un cluster kind neuf,
  rejoue tous les labs sans intervention (`e2e.sh`) puis leurs vérifications (`make check-mX`).
  Une rupture amont — image retirée, API modifiée, comme la disparition des images MinIO en
  2026 — est détectée avant la séance, pas pendant.
- **Versions épinglées** : une seule source pour l'infrastructure (`infra/versions.env`) et un
  environnement Python verrouillé (`uv.lock`) ; monter de version, c'est modifier une ligne et
  laisser la CI valider.

## Livrables par module

Chaque module dispose des ressources suivantes :

- **Support de cours (PPTX)** — ~22 slides, lecture autonome possible.
- **Énoncé de lab (Markdown, PDF généré)** — pas-à-pas avec commandes, sorties attendues,
  troubleshooting et vérification automatique (`make check-mX`).
- **Code source du lab (repo du cours)** — fichiers de départ (`starter/`), scripts
  d'infrastructure (`infra/`), `check.sh`.
- **Solutions correctives** — repo privé de l'enseignant ; état de départ du lab suivant publié
  après chaque rendu (branche `solution/mX`, tag `start/m(X+1)`), pour permettre aux binômes de
  remettre leur socle à niveau.
- **Sujet d'évaluation** (modules notés) — grille détaillée en fin d'énoncé ; au Module 10,
  énoncé du mini-projet, grille sur 40 et pré-contrôle de rendu (`make check-m10`).

> [!NOTE]
> **Contact & contributions**
> Pour signaler une erreur ou proposer une amélioration, ouvrir une *issue* sur le repo GitHub
> du cours, `mlops-cours-2026` (lien fourni en début de semestre). Les contributions
> étudiantes sont acceptées sous forme de pull requests — particulièrement appréciées pour le
> troubleshooting et la mise à jour des versions d'outils. Les propositions de dataset libre et
> les déclarations d'extension passent par les formulaires d'issue dédiés.

Version 2.0 — octobre 2026.
