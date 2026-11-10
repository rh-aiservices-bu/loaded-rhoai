#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
echo "--- TrustyAIService instances"; oc get trustyaiservice -A --no-headers 2>&1
for ns in $(oc get trustyaiservice -A --no-headers -o custom-columns=N:.metadata.namespace); do
  echo "=== $ns"
  oc get pods -n $ns --no-headers | grep trustyai | cut -c1-80
  P=$(oc get pods -n $ns -o name | grep trustyai | head -1)
  oc get $P -n $ns -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
for c in d['spec']['containers']:
    print(' container',c['name'],[ (m['mountPath'],m.get('subPath'),m['name']) for m in c.get('volumeMounts',[]) if 'ca' in m['name'] or 'cert' in m['mountPath']])
for v in d['spec']['volumes']:
    if 'ca' in v['name']: print(' volume',v['name'],v.get('configMap'))"
  echo " configmap odh-trusted-ca-bundle:"; oc get cm odh-trusted-ca-bundle -n $ns -o json 2>&1 | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin); print('   keys',{k:len(v) for k,v in d.get('data',{}).items()},'labels',{k:v for k,v in d['metadata'].get('labels',{}).items() if 'inject' in k or 'managed' in k},'created',d['metadata']['creationTimestamp'])
except Exception as e: print('   missing or unreadable')"
done
echo "--- across all dashboard namespaces: does odh-trusted-ca-bundle have ca-bundle.crt?"
oc get cm -A --field-selector metadata.name=odh-trusted-ca-bundle -o json | python3 -c "
import json,sys,collections
c=collections.Counter(); empty=[]
for d in json.load(sys.stdin)['items']:
    k=d.get('data',{}); has='ca-bundle.crt' in k and len(k['ca-bundle.crt'])>0
    c['has ca-bundle.crt' if has else 'MISSING or empty']+=1
    if not has: empty.append(d['metadata']['namespace'])
print(dict(c)); print('missing in (first 15):',empty[:15])"
echo "--- dsci trusted CA"; oc get dsci default-dsci -o jsonpath='{.spec.trustedCABundle}{"\n"}'
oc get cm -n openshift-config-managed trusted-ca-bundle -o jsonpath='{.data.ca-bundle\.crt}' 2>/dev/null | wc -c | sed 's/^/cluster trusted-ca-bundle bytes: /'
oc get proxy cluster -o jsonpath='proxy trustedCA={.spec.trustedCA.name}{"\n"}'
oc logs -n openshift-network-operator deploy/network-operator --since=6h 2>/dev/null | grep -icE 'trusted-ca|inject' | sed 's/^/network-operator log lines about injection: /'
