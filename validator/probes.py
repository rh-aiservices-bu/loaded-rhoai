"""Effect probes for customised variants (PLAN.md §6). A probe proves a customisation is in force,
not just present in the spec. Probe shapes are documented in tools/variants.py."""
import re

from . import kube


def _tokens(path):
    # Dots separate tokens; "\." is a literal dot inside a key (annotation names).
    return [t.replace("\0", ".") for t in path.replace("\\.", "\0").split(".")]


def values(obj, path):
    """Every value at `path`. `name[Type]` picks a condition by type; `name[*]` fans out over a list."""
    cur = [obj]
    for tok in _tokens(path):
        m = re.fullmatch(r"(.+?)\[(.+)\]", tok)
        key, sel = (m.group(1), m.group(2)) if m else (tok, None)
        nxt = []
        for c in cur:
            if not isinstance(c, dict) or key not in c:
                continue
            v = c[key]
            if sel is None:
                nxt.append(v)
            elif isinstance(v, list):
                nxt.extend(v if sel == "*" else [x for x in v if isinstance(x, dict) and x.get("type") == sel])
        cur = nxt
    return [x for c in cur for x in (c if isinstance(c, list) else [c])]


def compare(vals, op, want):
    norm = lambda x: str(x).lower() if isinstance(x, bool) else str(x)
    if op == "exists":
        return bool(vals)
    if op == "absent":
        return not vals
    if op == "eq":
        return any(norm(v) == norm(want) for v in vals)
    if op == "ne":
        return bool(vals) and all(norm(v) != norm(want) for v in vals)
    if op == "contains":
        return any(norm(v) == norm(want) or (isinstance(v, str) and str(want) in v) for v in vals)
    raise ValueError(f"unknown op {op}")


def _running_pods(ns, labels):
    return [p for p in kube.list_all("Pod", ns, labels) if p.get("status", {}).get("phase") == "Running"]


def run(probe):
    """Return (passed, detail). A cluster that can't be asked fails the probe with the reason."""
    try:
        return _run(probe)
    except kube.KubeError as e:
        return False, f"could not read the cluster: {e}"


def _run(probe):
    t = probe["type"]
    if t == "field":
        obj = kube.get(probe["kind"], probe.get("namespace"), probe["name"])
        if obj is None:
            return False, f"{probe['kind']} {probe.get('namespace')}/{probe['name']} not found"
        vals = values(obj, probe["path"])
        ok = compare(vals, probe.get("op", "exists"), probe.get("value"))
        return ok, f"{probe['kind']}/{probe['name']} {probe['path']} {probe.get('op')} {probe.get('value')!r}: got {vals[:3]!r}"
    if t == "pod":
        pods = _running_pods(probe["namespace"], probe["labels"])
        if not pods:
            return False, f"no running pod with {probe['labels']}"
        vals = [v for p in pods for v in values(p, probe["path"])]
        return compare(vals, probe.get("op", "exists"), probe.get("value")), f"pods {probe['labels']} {probe['path']}: got {vals[:4]!r}"
    if t == "pod_env":
        pods = _running_pods(probe["namespace"], probe["labels"])
        found = [e.get("value") for p in pods for c in p["spec"]["containers"] for e in c.get("env", []) if e["name"] == probe["env"]]
        return probe["value"] in found, f"pods {probe['labels']} env {probe['env']}: got {found[:3]!r} ({len(pods)} running pods)"
    if t == "owned":
        objs = [o for o in kube.list_all(probe["kind"], probe["namespace"])
                if any(r["kind"] == probe["owner_kind"] and r["name"] == probe["owner"] for r in o["metadata"].get("ownerReferences", []))]
        if not objs:
            return False, f"no {probe['kind']} owned by {probe['owner_kind']}/{probe['owner']}"
        if "path" not in probe:
            return True, f"{probe['kind']} {objs[0]['metadata']['name']}"
        vals = [v for o in objs for v in values(o, probe["path"])]
        return compare(vals, probe.get("op", "exists"), probe.get("value")), f"{probe['kind']} owned by {probe['owner']} {probe['path']}: got {vals[:3]!r}"
    return False, f"unknown probe type {t}"
