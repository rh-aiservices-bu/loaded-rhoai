#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
python3 - <<'PY'
import json,glob,copy
for f in sorted(glob.glob('generated/medium/shards/*.json')):
    for d in json.load(open(f))['items']:
        if d['kind']=='Notebook' and d['metadata']['name']=='wb-0000':
            for tag,val in (('oct','2026-10-02T09:00:00Z'),('nov','2026-11-01T09:00:00Z')):
                e=copy.deepcopy(d); n='wbtest-'+tag; e['metadata']['name']=n; e['metadata']['namespace']='lr-smoke'; e['metadata']['annotations']['kubeflow-resource-stopped']=val
                e['metadata']['labels']['app']=n
                c=e['spec']['template']['spec']['containers'][0]; c['name']=n; c['volumeMounts']=[]; e['spec']['template']['spec']['volumes']=[]
                json.dump(e,open(f'/tmp/lr-{tag}.json','w'))
PY
for t in oct nov; do oc apply --server-side --force-conflicts -f /tmp/lr-$t.json 2>&1 | cut -c1-200; done
sleep 8
for t in oct nov; do oc get notebook wbtest-$t -n lr-smoke -o json | python3 -c "
import json,sys
d=json.load(sys.stdin);print(d['metadata']['name'],'stop=',d['metadata']['annotations'].get('kubeflow-resource-stopped'),'gen',d['metadata'].get('generation'))"; oc get statefulset wbtest-$t -n lr-smoke -o jsonpath='  sts replicas={.spec.replicas}{"\n"}' 2>&1; done
oc logs -n redhat-ods-applications deploy/odh-notebook-controller-manager --since=2m 2>/dev/null | grep wbtest | grep -iE 'stop|annot|restart' | tail -4 | cut -c1-220
oc delete notebook wbtest-oct wbtest-nov -n lr-smoke; rm -f /tmp/lr-oct.json /tmp/lr-nov.json
echo "--- was the applied shard identical to what is on disk?"; ls -la --time-style=+%H:%M generated/medium/shards/001.json 2>/dev/null || stat -f '%Sm %N' generated/medium/shards/001.json
grep -c 'serverside-applied' logs/apply-medium-0-3.log; stat -f '%Sm %N' logs/apply-medium-0-3.log; date -u
