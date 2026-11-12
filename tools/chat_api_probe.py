#!/usr/bin/env python3
"""OpenAI chat API behaviour of a model endpoint, from inside the cluster (runs in lr-toolbox).

TARGETS is JSON: [{"id", "url", "model", "auth"?: true, "token"?: "..."}]. For each target it sends:
  ok          a normal chat
  stream      the same with stream: true and stream_options.include_usage
  bad-temperature   temperature -1
  bad-top_p         top_p 1.5
  bad-max_tokens    max_tokens -1
  bad-model         a model that doesn't exist
  bad-json          a body that isn't JSON
and prints one JSON line: {target id: {case: {code, ctype, ...summary}}}. The caller decides what passes.
"""
import concurrent.futures as cf
import json
import os
import ssl
import time
import urllib.error
import urllib.request

CTX = ssl._create_unverified_context()
MSG = [{"role": "user", "content": "Say hello in five words."}]


def send(url, body, token=None, raw=None):
    data = raw.encode() if raw is not None else json.dumps(body).encode()
    h = {"Content-Type": "application/json"}
    if token:
        h["Authorization"] = f"Bearer {token}"
    t0 = time.time()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=h), context=CTX, timeout=180) as r:
            return r.status, r.headers.get("Content-Type", ""), r.read().decode(errors="replace"), time.time() - t0
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("Content-Type", ""), e.read().decode(errors="replace"), time.time() - t0
    except Exception as e:
        return 0, "", str(e)[:300], time.time() - t0


def summarise_json(code, ctype, text, secs=0):
    out = {"code": code, "ctype": ctype.split(";")[0], "secs": round(secs, 2)}
    try:
        d = json.loads(text)
    except ValueError:
        out["json"], out["body"] = False, text[:200]
        return out
    out["json"] = True
    # OpenAI-style {"error": {...}}, vLLM's {"object": "error", "message": ...}, FastAPI's {"detail": ...}
    err = d.get("error") if isinstance(d, dict) and "error" in d else (d if isinstance(d, dict) and d.get("object") == "error" else (d.get("detail") if isinstance(d, dict) else None))
    if err:
        out["error"] = (err.get("message") if isinstance(err, dict) else str(err))[:200]
    if not isinstance(d, dict):
        return out
    if d.get("choices"):
        out["content"] = bool((d["choices"][0].get("message") or {}).get("content"))
        out["finish"] = d["choices"][0].get("finish_reason")
    if d.get("usage"):
        out["usage"] = d["usage"].get("total_tokens")
    return out


def summarise_stream(code, ctype, text, secs):
    out = {"code": code, "ctype": ctype.split(";")[0], "secs": round(secs, 2)}
    events = [l[5:].strip() for l in text.splitlines() if l.startswith("data:")]
    out["events"] = len(events)
    out["done"] = bool(events) and events[-1] == "[DONE]"
    deltas, usage = 0, None
    for e in events:
        if e == "[DONE]":
            continue
        try:
            d = json.loads(e)
        except ValueError:
            out["bad_event"] = e[:120]
            continue
        if any((c.get("delta") or {}).get("content") for c in d.get("choices") or []):
            deltas += 1
        if d.get("usage"):
            usage = d["usage"].get("total_tokens")
    out["deltas"], out["usage"] = deltas, usage
    if code != 200:
        out["body"] = text[:200]
    return out


def probe(t):
    url, model, tok = t["url"], t["model"], t.get("token") or (os.environ["TOKEN"] if t.get("auth") else None)
    base = {"model": model, "messages": MSG, "max_tokens": 24}
    res = {}
    res["ok"] = summarise_json(*send(url, base, tok))
    c, ct, text, secs = send(url, dict(base, stream=True, stream_options={"include_usage": True}), tok)
    res["stream"] = summarise_stream(c, ct, text, secs)
    for case, extra in (("bad-temperature", {"temperature": -1}), ("bad-top_p", {"top_p": 1.5}), ("bad-max_tokens", {"max_tokens": -1}),
                        ("bad-model", {"model": "no-such-model-loaded-rhoai"})):
        res[case] = summarise_json(*send(url, dict(base, **extra), tok))
    res["bad-json"] = summarise_json(*send(url, None, tok, raw='{"model": "x", "messages": ['))
    return t["id"], res


with cf.ThreadPoolExecutor(4) as ex:
    print(json.dumps(dict(ex.map(probe, json.loads(os.environ["TARGETS"])))))
