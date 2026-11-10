#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd /Users/phayes/projects/loaded-rhoai/spike
A=redhat-ods-applications
oc get ogxs.components.platform.opendatahub.io default-ogx -o yaml > logs/ogx-module-before-restart.yaml
oc get ogxserver ogx-smoke -n lr-smoke -o yaml > logs/ogxserver-before-restart.yaml
date -u +'before %H:%M:%SZ'
oc rollout restart deploy/opendatahub-ogx-operator -n $A
oc rollout status deploy/opendatahub-ogx-operator -n $A --timeout=180s
for i in $(seq 1 12); do r=$(oc get dsc default-dsc -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'); [ "$r" = True ] && break; sleep 10; done
date -u +'after %H:%M:%SZ'; echo "dsc ready=$r"
oc get ogxs.components.platform.opendatahub.io default-ogx -o json | python3 -c "
import json,sys
[print(c['type'],c['status'],c.get('reason'),c.get('lastTransitionTime'),(c.get('message') or '')[:120]) for c in json.load(sys.stdin)['status']['conditions']]"
oc get dsc default-dsc -o json | python3 -c "
import json,sys
print('not true:',[(c['type'],c.get('reason')) for c in json.load(sys.stdin)['status']['conditions'] if c['status']!='True' and c.get('reason')!='Removed'])"
