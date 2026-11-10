#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
date -u +%H:%M:%SZ
for ns in lr-team-07 lr-team-08 lr-team-09; do oc delete featurestore features -n $ns --wait=true --timeout=180s; done
for i in $(seq 1 18); do n=$(oc get pods -n lr-team-07 -n lr-team-08 --no-headers 2>/dev/null | grep -c 'feast-features-'); oc get deploy -A --no-headers 2>/dev/null | grep -q ' feast-features ' || break; sleep 10; done
echo "old deployments left: $(oc get deploy -A --no-headers | grep -c ' feast-features ')"
echo "shared binding after deleting all three stores: $(oc get clusterrolebinding feast-features-cluster-binding -o name 2>&1)"
oc delete clusterrolebinding feast-features-cluster-binding --ignore-not-found
oc apply --server-side -f generated/featurestores-unique.json
for i in $(seq 1 30); do r=$(oc get featurestore -A --no-headers -o custom-columns=P:.status.phase | grep -c Ready); [ "$r" = 3 ] && break; sleep 10; done
echo "Ready after $((i*10))s: $r of 3"
echo "--- watch status and bindings for 2 minutes"
for i in $(seq 1 8); do
  echo "$(date -u +%H:%M:%S) $(oc get featurestore -A --no-headers -o custom-columns=N:.metadata.name,P:.status.phase | tr -s ' ' | tr '\n' ' ')"
  sleep 15
done
oc get clusterrolebinding -o json | python3 -c "
import json,sys
for b in json.load(sys.stdin)['items']:
    if b['metadata']['name'].startswith('feast-') and 'cluster-binding' in b['metadata']['name']:
        print(' ',b['metadata']['name'],'->',[(s['namespace'],s['name']) for s in b.get('subjects',[])],'rv',b['metadata']['resourceVersion'])"
sleep 30
oc get clusterrolebinding -o json | python3 -c "
import json,sys
print('  resourceVersions 30s later:',[(b['metadata']['name'][-30:],b['metadata']['resourceVersion']) for b in json.load(sys.stdin)['items'] if b['metadata']['name'].startswith('feast-') and 'cluster-binding' in b['metadata']['name']])"
for ns in lr-team-07 lr-team-08 lr-team-09; do
  D=$(oc get deploy -n $ns -o name | grep feast | head -1)
  oc get featurestore -n $ns -o json | python3 -c "
import json,sys
for d in json.load(sys.stdin)['items']: print('  $ns',d['metadata']['name'],d['status'].get('phase'),[(c['type'],c['status']) for c in d['status'].get('conditions',[]) if c['status']!='True'])"
  S=$(oc get svc -n $ns -o name | grep feast | grep -i online | head -1)
  oc exec -n $ns $D -c online -- curl -sk -m 10 -o /dev/null -w "  $ns online /health http=%{http_code}\n" https://localhost:6566/health 2>/dev/null || oc exec -n $ns $D -c online -- curl -s -m 10 -o /dev/null -w "  $ns online /health http=%{http_code}\n" http://localhost:6566/health
done
P=$(oc get pods -n redhat-ods-applications -o name | grep 'feast-operator-controller-manager' | head -1)
oc logs -n redhat-ods-applications $P --since=60s 2>/dev/null | grep -c 'Successfully reconciled' | sed 's/^/operator reconciles in the last 60s: /'
