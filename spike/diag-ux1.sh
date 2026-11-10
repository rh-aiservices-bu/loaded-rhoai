#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
echo "--- pods not running"; oc get pods -A --no-headers 2>/dev/null | grep -E '^lr-' | grep -vE ' (Running|Completed) ' | awk '{print $1,$2,$3,$4,$6}' | head -14
P=$(oc get pods -A --no-headers | grep -E '^lr-' | grep ContainerCreating | head -1 | awk '{print $1"/"$2}'); if [ -n "$P" ]; then oc get events -n ${P%/*} --field-selector involvedObject.name=${P#*/} --sort-by=.lastTimestamp 2>/dev/null | tail -5 | cut -c1-210; fi
oc get nodes -o json | python3 -c "
import json,sys
for n in json.load(sys.stdin)['items']: print(n['metadata']['name'][:18],'attached vols',len(n['status'].get('volumesAttached',[])),'images',len(n['status'].get('images',[])))"
oc adm top nodes --no-headers | awk '{print $1,$3,$5}' | cut -c1-50
oc get notebook -A -o json | python3 -c "
import json,sys
its=json.load(sys.stdin)['items']; run=[n for n in its if 'kubeflow-resource-stopped' not in n['metadata'].get('annotations',{})]
print('notebooks',len(its),'running-intended',len(run),'ready',sum(1 for n in run if n.get('status',{}).get('readyReplicas')==1))"
echo "--- failing observe calls"; python3 - <<'PY'
import json
d=json.load(open('logs/ux/stage1-75ns.json'))['users']['admin']['pages']['observe']
print(d['slowest_ms'],d['slowest_url']); print(d['failed'])
PY
echo "--- perses"; oc get pods -n redhat-ods-monitoring --no-headers | grep -iE 'perses|thanos|prometheus' | cut -c1-75
oc get persesdatasource -n redhat-ods-monitoring --no-headers 2>/dev/null | cut -c1-90
oc get persesdashboard -A --no-headers 2>/dev/null | cut -c1-90
oc logs -n redhat-ods-monitoring $(oc get pods -n redhat-ods-monitoring -o name | grep -i perses | grep -v operator | head -1) --tail=200 2>/dev/null | grep -iE 'error|timeout|400|504' | tail -5 | cut -c1-260
oc get persesdatasource cluster-prometheus-tenancy-datasource -n redhat-ods-monitoring -o json 2>/dev/null | python3 -c "
import json,sys
print(json.dumps(json.load(sys.stdin)['spec'])[:500])"
oc get pods -n openshift-monitoring --no-headers | grep -E 'thanos|prometheus-k8s' | cut -c1-70
oc get pods -n openshift-user-workload-monitoring --no-headers | cut -c1-70
echo "--- gen-ai"; oc get pods -n redhat-ods-applications --no-headers | grep -iE 'gen-ai|dashboard' | cut -c1-70
oc logs -n redhat-ods-applications deploy/rhods-dashboard -c gen-ai-ui --tail=200 2>/dev/null | grep -iE 'error|lsd|vectorstore' | tail -5 | cut -c1-260
oc get deploy rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.template.spec.containers[*].name}{"\n"}'
