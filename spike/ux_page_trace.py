#!/usr/bin/env python3
"""Trace one dashboard page to see where its load time goes.
Usage: ux_page_trace.py <base> <users.json> <user> <path> <out.png>"""
import json
import sys
import time
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright

base, users_file, user, path, png = sys.argv[1:6]
pw_val = json.load(open(users_file))[user]["password"]
host = urlparse(base).netloc
BUSY = '[role="progressbar"], .pf-v6-c-spinner, .pf-v5-c-spinner, .pf-v6-c-skeleton, .pf-v5-c-skeleton, [data-testid*="loading"], [aria-busy="true"]'

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
    page.wait_for_load_state("domcontentloaded")
    page.wait_for_timeout(3000)
    try:
        page.get_by_role("button", name="Close", exact=True).click(timeout=2500)
    except Exception:
        pass

    calls, inflight = [], {}
    t0 = time.time()
    page.on("request", lambda r: inflight.__setitem__(r, time.time() - t0) if r.resource_type in ("xhr", "fetch") else None)

    def done(r, status="ok"):
        s = inflight.pop(r, None)
        if s is not None:
            calls.append((round(s, 2), round(time.time() - t0, 2), status, r.url.replace(base, "")[:110]))

    page.on("requestfinished", done)
    page.on("requestfailed", lambda r: done(r, "FAILED"))
    page.add_init_script("""window.__long=[];try{new PerformanceObserver(l=>{for(const e of l.getEntries())window.__long.push([Math.round(e.startTime),Math.round(e.duration)])}).observe({entryTypes:['longtask']})}catch(e){}""")

    t0 = time.time()
    page.goto(base + path, wait_until="domcontentloaded", timeout=90000)
    print(f"domcontentloaded {time.time() - t0:.2f}s")
    last = None
    while time.time() - t0 < 70:
        busy = page.locator(BUSY)
        n = busy.count()
        text = page.evaluate("() => (document.querySelector('main') || document.body).innerText.trim().length")
        state = (n, text // 200)
        if state != last:
            what = [e.get_attribute("class") or e.get_attribute("role") or "" for e in busy.all()[:2]]
            print(f"t={time.time() - t0:5.1f}s busy={n} textlen={text} inflight={len(inflight)} {[w[:40] for w in what]}", flush=True)
            last = state
        if n == 0 and text > 20 and time.time() - t0 > 3:
            page.wait_for_timeout(750)
            if page.locator(BUSY).count() == 0:
                break
        page.wait_for_timeout(200)
    print(f"usable at {time.time() - t0:.2f}s; inflight left={[r.url[-60:] for r in inflight]}")
    long_tasks = page.evaluate("window.__long || []")
    print("long tasks ms total", sum(x[1] for x in long_tasks), "count", len(long_tasks), "largest", sorted((x[1] for x in long_tasks), reverse=True)[:5])
    print("calls", len(calls))
    for c in sorted(calls, key=lambda c: c[1] - c[0], reverse=True)[:10]:
        print(f"  {c[1] - c[0]:6.2f}s start={c[0]:6.2f} {c[2]:6} {c[3]}")
    print("latest finishing:")
    for c in sorted(calls, key=lambda c: c[1], reverse=True)[:5]:
        print(f"  end={c[1]:6.2f} {c[3]}")
    page.screenshot(path=png, timeout=20000)
    b.close()
