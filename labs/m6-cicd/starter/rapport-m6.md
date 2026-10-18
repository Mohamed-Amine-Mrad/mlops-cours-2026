# Rapport — Lab 6 : CI/CD/CT de bout en bout

Binôme : TODO · Fork : `TODO/mlops-cours-2026` · Dataset : TODO (`name` de dataset.yaml) ·
Image en prod à la fin du lab : `TODO` · `@champion` : v TODO

## 1. Architecture

TODO : schéma (texte ou image) des composants et des flux : GitHub Actions, GHCR, Git
(overlays), Argo CD, KServe staging/prod, Evidently, webhook CT, KFP, MLflow. Indiquer
pour chaque flèche qui pousse et qui tire.

## 2. Temps du cycle

Démo de l'étape 9 (horodatages : journal du webhook, `git log --format='%ci %s'`, onglet
Actions, UI KFP).

| Étape | Début | Fin | Durée |
|---|---|---|---|
| Dérive détectée → run KFP lancé | TODO | TODO | TODO |
| Pipeline CT (ingest → gate) | TODO | TODO | TODO |
| Commit du modèle → image publiée (CI) | TODO | TODO | TODO |
| Image publiée → staging servi | TODO | TODO | TODO |
| Canary 10 % → promotion 100 % | TODO | TODO | TODO |
| **Cycle complet** | TODO | TODO | **TODO** |

Quelle étape domine, et comment la raccourcir ? TODO

## 3. Gates et décisions

- Gate de promotion (KFP, `promotion-gate`) : métrique et coût du challenger et du champion,
  décision : TODO
- Canary : part, analyse, décision (promotion ou retour arrière) : TODO

## 4. Points d'attention

TODO : sécurité du webhook (jeton, exposition), gate humaine ou automatique sur le CT,
retour arrière (trafic, @champion, Git), secrets (où sont-ils ? qui les voit ?).

## 5. Différences avec la prod

TODO : ce qu'il faudrait ajouter ou changer (secrets managés, bot dans le cluster avec un
jeton limité, PR plutôt que commit direct, environnements séparés, DR, audit, métriques
métier, données réellement récentes et étiquetées…).

## 6. Captures d'écran

TODO : Argo CD (Applications Synced/Healthy), run CT réussi dans KFP (rapport de la gate),
onglet Actions (run vert), `kubectl get isvc -n scoring` pendant le canary.
