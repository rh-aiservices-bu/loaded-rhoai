#!/usr/bin/env bash
# Pull the workbench images onto every worker, one image at a time per node, before workbenches exist.
# Init containers run in order, so each node pulls serially. The DaemonSet is removed afterwards;
# the images stay in each node's cache.
# Usage: prepull.sh [images.json]
set -uo pipefail
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
IMG=${1:-generated/notebook-images.json}
python3 - "$IMG" > /tmp/lr-prepull.json <<'PY'
import json,sys
imgs=sorted(set(json.load(open(sys.argv[1])).values()))
init=[{"name":f"pull-{i}","image":r,"command":["/bin/sh","-c","true"],"resources":{"requests":{"cpu":"10m","memory":"16Mi"}}} for i,r in enumerate(imgs)]
ds={"apiVersion":"apps/v1","kind":"DaemonSet","metadata":{"name":"lr-image-prepull","namespace":"lr-infra"},
    "spec":{"selector":{"matchLabels":{"app":"lr-image-prepull"}},"template":{"metadata":{"labels":{"app":"lr-image-prepull"}},
    "spec":{"nodeSelector":{"node-role.kubernetes.io/worker":""},"initContainers":init,
            "containers":[{"name":"done","image":imgs[0],"command":["/bin/sh","-c","sleep 86400"],"resources":{"requests":{"cpu":"10m","memory":"16Mi"}}}]}}}}
print(json.dumps(ds))
PY
oc apply -f /tmp/lr-prepull.json; rm -f /tmp/lr-prepull.json
t0=$(date +%s)
for i in $(seq 1 120); do
  d=$(oc get ds lr-image-prepull -n lr-infra -o jsonpath='{.status.desiredNumberScheduled}'); r=$(oc get ds lr-image-prepull -n lr-infra -o jsonpath='{.status.numberReady}')
  [ -n "$d" ] && [ "${r:-0}" = "$d" ] && [ "$d" -gt 0 ] && break; sleep 15
done
echo "prepull: ${r:-0}/$d nodes ready after $(( $(date +%s)-t0 ))s"
oc get pods -n lr-infra -l app=lr-image-prepull --no-headers -o wide | awk '{print "  ",$1,$3,$7}'
oc delete ds lr-image-prepull -n lr-infra
