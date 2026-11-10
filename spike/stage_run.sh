#!/usr/bin/env bash
# Apply a range of shards, wait for pods to settle, then time the dashboard.
# Usage: stage_run.sh <stage-label> <first-shard> <last-shard> [roles]
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
S=$1; F=$2; L=$3; R=${4:-admin,lead,regular}
U=https://rh-ai.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
if [ "$L" -ge "$F" ]; then
  bash apply_shards.sh "${PROFILE:-medium}" "$F" "$L"
  python3 stop_notebooks.py "${PROFILE:-medium}"
  for i in $(seq 1 40); do
    n=$(oc get pods -A --no-headers 2>/dev/null | grep -E '^lr-' | grep -vE ' (Running|Completed) ' | wc -l | tr -d ' ')
    [ "$n" = 0 ] && break; sleep 15
  done
  echo "not settled pods: $n"; oc get pods -A --no-headers 2>/dev/null | grep -E '^lr-' | grep -vE ' (Running|Completed) ' | awk '{print $1,$2,$3,$4}' | head -12 | cut -c1-110
fi
echo "projects=$(oc get ns -l opendatahub.io/dashboard=true --no-headers | wc -l | tr -d ' ') notebooks=$(oc get notebook -A --no-headers | wc -l | tr -d ' ') isvc=$(oc get isvc -A --no-headers | wc -l | tr -d ' ') pods=$(oc get pods -A --no-headers | wc -l | tr -d ' ')"
oc adm top nodes --no-headers | awk '{print $1,$2,$3,$4,$5}' | cut -c1-70
.venv/bin/python ux_timing.py "$U" generated/medium/users.json "$S" logs/ux --reps 2 --roles "$R" > "logs/ux-$S.log" 2>&1; echo "ux exit=$?"
cut -c1-100 "logs/ux-$S.log" | tail -55
