#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
oc get notebook -A -o json > /tmp/lr-nb.json
python3 - <<'PY'
import json,glob
gen={}
for f in glob.glob('generated/medium/shards/*.json'):
    for d in json.load(open(f))['items']:
        if d['kind']=='Notebook': gen[(d['metadata']['namespace'],d['metadata']['name'])]=d
its=json.load(open('/tmp/lr-nb.json'))['items']
wrong=[n for n in its if (n['metadata']['namespace'],n['metadata']['name']) in gen and 'kubeflow-resource-stopped' in gen[(n['metadata']['namespace'],n['metadata']['name'])]['metadata']['annotations'] and 'kubeflow-resource-stopped' not in n['metadata'].get('annotations',{})]
print('applied generated',sum(1 for n in its if (n['metadata']['namespace'],n['metadata']['name']) in gen),'should be stopped but are not',len(wrong))
n=wrong[0]; print(n['metadata']['namespace'],n['metadata']['name'],n['metadata']['creationTimestamp'],'gen',n['metadata'].get('generation'))
print('annotations',n['metadata']['annotations'])
for m in n['metadata']['managedFields']:
    print(m['manager'],m['operation'],m.get('time'),m.get('subresource',''),[k for k in m.get('fieldsV1',{}).get('f:metadata',{}).get('f:annotations',{}) if 'stop' in k or 'kubeflow' in k])
PY
rm -f /tmp/lr-nb.json
oc get mutatingwebhookconfiguration -o json | python3 -c "
import json,sys
for w in json.load(sys.stdin)['items']:
    for h in w['webhooks']:
        if any('notebooks' in r.get('resources',[]) for r in h.get('rules',[])): print('webhook',w['metadata']['name'],h['name'],h.get('reinvocationPolicy'))"
grep -n "kubeflow-resource-stopped" -r /Users/phayes/projects/loaded-rhoai/spike/*.yaml | head -3 | cut -c1-120
