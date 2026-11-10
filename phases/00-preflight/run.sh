#!/usr/bin/env bash
# Fail fast before changing anything (PLAN.md §4 "Preflight checks"). Read-only, except with
# FIX_TOPOLOGY=1, which makes the control plane unschedulable and removes DaemonSet pods left
# behind on it.
cd "$(dirname "$0")/../.." && . lib/common.sh
fail=0
bad() { echo "  FAIL  $*"; fail=1; }
ok()  { echo "  ok    $*"; }

log "preflight for RHOAI $RHOAI_VERSION, profile $PROFILE"

for t in oc python3 git curl helm; do command -v $t >/dev/null && ok "$t found" || bad "$t is not on PATH"; done
[ "$(oc auth can-i '*' '*' --all-namespaces 2>/dev/null)" = yes ] && ok "logged in as $(oc whoami) with cluster-admin" || bad "need cluster-admin (oc login first)"

ocp=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null)
if [ -n "$ocp" ] && [ "$(printf '%s\n%s\n' "$MIN_OCP" "$ocp" | sort -V | head -1)" = "$MIN_OCP" ]; then ok "OCP $ocp >= $MIN_OCP"; else bad "OCP ${ocp:-unknown} is older than $MIN_OCP"; fi

sc=$(oc get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}')
[ -n "$sc" ] && ok "default StorageClass $sc" || bad "no default StorageClass"

# Existing RHOAI: adopt only the exact version this release deploys.
cur=$(oc get csv -n redhat-ods-operator -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep '^rhods-operator' | head -1)
if [ -z "$cur" ]; then ok "RHOAI not installed: will install $RHOAI_CSV"
elif [ "$cur" = "$RHOAI_CSV" ]; then ok "RHOAI $cur already installed: will adopt it"
else bad "RHOAI $cur is installed, but this release deploys $RHOAI_CSV. Use a cluster without RHOAI, or one on $RHOAI_VERSION"; fi

# RHBK's CRDs are cluster-scoped, so every RHBK install must use the same channel (PLAN.md §6).
for ch in $(oc get sub -A -o jsonpath='{range .items[?(@.spec.name=="rhbk-operator")]}{.spec.channel}{"\n"}{end}' 2>/dev/null | sort -u); do
  [ "$ch" = "$RHBK_CHANNEL" ] && ok "existing RHBK on $ch matches" || bad "RHBK is already installed on $ch, but the MaaS guide installs $RHBK_CHANNEL"
done

# Topology (PLAN.md §4): workers in every zone, control plane unschedulable, big enough worker disks.
workers=$(oc get nodes -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/control-plane' -o json | python3 -c "
import json,sys
for n in json.load(sys.stdin)['items']:
    cap=n['status']['capacity'].get('ephemeral-storage','0Ki')
    gi=int(cap[:-2])//1048576 if cap.endswith('Ki') else int(cap)//1073741824
    print(n['metadata']['name'], n['metadata']['labels'].get('topology.kubernetes.io/zone','-'), gi)")
nw=$(echo "$workers" | grep -c . )
zones=$(echo "$workers" | awk '{print $2}' | sort -u | tr '\n' ' ')
echo "$workers" | sed 's/^/        worker /'
case $PROFILE in small) need=2 ;; *) need=3 ;; esac
[ "$nw" -ge "$need" ] && ok "$nw dedicated workers in zones: $zones" || bad "$PROFILE needs at least $need dedicated workers, found $nw"
small_disk=$(echo "$workers" | awk -v m="$MIN_WORKER_DISK_GI" '$3<m {print $1" ("$3"Gi)"}')
if [ -n "$small_disk" ]; then
  if [ "$PROFILE" = small ]; then warn "worker root disks under ${MIN_WORKER_DISK_GI}Gi: $small_disk"
  else bad "worker root disks under ${MIN_WORKER_DISK_GI}Gi: $small_disk (100 GB filled and evicted 69 pods on the spike)"; fi
else ok "worker root disks >= ${MIN_WORKER_DISK_GI}Gi"; fi

ms=$(oc get schedulers.config.openshift.io cluster -o jsonpath='{.spec.mastersSchedulable}')
if [ "$ms" = true ] && [ "$PROFILE" != small ]; then
  if [ "${FIX_TOPOLOGY:-0}" = 1 ]; then
    oc patch schedulers.config.openshift.io cluster --type merge -p '{"spec":{"mastersSchedulable":false}}' >/dev/null
    ok "control plane made unschedulable (--fix-topology)"
  else bad "the control plane is schedulable; workloads compete with etcd for disk. Re-run with --fix-topology"; fi
else ok "control plane unschedulable"; fi
if [ "${FIX_TOPOLOGY:-0}" = 1 ]; then python3 tools/fix_topology.py || bad "could not clean up DaemonSet pods on the control plane"; fi

# EBS volume attachments bind before CPU does (PLAN.md §15, §17 item 27).
python3 - <<'PY'
import json,subprocess
nodes=json.loads(subprocess.run(["oc","get","csinode","-o","json"],capture_output=True,text=True).stdout or '{"items":[]}')["items"]
va=json.loads(subprocess.run(["oc","get","volumeattachments","-o","json"],capture_output=True,text=True).stdout or '{"items":[]}')["items"]
used={}
for v in va: used[v["spec"]["nodeName"]]=used.get(v["spec"]["nodeName"],0)+1
for n in nodes:
    for d in n["spec"].get("drivers") or []:
        if d.get("allocatable",{}).get("count"):
            print(f"        volumes  {n['metadata']['name']:46} {used.get(n['metadata']['name'],0)}/{d['allocatable']['count']} ({d['name']})")
PY

[ "$fail" = 0 ] && log "preflight passed" || die "preflight failed; nothing was changed"
