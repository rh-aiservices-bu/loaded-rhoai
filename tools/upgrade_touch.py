#!/usr/bin/env python3
"""After an upgrade: does a spec change make an existing LLMInferenceService pick up the new release?

On 3.5.2 -> 3.6 EA2, existing services kept the presets (and so the images) they resolved on 3.5.2
for at least 13 minutes (PLAN.md §17 item 24). This makes a harmless spec change on a few services,
an env var LR_UPGRADE_TOUCH=<time> on the main container, waits for them to settle, and records
which presets and images each one is on before and after. Run it after validating the upgrade, so
the validation sees the cluster as the upgrade left it.

Usage: upgrade_touch.py <out.json> [namespace/name ...]
"""
import json
import subprocess
import sys
import time

DEFAULT = ["lr-models/lr-var-vllm-cpu", "lr-models/lr-var-replicas", "lr-models/lr-var-sched-config"]


def oc_json(*args):
    r = subprocess.run(["oc", *args, "-o", "json"], capture_output=True, text=True)
    return json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else None


def state(ns, name):
    o = oc_json("get", "llminferenceservice", name, "-n", ns)
    if not o:
        return None
    images = {}
    for d in (oc_json("get", "deployments", "-n", ns) or {}).get("items", []):
        if d["metadata"]["name"].startswith(f"{name}-kserve"):
            images.update({f"{d['metadata']['name']}/{c['name']}": c.get("image") for c in d["spec"]["template"]["spec"]["containers"]})
    ready = next((c["status"] for c in o.get("status", {}).get("conditions", []) if c["type"] == "Ready"), None)
    return {"generation": o["metadata"].get("generation"), "observed": o.get("status", {}).get("observedGeneration"),
            "ready": ready, "presets": o.get("status", {}).get("annotations", {}), "images": images}


def touch(ns, name, stamp):
    o = oc_json("get", "llminferenceservice", name, "-n", ns)
    containers = (o["spec"].get("template") or {}).get("containers") or []
    idx = next((i for i, c in enumerate(containers) if c.get("name") == "main"), None)
    if idx is None:
        return False, "no main container in spec.template to change"
    env = containers[idx].get("env") or []
    at = next((i for i, e in enumerate(env) if e["name"] == "LR_UPGRADE_TOUCH"), None)
    base = f"/spec/template/containers/{idx}/env"
    ops = ([{"op": "add", "path": base, "value": []}] if "env" not in containers[idx] else []) + (
        [{"op": "replace", "path": f"{base}/{at}/value", "value": stamp}] if at is not None
        else [{"op": "add", "path": f"{base}/-", "value": {"name": "LR_UPGRADE_TOUCH", "value": stamp}}])
    r = subprocess.run(["oc", "patch", "llminferenceservice", name, "-n", ns, "--type", "json", "-p", json.dumps(ops)], capture_output=True, text=True)
    return r.returncode == 0, (r.stdout + r.stderr).strip()


out, targets = sys.argv[1], sys.argv[2:] or DEFAULT
stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
csv = subprocess.run(["oc", "get", "csv", "-n", "redhat-ods-operator", "-o", "jsonpath={.items[*].metadata.name}"], capture_output=True, text=True).stdout
result = {"time": stamp, "rhoai": [c for c in csv.split() if c.startswith("rhods-operator")], "services": {}}
for t in targets:
    ns, name = t.split("/", 1)
    before = state(ns, name)
    if before is None:
        print(f"  {t}: not found, skipped")
        continue
    ok, msg = touch(ns, name, stamp)
    result["services"][t] = {"before": before, "patched": ok, "patch": msg}
    print(f"  {t}: spec changed" if ok else f"  {t}: could not change spec: {msg}")

deadline = time.time() + 900
for t, v in result["services"].items():
    ns, name = t.split("/", 1)
    while time.time() < deadline:
        now = state(ns, name)
        if now and now["observed"] == now["generation"] and now["ready"] == "True":
            break
        time.sleep(15)
    v["after"] = state(ns, name)
    b, a = v["before"], v["after"] or {}
    preset_moved = sorted(set(b["presets"].values())) != sorted(set(a.get("presets", {}).values()))
    images_moved = {k: (img, a.get("images", {}).get(k)) for k, img in b["images"].items() if a.get("images", {}).get(k) not in (None, img)}
    v["presetsMoved"], v["imagesMoved"] = preset_moved, images_moved
    print(f"  {t}: ready={a.get('ready')} presets {'MOVED' if preset_moved else 'unchanged'}"
          f" ({sorted(set(b['presets'].values()))[:1]} -> {sorted(set(a.get('presets', {}).values()))[:1]}), images moved: {len(images_moved)}")
    for k, (x, y) in images_moved.items():
        print(f"      {k}: {x.split('/')[-1][:50]} -> {y.split('/')[-1][:50]}")
json.dump(result, open(out, "w"), indent=1)
print(f"  saved {out}")
