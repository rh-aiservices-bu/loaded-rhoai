#!/usr/bin/env bash
# Gen AI playgrounds (PLAN.md §6), created by team members through the dashboard's gen-ai API.
# Needs identity (50) and MaaS tiers (55). Idempotent: existing playgrounds are left alone.
cd "$(dirname "$0")/../.." && . lib/common.sh
S="$GEN_DIR/$POP/seed.json"
[ -f "$S" ] || die "no $S; run phase 45 first"
log "Gen AI playgrounds"
python3 tools/playgrounds.py "$(domain)" "$GEN_DIR/$POP/users.json" "$S" || die "playgrounds"
log "phase 63 done"
