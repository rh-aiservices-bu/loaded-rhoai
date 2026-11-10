#!/usr/bin/env bash
# Every remaining DSC component (PLAN.md §8), RHOAI alerting, and per-user MaaS metrics (§7 item 7).
cd "$(dirname "$0")/../.." && . lib/common.sh

log "remaining components, alerting, per-user metrics"
oc patch dsc default-dsc --type merge --patch-file "$VERSION_DIR/manifests/dsc-patch.json" >/dev/null || die "DSC patch"
oc patch dsci default-dsci --type merge -p '{"spec":{"monitoring":{"alerting":{}}}}' >/dev/null || die "DSCI alerting"
# Without captureUser the TelemetryPolicy has no user label and the per-user token panels stay empty.
oc patch maastenantconfig default-tenant -n models-as-a-service --type merge \
  -p '{"spec":{"telemetry":{"enabled":true,"metrics":{"captureUser":true,"captureGroup":true}}}}' >/dev/null || die "MaaSTenantConfig telemetry"

dsc_ready 900 || die "DSC not Ready"
oc get monitoring default-monitoring -o json | python3 -c "
import json,sys
bad=[c['type'] for c in json.load(sys.stdin)['status']['conditions'] if c['status']!='True']
print('  monitoring conditions not True:', bad or 'none')"
for i in $(seq 1 30); do
  labels=$(oc get telemetrypolicy maas-telemetry -n openshift-ingress -o jsonpath='{.spec.metrics.default.labels}' 2>/dev/null)
  echo "$labels" | grep -q '"user"' && break; sleep 10
done
echo "$labels" | grep -q '"user"' && log "TelemetryPolicy maas-telemetry has the user label" || warn "TelemetryPolicy maas-telemetry has no user label yet: $labels"
log "phase 35 done"
