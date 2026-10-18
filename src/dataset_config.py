"""Lecture du contrat ``dataset.yaml`` — source unique de vérité sur les données.

Tous les scripts du projet (préparation, entraînement, validation, API,
équité, monitoring) passent par ce module : changer de dataset ne demande
que de réécrire ``dataset.yaml`` et ``src/download.py``.

Usage ::

    from src.dataset_config import load_config

    cfg = load_config()                 # lit ./dataset.yaml
    X, y = cfg.split_xy(df)             # y = 1 pour la classe positive
    pre = cfg.build_preprocessor()      # ColumnTransformer scikit-learn
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import pandas as pd
import yaml

DEFAULT_PATH = os.environ.get("DATASET_CONFIG", "dataset.yaml")


@dataclass(frozen=True)
class SensitiveAttribute:
    """Attribut sensible ; ``bins``/``labels`` regroupent un attribut numérique."""

    column: str
    bins: list[float] | None = None
    labels: list[str] | None = None

    def groups(self, df: pd.DataFrame) -> pd.Series:
        """Renvoie le groupe de chaque ligne (colonne découpée si ``bins``)."""
        values = df[self.column]
        if self.bins is None:
            return values.astype(str).rename(self.column)
        return (
            pd.cut(values, bins=self.bins, labels=self.labels, right=False)
            .astype(str)
            .rename(f"{self.column}_group")
        )


@dataclass(frozen=True)
class DatasetConfig:
    """Contenu typé de ``dataset.yaml``."""

    name: str
    raw_path: str
    target: str
    positive_class: Any
    numeric: list[str]
    categorical: list[str]
    sensitive: list[SensitiveAttribute] = field(default_factory=list)
    primary_metric: str = "roc_auc"
    promotion_threshold: float = 0.0
    cost_false_negative: float = 1.0
    cost_false_positive: float = 1.0
    test_size: float = 0.2
    random_state: int = 42
    raw: dict[str, Any] = field(default_factory=dict, repr=False)

    # ------------------------------------------------------------------ colonnes
    @property
    def features(self) -> list[str]:
        """Toutes les variables explicatives, numériques puis catégorielles."""
        return [*self.numeric, *self.categorical]

    @property
    def extra_sensitive(self) -> list[str]:
        """Attributs sensibles qui ne sont PAS des features (mesurés, jamais appris)."""
        return [s.column for s in self.sensitive if s.column not in self.features]

    @property
    def columns(self) -> list[str]:
        """Colonnes attendues dans les données : features, sensibles hors features, cible."""
        return [*self.features, *self.extra_sensitive, self.target]

    # ------------------------------------------------------------------ données
    def validate_columns(self, df: pd.DataFrame) -> None:
        """Lève ``ValueError`` si des colonnes déclarées manquent."""
        missing = [c for c in self.columns if c not in df.columns]
        if missing:
            raise ValueError(
                f"Colonnes déclarées dans dataset.yaml absentes des données : {missing}"
            )

    def encode_target(self, y: pd.Series) -> pd.Series:
        """1 pour la classe positive (``target.positive_class``), 0 sinon."""
        return (y.astype(str) == str(self.positive_class)).astype(int).rename(self.target)

    def split_xy(self, df: pd.DataFrame) -> tuple[pd.DataFrame, pd.Series]:
        """Sépare features et cible encodée 0/1."""
        self.validate_columns(df)
        return df[self.features].copy(), self.encode_target(df[self.target])

    def sensitive_frame(self, df: pd.DataFrame) -> pd.DataFrame:
        """Un DataFrame avec un groupe par attribut sensible (pour Fairlearn)."""
        return pd.concat([s.groups(df) for s in self.sensitive], axis=1)

    # ------------------------------------------------------------- modélisation
    def build_preprocessor(self):
        """Prétraitement standard : imputation + standardisation / one-hot."""
        from sklearn.compose import ColumnTransformer
        from sklearn.impute import SimpleImputer
        from sklearn.pipeline import Pipeline
        from sklearn.preprocessing import OneHotEncoder, StandardScaler

        numeric = Pipeline(
            [("impute", SimpleImputer(strategy="median")), ("scale", StandardScaler())]
        )
        categorical = Pipeline(
            [
                ("impute", SimpleImputer(strategy="most_frequent")),
                ("onehot", OneHotEncoder(handle_unknown="ignore", sparse_output=False)),
            ]
        )
        return ColumnTransformer(
            [("num", numeric, self.numeric), ("cat", categorical, self.categorical)]
        )

    def business_cost(self, y_true, y_pred) -> float:
        """Coût métier total selon la matrice de coûts de dataset.yaml."""
        import numpy as np

        y_true, y_pred = np.asarray(y_true), np.asarray(y_pred)
        fn = int(((y_true == 1) & (y_pred == 0)).sum())
        fp = int(((y_true == 0) & (y_pred == 1)).sum())
        return fn * self.cost_false_negative + fp * self.cost_false_positive

    def cost_threshold(self, weight_ratio: float = 1.0) -> float:
        """Seuil de décision qui minimise le coût métier attendu.

        Pour des probabilités bien calibrées, décider « positif » dès que
        ``p >= C_FP / (C_FP + C_FN)`` minimise le coût (ici 1/6).
        Si le modèle a été entraîné avec des poids de classes (ex.
        ``class_weight="balanced"``), ses probabilités sont gonflées d'un facteur
        ``weight_ratio = poids_positifs / poids_négatifs`` sur les cotes ; le seuil
        équivalent devient ``C_FP·k / (C_FP·k + C_FN)`` avec ``k = weight_ratio``.
        """
        fp, fn = self.cost_false_positive, self.cost_false_negative
        return fp * weight_ratio / (fp * weight_ratio + fn)

    # ------------------------------------------------------------------ fichiers
    def read_xy(self, path: str | os.PathLike[str]) -> tuple[pd.DataFrame, pd.Series]:
        """Lit un CSV préparé : features (numériques en float64) et cible 0/1.

        Le float64 rend la signature MLflow et l'export ONNX robustes (un entier
        envoyé à l'API est accepté comme un réel).
        """
        X, y = self.split_xy(pd.read_csv(path))
        X[self.numeric] = X[self.numeric].astype("float64")
        return X, y


def load_config(path: str | os.PathLike[str] = DEFAULT_PATH) -> DatasetConfig:
    """Charge et valide ``dataset.yaml``."""
    data = yaml.safe_load(Path(path).read_text(encoding="utf-8"))
    for key in ("name", "raw_path", "target", "features"):
        if key not in data:
            raise ValueError(f"dataset.yaml : clé obligatoire manquante « {key} »")
    feats = data["features"]
    metrics = data.get("metrics", {}) or {}
    costs = metrics.get("cost_matrix", {}) or {}
    split = data.get("split", {}) or {}
    cfg = DatasetConfig(
        name=data["name"],
        raw_path=data["raw_path"],
        target=data["target"]["column"],
        positive_class=data["target"]["positive_class"],
        numeric=list(feats.get("numeric", []) or []),
        categorical=list(feats.get("categorical", []) or []),
        sensitive=[SensitiveAttribute(**s) for s in data.get("sensitive", []) or []],
        primary_metric=metrics.get("primary", "roc_auc"),
        promotion_threshold=float(metrics.get("promotion_threshold", 0.0)),
        cost_false_negative=float(costs.get("false_negative", 1)),
        cost_false_positive=float(costs.get("false_positive", 1)),
        test_size=float(split.get("test_size", 0.2)),
        random_state=int(split.get("random_state", 42)),
        raw=data,
    )
    overlap = set(cfg.numeric) & set(cfg.categorical)
    if overlap:
        raise ValueError(f"Colonnes à la fois numériques et catégorielles : {overlap}")
    if cfg.target in cfg.features:
        raise ValueError("La cible ne peut pas être aussi une feature.")
    # Un attribut sensible peut ne pas être une feature (ex. exclu du modèle par choix
    # d'équité) : il doit alors seulement être présent dans les données (cfg.columns).
    return cfg
