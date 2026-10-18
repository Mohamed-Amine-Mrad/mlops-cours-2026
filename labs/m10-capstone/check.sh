#!/usr/bin/env bash
# shellcheck disable=SC2329  # fonctions de test appelées indirectement via check()
# =============================================================================
# Pré-contrôle de rendu du mini-projet (Module 10)
#
# Lancer depuis la racine du repo du binôme :
#   make check-m10                                   # jalon « final » (tout)
#   make check-m10 JALON=j1                          # ce qui est attendu au jalon J1
#   ./labs/m10-capstone/check.sh --jalon j1          # idem, sans make
#   ./labs/m10-capstone/check.sh --sans-cluster      # repo seul (docs, Git, tags)
#   ./labs/m10-capstone/check.sh --gh                # + relectures des PR ext/* (gh CLI)
#
# Utilisable par l'enseignant sur le poste d'un étudiant (cluster démarré, make pf)
# ou sur un simple clone (--sans-cluster). Il ne modifie rien : il agrège les
# vérifications des labs (make check-m0 … check-m8, sans s'arrêter au premier échec)
# et contrôle les livrables du mini-projet (dataset.yaml, journal, ADR, cards,
# tags de jalons, extensions fusionnées, README).
#
# Variables facultatives :
#   CHECK_TIMEOUT=900     délai maximal (s) par « make check-mX »
#   JOURNAL_MIN=N         nombre minimal d'entrées datées du journal (défaut selon le jalon)
#   EXT_MIN=2             nombre d'extensions fusionnées attendues (1 si étudiant seul)
#   AUTEURS_MIN=2         nombre minimal d'auteurs distincts dans l'historique
#   SOUTENANCE="2026-12-15 08:00"   vérifie que le tag final précède la soutenance de 48 h
#   LOG_DIR=…             dossier des journaux des checks (défaut /tmp/mlops-precontrole/…)
#
# Code retour = nombre de vérifications en échec (0 = rendu complet). Les
# avertissements (⚠️) signalent un point à regarder sans compter comme échec.
# =============================================================================
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/../.." || exit 1

JALON=${JALON:-final}
AVEC_CLUSTER=1
AVEC_GH=0
usage() { sed -n '4,28p' "$SELF" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --jalon)
      JALON=${2:-}
      shift 2 || { usage; exit 64; }
      ;;
    --jalon=*)
      JALON=${1#--jalon=}
      shift
      ;;
    --sans-cluster) AVEC_CLUSTER=0; shift ;;
    --gh) AVEC_GH=1; shift ;;
    -h | --help | --aide) usage; exit 0 ;;
    *) echo "Option inconnue : $1"; usage; exit 64 ;;
  esac
done
case "$JALON" in
  j0) LABS="0 1"; TAGS="j0"; ADR_MIN=0; JOURNAL_DEF=2 ;;
  j1) LABS="0 1 2 3 4 5"; TAGS="j0 j1"; ADR_MIN=1; JOURNAL_DEF=4 ;;
  j2) LABS="0 1 2 3 4 5 6 7 8"; TAGS="j0 j1 j2"; ADR_MIN=3; JOURNAL_DEF=6 ;;
  final) LABS="0 1 2 3 4 5 6 7 8"; TAGS="j0 j1 j2 final"; ADR_MIN=3; JOURNAL_DEF=8 ;;
  *) echo "Jalon inconnu : '$JALON' (j0, j1, j2 ou final)"; exit 64 ;;
esac
JOURNAL_MIN=${JOURNAL_MIN:-$JOURNAL_DEF}
EXT_MIN=${EXT_MIN:-2}
AUTEURS_MIN=${AUTEURS_MIN:-2}
CHECK_TIMEOUT=${CHECK_TIMEOUT:-900}
LOG_DIR=${LOG_DIR:-/tmp/mlops-precontrole/$(basename "$PWD")-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$LOG_DIR"

FAILS=0
TOTAL=0
WARNS=0
SEC_NAMES=()
SEC_OK=()
SEC_TOT=()
SEC=-1

# Exécute une commande avec un délai maximal (timeout absent sur macOS sans coreutils).
t() {
  local secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else "$@"; fi
}

# Python du repo (venv créé par uv sync) si disponible, sinon python3 du système.
py() {
  if [ -x .venv/bin/python ]; then
    t 60 .venv/bin/python "$@"
  elif command -v uv >/dev/null 2>&1; then
    t 60 uv run --no-sync --quiet python "$@"
  else
    t 60 python3 "$@"
  fi
}

section() {
  SEC=$((SEC + 1))
  SEC_NAMES[SEC]=$1
  SEC_OK[SEC]=0
  SEC_TOT[SEC]=0
  echo
  echo "── $1 ──"
}

record() { # record ok|ko
  TOTAL=$((TOTAL + 1))
  SEC_TOT[SEC]=$((SEC_TOT[SEC] + 1))
  if [ "$1" = ok ]; then
    SEC_OK[SEC]=$((SEC_OK[SEC] + 1))
  else
    FAILS=$((FAILS + 1))
  fi
}

# check "libellé" "indice en cas d'échec" commande [args...]
# La commande peut écrire un détail sur la sortie standard (affiché en retrait).
check() {
  local label=$1 hint=$2 out rc
  shift 2
  out=$("$@" 2>&1)
  rc=$?
  if [ $rc -eq 0 ]; then
    echo "✅ ${label}"
    record ok
  else
    echo "❌ ${label}  →  ${hint}"
    record ko
  fi
  [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/     /'
  return 0
}

warn() {
  echo "⚠️  $*"
  WARNS=$((WARNS + 1))
}
info() { echo "ℹ️  $*"; }

# Lignes non vides, hors commentaires HTML d'une ligne.
content_lines() { grep -v '^[[:space:]]*$' "$1" | grep -vc '^[[:space:]]*<!--.*-->[[:space:]]*$'; }
placeholders() { grep -c '\[À compléter' "$1"; }

# =============================================================================
echo "Pré-contrôle du mini-projet — jalon « ${JALON} » — $(basename "$PWD")"
echo "Commit : $(git rev-parse --short HEAD 2>/dev/null || echo '?')" \
  "($(git log -1 --format=%cd --date=format:'%Y-%m-%d %H:%M' 2>/dev/null || echo '?'))" \
  " · journaux : ${LOG_DIR}"

# --- 1. Socle : vérifications automatiques des labs ---------------------------
section "Socle — make check-m* (labs ${LABS// /, })"
if [ "$AVEC_CLUSTER" -eq 0 ]; then
  info "--sans-cluster : vérifications des labs non lancées (elles ont besoin du cluster)."
else
  [ -f .env ] || warn ".env absent : les checks utiliseront .env.example (cp .env.example .env)"
  for m in $LABS; do
    # shellcheck disable=SC2086
    set -- labs/m${m}-*/check.sh
    if [ ! -f "$1" ]; then
      echo "❌ make check-m${m}  →  labs/m${m}-*/check.sh absent : git fetch upstream && git merge upstream/main"
      record ko
      continue
    fi
    log="$LOG_DIR/check-m${m}.log"
    t "$CHECK_TIMEOUT" make --no-print-directory "check-m${m}" >"$log" 2>&1
    rc=$?
    ok=$(grep -c '^✅' "$log")
    ko=$(grep -c '^❌' "$log")
    detail="${ok}/$((ok + ko))"
    if [ $rc -eq 0 ]; then
      echo "✅ make check-m${m} — ${detail}"
      record ok
    else
      [ $rc -eq 124 ] && detail="${detail}, délai de ${CHECK_TIMEOUT} s dépassé"
      echo "❌ make check-m${m} — ${detail}  →  détail : ${log}"
      grep '^❌' "$log" | head -5 | sed 's/^/     /'
      record ko
    fi
  done
fi

# --- 2. Contrat de données : dataset.yaml --------------------------------------
section "Contrat de données — dataset.yaml"
DATASET_INFO=$(
  py - <<'EOF' 2>&1
from src.dataset_config import load_config

cfg = load_config()
src = cfg.raw.get("source") or {}
problems = []
if not str(src.get("license", "")).strip():
    problems.append("source.license vide (licence ouverte obligatoire)")
if not str(src.get("url", "")).strip():
    problems.append("source.url vide")
if not cfg.sensitive:
    problems.append("aucun attribut sensible déclaré (sensitive)")
if len(cfg.features) < 2:
    problems.append("moins de 2 features")
print(f"NAME={cfg.name}")
print(f"RAW={cfg.raw_path}")
print(f"TARGET={cfg.target}")
for p in problems:
    print(f"PROBLEM={p}")
EOF
)
DS_NAME=$(printf '%s\n' "$DATASET_INFO" | sed -n 's/^NAME=//p')
DS_RAW=$(printf '%s\n' "$DATASET_INFO" | sed -n 's/^RAW=//p')
DS_TARGET=$(printf '%s\n' "$DATASET_INFO" | sed -n 's/^TARGET=//p')
dataset_valid() {
  [ -f dataset.yaml ] || { echo "dataset.yaml absent"; return 1; }
  if [ -z "$DS_NAME" ]; then
    if printf '%s\n' "$DATASET_INFO" | grep -q 'ModuleNotFoundError'; then
      echo "environnement Python du projet absent : lancer « uv sync » puis relancer"
    else
      printf '%s\n' "$DATASET_INFO" | tail -3
    fi
    return 1
  fi
  if printf '%s\n' "$DATASET_INFO" | grep -q '^PROBLEM='; then
    printf '%s\n' "$DATASET_INFO" | sed -n 's/^PROBLEM=/- /p'
    return 1
  fi
  echo "dataset « ${DS_NAME} », cible « ${DS_TARGET} »"
}
check "dataset.yaml présent et valide (src.dataset_config.load_config)" \
  "corriger dataset.yaml (mêmes clés que le modèle du cours) ; uv sync" dataset_valid

data_ok() {
  py - "$DS_RAW" <<'EOF'
import os
import sys

import pandas as pd

from src.dataset_config import load_config

path = sys.argv[1]
cfg = load_config()
size = os.path.getsize(path)
df = pd.read_csv(path)
cfg.validate_columns(df)
errors = []
if not 1_000 <= len(df) <= 100_000:
    errors.append(f"{len(df)} lignes (attendu : 1 000 à 100 000)")
if size >= 50 * 1024**2:
    errors.append(f"{size / 1024**2:.0f} Mo (attendu : < 50 Mo)")
classes = df[cfg.target].astype(str).value_counts()
if len(classes) < 2 or str(cfg.positive_class) not in classes.index:
    errors.append(f"cible : classes {list(classes.index)}, classe positive absente")
rate = (df[cfg.target].astype(str) == str(cfg.positive_class)).mean()
print(f"{len(df)} lignes, {len(cfg.features)} features, {size / 1024:.0f} Ko, "
      f"classe positive « {cfg.positive_class} » = {rate:.0%}")
for e in errors:
    print("- " + e)
sys.exit(1 if errors else 0)
EOF
}
if [ -z "$DS_RAW" ]; then
  :
elif [ -f "$DS_RAW" ]; then
  check "Données brutes conformes (${DS_RAW} : colonnes, 1 000-100 000 lignes, < 50 Mo)" \
    "dvc pull (ou dvc repro sur un cluster neuf) ; vérifier dataset.yaml et src/download.py" data_ok
elif [ "$AVEC_CLUSTER" -eq 1 ]; then
  check "Données brutes présentes (${DS_RAW})" "make pf ; dvc pull, ou dvc repro sur un cluster neuf" false
else
  info "${DS_RAW} absent (normal sur un clone sans accès au remote DVC)."
fi
if [ -n "$DS_NAME" ] && [ "$DS_NAME" != "german-credit" ]; then
  info "Dataset libre « ${DS_NAME} » : vérifier l'issue de validation (label validé) sur le repo du cours."
fi
if [ -n "$DS_TARGET" ]; then
  hard=$(git grep -l -E "[\"']${DS_TARGET}[\"']" -- \
    src pipelines dags serving k8s monitoring governance tests packaging features 2>/dev/null |
    grep -v -E '^src/(download|dataset_config)\.py$' | head -10)
  if [ -n "$hard" ]; then
    warn "Nom de la cible « ${DS_TARGET} » écrit en dur (doit venir de dataset.yaml) :"
    printf '%s\n' "$hard" | sed 's/^/     /'
  fi
fi

# --- 3. Dépôt et reproductibilité ------------------------------------------------
section "Dépôt et reproductibilité"
dvc_ok() {
  local missing=""
  for f in dvc.yaml dvc.lock .dvc/config; do
    git ls-files --error-unmatch "$f" >/dev/null 2>&1 || missing="$missing $f"
  done
  [ -z "$missing" ] || { echo "non commités :$missing"; return 1; }
  grep -qE '^[[:space:]]*remote[[:space:]]*=' .dvc/config || {
    echo "aucun remote DVC par défaut dans .dvc/config"
    return 1
  }
}
check "DVC : dvc.yaml, dvc.lock et .dvc/config (remote par défaut) commités" \
  "Lab 1 : dvc remote add -d storage … ; dvc repro ; git add dvc.lock" dvc_ok
no_secrets() {
  local bad
  bad=$(git ls-files -- .env .dvc/config.local '*.pem' '*.key' 'kubeconfig*' 2>/dev/null)
  if [ -n "$DS_RAW" ]; then
    bad="$bad$(git ls-files -- "$DS_RAW" 2>/dev/null)"
  fi
  [ -z "$bad" ] || { echo "$bad"; return 1; }
}
check "Aucun secret ni donnée brute dans Git (.env, .dvc/config.local, ${DS_RAW:-data/raw})" \
  "git rm --cached <fichier> ; ajouter au .gitignore ; changer le secret exposé" no_secrets
readme_ok() {
  [ -f README.md ] || { echo "README.md absent"; return 1; }
  local missing="" spec name re
  for spec in \
    "Démarrage rapide|d(é|e)marrage|quick ?start" \
    "Cas d'usage|cas d.usage|contexte" \
    "Architecture|architecture" \
    "Données|donn(é|e)es|dataset" \
    "Modèle et résultats|mod(è|e)le|r(é|e)sultats" \
    "Extensions|extension" \
    "Équipe|(É|é|E|e)quipe|bin(ô|o)me|auteur" \
    "Démo|d(é|e)mo|vid(é|e)o"; do
    name=${spec%%|*}
    re=${spec#*|}
    grep -qiE "^#{1,3} .*(${re})" README.md || missing="$missing, $name"
  done
  grep -q 'make up' README.md || missing="$missing, commande « make up »"
  grep -q 'dvc repro' README.md || missing="$missing, commande « dvc repro »"
  [ -z "$missing" ] || { echo "manque : ${missing#, }"; return 1; }
}
check "README du projet : sections et démarrage rapide (make up, dvc repro)" \
  "voir labs/m10-capstone/README.md, « README du projet »" readme_ok
authors=$(git log --format='%aN <%aE>' HEAD 2>/dev/null | sort | uniq -c | sort -rn)
authors_ok() {
  local n
  n=$(printf '%s\n' "$authors" | grep -c .)
  printf '%s\n' "$authors" | head -6
  [ "$n" -ge "$AUTEURS_MIN" ]
}
check "Historique : au moins ${AUTEURS_MIN} auteurs distincts (commits depuis son propre compte)" \
  "chacun commite avec son compte : git config user.name / user.email" authors_ok

# --- 4. Livrables écrits ------------------------------------------------------
section "Livrables écrits"
journal_ok() {
  [ -f docs/journal.md ] || { echo "docs/journal.md absent"; return 1; }
  local n p
  n=$(grep -cE '^## +S[0-9]+ +— +[0-9]{4}-[0-9]{2}-[0-9]{2}' docs/journal.md)
  p=$(placeholders docs/journal.md)
  echo "${n} entrée(s) datée(s) (minimum ${JOURNAL_MIN})"
  [ "$p" -eq 0 ] || echo "${p} champ(s) [À compléter] restant(s) dans l'en-tête"
  [ "$n" -ge "$JOURNAL_MIN" ] && [ "$p" -eq 0 ]
}
check "docs/journal.md tenu (entrées « ## S<n> — AAAA-MM-JJ — … »)" \
  "une entrée de 3-5 lignes par séance" journal_ok

adr_ok() {
  local f valid=0 bad=""
  for f in docs/adr/[0-9][0-9][0-9][0-9]-*.md; do
    [ -f "$f" ] || continue
    case "$f" in docs/adr/0000-*) continue ;; esac
    if grep -qiE '^#{1,3} +D(é|e)cision' "$f" && [ "$(placeholders "$f")" -eq 0 ] &&
      grep -qiE 'statut' "$f"; then
      valid=$((valid + 1))
    else
      bad="$bad $(basename "$f")"
    fi
  done
  echo "${valid} ADR complet(s) (minimum ${ADR_MIN})"
  [ -z "$bad" ] || echo "incomplets (section Décision, Statut ou [À compléter]) :$bad"
  [ "$valid" -ge "$ADR_MIN" ]
}
if [ "$ADR_MIN" -gt 0 ]; then
  check "ADR dans docs/adr/ (hors 0000-modele.md)" \
    "cp docs/adr/0000-modele.md docs/adr/0001-….md" adr_ok
else
  info "ADR : non exigés au jalon ${JALON} ($(find docs/adr -name '[0-9]*.md' ! -name '0000-*' 2>/dev/null | wc -l | tr -d ' ') écrit(s))."
fi

card_ok() { # card_ok fichier min_lignes
  [ -f "$1" ] || { echo "$1 absent"; return 1; }
  local n p
  n=$(content_lines "$1")
  p=$(placeholders "$1")
  echo "${n} lignes de contenu, ${p} [À compléter] restant(s)"
  [ "$n" -ge "$2" ] && [ "$p" -eq 0 ]
}
if [ "$JALON" != j0 ]; then
  check "Dataset card (docs/dataset-card.md) complétée" \
    "partir du modèle fourni ; remplacer chaque [À compléter]" card_ok docs/dataset-card.md 25
fi
if [ "$JALON" = j2 ] || [ "$JALON" = final ]; then
  check "Model card (model-card/model-card.md) non vide" \
    "Lab 8 : model card" card_ok model-card/model-card.md 25
  if [ -f model-card/model-card.md ] && grep -qE 'TODO|TBD|XXX' model-card/model-card.md; then
    warn "model-card/model-card.md contient encore des TODO/TBD/XXX."
  fi
  for f in docs/dataset-card.md model-card/model-card.md; do
    if [ -f "$f" ] && [ -n "$DS_NAME" ] && ! grep -qiF "$DS_NAME" "$f" &&
      ! grep -qiF "${DS_TARGET:-@@}" "$f"; then
      warn "$f ne mentionne ni « ${DS_NAME} » ni la cible « ${DS_TARGET} » : est-elle adaptée à votre cas d'usage ?"
    fi
  done
fi
if [ "$JALON" = final ]; then
  rapport_ok() {
    [ -f docs/rapport.pdf ] || { echo "docs/rapport.pdf absent"; return 1; }
    if command -v pdfinfo >/dev/null 2>&1; then
      local pages
      pages=$(pdfinfo docs/rapport.pdf 2>/dev/null | awk '/^Pages:/{print $2}')
      echo "${pages:-?} pages (10 max hors page de garde et annexes)"
      [ "${pages:-0}" -le 14 ] || return 1
    fi
  }
  check "Rapport technique docs/rapport.pdf" "voir docs/rapport-technique.md" rapport_ok
  slides_ok() {
    local f
    for f in docs/slides.pdf docs/slides.pptx docs/slides.html docs/slides.odp; do
      [ -f "$f" ] && { echo "$f"; return 0; }
    done
    return 1
  }
  check "Slides de soutenance (docs/slides.pdf ou .pptx/.html/.odp)" \
    "commiter les slides avant le tag final" slides_ok
  video_ok() {
    local f
    for f in docs/demo.mp4 docs/demo.webm; do [ -f "$f" ] && { echo "$f"; return 0; }; done
    grep -iE '(vid(é|e)o|d(é|e)mo).*https?://|https?://.*(vid(é|e)o|d(é|e)mo|youtu|peertube|vimeo)' \
      README.md 2>/dev/null | head -1 | cut -c1-100 | grep .
  }
  check "Vidéo de démo (3 min) : lien dans le README ou docs/demo.mp4" \
    "ajouter le lien dans la section Démo du README" video_ok
fi

# --- 5. Jalons : tags Git -----------------------------------------------------
section "Jalons — tags Git (${TAGS// /, })"
prev=""
for tag in $TAGS; do
  tag_ok() {
    git rev-parse -q --verify "refs/tags/$1" >/dev/null || return 1
    git log -1 --format='%h  %cd  %s' --date=format:'%Y-%m-%d %H:%M' "$1^{commit}" | cut -c1-90
    if [ -n "$2" ] && git rev-parse -q --verify "refs/tags/$2" >/dev/null &&
      ! git merge-base --is-ancestor "$2" "$1"; then
      echo "attention : $2 n'est pas un ancêtre de $1 (historique réécrit ?)"
    fi
  }
  check "Tag ${tag}" "git tag ${tag} && git push origin ${tag} (enseignant : git fetch --tags)" \
    tag_ok "$tag" "$prev"
  prev=$tag
done
if [ "$JALON" = final ] && git rev-parse -q --verify refs/tags/final >/dev/null; then
  if [ "$(git rev-parse HEAD)" != "$(git rev-parse 'final^{commit}')" ]; then
    warn "HEAD n'est pas le commit du tag final (évaluer avec : git checkout final)."
  fi
  if [ -n "${SOUTENANCE:-}" ]; then
    final_on_time() {
      local tag_ts
      tag_ts=$(git for-each-ref --format='%(taggerdate:unix)' refs/tags/final)
      [ -n "$tag_ts" ] || tag_ts=$(git log -1 --format=%ct 'final^{commit}')
      py - "$tag_ts" "$SOUTENANCE" <<'EOF'
import sys
from datetime import datetime, timedelta

tag = datetime.fromtimestamp(int(sys.argv[1]))
limit = datetime.fromisoformat(sys.argv[2]) - timedelta(hours=48)
print(f"tag final : {tag:%Y-%m-%d %H:%M} ; limite : {limit:%Y-%m-%d %H:%M}")
sys.exit(0 if tag <= limit else 1)
EOF
    }
    check "Tag final posé au moins 48 h avant la soutenance (${SOUTENANCE})" \
      "date du commit ou du tag annoté ; l'enseignant recoupe avec l'heure du push sur GitHub" \
      final_on_time
  fi
fi

# --- 6. Extensions --------------------------------------------------------------
if [ "$JALON" = j2 ] || [ "$JALON" = final ]; then
  section "Extensions — branches ext/* fusionnées dans l'historique"
  # Fusions (merge commit « Merge pull request #N from user/ext/<nom> ») et squash
  # (titre de PR « ext/<nom> : … (#N) », convention du modèle de PR). Un « rebase and
  # merge » efface le nom de la branche : à éviter pour les extensions.
  EXT_LIST="$LOG_DIR/extensions.tsv"
  # Une ligne par extension : nom <TAB> commits concernés (du plus récent au plus ancien).
  git log --format='%H%x09%s' HEAD 2>/dev/null | awk -F'\t' '
    {
      re = "(^|[ /:(\047\"[])ext/[A-Za-z0-9._-]+"
      if (match($2, re)) {
        m = substr($2, RSTART, RLENGTH); sub(/^.*ext\//, "", m); sub(/[.]+$/, "", m)
        if (!(m in shas)) order[++n] = m
        shas[m] = shas[m] " " $1
      }
    }
    END { for (i = 1; i <= n; i++) print order[i] "\t" substr(shas[order[i]], 2) }' >"$EXT_LIST"
  while IFS="$(printf '\t')" read -r name commits; do
    who="" files="" prs=""
    for sha in $commits; do
      if [ "$(git log -1 --format=%P "$sha" | wc -w)" -gt 1 ]; then
        # Fusion classique : auteurs et fichiers de la branche fusionnée
        who="$who$(git log --format=%aN "${sha}^1..${sha}^2")"$'\n'
        files="$files$(git diff --name-only "${sha}^1" "$sha")"$'\n'
      else
        # Squash (ou commit préfixé ext/<nom>) : auteur + co-auteurs déclarés
        who="$who$(git log -1 --format=%aN "$sha")"$'\n'
        who="$who$(git log -1 --format=%B "$sha" |
          sed -n 's/^[Cc]o-authored-by: *\([^<]*\).*/\1/p' | sed 's/ *$//')"$'\n'
        files="$files$(git show --name-only --format= "$sha")"$'\n'
      fi
      prs="$prs $(git log -1 --format=%s "$sha" | grep -oE '#[0-9]+' | head -1)"
    done
    who=$(printf '%s' "$who" | grep . | sort | uniq -c | sort -rn |
      awk '{$1=""; sub(/^ /, ""); print}' | paste -sd, - | sed 's/,/, /g')
    prs=$(echo "$prs" | tr ' ' '\n' | grep . | sort -u | paste -sd' ' -)
    t_ok=$(printf '%s\n' "$files" | grep -cE '(^|/)tests?/|(^|/)test_[^/]*\.py$')
    a_ok=$(printf '%s\n' "$files" | grep -c '^docs/adr/')
    info "ext/${name} fusionnée ${prs:+(PR $prs) }— auteur(s) : ${who}"
    [ -n "$prs" ] || warn "ext/${name} : aucun numéro de PR dans les messages de fusion (fusion sans PR ?)"
    [ "$t_ok" -gt 0 ] || warn "ext/${name} : aucun fichier de test dans la fusion"
    [ "$a_ok" -gt 0 ] || warn "ext/${name} : aucun ADR dans la fusion (docs/adr/)"
  done <"$EXT_LIST"
  EXT_N=$(grep -c . "$EXT_LIST")
  ext_count() {
    echo "${EXT_N} extension(s) distincte(s) trouvée(s) (attendu : ${EXT_MIN})"
    [ "$EXT_N" -ge "$EXT_MIN" ]
  }
  check "Au moins ${EXT_MIN} extension(s) ext/<nom> fusionnée(s) dans main" \
    "PR « ext/<nom> : … » relue puis fusionnée (voir le modèle de PR)" ext_count
  pending=$(git branch -r --no-merged HEAD 2>/dev/null | grep -E '/ext/' | sed 's/^ *//')
  [ -z "$pending" ] || warn "branche(s) ext/* non fusionnée(s) : $(echo "$pending" | tr '\n' ' ')"

  if [ "$AVEC_GH" -eq 1 ]; then
    reviews_ok() {
      command -v gh >/dev/null 2>&1 || { echo "gh CLI absent"; return 1; }
      local json="$LOG_DIR/pr-merged.json"
      t 60 gh pr list --state merged --limit 300 \
        --json number,title,headRefName,author,reviews >"$json" 2>&1 || {
        tail -2 "$json"
        return 1
      }
      py - "$json" <<'EOF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    prs = [p for p in json.load(fh) if p["headRefName"].startswith("ext/")]
bad = 0
for p in prs:
    author = p["author"]["login"]
    ok = any(
        r["state"] == "APPROVED" and r["author"]["login"] != author
        for r in p.get("reviews", [])
    )
    verdict = "approuvée par un autre compte" if ok else "SANS approbation par un autre compte"
    print(f"#{p['number']} {p['headRefName']} par @{author} : {verdict}")
    bad += not ok
if not prs:
    print("aucune PR fusionnée depuis une branche ext/*")
sys.exit(1 if bad or not prs else 0)
EOF
    }
    check "PR ext/* approuvées par un autre compte que l'auteur (GitHub)" \
      "relecture et approbation par le partenaire avant fusion" reviews_ok
  fi
fi

# --- Récapitulatif ----------------------------------------------------------------
echo
echo "════════ Récapitulatif — jalon « ${JALON} » ════════"
for i in "${!SEC_NAMES[@]}"; do
  [ "${SEC_TOT[i]}" -gt 0 ] || continue
  mark="✅"
  [ "${SEC_OK[i]}" -eq "${SEC_TOT[i]}" ] || mark="❌"
  printf '%s %5s  %s\n' "$mark" "${SEC_OK[i]}/${SEC_TOT[i]}" "${SEC_NAMES[i]}"
done
echo
if [ "$FAILS" -eq 0 ]; then
  echo "🎉 ${TOTAL}/${TOTAL} vérifications OK, ${WARNS} avertissement(s) — rendu « ${JALON} » complet."
else
  echo "${FAILS} échec(s) sur ${TOTAL} vérifications, ${WARNS} avertissement(s)."
fi
echo "Ce pré-contrôle ne note pas : il vérifie la présence et le fonctionnement des livrables."
echo "Journaux détaillés : ${LOG_DIR}"
exit $((FAILS > 255 ? 255 : FAILS))
