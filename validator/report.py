"""Results and reports (PLAN.md §10.12): JUnit XML, a text summary and a single-page HTML report."""
import datetime
import html
import json
import os
import xml.etree.ElementTree as ET

PASS, FAIL, WARN, SKIP = "pass", "fail", "warn", "skip"


class Results:
    def __init__(self):
        self.items = []   # {category, name, status, detail, blocking}

    def add(self, category, name, status, detail="", blocking=True):
        self.items.append({"category": category, "name": name, "status": status, "detail": str(detail)[:2000], "blocking": blocking})
        return status == PASS

    def check(self, category, name, ok, detail="", blocking=True):
        return self.add(category, name, PASS if ok else (FAIL if blocking else WARN), detail, blocking)

    @property
    def failed(self):
        return [i for i in self.items if i["status"] == FAIL]

    def counts(self, category=None):
        c = {PASS: 0, FAIL: 0, WARN: 0, SKIP: 0}
        for i in self.items:
            if category is None or i["category"] == category:
                c[i["status"]] += 1
        return c

    def categories(self):
        seen = []
        for i in self.items:
            if i["category"] not in seen:
                seen.append(i["category"])
        return seen


def write(results, out_dir, meta):
    os.makedirs(out_dir, exist_ok=True)
    # JUnit: one testsuite per category; warnings and skips are skipped tests with a message.
    root = ET.Element("testsuites", name="loaded-rhoai")
    for cat in results.categories():
        items = [i for i in results.items if i["category"] == cat]
        c = results.counts(cat)
        suite = ET.SubElement(root, "testsuite", name=cat, tests=str(len(items)), failures=str(c[FAIL]), skipped=str(c[WARN] + c[SKIP]))
        for i in items:
            tc = ET.SubElement(suite, "testcase", classname=cat, name=i["name"])
            if i["status"] == FAIL:
                ET.SubElement(tc, "failure", message=i["detail"][:300]).text = i["detail"]
            elif i["status"] in (WARN, SKIP):
                ET.SubElement(tc, "skipped", message=f"{i['status']}: {i['detail'][:300]}")
    ET.ElementTree(root).write(os.path.join(out_dir, "junit.xml"), encoding="utf-8", xml_declaration=True)
    json.dump({"meta": meta, "results": results.items}, open(os.path.join(out_dir, "results.json"), "w"), indent=1)

    lines = [f"loaded-rhoai validation  {meta['started']}  RHOAI {meta.get('rhoai')}  population {meta.get('population')}", ""]
    for cat in results.categories():
        c = results.counts(cat)
        lines.append(f"  {cat:28} pass {c[PASS]:5}  fail {c[FAIL]:3}  warn {c[WARN]:3}  skip {c[SKIP]:3}")
    total = results.counts()
    lines += ["", f"  {'TOTAL':28} pass {total[PASS]:5}  fail {total[FAIL]:3}  warn {total[WARN]:3}  skip {total[SKIP]:3}", ""]
    for i in results.items:
        if i["status"] in (FAIL, WARN):
            lines.append(f"  {i['status'].upper():4} [{i['category']}] {i['name']}: {i['detail'][:240]}")
    summary = "\n".join(lines) + "\n"
    open(os.path.join(out_dir, "summary.txt"), "w").write(summary)

    rows = "".join(
        f"<tr class='{i['status']}'><td>{html.escape(i['category'])}</td><td>{html.escape(i['name'])}</td>"
        f"<td>{i['status']}</td><td>{html.escape(i['detail'][:600])}</td></tr>"
        for i in sorted(results.items, key=lambda i: ({FAIL: 0, WARN: 1, SKIP: 2, PASS: 3}[i["status"]], i["category"])))
    cats = "".join(f"<tr><td>{html.escape(c)}</td>" + "".join(f"<td>{results.counts(c)[s]}</td>" for s in (PASS, FAIL, WARN, SKIP)) + "</tr>"
                   for c in results.categories())
    page = f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Validation report</title><style>
:root{{--bg:#fff;--fg:#1b1b1b;--muted:#666;--line:#ddd;--fail:#b3261e;--warn:#8a6100;--pass:#1e6b3a}}
@media (prefers-color-scheme:dark){{:root{{--bg:#151515;--fg:#eee;--muted:#aaa;--line:#333;--fail:#ff8a80;--warn:#ffd27a;--pass:#8fd19e}}}}
body{{background:var(--bg);color:var(--fg);font:14px/1.45 system-ui,sans-serif;margin:0;padding:16px;max-width:1200px}}
table{{border-collapse:collapse;width:100%;margin:12px 0}}td,th{{border-bottom:1px solid var(--line);padding:4px 8px;text-align:left;vertical-align:top}}
tr.fail td:nth-child(3){{color:var(--fail);font-weight:600}}tr.warn td:nth-child(3){{color:var(--warn)}}tr.pass td:nth-child(3){{color:var(--pass)}}
.muted{{color:var(--muted)}}td:last-child{{word-break:break-word}}</style></head><body>
<h1>loaded-rhoai validation</h1><p class="muted">{html.escape(meta['started'])} · RHOAI {html.escape(str(meta.get('rhoai')))} · population {html.escape(str(meta.get('population')))} · mode {html.escape(meta.get('mode', ''))}</p>
<table><tr><th>Category</th><th>Pass</th><th>Fail</th><th>Warn</th><th>Skip</th></tr>{cats}</table>
<table><tr><th>Category</th><th>Check</th><th>Result</th><th>Detail</th></tr>{rows}</table></body></html>"""
    open(os.path.join(out_dir, "report.html"), "w").write(page)
    return summary


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
