#!/usr/bin/env bash
# Validate the cluster (PLAN.md §10): platform, inventory and per-kind status, functional probes,
# startability, identity, load, variant effect probes, and the upgrade comparison when RHOAI has
# changed since the last passing run. Extra arguments go to the validator, e.g. --exhaustive,
# --sample 10, --reset-baseline, --only functional,variants.
cd "$(dirname "$0")/../.." && . lib/common.sh
P="$GEN_DIR/$POP"
[ -f "$P/expected-inventory.json" ] || die "no $P/expected-inventory.json; run phase 45 first"
python3 -m validator.run --pop "$P" --version-dir "$VERSION_DIR" --rhoai-csv "$RHOAI_CSV" --out "$ROOT/reports" "$@"
