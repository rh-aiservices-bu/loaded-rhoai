#!/usr/bin/env python3
"""loaded-rhoai validator (PLAN.md §10). Run from the repo root:

  python3 -m validator.run --pop generated/medium [--sample 5] [--exhaustive] [--reset-baseline]
                           [--only platform,inventory,...] [--out reports]

Writes reports/<timestamp>/{junit.xml, summary.txt, report.html, results.json} and exits 1 if any
blocking check failed. Saves an upgrade baseline after a passing run on an unchanged version."""
import argparse
import json
import os
import sys
import time

from . import kube, report
from .checks import api, functional, inventory, maas, platform, upgrade, workloads

SECTIONS = [("platform", platform.run), ("upgrade", upgrade.run), ("inventory", inventory.run), ("functional", functional.run), ("api", api.run),
            ("startability", workloads.startability), ("identity", workloads.identity), ("load", workloads.load), ("maas", maas.run), ("variants", workloads.variants)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pop", required=True, help="generated population directory, e.g. generated/medium")
    ap.add_argument("--version-dir", required=True)
    ap.add_argument("--rhoai-csv", required=True)
    ap.add_argument("--out", default="reports")
    ap.add_argument("--sample", type=int, default=5)
    ap.add_argument("--exhaustive", action="store_true")
    ap.add_argument("--reset-baseline", action="store_true")
    ap.add_argument("--only", help="comma-separated sections")
    ap.add_argument("--expect-rhoai", help="the RHOAI release this cluster should be on, e.g. 3.6.0-ea.2; fails if it isn't")
    ap.add_argument("--maaspal-plan", help="JSON file [[scenario, {overrides}], ...] to run through maaspal in the maas section")
    a = ap.parse_args()

    if upgrade.in_progress():
        sys.exit("An upgrade looks to be in progress: " + "; ".join(upgrade.in_progress()) + ". Validate once it has finished.")
    root = os.getcwd()
    pop = a.pop.rstrip("/")
    ctx = {"root": root, "pop_dir": pop, "gen_dir": os.path.dirname(pop) or ".", "version_dir": a.version_dir, "rhoai_csv": a.rhoai_csv,
           "inventory": json.load(open(f"{pop}/expected-inventory.json")),
           "seed": json.load(open(f"{pop}/seed.json")) if os.path.exists(f"{pop}/seed.json") else {},
           "skipped": json.load(open(f"{pop}/variants-skipped.json")) if os.path.exists(f"{pop}/variants-skipped.json") else [],
           "domain": kube.oc("get", "ingresses.config/cluster", "-o", "jsonpath={.spec.domain}")[1].strip(),
           "sample": a.sample, "exhaustive": a.exhaustive, "reset_baseline": a.reset_baseline,
           "expect_rhoai": a.expect_rhoai, "maaspal_plan": a.maaspal_plan}
    exp = os.path.join(a.version_dir, "upgrade-expected-changes.json")
    ctx["expected_changes"] = json.load(open(exp)) if os.path.exists(exp) else []

    r = report.Results()
    started = report.now()
    only = set(a.only.split(",")) if a.only else None
    for name, fn in SECTIONS:
        if only and name not in only:
            continue
        t0 = time.time()
        print(f"[{report.now()[11:19]}] {name} ...", flush=True)
        try:
            fn(r, ctx)
        except Exception as e:  # a section that crashes is a failure, not a silent pass
            r.add(name, f"{name} section ran", report.FAIL, f"{type(e).__name__}: {e}")
        c = r.counts(name)
        print(f"           pass {c['pass']} fail {c['fail']} warn {c['warn']} ({int(time.time() - t0)}s)", flush=True)

    # After an upgrade: which checks the upgrade fixed, which still fail, which it broke.
    if ctx.get("mode") == "upgrade" and not only:
        upgrade.compare_results(r, ctx.get("baseline") or {})

    meta = {"started": started, "finished": report.now(), "rhoai": [n for n, _ in upgrade.installed_rhoai()], "built_on": a.rhoai_csv,
            "population": pop, "mode": ctx.get("mode", "")}
    out = os.path.join(a.out, started.replace(":", ""))
    print(report.write(r, out, meta))
    print(f"report: {out}/report.html")
    # A run with failing checks is still a valid record of the release: it's saved, failures and all,
    # so a later run can say what an upgrade fixed. Only runs that couldn't measure the cluster
    # (a section crashed) or measured part of it (--only) are not saved.
    crashed = [i["name"] for i in r.items if i["name"].endswith("section ran")]
    if ctx.get("save_baseline") and not only and not crashed:
        snap = upgrade.snapshot(ctx["inventory"])
        snap["results"] = upgrade.results_record(r, meta)
        ok, err = upgrade.save_baseline(snap, os.path.join(ctx["gen_dir"], "baseline.json"))
        print(f"baseline saved for upgrade comparison ({len(r.failed)} failing checks recorded)" if ok else f"could not save baseline: {err[:200]}")
    elif ctx.get("save_baseline") and crashed:
        print(f"baseline not saved: sections crashed ({', '.join(crashed)})")
    sys.exit(1 if r.failed else 0)


if __name__ == "__main__":
    main()
