"""Vérifie que le code montré dans les énoncés est EXACTEMENT celui des fichiers.

Chaque bloc de code d'un énoncé (labs/mX-*/README.md) dont la première ligne est
un commentaire « Fichier : chemin » doit être identique au fichier ``chemin`` de
l'état cumulé de la solution du lab X (solutions m0 → mX superposées au template).
Deux formes acceptées : le fichier contient l'en-tête (bloc == fichier) ou non
(bloc sans sa première ligne == fichier).

Usage ::

    python tools/check_sync.py --template . --solutions ../staging/solutions
    python tools/check_sync.py --tree .                  # repo des solutions (main)
    python tools/check_sync.py --tree . --upto 3         # branche solution/m3 : labs 0 à 3
    python tools/check_sync.py --tree . --skip-missing   # template (fichiers à venir ignorés)
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

FENCE = re.compile(r"^(?P<indent>[ \t]*)(?P<fence>`{3,}|~{3,})(?P<lang>[^\n`]*)$")
HEADER = re.compile(
    r"^\s*(?:#|//|--|<!--|;)\s*Fichier\s*:\s*(?P<path>[^\s>]+?)\s*(?:-->)?\s*$", re.IGNORECASE
)
LAB_DIR = re.compile(r"^m(?P<n>\d+)-")


def code_blocks(text: str):
    """(numéro de ligne, lignes) de chaque bloc clôturé, indentation retirée."""
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        m = FENCE.match(lines[i])
        if not m:
            i += 1
            continue
        indent, fence = m["indent"], m["fence"]
        start, body = i + 1, []
        i += 1
        while i < len(lines) and not lines[i].strip().startswith(fence):
            line = lines[i]
            body.append(line[len(indent) :] if line.startswith(indent) else line.lstrip())
            i += 1
        yield start, body
        i += 1


def resolve(rel: str, lab: int, template: Path, solutions: Path | None) -> Path | None:
    """Fichier tel qu'il est à la fin du lab ``lab`` (la dernière solution qui l'a écrit)."""
    if solutions is not None:
        for n in range(lab, -1, -1):
            cand = solutions / f"m{n}" / rel
            if cand.is_file():
                return cand
    cand = template / rel
    return cand if cand.is_file() else None


def check_lab(
    readme: Path, lab: int, template: Path, solutions: Path | None, skip_missing: bool = False
) -> list[str]:
    errors, count = [], 0
    for line_no, body in code_blocks(readme.read_text(encoding="utf-8")):
        if not body:
            continue
        m = HEADER.match(body[0])
        if not m:
            continue
        count += 1
        rel = m["path"]
        target = resolve(rel, lab, template, solutions)
        where = f"{readme.relative_to(template)}:{line_no}"
        if target is None:
            if not skip_missing:
                errors.append(f"{where} : fichier introuvable « {rel} »")
            continue
        actual = target.read_text(encoding="utf-8").rstrip("\n")
        with_header = "\n".join(body).rstrip("\n")
        without_header = "\n".join(body[1:]).rstrip("\n")
        if actual not in (with_header, without_header):
            a, b = actual.split("\n"), without_header.split("\n")
            if HEADER.match(a[0] if a else ""):
                b = with_header.split("\n")
            diff_at = next(
                (k for k, (x, y) in enumerate(zip(a, b, strict=False)) if x != y),
                min(len(a), len(b)),
            )
            errors.append(
                f"{where} : « {rel} » diffère du fichier (ligne {diff_at + 1} : "
                f"énoncé={b[diff_at] if diff_at < len(b) else '<fin>'!r} / "
                f"fichier={a[diff_at] if diff_at < len(a) else '<fin>'!r})"
            )
    return [f"{readme.parent.name}: {count} bloc(s) « Fichier : » vérifié(s)"] + errors


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--template", type=Path, default=Path("."), help="racine du repo du cours")
    ap.add_argument("--solutions", type=Path, help="dossier staging/solutions (mX/ superposés)")
    ap.add_argument("--tree", type=Path, help="arbre déjà assemblé (branche solution/mX)")
    ap.add_argument("--labs", nargs="*", type=int, help="limiter à ces numéros de lab")
    ap.add_argument("--upto", type=int, help="vérifier seulement les labs 0 à N")
    ap.add_argument(
        "--skip-missing", action="store_true", help="ignorer les fichiers absents (template)"
    )
    args = ap.parse_args()
    template = (args.tree or args.template).resolve()
    solutions = None if args.tree else (args.solutions.resolve() if args.solutions else None)

    failures = 0
    for readme in sorted((template / "labs").glob("m*-*/README.md")):
        lab = int(LAB_DIR.match(readme.parent.name)["n"])
        if args.labs and lab not in args.labs:
            continue
        if args.upto is not None and lab > args.upto:
            continue
        summary, *errors = check_lab(readme, lab, template, solutions, args.skip_missing)
        print(("✅ " if not errors else "❌ ") + summary)
        for e in errors:
            print("   - " + e)
        failures += len(errors)
    print(f"\n{failures} écart(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
