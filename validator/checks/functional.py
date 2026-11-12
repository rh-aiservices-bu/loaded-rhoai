"""§10.3 Functional probes: every running workload gets a real request, not just a status read."""
import json
import os
import re
import subprocess
import sys

from .. import kube
from ..report import SKIP

CAT = "functional"
CHAT = {"model": "sim", "messages": [{"role": "user", "content": "hello from loaded-rhoai"}], "max_tokens": 8}


def _toolbox(root, reqs):
    rc, _, err = kube.oc("apply", "-f", os.path.join(root, "manifests/infra/toolbox.yaml"))
    kube.oc("rollout", "status", "deploy/lr-toolbox", "-n", "lr-infra", "--timeout=180s")
    tok = kube.oc("whoami", "-t")[1].strip()
    p = subprocess.run(["oc", "exec", "-i", "-n", "lr-infra", "deploy/lr-toolbox", "--", "env", f"TOKEN={tok}", f"REQS={json.dumps(reqs)}", "python3", "-"],
                       stdin=open(os.path.join(root, "tools/http_batch.py")), capture_output=True, text=True, timeout=600)
    try:
        return json.loads(p.stdout.strip().splitlines()[-1])
    except Exception:
        return {q["id"]: {"code": 0, "body": (p.stderr or p.stdout)[:300]} for q in reqs}


def run(r, ctx):
    inv, root = ctx["inventory"], ctx["root"]
    reqs, expect = [], {}

    def add(rid, label, req, ok):
        reqs.append({"id": rid, **req})
        expect[rid] = (label, ok)

    ok_chat = lambda res: res["code"] == 200 and '"choices"' in res["body"]
    for o in inv:
        k, ns, n = o["kind"], o["namespace"], o["name"]
        chat = dict(CHAT, model=o.get("servedModel", "sim"))
        if k == "InferenceService" and o["state"] == "running":
            add(f"isvc/{ns}/{n}", f"InferenceService {ns}/{n} answers a chat", {"method": "POST", "url": f"http://{n}-predictor.{ns}.svc.cluster.local/v1/chat/completions", "body": chat}, ok_chat)
        elif o.get("chatUrl"):
            add(f"chat/{ns}/{n}", f"{k} {ns}/{n} answers a chat", {"method": "POST", "url": o["chatUrl"], "body": chat}, ok_chat)
        elif k == "InferenceGraph":
            add(f"ig/{ns}/{n}", f"InferenceGraph {ns}/{n} routes a chat", {"method": "POST", "url": f"https://{n}.{ns}.svc/", "body": CHAT, "auth": True}, ok_chat)
        elif k == "EvalHub":
            add(f"eh/{ns}/{n}", f"EvalHub {ns}/{n} healthy", {"url": f"https://{n}.{ns}.svc:8443/api/v1/health", "auth": True},
                lambda res: res["code"] == 200 and "healthy" in res["body"])
    for ws, want in ctx["seed"].get("mlflow", {}).items():
        add(f"mlflow/{ws}", f"MLflow workspace {ws} has its {want['experiments']} experiments",
            {"method": "POST", "url": "https://mlflow.redhat-ods-applications.svc:8443/mlflow/api/2.0/mlflow/experiments/search",
             "body": {"max_results": 100}, "auth": True, "headers": {"X-MLflow-Workspace": ws}},
            lambda res, w=want: res["code"] == 200 and len([e for e in json.loads(res["body"] or "{}").get("experiments", []) if "-experiment-" in e["name"]]) >= w["experiments"])
    if reqs:
        results = _toolbox(root, reqs)
        for rid, (label, ok) in expect.items():
            res = results.get(rid, {"code": 0, "body": "no result"})
            try:
                good = ok(res)
            except Exception:
                good = False
            r.check(CAT, label, good, f"http {res['code']}: {res['body'][:200]}")

    # OGX admits only same-project traffic, so ask from inside each server's own pod.
    for o in [o for o in inv if o["kind"] == "OGXServer" and not o.get("createdBy")]:
        pods = [p for p in kube.list_all("Pod", o["namespace"], {"app.kubernetes.io/instance": o["name"]}) if p["status"].get("phase") == "Running"]
        if not pods:
            r.check(CAT, f"OGX {o['namespace']}/{o['name']} answers a chat", False, "no running pod")
            continue
        code = ("import json,urllib.request\nm=[x['id'] for x in json.load(urllib.request.urlopen('http://localhost:8321/v1/models',timeout=30))['data']"
                " if x.get('custom_metadata',{}).get('model_type','llm')=='llm'][0]\n"
                "r=urllib.request.urlopen(urllib.request.Request('http://localhost:8321/v1/chat/completions',data=json.dumps({'model':m,'messages':[{'role':'user','content':'hi'}],'max_tokens':8}).encode(),"
                "headers={'Content-Type':'application/json'}),timeout=60)\nprint(r.status)")
        rc, out, err = kube.oc("exec", "-n", o["namespace"], pods[0]["metadata"]["name"], "--", "python3", "-c", code, timeout=120)
        r.check(CAT, f"OGX {o['namespace']}/{o['name']} answers a chat", rc == 0 and out.strip() == "200", (out or err).strip()[-200:])

    # Playgrounds and the MCP Gateway, as the users who own them.
    seed_file = os.path.join(ctx["pop_dir"], "seed.json")
    if ctx["seed"].get("playgrounds"):
        p = subprocess.run([sys.executable, os.path.join(root, "tools/playgrounds.py"), ctx["domain"], os.path.join(ctx["pop_dir"], "users.json"), seed_file, "--check"],
                           capture_output=True, text=True, timeout=1800)
        for line in p.stdout.splitlines():
            m = re.match(r"\s+(\S+)\s+(\S+): chat http=(\d+) (.*)", line)
            if m:
                outcome = m.group(4).strip()
                if outcome == "rate-limited":
                    r.add(CAT, f"playground {m.group(1)} chats as {m.group(2)}", "warn",
                          "reached MaaS but the user's tier was out of tokens; the playground reports MaaS's 429 as HTTP 500", blocking=False)
                else:
                    r.check(CAT, f"playground {m.group(1)} chats as {m.group(2)}", outcome == "ok", f"http {m.group(3)} {outcome[:160]}")
    regs = [o for o in inv if o["kind"] == "MCPServerRegistration"]
    if regs:
        users = json.load(open(os.path.join(ctx["pop_dir"], "users.json")))
        sys.path.insert(0, os.path.join(root, "tools"))
        from user_token import token
        url = f"https://mcp.{ctx['domain']}/mcp"
        for reg in regs:
            team = reg["namespace"].replace("lr-", "")
            member = sorted(n for n, u in users.items() if u["team"] == team and not u.get("admin"))[0]
            tok = token(f"oauth-openshift.{ctx['domain']}", member, users[member]["password"])
            prefix = team.replace("-", "") + "_"
            p = subprocess.run([sys.executable, os.path.join(root, "tools/mcp_probe.py"), url, "--token", tok or "",
                                "--call", prefix + "pods_list_in_namespace", json.dumps({"namespace": reg["namespace"]})],
                               capture_output=True, text=True, timeout=180)
            r.check(CAT, f"MCP Gateway: {member} calls {prefix}pods_list_in_namespace", p.returncode == 0, (p.stdout + p.stderr).strip().splitlines()[-1][:200] if (p.stdout + p.stderr).strip() else "no output")
        p = subprocess.run([sys.executable, os.path.join(root, "tools/mcp_probe.py"), url], capture_output=True, text=True, timeout=60)
        r.check(CAT, "MCP Gateway refuses a caller without a token", p.returncode != 0 and "401" in (p.stdout + p.stderr), (p.stdout + p.stderr).strip()[-120:])
    else:
        r.add(CAT, "MCP Gateway", SKIP, "no MCP server registrations in this population")
