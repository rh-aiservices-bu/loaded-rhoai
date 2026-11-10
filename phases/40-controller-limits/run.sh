#!/usr/bin/env bash
# Raise RHOAI controller memory limits measured at ~355 projects (PLAN.md §4 controllerResources).
# This needs opendatahub.io/managed=false on each Deployment, which an upgrade test must handle
# (PLAN.md §17 item 22). RHCL's limits are set on its Subscription in phase 10.
cd "$(dirname "$0")/../.." && . lib/common.sh

log "controller memory limits"
for spec in $CONTROLLER_LIMITS; do
  D=${spec%%:*}; M=${spec#*:}
  oc get deploy "$D" -n $APPS >/dev/null 2>&1 || { warn "no deployment $D"; continue; }
  C=$(oc get deploy "$D" -n $APPS -o jsonpath='{.spec.template.spec.containers[0].name}')
  cur=$(oc get deploy "$D" -n $APPS -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}')
  [ "$cur" = "$M" ] && { echo "  $D already $M"; continue; }
  oc annotate deploy "$D" -n $APPS opendatahub.io/managed=false --overwrite >/dev/null
  oc patch deploy "$D" -n $APPS --type strategic -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$C\",\"resources\":{\"limits\":{\"cpu\":\"2\",\"memory\":\"$M\"},\"requests\":{\"cpu\":\"200m\",\"memory\":\"512Mi\"}}}]}}}}" >/dev/null \
    && echo "  $D ${cur:-unset} -> $M" || warn "could not patch $D"
done
sleep 60
dsc_ready 600 || die "DSC not Ready after raising limits"
log "phase 40 done"
