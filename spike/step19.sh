#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
python3 stop_notebooks.py medium; echo "stop exit=$?"
sleep 45
oc get notebook -A -o json | python3 -c "
import json,sys
its=json.load(sys.stdin)['items']
print('notebooks',len(its),'stopped',sum(1 for n in its if 'kubeflow-resource-stopped' in n['metadata'].get('annotations',{})),'ready',sum(1 for n in its if n.get('status',{}).get('readyReplicas')==1))"
oc get pods -A --no-headers 2>/dev/null | grep -E '^lr-' | grep -c 'wb-' | sed 's/^/workbench pods: /'
oc get pods -A --no-headers 2>/dev/null | grep -E '^lr-' | grep -vE ' (Running|Completed) ' | awk '{print $1,$2,$3,$4}' | head -8 | cut -c1-100
for i in 1 2 3 4 5 6 7 8; do c=$(oc adm top nodes --no-headers | awk '{gsub("%","",$3); if($3>m)m=$3} END{print m}'); [ "${c:-99}" -lt 20 ] && break; sleep 30; done; echo "max node cpu ${c}%"
bash stage_run.sh stage1-75ns-settled 1 0
