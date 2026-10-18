# Décisions d'architecture (ADR)

Un **ADR** (*Architecture Decision Record*) est une note courte qui fige une décision
technique : le contexte, les options envisagées, le choix fait et ses conséquences. Dans six
mois (ou dans dix minutes, devant le jury), il répond à la question « pourquoi avez-vous fait
comme ça ? » mieux que n'importe quel souvenir.

## Règles du mini-projet

- Au moins **3 ADR** acceptés au rendu `final` : **au moins un sur le socle** et **un par
  extension** (chaque membre écrit celui de son extension).
- Un fichier par décision : `docs/adr/NNNN-titre-en-kebab-case.md`, numérotation continue à
  partir de `0001`, en partant du modèle [`0000-modele.md`](0000-modele.md).
- Un ADR passe par une PR relue par le partenaire, comme le code.
- On ne réécrit pas l'histoire : une décision abandonnée garde son fichier, avec le statut
  « remplacé par ADR-NNNN ».
- Écrire l'ADR **au moment** de la décision (statut « proposé »), pas la veille du rendu.

## Quand écrire un ADR ?

Dès qu'un choix a une alternative crédible et qu'il coûterait cher de revenir dessus. Idées
pour le socle (une seule suffit, mais choisissez une vraie décision) :

- la métrique de promotion et son seuil (`metrics` de `dataset.yaml`), compte tenu de la
  matrice de coûts ;
- le type de modèle retenu (régression logistique, forêt, gradient boosting) et pourquoi ;
- Kubeflow Pipelines ou Airflow pour l'orchestration ;
- la stratégie de déploiement (canary, pourcentage, critère de promotion ou de rollback) ;
- les seuils de drift et d'alerte (qui réveille-t-on, et pour quoi ?) ;
- le dataset : pourquoi rester sur le credit scoring ou pourquoi en changer.

## Index

| N° | Titre | Statut | Périmètre | Auteur |
|---|---|---|---|---|
| [0000](0000-modele.md) | Modèle d'ADR (non compté) | — | — | — |
| 0001 | [À compléter] | | | |
| 0002 | [À compléter] | | | |
| 0003 | [À compléter] | | | |
