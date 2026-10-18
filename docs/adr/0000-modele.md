# ADR-0000 — Titre court de la décision, à l'infinitif

<!--
Modèle d'Architecture Decision Record (inspiré de M. Nygard, 2011, et du format MADR).
Copier ce fichier en docs/adr/NNNN-titre-en-kebab-case.md (NNNN = numéro suivant, 0001, 0002…),
remplacer chaque [À compléter], supprimer ces commentaires. Une décision par fichier,
une page maximum. Un ADR accepté ne se réécrit pas : s'il est remis en cause, on en écrit
un nouveau qui le remplace (« Statut : remplacé par ADR-0007 »).
Ce fichier 0000 n'est pas compté par le pré-contrôle (make check-m10).
-->

- **Statut :** [À compléter : proposé | accepté | remplacé par ADR-NNNN | abandonné]
- **Date :** [À compléter : AAAA-MM-JJ]
- **Auteur(s) :** [À compléter : @pseudo-github]
- **Relu par :** [À compléter : @pseudo-github du partenaire]
- **Périmètre :** [À compléter : socle (Lab N) | extension ext/<nom>]
- **Liens :** [À compléter : PR #N, issue #N, ADR liés]

## Contexte

[À compléter : le problème à résoudre et les contraintes qui pèsent sur la décision, en 3 à 8
lignes. Contraintes typiques : ressources du poste (RAM, pas de GPU), délai, compétences du
binôme, exigences du cas d'usage (coût d'un faux négatif, explicabilité, latence), outils
imposés par le socle.]

## Options envisagées

| Option | Avantages | Inconvénients |
|---|---|---|
| [À compléter : option A] | | |
| [À compléter : option B] | | |
| [À compléter : ne rien faire / statu quo] | | |

## Décision

[À compléter : l'option retenue, formulée de façon affirmative (« Nous utilisons… »), et la
raison principale. Si un chiffre a guidé le choix (latence mesurée, taille d'image, ROC AUC,
coût métier), le donner avec la façon dont il a été obtenu (run MLflow, rapport, commande).]

## Conséquences

- **Positives :** [À compléter]
- **Négatives / dette acceptée :** [À compléter : ce qu'on s'interdit ou ce qu'il faudra
  reprendre, et à quel signal on rouvrira la décision]
- **Vérification :** [À compléter : comment on sait que la décision tient — test, check,
  alerte, métrique suivie]
