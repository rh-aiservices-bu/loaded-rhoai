#!/usr/bin/env bash
# Pass only after the DSC is Ready and no RHOAI controller has restarted for 5 minutes in a row.
# Gives up after SETTLE_TIMEOUT seconds (default 1200). Prints a short state summary either way.
set -uo pipefail
sum() { oc get pods -n redhat-ods-applications -o json | python3 -c "
import json,sys
print(sum(c['restartCount'] for p in json.load(sys.stdin)['items'] for c in p['status'].get('containerStatuses',[])))"; }
good=0; last=$(sum); t0=$(date +%s)
while [ $(( $(date +%s)-t0 )) -lt "${SETTLE_TIMEOUT:-1200}" ]; do
  sleep 30; r=$(oc get dsc default-dsc -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'); n=$(sum)
  if [ "$r" = True ] && [ "$n" = "$last" ]; then good=$((good+30)); else good=0; fi
  echo "  $(date -u +%H:%M:%S) dsc-ready=$r controller-restarts=$n stable=${good}s"; last=$n
  [ "$good" -ge 300 ] && break
done
oc get dsc default-dsc -o json | python3 -c "
import json,sys
for c in json.load(sys.stdin)['status']['conditions']:
    if c['status']!='True' and c.get('reason')!='Removed': print('  dsc',c['type'],c.get('reason'),(c.get('message') or '')[:150])"
oc get pods -A -o json | python3 -c "
import json,sys
for p in json.load(sys.stdin)['items']:
    ns=p['metadata']['namespace']
    for c in p['status'].get('containerStatuses',[]):
        w=c['state'].get('waiting',{}).get('reason')
        if w or (not c['ready'] and 'running' in c['state']): print('  not ready',ns,p['metadata']['name'][:48],c['name'][:18],c['restartCount'],w)"
oc get notebook -A -o json | python3 -c "
import json,sys
i=json.load(sys.stdin)['items']; print('  notebooks',len(i),'stopped',sum(1 for n in i if 'kubeflow-resource-stopped' in n['metadata'].get('annotations',{})),'ready',sum(1 for n in i if n.get('status',{}).get('readyReplicas')==1))"
oc get isvc -A -o json | python3 -c "
import json,sys
i=json.load(sys.stdin)['items']; print('  isvc',len(i),'stopped',sum(1 for n in i if n['metadata'].get('annotations',{}).get('serving.kserve.io/stop')=='true'),'ready',sum(1 for n in i if any(c['type']=='Ready' and c['status']=='True' for c in n.get('status',{}).get('conditions',[]))))"
if [ "$good" -ge 300 ]; then echo "  STABLE"; else echo "  NOT STABLE after $(( $(date +%s)-t0 ))s"; exit 1; fi
