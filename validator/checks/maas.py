"""MaaS end to end (PLAN.md §7, §10.7). The load generator proves continuous per-user traffic, but
its keys were minted when it started. This section checks what a new or returning user does after
an upgrade: the guide's own verification and OIDC tests, a fresh API key per tier that resolves to
the right subscription and answers a chat, and optionally a maaspal run."""
import json
import os
import re
import ssl
import subprocess
import urllib.error
import urllib.parse
import urllib.request

from .. import kube
from ..report import SKIP

CAT = "maas"
CTX = ssl._create_unverified_context()
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def _call(url, body=None, token=None, form=None, method=None):
    headers, data = {}, None
    if form is not None:
        data, headers["Content-Type"] = urllib.parse.urlencode(form).encode(), "application/x-www-form-urlencoded"
    elif body is not None:
        data, headers["Content-Type"] = json.dumps(body).encode(), "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=headers, method=method), context=CTX, timeout=60) as r:
            raw = r.read()
            return r.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except Exception:
            return e.code, {}
    except Exception as e:
        return 0, {"error": str(e)[:200]}


def _guide_script(r, guide, rel, label, args=()):
    path = os.path.join(guide, rel)
    if not os.path.exists(path):
        r.add(CAT, label, SKIP, f"{rel} not found; the guide is fetched into .cache/ by the install", blocking=False)
        return
    p = subprocess.run(["bash", path, *args], cwd=guide, capture_output=True, text=True, timeout=1800)
    out = ANSI.sub("", p.stdout + p.stderr)
    n = 0
    for line in out.splitlines():
        m = re.match(r"\s*\[(PASS|FAIL)\]\s*(.*)", line)
        if m:
            n += 1
            r.check(CAT, f"{label}: {m.group(2)[:90]}", m.group(1) == "PASS", m.group(2)[:300])
    if n == 0:
        r.check(CAT, label, p.returncode == 0, out.strip()[-300:] or f"exit {p.returncode}, no output")


def run(r, ctx):
    root, domain = ctx["root"], ctx["domain"]
    guide = os.path.join(root, ".cache", "rhoai-maas-guide")
    _guide_script(r, guide, "manifests/06-verification/verify.sh", "guide verify.sh")
    _guide_script(r, guide, "manifests/09-external-oidc/test-external-oidc.sh", "guide OIDC test")

    # A fresh key per tier, as a user who has never used MaaS on this release would get one.
    users = json.load(open(os.path.join(ctx["pop_dir"], "users.json")))
    maas, issuer = f"https://maas.{domain}", f"https://keycloak-maas-keycloak.{domain}/realms/maas"
    for tier in sorted({u["tier"] for u in users.values()}):
        name = sorted(n for n, u in users.items() if u["tier"] == tier and not u.get("admin"))[-1]
        code, tok = _call(f"{issuer}/protocol/openid-connect/token",
                          form={"grant_type": "password", "client_id": "maas-oidc", "scope": "openid", "username": name, "password": users[name]["password"]})
        if code != 200:
            r.check(CAT, f"{tier}: {name} logs in to Keycloak", False, f"http {code} {json.dumps(tok)[:160]}")
            continue
        code, key = _call(f"{maas}/maas-api/v1/api-keys", {"name": "loaded-rhoai-validate", "expiresIn": "1h"}, token=tok["access_token"])
        want_sub = "tier-" + tier.split("-", 1)[1]
        r.check(CAT, f"{tier}: {name} mints a new API key bound to {want_sub}", code in (200, 201) and key.get("subscription") == want_sub,
                f"http {code}, subscription {key.get('subscription')}")
        if code not in (200, 201):
            continue
        code, models = _call(f"{maas}/v1/models", token=key.get("key"), method="GET")
        ids = sorted(m["id"] for m in models.get("data", [])) if code == 200 else []
        ours = [i for i in ids if "/lr-models/" in i]
        r.check(CAT, f"{tier}: the new key lists the tier's models", bool(ours), f"http {code}, {len(ids)} models: {ids[:4]}")
        if ours:
            code, resp = _call(f"{maas}/v1/chat/completions", {"model": ours[0], "max_tokens": 8, "messages": [{"role": "user", "content": "hello"}]}, token=key.get("key"))
            r.check(CAT, f"{tier}: the new key answers a chat", code == 200 and "choices" in resp, f"http {code} {json.dumps(resp)[:160]}")
        if key.get("id"):
            _call(f"{maas}/maas-api/v1/api-keys/{key['id']}", token=tok["access_token"], method="DELETE")

    # maaspal, when asked: a plan file of [[scenario, {overrides}], ...]
    plan = ctx.get("maaspal_plan")
    if not plan:
        r.add(CAT, "maaspal", SKIP, "not requested (--maaspal-plan <file>)", blocking=False)
        return
    pods = [p["metadata"]["name"] for p in kube.list_all("Pod", "cp-maaspal") if "bff" in p["metadata"]["name"] and p["status"].get("phase") == "Running"]
    if not pods:
        r.check(CAT, "maaspal BFF running", False, "no running maaspal-bff pod in cp-maaspal")
        return
    tok = kube.oc("whoami", "-t")[1].strip()
    p = subprocess.run(["oc", "exec", "-i", "-n", "cp-maaspal", pods[0], "--", "env", f"TOKEN={tok}", f"PLAN={open(plan).read()}", "python3", "-"],
                       stdin=open(os.path.join(root, "tools/maaspal_run.py")), capture_output=True, text=True, timeout=7200)
    res = next((json.loads(l[len("RESULTS_JSON "):]) for l in p.stdout.splitlines() if l.startswith("RESULTS_JSON ")), None)
    if res is None:
        r.check(CAT, "maaspal ran", False, (p.stdout + p.stderr)[-300:])
        return
    for x in res:
        ok = x.get("status") in ("PASS", "PASSED", "COMPLETED") and not x.get("failed")
        r.check(CAT, f"maaspal {x['scenario']}", ok, f"{x.get('status')} failed assertions {x.get('failed')} run {x.get('run_id')}")
