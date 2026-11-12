"""OpenAI chat API behaviour: streaming and non-streaming requests, and requests with invalid
parameters, against the real vLLM models (directly) and the MaaS models (through the gateway).

The simulator isn't held to the invalid-parameter rules: it may accept anything, which says nothing
about the product. Through MaaS, what matters is that streams and errors pass the gateway intact."""
import json
import os
import ssl
import subprocess
import urllib.parse
import urllib.request

from .. import kube
from ..report import SKIP

CAT = "api"
INVALID = {"bad-temperature": "temperature -1", "bad-top_p": "top_p 1.5", "bad-max_tokens": "max_tokens -1",
           "bad-model": "a model that doesn't exist", "bad-json": "a body that isn't JSON"}


def _probe(root, targets):
    kube.oc("apply", "-f", os.path.join(root, "manifests/infra/toolbox.yaml"))
    kube.oc("rollout", "status", "deploy/lr-toolbox", "-n", "lr-infra", "--timeout=180s")
    tok = kube.oc("whoami", "-t")[1].strip()
    p = subprocess.run(["oc", "exec", "-i", "-n", "lr-infra", "deploy/lr-toolbox", "--", "env", f"TOKEN={tok}", f"TARGETS={json.dumps(targets)}", "python3", "-"],
                       stdin=open(os.path.join(root, "tools/chat_api_probe.py")), capture_output=True, text=True, timeout=1800)
    try:
        return json.loads(p.stdout.strip().splitlines()[-1]), ""
    except Exception:
        return {}, (p.stderr or p.stdout)[-300:]


def _judge(r, label, res, strict_invalid, blocking=True):
    ok = res.get("ok", {})
    r.check(CAT, f"{label}: non-streaming chat", ok.get("code") == 200 and ok.get("content") and ok.get("usage"),
            f"http {ok.get('code')} content={ok.get('content')} usage={ok.get('usage')} finish={ok.get('finish')} {ok.get('error', ok.get('body', ''))}", blocking)
    s = res.get("stream", {})
    r.check(CAT, f"{label}: streaming chat (SSE, deltas, usage, [DONE])",
            s.get("code") == 200 and s.get("ctype") == "text/event-stream" and s.get("deltas", 0) >= 1 and s.get("done") and s.get("usage") and not s.get("bad_event"),
            f"http {s.get('code')} {s.get('ctype')} events={s.get('events')} deltas={s.get('deltas')} usage={s.get('usage')} done={s.get('done')} "
            f"{s.get('bad_event', '')}{s.get('body', '')}", blocking)
    for case, what in INVALID.items():
        x = res.get(case, {})
        code = x.get("code", 0)
        want = (404,) if case == "bad-model" else (400, 422)
        good = code in want and x.get("json")
        detail = f"http {code} json={x.get('json')} {x.get('error', x.get('body', ''))}"
        if strict_invalid:
            # 200 means the bad value was accepted; 5xx means the server failed on it. Both are wrong.
            r.check(CAT, f"{label}: rejects {what} with {'/'.join(map(str, want))}", good, detail, blocking)
        elif code == 0 or code >= 500:
            # No response at all, or a server error: the gateway failed on a client mistake. On RHCL
            # 1.4.3 a backend 400 for max_tokens -1 left the connection open ~60 s with nothing sent,
            # on two of three tiers (FINDINGS.md). That's a real fault, not simulator leniency.
            r.check(CAT, f"{label}: answers {what} promptly with a client error", False,
                    detail + f" after {x.get('secs')} s (the gateway failed or hung on a client error)")
        else:
            # 200: the simulator accepted the value, which says nothing about the product.
            r.add(CAT, f"{label}: {what}", "pass" if 400 <= code < 500 else "warn",
                  detail + ("" if 400 <= code < 500 else " (the simulator accepted it)"), blocking=False)


def run(r, ctx):
    inv, root = ctx["inventory"], ctx["root"]
    targets, labels = [], {}
    for o in inv:
        if not o.get("apiTests"):
            continue
        if o["kind"] == "InferenceService":
            url = f"http://{o['name']}-predictor.{o['namespace']}.svc.cluster.local/v1/chat/completions"
        else:
            url = o.get("chatUrl")
        if url:
            tid = f"{o['kind']}/{o['namespace']}/{o['name']}"
            targets.append({"id": tid, "url": url, "model": o.get("servedModel", "sim")})
            labels[tid] = (f"{o['kind']} {o['namespace']}/{o['name']} (vLLM)", True)

    # Through the MaaS gateway, with a fresh key for one user per tier (simulator models).
    users = json.load(open(os.path.join(ctx["pop_dir"], "users.json")))
    issuer, maas = f"https://keycloak-maas-keycloak.{ctx['domain']}/realms/maas", f"https://maas.{ctx['domain']}"
    keys = []
    for tier in sorted({u["tier"] for u in users.values()}):
        name = sorted(n for n, u in users.items() if u["tier"] == tier and not u.get("admin"))[-2]
        try:
            ctxs = ssl._create_unverified_context()
            form = urllib.parse.urlencode({"grant_type": "password", "client_id": "maas-oidc", "scope": "openid", "username": name, "password": users[name]["password"]}).encode()
            at = json.load(urllib.request.urlopen(urllib.request.Request(f"{issuer}/protocol/openid-connect/token", data=form), context=ctxs, timeout=60))["access_token"]
            req = urllib.request.Request(f"{maas}/maas-api/v1/api-keys", data=json.dumps({"name": "loaded-rhoai-api-test", "expiresIn": "1h"}).encode(),
                                         headers={"Content-Type": "application/json", "Authorization": f"Bearer {at}"})
            k = json.load(urllib.request.urlopen(req, context=ctxs, timeout=60))
            models = json.load(urllib.request.urlopen(urllib.request.Request(f"{maas}/v1/models", headers={"Authorization": f"Bearer {k['key']}"}), context=ctxs, timeout=60))
            model = sorted(m["id"] for m in models["data"] if "/lr-models/" in m["id"])[0]
        except Exception as e:
            r.check(CAT, f"MaaS {tier}: key for the API tests", False, f"{type(e).__name__}: {str(e)[:200]}")
            continue
        tid = f"maas/{tier}"
        targets.append({"id": tid, "url": f"{maas}/v1/chat/completions", "model": model, "token": k["key"]})
        labels[tid] = (f"MaaS gateway, {tier} ({model.split('/')[-1]})", False)
        keys.append((k.get("id"), at))

    if not targets:
        r.add(CAT, "chat API tests", SKIP, "no real-model targets in this population and no MaaS keys", blocking=False)
        return
    results, err = _probe(root, targets)
    for tid, (label, strict) in labels.items():
        if tid not in results:
            r.check(CAT, f"{label}: probe ran", False, err or "no result")
            continue
        _judge(r, label, results[tid], strict)

    for kid, at in keys:   # tidy up the test keys
        if kid:
            try:
                urllib.request.urlopen(urllib.request.Request(f"{maas}/maas-api/v1/api-keys/{kid}", method="DELETE",
                                                              headers={"Authorization": f"Bearer {at}"}), context=ssl._create_unverified_context(), timeout=30)
            except Exception:
                pass
