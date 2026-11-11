"""§10.0 Platform health: nodes, cluster operators, OLM, DSCI/DSC conditions and firing alerts."""
import json
import os
import urllib.parse

from .. import kube
from ..report import PASS, SKIP

CAT = "platform"


def _prom(ns, pod, container, expr, scheme="http"):
    # RHOAI's own Prometheus serves HTTPS and wants a bearer token; the pod's service account works.
    url = f"{scheme}://localhost:9090/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    rc, out, _ = kube.oc("exec", "-n", ns, pod, "-c", container, "--", "sh", "-c",
                         f'curl -sk --max-time 40 -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" "{url}"', timeout=90)
    try:
        return json.loads(out)["data"]["result"]
    except Exception:
        return None


def run(r, ctx):
    nodes = kube.list_all("Node")
    bad = [n["metadata"]["name"] for n in nodes if not any(c["type"] == "Ready" and c["status"] == "True" for c in n["status"]["conditions"])]
    r.check(CAT, "nodes Ready", not bad and nodes, f"{len(nodes)} nodes; not Ready: {bad}")

    cos = kube.list_all("clusteroperators.config.openshift.io")
    def st(co, t):
        return next((c["status"] for c in co["status"].get("conditions", []) if c["type"] == t), "Unknown")
    bad = [co["metadata"]["name"] for co in cos if st(co, "Available") != "True" or st(co, "Degraded") == "True"]
    r.check(CAT, "cluster operators available, not degraded", not bad, f"{len(cos)} operators; problems: {bad}")

    subs = kube.list_all("subscriptions.operators.coreos.com")
    csvs = {(c["metadata"]["namespace"], c["metadata"]["name"]): c.get("status", {}).get("phase") for c in kube.list_all("clusterserviceversions.operators.coreos.com")}
    bad = [f"{s['metadata']['namespace']}/{s['spec']['name']}" for s in subs
           if csvs.get((s["metadata"]["namespace"], s.get("status", {}).get("installedCSV"))) != "Succeeded"]
    r.check(CAT, "every Subscription's CSV Succeeded", not bad, f"{len(subs)} subscriptions; not Succeeded: {bad}")
    unpinned = [f"{s['metadata']['namespace']}/{s['spec']['name']}" for s in subs if s["spec"].get("installPlanApproval") != "Manual"]
    r.check(CAT, "every Subscription pinned to Manual approval", not unpinned, f"Automatic: {unpinned}", blocking=False)
    # Check whatever RHOAI is installed. After an upgrade it's no longer the release the population
    # was built for (ctx["rhoai_csv"]); the upgrade section reports the change.
    installed = {n: ph for (ns, n), ph in csvs.items() if ns == "redhat-ods-operator" and n.startswith("rhods-operator.")}
    ok = len(installed) == 1 and list(installed.values())[0] == "Succeeded"
    note = "" if ctx["rhoai_csv"] in installed else f"; the population was built on {ctx['rhoai_csv']}"
    r.check(CAT, "RHOAI operator installed and Succeeded", ok, f"{installed}{note}")
    # --expect-rhoai: the release the operator was meant to reach. Catches an upgrade that silently
    # didn't happen, e.g. a channel switch with no upgrade edge leaves 3.5.2 reporting AtLatestKnown.
    want = ctx.get("expect_rhoai")
    if want:
        got = [n.replace("rhods-operator.", "") for n in installed]
        r.check(CAT, f"RHOAI is at the expected release {want}", any(g == want or g.startswith(want + ".") for g in got),
                f"installed {got}; the Subscription is on channel "
                f"{next((x['spec'].get('channel') for x in subs if x['spec']['name'] == 'rhods-operator'), '?')}")

    for kind, name in (("dscinitializations.dscinitialization.opendatahub.io", "default-dsci"), ("datascienceclusters.datasciencecluster.opendatahub.io", "default-dsc")):
        obj = kube.get(kind, None, name)
        if not obj:
            r.check(CAT, f"{name} exists", False, "missing")
            continue
        conds = obj.get("status", {}).get("conditions", [])
        # Degraded and Progressing are "bad when True"; every other condition is "bad when not True".
        bad = [f"{c['type']}={c['status']} ({c.get('reason')}: {(c.get('message') or '')[:100]})" for c in conds
               if c["status"] != "True" and c.get("reason") not in ("Removed", "NotApplicable") and c["type"] not in ("Degraded", "Progressing")]
        r.check(CAT, f"{name}: every condition True for enabled components", not bad, "; ".join(bad) or f"{len(conds)} conditions True")
        degraded = [f"{c['type']} ({c.get('reason')}: {(c.get('message') or '')[:160]})" for c in conds if c["type"] == "Degraded" and c["status"] == "True"]
        r.check(CAT, f"{name}: not Degraded", not degraded, "; ".join(degraded) or "Degraded is not True")

    # Each component CR (one per DSC component, components.platform.opendatahub.io) carries its own
    # Ready and Degraded conditions. A DSC that's only "not Ready" doesn't say why; these do.
    rc, out, _ = kube.oc("api-resources", "--api-group=components.platform.opendatahub.io", "-o", "name")
    for res in sorted(out.split()):
        for o in kube.list_all(res):
            conds = o.get("status", {}).get("conditions", [])
            if not conds:
                continue
            name = f"{o['kind']}/{o['metadata']['name']}"
            notready = [f"{c['type']}={c['status']} ({c.get('reason')}: {(c.get('message') or '')[:160]})" for c in conds
                        if c["type"] == "Ready" and c["status"] != "True"]
            degraded = [f"Degraded ({c.get('reason')}: {(c.get('message') or '')[:160]})" for c in conds if c["type"] == "Degraded" and c["status"] == "True"]
            r.check(CAT, f"component {name} Ready and not Degraded", not notready and not degraded, "; ".join(notready + degraded) or "Ready")

    # Use the allowlist of the installed release when the repo has one; otherwise the build release's,
    # and say so, because known issues differ between releases.
    inst_ver = next(iter(installed), "").replace("rhods-operator.", "")
    vdir = os.path.join(os.path.dirname(ctx["version_dir"]), inst_ver)
    if not os.path.exists(os.path.join(vdir, "alert-allowlist.json")):
        vdir = ctx["version_dir"]
    allow_note = f" (allowlist from versions/{os.path.basename(vdir)})"
    allow = json.load(open(os.path.join(vdir, "alert-allowlist.json")))
    def allowed(m):
        for a in allow:
            if a["alert"] == m.get("alertname") and all(m.get(k) == v for k, v in a.get("match", {}).items()):
                return a["reason"]
        return None
    stacks = [("cluster", "openshift-monitoring", "prometheus-k8s-0", "prometheus"),
              ("RHOAI", "redhat-ods-monitoring", "prometheus-data-science-monitoringstack-0", "prometheus")]
    for label, ns, pod, cont in stacks:
        res = _prom(ns, pod, cont, 'ALERTS{alertstate="firing",severity=~"warning|critical"}', "https" if label == "RHOAI" else "http")
        if res is None:
            r.add(CAT, f"no unexpected alerts ({label})", SKIP, f"could not query {ns}/{pod}")
            continue
        unexpected, known = [], []
        for a in res:
            m = a["metric"]
            desc = f"{m.get('alertname')} ns={m.get('namespace', '')} {m.get('pod', m.get('daemonset', m.get('job', '')))}"
            (known if allowed(m) else unexpected).append(desc)
        r.check(CAT, f"no unexpected alerts ({label})", not unexpected, f"unexpected: {unexpected}; allowlisted{allow_note}: {sorted(set(known))}")
