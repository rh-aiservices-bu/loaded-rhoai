#!/usr/bin/env python3
"""Create Gen AI playgrounds the way the dashboard does (PLAN.md §6).

Each playground is created by its team member through the dashboard's gen-ai API
(/gen-ai/api/v1/lsd/install), so the product builds the OGXServer, its pgvector database, config,
RBAC and monitoring itself. Generating those objects by hand would copy the dashboard's code and
miss changes to it between releases.

Usage: playgrounds.py <apps-domain> <users.json> <seed.json> [--check]
  default  create any playground that doesn't exist yet, then wait until each is Ready
  --check  send one chat through each playground as its owner (the validator's probe)
"""
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from user_token import token  # noqa: E402

domain, users_file, seed_file = sys.argv[1:4]
check = "--check" in sys.argv
users = json.load(open(users_file))
plan = json.load(open(seed_file)).get("playgrounds", [])
BASE = f"https://rh-ai.{domain}/gen-ai/api/v1"
CTX = ssl._create_unverified_context()


def api(method, path, tok, body=None, timeout=60):
    req = urllib.request.Request(BASE + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except Exception:
            return e.code, {}
    except Exception as e:
        return 0, {"error": str(e)[:200]}


def phase(status):
    d = (status or {}).get("data") or {}
    return d.get("phase") or d.get("status", {}).get("phase") if isinstance(d, dict) else None


failed = 0
tokens = {}
for p in plan:
    ns, user = p["namespace"], p["user"]
    tok = tokens.get(user) or token(f"oauth-openshift.{domain}", user, users[user]["password"])
    tokens[user] = tok
    if not tok:
        print(f"  {ns:14} {user}: login failed")
        failed += 1
        continue
    if check:
        code, models = api("GET", f"/lsd/models?namespace={ns}", tok)
        ids = [m["id"] for m in models.get("data", []) if m["id"].endswith(p["model"])]
        if not ids:
            print(f"  {ns:14} {user}: model {p['model']} not in the playground ({code})")
            failed += 1
            continue
        code, r = api("POST", f"/lsd/responses?namespace={ns}", tok,
                      {"input": "hello from loaded-rhoai", "model": ids[0], "model_source_type": "maas", "store": False}, timeout=120)
        # "incomplete" means the answer was cut at the length limit (the simulator's random replies
        # can be long); it still proves the playground reached its model through MaaS.
        d = r.get("data", {})
        ok = code in (200, 201) and (d.get("status") == "completed" or (d.get("status") == "incomplete" and d.get("output")))
        # MaaS answered 429 (the user's tier is out of tokens this minute): the path works, the budget
        # doesn't. The playground reports this as HTTP 500 "Too Many Requests" (3.5.2).
        limited = not ok and "Too Many Requests" in json.dumps(r)
        print(f"  {ns:14} {user}: chat http={code} {'ok' if ok else ('rate-limited' if limited else json.dumps(r)[:200])}")
        failed += 0 if ok or limited else 1
        continue
    code, st = api("GET", f"/lsd/status?namespace={ns}", tok)
    if code == 200 and st.get("data"):
        print(f"  {ns:14} {user}: exists ({phase(st)})")
        continue
    code, r = api("POST", f"/lsd/install?namespace={ns}", tok, {"models": [{"model_name": p["model"], "model_source_type": "maas"}]})
    print(f"  {ns:14} {user}: install http={code} {json.dumps(r)[:160] if code != 200 else p['model']}")
    if code != 200:
        failed += 1

if not check:
    deadline = time.time() + 900
    pending = {p["namespace"]: p for p in plan}
    while pending and time.time() < deadline:
        for ns, p in list(pending.items()):
            code, st = api("GET", f"/lsd/status?namespace={ns}", tokens.get(p["user"]) or "")
            if phase(st) == "Ready":
                del pending[ns]
        if pending:
            time.sleep(15)
    for ns in pending:
        print(f"  {ns:14} not Ready after 15 minutes")
    failed += len(pending)
print(f"PLAYGROUNDS planned={len(plan)} failed={failed}")
sys.exit(1 if failed else 0)
