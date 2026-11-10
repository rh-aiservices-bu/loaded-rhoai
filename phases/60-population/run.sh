#!/usr/bin/env bash
# The lived-in population (PLAN.md §6): MinIO, buckets, pre-pulled workbench images, then the
# generated shards one at a time, stopping workbenches after each so they never all start at once.
cd "$(dirname "$0")/../.." && . lib/common.sh
P="$GEN_DIR/$POP"
[ -d "$P/shards" ] || die "no $P/shards; run phase 45 first"

log "MinIO for connections, pipelines and models"
oc apply -f manifests/infra/minio.yaml >/dev/null || die "MinIO"
oc wait deploy/minio -n lr-infra --for=condition=Available --timeout=300s >/dev/null || die "MinIO not Available"
B=$(python3 -c "import json,sys;print(' '.join(json.load(open(sys.argv[1]))+['lr-models']))" "$P/buckets.json")
oc exec -n lr-infra deploy/minio -- sh -c "mc alias set l http://localhost:9000 lrminio lrminio-spike-only >/dev/null; for b in $B; do mc mb -p l/\$b >/dev/null; done; mc ls l | wc -l" | sed 's/^/  buckets: /'

log "pre-pulling workbench images on every worker"
bash tools/prepull.sh "$GEN_DIR/notebook-images.json"

log "applying $POP shards one at a time"
STAGGER=1 bash tools/apply_shards.sh "$POP" 0 999 || warn "some objects failed to apply; re-running phase 60 is safe and usually clears them"
log "stopping the workbenches that should be stopped (3.5.2 strips the stop annotation at create)"
python3 tools/stop_notebooks.py "$POP" | tail -2 || die "workbenches did not stay stopped"
log "phase 60 done"
