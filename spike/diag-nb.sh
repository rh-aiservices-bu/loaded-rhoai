#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
python3 - <<'PY'
import json,glob
stopped=run=0; sample=None
for f in glob.glob('generated/medium/shards/*.json'):
    for d in json.load(open(f))['items']:
        if d['kind']=='Notebook':
            a=d['metadata']['annotations']
            if 'kubeflow-resource-stopped' in a: stopped+=1; sample=sample or (d['metadata']['namespace'],d['metadata']['name'],a['kubeflow-resource-stopped'])
            else: run+=1
print('generated stopped',stopped,'running',run,'sample',sample)
json.dump(sample,open('/tmp/lr-s','w'))
PY
read NS N < <(python3 -c "import json;s=json.load(open('/tmp/lr-s'));print(s[0],s[1])"); rm -f /tmp/lr-s
echo "sample on cluster: $NS/$N"; oc get notebook $N -n $NS -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin);print(d['metadata']['annotations']);print([ (m['manager'],m['operation']) for m in d['metadata']['managedFields']])"
oc get notebook -A -o json | python3 -c "
import json,sys
its=json.load(sys.stdin)['items']
print('on cluster: total',len(its),'with stop annotation',sum(1 for n in its if 'kubeflow-resource-stopped' in n['metadata'].get('annotations',{})))
from collections import Counter
print(Counter(n['metadata'].get('annotations',{}).get('kubeflow-resource-stopped','none')[:7] for n in its))"
echo "--- which notebooks should be running"; python3 - <<'PY'
import json
inv=json.load(open('generated/medium/expected-inventory.json'))
print('inventory',[(o['state']) for o in inv if o['kind']=='Notebook'].count('running'),'running')
PY
