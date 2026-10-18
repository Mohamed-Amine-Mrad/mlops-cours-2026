"""Télécharge le jeu de données brut décrit par dataset.yaml.

Cas par défaut : Statlog German Credit (UCI, CC BY 4.0).
Le fichier UCI d'origine (``german.data``) code les catégories (A11, A43…) ;
on les décode avec les libellés d'OpenML (``credit-g``) pour obtenir un CSV
lisible, identique quelle que soit la source.

Usage ::

    python -m src.download                       # UCI, sinon OpenML en secours
    python -m src.download --from-file german.data   # hors ligne (fichier UCI local)

Sortie : ``data/raw/dataset.csv`` (chemin ``raw_path`` de dataset.yaml),
à versionner ensuite avec ``dvc add``.

Votre propre dataset ? Remplacez ce fichier par un script qui écrit un CSV
dont les colonnes correspondent à dataset.yaml (features + cible).
"""

from __future__ import annotations

import argparse
import io
import sys
import urllib.request
import zipfile
from pathlib import Path

import pandas as pd

from src.dataset_config import load_config

UCI_ZIP_URL = "https://archive.ics.uci.edu/static/public/144/statlog+german+credit+data.zip"

# Ordre des 20 attributs de german.data (documentation UCI) + la cible.
COLUMNS = [
    "checking_status", "duration", "credit_history", "purpose", "credit_amount",
    "savings_status", "employment", "installment_commitment", "personal_status",
    "other_parties", "residence_since", "property_magnitude", "age",
    "other_payment_plans", "housing", "existing_credits", "job", "num_dependents",
    "own_telephone", "foreign_worker", "credit_risk",
]  # fmt: skip

# Codes UCI -> libellés OpenML credit-g (documentation german.doc).
CODES = {
    "checking_status": {"A11": "<0", "A12": "0<=X<200", "A13": ">=200", "A14": "no checking"},
    "credit_history": {
        "A30": "no credits/all paid", "A31": "all paid", "A32": "existing paid",
        "A33": "delayed previously", "A34": "critical/other existing credit",
    },
    "purpose": {
        "A40": "new car", "A41": "used car", "A42": "furniture/equipment",
        "A43": "radio/tv", "A44": "domestic appliance", "A45": "repairs",
        "A46": "education", "A47": "vacation", "A48": "retraining",
        "A49": "business", "A410": "other",
    },
    "savings_status": {
        "A61": "<100", "A62": "100<=X<500", "A63": "500<=X<1000",
        "A64": ">=1000", "A65": "no known savings",
    },
    "employment": {
        "A71": "unemployed", "A72": "<1", "A73": "1<=X<4", "A74": "4<=X<7", "A75": ">=7",
    },
    "personal_status": {
        "A91": "male div/sep", "A92": "female div/dep/mar", "A93": "male single",
        "A94": "male mar/wid", "A95": "female single",
    },
    "other_parties": {"A101": "none", "A102": "co applicant", "A103": "guarantor"},
    "property_magnitude": {
        "A121": "real estate", "A122": "life insurance", "A123": "car", "A124": "no known property",
    },
    "other_payment_plans": {"A141": "bank", "A142": "stores", "A143": "none"},
    "housing": {"A151": "rent", "A152": "own", "A153": "for free"},
    "job": {
        "A171": "unemp/unskilled non res", "A172": "unskilled resident",
        "A173": "skilled", "A174": "high qualif/self emp/mgmt",
    },
    "own_telephone": {"A191": "none", "A192": "yes"},
    "foreign_worker": {"A201": "yes", "A202": "no"},
    "credit_risk": {"1": "good", "2": "bad"},
}  # fmt: skip


def decode_uci(raw: pd.DataFrame) -> pd.DataFrame:
    """Décode un DataFrame german.data (codes UCI) en libellés lisibles."""
    raw.columns = COLUMNS
    df = raw.copy()
    for col, mapping in CODES.items():
        values = df[col].astype(str).str.strip()
        unknown = sorted(set(values) - set(mapping))
        if unknown:
            raise ValueError(f"Codes inconnus dans {col} : {unknown}")
        df[col] = values.map(mapping)
    return df


def read_uci_file(path_or_buffer) -> pd.DataFrame:
    """Lit german.data (séparateur espace) ou une copie séparée par des virgules."""
    text = (
        path_or_buffer.read()
        if hasattr(path_or_buffer, "read")
        else Path(path_or_buffer).read_bytes()
    )
    text = text.decode("utf-8") if isinstance(text, bytes) else text
    sep = "," if "," in text.splitlines()[0] else r"\s+"
    return pd.read_csv(io.StringIO(text), sep=sep, header=None, dtype=str, engine="python")


def from_uci() -> pd.DataFrame:
    with urllib.request.urlopen(UCI_ZIP_URL, timeout=60) as resp:
        archive = zipfile.ZipFile(io.BytesIO(resp.read()))
    with archive.open("german.data") as fh:
        return decode_uci(read_uci_file(fh))


def from_openml() -> pd.DataFrame:
    from sklearn.datasets import fetch_openml

    df = fetch_openml("credit-g", version=1, as_frame=True).frame
    df = df.rename(columns={"class": "credit_risk"})
    for col in df.columns:  # catégories OpenML -> chaînes simples
        if isinstance(df[col].dtype, pd.CategoricalDtype):
            df[col] = df[col].astype(str)
    return df[COLUMNS]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--from-file", help="fichier german.data local (hors ligne)")
    args = parser.parse_args()

    cfg = load_config()
    if args.from_file:
        df, source = decode_uci(read_uci_file(args.from_file)), args.from_file
    else:
        try:
            df, source = from_uci(), "UCI"
        except (OSError, zipfile.BadZipFile, KeyError, ValueError) as exc:  # réseau, URL…
            print(f"UCI indisponible ({exc}) — repli sur OpenML credit-g", file=sys.stderr)
            df, source = from_openml(), "OpenML"

    # Types numériques explicites (les codes UCI sont lus comme texte)
    for col in cfg.numeric:
        df[col] = pd.to_numeric(df[col])
    cfg.validate_columns(df)

    out = Path(cfg.raw_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    df[cfg.columns].to_csv(out, index=False)
    share = (df[cfg.target] == cfg.positive_class).mean()
    print(f"{len(df)} lignes ({source}) -> {out} · classe '{cfg.positive_class}' : {share:.0%}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
