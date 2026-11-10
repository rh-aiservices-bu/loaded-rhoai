#!/usr/bin/env python3
"""Send a batch of HTTP requests from inside the cluster (runs in the lr-toolbox pod).
REQS is JSON: [{"id", "method", "url", "body"?, "headers"?, "auth"?: true}]. `auth` adds the
caller's TOKEN as a bearer token. Prints one JSON line: {id: {"code", "body"}}."""
import concurrent.futures as cf
import json
import os
import ssl
import urllib.error
import urllib.request

CTX = ssl._create_unverified_context()


def send(q):
    h = {"Content-Type": "application/json", **q.get("headers", {})}
    if q.get("auth"):
        h["Authorization"] = "Bearer " + os.environ["TOKEN"]
    body = json.dumps(q["body"]).encode() if q.get("body") is not None else None
    try:
        with urllib.request.urlopen(urllib.request.Request(q["url"], data=body, headers=h, method=q.get("method", "GET")), context=CTX, timeout=60) as r:
            return q["id"], {"code": r.status, "body": r.read()[:2000].decode(errors="replace")}
    except urllib.error.HTTPError as e:
        return q["id"], {"code": e.code, "body": e.read()[:500].decode(errors="replace")}
    except Exception as e:
        return q["id"], {"code": 0, "body": str(e)[:300]}


with cf.ThreadPoolExecutor(8) as ex:
    print(json.dumps(dict(ex.map(send, json.loads(os.environ["REQS"])))))
