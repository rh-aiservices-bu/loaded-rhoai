#!/usr/bin/env python3
"""Whole-cluster sweep: alerts, pods, events, workload statuses and the expected inventory.
Usage: sweep.py <population dir, e.g. generated/medium>"""
import collections
import datetime
import json
import subprocess
import sys
import urllib.parse

POP = sys.argv[1]


def oc(*args, timeout=120):
    r = subprocess.run(["oc", *args], capture_output=True, text=True, timeout=timeout)
    return json.loads(r.stdout) if r.stdout.strip().startswith("{") else None


def prom(expr):
    r = subprocess.run(["oc", "exec", "-n", "openshift-monitoring", "prometheus-k8s-0", "-c", "prometheus", "--", "curl", "-s", "--max-time", "40",
                        "http://localhost:9090/api/v1/query?" + urllib.parse.urlencode({"query": expr})], capture_output=True, text=True, timeout=70)
    try:
        return json.loads(r.stdout)["data"]["result"]
    except Exception:
        return []


print("=== firing alerts, warning and above (cluster Prometheus)")
for a in sorted(prom('ALERTS{alertstate="firing",severity=~"warning|critical"}'), key=lambda a: a["metric"].get("alertname")):
    m = a["metric"]
    print(f"  {m.get('severity'):8} {m.get('alertname'):42} ns={m.get('namespace', '')} {m.get('pod', m.get('deployment', m.get('job', '')))}"[:170])
print("=== firing alerts in RHOAI's own stack")
r = subprocess.run(["oc", "exec", "-n", "redhat-ods-monitoring", "prometheus-data-science-monitoringstack-0", "-c", "prometheus", "--", "curl", "-s", "--max-time", "30",
                    "http://localhost:9090/api/v1/query?" + urllib.parse.urlencode({"query": 'ALERTS{alertstate="firing"}'})], capture_output=True, text=True, timeout=60)
try:
    for a in json.loads(r.stdout)["data"]["result"]:
        print(f"  {a['metric'].get('severity', ''):8} {a['metric'].get('alertname')} ns={a['metric'].get('namespace', '')}"[:160])
except Exception:
    print("  could not query")

print("=== pods: not running, not ready, or restarted in the last 2h")
pods = oc("get", "pods", "-A", "-o", "json")["items"]
rest = prom('increase(kube_pod_container_status_restarts_total[2h]) > 0')
for p in pods:
    ns, n, ph = p["metadata"]["namespace"], p["metadata"]["name"], p["status"].get("phase")
    if "installer-" in n or ph == "Succeeded":
        continue
    bad = [(c["name"], list(c["state"])[0], c["state"].get("waiting", {}).get("reason") or c["state"].get("terminated", {}).get("reason"))
           for c in p["status"].get("containerStatuses", []) if not c["ready"]]
    if ph != "Running" or bad:
        print(f"  {ns:28} {n[:46]:47} {ph} {bad}"[:200])
for s in rest:
    print(f"  restarted: {s['metric'].get('namespace')} {s['metric'].get('pod', '')[:48]} {s['metric'].get('container')} +{round(float(s['value'][1]))}")

print("=== warning events in the last hour, grouped")
ev = oc("get", "events", "-A", "--field-selector", "type=Warning", "-o", "json")["items"]
c = collections.Counter()
hour_ago = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
for e in ev:
    last = e.get("lastTimestamp") or e.get("eventTime") or ""
    if last < hour_ago:
        continue
    ns = e["metadata"]["namespace"]
    c[(("lr-*" if ns.startswith("lr-") else ns), e["reason"], e["involvedObject"]["kind"], (e.get("message") or "")[:70])] += e.get("count", 1)
for (ns, reason, kind, msg), n in c.most_common(18):
    print(f"  {n:5} {ns:28} {reason:26} {kind:14} {msg}")

print("=== workload statuses")
checks = [
    ("notebooks", "notebook", lambda o: "stopped" if "kubeflow-resource-stopped" in o["metadata"].get("annotations", {}) else ("ready" if o.get("status", {}).get("readyReplicas") == 1 else "NOT READY")),
    ("inferenceservices", "isvc", lambda o: "stopped" if o["metadata"].get("annotations", {}).get("serving.kserve.io/stop") == "true" else next((("ready" if x["status"] == "True" else "NOT READY") for x in o.get("status", {}).get("conditions", []) if x["type"] == "Ready"), "NOT READY")),
    ("llminferenceservices", "llminferenceservice", lambda o: next((("ready" if x["status"] == "True" else "NOT READY") for x in o.get("status", {}).get("conditions", []) if x["type"] == "Ready"), "NOT READY")),
    ("pipeline servers", "dspa", lambda o: next((("ready" if x["status"] == "True" else "NOT READY") for x in o.get("status", {}).get("conditions", []) if x["type"] == "Ready"), "NOT READY")),
    ("feature stores", "featurestore", lambda o: o.get("status", {}).get("phase")),
    ("mcp servers", "mcpserver", lambda o: next((("ready" if x["status"] == "True" else "NOT READY") for x in o.get("status", {}).get("conditions", []) if x["type"] == "Ready"), "NOT READY")),
    ("trustyai", "trustyaiservice", lambda o: next((("ready" if x["status"] == "True" else "NOT READY") for x in o.get("status", {}).get("conditions", []) if x["type"] == "Available"), "?")),
    ("rayclusters", "raycluster", lambda o: f"{o.get('status', {}).get('state')}, suspend={o['spec'].get('suspend')}"),
    ("trainjobs", "trainjob", lambda o: next((x["type"] for x in o.get("status", {}).get("conditions", []) if x["status"] == "True"), "?")),
    ("spark", "sparkapplication", lambda o: o.get("status", {}).get("applicationState", {}).get("state")),
    ("kueue workloads", "workloads.kueue.x-k8s.io", lambda o: next((x["type"] for x in reversed(o.get("status", {}).get("conditions", [])) if x["status"] == "True"), "pending")),
    ("maas model refs", "maasmodelref", lambda o: o.get("status", {}).get("phase")),
    ("model registries", "modelregistries.modelregistry.opendatahub.io", lambda o: next((("ready" if x["status"] == "True" else "NOT READY") for x in o.get("status", {}).get("conditions", []) if x["type"] == "Available"), "?")),
    ("ogx servers", "ogxservers.ogx.io", lambda o: o.get("status", {}).get("phase")),
    ("evalhubs", "evalhubs.trustyai.opendatahub.io", lambda o: next((("ready" if x["status"] == "True" else "NOT READY") for x in o.get("status", {}).get("conditions", []) if x["type"] == "Ready"), "?")),
    ("inference graphs", "inferencegraphs.serving.kserve.io", lambda o: next((("ready" if x["status"] == "True" else "NOT READY") for x in o.get("status", {}).get("conditions", []) if x["type"] == "Ready"), "?")),
    ("mlflow", "mlflows.mlflow.opendatahub.io", lambda o: next((("ready" if x["status"] == "True" else "NOT READY") for x in o.get("status", {}).get("conditions", []) if x["type"] == "Available"), "?")),
]
for label, res, fn in checks:
    d = oc("get", res, "-A", "-o", "json")
    items = d["items"] if d else []
    print(f"  {label:22} {len(items):4}  {dict(collections.Counter(str(fn(o)) for o in items))}")

print("=== expected inventory vs cluster")
inv = json.load(open(f"{POP}/expected-inventory.json"))
kinds = collections.defaultdict(set)
for o in inv:
    kinds[o["kind"]].add((o["namespace"], o["name"]))
plural = {"Namespace": "namespaces", "Notebook": "notebooks.kubeflow.org", "InferenceService": "inferenceservices.serving.kserve.io", "ServingRuntime": "servingruntimes.serving.kserve.io",
          "PersistentVolumeClaim": "pvc", "RoleBinding": "rolebindings", "Secret": "secrets", "DataSciencePipelinesApplication": "dspa", "FeatureStore": "featurestore",
          "MCPServer": "mcpserver", "TrustyAIService": "trustyaiservice", "RayCluster": "raycluster", "TrainJob": "trainjob", "SparkApplication": "sparkapplication",
          "LocalQueue": "localqueue", "ModelRegistry": "modelregistries.modelregistry.opendatahub.io", "ClusterQueue": "clusterqueue", "ResourceFlavor": "resourceflavor", "ResourceQuota": "resourcequota", "LimitRange": "limitrange", "ServiceAccount": "serviceaccount",
          "OGXServer": "ogxservers.ogx.io", "EvalHub": "evalhubs.trustyai.opendatahub.io", "InferenceGraph": "inferencegraphs.serving.kserve.io",
          "MLflow": "mlflows.mlflow.opendatahub.io", "Deployment": "deployments.apps", "Service": "services", "ConfigMap": "configmaps"}
for kind, want in sorted(kinds.items()):
    d = oc("get", plural.get(kind, kind), "-A", "-o", "json", timeout=240)
    have = {(o["metadata"].get("namespace"), o["metadata"]["name"]) for o in (d["items"] if d else [])}
    missing = want - have
    print(f"  {kind:32} expected {len(want):4} missing {len(missing):3} {sorted(missing)[:3] if missing else ''}")
