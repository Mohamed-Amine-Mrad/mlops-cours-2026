<!--
Titre de la PR : commencez par le nom de la branche, ex. « lab/m5-serving : InferenceService
canary » ou « ext/batch-scoring : job de scoring planifié ». Pour une extension, ce préfixe
`ext/<nom>` est OBLIGATOIRE dans le titre : il reste dans l'historique même en « squash merge »
et c'est ce que lit le pré-contrôle de rendu (make check-m10).
La PR est relue et approuvée par le partenaire avant la fusion dans main.
-->

## Quoi et pourquoi

<!-- 2 à 5 lignes : ce que change la PR et la raison. Lien vers l'issue ou le lab. -->

## Type

- [ ] Lab du socle (`lab/mX-…`)
- [ ] Extension (`ext/<nom>`)
- [ ] Correctif / documentation

## Comment vérifier

<!-- Commandes que le relecteur lance, et ce qu'il doit voir. -->

```bash
make check-mX
```

## Checklist

- [ ] `make lint` et `make test` passent en local
- [ ] Le `make check-mX` du lab concerné est vert (ou l'écart est expliqué ci-dessus)
- [ ] Aucun nom de colonne, de cible ou de seuil en dur : tout vient de `dataset.yaml`
- [ ] Aucun secret ni donnée brute commité (`.env`, `.dvc/config.local`, `data/raw/`)
- [ ] `docs/journal.md` mis à jour ; ADR ajouté si une décision a été prise
- [ ] Extension : tests ajoutés, ADR écrit, page du rapport amorcée

## Relecture

<!-- Le relecteur (le partenaire) résume ce qu'il a vérifié et pose ses questions ici
ou en commentaires de ligne. Une approbation sans commentaire ne compte pas comme relecture. -->
