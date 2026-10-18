---
module: 5
lab: 5
title: "Déployer le modèle de scoring sur KServe"
subtitle: "Autoscaling, canary, benchmark sous charge réelle"
running_title: "Lab 5 — Serving avec KServe"
duree: "3 heures (atelier guidé)"
stack: "KServe · Knative · Kourier · Locust · Triton · kind"
prerequis: "Lab 4 réussi : image localhost:5001/scoring-api:1.0.0 dans le registry local"
livrable: "ISVC déployé + benchmark P50/P95/P99 + canary 90/10"
---

# Lab 5 — Déployer le modèle de scoring sur KServe

*De l'image Docker du Lab 4 à un service production-ready avec autoscaling, canary deployment
et benchmark sous charge réelle.*

## Objectifs

> [!NOTE]
> **À la fin du lab, vous aurez :**
>
> - KServe installé et opérationnel dans le cluster kind du cours, **sans le recréer**.
> - L'image `scoring-api:1.0.0` du Lab 4 déployée en InferenceService `scoring-model`, appelé
>   depuis votre poste sur `http://localhost:30080`.
> - L'autoscaling configuré : de `minReplicas: 0` (scale-to-zero) à `maxReplicas: 5`, piloté par
>   le nombre de requêtes par seconde.
> - Un test de charge Locust mesurant P50/P95/P99 et RPS max avec 100, 500 et 1 000
>   utilisateurs.
> - Un déploiement canary v2.0.0 recevant 10 % du trafic avant promotion.
> - Un rapport avec table de latences, scale-up observé et analyse du canary.
> - En option : le même modèle servi par Triton et par BentoML, comparés au même banc d'essai.

## Plan du lab

| # | Étape | Durée |
|---|---|---|
| 1 | Installer KServe dans le cluster du cours | 30 min |
| 2 | Rendre l'image `scoring-api` disponible pour le cluster | 10 min |
| 3 | Créer l'InferenceService minimal | 15 min |
| 4 | Tester le service via la passerelle (port 30080) + curl | 10 min |
| 5 | Configurer l'autoscaling (RPS + scale-to-zero) | 20 min |
| 6 | Test de charge Locust : 100 / 500 / 1000 users | 40 min |
| 7 | Déployer v2.0.0 en canary 90/10 | 25 min |
| 8 | (Optionnel) Triton et BentoML : comparer les serveurs | 20 min |
| 9 | Rédiger le rapport | 10 min |

> [!WARNING]
> **Ressources requises**
> Knative, Kourier, cert-manager et KServe ajoutent ≈ 1,5 Go de RAM au cluster, sans compter
> les pods du modèle. Allouez au moins 8 Go de RAM à Docker (Docker Desktop : Settings >
> Resources) et fermez ce qui n'est pas essentiel. Ne recréez **pas** le cluster pour lui donner
> plus de ressources : SeaweedFS et MLflow y vivent depuis le Lab 0. Libérez plutôt la RAM des
> labs précédents : Airflow (Lab 2) s'arrête avec `(cd infra/airflow && docker compose down)`
> (≈ 4 Go), Kubeflow Pipelines se met en pause avec
> `kubectl -n kubeflow scale deploy --all --replicas=0` (et repart avec `--replicas=1`).

> [!NOTE]
> **Vous travaillez sur votre propre dataset ?**
> Rien ne change dans les manifests ni dans le code : l'image du Lab 4 construit son schéma
> depuis `dataset.yaml`, et Locust, le client V2 et `make check-m5` fabriquent leurs requêtes à
> partir de `dataset.yaml` et de vraies lignes de `data/processed/test.csv`. Les chiffres
> (probabilités, seuil, latences, nombre de pods) seront différents. Points d'attention :
> (1) la cible de l'autoscaler (`scaleTarget`) dépend du coût d'une prédiction : un modèle plus
> lourd que la régression logistique (forêt de plusieurs Mo) demandera une cible plus basse ;
> (2) le protocole V2 de Triton (étape 8) ne sait pas transporter de valeur manquante numérique
> en JSON : le client V2 écarte ces lignes (elles restent servies par l'API du Lab 4, qui
> accepte `null`) ; (3) un modèle de plus de quelques dizaines de Mo allonge le démarrage à
> froid du scale-to-zero (étape 5.3).

## Branche de travail

Comme chaque lab (convention du Lab 0, étape 8.1), celui-ci se fait sur sa propre branche,
créée depuis `main` à jour, et se termine par une pull request relue par le partenaire du
binôme :

```bash
cd ~/mlops-cours-2026
git switch main && git pull
git switch -c lab/m5-serving
```

## Convention de notation

Les blocs de code contiennent des commandes shell à exécuter telles quelles depuis la racine de
votre fork (`~/mlops-cours-2026`) : elles n'ont **pas** de préfixe `$`, vous pouvez les
copier-coller directement. Les lignes commençant par `#` sont des commentaires. Un bloc dont la
première ligne est `# Fichier : chemin` est le contenu **complet** de ce fichier. Les encadrés
« Sortie attendue » montrent le résultat attendu.

## Étape 1/9 — Installer KServe dans le cluster du cours (30 min)

### 1.1 Le cluster du Lab 0, tel quel

L'ancienne version de ce lab supprimait le cluster et en recréait un pour mapper le port
30080. C'est inutile : `infra/kind/kind-config.yaml` mappe ce port depuis le Lab 0, précisément
pour la passerelle de KServe. Et ce serait destructeur : le stockage S3 (SeaweedFS) et MLflow
vivent dans ce cluster.

```bash
cd ~/mlops-cours-2026
set -a && source .env && set +a
make pf
kubectl config current-context
kubectl get nodes
docker port mlops-lab-control-plane
```

> **Sortie attendue :** `kind-mlops-lab`, trois nœuds `Ready` (`mlops-lab-control-plane`,
> `mlops-lab-worker`, `mlops-lab-worker2`), puis parmi les ports du nœud de contrôle
> `30080/tcp -> 0.0.0.0:30080` (ainsi que 80 et 443).

### 1.2 Installer Knative, Kourier, cert-manager et KServe

Une seule commande, qui lit les versions dans `infra/versions.env` :

```bash
make kserve
```

Le script `infra/kserve/install.sh` installe, dans cet ordre :

| Brique | Version | Namespace | Rôle |
|---|---|---|---|
| Knative Serving | `knative-v1.23.0` | `knative-serving` | révisions, routage du trafic, autoscaler KPA (scale-to-zero) |
| Kourier | `knative-v1.23.0` | `kourier-system` | passerelle HTTP (Envoy) de Knative, exposée sur le NodePort 30080 |
| cert-manager | `v1.21.2` | `cert-manager` | certificats TLS des webhooks de KServe |
| KServe | `v0.21.0` | `kserve` | CRD `InferenceService`, contrôleur, runtimes de modèles (sklearn, Triton…) |
| metrics-server | `v0.9.0` | `kube-system` | `kubectl top`, métriques CPU / mémoire des pods |
| KEDA (option) | `v2.21.0` | `keda` | autoscaling événementiel, voir « Pour aller plus loin » |

Ce que le script fait de plus que les commandes `kubectl apply` de l'ancien énoncé :

- **Kourier au lieu d'Istio** comme couche réseau de Knative : une seule passerelle Envoy au lieu
  d'un maillage de services complet, bien plus léger sur un poste. Knative est configuré pour
  l'utiliser (`ingress-class`), avec le domaine `example.com` (sans DNS : on passera l'en-tête
  `Host` à curl), et le service `kourier` passe en NodePort 30080 ;
- **le registry local** `localhost:5001` est ajouté à la liste des registries dont Knative ne
  résout pas les tags (étape 2) ;
- **KServe 0.21 en manifests YAML**, avec `kubectl apply --server-side` : le CRD
  `InferenceService` (≈ 2 Mo) dépasse la taille maximale de l'annotation qu'utilise un `apply`
  classique. La ConfigMap `inferenceservice-config` est ensuite modifiée
  (`infra/kserve/inferenceservice-config-patch.yaml`) : mode Knative par défaut et
  `disableIstioVirtualHost: true`, la procédure de KServe pour une couche réseau autre qu'Istio ;
- les contrôleurs de KServe dédiés aux LLM et au cache de modèles, inutiles ici, sont mis à
  0 réplique pour économiser la mémoire.

Extrait du script, la configuration de Knative pour kind :

```bash
# Kourier comme ingress de Knative (clé « ingress-class » ; « ingress.class » est l'ancien nom)
retry 6 k -n knative-serving patch configmap/config-network --type merge \
  -p '{"data":{"ingress-class":"kourier.ingress.networking.knative.dev"}}'
# Domaine externe example.com, sans DNS : on passe l'en-tête Host à curl / Locust
k -n knative-serving patch configmap/config-domain --type merge \
  -p '{"data":{"example.com":""}}'
```

> **Sortie attendue :** 5 à 10 minutes de téléchargements, puis la liste des pods de chaque
> namespace et, pour finir, la ligne « Passerelle Knative (Kourier) : http://localhost:30080
> (en-tête Host = URL de l'ISVC) ». Le script est idempotent : en cas d'erreur réseau, relancez
> `make kserve`.

### 1.3 Vérifier l'installation

```bash
kubectl get pods -n knative-serving
kubectl get pods -n kourier-system
kubectl get pods -n cert-manager
kubectl get pods -n kserve
kubectl get crd | grep serving.kserve.io
kubectl get clusterservingruntimes
kubectl get svc kourier -n kourier-system
```

> **Sortie attendue :** dans `knative-serving`, les pods `activator`, `autoscaler`, `controller`,
> `net-kourier-controller` et `webhook` en `Running` ; `3scale-kourier-gateway` dans
> `kourier-system` ; les trois pods de cert-manager ; `kserve-controller-manager` (2/2) dans
> `kserve`. Douze CRD KServe, dont `inferenceservices.serving.kserve.io`,
> `servingruntimes.serving.kserve.io` et `clusterservingruntimes.serving.kserve.io` ;
> quatorze runtimes (`kserve-sklearnserver`, `kserve-tritonserver`, `kserve-mlserver`…) ; enfin
> le service `kourier` de type `NodePort` avec `80:30080/TCP`.

> [!NOTE]
> **Pourquoi le mode Knative, et plus RawDeployment ?**
> KServe 0.21 propose deux modes de déploiement, renommés depuis l'ancien énoncé :
>
> | | Standard (ex-« RawDeployment ») | Knative (ex-« Serverless ») |
> |---|---|---|
> | Objets créés | Deployment + Service + HPA | Knative Service : révisions, routes, autoscaler |
> | Autoscaling | HPA (CPU, mémoire) ou KEDA | KPA : concurrence ou requêtes/s, **scale-to-zero** |
> | Canary | `spec.canary`, réservé aux modèles téléchargés (`storageUri`) | `canaryTrafficPercent`, pour tout prédicteur |
> | Accès depuis le poste | port-forward, ou contrôleur d'Ingress / Gateway | passerelle Kourier, port 30080 |
> | Coût | rien de plus | Knative + Kourier (≈ 1 Go) |
>
> L'ancien énoncé choisissait RawDeployment parce qu'Istio était lourd et que kind n'a pas de
> LoadBalancer ; il perdait au passage le scale-to-zero et son canary ne fonctionnait pas (son
> propre tableau de dépannage le reconnaissait : « 100/0 au lieu de 90/10 »). Avec Kourier et le
> port 30080 mappé au Lab 0, ces deux raisons disparaissent : on garde le mode Knative, qui
> donne le scale-to-zero et le canary dont ce lab a besoin. Le mode est fixé à la création d'un
> InferenceService et ne peut plus changer ensuite.

## Étape 2/9 — Rendre l'image disponible pour le cluster (10 min)

### 2.1 Plus de `kind load` : le registry du cours

L'ancien énoncé chargeait l'image dans les nœuds avec `kind load docker-image`. Depuis le Lab 0,
le registry `localhost:5001` est branché au cluster : les nœuds tirent eux-mêmes les images
`localhost:5001/...`, comme l'a montré l'étape 8.4 du Lab 4.

```bash
curl -s http://localhost:5001/v2/scoring-api/tags/list
```

> **Sortie attendue :** `{"name":"scoring-api","tags":["1.0.0"]}`.

> [!WARNING]
> **Un tag = une image, pour toujours**
> Knative résout normalement chaque tag en *digest* (l'empreinte de l'image) au moment de créer
> une révision : une révision désigne ainsi une image immuable. Mais c'est le contrôleur de
> Knative, dans un pod, qui interroge le registry, et pour un pod `localhost:5001` n'existe pas
> (seuls les nœuds kind le connaissent). `make kserve` a donc exclu ce registry de la résolution
> (`registries-skipping-tag-resolving`). Conséquence : ne repoussez jamais une image différente
> sous un tag existant ; chaque nouvelle version reçoit son propre tag (`2.0.0` à l'étape 7).

### 2.2 Créer le namespace et les dossiers

```bash
kubectl create namespace scoring
mkdir -p serving reports/m5
```

> **Sortie attendue :** `namespace/scoring created`.

## Étape 3/9 — Créer l'InferenceService minimal (15 min)

### 3.1 Manifest de l'InferenceService

```yaml
# Fichier : serving/scoring-isvc-v1.yaml
# InferenceService minimal : l'image FastAPI + ONNX du Lab 4, servie par KServe en mode
# Knative (Knative Serving + Kourier). Appel : http://localhost:30080 + en-tête Host.
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: scoring-model
  namespace: scoring
  annotations:
    serving.kserve.io/deploymentMode: Knative
spec:
  predictor:
    minReplicas: 1
    maxReplicas: 3
    containers:
      - name: kserve-container
        image: localhost:5001/scoring-api:1.0.0
        imagePullPolicy: IfNotPresent
        ports:
          - containerPort: 8000
            protocol: TCP
        resources:
          requests:
            cpu: "100m"
            memory: "256Mi"
          limits:
            cpu: "1"
            memory: "512Mi"
        readinessProbe:      # sans délai ni période : Knative sonde toutes les 25 ms
          httpGet:           # au démarrage, le pod est prêt dès que /health répond
            path: /health
            port: 8000
```

Le prédicteur est un **conteneur personnalisé** : l'image du Lab 4 telle quelle, avec son
contrat d'API (port 8000, `/health`, `/metadata`, `/predict`), son modèle ONNX et son seuil de
décision figés au build. `kserve-container` est le nom que KServe attend pour le conteneur du
modèle. La sonde de disponibilité n'a ni `initialDelaySeconds` ni `periodSeconds` : dans ce cas,
Knative sonde le conteneur de façon agressive pendant le démarrage, ce qui raccourcit le
démarrage à froid de l'étape 5.

```bash
kubectl apply -f serving/scoring-isvc-v1.yaml
kubectl get isvc -n scoring -w      # Ctrl-C quand READY=True
```

> **Sortie attendue :** après 20 à 40 s, une ligne `READY True` (colonnes `URL`, `READY`,
> `LATEST` = part du trafic de la dernière révision, `LATESTREADYREVISION`) ; le pod
> `scoring-model-predictor-00001-deployment-…` est `Running` dans le namespace `scoring`.

```text
NAME            URL                                                 READY   PREV   LATEST   ...
scoring-model   http://scoring-model-predictor.scoring.example.com   True           100      ...
```

### 3.2 Inspecter ce qui a été créé

```bash
kubectl get ksvc,revisions,kpa -n scoring
kubectl get pods -n scoring
kubectl describe isvc scoring-model -n scoring | tail -15
```

> **Sortie attendue :** un Knative Service `scoring-model-predictor` (`READY True`), une
> révision `scoring-model-predictor-00001`, un autoscaler (`kpa`) avec `DESIREDSCALE 1` et
> `ACTUALSCALE 1`, et un pod `2/2` : deux conteneurs, `kserve-container` et `queue-proxy`.

> [!NOTE]
> **Ce qui se passe sous le capot**
> KServe a traduit l'InferenceService en Knative Service. Knative en a tiré une **révision**
> (instantané immuable : image + configuration), un Deployment, une **route** qui répartit le
> trafic entre révisions, un **PodAutoscaler** (KPA) et les Services Kubernetes. Chaque pod reçoit
> un sidecar `queue-proxy` qui mesure la concurrence et le débit pour l'autoscaler et retient les
> requêtes pendant un démarrage. Tout ça à partir d'un seul YAML : c'est ce qui rendra le
> scale-to-zero et le canary possibles.

## Étape 4/9 — Tester via la passerelle (port 30080) + curl (10 min)

### 4.1 Appeler le service par son nom d'hôte

Tous les services Knative partagent la même passerelle Kourier : c'est l'en-tête `Host` de la
requête qui désigne le service. Le nom d'hôte est dans l'URL de l'InferenceService ; le domaine
`example.com` n'existe dans aucun DNS, on l'envoie donc nous-mêmes à `localhost:30080`.

```bash
ISVC_HOST=$(kubectl get isvc scoring-model -n scoring -o jsonpath='{.status.url}' | cut -d/ -f3)
echo "$ISVC_HOST"
curl -s -H "Host: ${ISVC_HOST}" http://localhost:30080/health
```

> **Sortie attendue :** `scoring-model-predictor.scoring.example.com` puis
> `{"status":"ok","model_loaded":true}`. Sans l'en-tête `Host`, Kourier répond 404 : il ne sait
> pas à quel service transmettre la requête.

### 4.2 Prédiction test

Le corps de la requête est fabriqué à partir de deux vraies demandes de
`data/processed/test.csv`, avec le script du Lab 4 :

```bash
uv run python packaging/sample_request.py -n 2 > /tmp/request.json
curl -s -X POST http://localhost:30080/predict -H "Host: ${ISVC_HOST}" \
    -H "Content-Type: application/json" -d @/tmp/request.json
```

> **Sortie attendue :**
> `{"model_version":"<N>","positive_class":"bad","threshold":0.3182,"predictions":[{"probability":0.5091253519058228,"prediction":1},{"probability":0.2659958302974701,"prediction":0}]}`,
> où `<N>` est la version du Registry exportée au Lab 4 (votre champion, au moins la 7 après
> les Labs 2 et 3).
> La première demande a un score de risque de 0,51, au-dessus du seuil de 0,318 : elle est
> classée à risque (`1`) ; la seconde (0,27) est acceptée (`0`). Ce sont exactement les valeurs
> du conteneur Docker du Lab 4 : même image, même modèle.

### 4.3 Le même seuil partout

Le seuil renvoyé n'est pas 0,5 : c'est le seuil qui minimise le coût métier, calculé par
l'entraînement du Lab 1 et enregistré dans le run MLflow du champion (`decision_threshold`), puis
recopié dans l'image au Lab 4. Vérifiez la chaîne de bout en bout :

```bash
uv run python -c "from mlflow import MlflowClient; c = MlflowClient(); \
mv = c.get_model_version_by_alias('scoring-model', 'champion'); \
print(mv.version, c.get_run(mv.run_id).data.params['decision_threshold'])"
curl -s -H "Host: ${ISVC_HOST}" http://localhost:30080/metadata | python3 -m json.tool | \
    grep -E '"threshold"|"model_version"'
```

> **Sortie attendue :** `<N> 0.3182`, puis `"threshold": 0.3182` et `"model_version": "<N>"`,
> avec le **même** `<N>` des deux côtés : le service sert le champion actuel et décide comme
> son évaluation. Deux numéros différents signalent une image construite avant le dernier
> changement de champion : réexportez le modèle et reconstruisez l'image (Lab 4).

> [!IMPORTANT]
> **Choisir le prédicteur : conteneur personnalisé ou runtime standard ?**
> KServe sait aussi servir un modèle sans image à construire : un *runtime standard*
> (`kserve-sklearnserver`, `kserve-mlserver` pour MLflow, Triton pour ONNX…) télécharge le
> modèle depuis S3 (`storageUri`) et répond aux protocoles d'inférence V1 ou V2. Mais ces
> runtimes renvoient soit la décision de `predict()` — **à 0,5** pour scikit-learn comme pour le
> pyfunc MLflow du Lab 1 —, soit des probabilités brutes : la décision métier passe alors chez le
> client, et rien ne garantit qu'il applique le même seuil. On sert donc l'image du Lab 4 :
> même contrat d'API, prétraitement dans le graphe ONNX, seuil voyageant avec le modèle. L'étape 8
> montre l'autre voie avec Triton, et comment y garder le seuil cohérent.

### 4.4 Depuis un pod du cluster (2 min)

Les autres services du cluster (le pipeline du Lab 6, le générateur de trafic du Lab 7)
appellent le modèle par son adresse interne, sans passer par le port 30080 :

```bash
kubectl run -n scoring client-test --rm -i --restart=Never --image=python:3.12-slim -- \
  python -c "import urllib.request; \
print(urllib.request.urlopen('http://scoring-model-predictor.scoring/health').read().decode())"
```

> **Sortie attendue :** `{"status":"ok","model_loaded":true}` puis
> `pod "client-test" deleted`. L'adresse `http://scoring-model-predictor.scoring` est celle de
> `status.address` de l'InferenceService ; elle mène à la passerelle interne de Kourier.

## Étape 5/9 — Configurer l'autoscaling (20 min)

### 5.1 Autoscaling sur le débit, jusqu'à zéro pod

```yaml
# Fichier : serving/scoring-isvc-v1-autoscale.yaml
# Même InferenceService, avec l'autoscaler de Knative (KPA) : cible en requêtes/s par pod,
# de 0 pod (scale-to-zero) à 5 pods.
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: scoring-model
  namespace: scoring
  annotations:
    serving.kserve.io/deploymentMode: Knative
    autoscaling.knative.dev/window: "60s"            # fenêtre de calcul du RPS moyen
    autoscaling.knative.dev/scale-down-delay: "30s"  # attendre 30 s avant de réduire
spec:
  predictor:
    minReplicas: 0          # scale-to-zero : plus aucun pod quand personne n'appelle
    maxReplicas: 5
    scaleMetric: rps        # autres valeurs : concurrency (défaut), cpu, memory
    scaleTarget: 200        # 200 requêtes/s par pod ; Knative vise 70 % de la cible (140)
    containers:
      - name: kserve-container
        image: localhost:5001/scoring-api:1.0.0
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

KServe traduit `minReplicas`, `maxReplicas`, `scaleMetric` et `scaleTarget` en annotations
`autoscaling.knative.dev/*` de la révision. L'autoscaler de Knative (KPA) calcule toutes les
2 secondes le débit moyen par pod sur la fenêtre de 60 s (et sur 6 s en mode « panique », quand
le trafic double brusquement) et ajuste le nombre de pods pour rester vers 140 requêtes/s par pod.

```bash
kubectl apply -f serving/scoring-isvc-v1-autoscale.yaml
kubectl get isvc scoring-model -n scoring
kubectl get kpa -n scoring
kubectl get revision scoring-model-predictor-00002 -n scoring \
    -o jsonpath='{.metadata.annotations}' | python3 -m json.tool | grep autoscaling
```

> **Sortie attendue :** une nouvelle révision `scoring-model-predictor-00002` reçoit 100 % du
> trafic ; deux autoscalers, celui de `00001` (0 pod : elle ne reçoit plus de trafic) et celui de
> `00002` ; les annotations `autoscaling.knative.dev/class: kpa.autoscaling.knative.dev`,
> `metric: rps`, `target: 200`, `min-scale: 0`, `max-scale: 5`, `window: 60s`.

> [!NOTE]
> **HPA, KPA ou KEDA ?**
> Trois autoscalers, trois logiques :
>
> | | HPA (Kubernetes) | KPA (Knative) | KEDA |
> |---|---|---|---|
> | Métriques | CPU, mémoire (custom via adaptateur Prometheus) | concurrence, requêtes/s | 60+ sources : file Kafka, Prometheus, cron… |
> | Minimum | 1 pod | 0 pod (scale-to-zero) | 0 pod |
> | Réaction | 15 s à 2 min | quelques secondes (mode panique) | quelques secondes |
> | Dans KServe 0.21 | mode Standard, `autoscalerClass: hpa` | mode Knative (défaut) | mode Standard, `autoscalerClass: keda` |
>
> L'ancien énoncé ciblait 60 % de CPU avec un HPA. Pour cette API très légère, le CPU est un
> mauvais signal : le goulot est l'unique worker uvicorn, saturé bien avant que le pod
> n'atteigne sa limite d'un CPU. Le débit (ou la concurrence) mesure directement ce qui compte.
> KEDA brille quand la charge vient d'une file de messages ; il s'installe avec
> `KSERVE_WITH_KEDA=1 make kserve` (voir « Pour aller plus loin »).

### 5.2 Script de monitoring live

```bash
# Fichier : serving/monitor.sh
#!/usr/bin/env bash
# Tableau de bord « live » de l'autoscaling, à lancer dans un terminal dédié pendant les
# tests de charge. Usage : ./serving/monitor.sh [isvc]   (défaut : scoring-model)
ISVC=${1:-scoring-model}
NS=scoring
SEL="serving.kserve.io/inferenceservice=${ISVC}"
while true; do
  clear
  echo "=== $(date +%T) — InferenceService ${NS}/${ISVC} ==="
  kubectl get isvc "$ISVC" -n "$NS"
  echo ""
  echo "=== Autoscaler Knative (KPA) : DESIREDSCALE = pods voulus, ACTUALSCALE = pods prêts ==="
  kubectl get kpa -n "$NS" -l "$SEL" 2>/dev/null
  echo ""
  echo "=== Pods ==="
  kubectl get pods -n "$NS" -l "$SEL"
  echo ""
  echo "=== CPU / mémoire (metrics-server) ==="
  kubectl top pods -n "$NS" -l "$SEL" --containers 2>/dev/null
  sleep 2
done
```

Ouvrez un deuxième terminal et laissez-y tourner le tableau de bord jusqu'à la fin du lab :

```bash
chmod +x serving/monitor.sh && ./serving/monitor.sh
```

> [!TIP]
> **metrics-server**
> `make kserve` l'a installé (avec `--kubelet-insecure-tls`, nécessaire sur kind). Si
> `kubectl top pods` répond `Metrics API not available`, attendez une minute après
> l'installation, ou relancez-le : `kubectl rollout restart -n kube-system deploy/metrics-server`.

### 5.3 Observer le scale-to-zero

Sans trafic, le pod disparaît après la fenêtre de 60 s, le délai de réduction de 30 s et le
délai de grâce de Knative (30 s) : ≈ 2 minutes. La requête suivante réveille le service : le
composant `activator` de Knative la retient pendant qu'un pod démarre.

```bash
kubectl get pods -n scoring -w        # attendre « Terminating » puis plus rien, Ctrl-C
curl -s -o /dev/null -w "HTTP %{http_code} en %{time_total} s\n" \
    -H "Host: ${ISVC_HOST}" http://localhost:30080/health
curl -s -o /dev/null -w "HTTP %{http_code} en %{time_total} s\n" \
    -H "Host: ${ISVC_HOST}" http://localhost:30080/health
```

> **Sortie attendue :** pour le premier appel, `HTTP 200 en 3.5… s` environ, de 2 à 8 s selon
> la machine (démarrage à froid : planification du pod, démarrage d'uvicorn, chargement du
> modèle, sondes) ; pour le second, `HTTP 200 en 0.004… s`. Notez ces deux temps pour le rapport.

> [!WARNING]
> **Le prix du scale-to-zero**
> Zéro pod la nuit, c'est zéro ressource consommée ; mais le premier client du matin attend
> quelques secondes. Pour une API de scoring appelée pendant un parcours de demande de crédit,
> on garde en général `minReplicas: 1` aux heures ouvrées. Le canary de l'étape 7 repasse
> d'ailleurs à `minReplicas: 1`.

## Étape 6/9 — Test de charge avec Locust (40 min)

### 6.1 Préparer Locust

Locust 2.46.6 fait partie du socle (`uv sync`) : rien à installer. Contrairement à l'ancien
scénario, qui tirait des valeurs au hasard dans des colonnes écrites en dur, les requêtes rejouent
de **vraies demandes** de `data/processed/test.csv`, colonnes lues dans `dataset.yaml`. Les corps
de requête sont construits par un petit module partagé, réutilisé par le client V2 de l'étape 8 :

```python
# Fichier : serving/payloads.py
"""Corps de requête construits à partir de dataset.yaml et de vraies lignes de test.

Deux protocoles d'inférence :
- V1 « instances » (API FastAPI du Lab 4, BentoML) : {"instances": [{colonne: valeur}, …]} ;
- V2 / Open Inference Protocol (Triton) : un tenseur [N, 1] par colonne, nommé comme elle,
  FP64 pour les numériques et BYTES (texte) pour les catégorielles : les entrées du graphe
  ONNX du Lab 4.
Aucune colonne n'est écrite ici : changer de dataset ne demande aucune modification.
"""

import sys
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]  # racine du repo
sys.path.append(str(ROOT))
from src.dataset_config import load_config  # noqa: E402

cfg = load_config(ROOT / "dataset.yaml")


def load_rows(csv: Path = ROOT / "data/processed/test.csv") -> list[dict]:
    """Lignes réelles (features de dataset.yaml seulement) ; NaN -> None (null en JSON)."""
    df = pd.read_csv(csv)[cfg.features]
    return df.astype(object).where(df.notna(), None).to_dict("records")


def complete_rows(rows: list[dict]) -> list[dict]:
    """Lignes sans valeur numérique manquante : le JSON du protocole V2 n'a pas de NaN."""
    return [r for r in rows if all(r[c] is not None for c in cfg.numeric)]


def v1_body(rows: list[dict]) -> dict:
    return {"instances": rows}


def v2_body(rows: list[dict]) -> dict:
    """Une entrée par colonne, de forme [N, 1] ; on ne demande que les probabilités."""
    n = len(rows)
    inputs = [
        {"name": c, "shape": [n, 1], "datatype": "FP64", "data": [float(r[c]) for r in rows]}
        for c in cfg.numeric
    ]
    inputs += [  # None -> "" : la valeur manquante du graphe ONNX (imputée par le pipeline)
        {"name": c, "shape": [n, 1], "datatype": "BYTES", "data": [r[c] or "" for r in rows]}
        for c in cfg.categorical
    ]
    return {"inputs": inputs, "outputs": [{"name": "probabilities"}]}


def v2_positive_proba(response: dict) -> list[float]:
    """Probabilité de la classe positive (colonne 1 du tenseur [N, 2] « probabilities »)."""
    out = next(o for o in response["outputs"] if o["name"] == "probabilities")
    return [float(p) for p in out["data"][1::2]]  # données à plat : p0, p1, p0, p1, …
```

```python
# Fichier : serving/locustfile.py
"""Test de charge de l'InferenceService (Lab 5) — rejoue de vraies lignes de test.csv.

Variables d'environnement (toutes optionnelles) :
  ISVC_HOST   en-tête Host, indispensable derrière Kourier (port 30080) : c'est lui qui
              désigne le service, ex. scoring-model-predictor.scoring.example.com
  API_FORMAT  v1 (défaut) : POST /predict, corps {"instances": [...]} (Lab 4, BentoML)
              v2          : POST /v2/models/<V2_MODEL>/infer, protocole V2 (Triton)
  V2_MODEL    nom du modèle côté Triton (défaut : scoring-model)
  BATCH_SIZE  demandes par requête (défaut : 1 ; voir le bonus « batch » de l'étape 6)

Usage (racine du repo) :
    ISVC_HOST=... uv run locust -f serving/locustfile.py --host http://localhost:30080 \
        --users 100 --spawn-rate 20 --run-time 2m --headless
"""

import os
import random

from locust import HttpUser, between, task
from payloads import complete_rows, load_rows, v1_body, v2_body

ISVC_HOST = os.getenv("ISVC_HOST", "")
API_FORMAT = os.getenv("API_FORMAT", "v1")
V2_MODEL = os.getenv("V2_MODEL", "scoring-model")
BATCH_SIZE = int(os.getenv("BATCH_SIZE", "1"))

ROWS = load_rows() if API_FORMAT == "v1" else complete_rows(load_rows())


class PredictUser(HttpUser):
    wait_time = between(0.1, 0.3)

    def on_start(self):
        if ISVC_HOST:
            self.client.headers["Host"] = ISVC_HOST  # routage Kourier/Knative par nom d'hôte

    @task
    def predict(self):
        rows = random.choices(ROWS, k=BATCH_SIZE)
        if API_FORMAT == "v2":
            self.client.post(
                f"/v2/models/{V2_MODEL}/infer", json=v2_body(rows), name="/v2/models/[model]/infer"
            )
        else:
            self.client.post("/predict", json=v1_body(rows))
```

Chaque utilisateur virtuel enchaîne des requêtes `/predict` en attendant 0,1 à 0,3 s entre deux :
100 utilisateurs envoient donc ≈ 450 requêtes/s. Locust ajoute lui-même le dossier du
locustfile au chemin d'import, d'où le simple `from payloads import …`. L'ancien scénario
appelait aussi `/health` une fois sur deux : on ne mesure ici que les requêtes de scoring.

### 6.2 Trois runs progressifs

Gardez le terminal de `monitor.sh` visible, et lancez les trois runs l'un après l'autre :

```bash
export ISVC_HOST
# Run 1 : charge légère (100 users)
uv run locust -f serving/locustfile.py --host http://localhost:30080 \
    --users 100 --spawn-rate 20 --run-time 2m --headless \
    --csv=reports/m5/run_100 --html=reports/m5/run_100.html

# Run 2 : charge moyenne (500 users)
uv run locust -f serving/locustfile.py --host http://localhost:30080 \
    --users 500 --spawn-rate 50 --run-time 3m --headless \
    --csv=reports/m5/run_500 --html=reports/m5/run_500.html

# Run 3 : stress (1000 users)
uv run locust -f serving/locustfile.py --host http://localhost:30080 \
    --users 1000 --spawn-rate 100 --run-time 3m --headless \
    --csv=reports/m5/run_1000 --html=reports/m5/run_1000.html
```

> **Sortie attendue :** trois rapports HTML + CSV dans `reports/m5/`. À chaque run, observez
> `monitor.sh` : run 1, l'autoscaler monte à 3 ou 4 pods (≈ 450 requêtes/s pour une cible de
> 140 par pod), en une quinzaine de secondes ; run 2, il atteint `maxReplicas` (5 pods) ; run 3,
> il plafonne à 5 pods, le CPU des pods touche sa limite, la latence P99 dépasse les 500 ms et
> quelques erreurs (503, délais dépassés) sont acceptables.

> [!TIP]
> **Locust sature avant le service ?**
> Si Locust affiche `CPU usage above 90%!`, c'est lui le goulot, pas KServe : un processus
> Python ne génère guère plus de 1 000 requêtes/s. Ajoutez `--processes 4` (Linux, macOS, WSL2)
> pour répartir les utilisateurs sur 4 processus ; les CSV et le rapport HTML restent agrégés.

### 6.3 Extraire les métriques pour le rapport

```python
# Fichier : serving/locust_report.py
"""Résume les CSV de Locust en un tableau Markdown, à coller dans le rapport (étape 9).

Usage (racine du repo) :
    uv run python serving/locust_report.py                          # reports/m5/run_*
    uv run python serving/locust_report.py "reports/m5/compare_*"   # comparatif (étape 8)
Une ligne par fichier <préfixe>_stats.csv : requêtes de scoring (POST) seulement.
"""

import re
import sys
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
PATTERN = sys.argv[1] if len(sys.argv) > 1 else "reports/m5/run_*"


def run_name(csv: Path) -> str:
    return csv.name.removesuffix("_stats.csv")


def natural_key(csv: Path):
    """run_100 < run_500 < run_1000 : tri numérique quand le nom contient un nombre."""
    numbers = re.findall(r"\d+", run_name(csv))
    return (int(numbers[-1]) if numbers else 0, run_name(csv))


def summarize(csv: Path) -> dict:
    stats = pd.read_csv(csv)
    post = stats[stats["Type"] == "POST"]
    if post.empty:
        raise SystemExit(f"{csv} : aucune requête POST (le test a-t-il tourné ?)")
    row = post.iloc[0]
    total, failures = int(row["Request Count"]), int(row["Failure Count"])
    return {
        "Run": run_name(csv),
        "Requêtes": total,
        "RPS": f"{row['Requests/s']:.1f}",
        "P50 (ms)": f"{row['50%']:.0f}",
        "P95 (ms)": f"{row['95%']:.0f}",
        "P99 (ms)": f"{row['99%']:.0f}",
        "Erreurs (%)": f"{100 * failures / total:.2f}" if total else "n/a",
    }


files = sorted(ROOT.glob(f"{PATTERN}_stats.csv"), key=natural_key)
if not files:
    raise SystemExit(f"Aucun fichier {PATTERN}_stats.csv : lancez d'abord Locust avec --csv")
rows = [summarize(f) for f in files]
print("| " + " | ".join(rows[0]) + " |")
print("|" + "---|" * len(rows[0]))
for r in rows:
    print("| " + " | ".join(str(v) for v in r.values()) + " |")
```

```bash
uv run python serving/locust_report.py
```

> **Sortie attendue :** un tableau Markdown de trois lignes (`run_100`, `run_500`, `run_1000`) :
> requêtes, RPS, P50, P95, P99 et taux d'erreur. Ordres de grandeur sur un laptop 8 cœurs :
> ≈ 440 requêtes/s et un P99 < 100 ms au run 1 ; un débit qui plafonne vers 800-1 000
> requêtes/s aux runs 2 et 3, avec un P99 qui explose au run 3.

> [!IMPORTANT]
> **Ce qu'il faut repérer**
> La saturation : au run 1000, le P99 explose par rapport au run 500 alors que le RPS ne monte
> presque plus. C'est votre RPS max. Au-delà, soit on augmente `maxReplicas`, soit on rend chaque
> pod plus efficace (plusieurs workers uvicorn, batching). Pour ce modèle (0,07 ms d'inférence
> ONNX), un pod tient quelques centaines de requêtes/s : le coût est dans HTTP, JSON et Python,
> pas dans le modèle (Lab 4, étape 5).

### 6.4 Bonus : le pattern batch

Le module 5 présente le scoring **batch** (toutes les demandes d'une nuit en une fois) comme un
pattern à part entière. L'API accepte jusqu'à 1 000 demandes par requête : envoyez-en 50 à la
fois, avec 20 utilisateurs, et comparez le nombre de **prédictions** par seconde.

```bash
BATCH_SIZE=50 uv run locust -f serving/locustfile.py --host http://localhost:30080 \
    --users 20 --spawn-rate 20 --run-time 1m --headless --csv=reports/m5/batch_50
uv run python serving/locust_report.py "reports/m5/batch_*"
```

> **Sortie attendue :** ≈ 85 à 95 requêtes/s, soit ≈ 4 000 à 4 500 prédictions/s (× 50), avec
> une latence à peine plus haute qu'en unitaire : regrouper les demandes divise le coût par
> prédiction. Un vrai job batch (lecture d'un fichier sur S3, écriture des scores) est une
> extension du mini-projet (`batch-scoring`).

## Étape 7/9 — Déployer v2.0.0 en canary 90/10 (25 min)

### 7.1 Préparer une v2.0.0

Pour simuler une nouvelle version, l'API apprend à dire quelle image a répondu : une route
`/version`. La version vient de l'**image** elle-même (l'argument de build `VERSION`, déjà
utilisé au Lab 4 pour le label `org.opencontainers.image.version`) plutôt que d'une variable du
manifest : impossible que le tag et ce que répond l'API divergent. Deux modifications.

Dans `packaging/app/serve.py`, remplacez la ligne `API_VERSION = "1.0.0"` par :

```python
# Version de l'image : ENV APP_VERSION posée au build (Lab 5) ; 1.0.0 pour l'image du Lab 4
API_VERSION = os.getenv("APP_VERSION", "1.0.0")
```

puis ajoutez cette route juste après celle de `/metadata` :

```python
@app.get("/version")
def version():
    # Lab 5 : quelle version a répondu ? (canary, rollback, tests de fumée du Lab 6)
    return {"version": API_VERSION, "model_version": MODEL_VERSION}
```

Dans `packaging/Dockerfile`, ajoutez juste avant la ligne `CMD` :

```dockerfile
# Lab 5 : l'API connaît la version de son image (/version, /metadata) — canary, rollback.
ENV APP_VERSION=${VERSION}
```

Reconstruisez avec le tag 2.0.0, poussez, et vérifiez l'image avant de la déployer :

```bash
MODEL_VERSION=$(uv run python -c \
    "import json; print(json.load(open('packaging/model/metadata.json'))['model_version'])")
docker build -f packaging/Dockerfile -t localhost:5001/scoring-api:2.0.0 \
    --build-arg VERSION=2.0.0 --build-arg MODEL_VERSION="$MODEL_VERSION" .
docker push localhost:5001/scoring-api:2.0.0
docker run -d --rm -p 8000:8000 --name scoring-v2 localhost:5001/scoring-api:2.0.0
sleep 5 && curl -s http://localhost:8000/version
docker stop scoring-v2
```

> **Sortie attendue :** `{"version":"2.0.0","model_version":"<N>"}` : nouvelle image, même
> modèle (la version `<N>` du Registry), donc mêmes prédictions et même seuil.

> [!NOTE]
> **On ne retouche jamais une image publiée**
> L'image `1.0.0` du Lab 4 n'a pas de route `/version`, et on ne la reconstruira pas pour
> l'ajouter : un tag publié désigne une image immuable (étape 2). Pour compter les réponses de
> chaque version, on interrogera donc `/metadata`, qui existe dans les deux : son champ
> `api_version` vaut `1.0.0` dans l'ancienne image et `2.0.0` dans la nouvelle.

### 7.2 Déployer la v2 en canary

```yaml
# Fichier : serving/scoring-isvc-canary.yaml
# Canary : la nouvelle révision (image 2.0.0) reçoit 10 % du trafic ; la dernière révision
# déployée à 100 % (image 1.0.0) garde les 90 % restants. Propre au mode Knative.
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: scoring-model
  namespace: scoring
  annotations:
    serving.kserve.io/deploymentMode: Knative
    serving.kserve.io/enable-tag-routing: "true"     # adresses dédiées latest-… et prev-…
    autoscaling.knative.dev/window: "60s"
    autoscaling.knative.dev/scale-down-delay: "30s"
spec:
  predictor:
    minReplicas: 1          # pendant le canary, les deux versions restent chaudes
    maxReplicas: 5
    scaleMetric: rps
    scaleTarget: 200
    canaryTrafficPercent: 10                     # <--- 10 % vers la nouvelle version
    containers:
      - name: kserve-container
        image: localhost:5001/scoring-api:2.0.0  # <--- nouvelle image
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

```bash
kubectl apply -f serving/scoring-isvc-canary.yaml
kubectl get isvc scoring-model -n scoring -w      # Ctrl-C quand READY=True
```

> **Sortie attendue :** la révision précédente (`PREV`, image 1.0.0) garde 90 % du trafic, la
> nouvelle (`LATEST`, image 2.0.0) en reçoit 10 % :

```text
NAME            ...   READY   PREV   LATEST   PREVROLLEDOUTREVISION           LATESTREADYREVISION
scoring-model   ...   True    90     10       scoring-model-predictor-00002   scoring-model-predictor-00003
```

### 7.3 Vérifier la répartition

```bash
# Envoyer 200 requêtes et compter par version
for i in $(seq 1 200); do
  curl -s -H "Host: ${ISVC_HOST}" http://localhost:30080/metadata | \
    grep -oE '"api_version":"[^"]+"'
done | sort | uniq -c
```

> **Sortie attendue :** environ `180 "api_version":"1.0.0"` et `20 "api_version":"2.0.0"`
> (avec un peu de variance statistique : de 12 à 28 pour la v2 reste normal). C'est votre canary
> en action.

L'annotation `enable-tag-routing` donne aussi à chaque version une adresse dédiée, pratique pour
tester la v2 directement avant de lui envoyer du vrai trafic :

```bash
curl -s -H "Host: latest-${ISVC_HOST}" http://localhost:30080/version
curl -s -H "Host: prev-${ISVC_HOST}" http://localhost:30080/metadata | \
    grep -oE '"api_version":"[^"]+"'
```

> **Sortie attendue :** `{"version":"2.0.0","model_version":"<N>"}` puis
> `"api_version":"1.0.0"`.

### 7.4 Promouvoir si satisfait

```bash
# Si la v2 se comporte bien : 100 % du trafic vers elle
kubectl patch isvc scoring-model -n scoring --type merge \
    -p '{"spec":{"predictor":{"canaryTrafficPercent":100}}}'
kubectl get isvc scoring-model -n scoring

# Ou rollback si problème : 0 % vers la v2, tout le trafic revient sur la révision précédente
# kubectl patch isvc scoring-model -n scoring --type merge \
#     -p '{"spec":{"predictor":{"canaryTrafficPercent":0}}}'
```

> **Sortie attendue :** `READY True` et `LATEST 100` pour la révision
> `scoring-model-predictor-00003` : la v2 sert tout le trafic ; la révision `00002` reste
> disponible pour un retour arrière, mais Knative la passe à zéro pod.

> [!IMPORTANT]
> **Point important sur les canaries**
> Un vrai canary en production combine : traffic splitting (ici) + surveillance automatique
> des métriques (taux d'erreur, latence, distribution des scores) + rollback automatique en cas
> de dégradation. Ici, la décision et le `kubectl patch` sont manuels, et l'état du cluster
> s'éloigne de ce qui est dans Git. Les Modules 6 et 7 automatisent tout cela : le changement de
> version passe par un commit (GitOps avec Argo CD), et la progression du canary aussi, par des
> commits (canary KServe piloté par Git, Lab 6), décidée au Lab 7 par l'analyse des métriques.

## Étape 8/9 — (Optionnel) Triton et BentoML : comparer les serveurs (20 min)

Le cours compare plusieurs serveurs de modèles (Triton, BentoML, KServe). On sert ici le même
modèle de trois façons, derrière la même passerelle : l'image FastAPI + ONNX Runtime
(`scoring-model`), l'image BentoML du Lab 4 (`scoring-bento`) et NVIDIA Triton avec le graphe
ONNX du Lab 4 téléchargé depuis S3 (`scoring-triton`, un runtime standard de KServe).

> [!WARNING]
> **Triton est lourd**
> L'image `nvcr.io/nvidia/tritonserver:23.05-py3` choisie par KServe 0.21 pèse ≈ 6 Go
> compressés (≈ 15 Go sur disque) et le pod demande jusqu'à 2 Go de RAM. Le premier démarrage
> peut prendre 10 à 20 minutes : lancez les étapes 8.1 à 8.3 tôt (par exemple pendant les runs
> Locust), ou contentez-vous de BentoML (8.4), bien plus léger. Supprimez ces services à la fin
> de l'étape.

### 8.1 Déposer le modèle ONNX sur S3 au format Triton

```python
# Fichier : serving/prepare_triton.py
"""Étape 8.1 — dépôt de modèles Triton sur le S3 du cours, à partir du modèle ONNX du Lab 4.

Arborescence produite (format imposé par Triton) :
    s3://models/triton/<nom du modèle>/config.pbtxt
    s3://models/triton/<nom du modèle>/1/model.onnx      (1 = version du modèle)
Le config.pbtxt ne liste AUCUNE colonne : Triton déduit les entrées et les sorties du graphe
ONNX (« auto-complete »). On y règle le batching dynamique et on publie, en paramètres, le
seuil de décision et la classe positive lus dans metadata.json : le client en a besoin pour
décider, Triton ne renvoyant que des probabilités.

Usage (racine du repo, après `set -a && source .env && set +a` et `make pf`) :
    uv run python serving/prepare_triton.py
"""

import json
import os
from pathlib import Path

import boto3

ROOT = Path(__file__).resolve().parents[1]
BUCKET = os.getenv("MODELS_BUCKET", "models")
PREFIX = "triton"  # storageUri de l'InferenceService : s3://models/triton

meta = json.loads((ROOT / "packaging/model/metadata.json").read_text())
name = meta["model_name"]
config = f"""name: "{name}"
platform: "onnxruntime_onnx"
max_batch_size: 64
dynamic_batching {{
  max_queue_delay_microseconds: 2000
}}
instance_group [
  {{
    count: 1
    kind: KIND_CPU
  }}
]
parameters {{
  key: "decision_threshold"
  value: {{ string_value: "{meta["threshold"]}" }}
}}
parameters {{
  key: "positive_class"
  value: {{ string_value: "{meta["positive_class"]}" }}
}}
parameters {{
  key: "model_version"
  value: {{ string_value: "{meta["model_version"]}" }}
}}
"""

# Point d'accès et identifiants lus dans l'environnement (.env : AWS_ENDPOINT_URL, AWS_*)
s3 = boto3.client("s3")
if BUCKET not in [b["Name"] for b in s3.list_buckets()["Buckets"]]:
    s3.create_bucket(Bucket=BUCKET)
s3.put_object(Bucket=BUCKET, Key=f"{PREFIX}/{name}/config.pbtxt", Body=config.encode())
s3.upload_file(str(ROOT / "packaging/model/model.onnx"), BUCKET, f"{PREFIX}/{name}/1/model.onnx")

print(config)
for obj in s3.list_objects_v2(Bucket=BUCKET, Prefix=f"{PREFIX}/")["Contents"]:
    print(f"s3://{BUCKET}/{obj['Key']}  ({obj['Size']} octets)")
```

```bash
uv run python serving/prepare_triton.py
```

> **Sortie attendue :** le `config.pbtxt` généré (seuil `0.3182`, classe positive `bad`,
> version `1`), puis `s3://models/triton/scoring-model/1/model.onnx  (11326 octets)` et
> `s3://models/triton/scoring-model/config.pbtxt  (407 octets)`. Le bucket `models` apparaît
> dans le filer (`http://localhost:8888/buckets/`).

À partir du graphe ONNX, Triton découvre 20 entrées de forme `[-1, 1]` (FP64 pour les 7
numériques, BYTES — du texte — pour les 13 catégorielles) et deux sorties, `label` et
`probabilities`. Le batching dynamique regroupe les requêtes qui arrivent en même temps (jusqu'à
64 demandes, après au plus 2 ms d'attente) en un seul appel au modèle : c'est le levier de
performance présenté en cours.

### 8.2 Donner à KServe l'accès au S3 du cours

Le *storage-initializer* de KServe, un conteneur d'initialisation ajouté au pod, télécharge
`storageUri` dans `/mnt/models` avant le démarrage de Triton. Il lui faut les identifiants S3
(un Secret) et le point d'accès SeaweedFS (des annotations sur ce Secret). Le Secret porte le
même nom que dans les namespaces `storage` et `mlflow` ; il est créé à partir de votre `.env`,
jamais commité :

```bash
kubectl create secret generic s3-credentials -n scoring \
    --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate secret s3-credentials -n scoring --overwrite \
    serving.kserve.io/s3-endpoint=s3.storage:8333 \
    serving.kserve.io/s3-usehttps=0 \
    serving.kserve.io/s3-region="$AWS_DEFAULT_REGION"
```

`s3-endpoint` est l'adresse **dans le cluster** (`s3.storage:8333`, sans `http://`) et
`s3-usehttps=0` indique que SeaweedFS parle HTTP. Le Secret est rattaché aux InferenceServices
par un ServiceAccount :

```yaml
# Fichier : serving/kserve-s3-sa.yaml
# ServiceAccount des InferenceServices qui téléchargent un modèle depuis le S3 du cours.
# KServe lit les clés AWS_* du Secret listé ci-dessous ET les annotations
# serving.kserve.io/s3-* posées sur ce Secret (point d'accès, HTTP, région).
# Le Secret s3-credentials n'est pas dans le repo : il est créé depuis .env (étape 8.2).
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kserve-s3
  namespace: scoring
secrets:
  - name: s3-credentials
```

```bash
kubectl apply -f serving/kserve-s3-sa.yaml
```

### 8.3 Servir le modèle avec Triton et l'interroger en protocole V2

```yaml
# Fichier : serving/scoring-triton-isvc.yaml
# Variante Triton : le MÊME graphe ONNX que l'image du Lab 4, servi par NVIDIA Triton
# (runtime kserve-tritonserver, protocole V2). Le storage-initializer de KServe copie le
# dépôt de modèles depuis le S3 du cours, avec le Secret du ServiceAccount kserve-s3.
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: scoring-triton
  namespace: scoring
  annotations:
    serving.kserve.io/deploymentMode: Knative
    # 1er démarrage : l'image Triton (≈ 6 Go compressés) peut dépasser les 10 min par défaut
    serving.knative.dev/progress-deadline: "1800s"
spec:
  predictor:
    minReplicas: 1
    maxReplicas: 1          # 1 pod : comparaison à ressources égales (étape 8.5)
    serviceAccountName: kserve-s3
    model:
      modelFormat:
        name: onnx
      runtime: kserve-tritonserver
      protocolVersion: v2
      storageUri: s3://models/triton   # scoring-model/config.pbtxt + scoring-model/1/model.onnx
      resources:
        requests: {cpu: "500m", memory: "1Gi"}
        limits: {cpu: "1", memory: "2Gi"}
```

```bash
kubectl apply -f serving/scoring-triton-isvc.yaml
kubectl get isvc scoring-triton -n scoring -w     # Ctrl-C quand READY=True (long la 1re fois)
TRITON_HOST=$(kubectl get isvc scoring-triton -n scoring -o jsonpath='{.status.url}' | cut -d/ -f3)
curl -s -H "Host: ${TRITON_HOST}" http://localhost:30080/v2/models/scoring-model | \
    python3 -m json.tool | head -20
```

> **Sortie attendue :** `READY True`, puis les métadonnées du modèle selon le protocole V2 :
> `"name": "scoring-model"`, `"platform": "onnxruntime_onnx"` et la liste des entrées
> (`"datatype": "FP64"` ou `"BYTES"`, `"shape": [-1, 1]`). Les logs du conteneur
> `storage-initializer` du pod montrent le téléchargement des deux fichiers.

Triton ne connaît que des tenseurs et renvoie des probabilités : c'est au client de décider. Ce
petit client construit la requête V2 depuis `dataset.yaml`, lit le seuil publié dans la
configuration du modèle et, avec `--compare`, envoie les mêmes demandes à l'API du Lab 4 :

```python
# Fichier : serving/v2_client.py
"""Étape 8.3 — interroge le modèle servi par Triton (protocole V2) et décide au seuil métier.

Triton ne renvoie que des probabilités : la décision est prise ICI, avec le seuil publié dans
la configuration du modèle (paramètre decision_threshold écrit par prepare_triton.py, donc
le seuil du run d'entraînement du Lab 1). Avec --compare, les mêmes demandes sont envoyées à
l'API du Lab 4 : mêmes probabilités et mêmes décisions attendues.

Usage (racine du repo) :
    uv run python serving/v2_client.py --host "$TRITON_HOST" -n 5 --compare "$ISVC_HOST"
"""

import argparse
import json
import urllib.request

from payloads import complete_rows, load_rows, v1_body, v2_body, v2_positive_proba

parser = argparse.ArgumentParser()
parser.add_argument("--host", required=True, help="en-tête Host de l'InferenceService Triton")
parser.add_argument("--gateway", default="http://localhost:30080", help="passerelle Kourier")
parser.add_argument("--model", default="scoring-model", help="nom du modèle côté Triton")
parser.add_argument("-n", type=int, default=5, help="nombre de demandes (une seule requête)")
parser.add_argument("--compare", metavar="HOST", help="en-tête Host de l'API du Lab 4")
args = parser.parse_args()


def call(host: str, path: str, body: dict | None = None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Host": host, "Content-Type": "application/json"}
    req = urllib.request.Request(args.gateway + path, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


rows = complete_rows(load_rows())[: args.n]
params = call(args.host, f"/v2/models/{args.model}/config")["parameters"]
threshold = float(params["decision_threshold"]["string_value"])
positive = params["positive_class"]["string_value"]

proba = v2_positive_proba(call(args.host, f"/v2/models/{args.model}/infer", v2_body(rows)))
decisions = [int(p >= threshold) for p in proba]
print(f"Triton : seuil {threshold} (publié avec le modèle), classe positive « {positive} »")
for p, d in zip(proba, decisions, strict=True):
    print(f"  P({positive}) = {p:.4f} -> décision {d}")

if args.compare:
    api = call(args.compare, "/predict", v1_body(rows))
    api_proba = [x["probability"] for x in api["predictions"]]
    api_decisions = [x["prediction"] for x in api["predictions"]]
    gap = max(abs(a - b) for a, b in zip(proba, api_proba, strict=True))
    same = sum(a == b for a, b in zip(decisions, api_decisions, strict=True))
    print(f"API Lab 4 : seuil {api['threshold']} · écart max des probabilités {gap:.1e}")
    print(f"Décisions identiques : {same}/{len(rows)}")
```

```bash
uv run python serving/v2_client.py --host "$TRITON_HOST" -n 5 --compare "$ISVC_HOST"
```

> **Sortie attendue :**

```text
Triton : seuil 0.3182 (publié avec le modèle), classe positive « bad »
  P(bad) = 0.5091 -> décision 1
  P(bad) = 0.2660 -> décision 0
  P(bad) = 0.7381 -> décision 1
  P(bad) = 0.6515 -> décision 1
  P(bad) = 0.3443 -> décision 1
API Lab 4 : seuil 0.3182 · écart max des probabilités 0.0e+00
Décisions identiques : 5/5
```

Même graphe ONNX, même moteur d'exécution (ONNX Runtime), même seuil : mêmes décisions. Mais
cette cohérence repose ici sur la discipline du client ; avec l'image du Lab 4, elle est garantie
par le service lui-même.

### 8.4 Servir l'image BentoML du Lab 4 avec KServe

KServe sert n'importe quelle image HTTP : celle que BentoML a construite au Lab 4 aussi (port
3000, même route `/predict`, même corps de requête, pipeline scikit-learn au lieu d'ONNX).

```yaml
# Fichier : serving/scoring-bento-isvc.yaml
# Variante BentoML du Lab 4 (pipeline scikit-learn, port 3000), servie par KServe comme
# l'API FastAPI : même passerelle, même route /predict, même corps de requête.
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: scoring-bento
  namespace: scoring
  annotations:
    serving.kserve.io/deploymentMode: Knative
spec:
  predictor:
    minReplicas: 1
    maxReplicas: 1          # 1 pod : comparaison à ressources égales (étape 8.5)
    containers:
      - name: kserve-container
        image: localhost:5001/scoring-bento:1.0.0
        imagePullPolicy: IfNotPresent
        ports:
          - containerPort: 3000
            protocol: TCP
        resources:
          requests: {cpu: "200m", memory: "512Mi"}
          limits: {cpu: "1", memory: "1Gi"}
        readinessProbe:
          httpGet: {path: /readyz, port: 3000}
```

```bash
docker tag scoring-api:bentoml localhost:5001/scoring-bento:1.0.0
docker push localhost:5001/scoring-bento:1.0.0
kubectl apply -f serving/scoring-bento-isvc.yaml
kubectl wait --for=condition=Ready isvc/scoring-bento -n scoring --timeout=300s
BENTO_HOST=$(kubectl get isvc scoring-bento -n scoring -o jsonpath='{.status.url}' | cut -d/ -f3)
curl -s -X POST http://localhost:30080/predict -H "Host: ${BENTO_HOST}" \
    -H "Content-Type: application/json" -d @/tmp/request.json
```

> **Sortie attendue :** `inferenceservice.serving.kserve.io/scoring-bento condition met`, puis
> la même réponse JSON qu'à l'étape 4.2, à 10⁻⁷ près (le Bento exécute le pipeline
> scikit-learn, pas l'ONNX).

### 8.5 Même banc d'essai pour les trois serveurs

Même charge pour chacun (20 utilisateurs, 1 minute), un pod par serveur ; Triton est appelé en
protocole V2 :

```bash
ISVC_HOST=$ISVC_HOST API_FORMAT=v1 uv run locust -f serving/locustfile.py \
    --host http://localhost:30080 --users 20 --spawn-rate 20 --run-time 1m --headless \
    --only-summary --csv=reports/m5/compare_fastapi
ISVC_HOST=$BENTO_HOST API_FORMAT=v1 uv run locust -f serving/locustfile.py \
    --host http://localhost:30080 --users 20 --spawn-rate 20 --run-time 1m --headless \
    --only-summary --csv=reports/m5/compare_bento
ISVC_HOST=$TRITON_HOST API_FORMAT=v2 uv run locust -f serving/locustfile.py \
    --host http://localhost:30080 --users 20 --spawn-rate 20 --run-time 1m --headless \
    --only-summary --csv=reports/m5/compare_triton
uv run python serving/locust_report.py "reports/m5/compare_*"
kubectl delete -f serving/scoring-triton-isvc.yaml -f serving/scoring-bento-isvc.yaml
```

> **Sortie attendue :** un tableau de trois lignes (`compare_bento`, `compare_fastapi`,
> `compare_triton`) avec le même débit (≈ 95 requêtes/s : la charge est identique) et des
> latences de quelques millisecondes. BentoML est en général le plus lent (surcoût du pipeline
> scikit-learn, ≈ 4 ms par appel au Lab 4) ; FastAPI et Triton sont proches.

| Critère | FastAPI + ONNX Runtime | BentoML | Triton |
|---|---|---|---|
| Ce que KServe déploie | votre image (conteneur personnalisé) | votre image (conteneur personnalisé) | runtime standard + modèle sur S3 |
| Protocole | V1 « instances » maison | V1 « instances » | V2 (Open Inference Protocol), HTTP et gRPC |
| Décision au seuil métier | dans le service | dans le service | chez le client |
| Batching | à la main (requêtes groupées) | adaptatif, intégré | dynamique, intégré (`dynamic_batching`) |
| Taille de l'image | ≈ 330 Mo | ≈ 500 Mo | ≈ 15 Go |
| Cas idéal | API légère, contrat maîtrisé | du prototype à la prod, vite | GPU, gros modèles, plusieurs modèles par serveur |

## Étape 9/9 — Rédiger le rapport (10 min)

Partez du modèle fourni et complétez ses 5 sections (la 6e est optionnelle) :

```bash
cp labs/m5-serving/starter/rapport-m5.md reports/rapport-m5.md
```

- **Résumé** : l'architecture déployée en 2-3 phrases.
- **Benchmark de latence** : tableau (users / RPS / P50 / P95 / P99 / erreurs) pour les 3 runs
  (100/500/1000) : collez la sortie de `serving/locust_report.py`.
- **Scale-up observé** : nombre de pods à chaque run, CPU moyen, temps de scale-up en secondes ;
  délai de scale-to-zero et démarrage à froid.
- **Analyse canary** : répartition observée v1/v2, conclusion sur la cohérence du split.
- **Points d'amélioration** : ajuster la cible de l'autoscaler, changer de métrique
  (concurrence), plusieurs workers par pod, batching, Triton, etc.
- (Optionnel) **Comparatif des serveurs** de l'étape 8 et bonus batch.

Commitez ensuite le travail (les rapports HTML de Locust, ≈ 1 Mo chacun, restent sur votre
poste) :

```bash
git add serving packaging/app/serve.py packaging/Dockerfile reports/rapport-m5.md \
    reports/m5/*_stats.csv
git commit -m "Lab 5: serving KServe (autoscaling, canary, benchmark)"
git push -u origin lab/m5-serving
gh pr create   # facultatif (GitHub CLI) : ou « Compare & pull request » sur GitHub
```

Votre partenaire relit la PR (manifests de `serving/`, rapport) et l'approuve ; vous la
fusionnez, puis vous revenez sur `main` : `git switch main && git pull`.

> [!NOTE]
> **Second membre du binôme (ou nouveau poste) : remettre votre cluster à niveau**
> Une fois la PR fusionnée, déployez le service sur **votre** cluster (Lab 4 à niveau : image
> `localhost:5001/scoring-api:1.0.0` dans votre registry) :
>
> ```bash
> cd ~/mlops-cours-2026 && git switch main && git pull && uv sync
> make kserve
> kubectl create namespace scoring --dry-run=client -o yaml | kubectl apply -f -
> kubectl apply -f serving/scoring-isvc-v1-autoscale.yaml
> kubectl wait --for=condition=Ready isvc/scoring-model -n scoring --timeout=300s
> MODEL_VERSION=$(uv run python -c \
>     "import json; print(json.load(open('packaging/model/metadata.json'))['model_version'])")
> docker build -f packaging/Dockerfile -t localhost:5001/scoring-api:2.0.0 \
>     --build-arg VERSION=2.0.0 --build-arg MODEL_VERSION="$MODEL_VERSION" .
> docker push localhost:5001/scoring-api:2.0.0
> kubectl apply -f serving/scoring-isvc-canary.yaml
> kubectl wait --for=condition=Ready isvc/scoring-model -n scoring --timeout=300s
> kubectl patch isvc scoring-model -n scoring --type merge \
>     -p '{"spec":{"predictor":{"canaryTrafficPercent":100}}}'
> make check-m5
> ```
>
> Les rapports Locust commités (`reports/m5/*_stats.csv`) sont ceux du binôme : inutile de
> relancer les tests de charge, et rien à commiter.

### Checklist de validation

| # | Élément | Test | Résultat attendu | ☐ |
|---|---|---|---|---|
| 1 | Cluster du Lab 0 + RAM | `kubectl get nodes` · `docker info \| grep Memory` | 3 nœuds `Ready`, > 6 GiB | ☐ |
| 2 | Knative installé | `kubectl get pods -n knative-serving` | Tous `Running` | ☐ |
| 3 | Kourier sur le port 30080 | `kubectl get svc kourier -n kourier-system` | `80:30080/TCP` | ☐ |
| 4 | cert-manager OK | `kubectl get pods -n cert-manager` | Tous `Running` | ☐ |
| 5 | KServe installé | `kubectl get pods -n kserve` | `kserve-controller-manager` `Running` | ☐ |
| 6 | Images dans le registry | `curl localhost:5001/v2/scoring-api/tags/list` | `1.0.0` et `2.0.0` | ☐ |
| 7 | ISVC READY=True | `kubectl get isvc -n scoring` | `READY True` | ☐ |
| 8 | Predict via la passerelle | `curl -H "Host: …" localhost:30080/predict` | JSON valide, `threshold` 0.3182 | ☐ |
| 9 | Seuil cohérent | `decision_threshold` du champion | = `threshold` servi | ☐ |
| 10 | Autoscaling configuré | `kubectl get kpa -n scoring` | autoscaler visible, scale-to-zero observé | ☐ |
| 11 | Run Locust 100 | `reports/m5/run_100.html` | P99 < 100 ms typiquement | ☐ |
| 12 | Run Locust 500 | `reports/m5/run_500.html` | Scale-up observé | ☐ |
| 13 | Run Locust 1000 | `reports/m5/run_1000.html` | Plateau à `maxReplicas` | ☐ |
| 14 | Canary déployé | `kubectl get isvc scoring-model -n scoring` | `PREV 90`, `LATEST 10` | ☐ |
| 15 | Split 90/10 observé | boucle sur `/metadata` | ≈ 180 v1, ≈ 20 v2 | ☐ |
| 16 | Rapport rédigé | `cat reports/rapport-m5.md` | 5 sections présentes | ☐ |

```bash
make check-m5
```

## Critères d'évaluation (noté sur 20)

| Critère | Description | Points |
|---|---|---|
| Déploiement KServe | KServe installé dans le cluster du cours, ISVC READY, `/predict` fonctionnel via la passerelle, seuil servi = seuil du champion. | 6 |
| Autoscaling | Autoscaler configuré (KPA sur le débit), scale-up observé sous charge, scale-to-zero mesuré. | 4 |
| Benchmark | 3 runs Locust, table P50/P95/P99 + RPS + erreurs. | 4 |
| Canary | v2 déployée, split 90/10 vérifié expérimentalement, promotion ou rollback. | 3 |
| Rapport | 5 sections, analyse honnête du point de saturation. | 3 |
| **Total** | | **20** |

## Annexe — Troubleshooting

| Symptôme | Cause probable | Solution |
|---|---|---|
| `make kserve` : `x509` ou `connection refused` sur un webhook | Webhook pas encore prêt (cert-manager vient de signer son certificat). | Le script réessaie seul ; sinon relancez `make kserve` (idempotent). |
| ISVC `READY=False` au bout de 5 min, pod en `ImagePullBackOff` | Image absente du registry ou nom erroné. | `curl localhost:5001/v2/scoring-api/tags/list` ; `kubectl describe pod -n scoring <pod>`. Pas de `kind load` : le registry est branché au cluster. |
| ISVC `READY=False`, révision `RevisionMissing` ou « failed to resolve image to digest » | Knative essaie de résoudre le tag `localhost:5001/…`. | Relancer `make kserve` (ajoute `localhost:5001` à `registries-skipping-tag-resolving`), puis supprimer et réappliquer l'ISVC. |
| Pod en `CrashLoopBackOff` | L'API ne démarre pas (modèle ou `dataset.yaml` absent de l'image). | `kubectl logs -n scoring <pod> -c kserve-container` ; reconstruire l'image (Lab 4). |
| Pods KServe ou Knative `OOMKilled` ou `Pending` | Ressources Docker insuffisantes. | Docker Desktop : Resources > 8 Go RAM, 4+ CPU. Arrêter Airflow, mettre KFP en pause (encadré « Ressources requises »). |
| `curl localhost:30080` : `Connection refused` | Service `kourier` pas en NodePort 30080, ou cluster créé sans le mapping. | `kubectl get svc kourier -n kourier-system` ; `docker port mlops-lab-control-plane` ; relancer `make kserve`. |
| `curl` : 404 avec une réponse vide | En-tête `Host` absent ou erroné : Kourier ne sait pas où router. | `echo $ISVC_HOST` (nouveau terminal ?) ; le recalculer depuis `kubectl get isvc … -o jsonpath='{.status.url}'`. |
| `curl /predict` : 503 Service Unavailable | Pod pas encore prêt. | `kubectl wait --for=condition=Ready pod -l serving.kserve.io/inferenceservice=scoring-model -n scoring`. |
| Premier appel lent (plusieurs secondes) | Démarrage à froid après un scale-to-zero. | Normal avec `minReplicas: 0` ; `minReplicas: 1` pour l'éviter. |
| `kubectl top pods` : `Metrics API not available` | metrics-server pas encore prêt. | Attendre 60 s après l'install, ou `kubectl rollout restart -n kube-system deploy/metrics-server`. |
| Sous charge, `DESIREDSCALE` reste à 1 | Cible `scaleTarget` au-dessus de ce qu'un pod sait servir : saturé, il ne dépasse jamais la cible. | Baisser `scaleTarget`, ou passer à `scaleMetric: concurrency`. |
| Locust : 100 % d'échecs, `404` | `ISVC_HOST` non exporté dans le terminal de Locust. | `export ISVC_HOST=…` avant `uv run locust`. |
| Locust : `connection reset`, erreurs au run 1000 | Le service sature (attendu au run 3), ou Locust lui-même (`CPU usage above 90%`). | Augmenter `maxReplicas`, relâcher les limites CPU ; côté Locust, `--processes 4`. |
| `update rejected: deploymentMode cannot be changed` | On a changé l'annotation `deploymentMode` d'un ISVC existant. | Le mode est fixé à la création : `kubectl delete isvc …` puis réappliquer. |
| Canary : 100/0 au lieu de 90/10 | ISVC en mode Standard (`canaryTrafficPercent` y est ignoré), ou pas de révision précédente déployée à 100 %. | Annotation `serving.kserve.io/deploymentMode: Knative` ; `kubectl get isvc` doit montrer `PREV` et `LATEST`. |
| `/version` : `{"detail":"Not Found"}` | Requête servie par la révision 1.0.0 (normal 9 fois sur 10), ou image 2.0.0 construite avant la modification de `serve.py`. | `curl -H "Host: latest-$ISVC_HOST" …/version` ; sinon reconstruire et pousser 2.0.0. |
| Triton : ISVC bloqué, `ProgressDeadlineExceeded` | Téléchargement de l'image Triton (≈ 6 Go) trop long. | Annotation `serving.knative.dev/progress-deadline` (déjà à 30 min) ; `kubectl get events -n scoring`. |
| Triton : init container `storage-initializer` en erreur (`NoCredentialsError`, `EndpointConnectionError`) | Secret absent, mal annoté, ou ServiceAccount non référencé. | `kubectl logs -n scoring <pod> -c storage-initializer` ; refaire l'étape 8.2 ; `serviceAccountName: kserve-s3`. |
| Triton : modèle `UNAVAILABLE`, `failed to load` | Mauvaise arborescence : `storageUri` doit désigner le dossier qui contient `scoring-model/`. | `aws-lab s3 ls --recursive s3://models/triton/` ; relancer `prepare_triton.py`. |
| `prepare_triton.py` : `XAmzContentSHA256Mismatch` ou erreur de *checksum* à l'envoi | Sommes de contrôle CRC envoyées par défaut par boto3 récent, mal acceptées par le serveur S3. | `export AWS_REQUEST_CHECKSUM_CALCULATION=when_required` puis relancer le script. |
| Triton : 400 `unexpected datatype` | Type d'entrée différent du graphe ONNX (FP32 au lieu de FP64…). | Construire la requête avec `serving/payloads.py` (`v2_body`). |
| Kourier : `SETTINGS_MAX_CONCURRENT_STREAMS` | Connexion gRPC périmée. | `kubectl rollout restart deploy/3scale-kourier-gateway -n kourier-system`. |
| Port-forward de secours | Passerelle indisponible et besoin d'un accès direct. | `kubectl port-forward -n scoring deploy/scoring-model-predictor-00001-deployment 8001:8000` puis `curl localhost:8001/health` (adapter le numéro de révision ; le port 8080 est pris par l'UI KFP). |
| Nœud kind plein (`no space left`) | Images accumulées (Triton !). | `docker exec mlops-lab-worker crictl rmi --prune` (idem `mlops-lab-worker2`, `mlops-lab-control-plane`). |

> [!NOTE]
> **Prochaine étape**
> Module 6 — CI/CD pour le ML avec Continuous Training. Vous allez automatiser le cycle complet :
> push Git → tests → build de l'image → déploiement de l'InferenceService `scoring-model`, avec
> Argo CD pour le GitOps et un ré-entraînement déclenché par la dérive des données.

## Pour aller plus loin

- **HPA en mode Standard** : un InferenceService créé avec les annotations
  `serving.kserve.io/deploymentMode: Standard` et `serving.kserve.io/autoscalerClass: hpa`, et
  `scaleMetric: cpu` / `scaleTarget: 60` dans `spec.predictor`, obtient un vrai
  HorizontalPodAutoscaler à 60 % de CPU (les anciennes annotations `serving.kserve.io/metrics`
  et `targetUtilizationPercentage` ne sont plus lues). Accès par port-forward vers le Service
  `<nom>-predictor`.
- **KEDA** : `KSERVE_WITH_KEDA=1 make kserve` installe KEDA v2.21.0. En mode Standard,
  `serving.kserve.io/autoscalerClass: keda` et un bloc `spec.predictor.autoScaling` font créer
  par KServe un `ScaledObject` ; avec les métriques Prometheus du Lab 7, on peut scaler sur le
  débit réel, ou sur la longueur d'une file de demandes à scorer.
- **Transformer** : un conteneur `spec.transformer` devant le prédicteur, pour un prétraitement
  qui évoluerait indépendamment du modèle (ici inutile : il est dans le graphe ONNX).
- **Batcher de KServe** : `spec.predictor.batcher` regroupe côté serveur les requêtes V1
  `{"instances": …}` avant de les transmettre au modèle.
- **Extensions du mini-projet** liées à ce lab : `scale-to-zero` (mesurer et réduire le
  démarrage à froid), `batch-scoring`, `onnx-quantifie`, `shadow`, `ab-test`.

## Vérification automatique

Depuis la racine du repo, cluster actif et port-forwards lancés (`make pf`) :

```bash
make check-m5
```

Le script `labs/m5-serving/check.sh` vérifie, sans rien modifier :

- l'infrastructure : namespace `scoring`, Knative Serving et Kourier prêts, passerelle sur le
  NodePort 30080, cert-manager et contrôleur KServe prêts, `kubectl top nodes` ;
- le service : InferenceService `scoring-model` `Ready` ; `/health` répond via
  `http://localhost:30080` avec l'en-tête `Host` tiré de `status.url` (via un port-forward si
  l'ISVC est en mode Standard) ; `/predict` répond pour une vraie ligne de
  `data/processed/test.csv` (colonnes lues dans `dataset.yaml`) avec une probabilité dans
  [0, 1] et une décision cohérente avec le seuil renvoyé ;
- la cohérence de décision : le seuil servi est égal au paramètre MLflow `decision_threshold`
  du champion (`models:/scoring-model@champion`) ;
- l'autoscaling : `maxReplicas` ≥ 2 et un autoscaler (KPA de Knative, HPA ou KEDA) ;
- le canary : tag `2.0.0` dans le registry, présent dans une révision de l'ISVC, et `/version`
  répond `2.x` ;
- les livrables : `reports/m5/run_100`, `run_500` et `run_1000` (`_stats.csv`) avec des requêtes
  de scoring, `reports/rapport-m5.md` avec au moins 5 sections et le tableau des trois runs
  rempli, manifests et scripts dans `serving/`.

Variables optionnelles : `NS`, `ISVC`, `GATEWAY` (défaut `http://localhost:30080`),
`CHECK_PORT`, `REGISTRY`. Code retour = nombre de vérifications en échec.
