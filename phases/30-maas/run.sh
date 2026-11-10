#!/usr/bin/env bash
# MaaS platform and observability from rhoai-maas-guide phases 2-7 (PLAN.md §7, §9): Kuadrant,
# user workload monitoring, the MaaS gateway, Postgres, Authorino TLS, the DSC, a simulator model,
# Tempo, OpenTelemetry, COO and usage logging. The guide's phases are idempotent.
cd "$(dirname "$0")/../.." && . lib/common.sh
ensure_guide

L="$LOG_DIR/setup-maas.log"
log "rhoai-maas-guide setup-maas.sh phases 2-7 (log: $L)"
(cd "$GUIDE_DIR" && bash scripts/setup-maas.sh --from-phase 2 --model simulator --skip-verify --with-observability) > "$L" 2>&1 \
  || { tail -20 "$L"; die "setup-maas.sh failed, see $L"; }
grep -E 'WARN|ERROR' "$L" | cut -c1-160 | head -20
c=$(http_code "https://maas.$(domain)/maas-api/health" 15)
log "MaaS API health: http=$c"
[ "$c" = 200 ] || warn "MaaS API not answering yet; phase 35 waits for the DSC"
log "phase 30 done"
