# Fichier : monitoring/canary_analysis.py
"""Analyse d'un canary KServe par les métriques : promouvoir, attendre ou annuler.

Pendant un canary (canaryTrafficPercent du Lab 6), deux révisions Knative servent le
trafic : la stable (« prev ») et la nouvelle (« latest »). Le PodMonitor du Lab 7 ajoute
le label « revision » à toutes les métriques de l'API : on compare donc les deux versions
sur la même fenêtre, avec les mêmes requêtes PromQL.

Garde-fous (tous doivent passer pour avancer) :
  0. observabilité : Prometheus scrape bien le canary (une version muette ne passe pas) ;
  1. volume    : assez de requêtes des deux côtés pour conclure ;
  2. erreurs   : taux de 5xx du canary <= max(1 %, 2 x celui de la stable) ;
  3. latence   : P95 du canary <= SLO et pas franchement plus lent que la stable ;
  4. scores    : distribution des scores proche de la stable (PSI < 0,25) ;
  5. décisions : taux de décisions positives (refus) à moins de 10 points de la stable.

Décision : ROLLBACK si un garde-fou échoue, WAIT s'il manque des données, sinon étape
suivante du canary (10 -> 50 -> 100 %). La décision est écrite dans reports/m7/ et
appliquée par Git (--apply) avec l'outil GitOps du Lab 6 : pipelines/gitops.py.

Usage (depuis la racine du repo, Prometheus accessible sur localhost:9090) :
  uv run python monitoring/canary_analysis.py
  uv run python monitoring/canary_analysis.py --apply --push
Code retour : 0 = avancer/promouvoir, 1 = rollback, 2 = attendre (données insuffisantes).
"""

import argparse
import json
import math
import re
import shutil
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path

import httpx

ROOT = Path(__file__).resolve().parents[1]
CANARY_FILE = ROOT / "k8s" / "overlays" / "prod" / "canary.yaml"  # Lab 6


def parse_args(argv=None):
    p = argparse.ArgumentParser(description="Analyse d'un canary KServe par les métriques")
    p.add_argument("--prometheus", default="http://localhost:9090")
    p.add_argument("--namespace", default="scoring")
    p.add_argument("--isvc", default="scoring-model")
    p.add_argument("--window", default="5m", help="fenêtre d'analyse PromQL (ex. 10m)")
    p.add_argument("--stable", help="révision stable (sinon : statut de l'ISVC)")
    p.add_argument("--canary", help="révision canary (sinon : statut de l'ISVC)")
    p.add_argument("--isvc-json", help="statut de l'ISVC (kubectl get isvc -o json) déjà exporté")
    p.add_argument("--steps", default="10,50,100", help="paliers du canary, en %%")
    p.add_argument("--min-requests", type=int, default=100)
    p.add_argument("--max-error-rate", type=float, default=0.01)
    p.add_argument("--latency-slo", type=float, default=0.2, help="P95 maximal, en secondes")
    p.add_argument("--max-latency-ratio", type=float, default=1.5)
    p.add_argument("--max-score-psi", type=float, default=0.25)
    p.add_argument("--max-positive-rate-delta", type=float, default=0.10)
    p.add_argument("--out", default="reports/m7/canary-analysis", help="relatif à la racine")
    p.add_argument("--apply", action="store_true", help="appliquer la décision (commit Git)")
    p.add_argument("--push", action="store_true", help="avec --apply : pousser le commit")
    return p.parse_args(argv)


class Prometheus:
    def __init__(self, url: str):
        self.client = httpx.Client(base_url=url, timeout=15.0)

    def vector(self, expr: str) -> list[tuple[dict, float]]:
        r = self.client.get("/api/v1/query", params={"query": expr})
        r.raise_for_status()
        data = r.json()["data"]
        return [(s["metric"], float(s["value"][1])) for s in data["result"]]

    def by_revision(self, expr: str) -> dict[str, float]:
        return {m.get("revision", ""): v for m, v in self.vector(expr)}


def traffic_from_isvc(args) -> tuple[str | None, str | None, int | None]:
    """(stable, canary, % canary) d'après status.components.predictor.traffic."""
    if args.isvc_json:
        status = json.loads(Path(args.isvc_json).read_text())
    elif shutil.which("kubectl"):
        out = subprocess.run(
            ["kubectl", "get", "isvc", args.isvc, "-n", args.namespace, "-o", "json"],
            capture_output=True,
            text=True,
            timeout=20,
        )
        if out.returncode != 0:
            return None, None, None
        status = json.loads(out.stdout)
    else:
        return None, None, None
    traffic = status.get("status", {}).get("components", {}).get("predictor", {}).get("traffic", [])
    latest = next((t for t in traffic if t.get("latestRevision")), None)
    prev = next((t for t in traffic if not t.get("latestRevision")), None)
    canary = latest["revisionName"] if latest and prev else None
    stable = prev["revisionName"] if prev else (latest or {}).get("revisionName")
    return stable, canary, (latest or {}).get("percent") if prev else None


def percent_from_git() -> int | None:
    if CANARY_FILE.exists():
        m = re.search(r"canaryTrafficPercent:\s*(\d+)", CANARY_FILE.read_text())
        return int(m.group(1)) if m else None
    return None


def score_psi(stable: dict[float, float], canary: dict[float, float]) -> float:
    """PSI entre deux histogrammes Prometheus (compteurs cumulés par borne « le »)."""

    def proportions(cumulative: dict[float, float]) -> list[float]:
        bounds = sorted(cumulative)
        counts = [
            cumulative[b] - (cumulative[bounds[i - 1]] if i else 0.0) for i, b in enumerate(bounds)
        ]
        total = sum(counts) or 1.0
        return [max(c / total, 1e-4) for c in counts]  # lissage : pas de log(0)

    ps, pc = proportions(stable), proportions(canary)
    return sum((c - s) * math.log(c / s) for s, c in zip(ps, pc, strict=True))


def collect(prom: Prometheus, sel: str, window: str, revisions: list[str]) -> dict:
    """Mesures par révision sur la fenêtre (PromQL lisible dans le rapport)."""

    def increase(metric: str, extra: str = "") -> str:
        return f"sum by (revision) (increase({metric}{{{sel}{extra}}}[{window}]))"

    predict = ',handler="/predict"'
    queries = {
        "requests": increase("http_requests_total", predict),
        "errors": increase("http_requests_total", predict + ',code=~"5.."'),
        "predictions": increase("ml_predictions_total"),
        "positives": increase("ml_predictions_total", ',outcome="1"'),
        "score_sum": increase("ml_prediction_score_sum"),
        "p95_seconds": "histogram_quantile(0.95, sum by (revision, le) "
        f"(rate(ml_inference_latency_seconds_bucket{{{sel}}}[{window}])))",
    }
    raw = {name: prom.by_revision(q) for name, q in queries.items()}
    buckets_q = f"sum by (revision, le) (increase(ml_prediction_score_bucket{{{sel}}}[{window}]))"
    buckets: dict[str, dict[float, float]] = {}
    for m, v in prom.vector(buckets_q):
        buckets.setdefault(m.get("revision", ""), {})[float(m["le"])] = v
    info_q = f"max by (revision, model_version, api_version, threshold) (ml_model_info{{{sel}}})"
    info = {m.get("revision", ""): m for m, _ in prom.vector(info_q)}

    stats = {}
    for rev in revisions:
        n = raw["predictions"].get(rev, 0.0)
        req = raw["requests"].get(rev, 0.0)
        p95 = raw["p95_seconds"].get(rev, float("nan"))
        stats[rev] = {
            "model_version": info.get(rev, {}).get("model_version"),
            "api_version": info.get(rev, {}).get("api_version"),
            "threshold": info.get(rev, {}).get("threshold"),
            "requests": round(req),
            "predictions": round(n),
            "error_rate": raw["errors"].get(rev, 0.0) / req if req else 0.0,
            "p95_ms": None if math.isnan(p95) else round(p95 * 1000, 1),
            "positive_rate": raw["positives"].get(rev, 0.0) / n if n else None,
            "mean_score": raw["score_sum"].get(rev, 0.0) / n if n else None,
        }
    up_q = f"max by (revision) (up{{{sel}}})"
    up = prom.by_revision(up_q)
    for rev in revisions:
        stats[rev]["up"] = up.get(rev)  # None : aucune cible (révision pas encore prête)
    queries["score_buckets"] = buckets_q
    queries["model_info"] = info_q
    queries["up"] = up_q
    return {"stats": stats, "buckets": buckets, "queries": queries}


def evaluate(args, stable: str, canary: str, data: dict) -> list[dict]:
    s, c = data["stats"][stable], data["stats"][canary]
    checks = []

    def check(name, ok, detail, enough=True):
        status = "PASS" if ok else "FAIL"
        checks.append({"check": name, "status": status if enough else "WAIT", "detail": detail})

    if c.get("up") is None:
        check("observabilité", False, "aucune cible Prometheus pour le canary (pas prêt ?)", False)
    else:
        check(
            "observabilité",
            c["up"] == 1,
            "métriques du canary scrapées (up=1)"
            if c["up"] == 1
            else "canary non scrapé (up=0) : /metrics absent ou en erreur",
        )
    # Volume compté en requêtes (et non en prédictions) : un canary qui ne renvoie que
    # des 500 n'a aucune prédiction, mais il doit être annulé, pas attendu.
    enough = min(s["requests"], c["requests"]) >= args.min_requests
    check(
        "volume",
        enough,
        f"stable {s['requests']} / canary {c['requests']} "
        f"requêtes /predict (minimum {args.min_requests})",
        enough,
    )
    max_err = max(args.max_error_rate, 2 * s["error_rate"])
    check(
        "erreurs",
        c["error_rate"] <= max_err,
        f"5xx canary {c['error_rate']:.2%} (stable {s['error_rate']:.2%}, max {max_err:.2%})",
        enough,
    )
    if c["p95_ms"] is None or s["p95_ms"] is None:
        check("latence", False, "P95 indisponible (pas de trafic sur une révision ?)", False)
    else:
        # Plancher de 25 ms : à quelques ms, l'interpolation des buckets fait du bruit
        limit = max(args.max_latency_ratio * s["p95_ms"], s["p95_ms"] + 25.0)
        ok = c["p95_ms"] <= min(limit, args.latency_slo * 1000)
        check(
            "latence",
            ok,
            f"P95 canary {c['p95_ms']} ms (stable {s['p95_ms']} ms, max "
            f"{min(limit, args.latency_slo * 1000):.0f} ms)",
            enough,
        )
    if stable in data["buckets"] and canary in data["buckets"]:
        psi = score_psi(data["buckets"][stable], data["buckets"][canary])
        check(
            "scores",
            psi < args.max_score_psi,
            f"PSI des scores canary/stable {psi:.3f} (max {args.max_score_psi})",
            enough,
        )
    else:
        check("scores", False, "histogramme des scores indisponible", False)
    if c["positive_rate"] is None or s["positive_rate"] is None:
        check("décisions", False, "aucune décision sur une des révisions", False)
    else:
        delta = c["positive_rate"] - s["positive_rate"]
        check(
            "décisions",
            abs(delta) <= args.max_positive_rate_delta,
            f"taux de décision positive canary {c['positive_rate']:.1%} vs stable "
            f"{s['positive_rate']:.1%} (écart {delta:+.1%}, max "
            f"±{args.max_positive_rate_delta:.0%})",
            enough,
        )
    return checks


def decide(checks: list[dict], percent: int | None, steps: list[int]) -> tuple[str, list[str]]:
    if any(c["status"] == "FAIL" for c in checks):
        return "ROLLBACK", ["rollback"]
    if any(c["status"] == "WAIT" for c in checks):
        return "WAIT", []
    nxt = next((s for s in steps if percent is None or s > percent), 100)
    return ("PROMOTE", ["promote"]) if nxt >= 100 else ("CONTINUE", ["canary", str(nxt)])


def write_report(path: str, result: dict) -> None:
    out = ROOT / path  # un chemin absolu reste absolu
    out.parent.mkdir(parents=True, exist_ok=True)
    out.with_suffix(".json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    st, ca = result["stable"], result["canary"]
    lines = [
        "# Analyse du canary",
        "",
        f"- Date : {result['timestamp']} · fenêtre `{result['window']}` · "
        f"ISVC `{result['isvc']}` (namespace `{result['namespace']}`)",
        f"- Trafic canary : {result['canary_percent']} %",
        f"- **Décision : {result['decision']}**"
        + (f" → `{result['command']}`" if result["command"] else ""),
        "",
        "| Mesure | Stable | Canary |",
        "|---|---|---|",
        f"| Révision | `{st}` | `{ca}` |",
    ]

    def fmt(x) -> str:
        return "—" if x is None else f"{x:.3f}" if isinstance(x, float) else str(x)

    for key in (
        "model_version",
        "api_version",
        "threshold",
        "requests",
        "predictions",
        "error_rate",
        "p95_ms",
        "positive_rate",
        "mean_score",
    ):
        a, b = result["stats"][st][key], result["stats"][ca][key]
        lines.append(f"| {key} | {fmt(a)} | {fmt(b)} |")
    lines += ["", "| Garde-fou | Statut | Détail |", "|---|---|---|"]
    lines += [f"| {c['check']} | {c['status']} | {c['detail']} |" for c in result["checks"]]
    lines += ["", "Requêtes PromQL :", ""]
    lines += [f"- {k} : `{q}`" for k, q in result["queries"].items()]
    out.with_suffix(".md").write_text("\n".join(lines) + "\n")


def main(argv=None) -> int:
    args = parse_args(argv)
    stable, canary, percent = traffic_from_isvc(args)
    status_known = stable is not None
    stable, canary = args.stable or stable, args.canary or canary
    prom = Prometheus(args.prometheus)
    sel = f'namespace="{args.namespace}",isvc="{args.isvc}"'
    if not (stable and canary):
        # Sans statut de l'ISVC (pas de kubectl) : les deux révisions les plus récentes
        # vues par Prometheus (les noms Knative se terminent par un numéro croissant).
        query = f"max by (revision) (ml_model_info{{{sel}}})"
        seen = [] if status_known else sorted(prom.by_revision(query))
        if len(seen) < 2:
            print("Pas de canary en cours : une seule révision sert le trafic.")
            return 2
        stable, canary = seen[-2], seen[-1]
    if percent is None:
        percent = percent_from_git()
    print(f"Stable : {stable} · Canary : {canary} ({percent} % du trafic) · fenêtre {args.window}")

    data = collect(prom, sel, args.window, [stable, canary])
    checks = evaluate(args, stable, canary, data)
    steps = [int(s) for s in args.steps.split(",")]
    decision, gitops = decide(checks, percent, steps)
    command = f"uv run python -m pipelines.gitops {' '.join(gitops)}" if gitops else ""

    for c in checks:
        print(f"  [{c['status']:4s}] {c['check']:10s} {c['detail']}")
    print(f"Décision : {decision}" + (f" -> {command}" if command else " (relancer plus tard)"))
    result = {
        "timestamp": datetime.now(UTC).isoformat(timespec="seconds"),
        "namespace": args.namespace,
        "isvc": args.isvc,
        "window": args.window,
        "stable": stable,
        "canary": canary,
        "canary_percent": percent,
        "decision": decision,
        "command": command,
        "checks": checks,
        "stats": data["stats"],
        "queries": data["queries"],
    }
    write_report(args.out, result)
    print(f"Rapport : {Path(args.out).with_suffix('.md')}")

    if args.apply and gitops:
        cmd = [sys.executable, "-m", "pipelines.gitops", *gitops, *(["--push"] * args.push)]
        print("Application :", " ".join(cmd[1:]))
        subprocess.run(cmd, cwd=ROOT, check=True)
    return {"ROLLBACK": 1, "WAIT": 2}.get(decision, 0)


if __name__ == "__main__":
    raise SystemExit(main())
