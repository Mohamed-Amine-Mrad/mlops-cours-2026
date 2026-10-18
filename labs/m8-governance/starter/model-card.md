# Model Card — `scoring-model` vTODO (TODO : cas d'usage en une ligne)

Binôme : TODO · Dataset : TODO (`name` de dataset.yaml) · Date : TODO ·
Statut : TODO (prototype pédagogique ? en production ?)

> Format : Mitchell et al., *Model Cards for Model Reporting* (FAT* 2019), sections 1 à 9,
> complétées par la sécurité de la chaîne (section 10) et le cadre réglementaire (section 11).
> Tous les chiffres viennent de vos rapports : `reports/fairness_baseline.json`,
> `reports/fairness_mitigated.json`, `reports/shap_importance.json`, `reports/metrics.json`.
> Remplacez chaque TODO ; `make check-m8` refuse une Model Card qui en contient encore.

## 1. Détails du modèle

- **Nom / version** : TODO (version et alias dans le Registry, run MLflow).
- **Type** : TODO (Pipeline : prétraitement + estimateur, hyper-paramètres).
- **Sortie et décision** : TODO (que prédit le modèle ? quel seuil de décision, pourquoi ?).
- **Artefacts** : TODO (format du modèle, export ONNX, image Docker).
- **Traçabilité** : TODO (DVC, MLflow, Git).
- **Auteurs / contact / licence / citation des données** : TODO.

## 2. Usage prévu

- **Usage primaire** : TODO.
- **Utilisateurs visés** : TODO.
- **Usages interdits (hors périmètre)** : TODO (au moins trois).

## 3. Facteurs

- **Attributs sensibles** (section `sensitive` de dataset.yaml) : TODO.
- **Le modèle les utilise-t-il directement ?** TODO.
- **Proxies** (AUC du test de proxy, variables révélatrices) : TODO.
- **Facteurs d'environnement** : TODO.

## 4. Métriques

### Performance globale (jeu de test, seuil TODO)

TODO : tableau ROC AUC, rappel, précision, F1, accuracy, taux de refus, coût métier, et une
référence naïve (« tout refuser », « tout accepter »).

### Performance par groupe

TODO : un tableau par attribut sensible (n, taux réel, taux de refus avec IC 95 %, TPR,
FPR, coût par demande) — généré par la commande de l'étape 6.2.

### Indicateurs d'équité

TODO : écart de parité, ratio d'acceptation (règle des 4/5), écart equalized odds.

## 5. Données d'évaluation

TODO : taille, mode de tirage, effectifs par groupe, limites statistiques.

## 6. Données d'entraînement

TODO : source, période, licence, taille, représentativité, qualité des attributs sensibles.

## 7. Analyse quantitative

TODO : disparités observées et interprétation ; tableau des stratégies d'atténuation
(coût, écarts, attribut utilisé en production) et décision retenue ; résultats SHAP
(variables les plus influentes, rang des attributs sensibles, cas locaux marquants).

## 8. Considérations éthiques

TODO : biais historiques, discrimination directe ou indirecte, coût social des erreurs.

## 9. Mises en garde et recommandations

TODO : ce qu'il ne faut PAS faire avec ce modèle, et ce qu'il faudrait faire avant tout
usage réel.

## 10. Sécurité de la chaîne

TODO : image durcie et rapports Trivy, ModelScan, RBAC, gestion des secrets.

## 11. Cadre réglementaire

TODO : classification AI Act (et échéance applicable), RGPD art. 22 ; renvoi vers
`reports/compliance-ai-act.md`.
