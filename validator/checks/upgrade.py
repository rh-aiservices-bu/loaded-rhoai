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
        objs[f"{o['kind']}|{o['namespace'] or ''}|{o['name']}"] = entry
    restarts = {}
    for p in kube.list_all("Pod", APPS):
        for c in p["status"].get("containerStatuses", []):
            restarts[f"{p['metadata'].get('labels', {}).get('app', p['metadata']['name'])}/{c['name']}"] = c["restartCount"]
    return {"rhoai": [n for n, _ in installed_rhoai()],
            "csvs": sorted({s.get("status", {}).get("installedCSV", "") for s in kube.list_all("subscriptions.operators.coreos.com")}),
            "presets": sorted(c["metadata"]["name"] for c in kube.list_all("LLMInferenceServiceConfig", APPS)),
            "objects": objs, "restarts": restarts}


def load_baseline(local):
    o = kube.get("ConfigMap", CM_NS, CM_NAME)
    if o and o.get("binaryData", {}).get("baseline.json.gz"):
        import gzip
        return json.loads(gzip.decompress(base64.b64decode(o["binaryData"]["baseline.json.gz"])))
    return json.load(open(local)) if os.path.exists(local) else None


def save_baseline(snap, local):
    import gzip
    json.dump(snap, open(local, "w"))
    data = base64.b64encode(gzip.compress(json.dumps(snap).encode())).decode()
    cm = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": CM_NAME, "namespace": CM_NS, "labels": {"loaded-rhoai.io/managed": "true"}},
          "binaryData": {"baseline.json.gz": data}}
    path = local + ".cm.json"
    json.dump(cm, open(path, "w"))
    rc, _, err = kube.oc("apply", "--server-side", "--force-conflicts", "-f", path)
    os.remove(path)
    return rc == 0, err


def run(r, ctx):
    local = os.path.join(ctx["gen_dir"], "baseline.json")
    base = load_baseline(local)
    now_rhoai = [n for n, _ in installed_rhoai()]
    ctx["mode"] = "steady"
    if not base or ctx.get("reset_baseline"):
        r.add(CAT, "baseline", SKIP, "no baseline yet; this run saves one if it passes", blocking=False)
        ctx["save_baseline"] = True
        return
    if base["rhoai"] == now_rhoai:
        r.add(CAT, "no upgrade since the baseline", "pass", f"RHOAI {now_rhoai}")
        ctx["save_baseline"] = True
        return

    ctx["mode"] = "upgrade"
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

    restarted = {k: snap["restarts"].get(k, 0) - v for k, v in base["restarts"].items() if snap["restarts"].get(k, 0) > v}
    r.add(CAT, "RHOAI controller restarts since the baseline", WARN if restarted else "pass", json.dumps(restarted)[:600], blocking=False)
    ctx["save_baseline"] = False
