#!/usr/bin/env bash
# Deployments page with projects fixed: 10 models -> 152 models -> 10 models.
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
U=https://rh-ai.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
UF=generated/medium/users.json
measure() {  # $1 label
  echo "=== $1  isvc=$(oc get isvc -A --no-headers | wc -l | tr -d ' ') runtimes=$(oc get servingruntime -A --no-headers | wc -l | tr -d ' ') projects=$(oc get ns -l opendatahub.io/dashboard=true --no-headers | wc -l | tr -d ' ')"
  for r in 1 2; do .venv/bin/python ux_fanout.py "$U" $UF user0001 /ai-hub/models/deployments logs/ux/models-$1-admin-$r.json 2>&1 | head -1 | cut -c1-260; done
  .venv/bin/python ux_fanout.py "$U" $UF user0009 /ai-hub/models/deployments logs/ux/models-$1-lead.json 2>&1 | head -1 | cut -c1-200
  .venv/bin/python ux_fanout.py "$U" $UF user0040 /ai-hub/models/deployments logs/ux/models-$1-regular.json 2>&1 | head -1 | cut -c1-200
  python3 etcd_recent.py 2>&1 | tail -1
}
settle() { python3 stop_notebooks.py medium-m9 | tail -1; bash wait-stable.sh 2>&1 | grep -E '^STABLE|NOT STABLE'; }
date -u +%H:%M:%SZ
measure A-10models
bash apply_shards.sh medium-m152 0 99
settle
measure B-152models
python3 - <<'PY' > logs/models-to-remove.txt
import json
keep={(o['kind'],o['namespace'],o['name']) for o in json.load(open('generated/medium-m9/expected-inventory.json'))}
for o in json.load(open('generated/medium-m152/expected-inventory.json')):
    if o['kind'] in ('InferenceService','ServingRuntime') and (o['kind'],o['namespace'],o['name']) not in keep:
        print(o['kind'],o['namespace'],o['name'])
PY
echo "removing $(wc -l < logs/models-to-remove.txt) objects"
while read -r k ns n; do oc delete "$k" "$n" -n "$ns" --wait=false >/dev/null 2>&1; done < <(grep InferenceService logs/models-to-remove.txt)
while read -r k ns n; do oc delete "$k" "$n" -n "$ns" --wait=false >/dev/null 2>&1; done < <(grep ServingRuntime logs/models-to-remove.txt)
for i in $(seq 1 30); do [ "$(oc get isvc -A --no-headers | wc -l | tr -d ' ')" = 9 ] && break; sleep 10; done
settle
measure C-10models-again
date -u +%H:%M:%SZ
