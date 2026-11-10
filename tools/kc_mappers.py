#!/usr/bin/env python3
"""Add the claims OpenShift needs to the `openshift` client. Usage: kc_mappers.py <keycloak-url>. Idempotent."""
import json,os,ssl,sys,urllib.request,urllib.parse,urllib.error
KC=sys.argv[1]; ctx=ssl.create_default_context()
def call(m,p,t=None,b=None,form=None):
    h={}; d=None
    if form: d=urllib.parse.urlencode(form).encode(); h["Content-Type"]="application/x-www-form-urlencoded"
    elif b is not None: d=json.dumps(b).encode(); h["Content-Type"]="application/json"
    if t: h["Authorization"]="Bearer "+t
    try:
        with urllib.request.urlopen(urllib.request.Request(KC+p,data=d,headers=h,method=m),context=ctx,timeout=30) as r:
            x=r.read(); return r.status,(json.loads(x) if x else None)
    except urllib.error.HTTPError as e: return e.code,e.read().decode()[:200]
_,t=call("POST","/realms/master/protocol/openid-connect/token",form={"grant_type":"password","client_id":"admin-cli","username":os.environ["KC_ADMIN"],"password":os.environ["KC_ADMIN_PASSWORD"]})
t=t["access_token"]; base="/admin/realms/maas"
print("realm scopes:",[s["name"] for s in call("GET",base+"/client-scopes",t)[1]])
c=call("GET",base+"/clients?clientId=openshift",t)[1][0]
print("client default scopes:",c.get("defaultClientScopes"),"mappers:",[m["name"] for m in c.get("protocolMappers",[])])
cfg=lambda claim,attr:{"user.attribute":attr,"claim.name":claim,"jsonType.label":"String","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}
want=[("preferred_username","username"),("email","email")]
have={m["name"] for m in c.get("protocolMappers",[])}
for claim,attr in want:
    if claim not in have:
        s,d=call("POST",f"{base}/clients/{c['id']}/protocol-mappers/models",t,{"name":claim,"protocol":"openid-connect","protocolMapper":"oidc-usermodel-property-mapper","config":cfg(claim,attr)})
        print("added",claim,s,d if s!=201 else "")
if "name" not in have:
    s,d=call("POST",f"{base}/clients/{c['id']}/protocol-mappers/models",t,{"name":"name","protocol":"openid-connect","protocolMapper":"oidc-full-name-mapper","config":{"id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}})
    print("added name",s,d if s!=201 else "")
