#!/usr/bin/env bash
# Settle (PLAN.md §6 "Healthy by construction"): pass only once the DSC is Ready and no RHOAI
# controller has restarted for 5 minutes in a row.
cd "$(dirname "$0")/../.." && . lib/common.sh
log "waiting for the cluster to settle"
bash tools/wait_stable.sh || die "cluster did not settle"
log "phase 65 done"
