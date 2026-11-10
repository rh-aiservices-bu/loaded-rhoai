#!/usr/bin/env bash
# Re-apply the population on the new workers: prepull, staggered apply, then verify each change.
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
log "delete the old running 'suspended' RayClusters (replaced by held ray-idle)"
for ns in $(oc get raycluster -A --no-headers | awk '$2=="ray-suspended"{print $1}'); do oc delete raycluster ray-suspended -n $ns --wait=false; done
log "prepull workbench images"
bash prepull.sh generated/notebook-images.json
log "staggered apply of medium-m9"
STAGGER=1 bash apply_shards.sh medium-m9 0 99
python3 stop_notebooks.py medium-m9 | tail -1
log "settle"
bash wait-stable.sh 2>&1 | grep -E '^STABLE|NOT STABLE|notready|unavailable' | head -8 | cut -c1-140
log "verify"
python3 - <<'PY'
import json,subprocess,urllib.parse
def q(e):
    r=subprocess.run(["oc","exec","-n","openshift-monitoring","prometheus-k8s-0","-c","prometheus","--","curl","-s","--max-time","40","http://localhost:9090/api/v1/query?"+urllib.parse.urlencode({"query":e})],capture_output=True,text=True,timeout=70)
    return json.loads(r.stdout)["data"]["result"]
low=q('min_over_time((node_filesystem_avail_bytes{mountpoint="/var"} or node_filesystem_avail_bytes{mountpoint="/sysroot"})[45m:1m])')
size=q('node_filesystem_size_bytes{mountpoint="/var"} or node_filesystem_size_bytes{mountpoint="/sysroot"}')
sz={s['metric']['instance'][:16]:round(float(s['value'][1])/2**30) for s in size}
print("lowest free disk in last 45 min:",{s['metric']['instance'][:16]:f"{round(float(s['value'][1])/2**30,1)} of {sz.get(s['metric']['instance'][:16])} GiB" for s in low})
PY
echo "evictions since $T0: $(oc get events -A --field-selector reason=Evicted -o json | python3 -c "
import json,sys
print(sum(1 for e in json.load(sys.stdin)['items'] if (e.get('lastTimestamp') or '')>='$T0'))")"
oc get raycluster -A -o json | python3 -c "
import json,sys
print('rayclusters:',[(r['metadata']['namespace'][-10:],r['metadata']['name'],'suspend',r['spec'].get('suspend'),r.get('status',{}).get('state')) for r in json.load(sys.stdin)['items']])"
echo "ray pods: $(oc get pods -A --no-headers | grep -c ray-idle)"
oc get workloads.kueue.x-k8s.io -A --no-headers | grep -i ray | cut -c1-110
oc get modelregistries.modelregistry.opendatahub.io -A -o json | python3 -c "
import json,sys
print('registries:',[(m['metadata']['name'],[(c['type'],c['status']) for c in m.get('status',{}).get('conditions',[]) if c['type']=='Available']) for m in json.load(sys.stdin)['items']])"
oc get featurestore,trustyaiservice -A --no-headers | cut -c1-90
oc get pods -A --no-headers | grep -E 'trustyai|feast-features' | awk '{print $1,$2,$3,$4}'
oc get notebook -A -o json | python3 -c "
import json,sys,collections
i=json.load(sys.stdin)['items']
print('notebooks stopped',sum(1 for n in i if 'kubeflow-resource-stopped' in n['metadata'].get('annotations',{})),'ready',sum(1 for n in i if n.get('status',{}).get('readyReplicas')==1),'images',dict(collections.Counter(n['metadata']['annotations'].get('notebooks.opendatahub.io/last-image-selection') for n in i)))"
python3 sweep.py generated/medium-m9 2>&1 | sed -n '/expected inventory/,$p' | grep -v 'missing   0'
log "done"
