#!/usr/bin/env python3
"""Visit a page repeatedly in one session and show what the page is waiting for when it stalls.
Usage: ux_repeat_trace.py <base> <users.json> <user> <path> <visits>"""
import json
import sys
import time

from playwright.sync_api import sync_playwright

base, users_file, user, path, visits = sys.argv[1:6]
pw_val = json.load(open(users_file))[user]["password"]
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
    page.wait_for_timeout(3000)
    try:
        page.get_by_role("button", name="Close", exact=True).click(timeout=2500)
    except Exception:
        pass
    inflight, ended = {}, []
    page.on("request", lambda r: inflight.__setitem__(r, time.time()))

    def end(r, how):
        s = inflight.pop(r, None)
        if s is not None:
            ended.append((round(time.time() - s, 2), how, r.resource_type, r.url.replace(base, "")[:115], t0))

    page.on("requestfinished", lambda r: end(r, "ok"))
    page.on("requestfailed", lambda r: end(r, f"FAILED:{r.failure}"))
    for v in range(int(visits)):
        inflight.clear()
        ended.clear()
        t0 = time.time()
        try:
            page.goto(base + path, wait_until="domcontentloaded", timeout=45000)
            nav = f"dcl={time.time() - t0:.2f}s"
        except Exception as e:
            nav = f"goto failed after {time.time() - t0:.1f}s: {str(e)[:60]}"
        settled, shown = None, set()
        while time.time() - t0 < 45:
            try:
                busy = page.locator(BUSY).count()
                text = page.evaluate("() => (document.querySelector('main') || document.body).innerText.trim().length")
            except Exception:
                busy, text = 99, 0
            if busy == 0 and text > 20:
                settled = settled or time.time()
                if time.time() - settled > 0.75:
                    break
            else:
                settled = None
            if time.time() - t0 > 4 and int(time.time() - t0) % 8 == 0:
                key = int(time.time() - t0)
                if key not in shown:
                    shown.add(key)
                    print(f"   t={key}s busy={busy} textlen={text} inflight={[(r.resource_type, r.url.replace(base, '')[:70]) for r in list(inflight)[:4]]}", flush=True)
            page.wait_for_timeout(150)
        u = f"{settled - t0:.2f}" if settled else "NEVER"
        slow = sorted(ended, key=lambda e: -e[0])[:3]
        print(f"visit {v + 1}: usable={u}s {nav} requests={len(ended)} left={len(inflight)} slowest={[(s[0], s[1][:18], s[3][:70]) for s in slow]}", flush=True)
    b.close()
