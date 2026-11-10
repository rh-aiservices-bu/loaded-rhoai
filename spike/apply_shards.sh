#!/usr/bin/env bash
# Apply generated shards in parallel with server-side apply.
# Usage: apply_shards.sh <profile> <first-shard> <last-shard>   (numbers, 0 = cluster-scoped shard)
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
P=$1; FIRST=$2; LAST=$3
L=logs/apply-$P-$FIRST-$LAST.log; : > "$L"
ls generated/$P/shards/*.json | while read -r f; do
  n=$(basename "$f" | cut -d- -f1 | cut -d. -f1); n=$((10#$n))
  [ "$n" -ge "$FIRST" ] && [ "$n" -le "$LAST" ] && echo "$f"
done > /tmp/lr-shards.$$
wait_ca() {  # wait until every namespace in the shard has a complete odh-trusted-ca-bundle
  for ns in $(python3 -c "import json,sys;print(' '.join(sorted({d['metadata']['namespace'] for d in json.load(open(sys.argv[1]))['items']})))" "$1"); do
    for i in $(seq 1 60); do
      [ -n "$(oc get cm odh-trusted-ca-bundle -n "$ns" -o jsonpath='{.data.ca-bundle\.crt}' 2>/dev/null | head -c 10)" ] && break; sleep 5
    done
  done
}
# STAGGER=1: one shard at a time, stopping workbenches after each, so nodes never face every
# workbench starting at once (that filled the 100 GB worker disks and caused 69 evictions).
if [ "${STAGGER:-0}" = 1 ]; then
  while read -r f; do
    case "$f" in *after-ca*) wait_ca "$f" ;; esac
    oc apply --server-side --force-conflicts -f "$f" >> "$L" 2>&1
    python3 stop_notebooks.py "$P" >/dev/null 2>&1
  done < /tmp/lr-shards.$$
else
  grep -v after-ca /tmp/lr-shards.$$ | xargs -P 6 -I{} sh -c 'oc apply --server-side --force-conflicts -f "$1" 2>&1' _ {} >> "$L"
  for f in $(grep after-ca /tmp/lr-shards.$$); do wait_ca "$f"; oc apply --server-side --force-conflicts -f "$f" >> "$L" 2>&1; done
fi
rm -f /tmp/lr-shards.$$
echo "applied=$(grep -cE 'serverside-applied|unchanged' "$L") errors=$(grep -cE '^(Error|error)|failed|denied|invalid' "$L")"
grep -E '^(Error|error)|failed|denied|invalid' "$L" | cut -c1-230 | sort | uniq -c | sort -rn | head -15
