#!/usr/bin/env bash
# Dependency operators, before RHOAI (PLAN.md §4 dependencyOperators, §8).
cd "$(dirname "$0")/../.." && . lib/common.sh
ensure_guide

# Once phase 90 has pinned the cluster, a re-run must not switch Subscriptions back to Automatic,
# or OLM could upgrade operators the moment this runs.
APPROVAL=Automatic
if [ -n "$(oc get sub -A -o jsonpath='{range .items[?(@.spec.installPlanApproval=="Manual")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -v '^rhods-operator$')" ]; then
  APPROVAL=Manual
  log "cluster is already pinned: keeping Manual approval"
fi
pin() { sed "s/installPlanApproval: Automatic/installPlanApproval: $APPROVAL/"; }

log "dependency operators"
pin < "$VERSION_DIR/manifests/operators.yaml" | oc apply -f - >/dev/null || die "apply operators.yaml"
for d in tempo opentelemetry coo; do
  oc kustomize "$GUIDE_DIR/manifests/07-observability/$d" | pin | oc apply -f - >/dev/null || die "apply guide observability $d"
done

ok=1
# Operators added to an already-pinned cluster wait for approval; approve exactly those.
[ "$APPROVAL" = Manual ] && { sleep 20; approve_plans openshift-operators mcp-gateway.; }
wait_sub openshift-operators rhcl-operator || ok=0
wait_sub openshift-operators mcp-gateway || ok=0
wait_sub openshift-lws-operator leader-worker-set || ok=0
wait_sub openshift-kueue-operator kueue-operator || ok=0
wait_sub openshift-jobset-operator job-set || ok=0
wait_sub openshift-keda openshift-custom-metrics-autoscaler-operator || ok=0
for s in $(oc get sub -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' | grep -E 'tempo|opentelemetry|observability'); do
  wait_sub "${s%%/*}" "${s#*/}" || ok=0
done
# RHCL pulls in Authorino, Limitador and the DNS operator as separate Subscriptions.
for s in authorino-operator limitador-operator dns-operator; do
  n=$(oc get sub -n openshift-operators -o jsonpath="{range .items[?(@.spec.name==\"$s\")]}{.metadata.name}{end}")
  [ -n "$n" ] && { wait_sub openshift-operators "$n" || ok=0; }
done
[ "$ok" = 1 ] || die "dependency operators did not all install"

kd=$(oc get deploy kuadrant-operator-controller-manager -n openshift-operators -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory} {.spec.template.spec.containers[0].env[?(@.name=="AUTH_SERVICE_TIMEOUT")].value}' 2>/dev/null)
log "kuadrant-operator memory limit and auth timeout: $kd"
log "phase 10 done"
