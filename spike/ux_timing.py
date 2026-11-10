#!/usr/bin/env python3
"""Dashboard UX timing (first version of PLAN.md §10.14).

Usage: ux_timing.py <dashboard-url> <users.json> <stage-label> <out-dir> [--reps N]

For each user and page it records:
  usable_s   navigation start until spinners and skeletons have been gone for 750 ms
             and the main area has content
  api        number of API calls, slowest call and total bytes
  errors     console errors and failed (>=400) API calls
Runs from wherever it's launched, so absolute numbers include that network path.
Compare stages with each other rather than reading them as a user's real experience.
"""
import argparse
import json
import os
import statistics
import time
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright

PAGES = [
    ("home", "/"),
    ("projects", "/projects"),
    ("models", "/ai-hub/models"),
    ("model-deployments", "/ai-hub/models/deployments"),
    ("playground", "/gen-ai-studio/playground"),
    ("ai-assets", "/gen-ai-studio/assets"),
    ("maas-keys", "/maas/keys-and-subs"),
    ("pipeline-runs", "/develop-train/pipelines/runs"),
    ("mlflow", "/develop-train/mlflow/experiments"),
    ("training-jobs", "/develop-train/training-jobs"),
    ("feature-store", "/develop-train/feature-store/overview"),
    ("observe", "/observe-and-monitor/dashboard"),
    ("workload-metrics", "/observe-monitor/workload-metrics"),
    ("hardware-profiles", "/settings/environment-setup/hardware-profiles"),
    ("user-management", "/settings/user-management"),
    ("maas-governance", "/maas/maas-governance"),
]
USERS = [("admin", "user0001"), ("lead", "user0009"), ("regular", "user0040")]
BUSY = ('[role="progressbar"], .pf-v6-c-spinner, .pf-v5-c-spinner, .pf-v6-c-skeleton, .pf-v5-c-skeleton, '
        '[data-testid*="loading"], [aria-busy="true"]')
HARD_TIMEOUT = 60


def login(page, url, user, password):
    """Retries, because a login page that's briefly down is something to record, not a crash."""
    for attempt in range(1, 5):
        try:
            page.goto(url, wait_until="domcontentloaded", timeout=90000)
            page.get_by_role("link", name="keycloak").click(timeout=60000)
            page.wait_for_selector("#username", timeout=45000)
            page.fill("#username", user)
            page.fill("#password", password)
            t0 = time.time()
            page.keyboard.press("Enter")
            page.wait_for_url(lambda u: "keycloak" not in u and "oauth" not in u, timeout=90000)
            if attempt > 1:
                print(f"login for {user} needed attempt {attempt}", flush=True)
            return wait_usable(page, t0)
        except Exception as e:
            print(f"login attempt {attempt} for {user} failed: {str(e)[:110]}", flush=True)
            page.screenshot(path=f"{OUT}/{STAGE}-login-fail-{user}-{attempt}.png", timeout=15000)
            page.wait_for_timeout(15000)
    raise RuntimeError(f"login failed for {user}")


def wait_usable(page, t0):
    """Seconds from t0 until the page has content and nothing has been busy for 750 ms."""
    settled_at = None
    while time.time() - t0 < HARD_TIMEOUT:
        busy = page.locator(BUSY).count()
        text = page.evaluate("() => (document.querySelector('main') || document.body).innerText.trim().length")
        if busy == 0 and text > 20:
            settled_at = settled_at or time.time()
            if time.time() - settled_at >= 0.75:
                return round(settled_at - t0, 2)
        else:
            settled_at = None
        page.wait_for_timeout(100)
    return None


def visit(page, base, path, host, tracker):
    tracker.clear()
    t0 = time.time()
    page.goto(base + path, wait_until="domcontentloaded", timeout=90000)
    usable = wait_usable(page, t0)
    page.wait_for_timeout(300)
    # A page that settles on the error screen isn't usable, however quickly it got there.
    page_error = page.get_by_text("An error occurred", exact=True).count() > 0
    if page_error:
        usable = None
    calls = [c for c in tracker if c.get("ms") is not None]
    slowest = max(calls, key=lambda c: c["ms"], default={"ms": 0, "url": ""})
    return {
        "usable_s": usable,
        "page_error": page_error,
        "api_calls": len(calls),
        "slowest_ms": round(slowest["ms"]),
        "slowest_url": slowest["url"][:120],
        "api_kb": round(sum(c.get("bytes", 0) for c in calls) / 1024),
        "failed": [f'{c["status"]} {c["url"][:90]}' for c in calls if c.get("status", 0) >= 400][:6],
    }


def projects_count(page):
    """The total the projects table shows, from its pagination or its rows."""
    return page.evaluate("""() => {
        const p = document.querySelector('.pf-v6-c-pagination__total-items, .pf-v5-c-pagination__total-items, [class*="pagination__total"]');
        const m = (p ? p.innerText : '').match(/of\\s+([\\d,]+)/);
        if (m) return parseInt(m[1].replace(',', ''));
        const t = document.querySelector('[class*="menu-toggle__text"] b:last-child, .pf-m-compact b:last-child');
        const n = t && t.innerText.match(/^\\d+$/);
        return n ? parseInt(n[0]) : document.querySelectorAll('tbody tr').length;
    }""")


def run_user(p, base, role, user, password, reps):
    host = urlparse(base).netloc
    b = p.chromium.launch()
    ctx = b.new_context(ignore_https_errors=True, viewport={"width": 1440, "height": 900})
    page = ctx.new_page()
    tracker, console, started = [], [], {}

    def on_request(r):
        if urlparse(r.url).netloc == host and r.resource_type in ("xhr", "fetch"):
            started[r] = {"url": urlparse(r.url).path}
            tracker.append(started[r])

    def on_response(r):
        e = started.get(r.request)
        if e is not None:
            e["status"] = r.status
            e["bytes"] = int(r.headers.get("content-length", 0) or 0)

    def on_finished(r):
        e = started.get(r)
        if e is not None:
            t = r.timing
            e["ms"] = (t["responseEnd"] - t["requestStart"]) if t["responseEnd"] > 0 else 0

    page.on("request", on_request)
    page.on("response", on_response)
    page.on("requestfinished", on_finished)
    page.on("console", lambda m: console.append(m.text[:200]) if m.type == "error" else None)

    result = {"login_s": login(page, base, user, password), "pages": {}}
    try:  # The first-visit welcome dialog would otherwise sit over every screenshot.
        page.get_by_role("button", name="Close", exact=True).click(timeout=3000)
    except Exception:
        pass
    for name, path in PAGES:
        runs = []
        for rep in range(reps):
            console.clear()
            try:
                r = visit(page, base, path, host, tracker)
            except Exception as e:  # A page that won't load is a result, not a crash.
                r = {"usable_s": None, "api_calls": 0, "slowest_ms": 0, "slowest_url": "", "api_kb": 0,
                     "failed": [f"navigation: {str(e)[:100]}"]}
                print(f"{role:8}{name:19}NAVIGATION FAILED {str(e)[:90]}", flush=True)
            r["console_errors"] = list(console)[:4]
            try:
                if name == "projects":
                    r["shown_projects"] = projects_count(page)
                if rep == 0:
                    page.screenshot(path=f"{OUT}/{STAGE}-{role}-{name}.png", timeout=15000)
            except Exception:
                pass
            runs.append(r)
        ok = [r["usable_s"] for r in runs if r["usable_s"] is not None]
        result["pages"][name] = {
            "median_s": round(statistics.median(ok), 2) if ok else None,
            "worst_s": max(ok) if ok else None,
            "timeouts": len(runs) - len(ok),
            "page_errors": sum(1 for r in runs if r.get("page_error")),
            "reps": len(runs),
            "api_calls": runs[-1]["api_calls"],
            "slowest_ms": max(r["slowest_ms"] for r in runs),
            "slowest_url": max(runs, key=lambda r: r["slowest_ms"])["slowest_url"],
            "api_kb": runs[-1]["api_kb"],
            "failed": runs[-1]["failed"],
            "console_errors": runs[-1]["console_errors"],
            "shown_projects": runs[-1].get("shown_projects"),
        }
        print(f"{role:8}{name:19}median={result['pages'][name]['median_s']} worst={result['pages'][name]['worst_s']} "
              f"api={runs[-1]['api_calls']} slowest={result['pages'][name]['slowest_ms']}ms failed={len(runs[-1]['failed'])} error_screens={result['pages'][name]['page_errors']}", flush=True)
    b.close()
    return result


ap = argparse.ArgumentParser()
ap.add_argument("base")
ap.add_argument("users")
ap.add_argument("stage")
ap.add_argument("out")
ap.add_argument("--reps", type=int, default=3)
ap.add_argument("--roles", default="admin,lead,regular")
a = ap.parse_args()
STAGE, OUT = a.stage, a.out
os.makedirs(OUT, exist_ok=True)
users = json.load(open(a.users))
results = {"stage": STAGE, "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "users": {}}
with sync_playwright() as p:
    for role, user in USERS:
        if role not in a.roles.split(","):
            continue
        results["users"][role] = dict(run_user(p, a.base, role, user, users[user]["password"], a.reps), user=user)
        print(f"{role} login_s={results['users'][role]['login_s']}", flush=True)
        with open(f"{OUT}/{STAGE}.json", "w") as f:  # Keep partial results if a later user fails.
            json.dump(results, f, indent=1)
with open(f"{OUT}/{STAGE}.json", "w") as f:
    json.dump(results, f, indent=1)
print("done", STAGE)
