#!/usr/bin/env bash
# Replace each zone's worker with one that has a larger root disk, keeping capacity throughout.
# Usage: replace-workers.sh <size-GiB> [zone ...]
set -uo pipefail
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
SIZE=$1; shift
ZONES=${*:-us-east-2a us-east-2b us-east-2c}
M=openshift-machine-api
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
for Z in $ZONES; do
  MS=$(oc get machineset -n $M -o name | grep "$Z-compute")
  OLD=$(oc get machines -n $M -l machine.openshift.io/cluster-api-machineset="${MS#*/}" -o jsonpath='{.items[0].metadata.name}')
  OLDNODE=$(oc get machine "$OLD" -n $M -o jsonpath='{.status.nodeRef.name}')
  log "$Z: replacing $OLD ($OLDNODE)"
  oc patch "$MS" -n $M --type json -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/providerSpec/value/blockDevices/0/ebs/volumeSize\",\"value\":$SIZE}]"
  oc scale "$MS" -n $M --replicas=2
  NEWNODE=""
  for i in $(seq 1 90); do
    NEWNODE=$(oc get nodes -l topology.kubernetes.io/zone=$Z,'!node-role.kubernetes.io/control-plane' -o json | python3 -c "
import json,sys
print(' '.join(n['metadata']['name'] for n in json.load(sys.stdin)['items'] if n['metadata']['name']!='$OLDNODE' and any(c['type']=='Ready' and c['status']=='True' for c in n['status']['conditions'])))")
    [ -n "$NEWNODE" ] && break; sleep 10
  done
  [ -n "$NEWNODE" ] || { log "FAILED: no new Ready node in $Z; old worker left in place"; exit 1; }
  log "$Z: new node $NEWNODE Ready, root disk $(oc debug node/$NEWNODE --quiet -- chroot /host df -BG --output=size /var 2>/dev/null | tail -1 | tr -d ' ')"
  oc adm cordon "$OLDNODE"
  oc adm drain "$OLDNODE" --ignore-daemonsets --delete-emptydir-data --force --timeout=900s --grace-period=60 > logs/drain-$Z.log 2>&1 || { log "FAILED: drain of $OLDNODE, see logs/drain-$Z.log"; exit 1; }
  log "$Z: drained $OLDNODE"
  oc annotate machine "$OLD" -n $M machine.openshift.io/delete-machine=true --overwrite
  oc scale "$MS" -n $M --replicas=1
  for i in $(seq 1 60); do oc get machine "$OLD" -n $M >/dev/null 2>&1 || break; sleep 10; done
  log "$Z: old machine removed"
  for i in $(seq 1 60); do
    bad=$(oc get pods -A --no-headers 2>/dev/null | awk '$4=="Pending" || $4=="ContainerCreating" || $4~/Err|Crash/' | grep -vc installer-)
    [ "$bad" = 0 ] && break; sleep 15
  done
  log "$Z: pods not yet running: $bad"
  oc get pods -A --no-headers | awk '$4=="Pending" || $4=="ContainerCreating" || $4~/Err|Crash/' | head -6 | cut -c1-120
  r=$(oc get dsc default-dsc -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  log "$Z: DSC Ready=$r"
done
oc get nodes --no-headers | cut -c1-90
