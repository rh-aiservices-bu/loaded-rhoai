#!/usr/bin/env bash
# Test the guide's Issue 7 fix: AUTH_SERVICE_TIMEOUT=2s on RHCL, then re-run maaspal load_test with traffic paused.
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
oc get subscription rhcl-operator -n openshift-operators -o jsonpath='before: {.spec.config}{"\n"}'
oc patch subscription rhcl-operator -n openshift-operators --type merge -p '{"spec":{"config":{"env":[{"name":"AUTH_SERVICE_TIMEOUT","value":"2s"}]}}}'
oc get subscription rhcl-operator -n openshift-operators -o jsonpath='after: {.spec.config}{"\n"}'
sleep 20; oc rollout status deploy/kuadrant-operator-controller-manager -n openshift-operators --timeout=300s | tail -1
oc get deploy kuadrant-operator-controller-manager -n openshift-operators -o json | python3 -c "
import json,sys
c=json.load(sys.stdin)['spec']['template']['spec']['containers'][0]; print('operator env AUTH_SERVICE_TIMEOUT=',[e.get('value') for e in c.get('env',[]) if e['name']=='AUTH_SERVICE_TIMEOUT'],'memory limit',c['resources'].get('limits',{}).get('memory'))"
sleep 90
oc get wasmplugin -A -o json 2>/dev/null | python3 -c "
import json,sys
for w in json.load(sys.stdin)['items']:
    s=json.dumps(w['spec']); i=s.find('timeout'); print('wasmplugin',w['metadata']['namespace'],w['metadata']['name'],s[i-40:i+60] if i>0 else 'no timeout field')" | cut -c1-200
N=loaded-rhoai-load; P=$(oc get pods -n $N -o name | grep loadgen | head -1)
oc exec -n $N $P -- touch /tmp/pause; log "traffic paused"; sleep 30
python3 - <<'PY' > /tmp/lr-plan4.json
import json
print(json.dumps([["load_test",{"target_model_name":"facebook-opt-125m-simulated","target_model_namespace":"llm"}],["gateway_overhead",{}]]))
PY
B=$(oc get pods -n cp-maaspal -o name | grep bff)
oc exec -i -n cp-maaspal $B -- env TOKEN="$(oc whoami -t)" PLAN="$(cat /tmp/lr-plan4.json)" python3 - < maaspal_run.py > logs/maaspal-run-4.log 2>&1; rm -f /tmp/lr-plan4.json
python3 - <<'PY'
import json
for l in open('logs/maaspal-run-4.log'):
    if l.startswith('RESULTS_JSON'):
        for x in json.loads(l[13:]):
            print(x['scenario'],x['status'])
            for a in x.get('assertions',[]): print(f"   {a.get('name','')[:34]:35} {a.get('status'):8} value={a.get('value')} target={a.get('target')}")
PY
for j in $(oc get jobs -n cp-maaspal -o name --sort-by=.metadata.creationTimestamp | grep -E 'load-test|gateway-ov' | tail -2); do echo "== $j"; oc logs -n cp-maaspal $j 2>/dev/null | grep -oE 'status=[0-9]+ [A-Za-z ]+' | sort | uniq -c | head -5; done
oc exec -n $N $(oc get pods -n $N -o name | grep loadgen | head -1) -- rm -f /tmp/pause; log "traffic resumed"
