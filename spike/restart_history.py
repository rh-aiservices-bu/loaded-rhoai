#!/usr/bin/env python3
"""When did each operator's container restart? Uses cluster Prometheus, and compares with namespace counts."""
import json,subprocess,time,urllib.parse
def q(path):
    r=subprocess.run(["oc","exec","-n","openshift-monitoring","prometheus-k8s-0","-c","prometheus","--","curl","-s","--max-time","50","http://localhost:9090/api/v1/"+path],capture_output=True,text=True,timeout=80)
    return json.loads(r.stdout)["data"]["result"]
end=int(time.time()); start=end-5*3600; step=300
fmt=lambda t:time.strftime("%H:%M",time.gmtime(t))
ns=q("query_range?"+urllib.parse.urlencode({"query":'count(kube_namespace_status_phase{phase="Active"})',"start":start,"end":end,"step":step}))
counts={int(t):int(float(v)) for t,v in ns[0]["values"]} if ns else {}
print("namespaces over time:"," ".join(f"{fmt(t)}={c}" for t,c in list(counts.items())[::6]))
sel='kube_pod_container_status_restarts_total{namespace=~"openshift-operators|redhat-ods-applications|redhat-ods-operator|kuadrant-system|openshift-ingress"}'
res=q("query_range?"+urllib.parse.urlencode({"query":sel,"start":start,"end":end,"step":step}))
rows=[]
for s in res:
    v=[(int(t),int(float(x))) for t,x in s["values"]]
    incs=[(a[0],b[1]-a[1]) for a,b in zip(v,v[1:]) if b[1]>a[1]]
    if not incs: continue
    after=[i for i in incs if i[0]>end-4*3600+1800 or True]
    rows.append((s["metric"]["pod"][:44],s["metric"]["container"][:12],incs))
for pod,c,incs in sorted(rows,key=lambda r:-sum(i[1] for i in r[2]))[:14]:
    f=incs[0][0]; print(f"{pod:45}{c:13}total+{sum(i[1] for i in incs):3} first={fmt(f)} (ns={counts.get(f,'?')}) last={fmt(incs[-1][0])} at:"," ".join(f"{fmt(t)}+{n}" for t,n in incs[:8]))
lim=q("query?"+urllib.parse.urlencode({"query":'kube_pod_container_resource_limits{resource="memory",pod=~"dashboard-operator.*|opendatahub-feast-operator.*|llm-d-batch-gateway-operator.*|maas-controller.*|kuadrant-operator.*"}'}))
for s in lim: print("limit",s["metric"]["pod"][:40],s["metric"]["container"],int(float(s["value"][1]))//(1024*1024),"Mi")
