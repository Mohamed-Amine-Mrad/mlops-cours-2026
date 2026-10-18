# Rapport — Lab 7 : monitoring du modèle de scoring

> Copiez ce fichier dans `reports/rapport-m7.md` et remplacez chaque `TODO`.
> `make check-m7` refuse le rapport tant qu'il reste un `TODO`.

## 1. Architecture déployée

TODO : schéma (texte ou ASCII) des composants et des flux : API instrumentée (révisions
Knative), PodMonitor, Prometheus, Alertmanager → Slack, Grafana, Alloy → Loki, CronJob de
drift → Pushgateway, webhook de ré-entraînement (Lab 6), Argo CD.

## 2. Instrumentation et dashboard

TODO : les métriques exposées par l'API (nom, type, labels, question à laquelle elle
répond) ; deux captures du dashboard `scoring-overview` : trafic normal, puis pendant le drift.

## 3. Alertes

| Alerte | Condition (PromQL) | Sévérité | Runbook |
|---|---|---|---|
| TODO | TODO | TODO | TODO |

TODO : pourquoi une alerte de burn rate plutôt qu'un seuil brut sur le taux d'erreur ?

## 4. Démo drift → alerte → ré-entraînement

| Horodatage | Événement |
|---|---|
| TODO | début du trafic dérivé |
| TODO | job de drift : variables en dérive, PSI |
| TODO | alerte ScoringDataDrift Firing, notification reçue |
| TODO | webhook CT : run KFP lancé (identifiant) |

## 5. Analyse du canary

TODO : révisions comparées, garde-fous (tableau de `reports/m7/canary-analysis.md`),
décision, commande appliquée, état final (`kubectl get isvc scoring-model -n scoring`).

## 6. Améliorations à prévoir

TODO : au moins trois pistes (fenêtres de burn rate, ré-entraînement automatique, labels réels
retardés, dashboards par équipe, rétention des journaux, etc.).
