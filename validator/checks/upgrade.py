"""§10.13 Upgrade comparison. A passing run on an unchanged version saves a baseline (locally and in
the cluster). When the installed RHOAI differs from the baseline's, the run compares against it:
what changed under each object, which LLMInferenceService presets moved (risk 24), what the
upgrade restarted. Inventory, status, functional and variant checks run as usual alongside."""
import base64
import hashlib
import json
import os

from .. import kube
from ..report import SKIP, WARN

CAT = "upgrade"
CM_NS, CM_NAME = "lr-infra", "loaded-rhoai-baseline"
CM_SCHEMAS = "loaded-rhoai-baseline-schemas"   # separate: schemas can approach ConfigMap size limits
SCHEMA_DEPTH = 8
APPS = "redhat-ods-applications"


def installed_rhoai():
    csvs = [c for c in kube.list_all("clusterserviceversions.operators.coreos.com", "redhat-ods-operator") if c["metadata"]["name"].startswith("rhods-operator")]
    return sorted((c["metadata"]["name"], c.get("status", {}).get("phase")) for c in csvs)


def in_progress():
    """An upgrade is mid-flight if RHOAI isn't Succeeded or an approved install plan isn't Complete."""
    reasons = [f"{n} is {p}" for n, p in installed_rhoai() if p != "Succeeded"]
    for ip in kube.list_all("installplans.operators.coreos.com"):
        if ip["spec"].get("approved") and ip.get("status", {}).get("phase") not in ("Complete", "Failed"):
            reasons.append(f"install plan {ip['metadata']['namespace']}/{ip['metadata']['name']} is {ip.get('status', {}).get('phase')}")
    return reasons


def snapshot(inventory):
    objs = {}
    live_by_kind = {}
    for o in inventory:
        if o.get("createdBy"):
            continue
        if o["kind"] not in live_by_kind:   # one list per kind, not one call per object
            live_by_kind[o["kind"]] = {(x["metadata"].get("namespace"), x["metadata"]["name"]): x for x in kube.list_all(o["kind"])}
        live = live_by_kind[o["kind"]].get((o["namespace"], o["name"]))
        if not live:
            continue
        spec = live.get("spec", live.get("data", {}))
        entry = {"gen": live["metadata"].get("generation"), "spec": hashlib.sha256(json.dumps(spec, sort_keys=True).encode()).hexdigest()[:16]}
        if o["kind"] == "LLMInferenceService":
            entry["presets"] = live.get("status", {}).get("annotations", {})
        if o["kind"] in ("InferenceService", "LLMInferenceService"):
            entry["images"] = model_images(o["kind"], o["namespace"], o["name"])
        if o["kind"] == "ServingRuntime":
            entry["runtimeVersion"] = live["metadata"].get("annotations", {}).get("opendatahub.io/runtime-version")
            entry["images"] = {c["name"]: c.get("image") for c in live["spec"].get("containers", [])}
        objs[f"{o['kind']}|{o['namespace'] or ''}|{o['name']}"] = entry
    restarts = {}
    for p in kube.list_all("Pod", APPS):
        for c in p["status"].get("containerStatuses", []):
            restarts[f"{p['metadata'].get('labels', {}).get('app', p['metadata']['name'])}/{c['name']}"] = c["restartCount"]
    return {"rhoai": [n for n, _ in installed_rhoai()],
            "csvs": sorted({s.get("status", {}).get("installedCSV", "") for s in kube.list_all("subscriptions.operators.coreos.com")}),
            "presets": sorted(c["metadata"]["name"] for c in kube.list_all("LLMInferenceServiceConfig", APPS)),
            "objects": objs, "restarts": restarts, "runtimeTemplates": runtime_templates(),
            "schemas": crd_schemas({o["kind"] for o in inventory})}


def _flatten_schema(node, path, out, depth):
    """{"spec.a.b": "string", "spec.list[].x": "integer|enum=a,b", ...} for one CRD version."""
    if depth > SCHEMA_DEPTH or not isinstance(node, dict):
        return
    t = node.get("type") or ("int-or-string" if node.get("x-kubernetes-int-or-string") else "object" if "properties" in node else "")
    if path:
        out[path] = t + (f"|enum={','.join(map(str, node['enum']))}" if node.get("enum") else "")
    for k, v in (node.get("properties") or {}).items():
        _flatten_schema(v, f"{path}.{k}" if path else k, out, depth + 1)
    if isinstance(node.get("items"), dict):
        _flatten_schema(node["items"], f"{path}[]", out, depth + 1)


def crd_schemas(kinds):
    """Spec schemas of the platform CRDs (DSC, DSCI, every component CRD) and of every kind we create."""
    names = {"datascienceclusters.datasciencecluster.opendatahub.io", "dscinitializations.dscinitialization.opendatahub.io"}
    names |= {kube.resource(k) for k in kinds if kube.resource(k).count(".") >= 2}
    out = {}
    for crd in kube.list_all("customresourcedefinitions.apiextensions.k8s.io"):
        n = crd["metadata"]["name"]
        if n not in names and crd["spec"]["group"] != "components.platform.opendatahub.io":
            continue
        ver = next((v for v in crd["spec"]["versions"] if v.get("storage")), crd["spec"]["versions"][0])
        flat = {}
        _flatten_schema((ver.get("schema", {}).get("openAPIV3Schema", {}).get("properties") or {}).get("spec", {}), "spec", flat, 0)
        out[n] = {"kind": crd["spec"]["names"]["kind"], "version": ver["name"], "fields": flat}
    return out


def _used_paths(obj, path="", out=None):
    """Paths our own manifests set, in the same notation as the flattened schemas."""
    out = set() if out is None else out
    if isinstance(obj, dict):
        for k, v in obj.items():
            p = f"{path}.{k}" if path else k
            out.add(p)
            _used_paths(v, p, out)
    elif isinstance(obj, list):
        for v in obj:
            _used_paths(v, f"{path}[]", out)
    return out


def _read_cm(name):
    import gzip
    o = kube.get("ConfigMap", CM_NS, name)
    if o and o.get("binaryData", {}).get("data.json.gz"):
        return json.loads(gzip.decompress(base64.b64decode(o["binaryData"]["data.json.gz"])))
    if o and o.get("binaryData", {}).get("baseline.json.gz"):   # format before schemas were added
        return json.loads(gzip.decompress(base64.b64decode(o["binaryData"]["baseline.json.gz"])))
    return None


def _write_cm(name, data, local):
    import gzip
    cm = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": name, "namespace": CM_NS, "labels": {"loaded-rhoai.io/managed": "true"}},
          "binaryData": {"data.json.gz": base64.b64encode(gzip.compress(json.dumps(data).encode())).decode()}}
    path = local + f".{name}.json"
    json.dump(cm, open(path, "w"))
    rc, _, err = kube.oc("apply", "--server-side", "--force-conflicts", "-f", path)
    os.remove(path)
    return rc == 0, err


_pods_by_ns = {}


def model_images(kind, ns, name):
    """Images a model is actually running, per component and container (stopped models: empty)."""
    if ns not in _pods_by_ns:
        _pods_by_ns[ns] = [p for p in kube.list_all("Pod", ns) if p.get("status", {}).get("phase") == "Running"]
    out = {}
    for p in _pods_by_ns[ns]:
        lab = p["metadata"].get("labels", {})
        mine = (lab.get("serving.kserve.io/inferenceservice") == name if kind == "InferenceService"
                else lab.get("app.kubernetes.io/name") == name and lab.get("app.kubernetes.io/part-of") == "llminferenceservice")
        if mine:
            comp = lab.get("kserve.io/component") or lab.get("app.kubernetes.io/component") or "pod"
            for c in p["spec"]["containers"]:
                out[f"{comp}/{c['name']}"] = c.get("image")
    return out


def runtime_templates():
    """Shipped runtime templates' versions, to tell which project copies an upgrade left behind."""
    out = {}
    for t in kube.list_all("templates.template.openshift.io", APPS):
        for obj in t.get("objects", []):
            if obj.get("kind") == "ServingRuntime":
                out[t["metadata"]["name"]] = obj["metadata"].get("annotations", {}).get("opendatahub.io/runtime-version")
    return out


def load_baseline(local):
    base = _read_cm(CM_NAME)
    if base is None and os.path.exists(local):
        base = json.load(open(local))
    if base is not None and "schemas" not in base:
        base["schemas"] = _read_cm(CM_SCHEMAS)   # None for baselines saved before schemas existed
    return base


def save_baseline(snap, local):
    json.dump(snap, open(local, "w"))
    schemas = snap.get("schemas") or {}
    ok, err = _write_cm(CM_NAME, {k: v for k, v in snap.items() if k != "schemas"}, local)
    if ok:
        ok, err = _write_cm(CM_SCHEMAS, schemas, local)
    return ok, err


def run(r, ctx):
    local = os.path.join(ctx["gen_dir"], "baseline.json")
    base = load_baseline(local)
    now_rhoai = [n for n, _ in installed_rhoai()]
    ctx["mode"] = "steady"
    if not base or ctx.get("reset_baseline"):
        r.add(CAT, "baseline", SKIP, "no baseline yet; this run saves one", blocking=False)
        ctx["save_baseline"] = True
        return
    if base["rhoai"] == now_rhoai:
        r.add(CAT, "no upgrade since the baseline", "pass", f"RHOAI {now_rhoai}")
        ctx["save_baseline"] = True
        return

    ctx["mode"] = "upgrade"
    ctx["baseline"] = base
    snap = snapshot(ctx["inventory"])
    r.add(CAT, "upgrade detected", "pass", f"{base['rhoai']} -> {now_rhoai}")
    changed_csvs = sorted(set(snap["csvs"]) - set(base["csvs"]))
    r.add(CAT, "operators changed by the upgrade", WARN if changed_csvs else "pass", f"new CSVs: {changed_csvs}", blocking=False)

    gone = [k for k in base["objects"] if k not in snap["objects"]]
    r.check(CAT, "every baseline object survived the upgrade", not gone, f"{len(gone)} gone: {gone[:10]}")
    spec_changed = [k for k, v in base["objects"].items() if k in snap["objects"] and snap["objects"][k]["spec"] != v["spec"]]
    by_kind = {}
    for k in spec_changed:
        by_kind.setdefault(k.split("|")[0], []).append(k.split("|", 1)[1])
    expected = set(ctx.get("expected_changes", []))
    unexpected = {k: v for k, v in by_kind.items() if k not in expected}
    r.check(CAT, "no unexpected spec changes (settings reset or rewritten by the upgrade)", not unexpected,
            "; ".join(f"{k}: {len(v)} e.g. {v[:3]}" for k, v in unexpected.items()) or "none", blocking=False)

    moved = []
    for k, v in base["objects"].items():
        if k.startswith("LLMInferenceService|") and k in snap["objects"]:
            before, after = v.get("presets", {}), snap["objects"][k].get("presets", {})
            if before != after:
                moved.append(f"{k.split('|', 1)[1]}: {sorted(set(before.values()))[:2]} -> {sorted(set(after.values()))[:2]}")
    r.add(CAT, "LLMInferenceService presets after the upgrade (PLAN.md §17 item 24)", WARN if moved else "pass",
          "; ".join(moved) or "no service changed its resolved presets", blocking=False)
    old_presets = sorted(set(base["presets"]) - set(snap["presets"]))
    new_presets = sorted(set(snap["presets"]) - set(base["presets"]))
    r.add(CAT, "shipped presets replaced", "pass", f"removed {len(old_presets)} (e.g. {old_presets[:2]}), added {len(new_presets)} (e.g. {new_presets[:2]})", blocking=False)

    image_changes(r, base, snap)
    schema_changes(r, ctx, base.get("schemas"), snap["schemas"])

    restarted = {k: snap["restarts"].get(k, 0) - v for k, v in base["restarts"].items() if snap["restarts"].get(k, 0) > v}
    r.add(CAT, "RHOAI controller restarts since the baseline", WARN if restarted else "pass", json.dumps(restarted)[:600], blocking=False)
    ctx["save_baseline"] = False


def schema_changes(r, ctx, before, after):
    """Fields the upgrade removed from, or retyped in, the CRDs we depend on. Fields our own manifests
    set are called out: those are the ones an upgrade can silently prune from existing objects."""
    if not before:
        r.add(CAT, "CRD schema changes", SKIP, "the baseline predates schema capture; the next baseline will include them", blocking=False)
        return
    used = {}
    import glob
    for f in glob.glob(os.path.join(ctx["pop_dir"], "shards", "*.json")):
        for d in json.load(open(f))["items"]:
            used.setdefault(d["kind"], set()).update(_used_paths({"spec": d.get("spec", {})}))
    affecting, summary = [], []
    for crd, old in sorted(before.items()):
        new = after.get(crd)
        if new is None:
            summary.append(f"{crd}: CRD removed")
            continue
        removed = sorted(set(old["fields"]) - set(new["fields"]))
        retyped = sorted(p for p in old["fields"] if p in new["fields"] and old["fields"][p] != new["fields"][p])
        added = len(set(new["fields"]) - set(old["fields"]))
        if removed or retyped or added or old["version"] != new["version"]:
            summary.append(f"{old['kind']}: storage {old['version']}->{new['version']}, {len(removed)} removed, {len(retyped)} retyped, {added} added")
        mine = used.get(old["kind"], set())
        for p in removed:
            if p in mine:
                affecting.append(f"{old['kind']} {p} removed (our objects set it)")
        for p in retyped:
            if p in mine:
                affecting.append(f"{old['kind']} {p}: {old['fields'][p]} -> {new['fields'][p]} (our objects set it)")
        detail = [f"removed {p}" for p in removed[:6]] + [f"{p}: {old['fields'][p]} -> {new['fields'][p]}" for p in retyped[:6]]
        if removed or retyped:
            r.add(CAT, f"schema changes in {old['kind']} ({crd})", WARN, "; ".join(detail) + (" ..." if len(removed) + len(retyped) > 12 else ""), blocking=False)
    r.add(CAT, "CRD schema changes summary", WARN if summary else "pass", "; ".join(summary) or "no schema changes", blocking=False)
    r.check(CAT, "no field our objects set was removed or retyped by the upgrade", not affecting, "; ".join(affecting[:15]) or "none", blocking=False)


def image_changes(r, base, snap):
    """Which running models the upgrade moved to new images (e.g. a new vLLM), and which it left on
    the old ones; and which project runtime copies are now behind their shipped template."""
    moved, stayed = [], []
    for k, v in base["objects"].items():
        kind = k.split("|")[0]
        if kind not in ("InferenceService", "LLMInferenceService") or not v.get("images") or k not in snap["objects"]:
            continue
        before, after = v["images"], snap["objects"][k].get("images", {})
        changed = {c: (img, after.get(c)) for c, img in before.items() if after.get(c) and after.get(c) != img}
        short = lambda i: (i or "").split("/")[-1][:60]
        if changed:
            moved.append(f"{k.split('|', 1)[1]}: " + ", ".join(f"{c} {short(a)} -> {short(b)}" for c, (a, b) in changed.items()))
        elif after:
            stayed.append(k.split("|", 1)[1])
    r.add(CAT, "running models moved to new images by the upgrade", WARN if moved else "pass",
          "; ".join(moved) or "none moved", blocking=False)
    r.add(CAT, "running models still on their pre-upgrade images", WARN if stayed else "pass",
          f"{len(stayed)}: {stayed[:12]}" if stayed else "none", blocking=False)
    if base.get("runtimeTemplates"):
        behind = []
        for k, v in base["objects"].items():
            if k.startswith("ServingRuntime|") and v.get("runtimeVersion") and k in snap["objects"]:
                now_copy = snap["objects"][k].get("runtimeVersion")
                for tname, tver in snap.get("runtimeTemplates", {}).items():
                    if tver and base["runtimeTemplates"].get(tname) == v["runtimeVersion"] and tver != now_copy:
                        behind.append(f"{k.split('|', 1)[1]} at {now_copy}, template {tname} now {tver}")
                        break
        r.add(CAT, "project runtime copies behind their shipped template", WARN if behind else "pass",
              "; ".join(behind[:10]) or "none", blocking=False)


def results_record(r, meta):
    """Every check's outcome, keyed by section and name, for comparison after an upgrade."""
    return {"rhoai": meta.get("rhoai"), "started": meta.get("started"),
            "checks": {f"{i['category']}|{i['name']}": {"status": i["status"], "detail": i["detail"][:240]} for i in r.items}}


def compare_results(r, base):
    """Failures carried across the upgrade, fixed by it, or introduced by it."""
    before = (base.get("results") or {}).get("checks")
    if not before:
        r.add(CAT, "check results compared with the baseline", SKIP, "the baseline predates recorded results", blocking=False)
        return
    now = {f"{i['category']}|{i['name']}": i for i in r.items if i["category"] != CAT}
    was_bad = {k for k, v in before.items() if v["status"] == "fail" and not k.startswith(CAT + "|")}
    still = sorted(k for k in was_bad if k in now and now[k]["status"] == "fail")
    fixed = sorted(k for k in was_bad if k in now and now[k]["status"] in ("pass", "warn", "skip"))
    gone = sorted(k for k in was_bad if k not in now)
    broke = sorted(k for k, i in now.items() if i["status"] == "fail" and before.get(k, {}).get("status") in ("pass", "warn"))
    new_fail = sorted(k for k, i in now.items() if i["status"] == "fail" and k not in before)
    fmt = lambda ks: "; ".join(k.replace("|", ": ", 1) for k in ks[:12]) + (f" (+{len(ks) - 12} more)" if len(ks) > 12 else "")
    when = (base.get("results") or {}).get("rhoai")
    r.add(CAT, f"failures still present after the upgrade (were failing on {when})", WARN if still else "pass", fmt(still) or "none", blocking=False)
    r.add(CAT, "failures the upgrade fixed", "pass", fmt(fixed) or "none", blocking=False)
    if gone:
        r.add(CAT, "failing checks that no longer run", WARN, fmt(gone), blocking=False)
    r.add(CAT, "checks the upgrade broke (passed before)", WARN if broke else "pass", fmt(broke) or "none", blocking=False)
    if new_fail:
        r.add(CAT, "failing checks that are new since the baseline", WARN, fmt(new_fail), blocking=False)
