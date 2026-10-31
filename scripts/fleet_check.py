#!/usr/bin/env python3
"""Fleet checks that YAML linters and kubeconform cannot do.

  scripts/fleet_check.py                       check, print the generated Applications
  scripts/fleet_check.py --json out.json       also write the plan as JSON
  scripts/fleet_check.py --compare base.json   print what a change adds/removes vs. base
  git diff --name-only A B | scripts/fleet_check.py --affected
                                               list the Applications those files feed (JSON)

What it checks
  clusters/*.yaml        required fields, name == file name, unique names and
                         servers, an add-on overlay exists for the environment
  products/*/product.yaml  schema (products/schema.json), name == folder,
                         unique names, every environment matches at least one
                         cluster, the config folder exists for every
                         environment, the owner team owns the product's folders
                         in .github/CODEOWNERS
  applicationsets/*.yaml  simulates the generators this repo uses (git files,
                         list, matrix, clusters) and fails on duplicate
                         Application names

The simulation mirrors how Argo CD will expand the ApplicationSets, using the
cluster labels Terraform derives from clusters/*.yaml. It is a preview, not
Argo CD itself: anything it cannot evaluate is reported, never guessed.

Needs PyYAML and jsonschema (pip install pyyaml jsonschema).
"""
from __future__ import annotations

import argparse
import fnmatch
import glob
import json
import os
import re
import sys
from pathlib import Path

try:
    import yaml
    import jsonschema
except ImportError:  # pragma: no cover
    sys.exit("fleet_check.py needs PyYAML and jsonschema: pip install pyyaml jsonschema")

ROOT = Path(__file__).resolve().parent.parent
errors: list[str] = []
warnings: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)


def load_yaml(path: Path):
    try:
        return yaml.safe_load(path.read_text())
    except yaml.YAMLError as e:
        err(f"{path.relative_to(ROOT)}: invalid YAML: {e}")
        return None


def norm_url(url: str) -> str:
    url = re.sub(r"^(https?://|git@)", "", url.strip()).replace(":", "/")
    return re.sub(r"(\.git)?/?$", "", url).lower()


# --------------------------------------------------------------------------
# Inventory
# --------------------------------------------------------------------------
CLUSTER_FIELDS = ["name", "provider", "server", "environment", "upgradeWave", "region"]


def load_inventory() -> dict[str, dict]:
    inv: dict[str, dict] = {}
    if not (ROOT / "clusters").is_dir():
        return inv  # the course adds clusters/ in module 01
    servers: dict[str, str] = {}
    for f in sorted((ROOT / "clusters").glob("*.yaml")):
        rel = f.relative_to(ROOT)
        c = load_yaml(f)
        if not isinstance(c, dict):
            err(f"{rel}: expected a mapping")
            continue
        for k in CLUSTER_FIELDS:
            if k not in c or c[k] in (None, ""):
                err(f"{rel}: missing field '{k}'")
        name = str(c.get("name", ""))
        if name and name != f.stem:
            err(f"{rel}: name '{name}' must match the file name '{f.stem}'")
        if name in inv:
            err(f"{rel}: duplicate cluster name '{name}'")
        server = str(c.get("server", ""))
        if server in servers:
            err(f"{rel}: server {server} is also used by {servers[server]}")
        servers[server] = str(rel)
        if c.get("provider") == "kind" and server != f"https://{name}-control-plane:6443":
            err(f"{rel}: kind clusters must use server https://{name}-control-plane:6443")
        env = c.get("environment")
        for addon in ("namespaces", "kyverno-policies"):
            if env and (ROOT / "addons" / addon).is_dir() and not (ROOT / "addons" / addon / "overlays" / str(env)).is_dir():
                err(f"{rel}: environment '{env}' has no addons/{addon}/overlays/{env}")
        inv[name or f.stem] = c
    if not inv:
        err("clusters/: no clusters in the inventory")
    return inv


REFERENCE = "github.com/platformengr/fleet-gitops"


def check_repo_urls(repo_url: str) -> None:
    """The #1 workshop snag: a manifest still points at the reference repo, so
    Argo CD reads someone else's Git and your pushes change nothing."""
    if not repo_url or norm_url(repo_url) == REFERENCE:
        return
    for f in sorted([ROOT / "root-app.yaml", *(ROOT / "applicationsets").glob("*.yaml"),
                     *(ROOT / "products").glob("*/product.yaml")]):
        if f.exists() and REFERENCE in f.read_text().lower():
            err(f"{f.relative_to(ROOT)}: still points at {REFERENCE}; run scripts/set-repo-url.sh")


def cluster_labels(c: dict) -> dict[str, str]:
    """The labels Terraform (infrastructure/kind) and the cloud scripts put on the Argo CD cluster Secret."""
    return {
        "argocd.argoproj.io/secret-type": "cluster",
        "fleet.gitops/name": str(c.get("name")),
        "fleet.gitops/environment": str(c.get("environment")),
        "fleet.gitops/region": str(c.get("region")),
        "fleet.gitops/upgrade-wave": str(c.get("upgradeWave")),
    }


# --------------------------------------------------------------------------
# Products
# --------------------------------------------------------------------------
def load_codeowners() -> list[tuple[str, list[str]]]:
    path = ROOT / ".github" / "CODEOWNERS"
    rules = []
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                parts = line.split()
                rules.append((parts[0], parts[1:]))
    return rules


def owner_rule(path: str, rules) -> tuple[str, list[str]]:
    """The CODEOWNERS rule that applies to path: the last match wins (GitHub
    semantics, simplified to folder prefixes and globs)."""
    found: tuple[str, list[str]] = ("", [])
    for pattern, owners in rules:
        p = pattern.lstrip("/")
        if (p.endswith("/") and path.startswith(p)) or fnmatch.fnmatch(path, p) or p == "*":
            found = (pattern, owners)
    return found


def load_products(inv: dict[str, dict], repo_url: str) -> dict[str, dict]:
    if not (ROOT / "products" / "schema.json").exists():
        return {}
    schema = json.loads((ROOT / "products" / "schema.json").read_text())
    validator = jsonschema.Draft202012Validator(schema)
    envs_in_fleet = {str(c.get("environment")) for c in inv.values()}
    codeowners = load_codeowners()
    products: dict[str, dict] = {}
    for f in sorted((ROOT / "products").glob("*/product.yaml")):
        rel = f.relative_to(ROOT)
        doc = load_yaml(f)
        if doc is None:
            continue
        schema_errors = sorted(validator.iter_errors(doc), key=lambda e: list(e.path))
        for e in schema_errors:
            where = ".".join(str(p) for p in e.path) or "(top level)"
            err(f"{rel}: {where}: {e.message}")
        if schema_errors:
            continue
        p = doc["product"]
        name = p["name"]
        if name != f.parent.name:
            err(f"{rel}: product.name '{name}' must match the folder name '{f.parent.name}'")
        if name in products:
            err(f"{rel}: duplicate product name '{name}'")
        seen = set()
        for e in p["environments"]:
            env = e["environment"]
            if env in seen:
                err(f"{rel}: environment '{env}' is listed twice")
            seen.add(env)
            if env not in envs_in_fleet:
                err(f"{rel}: environment '{env}' matches no cluster "
                    f"(clusters/*.yaml environments: {', '.join(sorted(envs_in_fleet))})")
            if norm_url(p["repository"]) == norm_url(repo_url):
                cfg = ROOT / p["path"] / env
                if not (cfg / "kustomization.yaml").exists():
                    err(f"{rel}: {p['path']}/{env}/kustomization.yaml does not exist")
        if norm_url(p["repository"]) == norm_url(repo_url):
            for folder in (f"products/{name}/", f"{p['path'].rstrip('/')}/"):
                pattern, owners = owner_rule(folder, codeowners)
                teams = [o for o in owners if "/" in o]
                if pattern in ("", "*") or (teams and not any(t.lower().endswith("/" + p["owner"].lower()) for t in teams)):
                    err(f"{rel}: .github/CODEOWNERS needs a rule giving /{folder} to the owner "
                        f"'{p['owner']}' (currently: {' '.join(owners) or 'nobody'} via '{pattern or 'no rule'}')")
        products[name] = doc
    return products


# --------------------------------------------------------------------------
# ApplicationSet simulation
# --------------------------------------------------------------------------
class Unsupported(Exception):
    pass


def lookup(params: dict, dotted: str):
    cur = params
    for part in dotted.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return None
    return cur


_EXPR = re.compile(r"\{\{-?\s*(.*?)\s*-?\}\}")


def eval_expr(expr: str, params: dict, go: bool):
    """Evaluates the small subset of template expressions this repo uses."""
    stages = [s.strip() for s in expr.split("|")]
    head = stages[0]
    m = re.fullmatch(r'default\s+"([^"]*)"\s+\.([\w.]+)', head)
    if m:
        v = lookup(params, m.group(2))
        val = m.group(1) if v in (None, "") else v
    elif re.fullmatch(r'trimSuffix\s+"([^"]*)"\s+\.([\w.]+)', head):
        m = re.fullmatch(r'trimSuffix\s+"([^"]*)"\s+\.([\w.]+)', head)
        v = str(lookup(params, m.group(2)) or "")
        val = v[: -len(m.group(1))] if m.group(1) and v.endswith(m.group(1)) else v
    elif go and head.startswith("."):
        val = lookup(params, head[1:])
    elif not go and re.fullmatch(r"[\w.\-]+", head):
        val = params.get(head, lookup(params, head))
    else:
        raise Unsupported(expr)
    for fn in stages[1:]:
        if fn == "toJson":
            val = json.dumps(val)
        elif fn == "quote":
            val = json.dumps("" if val is None else str(val))
        elif fn == "lower":
            val = str(val).lower()
        else:
            raise Unsupported(expr)
    if val is None:
        raise Unsupported(f"{expr} (no such parameter)")
    return val


def render(s, params: dict, go: bool):
    if isinstance(s, str):
        return _EXPR.sub(lambda m: str(eval_expr(m.group(1), params, go)), s)
    if isinstance(s, dict):
        return {k: render(v, params, go) for k, v in s.items()}
    if isinstance(s, list):
        return [render(v, params, go) for v in s]
    return s


def flatten(d: dict, prefix: str = "") -> dict:
    """Non-goTemplate ApplicationSets see nested keys as dotted names."""
    out = {}
    for k, v in d.items():
        key = f"{prefix}{k}"
        if isinstance(v, dict):
            out.update(flatten(v, key + "."))
        else:
            out[key] = v
    return out


def merge_params(a: dict, b: dict, where: str) -> dict:
    out = dict(a)
    for k, v in b.items():
        if k in out and out[k] != v:
            raise ValueError(f"{where}: matrix children both produce '{k}' with different values")
        out[k] = v
    return out


def gen_params(gen: dict, inv: dict, go: bool, inherited: dict, where: str) -> list[dict]:
    if "git" in gen:
        g = gen["git"]
        if "files" not in g:
            raise Unsupported("git directories generator")
        out = []
        for spec in g["files"]:
            pattern = render(spec["path"], inherited, go)
            for f in sorted(glob.glob(str(ROOT / pattern))):
                doc = yaml.safe_load(Path(f).read_text()) or {}
                rel = Path(f).relative_to(ROOT)
                pathinfo = {"path": str(rel.parent), "basename": rel.parent.name,
                            "filename": rel.name, "basenameNormalized": rel.parent.name}
                p = dict(doc) if go else flatten(doc)
                prefix = g.get("pathParamPrefix")
                if go:
                    p[prefix] = {"path": pathinfo} if prefix else None
                    if not prefix:
                        p["path"] = pathinfo
                    else:
                        p.pop(None, None)
                else:
                    for k, v in pathinfo.items():
                        p[(f"{prefix}." if prefix else "") + f"path.{k}" if k != "path" else (f"{prefix}." if prefix else "") + "path"] = v
                out.append(p)
        return apply_selector(out, gen.get("selector"))
    if "list" in gen:
        lst = gen["list"]
        if "elementsYaml" in lst:
            raw = render(lst["elementsYaml"], inherited, go)
            elems = yaml.safe_load(raw) or []
        else:
            elems = lst.get("elements", [])
        return apply_selector([dict(e) for e in elems], gen.get("selector"))
    if "clusters" in gen:
        sel = render(gen["clusters"].get("selector", {}), inherited, go)
        out = []
        for c in inv.values():
            labels = cluster_labels(c)
            if all(labels.get(k) == str(v) for k, v in sel.get("matchLabels", {}).items()):
                p = {"name": c["name"], "nameNormalized": c["name"], "server": c["server"]}
                if go:
                    p["metadata"] = {"labels": labels, "annotations": {}}
                else:
                    p.update({f"metadata.labels.{k}": v for k, v in labels.items()})
                out.append(p)
        return out
    if "matrix" in gen:
        children = gen["matrix"]["generators"]
        if len(children) != 2:
            raise Unsupported("matrix with other than two children")
        result = []
        for a in gen_params(children[0], inv, go, inherited, where):
            for b in gen_params(children[1], inv, go, merge_params(inherited, a, where), where):
                result.append(merge_params(a, b, where))
        return apply_selector(result, gen.get("selector"))
    raise Unsupported(f"generator {next(iter(gen))}")


def apply_selector(params: list[dict], selector):
    if not selector:
        return params
    ml = selector.get("matchLabels", {})
    return [p for p in params if all(str(p.get(k)) == str(v) for k, v in ml.items())]


def simulate(inv: dict) -> list[dict]:
    apps = []
    if (ROOT / "applicationsets").is_dir() and not (ROOT / "root-app.yaml").exists():
        err("applicationsets/ exists but root-app.yaml does not: nothing would sync it")
    for f in sorted((ROOT / "applicationsets").glob("*.yaml")):
        rel = str(f.relative_to(ROOT))
        for doc in yaml.safe_load_all(f.read_text()):
            if not doc:
                continue
            if doc.get("kind") == "Application":
                apps.append(summarize(doc, rel, "Application"))
                continue
            if doc.get("kind") != "ApplicationSet":
                continue
            spec = doc["spec"]
            go = bool(spec.get("goTemplate"))
            name = doc["metadata"]["name"]
            try:
                params = []
                for g in spec["generators"]:
                    params += gen_params(g, inv, go, {}, rel)
                for p in params:
                    apps.append(summarize(render_fields(spec["template"], p, go), rel, name))
            except Unsupported as e:
                err(f"{rel}: cannot preview ApplicationSet {name}: unsupported template/generator: {e}")
            except ValueError as e:
                err(str(e))
    seen: dict[str, str] = {}
    for a in apps:
        if a["name"] in seen:
            err(f"duplicate Application name '{a['name']}' from {a['from']} and {seen[a['name']]}")
        seen[a["name"]] = a["from"]
    return sorted(apps, key=lambda a: a["name"])


def render_fields(template: dict, params: dict, go: bool) -> dict:
    """Renders only what the preview shows: Helm values and the like may use
    template functions the simulator does not implement."""
    spec = template.get("spec", {})
    src = spec.get("source", {})
    return render({
        "metadata": {"name": template["metadata"]["name"],
                     "product": template["metadata"].get("labels", {}).get("fleet.gitops/product", "")},
        "spec": {
            "project": spec.get("project"),
            "source": {k: src[k] for k in ("repoURL", "path", "chart", "targetRevision") if k in src},
            "destination": spec.get("destination", {}),
        },
    }, params, go)


def summarize(app: dict, source_file: str, generated_by: str) -> dict:
    spec = app.get("spec", {})
    src = spec.get("source", {})
    dest = spec.get("destination", {})
    return {
        "name": app.get("metadata", {}).get("name"),
        "product": app.get("metadata", {}).get("product", ""),
        "generatedBy": generated_by,
        "from": source_file,
        "project": spec.get("project"),
        "source": src.get("path") or f"{src.get('chart')}@{src.get('targetRevision')}",
        "server": dest.get("server"),
        "namespace": dest.get("namespace"),
    }


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------
def cluster_name(server: str, inv: dict) -> str:
    for c in inv.values():
        if c.get("server") == server:
            return c["name"]
    return "hub" if server == "https://kubernetes.default.svc" else server


def markdown(apps, inv, products, compare=None) -> str:
    lines = []
    status = "passed" if not errors else f"failed ({len(errors)} problem{'s' * (len(errors) != 1)})"
    lines.append(f"### Fleet check {status}\n")
    lines.append(f"{len(inv)} cluster(s), {len(products)} product(s), {len(apps)} Argo CD Application(s).\n")
    if errors:
        lines.append("**Problems**\n")
        lines += [f"- {e}" for e in errors]
        lines.append("")
    if compare is not None:
        before = {a["name"]: a for a in compare}
        after = {a["name"]: a for a in apps}
        added = sorted(set(after) - set(before))
        removed = sorted(set(before) - set(after))
        changed = sorted(n for n in set(after) & set(before) if after[n] != before[n])
        lines.append("**What this change does to the fleet**\n")
        if not (added or removed or changed):
            lines.append("No Applications added, removed or re-targeted. Changes inside existing Applications sync as usual.\n")
        for title, names, src in (("Added", added, after), ("Removed", removed, before), ("Changed", changed, after)):
            if names:
                lines.append(f"{title}:")
                lines += [f"- `{n}` -> {cluster_name(src[n]['server'], inv)}/{src[n]['namespace']} from `{src[n]['source']}`" for n in names]
                lines.append("")
    product_apps = [a for a in apps if a["generatedBy"] in ("product-apps", "product-namespaces")]
    if product_apps:
        lines.append("**Product Applications**\n")
        lines.append("| Application | Project | Cluster | Namespace | Source |")
        lines.append("| --- | --- | --- | --- | --- |")
        for a in product_apps:
            lines.append(f"| `{a['name']}` | {a['project']} | {cluster_name(a['server'], inv)} | {a['namespace']} | `{a['source']}` |")
        lines.append("")
    lines.append(f"<details><summary>All {len(apps)} Applications</summary>\n")
    lines.append("| Application | ApplicationSet | Cluster | Namespace |")
    lines.append("| --- | --- | --- | --- |")
    for a in apps:
        lines.append(f"| `{a['name']}` | {a['generatedBy']} | {cluster_name(a['server'], inv)} | {a['namespace']} |")
    lines.append("\n</details>\n")
    return "\n".join(lines)


def affected(apps: list[dict], inv: dict, files: list[str]) -> list[dict]:
    """Applications whose inputs include one of files (best effort, for change records)."""
    servers = {f"clusters/{n}.yaml": c.get("server") for n, c in inv.items()}
    hit = []
    for a in apps:
        src = a["source"] if "@" not in a["source"] else None
        why = [f for f in files if
               (src and f.startswith(src.rstrip("/") + "/"))
               or f == a["from"]
               or (a["product"] and f.startswith(f"products/{a['product']}/"))
               or servers.get(f) == a["server"]]
        if why:
            hit.append(dict(a, cluster=cluster_name(a["server"], inv), because=why))
    return hit


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--json", help="write the generated Application list to this file")
    ap.add_argument("--compare", help="a --json file from the base branch; print what changes")
    ap.add_argument("--summary", help="append the Markdown report to this file (CI: $GITHUB_STEP_SUMMARY)")
    ap.add_argument("--quiet", action="store_true", help="print problems only")
    ap.add_argument("--affected", action="store_true", help="read changed file paths on stdin, print affected Applications as JSON")
    args = ap.parse_args()

    root_app = (load_yaml(ROOT / "root-app.yaml") if (ROOT / "root-app.yaml").exists() else None) or {}
    repo_url = root_app.get("spec", {}).get("source", {}).get("repoURL", "")
    check_repo_urls(repo_url)
    inv = load_inventory()
    products = load_products(inv, repo_url)
    apps = simulate(inv)
    if args.affected:
        files = [line.strip() for line in sys.stdin if line.strip()]
        print(json.dumps(affected(apps, inv, files), indent=2))
        return 0

    compare = None
    if args.compare and os.path.exists(args.compare):
        compare = json.loads(Path(args.compare).read_text())
    report = markdown(apps, inv, products, compare)
    if args.json:
        Path(args.json).write_text(json.dumps(apps, indent=2))
    if args.summary:
        with open(args.summary, "a") as fh:
            fh.write(report + "\n")
    if args.quiet:
        for e in errors:
            print(f"FAIL {e}")
    else:
        print(report)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
