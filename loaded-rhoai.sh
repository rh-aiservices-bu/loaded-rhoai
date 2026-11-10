#!/usr/bin/env bash
# loaded-rhoai: build a lived-in RHOAI cluster and validate it (PLAN.md §13).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"

usage() {
  cat <<'EOF'
Usage: ./loaded-rhoai.sh <command> [options]

  install     [--version 3.5.2] [--profile small|medium] [--seed 42] [--models N] [--running-models N]
              [--fix-topology] [--from NN] [--only NN] [--skip-maaspal] [--no-load] [--rate-scale 1.0]
  validate    [--exhaustive] [--sample N] [--reset-baseline] [--only sections]
              platform, inventory, status, functional probes, startability, identity, load, variants,
              and the upgrade comparison; reports in reports/<time>/
  status      installed version, DSC state, population counts, load generator
  load        status | pause | resume | usage
  maaspal     <plan.json>   run maaspal scenarios headlessly; plan is [[scenario, {overrides}], ...]
  creds       <user>        print a generated user's Keycloak password
  versions    list the RHOAI releases this repo can deploy
  phases      list install phases

Settings come from flags, then environment variables (RHOAI_VERSION, PROFILE, SEED, MODELS,
RATE_SCALE), then ./loaded-rhoai.env. install records its settings in generated/install.env,
and later commands reuse them.
EOF
}

# Lowest precedence first: loaded-rhoai.env, then the last install's settings, without
# overriding anything already set in the environment.
load_env_file() {
  [ -f "$1" ] || return 0
  while IFS='=' read -r k v; do
    case "$k" in ''|\#*) continue ;; esac
    [ -z "${!k:-}" ] && export "$k=$v"
  done < "$1"
}
load_env_file "$ROOT/generated/install.env"
load_env_file "$ROOT/loaded-rhoai.env"

PHASES=(00-preflight 10-operators 20-rhoai 30-maas 35-components 40-controller-limits 45-generate 50-identity 55-maas-tiers 58-mcp-gateway 60-population 62-seed 63-playgrounds 65-settle 68-load 70-maaspal 90-pin)

cmd=${1:-}; shift || true
case "$cmd" in
install)
  FROM=00; ONLY=; SKIP=()
  while [ $# -gt 0 ]; do
    case $1 in
      --version) export RHOAI_VERSION=$2; shift 2 ;;
      --profile) export PROFILE=$2; shift 2 ;;
      --seed) export SEED=$2; shift 2 ;;
      --models) export MODELS=$2; shift 2 ;;
      --running-models) export RUNNING_MODELS=$2; shift 2 ;;
      --rate-scale) export RATE_SCALE=$2; shift 2 ;;
      --fix-topology) export FIX_TOPOLOGY=1; shift ;;
      --from) FROM=$2; shift 2 ;;
      --only) ONLY=$2; shift 2 ;;
      --skip-maaspal) SKIP+=(70-maaspal); shift ;;
      --no-load) SKIP+=(68-load); shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "unknown option $1" >&2; usage; exit 2 ;;
    esac
  done
  . lib/common.sh
  printf 'RHOAI_VERSION=%s\nPROFILE=%s\nSEED=%s\nMODELS=%s\nRUNNING_MODELS=%s\nRATE_SCALE=%s\n' "$RHOAI_VERSION" "$PROFILE" "$SEED" "$MODELS" "$RUNNING_MODELS" "$RATE_SCALE" > generated/install.env
  log "loaded-rhoai install: RHOAI $RHOAI_VERSION, profile $PROFILE${MODELS:+ with $MODELS models}, seed $SEED"
  for p in "${PHASES[@]}"; do
    n=${p%%-*}
    if [ -n "$ONLY" ]; then [ "$n" = "$ONLY" ] || continue
    else [ "$((10#$n))" -lt "$((10#$FROM))" ] && continue; fi
    case " ${SKIP[*]:-} " in *" $p "*) log "skipping $p"; continue ;; esac
    log "=== phase $p"
    bash "phases/$p/run.sh" || { log "phase $p failed. Fix the cause, then resume with: ./loaded-rhoai.sh install --from $n"; exit 1; }
  done
  if [ -z "$ONLY" ]; then log "install complete. Next: ./loaded-rhoai.sh validate"; fi
  ;;
validate)
  exec bash phases/80-validate/run.sh "$@" ;;
status)
  . lib/common.sh
  echo "release:  RHOAI $RHOAI_VERSION, profile $POP, seed $SEED"
  echo "rhoai:    $(oc get csv -n redhat-ods-operator -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{"\n"}{end}' | grep rhods-operator)"
  echo "dsc:      Ready=$(oc get dsc default-dsc -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  echo "projects: $(oc get ns -l loaded-rhoai.io/managed=true --no-headers 2>/dev/null | wc -l | tr -d ' ') managed namespaces"
  for k in notebook isvc llminferenceservice dspa featurestore raycluster trainjob; do
    printf '  %-22s %s\n' "$k" "$(oc get "$k" -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  done
  echo "load:     $(oc get deploy loadgen -n loaded-rhoai-load -o jsonpath='{.status.availableReplicas}/{.spec.replicas} available' 2>/dev/null || echo 'not installed')"
  ;;
load)
  . lib/common.sh
  POD=$(oc get pods -n loaded-rhoai-load -l app=loadgen -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -n "$POD" ] || die "load generator not running"
  case "${1:-status}" in
    pause)  oc exec -n loaded-rhoai-load "$POD" -- touch /tmp/pause && log "traffic paused" ;;
    resume) oc exec -n loaded-rhoai-load "$POD" -- rm -f /tmp/pause && log "traffic resumed" ;;
    usage)  python3 tools/usage_check.py "$(cat generated/loadgen-start-epoch)" ;;
    status) oc exec -n loaded-rhoai-load "$POD" -- python3 -c "
import urllib.request,re,collections
t=urllib.request.urlopen('http://localhost:9100/metrics').read().decode()
c=collections.Counter(); users=set()
for l in t.splitlines():
    if l.startswith('loadgen_requests_total'):
        m=dict(re.findall(r'(\w+)=\"([^\"]*)\"',l)); c[m['code']]+=float(l.split()[-1]); users.add(m['user'])
print('users sending:',len(users),' requests by status code:',{k:int(v) for k,v in sorted(c.items())})"
            oc exec -n loaded-rhoai-load "$POD" -- sh -c 'if [ -f /tmp/pause ]; then echo "state: paused"; else echo "state: sending"; fi' ;;
    *) usage; exit 2 ;;
  esac ;;
maaspal)
  . lib/common.sh
  [ -f "${1:-}" ] || die "usage: maaspal <plan.json>"
  B=$(oc get pods -n cp-maaspal -o name | grep bff | head -1)
  [ -n "$B" ] || die "maaspal BFF not running"
  L="logs/maaspal-$(date -u +%Y%m%dT%H%M%SZ).log"
  oc exec -i -n cp-maaspal "$B" -- env TOKEN="$(oc whoami -t)" PLAN="$(cat "$1")" python3 - < tools/maaspal_run.py | tee "$L" ;;
creds)
  . lib/common.sh
  [ -n "${1:-}" ] || die "usage: creds <user>"
  python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]]['password'])" "generated/$POP/users.json" "$1" ;;
versions)
  for v in versions/*/version.env; do d=$(dirname "$v"); echo "$(basename "$d")  $(grep -E '^RHOAI_CSV=' "$v" | cut -d= -f2)"; done ;;
phases)
  printf '%s\n' "${PHASES[@]}" 80-validate ;;
-h|--help|help|"") usage ;;
*) echo "unknown command $cmd" >&2; usage; exit 2 ;;
esac
