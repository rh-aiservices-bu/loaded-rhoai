"""§10.4 Stopped workloads: would they start? §10.6 identity and RBAC. §10.8 load and MaaS usage.
Variant effect probes (PLAN.md §6)."""
import datetime
import json
import random
import re

from .. import kube, probes
from ..report import SKIP, WARN

APPS = "redhat-ods-applications"


def startability(r, ctx):
    cat = "startability"
    inv = ctx["inventory"]
    streams = {s["metadata"]["name"]: {t["tag"] for t in s.get("status", {}).get("tags", []) if t.get("items")} for s in kube.list_all("ImageStream", APPS)}
    pvcs = {(p["metadata"]["namespace"], p["metadata"]["name"]) for p in kube.list_all("PersistentVolumeClaim")}
    nbs = {(o["metadata"]["namespace"], o["metadata"]["name"]): o for o in kube.list_all("Notebook")}
    stopped = [o for o in inv if o["kind"] == "Notebook" and o["state"] == "stopped"]
    bad = []
    for i in stopped:
        nb = nbs.get((i["namespace"], i["name"]))
        if not nb:
            continue
        sel = nb["metadata"].get("annotations", {}).get("notebooks.opendatahub.io/last-image-selection", "")
        stream, _, tag = sel.partition(":")
        if stream and tag and tag not in streams.get(stream, set()):
            bad.append(f"{i['namespace']}/{i['name']}: image {sel} no longer in its ImageStream")
        for v in nb["spec"]["template"]["spec"].get("volumes", []):
            claim = v.get("persistentVolumeClaim", {}).get("claimName")
            if claim and (i["namespace"], claim) not in pvcs:
                bad.append(f"{i['namespace']}/{i['name']}: PVC {claim} missing")
    r.check(cat, f"{len(stopped)} stopped workbenches: image tag and PVCs still exist", not bad, "; ".join(bad[:8]))

    runtimes = {(o["metadata"]["namespace"], o["metadata"]["name"]) for o in kube.list_all("ServingRuntime")}
    isvcs = {(o["metadata"]["namespace"], o["metadata"]["name"]): o for o in kube.list_all("InferenceService")}
    stopped_m = [o for o in inv if o["kind"] == "InferenceService" and o["state"] == "stopped"]
    bad = [f"{i['namespace']}/{i['name']}: runtime {isvcs[(i['namespace'], i['name'])]['spec']['predictor'].get('model', {}).get('runtime')} missing"
           for i in stopped_m if (i["namespace"], i["name"]) in isvcs
           and (i["namespace"], isvcs[(i["namespace"], i["name"])]["spec"]["predictor"].get("model", {}).get("runtime")) not in runtimes]
    r.check(cat, f"{len(stopped_m)} stopped models: serving runtime still exists", not bad, "; ".join(bad[:8]))

    # Send the "start" change through admission without applying it, for a sample that rotates daily.
    rng = random.Random(datetime.date.today().isoformat())
    sample = stopped if ctx.get("exhaustive") else rng.sample(stopped, min(ctx.get("sample", 5), len(stopped)))
    for i in sample:
        rc, out, err = kube.oc("annotate", "notebook", i["name"], "-n", i["namespace"], "kubeflow-resource-stopped-", "--dry-run=server")
        r.check(cat, f"start {i['namespace']}/{i['name']} passes admission (dry run)", rc == 0, (out or err).strip()[:200])
    for i in (stopped_m if ctx.get("exhaustive") else rng.sample(stopped_m, min(2, len(stopped_m)))):
        rc, out, err = kube.oc("annotate", "isvc", i["name"], "-n", i["namespace"], "serving.kserve.io/stop=false", "--overwrite", "--dry-run=server")
        r.check(cat, f"start model {i['namespace']}/{i['name']} passes admission (dry run)", rc == 0, (out or err).strip()[:200])


def identity(r, ctx):
    cat = "identity"
    users = json.load(open(f"{ctx['pop_dir']}/users.json"))
    have = {u["metadata"]["name"] for u in kube.list_all("users.user.openshift.io")}
    missing = sorted(set(users) - have)
    r.check(cat, f"all {len(users)} generated users have logged in (User objects exist)", not missing, f"missing {len(missing)}: {missing[:8]}")
    groups = {g["metadata"]["name"]: set(g.get("users") or []) for g in kube.list_all("groups.user.openshift.io")}
    wrong = [n for n, u in users.items() if n in have and n not in groups.get(u["team"], set())]
    r.check(cat, "group membership synced from Keycloak (each user in their team group)", not wrong, f"not in team group: {wrong[:8]}")
    subjects_missing = []
    for rb in kube.list_all("RoleBinding", selector=None):
        if not rb["metadata"]["namespace"].startswith("lr-"):
            continue
        for s in rb.get("subjects") or []:
            if s["kind"] == "User" and s["name"] not in have:
                subjects_missing.append(f"{rb['metadata']['namespace']}/{rb['metadata']['name']}: user {s['name']}")
            if s["kind"] == "Group" and s["name"] not in groups and not s["name"].startswith("system:"):
                subjects_missing.append(f"{rb['metadata']['namespace']}/{rb['metadata']['name']}: group {s['name']}")
    r.check(cat, "every RoleBinding subject in team projects exists", not subjects_missing, "; ".join(subjects_missing[:8]))
    admins = groups.get("rhoai-admins", set())
    crb = [b for b in kube.list_all("clusterrolebindings.rbac.authorization.k8s.io") if b["roleRef"]["name"] == "cluster-reader"
           and any(s["kind"] == "Group" and s["name"] == "rhoai-admins" for s in b.get("subjects") or [])]
    r.check(cat, "rhoai-admins can see every project (cluster-reader)", bool(crb) and bool(admins), f"{len(admins)} admins")


def load(r, ctx):
    cat = "load"
    pods = [p for p in kube.list_all("Pod", "loaded-rhoai-load", {"app": "loadgen"}) if p["status"].get("phase") == "Running"]
    if not pods:
        r.add(cat, "load generator running", SKIP if ctx.get("no_load") else "fail", "no running loadgen pod")
        return
    rc, out, _ = kube.oc("exec", "-n", "loaded-rhoai-load", pods[0]["metadata"]["name"], "--", "python3", "-c",
                         "import urllib.request;print(urllib.request.urlopen('http://localhost:9100/metrics').read().decode())")
    codes, users, unexpected = {}, set(), 0
    for line in out.splitlines():
        if line.startswith("loadgen_requests_total"):
            m = dict(re.findall(r'(\w+)="([^"]*)"', line))
            v = float(line.split()[-1])
            codes[m["code"]] = codes.get(m["code"], 0) + v
            users.add(m["user"])
            if m["expected"] == "false":
                unexpected += v
    r.check(cat, "load generator: every load user is sending", len(users) >= 60, f"{len(users)} users; codes {dict((k, int(v)) for k, v in codes.items())}")
    total = sum(codes.values()) or 1
    r.check(cat, "load generator: no unexpected responses", unexpected / total < 0.001,
            f"{int(unexpected)} unexpected of {int(total)} ({100 * unexpected / total:.3f}%); 429s are expected only for power users", blocking=False)
    # Per-user attribution: every load user appears in MaaS's own counters with a user label.
    # MaaS's counters are scraped by user workload monitoring, so ask Thanos, which sees both stacks.
    tq = [p["metadata"]["name"] for p in kube.list_all("Pod", "openshift-monitoring", {"app.kubernetes.io/name": "thanos-query"})]
    rc, out, _ = kube.oc("exec", "-n", "openshift-monitoring", tq[0] if tq else "missing", "-c", "thanos-query", "--", "curl", "-s", "--max-time", "40",
                         "http://localhost:9090/api/v1/query?query=" + "sum%20by%20(user)%20(authorized_hits)", timeout=90)
    try:
        maas_users = {s["metric"].get("user") for s in json.loads(out)["data"]["result"]}
    except Exception:
        maas_users = set()
    missing = sorted(users - maas_users)
    r.check(cat, "MaaS attributes usage to every load user (authorized_hits has their user label)", not missing, f"missing {len(missing)}: {missing[:8]}")


def variants(r, ctx):
    cat = "variants"
    for o in ctx["inventory"]:
        for p in o.get("probes", []):
            ok, detail = probes.run(p)
            r.check(cat, f"{o['variant']}: {p['type']} {p.get('path', p.get('env', p.get('kind', '')))}", ok, detail)
    for s in ctx.get("skipped", []):
        r.add(cat, f"{s['variant']} (gated off for this release)", WARN, s["reason"], blocking=False)
