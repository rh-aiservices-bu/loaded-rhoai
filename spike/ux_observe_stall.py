#!/usr/bin/env python3
"""Does leaving the Observe dashboard mid-query stall the next page, and is that real for users?
Usage: ux_observe_stall.py <base> <users.json> <user>"""
import json
import statistics
import sys
import time
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright

base, users_file, user = sys.argv[1:4]
pw_val = json.load(open(users_file))[user]["password"]
OBSERVE, NEXT = "/observe-and-monitor/dashboard", "/projects"


def session(p):
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
    return b, page


def ready(page, t0, marker="Projects", limit=60):
    """Seconds until the Projects page heading is visible."""
    while time.time() - t0 < limit:
        try:
            if page.locator("h1", has_text=marker).count() and page.locator('[role="progressbar"]').count() == 0:
                return round(time.time() - t0, 2)
        except Exception:
            pass
        page.wait_for_timeout(100)
    return None


with sync_playwright() as p:
    print("--- query behaviour on Observe")
    b, page = session(p)
    calls, inflight = [], {}
    page.on("request", lambda r: inflight.__setitem__(r, time.time()) if "/perses/api/proxy" in r.url else None)

    def end(r, how):
        s = inflight.pop(r, None)
        if s is not None:
            resp = r.response() if how == "ok" else None
            calls.append((round(time.time() - s, 2), resp.status if resp else how, r.method, len(r.url) + len(r.post_data or "")))

    page.on("requestfinished", lambda r: end(r, "ok"))
    page.on("requestfailed", lambda r: end(r, "failed"))
    t0 = time.time()
    page.goto(base + OBSERVE, wait_until="domcontentloaded", timeout=60000)
    while time.time() - t0 < 70 and (time.time() - t0 < 5 or inflight):
        page.wait_for_timeout(250)
    print(f"all Perses queries finished at {time.time() - t0:.1f}s (still running: {len(inflight)})")
    d = [c[0] for c in calls]
    if d:
        print(f"queries={len(calls)} median={statistics.median(d)}s max={max(d)}s longest request size={max(c[3] for c in calls)} bytes")
    st = {}
    for c in calls:
        st[c[1]] = st.get(c[1], 0) + 1
    print("status:", st)
    big = sorted(calls, key=lambda c: -c[3])[:3]
    print("largest:", big)
    b.close()

    for label, wait_queries, how in (("reload, leaving mid-query", False, "reload"), ("sidebar click, leaving mid-query", False, "click"), ("reload, after queries finished", True, "reload")):
        res = []
        for i in range(3):
            b, page = session(p)
            inflight = {}
            page.on("request", lambda r, f=inflight: f.__setitem__(r, 1) if "/perses/api/proxy" in r.url else None)
            page.on("requestfinished", lambda r, f=inflight: f.pop(r, None))
            page.on("requestfailed", lambda r, f=inflight: f.pop(r, None))
            t0 = time.time()
            page.goto(base + OBSERVE, wait_until="domcontentloaded", timeout=60000)
            page.wait_for_timeout(2500)
            if wait_queries:
                while time.time() - t0 < 60 and inflight:
                    page.wait_for_timeout(250)
            left = len(inflight)
            t0 = time.time()
            if how == "click":
                page.get_by_role("link", name="Projects", exact=True).first.click(timeout=15000)
            else:
                page.goto(base + NEXT, wait_until="domcontentloaded", timeout=90000)
            res.append((ready(page, t0), left))
            b.close()
        print(f"{label:38} next-page seconds, with in-flight queries at departure: {res}", flush=True)
