#!/usr/bin/env python3
"""Choose the load generator's users from the generated population (PLAN.md §9).

60 non-admin users chosen by a stable hash of the seed, plus 2 free-tier "power users" outside
that set, who send far faster than their tier allows and are expected to see 429s.
Usage: select_load_users.py <users.json> <out load-users.json> <out power-users.txt> [seed]
"""
import collections
import hashlib
import json
import sys

users_file, out_users, out_power = sys.argv[1:4]
seed = sys.argv[4] if len(sys.argv) > 4 else "42"
u = json.load(open(users_file))
names = sorted((n for n, x in u.items() if not x.get("admin")),
               key=lambda n: hashlib.sha256(f"{seed}:active:{n}".encode()).hexdigest())
active = names[:60]
power = [n for n in names[60:] if u[n]["tier"] == "maas-free"][:2]
json.dump({n: {"password": u[n]["password"], "tier": u[n]["tier"]} for n in active + power}, open(out_users, "w"))
open(out_power, "w").write(",".join(power))
print("  active by tier", dict(collections.Counter(u[n]["tier"] for n in active)), "power users", power)
