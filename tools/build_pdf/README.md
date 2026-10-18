# build_pdf — énoncés Markdown → PDF à la charte du cours

Régénère les PDF des labs (`labs/m*/README.md`) et du syllabus (`docs/syllabus.md`) avec la
mise en page des PDF historiques du cours : couverture bleu nuit pleine page, en-tête et pied
de page, bandeaux d'étape, encadrés colorés, blocs de code, tables zébrées, signets PDF.

## Usage

Depuis la racine du repo (projet uv isolé, indépendant du `pyproject.toml` du cours) :

```bash
uv run --project tools/build_pdf python tools/build_pdf/build.py labs/*/README.md -o dist/pdf
uv run --project tools/build_pdf python tools/build_pdf/build.py docs/syllabus.md -o dist/pdf
```

Sorties : `MLOps_Module{N}_Lab.pdf` pour un lab (N = champ `module`), `MLOps_Syllabus.pdf` pour
un document `doc_type: syllabus`. Le script affiche le nombre de pages de chaque PDF ; il
signale sur la sortie d'erreur les caractères qu'aucune police embarquée ne sait dessiner
(remplacés par `□`). Code retour non nul si un fichier est introuvable ou en erreur.

## Format d'entrée

Celui de `CONVENTIONS.md` §6 :

| Markdown | Rendu |
|---|---|
| front matter `module`, `lab`, `title`, `subtitle`, `running_title`, `duree`, `format`, `prerequis`, `livrable`, `stack` | couverture (kicker « MODULE N · LAB N », champs Durée / Format / Prérequis / Livrable / Stack), en-tête « MLOps · Module N · *running_title* », métadonnées PDF |
| `# Lab N — Titre` + ligne `*sous-titre*` | grand titre de la page 2 |
| `## Section` | titre de section (après la dernière étape : grand titre ; les annexes ouvrent une nouvelle page, la première section finale aussi s'il reste moins d'un tiers de page) |
| `## Étape N/T — Titre (durée)` | bandeau d'étape « ÉTAPE N / T », titre, durée à droite |
| `### N.M Sous-section` | sous-titre teal |
| `> [!NOTE]` / `[!TIP]` / `[!IMPORTANT]` / `[!WARNING]` / `[!CAUTION]` + `**Titre**` | encadré bleu / bleu-teal / vert / jaune / rouge, barre latérale |
| `> **Sortie attendue :** …` | encadré vert pâle à barre verte (un bloc de code qui suit immédiatement un « Sortie attendue : » vide y est intégré) |
| blocs ```` ```lang ```` | bloc de code gris bordé, coloration sobre (Pygments) |
| tables GFM, listes (`-`, `1.`, `- [ ]`), **gras**, *italique*, `code`, liens, `---` | rendus natifs ; URL nues cliquables |

Champs optionnels reconnus dans tout document : `cover_kicker`, `cover_fields`
(liste de paires `[libellé, valeur]`), `footer_left`, `cover_footer_title`,
`cover_footer_text`. Le syllabus (`doc_type: syllabus`) les utilise tous ; chaque `#` y ouvre
une nouvelle page, `## Module N — Titre` devient un bandeau de module (pastille colorée par
bloc) et une table d'une seule ligne placée juste après devient la fiche « Thème / Volume / … ».

## Mise en page robuste

- Code : jamais de débordement. La police descend de 8 à 7,2 pt si cela suffit à faire tenir
  la ligne la plus longue ; sinon les lignes trop longues sont coupées (de préférence sur un
  espace, puis `,`, puis `/ - . =`) et la suite est préfixée d'un `↪` teal, alignée sur
  l'indentation. Les blocs se scindent entre les pages (jamais une ligne seule).
- Tables : largeur pleine, colonnes au prorata du volume de texte (bornées par le mot le plus
  long et par la largeur naturelle), police réduite à partir de 5 colonnes, retour à la ligne
  dans les cellules, en-tête répété sur chaque page, pas de coupure laissant moins de 3 lignes
  avant ou 2 lignes après. Colonne `#` en teal gras, colonnes courtes (durées, points, `☐`)
  centrées, ligne « Total » surlignée.
- Encadrés : scindables sur plusieurs pages. Titres jamais orphelins en bas de page (place
  exigée pour le titre + le début du bloc suivant). Paragraphes justifiés sauf les lignes qui
  seraient trop étirées (avant un long `code` ou une URL).
- Signets PDF (sommaire latéral ouvert à l'ouverture) : sections, étapes, sous-sections ;
  ancres internes `[texte](#titre)` façon GitHub ; métadonnées titre / auteur « Cours MLOps » /
  sujet / mots-clés, langue `fr-FR`.

## Polices (embarquées dans `fonts/`, sous-ensembles intégrés aux PDF)

| Rôle | Police | Licence |
|---|---|---|
| Texte (métriques identiques à Helvetica/Arial) | Liberation Sans 2.1.5 (Regular, Bold, Italic, BoldItalic) | SIL OFL 1.1 — `fonts/LICENSE-Liberation.txt` |
| Code | DejaVu Sans Mono 2.37 (Regular, Bold, Oblique) | Bitstream Vera + domaine public — `fonts/LICENSE-DejaVu.txt` |
| Repli symboles (☐ ★ ✓ ✔ ✘ ↪ ⚠ ≪ ∈ …) | DejaVu Sans 2.37 (Regular, Bold) | idem |

Les emoji (aucune police vectorielle libre légère ne les couvre) sont substitués par un glyphe
DejaVu coloré : ✅ → ✔ vert, ❌ → ✘ rouge, 🎉 → ★ teal, 🚀 → ➜ teal, ⚠️ → ⚠ ambre, etc.
(table `EMOJI_SUBST` dans `build.py`).
