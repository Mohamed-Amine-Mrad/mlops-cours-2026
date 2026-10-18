# Fichier : tests/test_monitoring.py
"""Tests du Lab 7 : métriques de l'API, générateur de trafic, analyse du canary.

Aucun cluster nécessaire. Les tests qui demandent le modèle ONNX (packaging/model/) ou les
données (data/processed/) sont sautés s'ils sont absents.
"""

import importlib.util
import sys
from pathlib import Path

import pandas as pd
import pytest

from src.dataset_config import load_config

ROOT = Path(__file__).resolve().parents[1]
cfg = load_config(ROOT / "dataset.yaml")


def load_script(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


canary = load_script("canary_analysis", ROOT / "monitoring" / "canary_analysis.py")
traffic = load_script("traffic", ROOT / "monitoring" / "traffic.py")


# --- API instrumentée -------------------------------------------------------------------
@pytest.fixture(scope="module")
def monitored():
    """(module serve, client) : l'API déjà importée (fixture du Lab 6) ou celle du repo."""
    if "app.serve" in sys.modules:
        serve = sys.modules["app.serve"]
    else:
        if not (ROOT / "packaging" / "model" / "model.onnx").exists():
            pytest.skip("packaging/model/model.onnx absent (Lab 4, étape 1)")
        sys.path.insert(0, str(ROOT / "packaging"))
        serve = importlib.import_module("app.serve")
    from fastapi.testclient import TestClient

    return serve, TestClient(serve.app)


def a_request() -> dict:
    """Une demande valide fabriquée depuis dataset.yaml (valeurs neutres)."""
    row = {c: 1.0 for c in cfg.numeric} | {c: "inconnu" for c in cfg.categorical}
    for s in cfg.sensitive:  # une valeur dans les bornes des attributs découpés
        if s.bins and s.column in cfg.numeric:
            row[s.column] = float(s.bins[0])
    return row


def test_metrics_endpoint_exposes_business_metrics(monitored):
    _, client = monitored
    r = client.post("/predict", json={"instances": [a_request(), a_request()]})
    assert r.status_code == 200
    metrics = client.get("/metrics")
    assert metrics.status_code == 200  # route directe : pas de redirection 307
    text = metrics.text
    for name in (
        "ml_predictions_total",
        "ml_inference_latency_seconds_bucket",
        "ml_prediction_score_bucket",
        "http_requests_total",
        "ml_model_info",
    ):
        assert name in text, name
    assert 'handler="/predict"' in text


def test_rejected_requests_are_counted(monitored):
    _, client = monitored
    r = client.post("/predict", json={"instances": [{"colonne_inconnue": 1}]})
    assert r.status_code == 422
    assert 'code="422",handler="/predict"' in client.get("/metrics").text


def test_groups_match_lab8(monitored):
    """Le découpage de l'API (sans pandas) = celui du Lab 8 (SensitiveAttribute.groups)."""
    serve, _ = monitored
    for s in serve.SENSITIVE:
        if s.bins:
            values = [s.bins[0], (s.bins[0] + s.bins[1]) / 2, s.bins[-1] - 1e-6]
        else:
            values = ["a", "b"]
        expected = s.groups(pd.DataFrame({s.column: values})).tolist()
        assert [serve.group_of(s, v) for v in values] == expected


# --- Générateur de trafic ---------------------------------------------------------------
def test_traffic_drift_spec_defaults_to_all_numeric():
    args = traffic.parse_args(["--mode", "drift", "--factor", "2"])
    assert traffic.drift_spec(cfg, args) == {c: "2.0" for c in cfg.numeric}
    assert traffic.drift_spec(cfg, traffic.parse_args([])) == {}


def test_traffic_apply_drift_keeps_integers():
    col = cfg.numeric[0]
    df = pd.DataFrame(
        {c: [10.0, 20.0] for c in cfg.numeric} | {c: ["x", "y"] for c in cfg.categorical}
    )
    out = traffic.apply_drift(cfg, df, {col: "0.55", cfg.categorical[0]: "z"})
    assert out[col].tolist() == [6.0, 11.0]  # 5.5 -> 6, 11.0 : arrondi conservé
    assert set(out[cfg.categorical[0]]) == {"z"}
    assert df[col].tolist() == [10.0, 20.0]  # l'original n'est pas modifié


# --- Analyse du canary ------------------------------------------------------------------
def stats(requests=500, errors=0.0, p95=5.0, positive=0.6, up=1.0):
    return {
        "up": up,
        "requests": requests,
        "predictions": requests,
        "error_rate": errors,
        "p95_ms": p95,
        "positive_rate": positive,
        "mean_score": 0.45,
    }


def run_checks(stable, canary_stats, same_scores=True):
    args = canary.parse_args([])
    hist = {0.25: 30.0, 0.5: 60.0, 0.75: 90.0, float("inf"): 100.0}
    shifted = {0.25: 5.0, 0.5: 10.0, 0.75: 40.0, float("inf"): 100.0}
    data = {
        "stats": {"s": stable, "c": canary_stats},
        "buckets": {"s": hist, "c": hist if same_scores else shifted},
    }
    return canary.evaluate(args, "s", "c", data)


def test_canary_healthy_progresses_then_promotes():
    checks = run_checks(stats(), stats(p95=6.0, positive=0.62))
    assert {c["status"] for c in checks} == {"PASS"}
    assert canary.decide(checks, 10, [10, 50, 100]) == ("CONTINUE", ["canary", "50"])
    assert canary.decide(checks, 50, [10, 50, 100]) == ("PROMOTE", ["promote"])


@pytest.mark.parametrize(
    "canary_stats, same_scores, failing",
    [
        (stats(errors=0.2), True, "erreurs"),
        (stats(p95=150.0), True, "latence"),
        (stats(positive=0.85), True, "décisions"),
        (stats(), False, "scores"),
        (stats(up=0.0, requests=0), True, "observabilité"),  # mauvaise image : pas de /metrics
    ],
)
def test_canary_regressions_trigger_rollback(canary_stats, same_scores, failing):
    checks = run_checks(stats(), canary_stats, same_scores)
    assert [c["check"] for c in checks if c["status"] == "FAIL"] == [failing]
    assert canary.decide(checks, 10, [10, 50, 100]) == ("ROLLBACK", ["rollback"])


def test_canary_without_enough_traffic_waits():
    checks = run_checks(stats(), stats(requests=20))
    assert canary.decide(checks, 10, [10, 50, 100])[0] == "WAIT"


def test_score_psi_is_zero_for_identical_histograms():
    hist = {0.5: 40.0, 1.0: 80.0, float("inf"): 100.0}
    assert canary.score_psi(hist, hist) == pytest.approx(0.0)
