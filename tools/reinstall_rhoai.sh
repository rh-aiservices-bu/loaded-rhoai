#!/usr/bin/env bash
# Move RHOAI to a release that has no OLM upgrade edge from the installed one, e.g. 3.5.x -> 3.6 EA
# on the `beta` channel, by reinstalling the operator. Deleting the Subscription and CSV leaves the
# DSC, DSCI, CRDs and every workload in place. Applies no post-upgrade fixes: the point is to see
# what the new release does to an existing cluster. Run from the repo root.
# Usage: tools/reinstall_rhoai.sh <channel> <csv-prefix>     e.g. beta rhods-operator.3.6
set -uo pipefail
. lib/common.sh
CH=$1; WANT=$2; NS=redhat-ods-operator
OUT="$GEN_DIR/upgrade-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"

lg() {  # load generator request counts by status code, to measure disruption
  P=$(oc get pods -n loaded-rhoai-load -l app=loadgen -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -n "$P" ] && oc exec -n loaded-rhoai-load "$P" -- python3 -c "
import urllib.request,re,collections,json
c=collections.Counter()
for l in urllib.request.urlopen('http://localhost:9100/metrics').read().decode().splitlines():
    if l.startswith('loadgen_requests_total'): c[dict(re.findall(r'(\w+)=\"([^\"]*)\"',l))['code']]+=float(l.split()[-1])
print(json.dumps({k:int(v) for k,v in c.items()}))"
}

OLD=$(oc get sub rhods-operator -n $NS -o jsonpath='{.status.installedCSV}')
[ -n "$OLD" ] || die "no installed RHOAI CSV found on the Subscription; not touching anything"
log "saving the current state to $OUT"
oc get sub rhods-operator -n $NS -o yaml > "$OUT/sub-before.yaml" && [ -s "$OUT/sub-before.yaml" ] || die "could not save the Subscription"
oc get dsc default-dsc -o yaml > "$OUT/dsc-before.yaml"
oc get dsci default-dsci -o yaml > "$OUT/dsci-before.yaml"
oc get csv -A -o custom-columns=NS:.metadata.namespace,CSV:.metadata.name,PHASE:.status.phase --no-headers | sort -u -k2 > "$OUT/csvs-before.txt"
SRC=$(oc get sub rhods-operator -n $NS -o jsonpath='{.spec.source}'); SRCNS=$(oc get sub rhods-operator -n $NS -o jsonpath='{.spec.sourceNamespace}')
CONFIG=$(oc get sub rhods-operator -n $NS -o jsonpath='{.spec.config}')
lg > "$OUT/loadgen-before.json"; date -u +%s > "$OUT/start-epoch"
log "load generator before: $(cat "$OUT/loadgen-before.json")"

log "removing $OLD (Subscription and CSV only)"
oc delete sub rhods-operator -n $NS || die "delete Subscription"
oc delete csv "$OLD" -n $NS --ignore-not-found || die "delete CSV"
for i in $(seq 1 30); do oc get csv "$OLD" -n $NS >/dev/null 2>&1 || break; sleep 5; done
oc get csv "$OLD" -n $NS >/dev/null 2>&1 && die "$OLD is still present"

log "subscribing to $CH (Manual approval; only a $WANT* plan is approved)"
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata: {name: rhods-operator, namespace: $NS}
spec: {channel: $CH, name: rhods-operator, source: ${SRC:-redhat-operators}, sourceNamespace: ${SRCNS:-openshift-marketplace}, installPlanApproval: Manual}
EOF
[ -n "$CONFIG" ] && warn "the old Subscription had spec.config ($CONFIG); it was not carried over"
for i in $(seq 1 30); do
  approve_plans $NS "$WANT"
  NEW=$(oc get sub rhods-operator -n $NS -o jsonpath='{.status.installedCSV}')
  [ -n "$NEW" ] && break; sleep 10
done
[ -n "$NEW" ] || die "no $WANT* install plan appeared; check: oc get sub,installplan -n $NS"
case "$NEW" in "$WANT"*) ;; *) die "installed $NEW, not $WANT*";; esac
wait_sub $NS rhods-operator 1200 || die "$NEW did not reach Succeeded"
log "installed $NEW"

log "waiting up to 20 minutes for the DSC (no fixes are applied)"
for i in $(seq 1 120); do
  r=$(oc get dsc default-dsc -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  [ "$r" = True ] && break; sleep 10
done
log "DSC Ready=$r"
oc get dsc default-dsc -o json | python3 -c "
import json,sys
for c in json.load(sys.stdin)['status']['conditions']:
    if c['status']!='True' and c.get('reason')!='Removed': print('  ',c['type'],c.get('reason'),(c.get('message') or '')[:200])" | tee "$OUT/dsc-conditions-after.txt"
lg > "$OUT/loadgen-after.json"
log "load generator after: $(cat "$OUT/loadgen-after.json")"
oc get csv -A -o custom-columns=NS:.metadata.namespace,CSV:.metadata.name,PHASE:.status.phase --no-headers | sort -u -k2 > "$OUT/csvs-after.txt"
log "done; state saved in $OUT. Next: ./loaded-rhoai.sh validate"
