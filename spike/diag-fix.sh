#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
A=redhat-ods-applications
date -u +%H:%M:%SZ
echo "--- apply errors"; grep -E '^(Error|error)|failed|denied|invalid' logs/apply-medium-9-99.log | cut -c1-220 | head -4
echo "--- deployments not available in $A"; oc get deploy -n $A -o json | python3 -c "
import json,sys
for d in json.load(sys.stdin)['items']:
    if d['status'].get('availableReplicas',0)<d['spec'].get('replicas',1): print(d['metadata']['name'],d['status'].get('availableReplicas',0),'/',d['spec'].get('replicas'),[ (c['resources'].get('limits')) for c in d['spec']['template']['spec']['containers']][:1])"
for D in dashboard-operator llm-d-batch-gateway-operator opendatahub-feast-operator odh-model-controller maas-controller; do
  P=$(oc get pods -n $A -o name | grep "^pod/$D" | head -1); [ -z "$P" ] && continue
  echo "=== $D $P"
  oc get $P -n $A -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
for c,s in zip(d['status']['containerStatuses'],d['spec']['containers']):
    t=c.get('lastState',{}).get('terminated',{})
    print(c['name'],'ready',c['ready'],'restarts',c['restartCount'],list(c['state'])[0],'last',t.get('reason'),t.get('exitCode'),t.get('startedAt'),t.get('finishedAt'),'res',s.get('resources',{}).get('limits'),'live',(s.get('livenessProbe') or {}).get('initialDelaySeconds'),(s.get('livenessProbe') or {}).get('timeoutSeconds'))"
  oc logs -n $A $P --previous --tail=400 2>/dev/null | grep -iE 'error|fatal|panic|timed out|timeout|leader|lost|Failed to' | tail -4 | cut -c1-260
  oc logs -n $A $P --previous 2>/dev/null | tail -1 | cut -c1-200
  oc get events -n $A --field-selector involvedObject.name=${P#pod/} --sort-by=.lastTimestamp 2>/dev/null | tail -3 | cut -c1-170
done
echo "--- api server pressure"; oc adm top pods -n openshift-kube-apiserver --no-headers 2>/dev/null | grep kube-apiserver | cut -c1-80
oc adm top nodes --no-headers | awk '{print $1,$3,$5}' | cut -c1-50
echo "--- who owns the operator deployments"; oc get deploy dashboard-operator -n $A -o json | python3 -c "
import json,sys
m=json.load(sys.stdin)['metadata']; print(m.get('ownerReferences'),{k:v for k,v in m.get('annotations',{}).items() if 'managed' in k or 'platform' in k},{k:v for k,v in m.get('labels',{}).items() if 'part-of' in k or 'managed' in k})"
