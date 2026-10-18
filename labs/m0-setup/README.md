---
module: 0
lab: 0
title: "Setup de l'environnement"
subtitle: "Préparer la stack MLOps pour les 36 heures à venir"
running_title: "Lab 0 — Setup de l'environnement"
duree: "1 heure en séance (atelier guidé) + environ 1 heure de préparation avant la séance"
format: "Atelier individuel ou en binôme · Linux / macOS / WSL2"
prerequis: "Docker, Kubernetes, Git, Python — niveau cours antérieurs"
livrable: "Capture de make check-m0 validé à 100 % + première pull request (lab/m0-setup) fusionnée"
---

# Lab 0 — Setup de l'environnement

*Mettre en place une fois pour toutes la stack utilisée dans tous les modules du cours.*

## Pourquoi ce lab ?

Tous les labs du cours (modules 1 à 10) reposent sur la même stack : un cluster Kubernetes local,
un stockage objet S3-compatible, un serveur MLflow partagé, Python avec un environnement
reproductible, et la chaîne d'outils MLOps de référence (DVC, MLflow, etc.). Le faire correctement
aujourd'hui évitera 36 heures de friction.

Bonne nouvelle : vous n'écrivez plus l'infrastructure à la main. Le **repo du cours**
`mlops-cours-2026`, que vous allez forker dès l'étape 3, contient les manifests et scripts
(`infra/`), un `Makefile` qui les pilote, les énoncés des labs (`labs/`) et le point de départ du
projet fil rouge : un modèle de **credit scoring** (décider d'accorder ou non un crédit), piloté
par un contrat de données, `dataset.yaml`, qui grandira module après module jusqu'au mini-projet
noté. Votre travail aujourd'hui : installer les outils, **comprendre** ce que fait chaque brique,
la déployer et la valider.

> [!NOTE]
> **Objectifs de ce lab**
> À la fin de cette heure, vous aurez :
>
> - Un Docker fonctionnel avec le plugin Docker Compose.
> - Les outils `kubectl`, `helm`, `k9s` et `kind` installés.
> - Votre copie (fork) du repo du cours `mlops-cours-2026` (une seule par binôme), clonée en SSH
>   sur votre poste.
> - Un cluster Kubernetes local **kind** à 1 control-plane + 2 workers, avec un **registry
>   d'images local** (`localhost:5001`).
> - Un stockage objet **SeaweedFS** (S3 local) et un serveur **MLflow** déployés dans le cluster,
>   avec un bucket de test.
> - Un environnement Python 3.12 isolé avec `uv`, et MLflow + DVC installés et testés.
> - Une **checklist de validation** entièrement verte, vérifiée par `make check-m0`.
> - Votre première **pull request** (branche `lab/m0-setup`), la convention de travail de tous
>   les labs.

## Pré-requis matériels et logiciels

| Élément | Requis pour le cours | Suffit pour les Labs 0 et 1 seulement |
|---|---|---|
| RAM | **16 Go** | 8 Go |
| CPU | 4 cœurs | 2 cœurs |
| Disque libre | 30 Go | 15 Go |
| OS | Linux (Ubuntu 22.04+) / macOS 13+ / Windows 11 + WSL2 | — |
| Connexion | Internet stable (téléchargements ~4 Go) | — |

> [!WARNING]
> **Windows : utilisez WSL2**
> Sous Windows, toutes les commandes de ce lab doivent être exécutées dans une distribution WSL2
> (Ubuntu 22.04 ou 24.04 recommandée). Docker Desktop doit être configuré pour utiliser WSL2 comme
> backend (Settings > General > « Use the WSL 2 based engine »). Les chemins doivent rester dans le
> système de fichiers Linux (`/home/...`), pas dans `/mnt/c/...`.

> [!CAUTION]
> **16 Go de RAM : vérifiez votre poste dès aujourd'hui**
> 8 Go suffisent pour les Labs 0 et 1, pas au-delà : Kubeflow Pipelines (Lab 2), KServe
> (Lab 5), Argo CD (Lab 6) et la stack de monitoring (Lab 7) s'ajoutent au même cluster, qui
> demande alors 10 à 12 Go alloués à Docker. Découvrir la limite en semaine 4 est trop tard.
> Si votre poste a moins de 16 Go, signalez-le **dès la première séance** : poste de l'école,
> machine virtuelle fournie par l'établissement, ou travail sur le poste du membre du binôme qui
> a 16 Go (chacun garde son compte GitHub et commite sous son nom). Le même poste de repli sert
> de plan B le jour de la soutenance.

## Plan du lab

Le lab se fait en deux temps. Les étapes **1, 2, 3 et 6** (installations et téléchargements,
environ 4 Go) se font **avant la séance**, chez vous : trente postes qui téléchargent en même
temps sur le réseau de la salle, c'est une heure perdue. La séance (1 h) est consacrée au
cluster, aux services et aux vérifications : étapes **4, 5, 7 et 8**.

| # | Étape | Quand | Durée |
|---|---|---|---|
| 1 | Vérifier Docker Engine + Docker Compose | Avant la séance | 10 min |
| 2 | Installer kubectl, helm, k9s et kind | Avant la séance | 10 min |
| 3 | Forker et cloner le repo du cours | Avant la séance | 10 min |
| 6 | Installer Python 3.12 + uv, synchroniser l'environnement, pré-télécharger les images | Avant la séance | 25 min |
| 4 | Créer le cluster kind + le registry local | En séance | 10 min |
| 5 | Déployer le stockage S3 (SeaweedFS) et MLflow dans le cluster | En séance | 15 min |
| 7 | Smoke tests MLflow et DVC | En séance | 10 min |
| 8 | Checklist finale de validation + première pull request | En séance | 10 min |
| — | Marge pour le dépannage | En séance | 15 min |

> [!IMPORTANT]
> **Avant la séance : étapes 1, 2, 3 et 6**
> Comptez environ une heure, dont une vingtaine de minutes de téléchargements sans surveillance
> (`uv sync`, puis `make prefetch` qui récupère à l'avance l'image des nœuds kind et les images
> du cours). Arrivez en séance avec `docker run --rm hello-world`, `kind version`, `uv --version`
> et `python --version` qui répondent dans le dossier du repo. Bloqué ? Notez le message
> d'erreur, consultez l'annexe « Troubleshooting » et venez 15 minutes en avance.

## Convention de notation

Les blocs de code contiennent des commandes shell à exécuter telles quelles : elles n'ont **pas**
de préfixe `$`, vous pouvez les copier-coller directement (depuis GitHub, un bouton de copie est
affiché sur chaque bloc). Les lignes commençant par `#` sont des commentaires. Les encadrés
« Sortie attendue » montrent le résultat attendu. Les encadrés colorés signalent les pièges
fréquents. `VOTRE_USER` désigne partout votre identifiant GitHub.

## Étape 1/8 — Avant la séance : vérifier Docker Engine + Docker Compose (10 min)

### 1.1 Vérifier que Docker est installé

Docker est le pré-requis fondamental : il fait tourner le cluster Kubernetes (kind utilise des
conteneurs Docker comme nœuds), le registry d'images local, les outils en conteneur (client S3) et
tous les services du cours.

```bash
docker --version
docker compose version
```

> **Sortie attendue :** `Docker version 29.x` (27 minimum), et `Docker Compose version v2.x` ou
> `v5.x` (le plugin Compose est passé directement de la v2 à la v5 fin 2025). La commande est bien
> `docker compose` (plugin), pas l'ancien `docker-compose` (v1, abandonné).

> [!TIP]
> **Si Docker n'est pas installé ou trop ancien**
> Suivez la procédure officielle :
>
> - Linux (Ubuntu) : [https://docs.docker.com/engine/install/ubuntu/](https://docs.docker.com/engine/install/ubuntu/)
> - macOS : Docker Desktop depuis docker.com
> - Windows : Docker Desktop avec backend WSL2 activé
>
> Sur Linux, ajoutez votre utilisateur au groupe `docker` pour éviter les `sudo` :
> `sudo usermod -aG docker $USER` puis `newgrp docker` (ou bien : déconnexion / reconnexion).

### 1.2 Smoke test

Lancer un conteneur jetable pour vérifier que le moteur fonctionne et que le réseau Docker est OK :

```bash
docker run --rm hello-world
```

> **Sortie attendue :** un message `Hello from Docker!` avec une explication des étapes effectuées
> par le démon.

### 1.3 Vérifier les ressources allouées

```bash
docker info | grep -E 'CPUs|Total Memory'
```

> [!WARNING]
> **Ressources insuffisantes ?**
> Si `docker info` affiche moins de 4 CPU ou 6 Go de RAM disponibles, le cluster kind à 3 nœuds
> (avec SeaweedFS et MLflow) risque de ramer. Sur Docker Desktop, ouvrez Settings > Resources et
> augmentez les valeurs.

## Étape 2/8 — Avant la séance : installer kubectl, helm, k9s et kind (10 min)

Quatre outils en ligne de commande indispensables :

- **kubectl** : le client officiel pour parler à n'importe quel cluster Kubernetes.
- **helm** : le gestionnaire de paquets de Kubernetes (Prometheus, Argo CD, etc. dans les modules
  suivants).
- **k9s** : un TUI (terminal UI) pour explorer le cluster sans taper 50 fois `kubectl get ...`.
- **kind** (Kubernetes IN Docker) : fait tourner un cluster K8s complet dans des conteneurs Docker.
  Idéal pour le développement : démarrage en une minute, suppression propre en une commande,
  isolation totale.

### 2.1 Installer kubectl

```bash
# Linux x86_64
KVER=$(curl -L -s https://dl.k8s.io/release/stable.txt)
curl -LO "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

# macOS (Homebrew)
brew install kubectl
```

```bash
kubectl version --client
```

> **Sortie attendue :** `Client Version: v1.37.x` (v1.36 minimum : kubectl doit rester à une
> version mineure près de celle du cluster, ici Kubernetes v1.37).

### 2.2 Installer helm

```bash
# Linux / macOS - script officiel (Helm 4)
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 | bash

# macOS alternative
brew install helm
```

```bash
helm version
```

> **Sortie attendue :** `version.BuildInfo{Version:"v4.3.x", ...}`. Helm 4 est sorti fin 2025 et
> reste compatible avec les charts existants ; si vous avez déjà Helm 3, il fonctionnera pour le
> cours, mais il ne reçoit plus que des correctifs de sécurité jusqu'en novembre 2026.

### 2.3 Installer k9s

```bash
# Linux (Ubuntu / Debian, x86_64) - paquet officiel
wget https://github.com/derailed/k9s/releases/latest/download/k9s_linux_amd64.deb
sudo apt install ./k9s_linux_amd64.deb && rm k9s_linux_amd64.deb

# Linux (autre distribution) - alternative
curl -sS https://webinstall.dev/k9s | bash

# macOS
brew install derailed/k9s/k9s
```

```bash
k9s version
```

> **Sortie attendue :** un bandeau ASCII puis `Version: v0.51.x`.

> [!TIP]
> **k9s : raccourcis qui sauvent la vie**
> Une fois lancé : `:pods` liste les pods, `:svc` les services, `:ns` les namespaces. `l` affiche
> les logs d'un pod, `s` ouvre un shell, `d` décrit, `Ctrl-D` supprime, `q` quitte. À utiliser
> tout le long du cours.

### 2.4 Installer kind

```bash
# Linux x86_64 (sur ARM64 : remplacer amd64 par arm64)
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.33.0/kind-linux-amd64
chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind

# macOS
brew install kind
```

```bash
kind version
```

> **Sortie attendue :** `kind v0.33.0 go1.xx.x linux/amd64` (ou `darwin/arm64` sur Mac Apple
> Silicon). kind v0.33.0 démarre par défaut des nœuds **Kubernetes v1.37.0**.

## Étape 3/8 — Avant la séance : forker et cloner le repo du cours (10 min)

Le repo modèle du cours contient la structure de dossiers attendue, l'infrastructure (`infra/`),
le `Makefile`, les fichiers de configuration (dépendances Python, lint, formatage), les énoncés et
scripts de vérification des labs. **Vous travaillerez dans votre copie de ce repo jusqu'au
mini-projet** : on la crée maintenant, car le cluster de l'étape 4 se crée depuis ses fichiers.

### 3.1 Pré-requis : compte GitHub + clé SSH

- Avoir un compte GitHub personnel actif.
- Avoir une clé SSH ajoutée à votre compte (Settings > SSH and GPG keys).
- Si vous n'avez pas de clé : `ssh-keygen -t ed25519 -C "votre.email@etu.fr"` puis copier le
  contenu de `~/.ssh/id_ed25519.pub` dans GitHub.

```bash
ssh -T git@github.com
```

> **Sortie attendue :** `Hi VOTRE_USER! You've successfully authenticated, but GitHub does not
> provide shell access.`

### 3.2 Créer votre copie du repo sur GitHub

Ouvrez le repo modèle du cours,
[https://github.com/mlops-itbs-2026/mlops-cours-2026](https://github.com/mlops-itbs-2026/mlops-cours-2026).
Deux possibilités :

| | **Fork** (recommandé) | **Use this template** |
|---|---|---|
| Bouton GitHub | **Fork** > Create fork | **Use this template** > Create a new repository |
| Visibilité | Public | Public ou privé |
| Récupérer les correctifs du cours | Simple : bouton « Sync fork » ou `git merge upstream/main` | Plus délicat : historique indépendant |
| GitHub Actions (Lab 6) | À activer une fois dans l'onglet Actions | Actives d'emblée |

Dans les deux cas, gardez le nom **`mlops-cours-2026`** : les scripts de vérification et les
énoncés le supposent.

> [!IMPORTANT]
> **Vous travaillez en binôme ? Choisissez votre organisation**
> Le mini-projet se fait en binôme, sur le repo que vous allez construire lab après lab. Deux
> organisations sont possibles :
>
> - **Option A — un repo commun.** Un seul membre (le propriétaire) crée le repo comme
>   ci-dessus, puis, dans **Settings** > **Collaborators** > **Add people**, ajoute son
>   partenaire (rôle *Write*) et l'enseignant (compte communiqué en cours). L'autre membre ne
>   crée pas de repo : il accepte l'invitation, puis clone à l'étape 3.3 le repo du propriétaire
>   (`PROPRIETAIRE/mlops-cours-2026`) et y ajoute lui aussi le remote `upstream`. À partir du
>   Lab 1, celui qui n'a pas piloté un lab remet son cluster à niveau à partir de `main` :
>   chaque énoncé se termine par un encadré « Second membre du binôme ».
> - **Option B — deux repos coordonnés.** Chaque membre crée **son propre** repo comme
>   ci-dessus et y ajoute son partenaire (rôle *Write*, pour relire les PR) et l'enseignant.
>   Chacun fait tous les labs dans son repo ; vous gardez le même jeu de données et vous relisez
>   mutuellement vos pull requests.
>
> Dans les deux cas, **chacun son cluster** : les deux membres font tout le lab (étapes 4 à 8)
> sur leur propre poste, avec leur propre `.env`. Les règles du travail à deux (choix de
> l'option, pull requests relues, protection de `main`, journal de bord, choix du dataset,
> jalons) sont dans le guide du mini-projet, `labs/m10-capstone/README.md` : lisez-le dès cette
> semaine.

### 3.3 Cloner en SSH et déclarer le repo du cours

```bash
# Remplacez VOTRE_USER par votre identifiant GitHub
# (option A : le partenaire met ici l'identifiant du propriétaire du repo commun)
cd ~
git clone git@github.com:VOTRE_USER/mlops-cours-2026.git
cd ~/mlops-cours-2026

# Remote "upstream" = repo du cours, pour récupérer les correctifs en cours de semestre
git remote add upstream https://github.com/mlops-itbs-2026/mlops-cours-2026.git
git remote -v
```

> **Sortie attendue :**
> `origin git@github.com:VOTRE_USER/mlops-cours-2026.git (fetch)` et `(push)`, puis
> `upstream https://github.com/mlops-itbs-2026/mlops-cours-2026.git (fetch)` et `(push)`.

> [!TIP]
> **Récupérer une mise à jour du cours**
> Quand l'enseignant annonce un correctif : `git fetch upstream && git merge upstream/main`, puis
> `git push`. Évitez de modifier les fichiers de `infra/` et `labs/` pour ne pas créer de
> conflits : votre travail vit à la racine du repo (`src/`, `pipelines/`, etc.).

### 3.4 Configurer Git

```bash
git config --global user.name  "Prenom Nom"
git config --global user.email "votre.email@etu.fr"

# Vérifier
git config --list | grep user
```

L'option `--global` est volontaire : le smoke test DVC de l'étape 7 crée un second dépôt Git
jetable, qui a lui aussi besoin de votre identité.

### 3.5 Tour du propriétaire

```bash
ls
make help
```

Vous devez voir notamment :

- `infra/` : l'infrastructure du cours. `versions.env` est la **source unique des versions**
  (kind, images, MLflow, KFP…), `kind/`, `storage/` et `mlflow/` sont déployés aujourd'hui, les
  autres briques arriveront module par module (`make kfp`, `make kserve`…).
- `labs/` : un dossier par lab (`labs/m0-setup/`, `labs/m1-versioning/`…) avec l'énoncé
  (`README.md`), le script de vérification (`check.sh`) et parfois des fichiers de départ.
- `Makefile` : toutes les commandes d'infrastructure (`make cluster`, `make storage`, `make pf`,
  `make check-m0`…).
- `dataset.yaml` et `src/` : le **contrat de données** du projet fil rouge. `dataset.yaml` décrit
  le jeu de données (par défaut *German Credit* : 1 000 demandes de crédit, cible `credit_risk`),
  ses colonnes, ses attributs sensibles et la métrique de promotion ; `src/dataset_config.py` le
  lit et `src/download.py` télécharge les données. Aucun script du cours ne contient de nom de
  colonne en dur : un binôme qui choisit son propre dataset (validé par l'enseignant) ne réécrit
  que `dataset.yaml` et `src/download.py`. Vous les découvrirez au Lab 1.
- `docs/` : les gabarits du mini-projet, à remplir au fil des séances : journal de bord
  (`journal.md`), décisions d'architecture (`adr/`, une ADR par choix important), fiche du
  dataset (`dataset-card.md`), plans du rapport technique et de la soutenance.
- `pyproject.toml` et `uv.lock` : les dépendances Python du cours, figées (étape 6). Le Lab 9
  (RAG) a son propre projet Python, isolé dans `rag/`.
- `.gitignore` : **complet dès aujourd'hui**. Un bloc par lab (`# --- Lab 1 : versioning ---`…)
  liste ce que chaque lab produit sans le versionner (données, pipelines compilés, rapports
  regénérés, `.env`…) : vous n'aurez rien à y ajouter.
- `.env.example` : les adresses et identifiants des services du lab.

Créez votre fichier `.env` à partir du modèle :

```bash
cp .env.example .env
cat .env
```

```bash
# Fichier : .env.example
# Copier en .env (jamais commité) : cp .env.example .env
# Puis, dans chaque nouveau terminal : set -a && source .env && set +a

# MLflow (port-forward : make pf)
MLFLOW_TRACKING_URI=http://localhost:5000

# Stockage S3 du cours — SeaweedFS (port-forward : make pf)
# Utilisé par DVC, boto3, et tout script qui lit/écrit directement dans S3.
# MLflow n'en a PAS besoin (le serveur fait proxy des artefacts).
AWS_ENDPOINT_URL=http://localhost:8333
AWS_ACCESS_KEY_ID=mlops
AWS_SECRET_ACCESS_KEY=mlops-lab-secret
AWS_DEFAULT_REGION=us-east-1

# Pas de télémétrie vers des services tiers (MLflow, Evidently…) depuis les postes
MLFLOW_DISABLE_TELEMETRY=true
DO_NOT_TRACK=true

# Lab 6 (étape 6.2) : jeton du webhook de ré-entraînement continu
# CT_WEBHOOK_TOKEN=
```

Les deux variables de télémétrie empêchent les outils d'envoyer des statistiques d'usage à leurs
éditeurs : MLflow 3 contacte sinon un service de télémétrie à chaque run
(`MLFLOW_DISABLE_TELEMETRY`), et `DO_NOT_TRACK` est la convention commune respectée par d'autres
outils du cours (Evidently…). Utile en salle de TP sans accès Internet, et un bon réflexe de
confidentialité. La dernière ligne, commentée, servira au Lab 6.

> [!CAUTION]
> **Ne jamais commiter `.env`**
> `.env` contient des identifiants. Il est listé dans `.gitignore` : vérifiez avec `git status`
> qu'il n'apparaît jamais dans les fichiers à commiter. Ici ce sont des identifiants de lab, mais
> le réflexe vaut pour la vraie vie.

## Étape 4/8 — Créer le cluster kind + le registry local (10 min)

Le cluster et le registry se créent en une commande, `make cluster`. Prenez d'abord deux minutes
pour lire ce qu'elle fait.

### 4.1 La configuration du cluster : `infra/kind/kind-config.yaml`

Ce cluster a 1 control-plane + 2 workers (assez pour simuler un vrai déploiement multi-nœuds,
léger pour une machine de TP).

```yaml
# Fichier : infra/kind/kind-config.yaml
# kind-config.yaml — cluster unique du cours (créé au Lab 0, conservé jusqu'au mini-projet).
# 1 control-plane + 2 workers. Ne PAS recréer le cluster dans les labs suivants :
# le stockage S3 (SeaweedFS) et MLflow y vivent.
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: mlops-lab
# Registry local (localhost:5001) — utilisé dès le Lab 2 (image du pipeline).
# Le patch n'est plus nécessaire avec les images kind >= v0.27 mais reste inoffensif.
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 80       # Ingress HTTP (Labs 5+)
        hostPort: 80
        protocol: TCP
      - containerPort: 443      # Ingress HTTPS
        hostPort: 443
        protocol: TCP
      - containerPort: 30080    # NodePort Kourier / KServe (Lab 5)
        hostPort: 30080
        protocol: TCP
  - role: worker
  - role: worker
```

- `extraPortMappings` : les ports 80 et 443 du poste sont reliés au control-plane, pour exposer
  plus tard un Ingress ; le port 30080 servira au Lab 5 (NodePort de la passerelle Kourier /
  KServe).
- `containerdConfigPatches` : indique à containerd (le runtime des nœuds) de lire la configuration
  des registries dans `/etc/containerd/certs.d`. C'est ce qui permettra aux nœuds de tirer des
  images depuis le registry local `localhost:5001`.

### 4.2 Le script de création : `infra/kind/create-cluster.sh`

```bash
# Fichier : infra/kind/create-cluster.sh
#!/usr/bin/env bash
# Crée le cluster kind du cours + un registry Docker local branché dessus.
# Idempotent : relancer le script ne casse rien.
# Recette officielle : https://kind.sigs.k8s.io/docs/user/local-registry/
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
source ../versions.env

# 1. Registry local (localhost:5001)
if [ "$(docker inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || true)" != "true" ]; then
  docker run -d --restart=always -p "127.0.0.1:${REGISTRY_PORT}:5000" \
    --network bridge --name "${REGISTRY_NAME}" "${REGISTRY_IMAGE}"
fi

# 2. Cluster
if ! kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER_NAME}"; then
  kind create cluster --config kind-config.yaml
else
  echo "Cluster ${KIND_CLUSTER_NAME} déjà présent — rien à faire."
fi

# 3. Alias localhost:5001 -> registry sur chaque nœud
REGISTRY_DIR="/etc/containerd/certs.d/localhost:${REGISTRY_PORT}"
for node in $(kind get nodes --name "${KIND_CLUSTER_NAME}"); do
  docker exec "${node}" mkdir -p "${REGISTRY_DIR}"
  printf '[host."http://%s:5000"]\n' "${REGISTRY_NAME}" \
    | docker exec -i "${node}" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
done

# 4. Registry sur le réseau Docker "kind"
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${REGISTRY_NAME}")" = "null" ]; then
  docker network connect kind "${REGISTRY_NAME}"
fi

# 5. Documenter le registry (KEP-1755)
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

kubectl cluster-info --context "kind-${KIND_CLUSTER_NAME}"
```

Ce script suit la recette officielle de kind et fait cinq choses :

1. **Registry local** : lance un conteneur `registry:3` (le registry Docker de référence) nommé
   `kind-registry`, publié sur `127.0.0.1:5001`. Le port 5001 évite le 5000, déjà pris sur macOS
   (récepteur AirPlay) et réservé ici au port-forward de MLflow.
2. **Cluster** : `kind create cluster` avec la configuration ci-dessus, seulement s'il n'existe pas
   (le script est **idempotent** : le relancer ne casse rien).
3. **Alias sur chaque nœud** : un fichier `hosts.toml` redirige `localhost:5001` vers
   `http://kind-registry:5000`. Ainsi, une image poussée depuis votre poste en
   `localhost:5001/scoring-api:1.0.0` est tirée par les pods sous **le même nom**.
4. **Réseau** : connecte le registry au réseau Docker `kind` pour que les nœuds le joignent.
5. **ConfigMap `local-registry-hosting`** : documente le registry pour les outils qui savent le
   découvrir (KEP-1755).

Ce registry sert **dès le Lab 2** : l'image du pipeline Kubeflow
(`localhost:5001/scoring-pipeline:<version>`), puis, à partir du Lab 4 (packaging), l'image de
l'API de prédiction (`localhost:5001/scoring-api:<version>`) ; vous les y pousserez avant de les
déployer.

### 4.3 Créer le cluster

```bash
cd ~/mlops-cours-2026
make cluster
```

> **Sortie attendue :** une dizaine de lignes de progression : *Ensuring node image
> (kindest/node:v1.37.0)*, *Preparing nodes*, *Writing configuration*, *Starting control-plane*,
> *Installing CNI*, *Installing StorageClass*, *Joining worker nodes*, puis `Have a nice day!`,
> `configmap/local-registry-hosting created` et `Kubernetes control plane is running at
> https://127.0.0.1:xxxxx`. Le premier lancement télécharge l'image des nœuds (~1 Go).

### 4.4 Vérifier

```bash
kubectl cluster-info --context kind-mlops-lab
kubectl get nodes -o wide
```

> **Sortie attendue :** trois nœuds en état `Ready` : `mlops-lab-control-plane`,
> `mlops-lab-worker`, `mlops-lab-worker2`, version `v1.37.0`.

```bash
docker ps --filter name=kind-registry
curl -s http://localhost:5001/v2/_catalog
```

> **Sortie attendue :** le conteneur `kind-registry` est `Up`, et le registry répond
> `{"repositories":[]}` (vide pour l'instant).

> [!TIP]
> **Bon réflexe — le contexte kubectl**
> Vérifiez que le contexte courant pointe bien sur ce cluster avant chaque session du cours :
> `kubectl config current-context` doit retourner `kind-mlops-lab`. Pour basculer :
> `kubectl config use-context kind-mlops-lab`.

> [!WARNING]
> **En cas d'erreur**
> Si `make cluster` échoue avec une erreur de port déjà utilisé (80, 443, 30080 ou 5001), arrêtez
> le service local qui l'utilise (Apache/Nginx, autre registry…) puis relancez `make cluster`. En
> dernier recours, commentez le mapping concerné dans `infra/kind/kind-config.yaml` et prévenez
> l'enseignant. Si la mémoire est saturée : `make down`, retirez un des deux `- role: worker` du
> fichier de configuration, puis `make cluster`.

> [!CAUTION]
> **Ce cluster est créé une seule fois**
> Le stockage S3 et MLflow vont vivre dans ce cluster jusqu'au mini-projet. Aucun lab ne le recrée.
> `make down` (ou `kind delete cluster`) détruit **toutes** les données : datasets, expériences,
> modèles.

## Étape 5/8 — Déployer le stockage S3 (SeaweedFS) et MLflow dans le cluster (15 min)

Le stockage objet compatible S3 sera utilisé comme remote DVC (versioning des données), comme
stockage des artefacts MLflow (modèles, figures), et comme stockage générique tout au long du
cours.

### 5.1 Pourquoi SeaweedFS ?

Les promotions précédentes utilisaient MinIO. Son édition communautaire a été archivée et ses
images retirées de Docker Hub en 2026 : les anciens manifests ne démarrent plus. Le cours utilise
désormais **SeaweedFS** : licence Apache 2.0, même API S3 (signature v4), et stockage par défaut de
**Kubeflow Pipelines depuis la version 2.15** — une seule technologie S3 pour tout le cours, y
compris le stockage interne de Kubeflow au Lab 2.

> [!NOTE]
> **Pourquoi un S3 local et pas un vrai S3 AWS ?**
> Pour 36h de cours, déployer 50 fois la stack sur AWS coûterait cher et imposerait des comptes
> individuels. SeaweedFS expose la même API S3 que AWS : tout ce qu'on développe est portable vers
> AWS S3, GCS (mode interopérable), Azure Blob (via passerelle) ou OVHcloud Object Storage en
> changeant uniquement l'endpoint et les identifiants.

### 5.2 Le manifest : `infra/storage/storage.yaml`

Configuration de TP uniquement : un seul réplica, pas de TLS, identifiants de lab — à ne jamais
utiliser en production.

```yaml
# Fichier : infra/storage/storage.yaml
# =============================================================================
# Stockage objet S3 du cours — SeaweedFS (Apache 2.0)
# Remplace MinIO (édition communautaire archivée, images retirées de Docker Hub
# en septembre 2026). SeaweedFS est aussi le stockage par défaut de Kubeflow
# Pipelines depuis KFP 2.15 : une seule technologie S3 pour tout le cours.
#
# Configuration de TP : 1 réplica, pas de TLS, identifiants de lab.
# À NE JAMAIS utiliser tel quel en production.
#
#   Endpoint S3 dans le cluster : http://s3.storage:8333
#   Endpoint S3 depuis le poste : http://localhost:8333   (port-forward)
#   Interface web (filer)       : http://localhost:8888   (port-forward)
# =============================================================================
apiVersion: v1
kind: Namespace
metadata:
  name: storage
---
apiVersion: v1
kind: Secret
metadata:
  name: s3-credentials
  namespace: storage
type: Opaque
stringData:
  # Variables standard AWS : réutilisables telles quelles via envFrom.
  AWS_ACCESS_KEY_ID: mlops
  AWS_SECRET_ACCESS_KEY: mlops-lab-secret
---
# Fichier d'identités lu par SeaweedFS (-s3.config). Mêmes identifiants.
apiVersion: v1
kind: Secret
metadata:
  name: seaweedfs-config
  namespace: storage
type: Opaque
stringData:
  s3.json: |
    {
      "identities": [
        {
          "name": "mlops",
          "credentials": [
            { "accessKey": "mlops", "secretKey": "mlops-lab-secret" }
          ],
          "actions": ["Admin", "Read", "Write", "List", "Tagging"]
        }
      ]
    }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: seaweedfs-data
  namespace: storage
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: seaweedfs
  namespace: storage
  labels:
    app: seaweedfs
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: seaweedfs
  template:
    metadata:
      labels:
        app: seaweedfs
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: seaweedfs
          image: ghcr.io/chrislusf/seaweedfs:4.48
          args:
            - server
            - -dir=/data
            - -filer
            - -s3
            - -s3.config=/etc/seaweedfs/s3.json
            - -master.volumePreallocate=false
            - -master.volumeSizeLimitMB=1024
          ports:
            - { name: s3, containerPort: 8333 }
            - { name: filer, containerPort: 8888 }
            - { name: master, containerPort: 9333 }
          readinessProbe:
            httpGet: { path: /status, port: 8333 }
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet: { path: /status, port: 8333 }
            initialDelaySeconds: 30
            periodSeconds: 30
          resources:
            requests: { cpu: 50m, memory: 256Mi }
            limits: { memory: 1Gi }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: ["ALL"] }
          volumeMounts:
            - { name: data, mountPath: /data }
            - { name: s3-config, mountPath: /etc/seaweedfs, readOnly: true }
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: seaweedfs-data
        - name: s3-config
          secret:
            secretName: seaweedfs-config
            items:
              - { key: s3.json, path: s3.json }
---
apiVersion: v1
kind: Service
metadata:
  name: s3
  namespace: storage
spec:
  selector:
    app: seaweedfs
  ports:
    - { name: s3, port: 8333, targetPort: 8333 }
    - { name: filer, port: 8888, targetPort: 8888 }
```

| Ressource | Rôle |
|---|---|
| `Namespace storage` | Isole le stockage du reste du cluster. |
| `Secret s3-credentials` | Identifiants S3 du lab sous les noms standard AWS (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) : un pod les reçoit tels quels avec `envFrom`. Le même secret est recréé dans chaque namespace qui en a besoin (`mlflow`, etc.). |
| `Secret seaweedfs-config` | Fichier `s3.json` lu par SeaweedFS : une identité `mlops` avec ses droits (`Admin`, `Read`, `Write`, `List`, `Tagging`). |
| `PersistentVolumeClaim seaweedfs-data` | 10 Gi sur la StorageClass par défaut de kind (`standard`, provisionneur *local-path*) : les données survivent au redémarrage du pod (l'ancien manifest MinIO utilisait un `emptyDir`, perdu à chaque redémarrage). |
| `Deployment seaweedfs` | `weed server -filer -s3` lance en **un seul processus** les quatre composants de SeaweedFS : *master* (métadonnées des volumes, port 9333), *volume server* (les données), *filer* (arborescence de fichiers + interface web, port 8888) et la *passerelle S3* (port 8333). `volumePreallocate=false` et `volumeSizeLimitMB=1024` évitent de réserver des dizaines de Go sur le disque du poste. Stratégie `Recreate` car le volume est `ReadWriteOnce`. Conteneur non-root, sondes sur `/status`. |
| `Service s3` | Expose le port 8333 (API S3) et 8888 (filer) : `http://s3.storage:8333` depuis les pods du cluster. |

Les buckets partagés du cours sont créés par un Job, juste après le déploiement :

```yaml
# Fichier : infra/storage/buckets-job.yaml
# Crée les buckets partagés du cours (idempotent).
#   mlflow-artifacts : artefacts MLflow (modèles, figures)  — Lab 0+
#   dvc-store        : remote DVC (datasets versionnés)     — Lab 1+
# Relancer : kubectl -n storage delete job create-buckets --ignore-not-found
#            kubectl apply -f infra/storage/buckets-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: create-buckets
  namespace: storage
spec:
  backoffLimit: 10
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: aws
          image: amazon/aws-cli:2.37.9
          envFrom:
            - secretRef:
                name: s3-credentials
          env:
            - { name: AWS_DEFAULT_REGION, value: us-east-1 }
            - { name: AWS_ENDPOINT_URL, value: "http://s3.storage:8333" }
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -e
              for b in mlflow-artifacts dvc-store; do
                aws s3api head-bucket --bucket "$b" 2>/dev/null \
                  || aws s3 mb "s3://$b"
              done
              aws s3 ls
```

- `mlflow-artifacts` : les artefacts MLflow (modèles, figures), dès aujourd'hui ;
- `dvc-store` : le remote DVC du projet fil rouge, à partir du Lab 1 (préfixe `scoring/`).

### 5.3 Déployer SeaweedFS

```bash
make storage
kubectl -n storage get pods,pvc,svc
```

> **Sortie attendue :** après les commandes `kubectl` affichées par `make`,
> `deployment "seaweedfs" successfully rolled out` puis `job.batch/create-buckets condition met`
> (en 1 à 2 minutes). Ensuite : un pod `seaweedfs-xxxxx-xxxxx` en état `Running 1/1`, un pod
> `create-buckets-xxxxx` en état `Completed`, un PVC `seaweedfs-data` en état `Bound`, et le
> service `s3` (ports `8333/TCP,8888/TCP`).

```bash
kubectl -n storage logs job/create-buckets
```

> **Sortie attendue :** `make_bucket: mlflow-artifacts`, `make_bucket: dvc-store`, puis la liste
> des deux buckets. Le Job s'efface automatiquement 10 minutes après sa fin
> (`ttlSecondsAfterFinished`) : passé ce délai, cette commande ne trouve plus rien, c'est normal.

### 5.4 Déployer MLflow

Le cours utilise **un seul serveur MLflow**, dans le cluster, partagé par tous les labs : votre
poste, les pipelines Kubeflow (Lab 2), la CI (Lab 6) y enregistrent leurs expériences. Un serveur
MLflow distingue deux stockages :

- le **backend store** : les métadonnées (expériences, runs, paramètres, métriques, registre de
  modèles). Ici une base **SQLite** sur un volume persistant (`PVC mlflow-data`) ; en production,
  PostgreSQL ou MySQL.
- l'**artifact store** : les fichiers lourds (modèles, figures, rapports). Ici le bucket
  **`s3://mlflow-artifacts`** sur SeaweedFS.

```yaml
# Extrait de infra/mlflow/mlflow.yaml (simplifié)
containers:
  - name: mlflow
    image: ghcr.io/mlflow/mlflow:v3.16.1
    args:
      - >-
        pip install --no-cache-dir --quiet boto3 &&
        exec mlflow server
        --backend-store-uri sqlite:////mlflow/mlflow.db
        --artifacts-destination s3://mlflow-artifacts
        --host 0.0.0.0 --port 5000 --workers 2
        --allowed-hosts "localhost:*,127.0.0.1:*,mlflow.mlflow:*,..."
    envFrom:
      - secretRef:
          name: s3-credentials
    env:
      - { name: MLFLOW_S3_ENDPOINT_URL, value: "http://s3.storage:8333" }
```

L'option `--artifacts-destination` active le **mode proxy** : les clients n'écrivent jamais
directement dans S3, ils envoient les artefacts au serveur MLflow en HTTP, et c'est lui qui les
range dans le bucket. Conséquence : **seul le serveur détient les identifiants S3**, votre poste,
les pods et la CI n'ont besoin que de l'URL MLflow.

```text
poste / pod / CI  --HTTP :5000-->  mlflow (pod)  --S3 :8333-->  seaweedfs : s3://mlflow-artifacts
                                        |
                                        +-- SQLite /mlflow/mlflow.db (PVC mlflow-data)
```

Deux détails du manifest : l'image officielle ne contient pas le client S3 `boto3`, installé au
démarrage du conteneur ; `--allowed-hosts` liste les noms d'hôte acceptés par le middleware de
sécurité de MLflow 3 (protection contre le *DNS rebinding*) : `localhost` pour le port-forward,
`mlflow.mlflow` pour les pods.

```bash
make mlflow
kubectl -n mlflow get pods,pvc
```

> **Sortie attendue :** `deployment "mlflow" successfully rolled out`, puis un pod
> `mlflow-xxxxx-xxxxx` en état `Running 1/1` et un PVC `mlflow-data` en état `Bound`. Comptez 2 à
> 5 minutes au premier lancement (image d'environ 1 Go + installation de `boto3`).

> [!TIP]
> **Ne restez pas à regarder le rollout**
> Si l'étape 6 n'a pas pu être faite avant la séance, lancez-la dans un second terminal pendant
> que `make mlflow` attend, puis revenez ici pour la suite de l'étape 5. Sinon, relisez le
> manifest de MLflow (`infra/mlflow/mlflow.yaml`) en attendant.

### 5.5 Accéder aux services depuis le poste : `make pf`

Les services tournent dans le cluster ; on les rend accessibles depuis le poste par des
*port-forwards* `kubectl`, lancés en arrière-plan par `make pf` :

```bash
make pf
```

> **Sortie attendue :**
> `S3     -> http://localhost:8333`, `Filer  -> http://localhost:8888`,
> `MLflow -> http://localhost:5000`.

Sous le capot, `make pf` exécute (en arrière-plan, journaux dans `/tmp/mlops-port-forward/`) :

```bash
kubectl --context kind-mlops-lab -n storage port-forward svc/s3 8333:8333 8888:8888
kubectl --context kind-mlops-lab -n mlflow  port-forward svc/mlflow 5000:5000
```

`make pf-stop` les arrête. Vérifiez que MLflow répond :

```bash
curl http://localhost:5000/health
```

> **Sortie attendue :** `OK`.

> [!WARNING]
> **Un port-forward ne survit pas à tout**
> Les port-forwards s'arrêtent si le pod redémarre, si le poste se met en veille, ou si vous
> fermez la session. Symptôme : `Connection refused` sur `localhost:5000` ou `localhost:8333`.
> Remède : relancer `make pf` (c'est sans risque). À faire au début de chaque séance.

### 5.6 L'interface web du filer

Ouvrez [http://localhost:8888/buckets/](http://localhost:8888/buckets/) dans le navigateur. Le filer de SeaweedFS présente le
stockage comme une arborescence de fichiers : chaque bucket S3 est un dossier de `/buckets/`. Vous
devez voir `mlflow-artifacts/` et `dvc-store/` (vides pour l'instant).

> [!NOTE]
> **Pas de login ?**
> L'interface du filer n'est pas authentifiée : c'est acceptable sur un port-forward local de TP,
> jamais sur un service exposé. L'API S3 (port 8333), elle, exige les identifiants de `s3.json`.

### 5.7 Créer le bucket de test avec un client S3 en conteneur

Pour parler S3 en ligne de commande, on utilise le client officiel AWS, `aws`, dans son conteneur
(rien à installer). Définissez une fonction `aws-lab` dans votre `~/.bashrc` (sous zsh, remplacez
`~/.bashrc` par `~/.zshrc` dans les deux commandes) :

```bash
cat >> ~/.bashrc <<'EOF'
# Client S3 du cours : AWS CLI en conteneur, vers SeaweedFS (make pf)
aws-lab() {
  docker run --rm --network host \
    -e AWS_ACCESS_KEY_ID=mlops -e AWS_SECRET_ACCESS_KEY=mlops-lab-secret \
    -e AWS_DEFAULT_REGION=us-east-1 \
    amazon/aws-cli:2.37.9 --endpoint-url http://localhost:8333 "$@"
}
EOF
source ~/.bashrc
```

Créez le bucket `mlops-test` et listez les buckets :

```bash
aws-lab s3 mb s3://mlops-test
aws-lab s3 ls
```

> **Sortie attendue :** `make_bucket: mlops-test`, puis les trois buckets `dvc-store`,
> `mlflow-artifacts` et `mlops-test`, chacun précédé de sa date de création. Rafraîchissez
> [http://localhost:8888/buckets/](http://localhost:8888/buckets/) : le dossier `mlops-test/` est apparu.

> [!WARNING]
> **Docker Desktop (macOS / Windows) : `--network host`**
> `--network host` permet au conteneur de joindre le `localhost:8333` du poste. Sur Docker Desktop,
> activez Settings > Resources > Network > « Enable host networking », ou bien remplacez dans
> `aws-lab` l'option `--network host` et `http://localhost:8333` par
> `http://host.docker.internal:8333`.

## Étape 6/8 — Avant la séance : Python 3.12, uv et images du cours (25 min)

uv est un gestionnaire de paquets Python ultra-rapide (écrit en Rust, par Astral, les auteurs de
Ruff). Il remplace `pip` + `virtualenv` + `pip-tools` + `pyenv`. Pourquoi le choisir : installation
10 à 100x plus rapide que pip, lockfile reproductible, gestion des versions Python intégrée.

### 6.1 Installer uv

```bash
# Linux / macOS / WSL2
curl -LsSf https://astral.sh/uv/install.sh | sh

# Recharger le shell pour avoir uv dans le PATH
source ~/.bashrc       # ou ~/.zshrc selon votre shell

uv --version
```

> **Sortie attendue :** `uv 0.12.x` ou plus récent.

### 6.2 Installer Python 3.12 via uv

```bash
uv python install 3.12
uv python list --only-installed
```

> **Sortie attendue :** une ligne `cpython-3.12.x-linux-x86_64-gnu` (ou `macos-aarch64-none`)
> avec son chemin d'installation.

### 6.3 Synchroniser l'environnement du cours

Pas de `uv init` ni de `uv add` : le repo du cours fournit déjà `pyproject.toml` (les
dépendances déclarées) et `uv.lock` (les versions exactes de **tous** les paquets, dépendances
transitives comprises). Une seule commande crée le venv et installe exactement les mêmes versions
que vos camarades et que la CI :

```bash
cd ~/mlops-cours-2026
uv sync
source .venv/bin/activate
```

> **Sortie attendue :** `Using CPython 3.12.x`, `Creating virtual environment at: .venv`, puis
> `Resolved … packages` et `Installed … packages` (près de 300 paquets : comptez une à quelques
> minutes selon la connexion). Le préfixe `(mlops-cours-2026)` apparaît au début de votre prompt.

Ouvrez `pyproject.toml` pour voir ce qui a été installé : un **environnement unique** pour tout le
socle du cours (Labs 0 à 8), installé une fois pour toutes aujourd'hui.

- les **dépendances du socle**, regroupées par lab dans le fichier : `mlflow`, `dvc[s3]`, `boto3`,
  `pandas`, `scikit-learn`, `feast` (Lab 1), `kfp` (Lab 2), `great-expectations`, `evidently`
  (Lab 3), `onnxruntime`, `fastapi`, `bentoml` (Lab 4), `locust` (Labs 4-5), `prometheus-client`
  (Lab 7), `fairlearn`, `shap`, `modelscan` (Lab 8)… ;
- le groupe **`dev`**, installé par défaut : `ruff` (lint/format), `pytest`, `yamllint`.

Aucun lab ne vous fera réinstaller quoi que ce soit : `uv sync`, sans option, suffit toujours.
Seul le Lab 9 (RAG, LLM) a son propre projet Python, isolé dans `rag/` (`rag/pyproject.toml`) :
ses dépendances (LangChain, Ragas, Phoenix…) ne se mélangent pas au socle.

> [!WARNING]
> **`uv sync` synchronise exactement**
> `uv sync` installe ce que décrit `uv.lock` **et désinstalle le reste**. N'installez pas de
> paquets à la main (`pip install`, `uv add`) dans le repo du cours : ils disparaîtraient au
> prochain `uv sync`, ou modifieraient `uv.lock` et créeraient des conflits avec les mises à jour
> du cours.

### 6.4 Vérifier

```bash
python --version
python -c "import sklearn, mlflow, dvc; print('OK', sklearn.__version__, mlflow.__version__)"
dvc --version
```

> **Sortie attendue :** `Python 3.12.x`, puis `OK 1.9.1 3.16.1`, puis `3.67.1`.

Sans activer le venv, préfixez les commandes par `uv run` (par exemple `uv run dvc --version`) :
uv utilise alors automatiquement le venv du projet.

> [!TIP]
> **Activation automatique de l'environnement**
> Pour ne plus avoir à taper `source .venv/bin/activate` (ni à charger `.env`) à chaque ouverture
> de terminal dans ce dossier, installez **direnv** (`brew install direnv` ou
> `sudo apt install direnv`), ajoutez `eval "$(direnv hook bash)"` à votre `~/.bashrc` (ou
> `zsh` dans `~/.zshrc`), puis créez dans le repo un fichier `.envrc` contenant deux lignes :
> `source .venv/bin/activate` et `dotenv` (qui charge `.env`). Tapez `direnv allow` dans le
> dossier.

### 6.5 Pré-télécharger les images du cours

Dernière préparation avant la séance : récupérer dès maintenant les images que les étapes 4 et 5
téléchargeraient en salle, toutes en même temps (image des nœuds kind, environ 1 Go ; MLflow,
environ 1 Go ; SeaweedFS ; client AWS ; registry). La cible `make prefetch` les tire une fois
pour toutes, aux versions de `infra/versions.env` :

```bash
cd ~/mlops-cours-2026
make prefetch
```

> **Sortie attendue :** la progression du téléchargement de chaque image (rien à télécharger
> pour celles déjà présentes). Comptez 10 à 20 minutes selon la connexion, sans surveillance.
> C'est la fin de la préparation : la séance commence à l'étape 4.

## Étape 7/8 — Smoke tests MLflow et DVC (10 min)

DVC et MLflow sont installés et les services tournent. On vérifie ici qu'ils fonctionnent de bout
en bout : client Python, serveur MLflow, stockage S3.

### 7.1 Smoke test MLflow

Il n'y a plus de serveur à lancer sur le poste : on utilise le serveur MLflow du cluster, joignable
grâce à `make pf`. Chargez les variables de `.env` (dont `MLFLOW_TRACKING_URI`) dans le terminal :

```bash
cd ~/mlops-cours-2026
set -a && source .env && set +a
echo $MLFLOW_TRACKING_URI
```

> **Sortie attendue :** `http://localhost:5000`.

Créez le fichier `labs/m0-setup/smoke_mlflow.py` :

```python
# Fichier : labs/m0-setup/smoke_mlflow.py
"""Smoke test MLflow : logge un run (paramètre, métriques, artefact) sur le serveur."""

import os

import mlflow

# Serveur MLflow du cluster, exposé sur le poste par `make pf` (voir .env).
mlflow.set_tracking_uri(os.environ.get("MLFLOW_TRACKING_URI", "http://localhost:5000"))
mlflow.set_experiment("smoke-test")

with mlflow.start_run(run_name="hello-mlops") as run:
    mlflow.log_param("framework", "scikit-learn")
    mlflow.log_metric("accuracy", 0.42)
    mlflow.log_metric("loss", 1.337)
    # L'artefact passe par le serveur MLflow (mode proxy) jusqu'au bucket S3
    # mlflow-artifacts : le client n'a besoin d'aucun identifiant S3.
    mlflow.log_text("hello mlops\n", "hello.txt")
    print("Run logged successfully.")
    print(f"run_id       : {run.info.run_id}")
    print(f"artifact_uri : {run.info.artifact_uri}")
```

```bash
python labs/m0-setup/smoke_mlflow.py
```

> **Sortie attendue :** `Run logged successfully.`, le `run_id`, un `artifact_uri` de la forme
> `mlflow-artifacts:/1/<run_id>/artifacts`, puis deux liens `View run hello-mlops at:
> http://localhost:5000/#/experiments/1/runs/<run_id>` et `View experiment at: …`.

Ouvrez [http://localhost:5000](http://localhost:5000) dans le navigateur. Vous devez voir une expérience `smoke-test` avec
un run `hello-mlops` contenant le paramètre, les métriques et, dans l'onglet *Artifacts*, le
fichier `hello.txt`.

> **Sortie attendue :** l'UI MLflow affiche le run avec `accuracy=0.42` et `loss=1.337`, et
> l'artefact `hello.txt`. Capture d'écran à conserver.

Allez enfin voir où l'artefact a atterri : [http://localhost:8888/buckets/mlflow-artifacts/](http://localhost:8888/buckets/mlflow-artifacts/)
contient un dossier `1/<run_id>/artifacts/hello.txt`. Le script n'a utilisé **aucun** identifiant
S3 : c'est le serveur MLflow qui a écrit dans le bucket (mode proxy).

### 7.2 Smoke test DVC + SeaweedFS

On teste DVC dans un dossier **jetable**, hors du repo du cours (le vrai remote DVC du projet de
credit scoring, `s3://dvc-store/scoring`, sera configuré au Lab 1). Gardez le venv activé
(étape 6) : la commande `dvc` vient de `~/mlops-cours-2026/.venv`.

```bash
rm -rf /tmp/dvc-smoke && mkdir -p /tmp/dvc-smoke && cd /tmp/dvc-smoke
git init && dvc init && git commit -m "dvc init"

# Configurer SeaweedFS (bucket mlops-test) comme remote DVC
dvc remote add -d storage s3://mlops-test/dvcstore
dvc remote modify storage endpointurl http://localhost:8333
dvc remote modify --local storage access_key_id mlops
dvc remote modify --local storage secret_access_key mlops-lab-secret

# Créer un fichier de test, le tracker avec DVC, le pousser
mkdir -p data && echo "hello mlops" > data/sample.txt
dvc add data/sample.txt
git add data/.gitignore data/sample.txt.dvc .dvc/config
git commit -m "Track sample.txt with DVC"
dvc push
```

> **Sortie attendue :** `Setting 'storage' as a default remote.`, puis `1 file pushed`.

Observez la séparation des configurations : `cat .dvc/config` montre l'URL et l'endpoint (fichier
commité, partagé avec l'équipe), `cat .dvc/config.local` les identifiants (fichier **local**,
ignoré par Git, grâce à l'option `--local`). L'endpoint est en `http://` : plus besoin de l'ancien
`use_ssl false`.

Vérifiez que l'objet est bien dans le bucket :

```bash
aws-lab s3 ls --recursive s3://mlops-test/dvcstore/
```

> **Sortie attendue :**
> `2026-10-05 14:21:07         12 dvcstore/files/md5/90/db47eedd801dabbdf799868fb4ae77`.
> DVC range chaque fichier sous `files/md5/` d'après son empreinte MD5 (adressage par contenu) :
> deux fichiers identiques ne sont stockés qu'une fois. Le même objet est visible dans le filer :
> [http://localhost:8888/buckets/mlops-test/dvcstore/files/md5/90/](http://localhost:8888/buckets/mlops-test/dvcstore/files/md5/90/).

> [!IMPORTANT]
> **Étape clé validée**
> Si vous voyez l'objet dans SeaweedFS, la stack DVC + S3 fonctionne. Vous savez désormais
> versionner des données avec un remote S3 — c'est exactement le pattern qui sera utilisé dans
> tous les modules du cours (avec le bucket `dvc-store`).

## Étape 8/8 — Checklist finale de validation + première pull request (10 min)

### 8.1 Premier commit, première pull request

La convention de travail du cours, et du mini-projet, commence ici : on ne commite pas
directement sur `main`. **Chaque lab se fait sur une branche `lab/mX-<slug>`**, du nom du
dossier de l'énoncé (`lab/m0-setup` aujourd'hui, `lab/m1-versioning` au Lab 1…), créée en début
de lab depuis `main` à jour. En fin de lab, la branche est poussée sur GitHub et fusionnée dans
`main` par une **pull request** relue et approuvée par le partenaire du binôme : `main` ne
contient que du travail relu, et l'historique montre qui a fait quoi (il compte dans la note du
mini-projet). Seuls les commits automatiques des outils GitOps (CI, déploiements, à partir du
Lab 6) arrivent directement sur `main`.

Créez la branche, ajoutez un fichier de notes personnelles et commitez votre smoke test :

```bash
cd ~/mlops-cours-2026
git switch -c lab/m0-setup
echo "# Mes notes du cours MLOps" > NOTES.md
git add NOTES.md labs/m0-setup/smoke_mlflow.py
git status        # .env ne doit PAS apparaître
git commit -m "Lab 0: setup OK"
git push -u origin lab/m0-setup
```

> **Sortie attendue :** `branch 'lab/m0-setup' set up to track 'origin/lab/m0-setup'`, et
> GitHub répond par un lien `Create a pull request for 'lab/m0-setup' on GitHub by visiting: …`.

Ouvrez la pull request : ce lien, le bouton **Compare & pull request** de la page du repo, ou
`gh pr create` si vous utilisez GitHub CLI (facultatif, interactif). Le modèle de PR du repo
s'affiche : un titre qui commence par le nom de la branche (`lab/m0-setup : setup OK`), et
dans la description ce que vous avez fait et la sortie de `make check-m0`. Tous les labs
suivent le même modèle. Votre partenaire la relit (**Files changed**) et l'approuve (**Review
changes** > **Approve**) ; vous la fusionnez (**Merge pull request**). Seul, relisez-la et
fusionnez-la vous-même. Revenez ensuite sur `main`, à jour :

```bash
git switch main && git pull
git log --oneline -3
```

> **Sortie attendue :** le commit de fusion `Merge pull request #… from VOTRE_USER/lab/m0-setup`
> au-dessus de « Lab 0: setup OK ». Le même historique est visible sur GitHub.

> [!TIP]
> **En binôme**
> En option B, chacun commite et ouvre sa PR dans son propre repo, et le partenaire la relit.
> En option A, un seul commit et une seule PR : le pilote du jour commite et ouvre la PR ;
> l'autre la relit et l'approuve. Une fois la PR
> fusionnée, l'autre membre supprime ses deux fichiers locaux, identiques, et récupère `main` :
> `rm NOTES.md labs/m0-setup/smoke_mlflow.py && git pull`. Son `make check-m0` passe aussi : son
> smoke test a écrit dans **son** MLflow, et le fichier est commité et poussé. Pour la suite
> (alternance pilote / copilote, journal de bord, branches d'extension), voir le guide du
> mini-projet.

### 8.2 Checklist

Exécutez chaque commande de la colonne « Test » et cochez la case correspondante si la sortie
attendue est obtenue. **Tous les items doivent être verts** avant de passer au Module 1. La
commande `make check-m0` automatise ces vérifications (voir la dernière section).

| # | Composant | Test | Résultat attendu | ☐ |
|---|---|---|---|---|
| 1 | Docker | `docker run --rm hello-world` | Message « Hello from Docker! » | ☐ |
| 2 | Docker Compose | `docker compose version` | Compose v2.x ou v5.x | ☐ |
| 3 | kubectl | `kubectl version --client` | Client v1.36+ | ☐ |
| 4 | helm | `helm version` | v4.x (ou v3.x) | ☐ |
| 5 | k9s | `k9s version` | Affichage de la version | ☐ |
| 6 | kind | `kind get clusters` | `mlops-lab` | ☐ |
| 7 | Cluster K8s | `kubectl get nodes` | 3 nœuds Ready, v1.37 | ☐ |
| 8 | Registry local | `curl -s localhost:5001/v2/_catalog` | `{"repositories":[]}` | ☐ |
| 9 | SeaweedFS | `kubectl -n storage get pods` | Pod `seaweedfs` Running | ☐ |
| 10 | Buckets S3 | `aws-lab s3 ls` | `dvc-store`, `mlflow-artifacts`, `mlops-test` | ☐ |
| 11 | MLflow | Ouvrir `http://localhost:5000` | Expérience `smoke-test`, run `hello-mlops` + artefact | ☐ |
| 12 | uv + Python 3.12 | `uv --version` ; `python --version` | uv 0.12+, Python 3.12.x | ☐ |
| 13 | DVC + SeaweedFS | `dvc push` (depuis `/tmp/dvc-smoke`) | 1 file pushed, objet visible dans le filer | ☐ |
| 14 | Pull request | `git log --oneline -3` (sur `main`) | PR `lab/m0-setup` fusionnée, visible sur GitHub | ☐ |

```bash
make check-m0
```

> [!IMPORTANT]
> **Validation finale**
> Faites une capture d'écran de la sortie de `make check-m0` (ou de cette checklist) **une fois
> tous les items verts** et déposez-la sur l'espace de rendu du cours. C'est le livrable du Lab 0.

## Annexe — Troubleshooting

Erreurs les plus fréquentes rencontrées par les promotions précédentes, avec le diagnostic et la
solution. Si votre problème n'est pas listé, demandez à l'enseignant ou ouvrez une issue sur le
repo du cours.

| Symptôme | Cause probable | Solution |
|---|---|---|
| `docker: permission denied` | Utilisateur pas dans le groupe `docker`. | `sudo usermod -aG docker $USER` puis `newgrp docker`. |
| `kind create cluster` bloque sur « Preparing nodes » | Pas assez de RAM/CPU alloués à Docker Desktop. | Augmenter à 6 Go RAM / 4 CPU dans Settings > Resources. |
| `Port 80/443 already in use` (ou 30080) | Apache, nginx ou IIS tourne déjà. | `sudo systemctl stop apache2` (ou commenter le mapping dans `infra/kind/kind-config.yaml`). |
| `make cluster` : `port is already allocated` sur 5001 | Un autre registry ou service occupe le port 5001. | `docker ps` pour le trouver, l'arrêter, relancer `make cluster`. |
| `kubectl: connection refused` | Mauvais contexte sélectionné. | `kubectl config use-context kind-mlops-lab`. |
| Pod `seaweedfs` en `Pending` | PVC non provisionné (disque plein, provisionneur absent). | `kubectl -n storage get pvc` et `kubectl -n storage describe pod -l app=seaweedfs`. |
| Pod `seaweedfs` en `CrashLoopBackOff` | `s3.json` invalide, permission sur `/data`, mémoire insuffisante. | `kubectl -n storage logs deploy/seaweedfs` pour voir l'erreur exacte. |
| `make storage` expire sur le Job `create-buckets` | SeaweedFS pas encore prêt ou en erreur. | `kubectl -n storage logs job/create-buckets`, puis relancer `make storage` (idempotent). |
| Pod `mlflow` longtemps `0/1` ou en `CrashLoopBackOff` | Téléchargement de l'image (~1 Go) ou de `boto3` impossible (réseau, proxy). | `kubectl -n mlflow logs deploy/mlflow -f` ; vérifier l'accès Internet du cluster. |
| `Could not connect to the endpoint URL: "http://localhost:8333/..."` | Port-forward S3 arrêté (ou `--network host` non supporté). | `make pf` ; lire `/tmp/mlops-port-forward/s3.log` ; sur Docker Desktop, voir l'encadré de l'étape 5.7. |
| `make pf` : `bind: address already in use` sur 5000 | macOS : récepteur AirPlay sur le port 5000, ou autre serveur local. | Réglages Système > Général > AirDrop et Handoff > désactiver « Récepteur AirPlay » ; arrêter tout `mlflow server` local. |
| `InvalidAccessKeyId` / `SignatureDoesNotMatch` | Identifiants différents de ceux de `s3.json`. | Utiliser `mlops` / `mlops-lab-secret` (voir `.env`). |
| UI MLflow : `Invalid Host header` / 403 | Accès par un nom d'hôte non listé dans `--allowed-hosts`. | Passer par `http://localhost:5000` (`make pf`). |
| `dvc push` : `Unable to locate credentials` | Identifiants non configurés sur le remote. | `dvc remote modify --local storage access_key_id mlops` (et `secret_access_key`). |
| `dvc push` : `SSL: WRONG_VERSION_NUMBER` | Endpoint en `https://` alors que SeaweedFS écoute en HTTP. | `dvc remote modify storage endpointurl http://localhost:8333`. |
| `uv: command not found` | PATH pas rechargé après installation. | `source ~/.bashrc` ou ouvrir un nouveau terminal. |
| `uv sync` : `No interpreter found for Python 3.12` | Python 3.12 pas installé. | `uv python install 3.12`. |
| MLflow UI vide après run | Tracking URI pointe sur une autre instance. | `echo $MLFLOW_TRACKING_URI` doit afficher `http://localhost:5000` ; recharger `.env`. |
| `git push` : `Permission denied (publickey)` | Clé SSH non ajoutée à GitHub. | `ssh -T git@github.com` pour tester, ajouter la clé sur GitHub. |
| WSL2 : Docker très lent / fichiers introuvables | Code dans `/mnt/c/` au lieu de `/home/`. | Cloner et travailler dans le système de fichiers Linux WSL. |

> [!NOTE]
> **Note historique : `ImagePullBackOff` sur `minio/minio`**
> Si vous suivez un ancien support (ou un tutoriel en ligne) qui déploie `minio/minio` ou utilise
> le client `minio/mc`, le pod restera en `ImagePullBackOff` : ces images ont été retirées de
> Docker Hub en 2026. C'est la raison du passage à SeaweedFS : utilisez `make storage` et le client
> `aws-lab`.

## Pour aller plus loin

- Documentation kind : [https://kind.sigs.k8s.io/docs/](https://kind.sigs.k8s.io/docs/)
- kind et registry local : [https://kind.sigs.k8s.io/docs/user/local-registry/](https://kind.sigs.k8s.io/docs/user/local-registry/)
- kubectl cheatsheet : [https://kubernetes.io/docs/reference/kubectl/cheatsheet/](https://kubernetes.io/docs/reference/kubectl/cheatsheet/)
- SeaweedFS (wiki) et son API S3 : [https://github.com/seaweedfs/seaweedfs/wiki/Amazon-S3-API](https://github.com/seaweedfs/seaweedfs/wiki/Amazon-S3-API)
- Stockage objet de Kubeflow Pipelines (SeaweedFS par défaut depuis KFP 2.15) :
  [https://www.kubeflow.org/docs/components/pipelines/operator-guides/configure-object-store/](https://www.kubeflow.org/docs/components/pipelines/operator-guides/configure-object-store/)
- uv : [https://docs.astral.sh/uv/](https://docs.astral.sh/uv/)
- MLflow tracking : [https://mlflow.org/docs/latest/ml/tracking/](https://mlflow.org/docs/latest/ml/tracking/)
- Serveur MLflow, backend store et proxy d'artefacts :
  [https://mlflow.org/docs/latest/self-hosting/architecture/tracking-server/](https://mlflow.org/docs/latest/self-hosting/architecture/tracking-server/)
- DVC user guide : [https://dvc.org/doc/user-guide](https://dvc.org/doc/user-guide)

> [!NOTE]
> **Prochaine séance**
> Lab 1 — Versionner un projet ML end-to-end. Vous poserez le projet fil rouge de credit scoring
> (contrat `dataset.yaml`, jeu *German Credit*) sur la stack que vous venez de monter : données
> versionnées avec DVC (remote `s3://dvc-store/scoring`), 20+ expériences scikit-learn tracées dans
> le serveur MLflow du cluster (expérience `scoring`), promotion du meilleur modèle dans le Model
> Registry (`scoring-model@champion`), pipeline `dvc repro` et feature store Feast.
> Préparez le terrain : gardez le cluster kind actif entre les séances (il ne consomme presque rien
> quand il est inactif). Au début de chaque séance : `kubectl get nodes`, puis `make pf`. Votre
> binôme préfère un autre jeu de données que *German Credit* ? Proposez-le à l'enseignant avant
> la séance du Lab 1 (guide du mini-projet, `labs/m10-capstone/README.md`).

## Vérification automatique

Depuis la racine du repo, port-forwards actifs (`make pf`) :

```bash
make check-m0
```

Le script `labs/m0-setup/check.sh` vérifie, sans rien modifier :

- les outils : `docker` (`hello-world`), `docker compose`, `kubectl`, `helm`, `k9s`, `kind` ;
- le cluster `mlops-lab` : 3 nœuds `Ready`, contexte courant `kind-mlops-lab`, registry
  `localhost:5001` qui répond et ConfigMap `local-registry-hosting` présente ;
- les déploiements `seaweedfs` (namespace `storage`) et `mlflow` (namespace `mlflow`) disponibles ;
- les buckets `mlflow-artifacts`, `dvc-store` et `mlops-test` (via `boto3`, identifiants lus dans
  `.env`) ;
- MLflow : `/health` répond `OK`, l'expérience `smoke-test` contient le run `hello-mlops`
  (`accuracy = 0.42`) et son artefact `hello.txt` (relu à travers le proxy) ;
- Python : `uv` installé, venv du repo en Python 3.12, DVC 3.x ;
- DVC : un objet sous `s3://mlops-test/dvcstore/files/md5/` ;
- Git : remote `origin` vers `VOTRE_USER/mlops-cours-2026` sur GitHub, `smoke_mlflow.py` commité
  et le commit courant poussé.

Chaque item affiche ✅ ou ❌ (avec une indication de l'étape à revoir) ; le code retour est le
nombre d'échecs.

> **Sortie attendue :** `🎉 19/19 vérifications OK — Lab 0 validé.`
