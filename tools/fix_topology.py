#!/usr/bin/env python3
"""Delete DaemonSet pods left on control-plane nodes after the control plane was made unschedulable.

When the control plane was schedulable, DaemonSets that don't tolerate the control-plane taint
still got pods there. Once it's unschedulable those pods stay, the DaemonSet reports them as
mis-scheduled, and KubeDaemonSetMisScheduled / RolloutStuck fire (3.5.2 spike). The DaemonSet
controller won't recreate them on the control plane, so deleting them is the fix.
Only pods of DaemonSets that report numberMisscheduled > 0, on control-plane nodes, are touched.
"""
import json
import subprocess
import sys


def oc_json(*args):
    return json.loads(subprocess.run(["oc", *args, "-o", "json"], capture_output=True, text=True, check=True).stdout)


cp = {n["metadata"]["name"] for n in oc_json("get", "nodes", "-l", "node-role.kubernetes.io/control-plane")["items"]}
bad_ds = {(d["metadata"]["namespace"], d["metadata"]["name"]) for d in oc_json("get", "ds", "-A")["items"]
          if d.get("status", {}).get("numberMisscheduled", 0) > 0}
deleted = 0
for p in oc_json("get", "pods", "-A")["items"]:
    owner = next((o["name"] for o in p["metadata"].get("ownerReferences", []) if o["kind"] == "DaemonSet"), None)
    ns = p["metadata"]["namespace"]
    if owner and (ns, owner) in bad_ds and p["spec"].get("nodeName") in cp:
        r = subprocess.run(["oc", "delete", "pod", p["metadata"]["name"], "-n", ns, "--wait=false"], capture_output=True, text=True)
        print(f"  deleted {ns}/{p['metadata']['name']} on {p['spec']['nodeName']}" if r.returncode == 0 else f"  could not delete {ns}/{p['metadata']['name']}: {r.stderr[:120]}")
        deleted += r.returncode == 0
print(f"  mis-scheduled DaemonSets: {len(bad_ds)}, pods removed from the control plane: {deleted}")
sys.exit(0)
