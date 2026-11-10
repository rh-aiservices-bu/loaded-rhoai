#!/usr/bin/env python3
"""Talk MCP to the MCP Gateway: initialize, list tools, and optionally call one.

Usage: mcp_probe.py <url> [--virtual ns/name] [--call tool [json-args]] [--token TOKEN]
Prints the tool names (one line) and, with --call, the tool's first result text. Exit 1 on error.
"""
import argparse
import json
import ssl
import sys
import urllib.error
import urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("url")
ap.add_argument("--virtual")
ap.add_argument("--call", nargs="+")
ap.add_argument("--token")
a = ap.parse_args()
CTX = ssl._create_unverified_context()
session = None


def rpc(method, params=None, i=[0]):
    global session
    i[0] += 1
    h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    if session:
        h["mcp-session-id"] = session
    if a.virtual:
        h["X-Mcp-Virtualserver"] = a.virtual
    if a.token:
        h["Authorization"] = f"Bearer {a.token}"
    body = {"jsonrpc": "2.0", "id": i[0], "method": method, **({"params": params} if params is not None else {})}
    req = urllib.request.Request(a.url, data=json.dumps(body).encode(), headers=h)
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=60) as r:
            session = session or r.headers.get("mcp-session-id")
            raw = r.read().decode()
    except urllib.error.HTTPError as e:
        sys.exit(f"{method}: HTTP {e.code} {e.read()[:200]!r}")
    # Responses may be JSON or a server-sent event stream with JSON in `data:` lines.
    for chunk in [raw] + [l[5:].strip() for l in raw.splitlines() if l.startswith("data:")]:
        try:
            d = json.loads(chunk)
            if "error" in d:
                sys.exit(f"{method}: {d['error']}")
            return d.get("result", {})
        except ValueError:
            continue
    sys.exit(f"{method}: unreadable response {raw[:200]!r}")


rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "loaded-rhoai", "version": "1"}})
tools = [t["name"] for t in rpc("tools/list").get("tools", [])]
print("TOOLS " + " ".join(sorted(tools)))
if a.call:
    args = json.loads(a.call[1]) if len(a.call) > 1 else {}
    res = rpc("tools/call", {"name": a.call[0], "arguments": args})
    text = " ".join(c.get("text", "") for c in res.get("content", []) if c.get("type") == "text")
    print(f"CALL {a.call[0]} isError={res.get('isError', False)} {text[:300]!r}")
    sys.exit(1 if res.get("isError") else 0)
