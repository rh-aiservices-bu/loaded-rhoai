#!/usr/bin/env bash
# Apply generated shards with server-side apply.
# Usage: apply_shards.sh <population> <first-shard> <last-shard>   (numbers; 0 is the cluster-scoped shard)
# STAGGER=1 applies one shard at a time and stops workbenches after each, so nodes never face every
# workbench starting at once (that filled 100 GB worker disks and caused 69 evictions on the spike).
# Run from the repo root.
set -uo pipefail
P=$1; FIRST=$2; LAST=$3
L=logs/apply-$P-$FIRST-$LAST.log; : > "$L"
LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT
for f in generated/"$P"/shards/*.json; do
  n=$(basename "$f" | cut -d- -f1 | cut -d. -f1); n=$((10#$n))
  [ "$n" -ge "$FIRST" ] && [ "$n" -le "$LAST" ] && echo "$f"
done > "$LIST"

# TrustyAI and Feast mount odh-trusted-ca-bundle with subPath; a pod that starts before the
# network operator adds ca-bundle.crt fails with "Not a directory" and never recovers.
wait_ca() {
  for ns in $(python3 -c "import json,sys;print(' '.join(sorted({d['metadata']['namespace'] for d in json.load(open(sys.argv[1]))['items']})))" "$1"); do
    for i in $(seq 1 60); do
      [ -n "$(oc get cm odh-trusted-ca-bundle -n "$ns" -o jsonpath='{.data.ca-bundle\.crt}' 2>/dev/null | head -c 10)" ] && break; sleep 5
    done
  done
}

if [ "${STAGGER:-0}" = 1 ]; then
  total=$(wc -l < "$LIST" | tr -d ' '); i=0
  while read -r f; do
    i=$((i + 1))
    case "$f" in *after-ca*) wait_ca "$f" ;; esac
    oc apply --server-side --force-conflicts -f "$f" >> "$L" 2>&1
    python3 tools/stop_notebooks.py "$P" >/dev/null 2>&1
    [ $((i % 5)) = 0 ] && echo "  applied $i of $total shards"
  done < "$LIST"
else
  grep -v after-ca "$LIST" | xargs -P 6 -I{} sh -c 'oc apply --server-side --force-conflicts -f "$1" 2>&1' _ {} >> "$L"
  for f in $(grep after-ca "$LIST"); do wait_ca "$f"; oc apply --server-side --force-conflicts -f "$f" >> "$L" 2>&1; done
fi
errors=$(grep -cE '^(Error|error)|failed|denied|invalid' "$L")
echo "  applied=$(grep -cE 'serverside-applied|unchanged' "$L") errors=$errors (log: $L)"
grep -E '^(Error|error)|failed|denied|invalid' "$L" | cut -c1-230 | sort | uniq -c | sort -rn | head -15
[ "$errors" = 0 ]
