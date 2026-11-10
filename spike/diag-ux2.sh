#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
U=https://rh-ai.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
echo "--- notebooks now"
oc get notebook -A -o json | python3 -c "
import json,sys
its=json.load(sys.stdin)['items']
print('total',len(its),'with stop',sum(1 for n in its if 'kubeflow-resource-stopped' in n['metadata'].get('annotations',{})),'ready',sum(1 for n in its if n.get('status',{}).get('readyReplicas')==1))"
oc get pods -A --no-headers | grep -E '^lr-' | grep -c ' wb-' | sed 's/^/workbench pods: /'
oc logs -n redhat-ods-applications deploy/odh-notebook-controller-manager --since=25m 2>/dev/null | grep -iE 'stopp|culled|annotation' | grep -v 'namespace annotation' | sed -E 's/"ts":"[^"]*",//; s/"notebook":"[^"]*",//; s/"namespace":"[^"]*"//' | cut -c1-130 | sort | uniq -c | sort -rn | head -6
oc logs -n redhat-ods-applications deploy/notebook-controller-deployment --since=25m 2>/dev/null | grep -iE 'stop|annotat|cull' | cut -c1-30,60-160 | head -4
oc get notebook -A --show-managed-fields -o json | python3 -c "
import json,sys,collections
c=collections.Counter()
for n in json.load(sys.stdin)['items']:
    for m in n['metadata'].get('managedFields',[]):
        c[(m['manager'],m['operation'],m.get('subresource',''))]+=1
print(c.most_common(8))"
echo "--- keycloak/oauth"; oc get pods -n maas-keycloak --no-headers | cut -c1-60; oc get pods -n openshift-authentication --no-headers | cut -c1-60
curl -s -m 15 -o /dev/null -w 'gateway root http=%{http_code} t=%{time_total}\n' "$U/"
echo "--- dashboard backend"; oc adm top pods -n redhat-ods-applications --no-headers 2>/dev/null | grep -E 'rhods-dashboard' | cut -c1-70
oc get deploy rhods-dashboard -n redhat-ods-applications -o json | python3 -c "
import json,sys
for c in json.load(sys.stdin)['spec']['template']['spec']['containers']: print(c['name'],c.get('resources'))"
echo "--- trace workload-metrics as admin"
.venv/bin/python ux_page_trace.py "$U" generated/medium/users.json user0001 /observe-monitor/workload-metrics logs/ux/trace-workload-metrics.png 2>&1 | cut -c1-170
