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
