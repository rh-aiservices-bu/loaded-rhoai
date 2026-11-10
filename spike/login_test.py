#!/usr/bin/env python3
"""Log a generated user in through OpenShift OAuth's password challenge, without touching kubeconfig.
Usage: login_test.py <oauth-host> <api-url> <users.json> <idp> <user> [<user>...]"""
import base64,json,ssl,sys,urllib.request,urllib.parse,urllib.error
host,api,users_file,idp=sys.argv[1:5]; names=sys.argv[5:]
users=json.load(open(users_file)); ctx=ssl._create_unverified_context()
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*a,**k): return None
op=urllib.request.build_opener(NoRedirect,urllib.request.HTTPSHandler(context=ctx))
for n in names:
    q=urllib.parse.urlencode({"client_id":"openshift-challenging-client","response_type":"token","idp":idp})
    req=urllib.request.Request(f"https://{host}/oauth/authorize?{q}",headers={"X-CSRF-Token":"1","Authorization":"Basic "+base64.b64encode(f"{n}:{users[n]['password']}".encode()).decode()})
    try:
        r=op.open(req,timeout=60); code,loc=r.status,r.headers.get("Location","")
    except urllib.error.HTTPError as e:
        code,loc=e.code,e.headers.get("Location","")
    frag=urllib.parse.parse_qs(urllib.parse.urlparse(loc).fragment)
    tok=frag.get("access_token",[None])[0]
    if not tok:
        print(n,"LOGIN FAILED",code,loc[:150]); continue
    who=urllib.request.Request(f"{api}/apis/user.openshift.io/v1/users/~",headers={"Authorization":"Bearer "+tok})
    d=json.load(urllib.request.urlopen(who,context=ctx,timeout=30))
    print(n,"ok name=",d["metadata"]["name"],"identities=",d.get("identities"),"groups=",d.get("groups"))
