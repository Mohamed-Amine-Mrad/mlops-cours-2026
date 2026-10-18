"""Tests du contrat dataset.yaml (s'exécutent sans réseau ni cluster)."""

from pathlib import Path

import pandas as pd
import pytest

from src.dataset_config import load_config

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def cfg():
    return load_config(ROOT / "dataset.yaml")


@pytest.fixture
def sample(cfg):
    """Deux lignes synthétiques conformes au contrat."""
    row = {c: 1 for c in cfg.numeric} | {c: "x" for c in cfg.categorical}
    df = pd.DataFrame([row, row])
    for s in cfg.sensitive:
        df[s.column] = [20, 40] if s.bins else ["a", "b"]
    df[cfg.target] = [cfg.positive_class, "other"]
    return df


def test_contrat_coherent(cfg):
    assert cfg.target not in cfg.features
    assert not set(cfg.numeric) & set(cfg.categorical)
    assert all(s.column in cfg.columns for s in cfg.sensitive)
    assert 0 < cfg.test_size < 1


def test_cible_encodee_0_1(cfg, sample):
    _, y = cfg.split_xy(sample)
    assert y.tolist() == [1, 0]


def test_colonne_manquante_detectee(cfg, sample):
    with pytest.raises(ValueError, match="absentes"):
        cfg.split_xy(sample.drop(columns=[cfg.numeric[0]]))


def test_groupes_sensibles(cfg, sample):
    groups = cfg.sensitive_frame(sample)
    assert list(groups.columns) == [
        f"{s.column}_group" if s.bins else s.column for s in cfg.sensitive
    ]


def test_cout_metier(cfg):
    # 1 faux négatif + 1 faux positif
    assert cfg.business_cost([1, 0, 1], [0, 1, 1]) == (
        cfg.cost_false_negative + cfg.cost_false_positive
    )


def test_seuil_cout(cfg):
    fp, fn = cfg.cost_false_positive, cfg.cost_false_negative
    assert cfg.cost_threshold() == pytest.approx(fp / (fp + fn))
    # poids de classes : seuil plus haut, toujours dans ]0, 1[
    assert cfg.cost_threshold() < cfg.cost_threshold(2.0) < 1


def test_read_xy_float(cfg, sample, tmp_path):
    path = tmp_path / "s.csv"
    sample.to_csv(path, index=False)
    X, y = cfg.read_xy(path)
    assert all(X[c].dtype == "float64" for c in cfg.numeric)
    assert y.tolist() == [1, 0]


def test_preprocesseur(cfg, sample):
    X, _ = cfg.split_xy(sample)
    out = cfg.build_preprocessor().fit_transform(X)
    assert out.shape[0] == 2


def test_sensible_hors_features(tmp_path):
    """Un attribut sensible exclu du modèle reste mesurable (Lab 8)."""
    import yaml

    data = yaml.safe_load((ROOT / "dataset.yaml").read_text(encoding="utf-8"))
    data["features"]["categorical"].remove("personal_status")
    path = tmp_path / "dataset.yaml"
    path.write_text(yaml.safe_dump(data), encoding="utf-8")
    cfg = load_config(path)
    assert "personal_status" not in cfg.features
    assert cfg.extra_sensitive == ["personal_status"]
    assert "personal_status" in cfg.columns
