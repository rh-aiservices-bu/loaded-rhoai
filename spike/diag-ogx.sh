#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
A=redhat-ods-applications
oc get dsc default-dsc -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)['status']
for c in d['conditions']:
    if c['type'] in ('Ready','ModulesReady','OGXReady','ProvisioningSucceeded'): print(c['type'],c['status'],c.get('reason'),c.get('lastTransitionTime'),(c.get('message') or '')[:200])
print('components.ogx',d.get('components',{}).get('ogx'))"
echo "--- ogx module CR"; oc get ogxes.components.platform.opendatahub.io -o json 2>/dev/null | python3 -c "
import json,sys
for i in json.load(sys.stdin)['items']:
    print(i['metadata']['name'],i.get('spec'));
    for c in i['status'].get('conditions',[]): print(' ',c['type'],c['status'],c.get('reason'),c.get('lastTransitionTime'),(c.get('message') or '')[:220])"
echo "--- ogx pods"; oc get pods -n $A --no-headers | grep -iE 'ogx|llama' | cut -c1-110
echo "--- deployments"; oc get deploy -n $A --no-headers | grep -iE 'ogx|llama' | cut -c1-90
oc get deploy opendatahub-ogx-operator -n $A -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('spec replicas',d['spec'].get('replicas'),'ready',d['status'].get('readyReplicas'))
for c in d['status'].get('conditions',[]): print(' ',c['type'],c['status'],c.get('reason'),(c.get('message') or '')[:160])"
echo "--- module operator log"; P=$(oc get pods -n $A -o name | grep -E 'opendatahub-ogx-operator' | head -1); oc logs -n $A $P --tail=200 2>/dev/null | grep -iE 'error|degrad|fail' | tail -8 | cut -c1-320
echo "--- ogx controller log"; oc logs -n $A deploy/ogx-k8s-operator-controller-manager --tail=200 2>/dev/null | grep -iE '"level":"error"|degrad' | tail -5 | cut -c1-320
echo "--- rhods log"; oc logs -n redhat-ods-operator deploy/rhods-operator --tail=2000 2>/dev/null | grep -iE 'ogx' | grep -iE 'error|degrad|fail' | tail -5 | cut -c1-320
echo "--- stopped workloads"; oc get pods -n lr-smoke --no-headers | grep -E 'isvc-stopped|wb-stopped' | cut -c1-90; oc get isvc isvc-stopped -n lr-smoke -o jsonpath='isvc stop={.metadata.annotations.serving\.kserve\.io/stop}{"\n"}'; oc get statefulset wb-stopped -n lr-smoke -o jsonpath='wb replicas={.spec.replicas}{"\n"}'
