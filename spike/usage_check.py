#!/usr/bin/env python3
"""Compare MaaS's per-user token counters with what the load generator sent (PLAN.md §9, §10.8).
Uses raw counter differences (now minus start), not increase(), which over-read on the 3.5.1 spike.
Usage: usage_check.py <start-epoch>"""
import collections
import json
import re
import subprocess
import sys
import time
import urllib.parse

START = int(sys.argv[1])


def thanos(expr, at=None):
    pod = subprocess.run(["oc", "get", "pods", "-n", "openshift-monitoring", "-l", "app.kubernetes.io/name=thanos-query", "-o", "jsonpath={.items[0].metadata.name}"],
                         capture_output=True, text=True).stdout
    params = {"query": expr}
    if at:
        params["time"] = at
    r = subprocess.run(["oc", "exec", "-n", "openshift-monitoring", pod, "-c", "thanos-query", "--", "curl", "-s", "--max-time", "40",
                        "http://localhost:9090/api/v1/query?" + urllib.parse.urlencode(params)], capture_output=True, text=True, timeout=70)
    try:
        return json.loads(r.stdout)["data"]["result"]
    except Exception:
        print("query failed:", r.stdout[:200], r.stderr[:200])
        return []


now = int(time.time())
# Counter names and labels, as found on the 3.5.1 spike: authorized_hits{user,subscription,model} in cluster Thanos.
names = sorted({s["metric"]["__name__"] for s in thanos('{__name__=~"authorized_hits.*|authorized_calls.*|limited_calls.*"}')})
print("MaaS counters in cluster Thanos:", names)
hit_now = {(s["metric"].get("user"), s["metric"].get("model", "")): float(s["value"][1]) for s in thanos('sum by (user, model) (authorized_hits)', now)}
hit_start = {(s["metric"].get("user"), s["metric"].get("model", "")): float(s["value"][1]) for s in thanos('sum by (user, model) (authorized_hits)', START)}
lim_now = {s["metric"].get("user"): float(s["value"][1]) for s in thanos('sum by (user) (limited_calls)', now)}
lim_start = {s["metric"].get("user"): float(s["value"][1]) for s in thanos('sum by (user) (limited_calls)', START)}
sub = collections.defaultdict(set)
for s in thanos('sum by (user, subscription) (authorized_hits)', now):
    sub[s["metric"].get("user")].add(s["metric"].get("subscription"))

# What the load generator says it sent, from its own metrics.
pod = subprocess.run(["oc", "get", "pods", "-n", "loaded-rhoai-load", "-o", "jsonpath={.items[0].metadata.name}"], capture_output=True, text=True).stdout
text = subprocess.run(["oc", "exec", "-n", "loaded-rhoai-load", pod, "--", "python3", "-c",
                       "import urllib.request;print(urllib.request.urlopen('http://localhost:9100/metrics').read().decode())"], capture_output=True, text=True).stdout
sent, tier, limited = collections.Counter(), {}, collections.Counter()
for line in text.splitlines():
    m = dict(re.findall(r'(\w+)="([^"]*)"', line))
    if line.startswith("loadgen_tokens_total"):
        sent[m["user"]] += float(line.split()[-1])
        tier[m["user"]] = m["tier"]
    elif line.startswith("loadgen_requests_total") and m.get("code") == "429":
        limited[m["user"]] += float(line.split()[-1])

maas = collections.Counter()
for (u, _), v in hit_now.items():
    maas[u] += v - hit_start.get((u, _), 0.0)
users = sorted(sent)
exact = sum(1 for u in users if round(maas.get(u, 0)) == round(sent[u]))
print(f"users the load generator sent as: {len(users)}; seen by MaaS with a user label: {sum(1 for u in users if maas.get(u))}")
print(f"token totals: load generator {int(sum(sent.values()))}, MaaS {int(sum(maas[u] for u in users))}")
print(f"users whose MaaS count matches exactly: {exact} of {len(users)}")
diffs = sorted(((abs(maas.get(u, 0) - sent[u]), u) for u in users), reverse=True)[:5]
for d, u in diffs:
    print(f"  {u} {tier[u]:14} sent={int(sent[u])} maas={int(maas.get(u, 0))} subscriptions={sorted(sub.get(u, []))}")
wrong_tier = [u for u in users if sub.get(u) and not any(s == "tier-" + tier[u].split("-")[1] for s in sub[u])]
print("users attributed to a subscription other than their tier:", wrong_tier[:10])
print("rate-limited per user, load generator vs MaaS limited_calls:",
      {u: (int(limited[u]), int(lim_now.get(u, 0) - lim_start.get(u, 0))) for u in limited})
print("empty user label series:", [k for k in hit_now if not k[0]][:3])
