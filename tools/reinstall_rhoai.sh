#!/usr/bin/env bash
# Move RHOAI to a release that has no OLM upgrade edge from the installed one, by reinstalling the
# operator. Deleting the Subscription and CSV leaves the DSC, DSCI, CRDs and every workload in place.
# Applies no post-upgrade fixes: the point is to see what the new release does to an existing cluster.
# Run from the repo root.
#
# Usage: tools/reinstall_rhoai.sh [--catalog <fbc-image>] <channel> <csv-prefix>
#   From the stock catalog (e.g. 3.6 EA on the beta channel):
#     tools/reinstall_rhoai.sh beta rhods-operator.3.6
#   From an FBC fragment image (e.g. a 3.6 release candidate), channel/CSV discovered from it:
#     tools/reinstall_rhoai.sh --catalog quay.io/rhoai/rhoai-fbc-fragment@sha256:<digest> auto auto
#   `auto` channel = the package's default channel in that catalog; `auto` csv-prefix = that channel's head.
set -uo pipefail
. lib/common.sh
CATALOG=""
if [ "${1:-}" = "--catalog" ]; then CATALOG=$2; shift 2; fi
CH=$1; WANT=$2; NS=redhat-ods-operator
CATSRC=lr-rhoai-fbc; MKT=openshift-marketplace
OUT="$GEN_DIR/upgrade-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"

# Stand up an FBC fragment as a CatalogSource and discover the rhods-operator channel/CSV it serves.
# The fragment carries only rhods-operator; its dependencies still resolve from redhat-operators.
if [ -n "$CATALOG" ]; then
  # A private catalog image needs a pull secret on the catalog pod. CATALOG_PULL_SECRET names a
  # dockerconfigjson secret in openshift-marketplace; CatalogSource.spec.secrets attaches it. Only
  # the catalog image needs this: for RHOAI the bundle and operand images are on registry.redhat.io,
  # which the cluster's global pull secret already covers, so no node change or reboot.
  secrets_line=""
  [ -n "${CATALOG_PULL_SECRET:-}" ] && secrets_line="  secrets: [$CATALOG_PULL_SECRET]"
  log "creating CatalogSource $CATSRC from $CATALOG${CATALOG_PULL_SECRET:+ (pull secret $CATALOG_PULL_SECRET)}"
  cat <<EOF | oc apply -f - || die "apply CatalogSource"
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata: {name: $CATSRC, namespace: $MKT, labels: {loaded-rhoai.io/managed: "true"}}
spec:
  sourceType: grpc
  image: $CATALOG
  displayName: RHOAI FBC (loaded-rhoai)
  publisher: loaded-rhoai
$secrets_line
  updateStrategy: {registryPoll: {interval: 30m}}
EOF
  # CatalogSource.spec.secrets covers bundle resolution, but the catalog POD pulls its own image via
  # its service account (named after the CatalogSource). Link the secret there too, with retries since
  # OLM creates the SA after the CatalogSource. Then restart the pod so it pulls with the secret.
  if [ -n "${CATALOG_PULL_SECRET:-}" ]; then
    for i in $(seq 1 18); do
      oc get sa "$CATSRC" -n $MKT >/dev/null 2>&1 && break; sleep 5
    done
    oc secrets link "$CATSRC" "$CATALOG_PULL_SECRET" --for=pull -n $MKT 2>/dev/null \
      || oc secrets link default "$CATALOG_PULL_SECRET" --for=pull -n $MKT 2>/dev/null
  fi
  oc delete pod -n $MKT -l olm.catalogSource=$CATSRC --ignore-not-found >/dev/null 2>&1
  for i in $(seq 1 60); do
    st=$(oc get catalogsource $CATSRC -n $MKT -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null)
    echo "  [$i] CatalogSource state=$st"
    [ "$st" = READY ] && break; sleep 10
  done
  [ "$st" = READY ] || die "CatalogSource $CATSRC not READY (check the image pulls and serves a catalog)"
  # The package manifest from this catalog carries label catalog=<name>.
  for i in $(seq 1 30); do
    pm=$(oc get packagemanifest -n $MKT -l "catalog=$CATSRC" -o jsonpath='{range .items[?(@.status.packageName=="rhods-operator")]}{.metadata.name}{end}' 2>/dev/null)
    [ -n "$pm" ] && break; sleep 10
  done
  [ -n "$pm" ] || die "no rhods-operator package in catalog $CATSRC"
  defch=$(oc get packagemanifest -n $MKT "$pm" -o jsonpath='{.status.defaultChannel}' 2>/dev/null)
  [ "$CH" = auto ] && CH=$defch
  head=$(oc get packagemanifest -n $MKT "$pm" -o jsonpath="{.status.channels[?(@.name==\"$CH\")].currentCSV}" 2>/dev/null)
  [ "$WANT" = auto ] && WANT=$head
  log "catalog $CATSRC serves rhods-operator: default channel=$defch, using channel=$CH, head CSV=$head"
  oc get packagemanifest -n $MKT "$pm" -o jsonpath='{range .status.channels[*]}  channel {.name} -> {.currentCSV}{"\n"}{end}'
  [ -n "$CH" ] && [ -n "$WANT" ] || die "could not resolve channel/CSV from the catalog (channel=$CH csv=$WANT)"
  SRC_OVERRIDE=$CATSRC; SRCNS_OVERRIDE=$MKT
fi

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
# An FBC catalog overrides the source; dependency operators keep resolving from their own catalogs.
[ -n "${SRC_OVERRIDE:-}" ] && { SRC=$SRC_OVERRIDE; SRCNS=$SRCNS_OVERRIDE; echo "$CATALOG" > "$OUT/fbc-image.txt"; }
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
# Bundle unpack can take several minutes (FBC resolution + large bundle), and the install plan only
# appears afterwards, so wait up to ~18 min.
for i in $(seq 1 108); do
  approve_plans $NS "$WANT"
  NEW=$(oc get sub rhods-operator -n $NS -o jsonpath='{.status.installedCSV}')
  [ -n "$NEW" ] && break
  [ $((i % 6)) = 0 ] && log "  still waiting for a $WANT* install plan ($(oc get sub rhods-operator -n $NS -o jsonpath='{.status.conditions[?(@.type=="BundleUnpacking")].reason}' 2>/dev/null))"
  sleep 10
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
