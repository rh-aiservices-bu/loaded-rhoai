#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
A=redhat-ods-applications
date -u +%H:%M:%SZ
oc get dsc default-dsc -o json | python3 -c "
import json,sys
for c in json.load(sys.stdin)['status']['conditions']:
    if c['status']!='True' and c.get('reason')!='Removed' or c['type'] in ('Ready',): print(c['type'],c['status'],c.get('reason'),c.get('lastTransitionTime'),(c.get('message') or '')[:170])"
P=$(oc get pods -n $A -o name | grep kserve-module-controller-manager | head -1)
oc get $P -n $A -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
for c,s in zip(d['status']['containerStatuses'],d['spec']['containers']):
    t=c.get('lastState',{}).get('terminated',{})
    print(c['name'],'ready',c['ready'],'restarts',c['restartCount'],list(c['state'])[0],'last',t.get('reason'),t.get('exitCode'),t.get('startedAt'),t.get('finishedAt'),'limits',s.get('resources',{}).get('limits'),'node',d['spec']['nodeName'][:16])"
oc logs -n $A $P --previous --tail=500 2>/dev/null | grep -iE 'error|fatal|panic|leader|timed out|deadline|lost' | tail -6 | cut -c1-260
oc logs -n $A $P --previous --tail=2 2>/dev/null | cut -c1-200
oc get events -n $A --field-selector involvedObject.name=${P#pod/} --sort-by=.lastTimestamp 2>/dev/null | tail -4 | cut -c1-170
oc adm top pod ${P#pod/} -n $A --no-headers 2>/dev/null | cut -c1-80
echo "--- ai gateway"; oc get aigateways.components.platform.opendatahub.io -o json 2>/dev/null | python3 -c "
import json,sys
for i in json.load(sys.stdin)['items']:
    for c in i['status'].get('conditions',[]):
        if c['status']!='True' or c['type']=='Ready': print(i['metadata']['name'],c['type'],c['status'],c.get('reason'),(c.get('message') or '')[:170])"
for N in redhat-ods-applications redhat-ai-gateway-infra; do oc get deploy -n $N -o json | python3 -c "
import json,sys
print('$N unavailable:',[d['metadata']['name'] for d in json.load(sys.stdin)['items'] if d['status'].get('availableReplicas',0)<d['spec'].get('replicas',1)])"; done
oc get pods -n redhat-ai-gateway-infra --no-headers 2>&1 | cut -c1-80
oc get pods -n $A --no-headers | grep -E 'batch|maas|ai-gateway' | cut -c1-90
oc get pods -n openshift-ingress --no-headers | cut -c1-80
oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='gateway programmed={.status.conditions[?(@.type=="Programmed")].status}{"\n"}'
oc get pvc -A --no-headers | grep Pending | awk '{print $1,$2}' | head -8
