#!/usr/bin/env python3
"""Print an OpenShift access token for a generated user, logging in through the keycloak IdP
with the OAuth password challenge (the same flow warm_login.py uses).
Usage: user_token.py <oauth-host> <users.json> <user> [idp]     Also importable: token(...)"""
import base64
import json
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def token(host, user, password, idp="keycloak"):
    opener = urllib.request.build_opener(_NoRedirect, urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
    q = urllib.parse.urlencode({"client_id": "openshift-challenging-client", "response_type": "token", "idp": idp})
    req = urllib.request.Request(f"https://{host}/oauth/authorize?{q}", headers={
        "X-CSRF-Token": "1", "Authorization": "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()})
    try:
        loc = opener.open(req, timeout=60).headers.get("Location", "")
    except urllib.error.HTTPError as e:
        loc = e.headers.get("Location", "") or ""
    return urllib.parse.parse_qs(urllib.parse.urlparse(loc).fragment).get("access_token", [None])[0]


if __name__ == "__main__":
    host, users_file, user = sys.argv[1:4]
    t = token(host, user, json.load(open(users_file))[user]["password"], sys.argv[4] if len(sys.argv) > 4 else "keycloak")
    if not t:
        sys.exit(f"login failed for {user}")
    print(t)
