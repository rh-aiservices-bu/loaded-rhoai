#!/usr/bin/env python3
import json,subprocess,urllib.parse
def q(e):
    r=subprocess.run(["oc","exec","-n","openshift-monitoring","prometheus-k8s-0","-c","prometheus","--","curl","-s","--max-time","40","http://localhost:9090/api/v1/query?"+urllib.parse.urlencode({"query":e})],capture_output=True,text=True,timeout=70)
    return json.loads(r.stdout)["data"]["result"]
for label,e,s in (("etcd commit p99 peak last 15m (ms)",'max_over_time(histogram_quantile(0.99,sum by (instance,le)(rate(etcd_disk_backend_commit_duration_seconds_bucket[2m])))[15m:1m])',1000),
                  ("etcd WAL fsync p99 peak last 15m (ms)",'max_over_time(histogram_quantile(0.99,sum by (instance,le)(rate(etcd_disk_wal_fsync_duration_seconds_bucket[2m])))[15m:1m])',1000),
                  ("lease PUT p99 peak last 15m (s)",'max_over_time(histogram_quantile(0.99,sum by (instance,le)(rate(apiserver_request_duration_seconds_bucket{resource="leases",verb="PUT"}[2m])))[15m:1m])',1),
                  ("controller restarts last 15m",'sum(increase(kube_pod_container_status_restarts_total{namespace=~"redhat-ods-applications|openshift-operators"}[15m]))',1)):
    print(label,[(x["metric"].get("instance","all").split(":")[0],round(float(x["value"][1])*s,1)) for x in q(e)])
