#!/usr/bin/env python3
"""Log in to the dashboard as a generated user and list its real navigation links.
Usage: ux_explore.py <dashboard-url> <users.json> <user> <out-dir>"""
import json
import os
import sys

from playwright.sync_api import sync_playwright

url, users_file, user, out = sys.argv[1:5]
pw_val = json.load(open(users_file))[user]["password"]
os.makedirs(out, exist_ok=True)

with sync_playwright() as p:
    b = p.chromium.launch()
    ctx = b.new_context(ignore_https_errors=True, viewport={"width": 1440, "height": 900})
    page = ctx.new_page()
    page.goto(url, wait_until="domcontentloaded", timeout=90000)
    page.get_by_role("link", name="keycloak").click(timeout=60000)
    page.fill("#username", user)
    page.fill("#password", pw_val)
    page.keyboard.press("Enter")
    page.wait_for_url(lambda u: "keycloak" not in u and "oauth" not in u, timeout=90000)
    page.wait_for_load_state("networkidle", timeout=90000)
    print("landed:", page.url)
    page.screenshot(path=f"{out}/landing-{user}.png")

    # Expand every nav group so that all links are in the DOM.
    for e in page.locator("nav button[aria-expanded='false']").all():
        try:
            e.click(timeout=1500)
        except Exception:
            pass
    links = page.eval_on_selector_all(
        "nav a[href]", "els => els.map(e => [e.textContent.trim(), e.getAttribute('href')])")
    seen = set()
    for text, href in links:
        if href not in seen:
            seen.add(href)
            print(f"{text[:45]:46}{href}")
    print("cookies:", [c["name"] for c in ctx.cookies()][:8])
    b.close()
