#!/usr/bin/env python3
"""Per-user MaaS load: each active user logs in to Keycloak, mints their own API key and sends
chat requests at a tier-dependent Poisson rate (PLAN.md §9, "Continuous load").

Usage:
  loadgen.py smoke <users.json>          one request per user, report the subscription each resolves to
  loadgen.py run   <users.json>          run until stopped, serving Prometheus metrics on :9100

Environment: MAAS_URL, KEYCLOAK_ISSUER, RATE_SCALE (default 1.0), POWER_USERS (comma list).
users.json: {"username": {"password": ..., "tier": "maas-free|maas-standard|maas-premium"}}
"""
import collections
import http.server
import json
import os
import random
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

MAAS = os.environ["MAAS_URL"].rstrip("/")
ISSUER = os.environ["KEYCLOAK_ISSUER"].rstrip("/")
SCALE = float(os.environ.get("RATE_SCALE", "1.0"))
POWER = set(filter(None, os.environ.get("POWER_USERS", "").split(",")))
RATE = {"maas-free": 0.03, "maas-standard": 0.08, "maas-premium": 0.15}  # requests per second per user
POWER_RATE = 1.0
CTX = ssl._create_unverified_context()  # spike only: the cluster's ingress certificate is trusted, but keep it simple
PROMPTS = ["summarise today's plant telemetry", "draft a maintenance work order", "explain the reservoir level trend",
           "write a shift handover note", "list three risks in this change request", "translate 'good morning' to French"]

lock = threading.Lock()
requests_total = collections.Counter()   # (user, tier, model, code, expected)
tokens_total = collections.Counter()     # (user, tier, model)
auth_total = collections.Counter()       # (user, step, code)


def call(url, body=None, token=None, form=None, method="POST", timeout=60):
    headers = {}
    data = None
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=timeout) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except Exception:
            return e.code, {}
    except Exception as e:  # timeouts, resets
        return 0, {"error": str(e)[:200]}


def login(user, info):
    code, tok = call(f"{ISSUER}/protocol/openid-connect/token",
                     form={"grant_type": "password", "client_id": "maas-oidc", "scope": "openid", "username": user, "password": info["password"]})
    with lock:
        auth_total[(user, "token", code)] += 1
    if code != 200:
        return None, None
    code, key = call(f"{MAAS}/maas-api/v1/api-keys", {"name": f"{user}-loadgen", "expiresIn": "24h"}, token=tok["access_token"])
    with lock:
        auth_total[(user, "apikey", code)] += 1
    if code not in (200, 201):
        return None, None
    return key.get("key"), key.get("subscription")


def models(api_key):
    code, d = call(f"{MAAS}/v1/models", token=api_key, method="GET")
    return sorted(m["id"] for m in d.get("data", [])) if code == 200 else []


def ask(user, tier, api_key, model, r):
    max_tokens = min(int(r.paretovariate(1.5) * 40), 600)
    code, resp = call(f"{MAAS}/v1/chat/completions", {"model": model, "max_tokens": max_tokens,
                                                       "messages": [{"role": "user", "content": r.choice(PROMPTS)}]}, token=api_key)
    expected = code == 200 or (code == 429 and user in POWER)
    short = model.split("/")[-1]
    with lock:
        requests_total[(user, tier, short, code, "true" if expected else "false")] += 1
        if code == 200:
            tokens_total[(user, tier, short)] += resp.get("usage", {}).get("total_tokens", 0)
    return code


def user_loop(user, info):
    r = random.Random(user)
    time.sleep(r.uniform(0, 30))  # don't log everyone in at the same moment
    # Keep retrying: after a cluster restart Keycloak and MaaS come up after this pod does.
    delay = 15
    while True:
        api_key, sub = login(user, info)
        available = models(api_key) if api_key else []
        if available:
            break
        time.sleep(delay + r.uniform(0, 10))
        delay = min(delay * 2, 300)
    pinned = available[:1] if user in POWER else available  # limits apply per user per model (PLAN.md §9)
    rate = (POWER_RATE if user in POWER else RATE[info["tier"]]) * SCALE
    while True:
        time.sleep(r.expovariate(rate))
        while os.path.exists("/tmp/pause"):  # `touch /tmp/pause` stops traffic; metrics stay readable
            time.sleep(1)
        if ask(user, info["tier"], api_key, r.choice(pinned), r) == 401:
            api_key, sub = login(user, info)
            if not api_key:
                time.sleep(60)


def metrics():
    out = ["# TYPE loadgen_requests_total counter", "# TYPE loadgen_tokens_total counter", "# TYPE loadgen_auth_total counter"]
    with lock:
        for (u, t, m, c, e), v in requests_total.items():
            out.append(f'loadgen_requests_total{{user="{u}",tier="{t}",model="{m}",code="{c}",expected="{e}"}} {v}')
        for (u, t, m), v in tokens_total.items():
            out.append(f'loadgen_tokens_total{{user="{u}",tier="{t}",model="{m}"}} {v}')
        for (u, s, c), v in auth_total.items():
            out.append(f'loadgen_auth_total{{user="{u}",step="{s}",code="{c}"}} {v}')
    return "\n".join(out) + "\n"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = metrics().encode() if self.path.startswith("/metrics") else b"ok\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def main():
    mode, users_file = sys.argv[1], sys.argv[2]
    users = json.load(open(users_file))
    if mode == "smoke":
        for u, info in users.items():
            key, sub = login(u, info)
            ms = models(key) if key else []
            code = ask(u, info["tier"], key, ms[0], random.Random(u)) if ms else None
            print(f"{u:10} {info['tier']:14} key={'yes' if key else 'NO'} subscription={sub} models={len(ms)} chat={code}")
        print("auth:", dict(collections.Counter((s, c) for (_, s, c) in auth_total.elements())))
        return
    for u, info in users.items():
        threading.Thread(target=user_loop, args=(u, info), daemon=True).start()
    http.server.ThreadingHTTPServer(("", 9100), Handler).serve_forever()


if __name__ == "__main__":
    main()
