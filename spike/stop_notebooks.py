#!/usr/bin/env python3
"""Stop every Notebook the generator says should be stopped.

On RHOAI 3.5.2 a Notebook created with kubeflow-resource-stopped loses the annotation right
after create and starts anyway, so population has to create first and stop afterwards.

Usage: stop_notebooks.py <profile>     Idempotent. Exits non-zero if any don't stay stopped.
"""
import concurrent.futures as cf
import glob
import json
import subprocess
import sys
import time

KEY = "kubeflow-resource-stopped"
profile = sys.argv[1]
want = {}
for f in glob.glob(f"generated/{profile}/shards/*.json"):
    for d in json.load(open(f))["items"]:
        if d["kind"] == "Notebook" and KEY in d["metadata"]["annotations"]:
            want[(d["metadata"]["namespace"], d["metadata"]["name"])] = d["metadata"]["annotations"][KEY]


def missing():
    out = subprocess.run(["oc", "get", "notebook", "-A", "-o", "json"], capture_output=True, text=True, check=True).stdout
    return [(n["metadata"]["namespace"], n["metadata"]["name"]) for n in json.loads(out)["items"]
            if (n["metadata"]["namespace"], n["metadata"]["name"]) in want and KEY not in n["metadata"].get("annotations", {})]


def stop(item):
    ns, name = item
    r = subprocess.run(["oc", "annotate", "notebook", name, "-n", ns, f"{KEY}={want[item]}", "--overwrite"], capture_output=True, text=True)
    return None if r.returncode == 0 else f"{ns}/{name}: {r.stderr[:160]}"


for attempt in range(1, 6):
    todo = missing()
    print(f"attempt {attempt}: {len(todo)} to stop", flush=True)
    if not todo:
        break
    with cf.ThreadPoolExecutor(8) as ex:
        errs = [e for e in ex.map(stop, todo) if e]
    for e in errs[:5]:
        print(" ", e)
    time.sleep(25)  # If something strips the annotation again, the next pass sees it.
left = missing()
print(f"expected stopped={len(want)} still not stopped={len(left)}")
sys.exit(1 if left else 0)
