# Fichier : pipelines/gitops.py
"""Changer ce qui tourne dans le cluster = faire un commit (Lab 6, GitOps avec Argo CD).

Le même outil sert à vous, à la CI (job deploy-staging), au bot du ré-entraînement
(pipelines/trigger_ct.py) et à l'analyse du canary du Lab 7. Depuis la racine du repo :

  status                              images de Git et versions réellement servies
  deploy --env staging --tag T [--image N]       nouvelle image en staging
  deploy --env prod [--canary 10]     l'image de staging part en prod, en canary
  canary P · promote · rollback       part du trafic de la nouvelle révision en prod
                                      (promote = 100 ; rollback = 0 et @champion restauré)
  release [--local-ci]                après un ré-entraînement : modèle -> Git -> CI ->
                                      staging -> canary prod -> promotion (ou retour arrière)
  local-ci                            sans GitHub Actions : build local + push localhost:5001
                                      + tag de staging (les jobs build et deploy-staging)
  payload                             corps /predict synthétique, construit depuis dataset.yaml

Chaque commande fait UN commit ; --push le pousse (après git pull --rebase), depuis main
uniquement : l'outil refuse de partir d'une branche de travail lab/* ou ext/*.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
from collections.abc import Callable, Iterator
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
OVERLAYS = {
    "staging": Path("k8s/overlays/staging/kustomization.yaml"),
    "prod": Path("k8s/overlays/prod/kustomization.yaml"),
}
CANARY = Path("k8s/overlays/prod/canary.yaml")  # spec.predictor.canaryTrafficPercent
NAMESPACES = {"staging": "scoring-staging", "prod": "scoring"}
ISVC = "scoring-model"
MODEL_NAME = "scoring-model"
CI_WORKFLOW = Path(".github/workflows/ci.yml")
REMOTE = os.getenv("GITOPS_REMOTE", "origin")  # le dépôt lu par Argo CD (votre fork)
BRANCH = os.getenv("GITOPS_BRANCH", "main")
GATEWAY = os.getenv("GATEWAY", "http://localhost:30080")  # passerelle Kourier (Lab 5)
DOMAIN = os.getenv("KNATIVE_DOMAIN", "example.com")
REGISTRY = os.getenv("REGISTRY", "localhost:5001")  # mode --local-ci


# --- Les fichiers de Git -----------------------------------------------------------------
def read_image(root: Path, env: str) -> tuple[str, str]:
    """(newName, newTag) de l'overlay de l'environnement."""
    data = yaml.safe_load((root / OVERLAYS[env]).read_text(encoding="utf-8"))
    image = next(i for i in data["images"] if i["name"] == "scoring-api")
    return image["newName"], str(image["newTag"])


def set_image(root: Path, env: str, name: str, tag: str) -> None:
    """Réécrit newName/newTag en gardant le reste du fichier (commentaires compris)."""
    path = root / OVERLAYS[env]
    text = path.read_text(encoding="utf-8")
    text = re.sub(r"(?m)^(\s*newName:).*$", rf"\g<1> {name}", text, count=1)
    text = re.sub(r"(?m)^(\s*newTag:).*$", rf'\g<1> "{tag}"', text, count=1)
    path.write_text(text, encoding="utf-8")
    if read_image(root, env) != (name, tag):
        raise SystemExit(f"{path} : newName/newTag introuvables")


def read_canary(root: Path) -> int:
    data = yaml.safe_load((root / CANARY).read_text(encoding="utf-8"))
    return int(data["spec"]["predictor"]["canaryTrafficPercent"])


def set_canary(root: Path, percent: int) -> None:
    if not 0 <= percent <= 100:
        raise SystemExit("La part du canary est un entier entre 0 et 100")
    path = root / CANARY
    text = re.sub(
        r"(?m)^(\s*canaryTrafficPercent:).*$",
        rf"\g<1> {percent}",
        path.read_text(encoding="utf-8"),
        count=1,
    )
    path.write_text(text, encoding="utf-8")
    if read_canary(root) != percent:
        raise SystemExit(f"{path} : canaryTrafficPercent introuvable")


def ci_api_version(root: Path = ROOT) -> str:
    """Version d'API (MAJEUR.MINEUR) déclarée dans le workflow : env.API_VERSION."""
    workflow = yaml.safe_load((root / CI_WORKFLOW).read_text(encoding="utf-8"))
    return str(workflow["env"]["API_VERSION"])


# --- Git ---------------------------------------------------------------------------------
def git(root: Path, *args: str) -> str:
    out = subprocess.run(["git", *args], cwd=root, check=True, capture_output=True, text=True)
    return out.stdout.strip()


def ensure_clean(root: Path) -> None:
    """Refuse de mélanger un commit GitOps avec des modifications en cours des overlays."""
    if git(root, "status", "--porcelain", "--", "k8s/overlays"):
        print("k8s/overlays/ a des modifications non commitées : commitez-les d'abord.")
        sys.exit(2)


def ensure_not_work_branch(root: Path) -> None:
    """Une opération poussée part de main, jamais d'une branche de travail (lab/*, ext/*).

    push() rejoue la branche courante sur origin/main puis pousse HEAD : depuis une branche de
    travail, ses commits partiraient sur main sans pull request ni relecture.
    """
    branch = git(root, "rev-parse", "--abbrev-ref", "HEAD")
    if branch.startswith(("lab/", "ext/")):
        print(f"Branche {branch} : les opérations GitOps poussées partent de {BRANCH}.")
        print(f"  git switch {BRANCH} && git pull    puis relancez la commande.")
        sys.exit(2)


def push(root: Path) -> None:
    """git push, après avoir rejoué notre commit sur les commits des autres (CI, bot)."""
    for attempt in range(3):
        git(root, "pull", "--rebase", "--autostash", "--quiet", REMOTE, BRANCH)
        try:
            git(root, "push", "--quiet", REMOTE, f"HEAD:{BRANCH}")
            return
        except subprocess.CalledProcessError:
            time.sleep(2 * (attempt + 1))  # quelqu'un a poussé entre-temps : on recommence
    raise SystemExit("git push refusé 3 fois : voir git status")


def commit(root: Path, paths: list[Path], message: str, do_push: bool) -> None:
    if not git(root, "status", "--porcelain", "--", *map(str, paths)):
        print(f"Rien à changer ({message})")
        return
    git(root, "add", "--", *map(str, paths))
    git(root, "commit", "--quiet", "-m", message)
    if do_push:
        push(root)
    where = f"{REMOTE}/{BRANCH} (Argo CD l'appliquera)" if do_push else "local (pas poussé)"
    print(f"[{git(root, 'rev-parse', '--short', 'HEAD')}] {message} -> {where}")


@contextlib.contextmanager
def worktree(root: Path = ROOT) -> Iterator[Path]:
    """Copie de travail jetable sur origin/main : le bot ne touche jamais à la vôtre."""
    git(root, "fetch", "--quiet", REMOTE, BRANCH)
    path = Path(tempfile.mkdtemp(prefix="gitops-"))
    git(root, "worktree", "add", "--quiet", "--detach", str(path), f"{REMOTE}/{BRANCH}")
    try:
        yield path
    finally:
        git(root, "worktree", "remove", "--force", str(path))


# --- Les commandes de déploiement --------------------------------------------------------
def deploy(root: Path, env: str, name: str | None, tag: str | None, canary: int, do_push: bool,
           note: str = "") -> None:  # fmt: skip
    """Nouvelle image dans un environnement ; en prod, avec la part de canary demandée."""
    if env == "prod" and not tag:
        name, tag = read_image(root, "staging")  # on promeut ce que staging a validé
    if not tag:
        raise SystemExit("--tag est obligatoire pour staging")
    name = name or read_image(root, env)[0]
    set_image(root, env, name, tag)
    paths = [OVERLAYS[env]]
    if env == "prod":
        set_canary(root, canary)
        paths.append(CANARY)
        message = f"gitops(prod): canary {canary}% {tag}"
    else:
        message = f"gitops(staging): {name}:{tag}"
    commit(root, paths, f"{message} {note}".strip(), do_push)


def canary(root: Path, percent: int, do_push: bool, label: str = "canary") -> None:
    set_canary(root, percent)
    tag = read_image(root, "prod")[1]
    commit(root, [CANARY], f"gitops(prod): {label} {percent}% {tag}", do_push)


def restore_champion(canary_model: str | None) -> None:
    """Rollback côté Registry : @champion revient à la version notée par la gate…

    … seulement si le canary retiré servait bien le @champion actuel (sortie d'un modèle).
    Un canary « image seule » (même modèle, nouveau code) ne touche pas au Registry.
    """
    from mlflow import MlflowClient

    client = MlflowClient()
    current = client.get_model_version_by_alias(MODEL_NAME, "champion")
    if canary_model != current.version:
        print(f"Canary (modèle v{canary_model}) ≠ @champion v{current.version} : alias inchangé")
        return
    previous = current.tags.get("previous_champion", "none")
    if previous == "none":
        print(f"@champion v{current.version} : aucune version précédente notée, inchangé")
        return
    client.set_registered_model_alias(MODEL_NAME, "champion", previous)
    client.set_model_version_tag(MODEL_NAME, current.version, "promotion", "rolled_back")
    print(f"@champion : v{current.version} -> v{previous} (v{current.version} rolled_back)")


# --- Ce que le cluster sert réellement (passerelle Kourier du Lab 5) ---------------------
def host(env: str, route: str = "") -> str:
    """Nom d'hôte Knative ; route « latest- » = nouvelle révision, « prev- » = précédente."""
    return f"{route}{ISVC}-predictor.{NAMESPACES[env]}.{DOMAIN}"


def call(env: str, path: str, body: dict | None = None, route: str = "", timeout=10) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Host": host(env, route), "Content-Type": "application/json"}
    req = urllib.request.Request(f"{GATEWAY}{path}", data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def served(env: str, route: str = "") -> dict | None:
    """/version servi, ou None si le service ne répond pas (encore)."""
    try:
        return call(env, "/version", route=route, timeout=60)  # 60 s : réveil scale-to-zero
    except (OSError, ValueError):
        return None


def payload(n: int = 1) -> dict:
    """Corps /predict valide pour TOUT dataset : colonnes et types lus dans dataset.yaml."""
    sys.path.insert(0, str(ROOT))
    from src.dataset_config import load_config

    cfg = load_config(ROOT / "dataset.yaml")
    row = {c: 1.0 for c in cfg.numeric} | {c: "inconnu" for c in cfg.categorical}
    return {"instances": [row] * n}


def smoke(env: str, route: str = "", n: int = 1) -> bool:
    """n prédictions : réponses 200 et probabilités dans [0, 1]."""
    try:
        for _ in range(n):
            preds = call(env, "/predict", payload(), route=route)["predictions"]
            if not all(0.0 <= p["probability"] <= 1.0 for p in preds):
                return False
        return True
    except (OSError, ValueError, KeyError):  # injoignable, erreur HTTP, réponse inattendue
        return False


def wait_for(what: str, check: Callable[[], object], timeout: int, every: int = 10):
    print(f"… {what} (au plus {timeout // 60} min)", flush=True)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(every)
    raise SystemExit(f"Délai dépassé : {what}")


def status(root: Path) -> None:
    for env in ("staging", "prod"):
        name, tag = read_image(root, env)
        extra = f" · canary {read_canary(root)} %" if env == "prod" else ""
        print(f"{env:8} Git : {name}:{tag}{extra}")
        for route in ("", "latest-", "prev-") if env == "prod" else ("",):
            print(f"{'':8} servi{f' ({route[:-1]})' if route else ''} : {served(env, route)}")


# --- La chaîne complète après un ré-entraînement -----------------------------------------
def export_champion(root: Path) -> str:
    """Exporte @champion en ONNX dans packaging/model/ (script du Lab 4) ; renvoie sa version."""
    subprocess.run([sys.executable, "packaging/app/export_onnx.py"], cwd=root, check=True)
    meta = json.loads((root / "packaging/model/metadata.json").read_text(encoding="utf-8"))
    return str(meta["model_version"])


def wait_ci(root: Path, model_sha: str, timeout: int) -> str:
    """Attend le commit de la CI (job deploy-staging) qui suit le nôtre ; renvoie le tag."""

    def staged() -> str | None:
        git(root, "fetch", "--quiet", REMOTE, BRANCH)
        log = git(root, "log", "--format=%H %s", f"{model_sha}..{REMOTE}/{BRANCH}", "--",
                  str(OVERLAYS["staging"]))  # fmt: skip
        for line in log.splitlines():
            sha, subject = line.split(" ", 1)
            if model_sha[:7] in subject:  # la CI cite le commit qu'elle a construit
                text = git(root, "show", f"{sha}:{OVERLAYS['staging']}")
                image = next(i for i in yaml.safe_load(text)["images"])
                return str(image["newTag"])
        return None

    return wait_for(f"CI GitHub Actions du commit {model_sha[:7]}", staged, timeout, every=20)


def local_ci(root: Path, model_sha: str, model_version: str, do_push: bool) -> str:
    """Sans GitHub Actions (hors ligne, e2e) : build + push vers le registry local."""
    count = git(root, "rev-list", "--count", "HEAD")
    tag = f"{ci_api_version(root)}.{count}"
    image = f"{REGISTRY}/scoring-api"
    build_args = ["--build-arg", f"VERSION={tag}", "--build-arg", f"MODEL_VERSION={model_version}"]
    subprocess.run(["docker", "build", "-q", "-f", "packaging/Dockerfile", *build_args,
                    "-t", f"{image}:{tag}", "."], cwd=root, check=True)  # fmt: skip
    subprocess.run(["docker", "push", "-q", f"{image}:{tag}"], check=True)
    deploy(root, "staging", image, tag, 0, do_push, note=f"[{model_sha[:7]}]")  # comme la CI
    return tag


def naive_analysis(n: int = 50) -> bool:
    """Analyse minimale du canary : la nouvelle révision répond-elle correctement ?

    Le Lab 7 la remplace par une vraie comparaison de métriques (Prometheus).
    """
    return smoke("prod", route="latest-", n=n)


def release(local: bool, auto_promote: bool, percent: int, timeout: int, note: str = "") -> None:
    with worktree() as wt:
        version = export_champion(wt)
        commit(wt, [Path("packaging/model")], f"ct: scoring-model v{version} {note}".strip(), True)
        model_sha = git(wt, "rev-parse", "HEAD")
        if local:
            tag = local_ci(wt, model_sha, version, do_push=True)
        else:
            tag = wait_ci(wt, model_sha, timeout)
    print(f"Image {tag} (modèle v{version}) en staging")

    def staging_ready() -> bool:
        info = served("staging")
        return bool(info and info.get("version") == tag and smoke("staging"))

    wait_for(f"staging sert {tag}", staging_ready, timeout)
    with worktree() as wt:
        deploy(wt, "prod", None, None, percent, do_push=True)

    def canary_ready() -> bool:
        info = served("prod", route="latest-")
        return bool(info and info.get("version") == tag)

    wait_for(f"canary {percent} % de {tag} en prod", canary_ready, timeout)
    if not auto_promote:
        print("Canary en place : décision laissée à l'analyse (Lab 7) : promote ou rollback")
        return
    ok = naive_analysis()
    with worktree() as wt:
        canary(wt, 100 if ok else 0, do_push=True, label="promote" if ok else "rollback")
    if not ok:
        restore_champion(version)
    print(f"{tag} {'promue à 100 %' if ok else 'retirée (rollback)'}")


# --- Ligne de commande -------------------------------------------------------------------
def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    sub.add_parser("payload")
    p_deploy = sub.add_parser("deploy")
    p_deploy.add_argument("--env", choices=list(OVERLAYS), required=True)
    p_deploy.add_argument("--image", help="newName (défaut : celui de l'overlay / de staging)")
    p_deploy.add_argument("--tag", help="newTag (prod : défaut = le tag de staging)")
    p_deploy.add_argument("--canary", type=int, default=10, help="prod : part du canary")
    p_deploy.add_argument("--note", default="", help="ajouté au message de commit")
    p_canary = sub.add_parser("canary")
    p_canary.add_argument("percent", type=int)
    sub.add_parser("promote")
    sub.add_parser("rollback")
    p_release = sub.add_parser("release")
    p_release.add_argument("--local-ci", action="store_true", help="docker build local")
    p_release.add_argument("--no-auto-promote", action="store_true")
    p_release.add_argument("--canary", type=int, default=10)
    p_release.add_argument("--timeout", type=int, default=1800, help="secondes par attente")
    sub.add_parser("local-ci")
    for p in (p_deploy, p_canary, *(sub.choices[c] for c in ("promote", "rollback", "local-ci"))):
        p.add_argument("--push", action="store_true", help="pousser le commit sur origin")
    args = parser.parse_args(argv)

    if args.cmd == "payload":
        print(json.dumps(payload()))
    elif args.cmd == "status":
        status(ROOT)
    elif args.cmd == "release":
        release(args.local_ci, not args.no_auto_promote, args.canary, args.timeout)
    else:
        ensure_clean(ROOT)
        if args.push:
            ensure_not_work_branch(ROOT)
        if args.cmd == "deploy":
            deploy(ROOT, args.env, args.image, args.tag, args.canary, args.push, args.note)
        elif args.cmd == "canary":
            canary(ROOT, args.percent, args.push)
        elif args.cmd == "promote":
            canary(ROOT, 100, args.push, label="promote")
        elif args.cmd == "rollback":
            retired = served("prod", route="latest-") or {}  # le modèle du canary retiré
            canary(ROOT, 0, args.push, label="rollback")
            restore_champion(retired.get("model_version"))
        elif args.cmd == "local-ci":
            meta = json.loads((ROOT / "packaging/model/metadata.json").read_text(encoding="utf-8"))
            sha = git(ROOT, "rev-parse", "HEAD")
            print(local_ci(ROOT, sha, str(meta["model_version"]), args.push))


if __name__ == "__main__":
    main()
