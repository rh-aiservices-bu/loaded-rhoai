#!/usr/bin/env bash
# Shared helpers for loaded-rhoai phases. Sourced by loaded-rhoai.sh and every phases/NN-*/run.sh.
# Expects the working directory to be the repo root.

set -uo pipefail
for p in /opt/homebrew/bin /usr/local/bin; do [ -d "$p" ] && case ":$PATH:" in *":$p:"*) ;; *) PATH="$p:$PATH" ;; esac; done
export PATH

ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
RHOAI_VERSION=${RHOAI_VERSION:-3.5.2}
VERSION_DIR="$ROOT/versions/$RHOAI_VERSION"
[ -f "$VERSION_DIR/version.env" ] || { echo "No release for RHOAI $RHOAI_VERSION. Supported: $(ls "$ROOT/versions" | tr '\n' ' ')" >&2; exit 2; }
# shellcheck source=/dev/null
. "$VERSION_DIR/version.env"

PROFILE=${PROFILE:-medium}
SEED=${SEED:-42}
MODELS=${MODELS:-}                     # empty: the profile's model count
RUNNING_MODELS=${RUNNING_MODELS:-}     # empty: the profile's running count
RATE_SCALE=${RATE_SCALE:-1.0}
APPS=redhat-ods-applications
LOG_DIR="$ROOT/logs"
GEN_DIR="$ROOT/generated"
GUIDE_DIR="$ROOT/.cache/rhoai-maas-guide"
POP="$PROFILE${MODELS:+-m$MODELS}"     # generated population directory name, as generate.py writes it
mkdir -p "$LOG_DIR" "$GEN_DIR"

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
warn() { echo "[$(date -u +%H:%M:%S)] WARNING: $*" >&2; }
die()  { echo "[$(date -u +%H:%M:%S)] FAILED: $*" >&2; exit 1; }

domain() { oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'; }

# Wait until a Subscription has installed a CSV and that CSV has Succeeded.
wait_sub() {  # wait_sub <namespace> <subscription> [timeout seconds]
  local ns=$1 sub=$2 t=${3:-900} csv phase i
  for i in $(seq 1 $((t / 10))); do
    csv=$(oc get sub "$sub" -n "$ns" -o jsonpath='{.status.installedCSV}' 2>/dev/null)
    if [ -n "$csv" ]; then
      phase=$(oc get csv "$csv" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)
      [ "$phase" = Succeeded ] && { log "  $sub: $csv Succeeded"; return 0; }
    fi
    sleep 10
  done
  warn "$ns/$sub not Succeeded after ${t}s (csv=${csv:-none} phase=${phase:-none})"
  return 1
}

# On a pinned cluster, OLM makes every install plan in a namespace Manual once any Subscription
# there is Manual. Approve pending plans only when every CSV in them is one we asked for.
approve_plans() {  # approve_plans <namespace> <csv-name-prefix> [...]
  local ns=$1; shift
  oc get installplan -n "$ns" -o json | python3 -c "
import json,sys
want=sys.argv[1:]
for p in json.load(sys.stdin)['items']:
    if p['spec'].get('approved') or p.get('status',{}).get('phase')!='RequiresApproval': continue
    csvs=p['spec']['clusterServiceVersionNames']
    if all(any(c.startswith(w) for w in want) for c in csvs): print(p['metadata']['name'], ' '.join(csvs))
" "$@" | while read -r plan csvs; do
    oc patch installplan "$plan" -n "$ns" --type merge -p '{"spec":{"approved":true}}' >/dev/null && log "  approved $ns/$plan ($csvs)"
  done
}

# Wait for DSC Ready. Every ~3 minutes, touch the component CRs: on 3.5.2 a component that
# recovers isn't always re-checked, so its status stays False until something changes (PLAN.md §17 item 23).
dsc_ready() {  # dsc_ready [timeout seconds]
  local t=${1:-600} i r cr
  for i in $(seq 1 $((t / 10))); do
    r=$(oc get dsc default-dsc -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    [ "$r" = True ] && return 0
    if [ $((i % 18)) = 0 ]; then
      for cr in $(oc api-resources --api-group=components.platform.opendatahub.io -o name 2>/dev/null); do
        oc get "$cr" -o name 2>/dev/null | xargs -r -I{} oc annotate {} loaded-rhoai.io/recheck="$(date +%s)" --overwrite >/dev/null 2>&1
      done
      log "  touched component CRs to re-check status"
    fi
    sleep 10
  done
  oc get dsc default-dsc -o json | python3 -c "
import json,sys
for c in json.load(sys.stdin)['status']['conditions']:
    if c['status']!='True' and c.get('reason')!='Removed': print('  ',c['type'],c.get('reason'),(c.get('message') or '')[:120])"
  return 1
}

# Clone rhoai-maas-guide at the pinned commit (or re-use it if it's already there).
ensure_guide() {
  if [ ! -d "$GUIDE_DIR/.git" ]; then
    log "fetching rhoai-maas-guide $GUIDE_REF"
    git clone -q "$GUIDE_REPO" "$GUIDE_DIR" || die "git clone $GUIDE_REPO"
  fi
  if [ "$(git -C "$GUIDE_DIR" rev-parse HEAD)" != "$GUIDE_REF" ]; then
    git -C "$GUIDE_DIR" fetch -q origin || true
    git -C "$GUIDE_DIR" checkout -q "$GUIDE_REF" || die "rhoai-maas-guide has no commit $GUIDE_REF"
  fi
}

# Keycloak admin credentials, for the realm-config tools.
kc_admin_env() {
  KC_ADMIN=$(oc get secret keycloak-initial-admin -n maas-keycloak -o jsonpath='{.data.username}' | base64 -d)
  KC_ADMIN_PASSWORD=$(oc get secret keycloak-initial-admin -n maas-keycloak -o jsonpath='{.data.password}' | base64 -d)
  export KC_ADMIN KC_ADMIN_PASSWORD
}

http_code() { curl -s -m "${2:-10}" -o /dev/null -w '%{http_code}' "$1"; }

# Run a standard-library Python tool inside the cluster, in the lr-toolbox pod.
# Usage: in_cluster <tool.py> [VAR=value ...]   TOKEN is always passed (the caller's own token).
in_cluster() {
  local tool=$1; shift
  oc apply -f "$ROOT/manifests/infra/toolbox.yaml" >/dev/null || return 1
  oc rollout status deploy/lr-toolbox -n lr-infra --timeout=180s >/dev/null || return 1
  oc exec -i -n lr-infra deploy/lr-toolbox -- env TOKEN="$(oc whoami -t)" "$@" python3 - < "$tool"
}
