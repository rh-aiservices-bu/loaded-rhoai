#!/usr/bin/env bash
# maaspal (PLAN.md §11), installed headless. It is NOT registered with the dashboard: maaspal's
# README registers it with `oc set env MODULE_FEDERATION_CONFIG=...`, but on 3.5.2 that variable
# comes from the operator-owned federation-config ConfigMap, and overwriting it removed the 11
# shipped dashboard modules. Runs go through its BFF API (tools/maaspal_run.py).
cd "$(dirname "$0")/../.." && . lib/common.sh
NS=cp-maaspal

log "maaspal $MAASPAL_VERSION"
helm upgrade --install maaspal "$MAASPAL_CHART" --version "$MAASPAL_VERSION" -n $NS --create-namespace \
  --set 'access.groups[0]=rhoai-admins' --set rbac.userProvisioning=true > "$LOG_DIR/maaspal-helm.log" 2>&1 \
  || { tail -10 "$LOG_DIR/maaspal-helm.log"; die "helm install maaspal"; }
oc label namespace $NS maas.opendatahub.io/gateway-access=true loaded-rhoai.io/managed=true --overwrite >/dev/null
for d in $(oc get deploy -n $NS -o name); do oc rollout status "$d" -n $NS --timeout=300s >/dev/null || die "$d not available"; done
oc get pods -n $NS --no-headers | awk '{print "  "$1, $2, $3}'
log "phase 70 done (run scenarios with ./loaded-rhoai.sh maaspal <plan.json>)"
