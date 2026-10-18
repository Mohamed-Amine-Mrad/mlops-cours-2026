# Fichier : monitoring/traffic.py
"""Générateur de trafic pour l'API de scoring : normal, puis dérivé (drift).

Les demandes sont de vraies lignes de data/processed/test.csv (colonnes lues dans
dataset.yaml), tirées au hasard. En mode « drift », des variables sont déformées pour
simuler un changement de population :
  - numérique  : COLONNE=FACTEUR multiplie la colonne (ex. 0.6 = valeurs 40 % plus basses) ;
  - catégorielle : COLONNE=VALEUR remplace toutes les valeurs par VALEUR.
Sans --drift, toutes les variables numériques sont multipliées par --factor.

Exemples (depuis la racine du repo) :
  uv run python monitoring/traffic.py --url http://localhost:8000 --duration 60
  uv run python monitoring/traffic.py --mode drift --duration 300
  uv run python monitoring/traffic.py --mode drift --drift age=0.6 --drift credit_amount=2.5
Par défaut, l'URL et l'en-tête Host viennent de SCORING_URL et ISVC_HOST (Lab 5).
"""

import argparse
import os
import sys
import time
from pathlib import Path

import httpx
import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
sys.path.append(str(ROOT))
from src.dataset_config import load_config  # noqa: E402


def parse_args(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--url", default=os.getenv("SCORING_URL", "http://localhost:30080"))
    p.add_argument(
        "--host-header",
        default=os.getenv("ISVC_HOST", ""),
        help="en-tête Host (passerelle Kourier) ; vide = aucun",
    )
    p.add_argument("--mode", choices=["normal", "drift"], default="normal")
    p.add_argument(
        "--drift",
        action="append",
        default=[],
        metavar="COLONNE=VALEUR",
        help="déformation d'une colonne (répétable)",
    )
    p.add_argument(
        "--factor",
        type=float,
        default=1.5,
        help="facteur appliqué aux colonnes numériques si --drift est absent",
    )
    p.add_argument("--rps", type=float, default=20.0, help="requêtes par seconde visées")
    p.add_argument("--duration", type=float, default=300.0, help="secondes (0 = sans fin)")
    p.add_argument("--batch", type=int, default=1, help="demandes par requête")
    p.add_argument("--data", default=str(ROOT / "data" / "processed" / "test.csv"))
    p.add_argument("--save", help="écrire les demandes envoyées dans ce CSV")
    p.add_argument("--seed", type=int, default=42)
    return p.parse_args(argv)


def load_requests(cfg, path: str) -> pd.DataFrame:
    """Les features de test.csv, dans l'ordre de dataset.yaml (cible et id ignorés)."""
    df = pd.read_csv(path)
    missing = [c for c in cfg.features if c not in df.columns]
    if missing:
        raise SystemExit(f"Colonnes absentes de {path} : {missing}")
    return df[cfg.features]


def drift_spec(cfg, args) -> dict[str, str]:
    if args.mode == "normal":
        return {}
    if not args.drift:
        return {c: str(args.factor) for c in cfg.numeric}
    spec = dict(item.split("=", 1) for item in args.drift)
    unknown = [c for c in spec if c not in cfg.features]
    if unknown:
        raise SystemExit(f"--drift : colonnes inconnues dans dataset.yaml : {unknown}")
    return spec


def apply_drift(cfg, df: pd.DataFrame, spec: dict[str, str]) -> pd.DataFrame:
    out = df.copy()
    for col, value in spec.items():
        if col in cfg.numeric:
            shifted = out[col] * float(value)
            # Une colonne entière (âge, durée...) reste entière : la dérive reste plausible
            integer = bool((df[col].dropna() % 1 == 0).all())
            out[col] = shifted.round() if integer else shifted
        else:
            out[col] = value
    return out


def to_instances(df: pd.DataFrame) -> list[dict]:
    """NaN -> null (valeur manquante acceptée par l'API) ; types JSON natifs."""
    clean = df.astype(object).where(df.notna(), None)
    return clean.to_dict("records")


def main(argv=None) -> int:
    args = parse_args(argv)
    cfg = load_config(ROOT / "dataset.yaml")
    pool = load_requests(cfg, args.data)
    spec = drift_spec(cfg, args)
    rng = np.random.default_rng(args.seed)
    url = args.url.rstrip("/") + "/predict"
    headers = {"Host": args.host_header} if args.host_header else {}
    print(
        f"Trafic {args.mode} -> {url} ({args.rps:g} req/s, lot de {args.batch})"
        + (f" · dérive : {spec}" if spec else "")
    )

    sent = errors = positives = 0
    scores: list[float] = []
    saved: list[pd.DataFrame] = []
    start = last_report = time.monotonic()
    period = 1.0 / args.rps
    with httpx.Client(headers=headers, timeout=5.0) as client:
        try:
            while args.duration <= 0 or time.monotonic() - start < args.duration:
                tick = time.monotonic()
                batch = pool.iloc[rng.integers(0, len(pool), size=args.batch)]
                batch = apply_drift(cfg, batch, spec)
                try:
                    r = client.post(url, json={"instances": to_instances(batch)})
                    r.raise_for_status()
                    preds = r.json()["predictions"]
                    sent += len(preds)
                    positives += sum(p["prediction"] for p in preds)
                    scores += [p["probability"] for p in preds]
                    if args.save:
                        saved.append(batch)
                except (httpx.HTTPError, KeyError, ValueError) as e:
                    errors += 1
                    if errors <= 3:
                        print(f"  erreur : {e}")
                if time.monotonic() - last_report >= 10:
                    last_report = time.monotonic()
                    print(
                        f"  {time.monotonic() - start:5.0f} s · {sent} demandes · {errors} erreurs"
                        f" · « {cfg.positive_class} » {positives / max(sent, 1):.1%}"
                    )
                time.sleep(max(0.0, period - (time.monotonic() - tick)))
        except KeyboardInterrupt:
            pass

    print(
        f"Terminé : {sent} demandes, {errors} requêtes en erreur, "
        f"taux de décision « {cfg.positive_class} » {positives / max(sent, 1):.1%}, "
        f"score moyen {np.mean(scores) if scores else float('nan'):.3f}"
    )
    if args.save and saved:
        pd.concat(saved).to_csv(args.save, index=False)
        print(f"Demandes enregistrées dans {args.save}")
    return 0 if sent else 1


if __name__ == "__main__":
    raise SystemExit(main())
