"""§10.1 Expected inventory and §10.2 per-kind status checks.

Every object the generator created (or recorded as created on a user's behalf) must exist, and its
state must match what was expected. A stateful kind with no registered check fails, so a new
workload type can't be added without a check."""
import collections

from .. import kube
from ..report import FAIL

CAT_INV, CAT_STATUS = "inventory", "status"


def cond(o, t, want="True"):
    return any(c.get("type") == t and c.get("status") == want for c in o.get("status", {}).get("conditions", []))


def _nb(o, st):
    stopped = "kubeflow-resource-stopped" in o["metadata"].get("annotations", {})
    if st == "stopped":
        return stopped, "stop annotation present" if stopped else "stop annotation missing (it starts)"
    return (not stopped and o.get("status", {}).get("readyReplicas") == 1), f"readyReplicas={o.get('status', {}).get('readyReplicas')}"


def _isvc(o, st):
    stopped = o["metadata"].get("annotations", {}).get("serving.kserve.io/stop") == "true"
    if st == "stopped":
        return stopped, "stopped" if stopped else "stop annotation missing"
    return (not stopped and cond(o, "Ready")), "Ready" if cond(o, "Ready") else "not Ready"


def _ready(t="Ready"):
    return lambda o, st: (cond(o, t), f"{t}={'True' if cond(o, t) else 'False'}")


CHECKS = {
    "Notebook": _nb,
    "InferenceService": _isvc,
    "LLMInferenceService": _ready(),
    "InferenceGraph": _ready(),
    "DataSciencePipelinesApplication": _ready(),
    "FeatureStore": lambda o, st: (o.get("status", {}).get("phase") == "Ready", f"phase={o.get('status', {}).get('phase')}"),
    "MCPServer": _ready(),
    "MCPServerRegistration": _ready(),
    "MCPVirtualServer": lambda o, st: (True, "exists"),
    "TrustyAIService": _ready("Available"),
    "ModelRegistry": _ready("Available"),
    "OGXServer": lambda o, st: (o.get("status", {}).get("phase") == "Ready", f"phase={o.get('status', {}).get('phase')}"),
    "EvalHub": _ready(),
    "MLflow": _ready("Available"),
    "RayCluster": lambda o, st: ((o.get("status", {}).get("state") == "suspended") if st == "suspended" else (o.get("status", {}).get("state") == "ready"),
                                 f"state={o.get('status', {}).get('state')}"),
    "TrainJob": lambda o, st: (cond(o, "Complete"), "Complete" if cond(o, "Complete") else "not Complete"),
    "SparkApplication": lambda o, st: (o.get("status", {}).get("applicationState", {}).get("state") == "COMPLETED",
                                       f"state={o.get('status', {}).get('applicationState', {}).get('state')}"),
    "Deployment": lambda o, st: (o.get("status", {}).get("availableReplicas", 0) >= o["spec"].get("replicas", 1),
                                 f"available {o.get('status', {}).get('availableReplicas', 0)}/{o['spec'].get('replicas', 1)}"),
    "PersistentVolumeClaim": lambda o, st: (o.get("status", {}).get("phase") == "Bound" or st == "unbound-ok", f"phase={o.get('status', {}).get('phase')}"),
    "RateLimitPolicy": _ready("Enforced"),
    "TelemetryPolicy": _ready("Accepted"),
}


def run(r, ctx):
    inv = ctx["inventory"]
    by_kind = collections.defaultdict(list)
    for o in inv:
        by_kind[o["kind"]].append(o)
    for kind, items in sorted(by_kind.items()):
        have = {}
        for o in kube.list_all(kind):
            have[(o["metadata"].get("namespace"), o["metadata"]["name"])] = o
        missing = [f"{i['namespace']}/{i['name']}" if i["namespace"] else i["name"] for i in items if (i["namespace"], i["name"]) not in have]
        r.check(CAT_INV, f"{kind}: all {len(items)} present", not missing, f"missing {len(missing)}: {missing[:8]}")

        stateful = [i for i in items if i["state"] != "static"]
        if not stateful:
            continue
        fn = CHECKS.get(kind)
        if fn is None:
            r.add(CAT_STATUS, f"{kind}: has a status check", FAIL, f"{len(stateful)} objects expect a state but no check is registered")
            continue
        bad = []
        for i in stateful:
            o = have.get((i["namespace"], i["name"]))
            if o is None:
                continue
            ok, why = fn(o, i["state"])
            if not ok:
                bad.append(f"{i['namespace']}/{i['name']} expected {i['state']}: {why}")
        r.check(CAT_STATUS, f"{kind}: {len(stateful)} in expected state", not bad, "; ".join(bad[:8]) + (f" (+{len(bad) - 8} more)" if len(bad) > 8 else ""))
