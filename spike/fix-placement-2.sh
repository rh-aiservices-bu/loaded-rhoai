#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
for i in $(seq 1 30); do s=$(oc get node ip-10-0-66-2.us-east-2.compute.internal --no-headers | awk '{print $2}'); [ "$s" = Ready ] && break; sleep 10; done; echo "new node: $s"
oc patch schedulers.config.openshift.io cluster --type merge -p '{"spec":{"mastersSchedulable":false}}'
for i in $(seq 1 18); do w=$(oc get nodes -l node-role.kubernetes.io/control-plane,node-role.kubernetes.io/worker --no-headers 2>/dev/null | wc -l | tr -d ' '); [ "$w" = 0 ] && break; sleep 10; done; echo "control-plane nodes still labelled worker: $w"
oc get nodes --no-headers | cut -c1-80
list() { oc get pods -A -o json | python3 -c "
import json,sys
CP=set('''ip-10-0-13-89.us-east-2.compute.internal ip-10-0-58-127.us-east-2.compute.internal ip-10-0-89-53.us-east-2.compute.internal'''.split())
MOVE={'openshift-operators','openshift-keda','openshift-kueue-operator','openshift-lws-operator','openshift-jobset-operator','openshift-tempo-operator','openshift-opentelemetry-operator','openshift-cluster-observability-operator','openshift-logging'}
for p in json.load(sys.stdin)['items']:
    ns=p['metadata']['namespace']; o=p['metadata'].get('ownerReferences',[{}])
    if p['spec'].get('nodeName') not in CP or o[0].get('kind') in ('DaemonSet','Node') or p['status'].get('phase') in ('Succeeded','Failed'): continue
    if ns.startswith(('openshift-','kube-')) and ns not in MOVE: continue
    if ns in ('keycloak',): pass
    print(ns,p['metadata']['name'])"; }
list > logs/cp-pods-to-move.txt; echo "to move: $(wc -l < logs/cp-pods-to-move.txt)"
awk '{print $1}' logs/cp-pods-to-move.txt | sort | uniq -c | sort -rn | head -30 | awk '{printf "%s(%s) ",$2,$1} END{print ""}' | cut -c1-500
n=0; while read -r ns pod; do
  oc delete pod "$pod" -n "$ns" --wait=false >/dev/null 2>&1; n=$((n+1))
  if [ $((n%6)) = 0 ]; then sleep 25; fi
done < logs/cp-pods-to-move.txt
echo "deleted $n"; date -u +%H:%M:%SZ
