#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
oc get pods -A -o json > /tmp/lr-pods.json; oc get nodes -o json > /tmp/lr-nodes.json; oc get pv -o json > /tmp/lr-pv.json
python3 - <<'PY'
import json,collections
pods=json.load(open('/tmp/lr-pods.json'))['items']; nodes=json.load(open('/tmp/lr-nodes.json'))['items']; pvs=json.load(open('/tmp/lr-pv.json'))['items']
def cpu(v): return float(v[:-1])/1000 if v.endswith('m') else float(v)
def mem(v):
    for s,m in (('Ki',1/2**20),('Mi',1/1024),('Gi',1),('Ti',1024),('M',1/1024),('G',1)):
        if v.endswith(s): return float(v[:-len(s)])*m
    return float(v)/2**30
info={}
for n in nodes:
    l=n['metadata']['labels']; a=n['status']['allocatable']
    info[n['metadata']['name']]=dict(cp='node-role.kubernetes.io/control-plane' in l,zone=l['topology.kubernetes.io/zone'],cpu=cpu(a['cpu']),mem=mem(a['memory']),rc=0,rm=0,count=0,ns=collections.Counter(),big=[])
sys_pref=('openshift-','kube-')
moved=collections.Counter(); moved_c=moved_m=0; pvc_zone=collections.Counter()
for p in pods:
    if p['status'].get('phase') not in ('Running','Pending'): continue
    n=p['spec'].get('nodeName')
    if n not in info: continue
    c=sum(cpu(x.get('resources',{}).get('requests',{}).get('cpu','0')) for x in p['spec']['containers'])
    m=sum(mem(x.get('resources',{}).get('requests',{}).get('memory','0')) for x in p['spec']['containers'])
    i=info[n]; ns=p['metadata']['namespace']; i['rc']+=c; i['rm']+=m; i['count']+=1; i['ns'][ns]+=1
    if i['cp'] and not ns.startswith(sys_pref): moved[ns]+=1; moved_c+=c; moved_m+=m
for n,i in sorted(info.items()):
    print(f"{n[:18]} {'CP' if i['cp'] else 'W '} {i['zone']} pods={i['count']} req cpu={i['rc']:.1f}/{i['cpu']:.0f} mem={i['rm']:.0f}/{i['mem']:.0f}Gi nonsys={sum(v for k,v in i['ns'].items() if not k.startswith(sys_pref))}")
    print('    top:',i['ns'].most_common(6))
wk=[i for i in info.values() if not i['cp']]
print('pods to move off control plane:',sum(moved.values()),'requests cpu',round(moved_c,1),'mem',round(moved_m),'Gi')
print('worker free now: cpu',round(sum(i['cpu']-i['rc'] for i in wk),1),'mem',round(sum(i['mem']-i['rm'] for i in wk)),'Gi; pods free',sum(250-i['count'] for i in wk))
print('namespaces moving:',moved.most_common(14))
z=collections.Counter()
for v in pvs:
    t=v['spec'].get('nodeAffinity',{}).get('required',{}).get('nodeSelectorTerms',[{}])[0].get('matchExpressions',[{}])
    for e in t:
        if 'zone' in e.get('key',''): z[e['values'][0]]+=1
print('bound EBS volumes per zone:',dict(z))
PY
rm -f /tmp/lr-pods.json /tmp/lr-nodes.json /tmp/lr-pv.json
oc get schedulers.config.openshift.io cluster -o jsonpath='mastersSchedulable={.spec.mastersSchedulable}{"\n"}'
oc get machineset -n openshift-machine-api --no-headers | cut -c1-70
oc debug node/ip-10-0-58-127.us-east-2.compute.internal --quiet -- chroot /host sh -c 'lsblk -d -o NAME,SIZE,ROTA | head -4; df -h /var/lib/etcd /var/lib/containers 2>/dev/null | tail -2; iostat -dx 3 2 2>/dev/null | tail -4 | cut -c1-100' 2>&1 | tail -10
