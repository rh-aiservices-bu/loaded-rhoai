#!/usr/bin/env python3
"""Log every generated user in once, so real User, Identity and Group objects exist (PLAN.md §6).
Usage: warm_login.py <oauth-host> <api-url> <users.json> <idp>"""
import base64,concurrent.futures as cf,json,ssl,sys,urllib.request,urllib.parse,urllib.error
host,api,f,idp=sys.argv[1:5]; users=json.load(open(f)); ctx=ssl._create_unverified_context()
class NR(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*a,**k): return None
op=urllib.request.build_opener(NR,urllib.request.HTTPSHandler(context=ctx))
def login(n):
    for attempt in range(3):
        q=urllib.parse.urlencode({"client_id":"openshift-challenging-client","response_type":"token","idp":idp})
        req=urllib.request.Request(f"https://{host}/oauth/authorize?{q}",headers={"X-CSRF-Token":"1","Authorization":"Basic "+base64.b64encode(f"{n}:{users[n]['password']}".encode()).decode()})
        try: r=op.open(req,timeout=60); loc=r.headers.get("Location","")
        except urllib.error.HTTPError as e: loc=e.headers.get("Location","") or ""
        except Exception as e: loc=""
        tok=urllib.parse.parse_qs(urllib.parse.urlparse(loc).fragment).get("access_token",[None])[0]
        if tok:
            d=json.load(urllib.request.urlopen(urllib.request.Request(f"{api}/apis/user.openshift.io/v1/users/~",headers={"Authorization":"Bearer "+tok}),context=ctx,timeout=30))
            return n,d["metadata"]["name"],d.get("groups")
    return n,None,None
with cf.ThreadPoolExecutor(6) as ex: res=list(ex.map(login,users))
bad=[r for r in res if r[1]!=r[0]]
print(f"logins ok={len(res)-len(bad)} bad={len(bad)}"); print("sample",res[5]); print("bad sample",bad[:3])
sys.exit(1 if bad else 0)
