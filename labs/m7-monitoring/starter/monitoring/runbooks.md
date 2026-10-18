# Runbooks — service de scoring

Une section par alerte de `monitoring/scoring-alerts.yaml`. Chaque section répond à trois
questions : qu'est-ce que ça veut dire, comment confirmer, que faire. Les commandes supposent
les port-forwards du Lab 7 (Prometheus :9090, Grafana :3000) et `make pf`.

## ScoringHighLatency

**Signification** : la latence P95 de `/predict` dépasse 200 ms depuis 5 minutes.

**Confirmer** : dashboard `scoring-overview`, rangée « SLO », panneau P95 ; comparer avec le
RPS et le CPU des pods (rangée « Infra »).

```promql
histogram_quantile(0.95, sum by (revision, le) (rate(ml_inference_latency_seconds_bucket{namespace="scoring"}[5m])))
```

**Agir** :
- Une seule révision lente (canary) : `uv run python monitoring/canary_analysis.py`, puis
  rollback si la décision le demande.
- Toutes les révisions lentes et CPU saturé : vérifier que l'autoscaler a ajouté des pods
  (`kubectl get kpa -n scoring`), augmenter `maxReplicas` ou la limite CPU par un commit.
- Lots très gros (`/predict` avec des centaines d'instances) : voir le client, `MAX_BATCH`.

## ScoringErrorBudgetBurn

**Signification** : le budget d'erreur du SLO de disponibilité (99,5 % de requêtes sans 5xx)
se consomme 14,4 fois (fenêtre 1 h) ou 6 fois (fenêtre 6 h) trop vite. Critique.

**Confirmer** :

```promql
sum by (revision, code) (rate(http_requests_total{namespace="scoring",handler="/predict"}[5m]))
```

Logs dans Grafana (Explore, source Loki) :
`{namespace="scoring", container="kserve-container"} |= "Error"`.

**Agir** :
- Erreurs sur la seule révision canary : rollback immédiat
  (`uv run python -m pipelines.gitops rollback --push`).
- Erreurs partout après un déploiement : revenir à l'image précédente par un commit.
- Pods qui redémarrent (`kubectl get pods -n scoring`) : `kubectl describe pod`, OOMKilled ?

## ScoringDataDrift

**Signification** : le job Evidently (CronJob `scoring-drift`) mesure, sur la dernière heure
de demandes, une distribution d'au moins une variable trop éloignée des données
d'entraînement (PSI > 0,25). La valeur de l'alerte est la part de variables en dérive.

**Confirmer** :
- Dashboard, rangée « Drift » : quelles variables, depuis quand.
- Rapport HTML du dernier run : `aws-lab s3 ls s3://monitoring/drift-reports/`.
- Logs du job : `kubectl logs -n monitoring -l job-name=<dernier job>`.

**Agir** :
- Vérifier d'abord la qualité des données (bug d'un client, changement d'unité) : un drift
  n'est pas toujours un changement de population.
- Changement réel de population : déclencher le ré-entraînement continu (Lab 6), puis
  suivre le canary du nouveau modèle (`monitoring/canary_analysis.py`).
- Faux positif répété : trop peu de demandes (`ml_drift_current_rows`) ou seuil trop bas.

## ScoringPositiveRateShift

**Signification** : le taux de décisions positives (ici : refus de crédit) des 5 dernières
minutes s'écarte de plus de 10 points de celui des 6 dernières heures.

**Confirmer** : dashboard, rangée « Modèle » : taux de refus global et par groupe sensible.
Le score moyen a-t-il bougé aussi ? Si oui : changement des demandes (voir le drift) ; si non :
changement de seuil ou de version (comparer `ml_model_info` par révision).

**Agir** : drift → voir `ScoringDataDrift` ; nouvelle version → analyse du canary ; écart
concentré sur un groupe sensible → prévenir le responsable conformité (Lab 8).

## ScoringNoReplicaAvailable

**Signification** : aucun pod de l'InferenceService `scoring-model` n'est prêt en production.

**Confirmer** : `kubectl get isvc,revisions,pods -n scoring` ; état de l'application Argo CD
`scoring-prod`.

**Agir** : `kubectl describe pod` (image introuvable, sonde en échec, OOMKilled) ; corriger par
un commit (image, ressources) et laisser Argo CD synchroniser.

## ScoringDriftJobStale

**Signification** : le job de drift n'a rien publié dans le Pushgateway depuis 45 minutes :
le drift n'est plus surveillé.

**Confirmer** : `kubectl get cronjob,jobs -n monitoring` ; logs du dernier pod du job.

**Agir** : causes fréquentes : image absente du registry, Secret `s3-credentials` manquant
dans `monitoring`, Loki ou Pushgateway injoignable, ConfigMap `scoring-drift-reference`
absente. Relancer à la main : `kubectl create job --from=cronjob/scoring-drift manual-$(date +%s) -n monitoring`.
