# Soutenance — déroulé et checklist de préparation

## Déroulé (25 minutes par binôme)

| Temps | Durée | Qui | Contenu | Barème concerné |
|---|---|---|---|---|
| 0:00 | 5 min | Binôme | **Démo du socle de bout en bout** : une modification (code, données ou paramètre) traverse la chaîne jusqu'au modèle servi, puis on le voit dans le monitoring | Socle (12, commun) |
| 0:05 | 5 min | Membre 1 | **Extension 1** : objectif, démonstration en direct, tests, ADR | Extension (12, individuel) |
| 0:10 | 5 min | Membre 2 | **Extension 2** : même format | Extension (12, individuel) |
| 0:15 | 4 min | Membre 1 | **Défi en direct** : un incident tiré au sort est provoqué sur le socle ; vous diagnostiquez et corrigez à voix haute | Défi et questions (10, individuel) |
| 0:19 | 4 min | Membre 2 | **Défi en direct** : un autre incident, même format | Défi et questions (10, individuel) |
| 0:23 | 2 min | Binôme | **Questions** du jury (souvent sur une ADR, le rapport ou l'historique Git) | Défi et questions (10, individuel) |

Règles du défi :

- l'incident est tiré au sort parmi six familles : données invalides, drift, service qui ne
  répond plus, déploiement bloqué, modèle dégradé, secret manquant ;
- le partenaire ne souffle pas (il peut avoir son propre défi juste après) ;
- on évalue la **démarche** : formuler une hypothèse, l'outil choisi pour la vérifier, la
  lecture des signaux, la correction ou, à défaut, la correction que vous appliqueriez. Un
  incident non résolu en 4 minutes avec un diagnostic juste vaut plus qu'une correction au
  hasard qui tombe en marche.

**Plan B** (cluster en panne le jour J) : la vidéo de démo de 3 minutes remplace la démo du
socle ; le défi se fait sur le cluster de l'enseignant, avec le même repo, reconstruit par
`dvc repro` (le remote DVC de votre cluster n'est pas accessible depuis un autre poste).

## Checklist de préparation

### Dès la S8 (déclaration des extensions)

| ☐ | Action |
|---|---|
| ☐ | Chaque membre a déclaré son extension (issue sur le repo du cours) et l'a fait accepter |
| ☐ | Une branche `ext/<nom>` par membre, ADR « proposé » ouvert |
| ☐ | Le binôme s'est entraîné au moins une fois à « casser » le socle de l'autre (voir l'énoncé du mini-projet, section « Préparer le défi ») |

### J-7

| ☐ | Action |
|---|---|
| ☐ | Les deux PR `ext/*` sont fusionnées dans `main` après relecture |
| ☐ | `make check-m10` lancé sur les **deux** postes ; écarts corrigés ou expliqués dans le rapport |
| ☐ | Répétition chronométrée complète (25 min) avec un autre binôme comme jury |
| ☐ | Reproductibilité testée sur une machine (ou un compte) qui n'a jamais vu le projet : `git clone`, `make up`, `uv sync`, `dvc repro` puis `dvc push`, pipeline (`dvc pull` ne marche que sur le cluster qui a fait le `dvc push`) |

### J-2 (48 h avant) — tag `final`

| ☐ | Action |
|---|---|
| ☐ | `docs/rapport.pdf` (10 pages max), slides (`docs/slides.pdf`), lien de la vidéo de démo (3 min) dans le README |
| ☐ | `docs/journal.md` à jour, au moins 3 ADR acceptés, dataset card et model card relues |
| ☐ | `git tag final && git push origin final` (vérifier sur GitHub que le tag est visible) |
| ☐ | Plus aucun commit sur `main` après le tag (le jury évalue le tag) |

### Veille et jour J

| ☐ | Action |
|---|---|
| ☐ | Cluster démarré **avant** d'entrer dans la salle : `make pf`, modèle servi, Grafana ouvert |
| ☐ | Terminaux préparés (taille de police lisible, historique propre), onglets ouverts dans l'ordre de la démo |
| ☐ | Une requête de prédiction prête à copier-coller ; un jeu de données « modifié » prêt pour la démo |
| ☐ | Les commandes de diagnostic sous la main : `kubectl get/describe/logs/events`, `make check-mX`, MLflow, Grafana, Argo CD |
| ☐ | Batterie et réseau vérifiés ; vidéo de démo téléchargée en local (plan B) |
