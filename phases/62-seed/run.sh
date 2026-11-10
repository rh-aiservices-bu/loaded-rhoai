#!/usr/bin/env bash
# Seed data that lives behind APIs rather than in Kubernetes objects (PLAN.md §6):
# MLflow experiments and runs per team workspace. Idempotent.
cd "$(dirname "$0")/../.." && . lib/common.sh
S="$GEN_DIR/$POP/seed.json"
[ -f "$S" ] || die "no $S; run phase 45 first"

log "MLflow experiments and runs"
PLAN=$(python3 -c "import json,sys;print(json.dumps(json.load(open(sys.argv[1]))['mlflow']))" "$S")
for i in $(seq 1 30); do
  [ "$(oc get mlflow mlflow -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)" = True ] && break; sleep 10
done
out=$(in_cluster tools/seed_mlflow.py PLAN="$PLAN") || die "MLflow seeding failed: $out"
echo "$out" | sed 's/^/  /'
echo "$out" | grep -q 'errors=0' || die "MLflow seeding had errors"
log "phase 62 done"
