#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
python3 - <<'PY'
import json,glob,copy
for f in sorted(glob.glob('generated/medium/shards/*.json')):
    for d in json.load(open(f))['items']:
        if d['kind']=='Notebook' and d['metadata']['name']=='wb-0000':
            json.dump(d,open('/tmp/lr-a.json','w'))
            e=copy.deepcopy(d); e['metadata']['name']='wb-test-recent'; e['metadata']['annotations']['kubeflow-resource-stopped']='2026-11-06T09:00:00Z'
            json.dump(e,open('/tmp/lr-b.json','w'))
            print('generated annotation',d['metadata']['annotations'].get('kubeflow-resource-stopped'))
PY
for f in a b; do oc apply --server-side --force-conflicts --dry-run=server -f /tmp/lr-$f.json -o json 2>&1 | python3 -c "
import json,sys
d=json.load(sys.stdin); print(d['metadata']['name'],'stop=',d['metadata']['annotations'].get('kubeflow-resource-stopped'))"; done
oc get notebook wb-0000 -n lr-team-01 --show-managed-fields -o json | python3 -c "
import json,sys
for m in json.load(sys.stdin)['metadata'].get('managedFields',[]):
    print(m['manager'],m['operation'],m.get('time'),m.get('subresource',''),[k for k in m.get('fieldsV1',{}).get('f:metadata',{}).get('f:annotations',{}) if 'stop' in k])"
oc get statefulset wb-0000 -n lr-team-01 -o jsonpath='sts replicas={.spec.replicas}{"\n"}'
oc logs -n redhat-ods-applications deploy/odh-notebook-controller-manager --since=30m 2>/dev/null | grep -iE 'wb-0000' | grep -iE 'stop|annot' | tail -3 | cut -c1-200
oc logs -n redhat-ods-applications deploy/notebook-controller-deployment --since=30m 2>/dev/null | grep -iE 'wb-0000' | tail -3 | cut -c1-200
rm -f /tmp/lr-a.json /tmp/lr-b.json
