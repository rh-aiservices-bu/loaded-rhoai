#!/usr/bin/env python3
"""What was the control plane doing during the controller restart waves? Uses cluster Prometheus."""
import json,subprocess,time,urllib.parse
def q(path):
    r=subprocess.run(["oc","exec","-n","openshift-monitoring","prometheus-k8s-0","-c","prometheus","--","curl","-s","--max-time","55","http://localhost:9090/api/v1/"+path],capture_output=True,text=True,timeout=90)
    try: return json.loads(r.stdout)["data"]["result"]
    except Exception: return []
end=int(time.time()); start=end-100*60; step=120
fmt=lambda t:time.strftime("%H:%M",time.gmtime(t))
def rng(label,expr,scale=1,unit=""):
    res=q("query_range?"+urllib.parse.urlencode({"query":expr,"start":start,"end":end,"step":step}))
    print(f"--- {label}")
    for s in res[:6]:
        m=s["metric"]; name=m.get("instance",m.get("pod",m.get("verb",m.get("code",""))))
        vals=[(int(t),float(v)*scale) for t,v in s["values"] if v!="NaN"]
        if not vals: continue
        peak=max(vals,key=lambda x:x[1]); med=sorted(v for _,v in vals)[len(vals)//2]
        spikes=[f"{fmt(t)}={v:.1f}" for t,v in vals if v>max(med*3,0.001)][:10]
        print(f"  {name[:34]:35} median={med:.2f}{unit} peak={peak[1]:.2f}{unit}@{fmt(peak[0])} spikes:{spikes}")
rng("API p99 latency, mutating (s)",'histogram_quantile(0.99,sum by (instance,le)(rate(apiserver_request_duration_seconds_bucket{verb=~"POST|PUT|PATCH|DELETE",subresource!="log"}[2m])))',1,"s")
rng("API p99 latency, leases (s)",'histogram_quantile(0.99,sum by (instance,le)(rate(apiserver_request_duration_seconds_bucket{resource="leases",verb="PUT"}[2m])))',1,"s")
rng("API requests per second",'sum by (instance)(rate(apiserver_request_total[2m]))',1,"/s")
rng("API requests rejected by flow control",'sum by (priority_level)(rate(apiserver_flowcontrol_rejected_requests_total[2m]))',1,"/s")
rng("API 5xx per second",'sum by (code)(rate(apiserver_request_total{code=~"5.."}[2m]))',1,"/s")
rng("etcd WAL fsync p99 (ms)",'histogram_quantile(0.99,sum by (instance,le)(rate(etcd_disk_wal_fsync_duration_seconds_bucket[2m])))',1000,"ms")
rng("etcd backend commit p99 (ms)",'histogram_quantile(0.99,sum by (instance,le)(rate(etcd_disk_backend_commit_duration_seconds_bucket[2m])))',1000,"ms")
rng("etcd leader changes (per 2m)",'sum(increase(etcd_server_leader_changes_seen_total[2m]))')
rng("etcd db size (MB)",'max by (instance)(etcd_mvcc_db_total_size_in_bytes)',1/1048576,"MB")
rng("apiserver memory (GiB)",'sum by (pod)(container_memory_working_set_bytes{namespace="openshift-kube-apiserver",container="kube-apiserver"})',1/2**30,"Gi")
rng("apiserver CPU (cores)",'sum by (pod)(rate(container_cpu_usage_seconds_total{namespace="openshift-kube-apiserver",container="kube-apiserver"}[2m]))',1,"c")
rng("apiserver restarts",'sum by (pod)(increase(kube_pod_container_status_restarts_total{namespace="openshift-kube-apiserver"}[2m]))')
rng("Node load per node",'node_load1',1,"")
rng("Controller restarts across RHOAI (per 2m)",'sum(increase(kube_pod_container_status_restarts_total{namespace=~"redhat-ods-applications|openshift-operators"}[2m]))')
rng("Top API clients: watches open",'sum by (resource)(apiserver_longrunning_requests{verb="WATCH"})')
top=q("query?"+urllib.parse.urlencode({"query":'topk(10,sum by (resource)(apiserver_storage_objects))'}))
print("--- objects:",[(s["metric"]["resource"][:26],int(float(s["value"][1]))) for s in top])
top=q("query?"+urllib.parse.urlencode({"query":'topk(8,sum by (username)(rate(apiserver_request_total[10m])))'}))
print("--- top requesters:",[(s["metric"].get("username","?")[:40],round(float(s["value"][1]),1)) for s in top])
top=q("query?"+urllib.parse.urlencode({"query":'topk(8,sum by (resource,verb)(rate(apiserver_request_total{verb=~"LIST|WATCH|GET"}[10m])))'}))
print("--- top reads:",[(s["metric"].get("resource","?")[:24],s["metric"].get("verb"),round(float(s["value"][1]),1)) for s in top])
