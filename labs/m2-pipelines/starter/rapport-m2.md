# Rapport comparatif — Kubeflow Pipelines vs Airflow (Lab 2)

<!-- Copier ce modèle : cp labs/m2-pipelines/starter/rapport-m2.md reports/rapport-m2.md
     Cible : une page, environ 500 mots. Remplacez chaque TODO (make check-m2 les cherche). -->

**Binôme :** TODO · **Date :** TODO · **Machine :** TODO (CPU, RAM, OS) ·
**Dataset :** TODO (`name` de dataset.yaml)

## 1. Contexte

TODO (1 paragraphe) : quel pipeline, combien de steps, quel dataset, où tournent les steps,
quelle image, ce qui est partagé entre les deux orchestrateurs.

## 2. Résultats quantitatifs

| Mesure | KFP | Airflow |
|---|---|---|
| Installation de zéro (min) | TODO | TODO |
| Temps jusqu'au premier run réussi (min) | TODO | TODO |
| Durée d'un run complet (min) | TODO | TODO |
| Relance avec les mêmes paramètres (min) | TODO | TODO |
| Hot-reload : modifier un step et voir le résultat (min) | TODO | TODO |
| Lignes de code propres à l'orchestrateur | TODO | TODO |
| Mémoire consommée par l'outil (Go, `docker stats`) | TODO | TODO |

## 3. Analyse qualitative

### Developer experience

TODO

### Scaling

TODO

### Debugging

TODO

## 4. Recommandation

TODO (1 paragraphe) : dans quel contexte choisir KFP ? Airflow ? Sous quelles conditions ?

## 5. Limites de la comparaison

TODO (1 paragraphe) : ce que ce lab ne dit PAS.
