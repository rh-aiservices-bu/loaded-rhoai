#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
date -u +%H:%M:%SZ
echo "--- rhbk"; oc get csv -n maas-keycloak --no-headers | grep rhbk | cut -c1-90; oc get installplan -n maas-keycloak -o json | python3 -c "
import json,sys
for i in json.load(sys.stdin)['items']: print(i['metadata']['name'],i['metadata']['creationTimestamp'],i['spec']['approved'],i['status'].get('phase'),i['spec']['clusterServiceVersionNames'])"
oc get sub rhbk-operator -n maas-keycloak -o jsonpath='sub {.spec.channel} installed={.status.installedCSV} current={.status.currentCSV}{"\n"}'
oc get pods -n maas-keycloak -o json | python3 -c "
import json,sys
for p in json.load(sys.stdin)['items']:
    print(p['metadata']['name'],p['metadata']['creationTimestamp'],[ (c['name'],c['restartCount'],(c.get('lastState',{}).get('terminated') or {}).get('reason')) for c in p['status'].get('containerStatuses',[])])"
oc get events -n maas-keycloak --sort-by=.lastTimestamp 2>/dev/null | tail -12 | cut -c1-170
oc get deploy rhbk-operator -n maas-keycloak -o jsonpath='gen={.metadata.generation} image={.spec.template.spec.containers[0].image}{"\n"}' | cut -c1-150
oc get statefulset keycloak -n maas-keycloak -o jsonpath='sts image={.spec.template.spec.containers[0].image} rev={.status.updateRevision}{"\n"}' | cut -c1-150
echo "--- any install plans created in the last 6 hours, cluster-wide"
oc get installplan -A -o json | python3 -c "
import json,sys,datetime
now=datetime.datetime.now(datetime.timezone.utc)
for i in json.load(sys.stdin)['items']:
    t=datetime.datetime.fromisoformat(i['metadata']['creationTimestamp'].replace('Z','+00:00'))
    if (now-t).total_seconds()<6*3600: print(i['metadata']['namespace'],i['metadata']['creationTimestamp'],i['spec']['approved'],i['status'].get('phase'),i['spec']['clusterServiceVersionNames'])"
echo "--- csvs"; oc get csv -A --no-headers | awk '{print $2,$(NF-1),$NF}' | sort -u | cut -c1-80
echo "--- catalog source"; oc get catalogsource -n openshift-marketplace --no-headers | cut -c1-80; oc get pods -n openshift-marketplace --no-headers | grep redhat-operators | cut -c1-70
echo "--- node events"; oc get events -A --field-selector reason=Rebooted 2>/dev/null | tail -3 | cut -c1-130; oc get nodes -o json | python3 -c "
import json,sys
for n in json.load(sys.stdin)['items']:
    r=[c for c in n['status']['conditions'] if c['type']=='Ready'][0]; print(n['metadata']['name'][:16],r['status'],r['lastTransitionTime'])"
