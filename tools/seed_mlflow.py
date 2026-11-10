#!/usr/bin/env python3
"""Seed MLflow experiments and runs per team project (PLAN.md §6, §8).

MLflow on RHOAI 3.5.2 is one cluster-wide server with a workspace per project: every request
names it in the X-MLflow-Workspace header. Runs inside the cluster (the service isn't exposed),
fed in with `oc exec -i <pod> -- env TOKEN=... PLAN=... python3 - < seed_mlflow.py`.
PLAN is JSON: {"<namespace>": {"experiments": N, "runs": M}}. Idempotent: existing experiments
are reused, and runs are only added until each experiment has M.
"""
import json
import os
import random
import ssl
import time
import urllib.error
import urllib.request

BASE = "https://mlflow.redhat-ods-applications.svc:8443/mlflow/api/2.0/mlflow"
CTX = ssl._create_unverified_context()
TOKEN = os.environ["TOKEN"]


def call(ws, path, body):
    req = urllib.request.Request(f"{BASE}/{path}", data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": f"Bearer {TOKEN}", "X-MLflow-Workspace": ws})
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def get(ws, path):
    req = urllib.request.Request(f"{BASE}/{path}", headers={"Authorization": f"Bearer {TOKEN}", "X-MLflow-Workspace": ws})
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


made = errors = 0
for ws, want in json.loads(os.environ["PLAN"]).items():
    r = random.Random(ws)
    for e in range(want["experiments"]):
        name = f"{ws}-experiment-{e + 1}"
        code, d = get(ws, f"experiments/get-by-name?experiment_name={name}")
        if code == 200:
            exp = d["experiment"]["experiment_id"]
        else:
            code, d = call(ws, "experiments/create", {"name": name, "tags": [{"key": "loaded-rhoai.io/managed", "value": "true"}]})
            if code != 200:
                print(f"  {ws} {name}: create {code} {d}")
                errors += 1
                continue
            exp = d["experiment_id"]
        code, d = call(ws, "runs/search", {"experiment_ids": [exp], "max_results": 100})
        have = len(d.get("runs", []))
        for i in range(have, want["runs"]):
            start = int(time.time() * 1000) - r.randint(1, 30) * 86400000
            code, run = call(ws, "runs/create", {"experiment_id": exp, "start_time": start, "run_name": f"run-{i + 1}",
                                                 "tags": [{"key": "mlflow.user", "value": ws}]})
            if code != 200:
                errors += 1
                continue
            rid = run["run"]["info"]["run_id"]
            lr = r.choice([0.1, 0.01, 0.001])
            call(ws, "runs/log-batch", {"run_id": rid,
                                        "params": [{"key": "learning_rate", "value": str(lr)}, {"key": "epochs", "value": str(r.randint(3, 20))}],
                                        "metrics": [{"key": "accuracy", "value": round(r.uniform(0.6, 0.97), 4), "timestamp": start + 60000, "step": s}
                                                    for s in range(5)]})
            call(ws, "runs/update", {"run_id": rid, "status": "FINISHED", "end_time": start + 600000})
            made += 1
print(f"MLFLOW_SEED workspaces={len(json.loads(os.environ['PLAN']))} runs_created={made} errors={errors}")
