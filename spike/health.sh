#!/usr/bin/env bash
# Read-only cluster and workload health summary.
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
to="timeout 40"; command -v timeout >/dev/null || to=""
echo "--- identity"; oc whoami 2>&1; oc whoami --show-server 2>&1
echo "--- nodes"; oc get nodes --no-headers 2>&1 | cut -c1-90
echo "--- cluster"; oc get clusterversion --no-headers 2>&1 | cut -c1-110; oc get co --no-headers 2>&1 | awk '$3!="True"||$4!="False"||$5!="False"' | cut -c1-140; oc get mcp --no-headers 2>&1 | cut -c1-90
echo "--- operators not Succeeded"; oc get csv -A --no-headers 2>/dev/null | awk '{print $2,$NF}' | sort -u | grep -v Succeeded
oc get csv rhods-operator.3.5.2 -n redhat-ods-operator -o jsonpath='rhoai {.status.phase}{"\n"}' 2>&1
echo "--- dsc"; oc get dsc default-dsc -o json 2>/dev/null | python3 -c "
import json,sys
for c in json.load(sys.stdin)['status']['conditions']:
    if c['status']!='True' and c.get('reason')!='Removed': print(c['type'],c['status'],c.get('reason'),(c.get('message') or '')[:140])
print('dsc checked')"
oc get dsci default-dsci -o jsonpath='dsci {.status.phase}{"\n"}' 2>&1
oc get monitoring default-monitoring -o json 2>/dev/null | python3 -c "
import json,sys
print('monitoring not true:',[c['type'] for c in json.load(sys.stdin)['status']['conditions'] if c['status']!='True'])"
echo "--- unhealthy pods"; oc get pods -A --no-headers 2>/dev/null | grep -vE ' (Running|Completed) ' | grep -v installer- | awk '{print $1,$2,$3,$4,$5}' | cut -c1-120 | head -40
echo "--- not-fully-ready running pods"; oc get pods -A --no-headers 2>/dev/null | awk '$4=="Running"{split($3,a,"/"); if(a[1]!=a[2]) print $1,$2,$3,$5}' | cut -c1-110 | head -25
echo "--- maas"; oc get llminferenceservice -A --no-headers 2>&1 | awk '{print $1,$2,$4}'; oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='gateway programmed={.status.conditions[?(@.type=="Programmed")].status}{"\n"}' 2>&1
H=$(oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.spec.listeners[0].hostname}' 2>/dev/null); curl -sk -m 15 -o /dev/null -w "maas health http=%{http_code}\n" "https://$H/maas-api/health"
echo "--- keycloak"; oc get pods -n maas-keycloak --no-headers 2>&1 | cut -c1-70
echo "--- smoke workloads"; oc get isvc,notebook,dspa,featurestore,mcpserver,ogxserver,evalhub,trustyaiservice,sparkapplication -n lr-smoke --no-headers 2>&1 | cut -c1-110
oc get raycluster,trainjob -n lr-smoke-queued --no-headers 2>&1 | cut -c1-110; oc get mlflow mlflow --no-headers 2>&1 | cut -c1-80; oc get modelregistries.modelregistry.opendatahub.io -A --no-headers 2>&1 | cut -c1-80
oc get pods -n lr-infra --no-headers 2>&1 | cut -c1-70
oc get nodes --no-headers -o custom-columns='N:.metadata.name' 2>/dev/null | wc -l | sed 's/^/node count: /'; oc adm top nodes --no-headers 2>&1 | cut -c1-90
oc get events -A --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -8 | cut -c1-170
