#!/usr/bin/env bash
# RHOAI itself, at exactly $RHOAI_CSV (PLAN.md §5). Adopts an install that's already on it.
cd "$(dirname "$0")/../.." && . lib/common.sh
NS=redhat-ods-operator

if [ "$(oc get csv "$RHOAI_CSV" -n $NS -o jsonpath='{.status.phase}' 2>/dev/null)" = Succeeded ]; then
  log "$RHOAI_CSV already installed, adopting it"
else
  log "installing $RHOAI_CSV (Manual approval: only the exact install plan is approved)"
  oc apply -f "$VERSION_DIR/manifests/rhoai-subscription.yaml" >/dev/null || die "apply RHOAI subscription"
  P=
  for i in $(seq 1 60); do
    P=$(oc get installplan -n $NS -o json | python3 -c "
import json,sys
for i in json.load(sys.stdin)['items']:
    if not i['spec']['approved'] and i['spec']['clusterServiceVersionNames']==['$RHOAI_CSV']: print(i['metadata']['name'])")
    [ -n "$P" ] && break
    [ "$(oc get csv "$RHOAI_CSV" -n $NS -o jsonpath='{.status.phase}' 2>/dev/null)" = Succeeded ] && break
    sleep 5
  done
  if [ -n "$P" ]; then oc patch installplan "$P" -n $NS --type merge -p '{"spec":{"approved":true}}' >/dev/null; log "approved install plan $P"; fi
  wait_sub $NS rhods-operator 900 || die "$RHOAI_CSV did not install"
fi

# Operand CRs: without them the LWS and JobSet CRDs never appear, and trainer stays not Ready.
oc apply -f "$VERSION_DIR/manifests/operator-operands.yaml" >/dev/null || die "apply operator operands"
for i in $(seq 1 30); do oc get crd leaderworkersets.leaderworkerset.x-k8s.io jobsets.jobset.x-k8s.io >/dev/null 2>&1 && break; sleep 10; done
oc get crd leaderworkersets.leaderworkerset.x-k8s.io jobsets.jobset.x-k8s.io >/dev/null 2>&1 || die "LWS or JobSet CRD missing"
log "phase 20 done"
