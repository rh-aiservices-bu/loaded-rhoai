#!/usr/bin/env bash
# Continuous per-user MaaS load (PLAN.md §9): 60 active users at tier rates, plus two free-tier
# power users who are expected to hit 429s. Each logs in to Keycloak and mints their own API key.
cd "$(dirname "$0")/../.." && . lib/common.sh
USERS="$GEN_DIR/$POP/users.json"
[ -f "$USERS" ] || die "no $USERS; run phase 45 first"

python3 tools/select_load_users.py "$USERS" "$GEN_DIR/load-users.json" "$GEN_DIR/power-users.txt" "$SEED" || die "select load users"
POWER=$(cat "$GEN_DIR/power-users.txt")
DOMAIN=$(domain)

log "load generator (rate scale $RATE_SCALE, power users $POWER)"
sed -e "s|__LOADGEN_IMAGE__|$LOADGEN_IMAGE|" -e "s|__DOMAIN__|$DOMAIN|g" -e "s|__RATE_SCALE__|$RATE_SCALE|" -e "s|__POWER_USERS__|$POWER|" \
  manifests/load/loadgen.yaml > "$GEN_DIR/loadgen.yaml"
oc apply -f "$GEN_DIR/loadgen.yaml" --dry-run=client >/dev/null || die "loadgen manifest"
oc create namespace loaded-rhoai-load --dry-run=client -o yaml | oc apply -f - >/dev/null
oc create secret generic loadgen-users -n loaded-rhoai-load --from-file=users.json="$GEN_DIR/load-users.json" --dry-run=client -o yaml | oc apply -f - >/dev/null
oc create configmap loadgen-script -n loaded-rhoai-load --from-file=loadgen.py=loadgen/loadgen.py --dry-run=client -o yaml | oc apply -f - >/dev/null
oc apply -f "$GEN_DIR/loadgen.yaml" >/dev/null || die "apply loadgen"
oc rollout restart deploy/loadgen -n loaded-rhoai-load >/dev/null   # pick up a changed script or user list
oc rollout status deploy/loadgen -n loaded-rhoai-load --timeout=300s >/dev/null || die "loadgen not available"
date +%s > "$GEN_DIR/loadgen-start-epoch"
log "phase 68 done (users log in over the first 30 s; usage check: ./loaded-rhoai.sh load usage)"
