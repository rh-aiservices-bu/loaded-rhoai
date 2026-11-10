#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
N=openshift-operators; P=$(oc get pods -n $N -o name | grep kuadrant-operator-controller)
oc get $P -n $N -o json | python3 -c "
import json,sys
d=json.load(sys.stdin); c=d['status']['containerStatuses'][0]; print('restarts',c['restartCount'],'state',list(c['state'].keys()),c['lastState'].get('terminated',{}).get('reason'),c['lastState'].get('terminated',{}).get('exitCode'),c['lastState'].get('terminated',{}).get('finishedAt'))
s=d['spec']['containers'][0]; print('resources',s.get('resources')); print('liveness',s.get('livenessProbe')); print('readiness',s.get('readinessProbe',{}).get('initialDelaySeconds'))"
echo "--- previous log"; oc logs -n $N $P --previous --tail=300 2>/dev/null | grep -iE 'error|fatal|panic|timed out|sync|cache' | sed -E 's/"ts":[0-9.e+]*,?//' | cut -c1-210 | tail -10
oc logs -n $N $P --previous 2>/dev/null | wc -l | sed 's/^/previous log lines: /'
oc logs -n $N $P --previous --tail=3 2>/dev/null | cut -c1-200
echo "--- all restarted containers across the cluster"
oc get pods -A -o json | python3 -c "
import json,sys
rows=[]
for p in json.load(sys.stdin)['items']:
    for c in p['status'].get('containerStatuses',[]):
        if c['restartCount']>2:
            t=c.get('lastState',{}).get('terminated',{})
            rows.append((c['restartCount'],p['metadata']['namespace'],p['metadata']['name'][:48],c['name'][:24],t.get('reason'),t.get('finishedAt')))
for r in sorted(rows,reverse=True)[:25]: print(r)"
echo "--- memory of operators"; oc adm top pods -n $N --no-headers 2>/dev/null | cut -c1-80
oc adm top pods -n redhat-ods-applications --no-headers 2>/dev/null | sort -k3 -h -r | head -14 | cut -c1-85
echo "--- counts"; echo "secrets=$(oc get secrets -A --no-headers | wc -l) configmaps=$(oc get cm -A --no-headers | wc -l) services=$(oc get svc -A --no-headers | wc -l) ns=$(oc get ns --no-headers | wc -l)"
