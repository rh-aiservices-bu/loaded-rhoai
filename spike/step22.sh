#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
snap() { oc get pods -n redhat-ods-applications -o json | python3 -c "
import json,sys
print('$1',{p['metadata']['name'].rsplit('-',2)[0][:30]:sum(c['restartCount'] for c in p['status'].get('containerStatuses',[])) for p in json.load(sys.stdin)['items'] if sum(c['restartCount'] for c in p['status'].get('containerStatuses',[]))>2})"; }
snap before
ls generated/medium/shards | tail -1
bash stage_run.sh stage3-369ns 9 99
snap after
oc get pods -n openshift-operators --no-headers | grep kuadrant-operator | cut -c1-90
oc get dsc default-dsc -o jsonpath='dsc ready={.status.conditions[?(@.type=="Ready")].status}{"\n"}'
oc get dsc default-dsc -o json | python3 -c "
import json,sys
print('dsc not true:',[(c['type'],c.get('reason')) for c in json.load(sys.stdin)['status']['conditions'] if c['status']!='True' and c.get('reason')!='Removed'])"
