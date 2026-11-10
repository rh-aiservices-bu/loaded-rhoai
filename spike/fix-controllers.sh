#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
A=redhat-ods-applications
date -u +%H:%M:%SZ
python3 stop_notebooks.py medium | tail -2
echo "--- re-apply shards with quota errors"
grep -l 'status unknown for quota' logs/apply-medium-9-99.log >/dev/null && for f in generated/medium/shards/0{09,1?}.json; do oc apply --server-side --force-conflicts -f $f 2>&1 | grep -cE 'Forbidden|Error' | sed "s#^#$(basename $f) errors: #"; done
python3 stop_notebooks.py medium | tail -1
echo "--- patch controllers"
for D in dashboard-operator llm-d-batch-gateway-operator opendatahub-feast-operator maas-controller kuberay-operator trustyai-service-operator-controller-manager; do
  C=$(oc get deploy $D -n $A -o jsonpath='{.spec.template.spec.containers[0].name}')
  oc annotate deploy $D -n $A opendatahub.io/managed=false --overwrite >/dev/null
  oc patch deploy $D -n $A --type strategic -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$C\",\"resources\":{\"limits\":{\"cpu\":\"2\",\"memory\":\"2Gi\"},\"requests\":{\"cpu\":\"200m\",\"memory\":\"512Mi\"}}}]}}}}" | cut -c1-90
done
sleep 150
echo "--- did RHOAI keep the change?"
for D in dashboard-operator llm-d-batch-gateway-operator opendatahub-feast-operator maas-controller kuberay-operator trustyai-service-operator-controller-manager; do
  oc get deploy $D -n $A -o jsonpath="$D limit={.spec.template.spec.containers[0].resources.limits.memory} avail={.status.availableReplicas} managed={.metadata.annotations.opendatahub\.io/managed}{\"\n\"}"
done
oc get pods -n $A -o json | python3 -c "
import json,sys
for p in json.load(sys.stdin)['items']:
    for c in p['status'].get('containerStatuses',[]):
        if not c['ready'] and 'Completed' not in str(c['state']): print(' notready',p['metadata']['name'][:50],c['restartCount'],list(c['state'])[0],c['state'].get('waiting',{}).get('reason'))"
oc get dsc default-dsc -o json | python3 -c "
import json,sys
print('dsc not true:',[(c['type'],c.get('reason')) for c in json.load(sys.stdin)['status']['conditions'] if c['status']!='True' and c.get('reason')!='Removed'])"
oc adm top pods -n $A --no-headers 2>/dev/null | grep -E 'dashboard-operator|batch-gateway|opendatahub-feast|maas-controller|kuberay|trustyai-service-op' | cut -c1-90
