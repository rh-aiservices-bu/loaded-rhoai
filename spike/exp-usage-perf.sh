#!/usr/bin/env bash
# Exact per-user usage check with traffic paused, then maaspal's metric and performance scenarios.
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
N=loaded-rhoai-load
oc create configmap loadgen-script -n $N --from-file=loadgen.py=loadgen.py --dry-run=client -o yaml | oc apply -f - >/dev/null
oc rollout restart deploy/loadgen -n $N >/dev/null; oc rollout status deploy/loadgen -n $N --timeout=180s >/dev/null
E=$(date -u +%s); echo $E > logs/loadgen-start-epoch; log "load generator restarted, collecting 8 minutes"
sleep 480
P=$(oc get pods -n $N -o name | grep loadgen | head -1)
oc exec -n $N $P -- touch /tmp/pause; log "traffic paused; waiting 150 s for in-flight requests and two scrapes"
sleep 150
log "exact per-user comparison (traffic stopped)"
python3 usage_check.py $E 2>&1 | grep -vE '^MaaS counters' | cut -c1-200
log "maaspal: usage metrics with the right route, then performance, all with traffic paused"
python3 - <<'PY' > /tmp/lr-plan3.json
import json
m={"target_model_name":"facebook-opt-125m-simulated","target_model_namespace":"llm"}
nb={"send_from_browser":False}
print(json.dumps([
 ["usage_metrics_accuracy",dict(m,**nb,subscription="simulator-premium",limitador_namespace="llm/facebook-opt-125m-simulated-kserve-route")],
 ["gateway_overhead",{}],
 ["load_test",dict(m)],
 ["multi_model_load",{}],
]))
PY
B=$(oc get pods -n cp-maaspal -o name | grep bff)
oc exec -i -n cp-maaspal $B -- env TOKEN="$(oc whoami -t)" PLAN="$(cat /tmp/lr-plan3.json)" python3 - < maaspal_run.py > logs/maaspal-run-3.log 2>&1; rm -f /tmp/lr-plan3.json
grep -v RESULTS_JSON logs/maaspal-run-3.log | cut -c1-330
python3 - <<'PY'
import json
for l in open('logs/maaspal-run-3.log'):
    if l.startswith('RESULTS_JSON'):
        for x in json.loads(l[13:]):
            for a in x.get('assertions',[]):
                print(f"  {x['scenario']:20} {a.get('name','')[:34]:35} {a.get('status'):8} value={a.get('value')} target={a.get('target')}")
PY
oc exec -n $N $(oc get pods -n $N -o name | grep loadgen | head -1) -- rm -f /tmp/pause; log "traffic resumed"
