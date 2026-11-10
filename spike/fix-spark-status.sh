#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
R=sparkoperators.components.platform.opendatahub.io/default-sparkoperator
oc annotate $R loaded-rhoai.io/recheck="$(date +%s)" --overwrite
for i in $(seq 1 9); do r=$(oc get dsc default-dsc -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'); [ "$r" = True ] && break; sleep 10; done
echo "after touching CR: dsc ready=$r"
if [ "$r" != True ]; then
  oc rollout restart deploy/rhods-operator -n redhat-ods-operator; oc rollout status deploy/rhods-operator -n redhat-ods-operator --timeout=280s | tail -1 | cut -c1-80
  for i in $(seq 1 18); do r=$(oc get dsc default-dsc -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'); [ "$r" = True ] && break; sleep 10; done
  echo "after restarting rhods-operator: dsc ready=$r"
fi
oc get dsc default-dsc -o json | python3 -c "
import json,sys
print('not true:',[(c['type'],(c.get('message') or '')[:80]) for c in json.load(sys.stdin)['status']['conditions'] if c['status']!='True' and c.get('reason')!='Removed'])"
oc get deploy -A -o json | python3 -c "
import json,sys
print('annotated managed=false:',[d['metadata']['name'] for d in json.load(sys.stdin)['items'] if d['metadata'].get('annotations',{}).get('opendatahub.io/managed')=='false' and d['metadata']['namespace']=='redhat-ods-applications'])"
