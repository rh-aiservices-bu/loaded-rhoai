#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
date -u +%H:%M:%SZ
M=ocp-5xv6t-worker-us-east-2c-compute-gcd7s
oc get machine $M -n openshift-machine-api -o json | python3 -c "
import json,sys
d=json.load(sys.stdin); s=d['status']; print('phase',s.get('phase'),'created',d['metadata']['creationTimestamp'],'instance',s.get('providerStatus',{}).get('instanceState'),'addresses',[a['address'] for a in s.get('addresses',[])][:2])
for c in s.get('conditions',[])+s.get('providerStatus',{}).get('conditions',[]): print(' ',c['type'],c['status'],c.get('reason'),(c.get('message') or '')[:140])"
oc get csr --no-headers 2>/dev/null | awk '{print $NF, $3}' | sort | uniq -c | tail -6
oc get csr --no-headers 2>/dev/null | grep -i pending | cut -c1-120 | tail -5
oc get machineset ocp-5xv6t-worker-us-east-2a-compute -n openshift-machine-api -o json | python3 -c "
import json,sys
print('2a userdata',json.load(sys.stdin)['spec']['template']['spec']['providerSpec']['value'].get('userDataSecret'))"
oc get machineset ocp-5xv6t-worker-us-east-2c-compute -n openshift-machine-api -o json | python3 -c "
import json,sys
v=json.load(sys.stdin)['spec']['template']['spec']['providerSpec']['value']; print('2c userdata',v.get('userDataSecret'),v.get('subnet'),v.get('securityGroups'),v.get('ami'))"
oc logs -n openshift-cluster-machine-approver deploy/machine-approver -c machine-approver-controller --tail=6 2>/dev/null | cut -c1-170
oc get mcp worker --no-headers | cut -c1-90
oc get pods -n openshift-machine-config-operator --no-headers | grep -E 'machine-config-server' | cut -c1-70
curl -sk -m 8 -o /dev/null -w 'mcs port via api lb: http=%{http_code}\n' "https://api-int.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' | sed 's/^apps\.//'):22623/healthz"
