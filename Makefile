# =============================================================================
# Cours MLOps — commandes d'infrastructure et de vérification
#   make help            liste des cibles
#   make up              cluster kind + registry + SeaweedFS + MLflow (Lab 0)
#   make pf              port-forwards S3 (8333), filer (8888), MLflow (5000)
#   make check-m1        vérifie l'état attendu à la fin du Lab 1
# =============================================================================
SHELL := bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c
include infra/versions.env
export

KCTX := kind-$(KIND_CLUSTER_NAME)
PF_LOG := /tmp/mlops-port-forward

.PHONY: help
help: ## Affiche cette aide
	@grep -hE '^[a-zA-Z0-9_%-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n",$$1,$$2}'

# --- Socle (Lab 0) ------------------------------------------------------------
.PHONY: cluster storage mlflow up
cluster: ## Crée le cluster kind + le registry local (idempotent)
	./infra/kind/create-cluster.sh

storage: ## Déploie SeaweedFS (S3) et crée les buckets partagés
	kubectl --context $(KCTX) apply -f infra/storage/storage.yaml
	kubectl --context $(KCTX) -n storage rollout status deploy/seaweedfs --timeout=300s
	kubectl --context $(KCTX) -n storage delete job create-buckets --ignore-not-found
	kubectl --context $(KCTX) apply -f infra/storage/buckets-job.yaml
	kubectl --context $(KCTX) -n storage wait --for=condition=complete job/create-buckets --timeout=300s

mlflow: ## Déploie le serveur MLflow du cours
	kubectl --context $(KCTX) apply -k infra/mlflow
	kubectl --context $(KCTX) -n mlflow rollout status deploy/mlflow --timeout=600s

# Images tirées à l'avance (make prefetch) puis chargées dans les nœuds (make preload) :
# évite ~3 Go de téléchargements simultanés en salle.
CLUSTER_IMAGES := $(SEAWEEDFS_IMAGE) $(MLFLOW_IMAGE) $(AWS_CLI_IMAGE)

.PHONY: prefetch preload
prefetch: ## Avant la séance du Lab 0 : télécharge les images du socle (~3 Go)
	docker pull $(KIND_NODE_IMAGE)
	docker pull $(REGISTRY_IMAGE)
	for img in $(CLUSTER_IMAGES); do docker pull "$$img"; done

preload: ## Charge dans les nœuds kind les images déjà présentes sur le poste
	for img in $(CLUSTER_IMAGES); do
	  if docker image inspect "$$img" >/dev/null 2>&1; then
	    kind load docker-image --name $(KIND_CLUSTER_NAME) "$$img" \
	      || echo "  (chargement impossible pour $$img : il sera téléchargé par le cluster)"
	  fi
	done

up: cluster preload storage mlflow ## Socle complet du Lab 0
	@echo "Socle prêt. Lancez 'make pf' pour accéder aux services depuis le poste."

.PHONY: pf pf-stop
pf: ## Port-forwards : S3 :8333, filer :8888, MLflow :5000 (en arrière-plan)
	mkdir -p $(PF_LOG)
	pkill -f "port-forward svc/s3 8333" || true
	pkill -f "port-forward svc/mlflow 5000" || true
	nohup kubectl --context $(KCTX) -n storage port-forward svc/s3 8333:8333 8888:8888 >$(PF_LOG)/s3.log 2>&1 &
	nohup kubectl --context $(KCTX) -n mlflow  port-forward svc/mlflow 5000:5000      >$(PF_LOG)/mlflow.log 2>&1 &
	sleep 3
	echo "S3     -> http://localhost:8333"
	echo "Filer  -> http://localhost:8888"
	echo "MLflow -> http://localhost:5000"

pf-stop: ## Arrête tous les port-forwards du cours (S3, MLflow, UI KFP)
	pkill -f "port-forward svc/s3 8333" || true
	pkill -f "port-forward svc/mlflow 5000" || true
	pkill -f "port-forward svc/ml-pipeline-ui 8080" || true

# --- Briques ajoutées module par module ----------------------------------------
.PHONY: kfp airflow kserve argocd monitoring external-secrets
kfp: ## Lab 2 — Kubeflow Pipelines standalone (KFP_VERSION)
	./infra/kfp/install.sh
airflow: ## Lab 2 — Airflow (variante de comparaison)
	./infra/airflow/install.sh
kserve: ## Lab 5 — cert-manager + Knative + Kourier + KServe
	./infra/kserve/install.sh
argocd: ## Lab 6 — Argo CD (GitOps)
	./infra/argocd/install.sh
monitoring: ## Lab 7 — kube-prometheus-stack, Pushgateway, Loki, Alloy
	./infra/monitoring/install.sh
external-secrets: ## Lab 8 — External Secrets Operator
	./infra/external-secrets/install.sh

# --- Raccourcis ---------------------------------------------------------------------
.PHONY: kfp-ui pipeline-image pf-monitoring
kfp-ui: ## Lab 2 — UI/API Kubeflow Pipelines sur http://localhost:8080 (arrière-plan)
	mkdir -p $(PF_LOG)
	pkill -f "port-forward svc/ml-pipeline-ui 8080" || true
	nohup kubectl --context $(KCTX) -n kubeflow port-forward svc/ml-pipeline-ui 8080:80 \
	  >$(PF_LOG)/kfp-ui.log 2>&1 &
	sleep 2 && echo "KFP UI -> http://localhost:8080"

pipeline-image: ## Lab 2+ — construit et pousse l'image du pipeline (tag de pipelines/components.py)
	test -f pipelines/Dockerfile || { echo "pipelines/Dockerfile absent (Lab 2, étape 2)"; exit 1; }
	IMAGE=$$(uv run --no-sync python -c "from pipelines.components import PIPELINE_IMAGE as i; print(i)")
	docker build -f pipelines/Dockerfile -t "$$IMAGE" .
	docker push "$$IMAGE"

pf-monitoring: ## Lab 7 — port-forwards Grafana, Prometheus, Alertmanager
	./infra/monitoring/port-forward.sh

# --- Vérifications de fin de lab ------------------------------------------------
check-m%: ## Vérifie l'état attendu en fin de lab (ex. make check-m3)
	./labs/m$*-*/check.sh

# --- Qualité ------------------------------------------------------------------
.PHONY: lint test check-sync pdf
lint: ## Lint Python (ruff) + YAML (yamllint)
	uv run ruff check .
	uv run ruff format --check .
	uv run yamllint -c .yamllint.yaml .

test: ## Tests unitaires
	uv run pytest -q

check-sync: ## Le code des énoncés est-il identique aux fichiers ? (SYNC_ARGS="--upto 3")
	uv run python tools/check_sync.py --tree . $(SYNC_ARGS)

pdf: ## Régénère les PDF des énoncés et du syllabus dans dist/pdf
	uv run --project tools/build_pdf python tools/build_pdf/build.py \
	  labs/*/README.md docs/syllabus.md -o dist/pdf

# --- Nettoyage ----------------------------------------------------------------
.PHONY: down
down: pf-stop ## Supprime le cluster (ATTENTION : données S3 et MLflow perdues)
	kind delete cluster --name $(KIND_CLUSTER_NAME)
	docker rm -f $(REGISTRY_NAME) || true
