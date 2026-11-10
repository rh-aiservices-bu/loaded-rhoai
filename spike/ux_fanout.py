#!/usr/bin/env python3
"""Load one page with no time limit and group its API calls by type, to show what they scale with.
Usage: ux_fanout.py <base> <users.json> <user> <path> <out.json>"""
import collections
import json
import re
import statistics
import sys
import time
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright

base, users_file, user, path, out = sys.argv[1:6]
pw_val = json.load(open(users_file))[user]["password"]
host = urlparse(base).netloc
BUSY = '[role="progressbar"], .pf-v6-c-spinner, .pf-v5-c-spinner, .pf-v6-c-skeleton, .pf-v5-c-skeleton, [data-testid*="loading"], [aria-busy="true"]'
LIMIT = 300
NS = re.compile(r"/namespaces/[^/?]+")


def norm(u):
    return NS.sub("/namespaces/*", urlparse(u).path)


with sync_playwright() as p:
    b = p.chromium.launch()
    ctx = b.new_context(ignore_https_errors=True, viewport={"width": 1440, "height": 900})
    page = ctx.new_page()
    page.goto(base, wait_until="domcontentloaded", timeout=90000)
    page.get_by_role("link", name="keycloak").click(timeout=60000)
    page.wait_for_selector("#username", timeout=60000)
    page.fill("#username", user)
    page.fill("#password", pw_val)
    page.keyboard.press("Enter")
    page.wait_for_url(lambda u: "keycloak" not in u and "oauth" not in u, timeout=90000)
    page.wait_for_timeout(3000)
    try:
        page.get_by_role("button", name="Close", exact=True).click(timeout=2500)
    except Exception:
        pass

    calls, inflight = [], {}
    t0 = 0.0

    def start(r):
        if urlparse(r.url).netloc == host and r.resource_type in ("xhr", "fetch"):
            inflight[r] = time.time()

    def done(r, failed=False):
        s = inflight.pop(r, None)
        if s is None:
            return
        status = "failed"
        if not failed:
            resp = r.response()
            status = resp.status if resp else "none"
        calls.append({"t": round(time.time() - t0, 2), "dur": round(time.time() - s, 3), "status": status, "path": norm(r.url), "ns": bool(NS.search(r.url))})

    page.on("request", start)
    page.on("requestfinished", done)
    page.on("requestfailed", lambda r: done(r, True))

    t0 = time.time()
    page.goto(base + path, wait_until="domcontentloaded", timeout=120000)
    usable, settled, last_n, last_change = None, None, 0, time.time()
    samples = []
    while time.time() - t0 < LIMIT:
        try:
            busy = page.locator(BUSY).count()
            text = page.evaluate("() => (document.querySelector('main') || document.body).innerText.trim().length")
        except Exception:
            busy, text = 99, 0
        if busy == 0 and text > 20:
            settled = settled or time.time()
            if time.time() - settled > 0.75 and usable is None:
                usable = round(settled - t0, 2)
        else:
            settled = None
            usable = None
        if len(calls) != last_n:
            last_n, last_change = len(calls), time.time()
        if int(time.time() - t0) % 15 == 0 and (not samples or samples[-1][0] != int(time.time() - t0)):
            samples.append((int(time.time() - t0), len(calls), len(inflight), busy))
        if usable is not None and not inflight and time.time() - last_change > 8:
            break
        page.wait_for_timeout(200)
    total = round(time.time() - t0, 1)
    rows = page.locator("tbody tr").count()
    page_error = None
    if page.get_by_text("An error occurred", exact=True).count():
        page_error = "An error occurred"
        try:
            page.get_by_text("Show error", exact=True).click(timeout=5000)
            page.wait_for_timeout(1000)
            page_error = page.evaluate("() => (document.querySelector('main') || document.body).innerText")[:1500]
        except Exception:
            pass
    page.screenshot(path=out.replace(".json", ".png"), timeout=30000)
    pattern = collections.defaultdict(lambda: dict(count=0, dur=[], status=collections.Counter()))
    for c in calls:
        g = pattern[c["path"]]
        g["count"] += 1
        g["dur"].append(c["dur"])
        g["status"][str(c["status"])] += 1
    summary = {"usable_s": None if page_error else usable, "page_error": page_error, "ran_s": total, "finished": usable is not None and not inflight, "calls": len(calls),
               "still_inflight": len(inflight), "namespaced_calls": sum(1 for c in calls if c["ns"]), "table_rows": rows, "progress": samples[::2]}
    top = sorted(pattern.items(), key=lambda kv: -kv[1]["count"])[:14]
    summary["top"] = [{"path": k[:100], "count": v["count"], "median_s": round(statistics.median(v["dur"]), 2), "max_s": round(max(v["dur"]), 2), "status": dict(v["status"])} for k, v in top]
    json.dump(summary, open(out, "w"), indent=1)
    print(json.dumps({k: v for k, v in summary.items() if k not in ("top", "progress")}))
    print("progress (sec, calls done, in flight, busy):", summary["progress"][:14])
    for t in summary["top"]:
        print(f"{t['count']:5} med={t['median_s']:5} max={t['max_s']:6} {t['status']} {t['path']}")
    b.close()
