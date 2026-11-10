#!/usr/bin/env python3
"""Run maaspal scenarios headlessly through its BFF, one at a time, and summarise results.

Runs inside the BFF pod (the NetworkPolicy only admits the dashboard), so it's fed in with
`oc exec ... python3 - < maaspal_run.py`. Needs TOKEN (a user allowed to use maaspal) and PLAN
(JSON list of [scenario, config_overrides]) in the environment.
"""
import json
import os
import time
import urllib.error
import urllib.request

BASE = "http://localhost:3000/api"
H = {"Authorization": "Bearer " + os.environ["TOKEN"], "Content-Type": "application/json"}
TERMINAL = {"PASS", "FAIL", "ERROR", "CANCELLED", "PASSED", "FAILED", "COMPLETED", "STOPPED"}


def req(method, path, body=None):
    r = urllib.request.Request(BASE + path, data=json.dumps(body).encode() if body is not None else None, headers=H, method=method)
    with urllib.request.urlopen(r, timeout=60) as resp:
        return json.load(resp)


results = []
for scenario, overrides in json.loads(os.environ["PLAN"]):
    t0 = time.time()
    try:
        run = req("POST", "/runs", {"scenario": scenario, "config_overrides": overrides, "auto_cleanup": True})
    except urllib.error.HTTPError as e:
        print(f"{scenario:32} could not start: {e.code} {e.read()[:200]}", flush=True)
        results.append({"scenario": scenario, "status": "NOT STARTED"})
        continue
    rid, status = run["run_id"], run["status"]
    while status not in TERMINAL and time.time() - t0 < 1800:
        time.sleep(10)
        status = req("GET", f"/runs/{rid}")["status"]
    detail = req("GET", f"/runs/{rid}")
    asserts = req("GET", f"/runs/{rid}/assertions").get("assertions", [])
    failed = [a for a in asserts if str(a.get("status", a.get("passed", ""))).upper() in ("FAILING", "FALSE", "FAIL", "FAILED", "PENDING")]
    print(f"{scenario:32} {status:9} {int(time.time() - t0):4}s assertions={len(asserts)} failed={len(failed)} run={rid}", flush=True)
    for a in failed[:4]:
        print(f"    FAILED: {json.dumps(a)[:300]}", flush=True)
    if status not in ("PASS", "PASSED", "COMPLETED") and not failed:
        print(f"    detail: {json.dumps({k: v for k, v in detail.items() if k not in ('config_overrides',)})[:400]}", flush=True)
    results.append({"scenario": scenario, "status": status, "run_id": rid, "seconds": int(time.time() - t0),
                    "assertions": asserts, "failed": len(failed)})
print("RESULTS_JSON " + json.dumps(results))
