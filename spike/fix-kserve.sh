#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
A=redhat-ods-applications
D=kserve-module-controller-manager
C=$(oc get deploy $D -n $A -o jsonpath='{.spec.template.spec.containers[0].name}')
oc annotate deploy $D -n $A opendatahub.io/managed=false --overwrite
oc patch deploy $D -n $A --type strategic -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$C\",\"resources\":{\"limits\":{\"cpu\":\"2\",\"memory\":\"3Gi\"},\"requests\":{\"cpu\":\"200m\",\"memory\":\"1Gi\"}}}]}}}}"
oc rollout status deploy/$D -n $A --timeout=180s | tail -1
oc rollout restart deploy/ai-gateway-operator -n $A; oc rollout status deploy/ai-gateway-operator -n $A --timeout=180s | tail -1
for i in $(seq 1 12); do r=$(oc get dsc default-dsc -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'); [ "$r" = True ] && break; sleep 10; done
date -u +%H:%M:%SZ; echo "dsc ready=$r after $((i*10))s"
oc get dsc default-dsc -o json | python3 -c "
import json,sys
print('not true:',[(c['type'],c.get('reason')) for c in json.load(sys.stdin)['status']['conditions'] if c['status']!='True' and c.get('reason')!='Removed'])"
echo "--- memory vs limit, highest first"
oc adm top pods -A --no-headers 2>/dev/null > /tmp/lr-top.txt
oc get pods -A -o json | python3 -c "
import json,sys,re
def mi(v):
    m=re.match(r'([0-9.]+)(Ki|Mi|Gi)?',v); n=float(m[1]); return n*{'Ki':1/1024,'Mi':1,'Gi':1024,None:1/1048576}[m[2]]
lim={}
for p in json.load(sys.stdin)['items']:
    t=sum(mi(c['resources']['limits']['memory']) for c in p['spec']['containers'] if c.get('resources',{}).get('limits',{}).get('memory'))
    if len(p['spec']['containers'])==1 and t: lim[(p['metadata']['namespace'],p['metadata']['name'])]=t
rows=[]
for l in open('/tmp/lr-top.txt'):
    ns,n,cpu,mem=l.split()[:4]
    if (ns,n) in lim:
        rows.append((mi(mem)/lim[(ns,n)],int(mi(mem)),int(lim[(ns,n)]),ns,n[:48]))
for r in sorted(rows,reverse=True)[:12]: print(f'{r[0]*100:4.0f}% {r[1]:5}Mi/{r[2]:5}Mi {r[3]} {r[4]}')"
rm -f /tmp/lr-top.txt
