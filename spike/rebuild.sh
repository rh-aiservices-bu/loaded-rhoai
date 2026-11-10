#!/usr/bin/env bash
# Rebuild a lived-in RHOAI 3.5.2 cluster with the spike's fixes applied up front.
# Usage: rebuild.sh <phase>   phases: 0 topology, 1 operators, 2 maas, 3 components, 4 limits,
#                             5 identity, 6 verify, 7 population
set -uo pipefail
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
G=/Users/phayes/projects/rhoai-maas-guide
A=redhat-ods-applications
DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
die() { log "FAILED: $*"; exit 1; }

wait_csvs() {  # wait until every CSV in the cluster is Succeeded, and at least $1 distinct ones exist
  for i in $(seq 1 90); do
    n=$(oc get csv -A --no-headers 2>/dev/null | awk '{print $2}' | sort -u | wc -l | tr -d ' ')
    [ "$n" -lt "${1:-0}" ] && { sleep 10; continue; }
    bad=$(oc get csv -A --no-headers 2>/dev/null | awk '{print $2,$NF}' | sort -u | grep -vc Succeeded)
    [ "$bad" = 0 ] && return 0; sleep 10
  done
  oc get csv -A --no-headers | awk '{print $2,$NF}' | sort -u | grep -v Succeeded; return 1
}

dsc_ready() {  # wait for DSC Ready; touch component CRs if a status looks stale
  for i in $(seq 1 60); do
    r=$(oc get dsc default-dsc -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    [ "$r" = True ] && return 0
    if [ $((i % 18)) = 0 ]; then
      for cr in $(oc api-resources --api-group=components.platform.opendatahub.io -o name 2>/dev/null); do
        oc get "$cr" -o name 2>/dev/null | xargs -r -I{} oc annotate {} loaded-rhoai.io/recheck="$(date +%s)" --overwrite >/dev/null 2>&1
      done
      log "touched component CRs to re-check status"
    fi
    sleep 10
  done
  oc get dsc default-dsc -o json | python3 -c "
import json,sys
print([(c['type'],c.get('reason'),(c.get('message') or '')[:90]) for c in json.load(sys.stdin)['status']['conditions'] if c['status']!='True' and c.get('reason')!='Removed'])"
  return 1
}

case "${1:-}" in
0)
  log "topology: worker in every zone, control plane unschedulable"
  MS=$(oc get machineset -n openshift-machine-api -o name | grep 'us-east-2c-compute')
  oc scale "$MS" -n openshift-machine-api --replicas=1
  for i in $(seq 1 90); do
    n=$(oc get nodes -l topology.kubernetes.io/zone=us-east-2c,'!node-role.kubernetes.io/control-plane' --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
    [ "$n" -ge 1 ] && break; sleep 10
  done
  [ "$n" -ge 1 ] || die "2c worker did not become Ready"
  oc patch schedulers.config.openshift.io cluster --type merge -p '{"spec":{"mastersSchedulable":false}}'
  sleep 30; oc get nodes --no-headers | cut -c1-90 ;;
1)
  log "dependency operators"
  oc apply -f 10-operators.yaml >/dev/null
  for d in tempo opentelemetry coo; do oc apply -k $G/manifests/07-observability/$d >/dev/null; done
  wait_csvs 14 || die "dependency CSVs"
  oc get csv -A --no-headers | awk '{print $2,$NF}' | sort -u
  log "RHOAI 3.5.2, approving only the exact plan"
  oc apply -f 20-rhoai-operator.yaml >/dev/null
  for i in $(seq 1 30); do
    P=$(oc get installplan -n redhat-ods-operator -o json | python3 -c "
import json,sys
for i in json.load(sys.stdin)['items']:
    if not i['spec']['approved'] and i['spec']['clusterServiceVersionNames']==['rhods-operator.3.5.2']: print(i['metadata']['name'])")
    [ -n "$P" ] && break; sleep 5
  done
  [ -n "$P" ] || die "no install plan for exactly rhods-operator.3.5.2"
  oc patch installplan "$P" -n redhat-ods-operator --type merge -p '{"spec":{"approved":true}}'
  for i in $(seq 1 60); do [ "$(oc get csv rhods-operator.3.5.2 -n redhat-ods-operator -o jsonpath='{.status.phase}' 2>/dev/null)" = Succeeded ] && break; sleep 10; done
  oc get csv rhods-operator.3.5.2 -n redhat-ods-operator -o jsonpath='rhoai {.status.phase}{"\n"}'
  oc apply -f 11-operator-operands.yaml
  for i in $(seq 1 18); do oc get crd leaderworkersets.leaderworkerset.x-k8s.io jobsets.jobset.x-k8s.io >/dev/null 2>&1 && break; sleep 10; done
  oc get crd leaderworkersets.leaderworkerset.x-k8s.io jobsets.jobset.x-k8s.io --no-headers | cut -c1-60 ;;
2)
  log "guide phases 2-7: MaaS and observability"
  (cd $G && bash scripts/setup-maas.sh --from-phase 2 --model simulator --skip-verify --with-observability) > logs/setup-maas.log 2>&1 || die "setup-maas, see logs/setup-maas.log"
  grep -E 'WARN|ERROR' logs/setup-maas.log | cut -c1-160
  tail -14 logs/setup-maas.log | cut -c1-140 ;;
3)
  log "remaining components, alerting, per-user metrics"
  oc patch dsc default-dsc --type merge --patch-file 30-dsc-patch.json
  oc patch dsci default-dsci --type merge -p '{"spec":{"monitoring":{"alerting":{}}}}'
  oc patch maastenantconfig default-tenant -n models-as-a-service --type merge -p '{"spec":{"telemetry":{"enabled":true,"metrics":{"captureUser":true,"captureGroup":true}}}}'
  dsc_ready || die "DSC not Ready"
  oc get monitoring default-monitoring -o json | python3 -c "
import json,sys
print('monitoring not true:',[c['type'] for c in json.load(sys.stdin)['status']['conditions'] if c['status']!='True'])" ;;
4)
  log "controller limits measured on the last cluster"
  oc patch subscription rhcl-operator -n openshift-operators --type merge -p '{"spec":{"config":{"resources":{"requests":{"cpu":"200m","memory":"512Mi"},"limits":{"cpu":"2","memory":"3Gi"}}}}}'
  for spec in ai-gateway-operator:2Gi dashboard-operator:2Gi kserve-module-controller-manager:3Gi kuberay-operator:2Gi \
              llm-d-batch-gateway-operator:2Gi maas-controller:2Gi opendatahub-feast-operator:2Gi \
              spark-operator-controller:2Gi trustyai-service-operator-controller-manager:2Gi; do
    D=${spec%%:*}; M=${spec#*:}
    oc get deploy "$D" -n $A >/dev/null 2>&1 || { log "missing deployment $D"; continue; }
    C=$(oc get deploy "$D" -n $A -o jsonpath='{.spec.template.spec.containers[0].name}')
    oc annotate deploy "$D" -n $A opendatahub.io/managed=false --overwrite >/dev/null
    oc patch deploy "$D" -n $A --type strategic -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$C\",\"resources\":{\"limits\":{\"cpu\":\"2\",\"memory\":\"$M\"},\"requests\":{\"cpu\":\"200m\",\"memory\":\"512Mi\"}}}]}}}}" >/dev/null
  done
  sleep 60
  dsc_ready || die "DSC not Ready after limits"
  oc get deploy -n $A -o json | python3 -c "
import json,sys
print([(d['metadata']['name'],d['spec']['template']['spec']['containers'][0]['resources'].get('limits',{}).get('memory'),d['status'].get('availableReplicas')) for d in json.load(sys.stdin)['items'] if d['metadata'].get('annotations',{}).get('opendatahub.io/managed')=='false'])"
  oc get deploy kuadrant-operator-controller-manager -n openshift-operators -o jsonpath='kuadrant {.spec.template.spec.containers[0].resources.limits.memory} avail={.status.availableReplicas}{"\n"}' ;;
5)
  log "Keycloak, made persistent before any users exist"
  (cd $G && bash manifests/09-external-oidc/setup-keycloak.sh) > logs/setup-keycloak.log 2>&1 || die "setup-keycloak"
  K=maas-keycloak; U=https://keycloak-$K.$DOMAIN/realms/maas/.well-known/openid-configuration
  sed 's/namespace: lr-smoke/namespace: maas-keycloak/' 50-keycloak-persistent.yaml | python3 -c "
import sys; print(sys.stdin.read().split('---')[0])" | oc apply -f -
  oc patch deploy keycloak-pgsql -n $K --type strategic -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null},"template":{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"keycloak-pgsql-data"}}],"containers":[{"name":"pgsql","volumeMounts":[{"name":"data","mountPath":"/var/lib/pgsql/data"}]}]}}}}' || die "pgsql patch"
  oc rollout status deploy/keycloak-pgsql -n $K --timeout=240s
  oc delete pod keycloak-0 -n $K --wait=true; oc wait pod/keycloak-0 -n $K --for=condition=Ready --timeout=300s
  oc delete keycloakrealmimport maas -n $K; oc apply -f $G/manifests/09-external-oidc/keycloak/instance/keycloakrealmimport.yaml
  for i in $(seq 1 30); do [ "$(curl -s -m 8 -o /dev/null -w '%{http_code}' $U)" = 200 ] && break; sleep 10; done
  oc delete pod -n $K -l app=keycloak-pgsql --wait=true; oc delete pod keycloak-0 -n $K --wait=true
  oc rollout status deploy/keycloak-pgsql -n $K --timeout=180s; oc wait pod/keycloak-0 -n $K --for=condition=Ready --timeout=300s
  c=$(curl -s -m 8 -o /dev/null -w '%{http_code}' $U); log "realm after restarting both pods: http=$c"; [ "$c" = 200 ] || die "realm not durable"
  log "users, client, claims, IdP"
  export KC_ADMIN=$(oc get secret keycloak-initial-admin -n $K -o jsonpath='{.data.username}' | base64 -d)
  export KC_ADMIN_PASSWORD=$(oc get secret keycloak-initial-admin -n $K -o jsonpath='{.data.password}' | base64 -d)
  SECRET=$(oc get secret lr-keycloak-client -n openshift-config -o jsonpath='{.data.clientSecret}' 2>/dev/null | base64 -d)
  if [ -z "$SECRET" ]; then SECRET=$(python3 -c "import secrets;print(secrets.token_urlsafe(32))"); oc create secret generic lr-keycloak-client -n openshift-config --from-literal=clientSecret="$SECRET"; fi
  python3 kc_seed.py "https://keycloak-$K.$DOMAIN" generated/medium/users.json "https://oauth-openshift.$DOMAIN/oauth2callback/keycloak" "$SECRET" || die "kc_seed"
  python3 kc_mappers.py "https://keycloak-$K.$DOMAIN" || die "mappers"
  if ! oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}' | grep -qw keycloak; then
    oc patch oauth cluster --type json -p "[{\"op\":\"add\",\"path\":\"/spec/identityProviders/-\",\"value\":{\"name\":\"keycloak\",\"mappingMethod\":\"claim\",\"type\":\"OpenID\",\"openID\":{\"clientID\":\"openshift\",\"clientSecret\":{\"name\":\"lr-keycloak-client\"},\"issuer\":\"https://keycloak-$K.$DOMAIN/realms/maas\",\"claims\":{\"preferredUsername\":[\"preferred_username\"],\"name\":[\"name\"],\"email\":[\"email\"],\"groups\":[\"groups\"]}}}}]"
  fi
  sleep 45; for i in $(seq 1 40); do [ "$(oc get co authentication -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}')" = False ] && break; sleep 15; done
  python3 warm_login.py "oauth-openshift.$DOMAIN" "$(oc whoami --show-server)" generated/medium/users.json keycloak || die "warm login"
  oc patch auth.services.platform.opendatahub.io auth --type merge -p '{"spec":{"adminGroups":["rhods-admins","rhoai-admins"],"allowedGroups":["system:authenticated"]}}'
  oc adm policy add-cluster-role-to-group cluster-reader rhoai-admins >/dev/null
  log "pin every Subscription: Manual approval from now on"
  oc get sub -A --no-headers -o custom-columns=NS:.metadata.namespace,N:.metadata.name | while read -r ns n; do
    oc patch sub "$n" -n "$ns" --type merge -p '{"spec":{"installPlanApproval":"Manual"}}' >/dev/null; done
  oc get sub -A --no-headers -o custom-columns=NS:.metadata.namespace,N:.metadata.name,A:.spec.installPlanApproval,CSV:.status.installedCSV ;;
6)
  log "end-to-end checks"
  (cd $G && bash scripts/verify-maas.sh --no-cleanup) > logs/verify-maas.log 2>&1; tail -6 logs/verify-maas.log | cut -c1-90
  (cd $G && bash manifests/09-external-oidc/test-external-oidc.sh) > logs/test-oidc.log 2>&1; tail -6 logs/test-oidc.log | cut -c1-90 ;;
7)
  P=${2:-medium-m9}
  log "population $P"
  oc apply -f 40-infra.yaml >/dev/null; oc wait deploy/minio -n lr-infra --for=condition=Available --timeout=240s
  B=$(python3 -c "import json;print(' '.join(json.load(open('generated/$P/buckets.json'))+['lr-models']))")
  oc exec -n lr-infra deploy/minio -- sh -c "mc alias set l http://localhost:9000 lrminio lrminio-spike-only >/dev/null; for b in $B; do mc mb -p l/\$b; done" | tail -2
  bash prepull.sh generated/notebook-images.json
  STAGGER=1 bash apply_shards.sh "$P" 0 99
  python3 stop_notebooks.py "$P" | tail -2
  bash wait-stable.sh 2>&1 | grep -v 'short name' | tail -14 | cut -c1-150 ;;
*) echo "usage: $0 <0-7>"; exit 2 ;;
esac
log "phase ${1} done"
