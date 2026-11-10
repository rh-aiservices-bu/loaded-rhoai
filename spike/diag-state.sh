#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
date -u +%H:%M:%SZ
echo "--- leftovers"; pgrep -fl 'ux_timing|stage_run|apply_shards|stop_notebooks|step22' | cut -c1-110
grep -l . logs/apply-medium-9-99.log 2>/dev/null && echo "applied lines: $(grep -cE 'serverside-applied|unchanged' logs/apply-medium-9-99.log)  errors: $(grep -cE '^(Error|error)|failed|denied|invalid' logs/apply-medium-9-99.log)"
ls logs/ux-stage3* 2>/dev/null
echo "--- counts vs generated"; python3 - <<'PY'
import json,collections
inv=json.load(open('generated/medium/expected-inventory.json'))
c=collections.Counter(o['kind'] for o in inv); print({k:c[k] for k in ('Namespace','Notebook','InferenceService','ServingRuntime','DataSciencePipelinesApplication')})
PY
echo "ns=$(oc get ns -l loaded-rhoai.io/managed=true --no-headers | wc -l | tr -d ' ') notebooks=$(oc get notebook -A --no-headers | wc -l | tr -d ' ') isvc=$(oc get isvc -A --no-headers | wc -l | tr -d ' ') runtimes=$(oc get servingruntime -A --no-headers | wc -l | tr -d ' ') dspa=$(oc get dspa -A --no-headers | wc -l | tr -d ' ')"
oc get notebook -A -o json | python3 -c "
import json,sys
i=json.load(sys.stdin)['items']; print('notebooks stopped',sum(1 for n in i if 'kubeflow-resource-stopped' in n['metadata'].get('annotations',{})),'ready',sum(1 for n in i if n.get('status',{}).get('readyReplicas')==1))"
oc get isvc -A -o json | python3 -c "
import json,sys
i=json.load(sys.stdin)['items']; print('isvc stop-annotated',sum(1 for n in i if n['metadata'].get('annotations',{}).get('serving.kserve.io/stop')=='true'),'Ready=True',sum(1 for n in i if any(c['type']=='Ready' and c['status']=='True' for c in n.get('status',{}).get('conditions',[]))))"
echo "--- dsc"; oc get dsc default-dsc -o json | python3 -c "
import json,sys
for c in json.load(sys.stdin)['status']['conditions']:
    if c['status']!='True' and c.get('reason')!='Removed': print(c['type'],c['status'],c.get('reason'),c.get('lastTransitionTime'),(c.get('message') or '')[:200])"
oc get ogxs.components.platform.opendatahub.io default-ogx -o jsonpath='ogx degraded={.status.conditions[?(@.type=="Degraded")].status} {.status.conditions[?(@.type=="Degraded")].message}{"\n"}' | cut -c1-160
echo "--- crash-looping or restarting"; oc get pods -A -o json | python3 -c "
import json,sys
for p in json.load(sys.stdin)['items']:
    for c in p['status'].get('containerStatuses',[]):
        w=c['state'].get('waiting',{}).get('reason'); t=c.get('lastState',{}).get('terminated',{})
        if w in ('CrashLoopBackOff','ImagePullBackOff','ErrImagePull') or c['restartCount']>=8: print(c['restartCount'],w,p['metadata']['namespace'],p['metadata']['name'][:50],t.get('reason'),t.get('finishedAt'))"
oc get pods -A --no-headers | grep -E '^lr-' | grep -vE ' (Running|Completed) ' | awk '{print $1,$2,$3,$4}' | head -8 | cut -c1-100
echo "--- where deployed models are listed"; G=$(oc get route -n openshift-ingress data-science-gateway -o jsonpath='{.spec.host}'); P=$(oc get pods -n redhat-ods-applications -o name | grep '^pod/rhods-dashboard' | head -1); oc exec -n redhat-ods-applications $P -c rhods-dashboard -- sh -c 'cd /usr/src/app/frontend/public 2>/dev/null || cd /usr/src/app; grep -rhoE "/ai-hub/[a-zA-Z/-]*(deploy|registry)[a-zA-Z/-]*" . 2>/dev/null | sort -u | head -12' 2>/dev/null | cut -c1-90
