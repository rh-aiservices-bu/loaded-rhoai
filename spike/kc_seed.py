#!/usr/bin/env python3
"""Upsert generated users, groups and the `openshift` client into the Keycloak `maas` realm.

Usage: kc_seed.py <keycloak-url> <users.json> <oauth-redirect-uri> <client-secret>
Admin credentials come from KC_ADMIN and KC_ADMIN_PASSWORD. Idempotent.
"""
import concurrent.futures as cf
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

KC, USERS, REDIRECT, SECRET = sys.argv[1:5]
REALM = "maas"
CTX = ssl.create_default_context()
base = f"/admin/realms/{REALM}"
token = {"value": None, "at": 0}


def raw(method, path, tok=None, body=None, form=None):
    data, headers = None, {}
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if tok:
        headers["Authorization"] = f"Bearer {tok}"
    req = urllib.request.Request(KC + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=60) as r:
            b = r.read()
            return r.status, (json.loads(b) if b else None)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:300]


def tok():
    if time.time() - token["at"] > 30:
        s, d = raw("POST", "/realms/master/protocol/openid-connect/token",
                   form={"grant_type": "password", "client_id": "admin-cli",
                         "username": os.environ["KC_ADMIN"], "password": os.environ["KC_ADMIN_PASSWORD"]})
        if s != 200:
            sys.exit(f"admin login failed: {s} {d}")
        token.update(value=d["access_token"], at=time.time())
    return token["value"]


def call(method, path, body=None):
    return raw(method, path, tok(), body)


def main():
    users = json.load(open(USERS))
    groups = sorted({u["team"] for u in users.values()} | {u["tier"] for u in users.values()} | {"rhoai-admins", "rhoai-users"})
    gid = {}
    s, existing = call("GET", f"{base}/groups?max=1000")
    gid.update({g["name"]: g["id"] for g in existing})
    for g in groups:
        if g not in gid:
            s, d = call("POST", f"{base}/groups", {"name": g})
            if s not in (201, 409):
                sys.exit(f"group {g}: {s} {d}")
    s, existing = call("GET", f"{base}/groups?max=1000")
    gid.update({g["name"]: g["id"] for g in existing})

    # Confidential client OpenShift's OAuth server uses. directAccessGrants allows scripted logins.
    s, found = call("GET", f"{base}/clients?clientId=openshift")
    spec = {"clientId": "openshift", "enabled": True, "publicClient": False, "secret": SECRET,
            "standardFlowEnabled": True, "directAccessGrantsEnabled": True, "redirectUris": [REDIRECT],
            "defaultClientScopes": ["profile", "email", "groups"], "protocol": "openid-connect"}
    if found:
        s, d = call("PUT", f"{base}/clients/{found[0]['id']}", dict(found[0], **spec))
    else:
        s, d = call("POST", f"{base}/clients", spec)
    if s not in (201, 204):
        sys.exit(f"client openshift: {s} {d}")
    print(f"groups={len(groups)} client=openshift ok")

    def seed(item):
        name, u = item
        s, d = call("POST", f"{base}/users", {
            "username": name, "enabled": True, "emailVerified": True, "email": f"{name}@example.com",
            "firstName": name, "lastName": u["team"], "requiredActions": [],
            "attributes": {"team": [u["team"]], "persona": [u["persona"]], "maasTier": [u["tier"]]}})
        if s not in (201, 409):
            return f"{name}: create {s} {d}"
        s, found = call("GET", f"{base}/users?username={name}&exact=true")
        uid = found[0]["id"]
        s, d = call("PUT", f"{base}/users/{uid}/reset-password", {"type": "password", "value": u["password"], "temporary": False})
        if s != 204:
            return f"{name}: password {s} {d}"
        member = [u["team"], u["tier"], "rhoai-users"] + (["rhoai-admins"] if u.get("admin") else [])
        for g in member:
            s, d = call("PUT", f"{base}/users/{uid}/groups/{gid[g]}")
            if s != 204:
                return f"{name}: group {g} {s} {d}"
        return None

    with cf.ThreadPoolExecutor(8) as ex:
        errs = [e for e in ex.map(seed, users.items()) if e]
    print(f"users={len(users)} errors={len(errs)}")
    for e in errs[:10]:
        print(" ", e)
    sys.exit(1 if errs else 0)


main()
