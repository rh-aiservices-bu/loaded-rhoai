#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
date -u +%H:%M:%SZ
oc get isvc -A -o json > logs/isvc-before-exp-b.json
python3 - <<'PY' > logs/isvc-to-delete.txt
import json
items=json.load(open('logs/isvc-before-exp-b.json'))['items']
run=sorted(n['metadata']['name'] for n in items if n['metadata']['name'].startswith('model-') and n['metadata'].get('annotations',{}).get('serving.kserve.io/stop')!='true')
keep=set(run[:7])|{'isvc-running','isvc-stopped'}
for n in items:
    if n['metadata']['name'] not in keep: print(n['metadata']['namespace'],n['metadata']['name'])
import sys; print('keeping',sorted(keep),file=sys.stderr)
PY
echo "deleting $(wc -l < logs/isvc-to-delete.txt)"
n=0; while read -r ns name; do oc delete isvc "$name" -n "$ns" --wait=false >/dev/null 2>&1; n=$((n+1)); [ $((n%15)) = 0 ] && sleep 8; done < logs/isvc-to-delete.txt
for i in $(seq 1 30); do c=$(oc get isvc -A --no-headers | wc -l | tr -d ' '); [ "$c" = 9 ] && break; sleep 10; done; echo "isvc now $c, llmisvc $(oc get llminferenceservice -A --no-headers | wc -l | tr -d ' ')"
python3 etcd_recent.py 2>&1 | cut -c1-200
bash wait-stable.sh 2>&1 | grep -v 'short name' | tail -12 | cut -c1-140
U=https://rh-ai.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
.venv/bin/python ux_fanout.py $U generated/medium/users.json user0001 /ai-hub/models/deployments logs/ux/fanout-B-10m.json 2>&1 | cut -c1-175
bash stage_run.sh expB-357p-10m 1 0
python3 etcd_recent.py 2>&1 | cut -c1-200
