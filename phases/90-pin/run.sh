#!/usr/bin/env bash
# Freeze the install (PLAN.md §5 "Upgrade workflow"): switch every Subscription to Manual approval,
# so nothing upgrades until a person approves it, and compare installed CSVs with the release lock.
cd "$(dirname "$0")/../.." && . lib/common.sh

log "pinning every Subscription to Manual approval"
oc get sub -A --no-headers -o custom-columns=NS:.metadata.namespace,N:.metadata.name | while read -r ns n; do
  oc patch sub "$n" -n "$ns" --type merge -p '{"spec":{"installPlanApproval":"Manual"}}' >/dev/null || warn "could not pin $ns/$n"
done

log "installed CSVs against versions/$RHOAI_VERSION/lock.txt"
oc get sub -A -o json | python3 -c "
import json,sys
lock={}
for line in open('$VERSION_DIR/lock.txt'):
    if line.strip() and not line.startswith('#'):
        p,c=line.split(); lock[p]=c
seen=set()
for s in json.load(sys.stdin)['items']:
    p=s['spec']['name']; c=s.get('status',{}).get('installedCSV','?')
    if (p,c) in seen: continue
    seen.add((p,c))
    note='' if lock.get(p)==c else (' (lock: '+lock[p]+')' if p in lock else ' (not in lock)')
    print(f'  {p:46} {c}{note}')
"
[ "$(oc get csv "$RHOAI_CSV" -n redhat-ods-operator -o jsonpath='{.status.phase}')" = Succeeded ] || die "$RHOAI_CSV is not the installed RHOAI"
log "phase 90 done"
