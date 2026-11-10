#!/usr/bin/env bash
# MaaS models and Keycloak-group tiers (PLAN.md §7 items 5-6): three simulator LLMInferenceServices
# behind the MaaS gateway, and free/standard/premium subscriptions and auth policies on maas-* groups.
cd "$(dirname "$0")/../.." && . lib/common.sh

log "MaaS simulator models and tiers"
oc apply --server-side -f "$VERSION_DIR/manifests/maas-models-tiers.json" >/dev/null || die "apply MaaS models and tiers"
for i in $(seq 1 60); do
  nr=$(oc get llminferenceservice -n lr-models -o json | python3 -c "
import json,sys
print(sum(1 for o in json.load(sys.stdin)['items'] if not any(c['type']=='Ready' and c['status']=='True' for c in o.get('status',{}).get('conditions',[]))))")
  nm=$(oc get maasmodelref -n lr-models -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' | grep -vc Ready)
  [ "$nr" = 0 ] && [ "$nm" = 0 ] && break; sleep 10
done
oc get llminferenceservice,maasmodelref -n lr-models --no-headers | awk '{print "  "$1, $2, $3}'
[ "$nr" = 0 ] && [ "$nm" = 0 ] || die "MaaS models not Ready (LLMISVC not ready: $nr, model refs not Ready: $nm)"
oc get maassubscription -n models-as-a-service --no-headers | awk '{print "  subscription "$1, $2, "priority "$3}'
log "phase 55 done"
