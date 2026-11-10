#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
A=redhat-ods-applications
date -u +%H:%M:%SZ; oc whoami 2>&1; oc whoami --show-server 2>&1
oc get nodes --no-headers 2>&1 | awk '{print $2}' | sort | uniq -c
oc get nodes -o json | python3 -c "
import json,sys
print('node ready since',sorted({[c for c in n['status']['conditions'] if c['type']=='Ready'][0]['lastTransitionTime'] for n in json.load(sys.stdin)['items']})[-1])"
oc get co --no-headers 2>/dev/null | awk '$3!="True"||$4!="False"||$5!="False"' | cut -c1-110
oc get dsc default-dsc -o json | python3 -c "
import json,sys
d=[c for c in json.load(sys.stdin)['status']['conditions'] if c['status']!='True' and c.get('reason')!='Removed']
print('dsc not true:',[(c['type'],c.get('reason'),(c.get('message') or '')[:90]) for c in d])"
oc get monitoring default-monitoring -o json | python3 -c "
import json,sys
print('monitoring not true:',[c['type'] for c in json.load(sys.stdin)['status']['conditions'] if c['status']!='True'])"
for D in dashboard-operator llm-d-batch-gateway-operator opendatahub-feast-operator maas-controller kuberay-operator trustyai-service-operator-controller-manager; do oc get deploy $D -n $A -o jsonpath="$D limit={.spec.template.spec.containers[0].resources.limits.memory} avail={.status.availableReplicas} managed={.metadata.annotations.opendatahub\.io/managed}{\"\n\"}"; done
oc get deploy kuadrant-operator-controller-manager -n openshift-operators -o jsonpath='kuadrant limit={.spec.template.spec.containers[0].resources.limits.memory} avail={.status.availableReplicas}{"\n"}'
oc get pods -A -o json | python3 -c "
import json,sys
rows=[]
for p in json.load(sys.stdin)['items']:
    for c in p['status'].get('containerStatuses',[]):
        w=c['state'].get('waiting',{}).get('reason'); t=c.get('lastState',{}).get('terminated',{})
        if w or (not c['ready'] and 'running' in c['state']) or (t.get('finishedAt','')>'' and c['restartCount']>=3 and p['metadata']['namespace'] in ('redhat-ods-applications','openshift-operators')):
            rows.append((p['metadata']['namespace'],p['metadata']['name'][:46],c['restartCount'],w,t.get('reason'),t.get('finishedAt')))
for r in rows[:25]: print(r)"
oc get notebook -A -o json | python3 -c "
import json,sys
i=json.load(sys.stdin)['items']; print('notebooks',len(i),'stopped',sum(1 for n in i if 'kubeflow-resource-stopped' in n['metadata'].get('annotations',{})),'ready',sum(1 for n in i if n.get('status',{}).get('readyReplicas')==1))"
oc get isvc -A -o json | python3 -c "
import json,sys
i=json.load(sys.stdin)['items']; print('isvc',len(i),'stop-annotated',sum(1 for n in i if n['metadata'].get('annotations',{}).get('serving.kserve.io/stop')=='true'),'Ready',sum(1 for n in i if any(c['type']=='Ready' and c['status']=='True' for c in n.get('status',{}).get('conditions',[]))))"
echo "pvc pending: $(oc get pvc -A --no-headers | grep -c Pending)  bound: $(oc get pvc -A --no-headers | grep -c Bound)  managed ns: $(oc get ns -l loaded-rhoai.io/managed=true --no-headers | wc -l | tr -d ' ')"
oc get csv -A --no-headers | awk '{print $2,$NF}' | sort -u | grep -v Succeeded
oc adm top nodes --no-headers | awk '{print $1,$3,$5}' | cut -c1-50
curl -sk -m 15 -o /dev/null -w "maas health http=%{http_code}\n" https://maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')/maas-api/health
curl -s -m 15 -o /dev/null -w "keycloak realm http=%{http_code}\n" https://keycloak-maas-keycloak.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')/realms/maas/.well-known/openid-configuration
