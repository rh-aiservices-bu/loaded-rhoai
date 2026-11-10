#!/usr/bin/env bash
# Keycloak identity (PLAN.md §6 "Identity"): the guide's Keycloak, made persistent before any user
# exists; generated users, groups and the `openshift` client; claim mappers; the OpenShift OpenID
# IdP added alongside existing ones; one login per user; dashboard admin groups.
cd "$(dirname "$0")/../.." && . lib/common.sh
ensure_guide
K=maas-keycloak
DOMAIN=$(domain)
KC="https://keycloak-$K.$DOMAIN"
ISSUER="$KC/realms/maas/.well-known/openid-configuration"
USERS="$GEN_DIR/$POP/users.json"
[ -f "$USERS" ] || die "no $USERS; run phase 45 first"

persistent() { [ "$(oc get deploy keycloak-pgsql -n $K -o jsonpath='{.spec.template.spec.volumes[?(@.name=="data")].persistentVolumeClaim.claimName}' 2>/dev/null)" = keycloak-pgsql-data ]; }

if persistent && [ "$(http_code "$ISSUER")" = 200 ]; then
  log "Keycloak already installed and persistent"
else
  log "Keycloak from rhoai-maas-guide (log: $LOG_DIR/setup-keycloak.log)"
  (cd "$GUIDE_DIR" && bash manifests/09-external-oidc/setup-keycloak.sh) > "$LOG_DIR/setup-keycloak.log" 2>&1 \
    || { tail -20 "$LOG_DIR/setup-keycloak.log"; die "setup-keycloak.sh failed"; }
  if ! persistent; then
    log "moving the Keycloak database onto a PVC, then re-importing the realm"
    oc apply -f manifests/identity/keycloak-pgsql-pvc.yaml >/dev/null || die "Keycloak PVC"
    oc patch deploy keycloak-pgsql -n $K --type strategic -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null},"template":{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"keycloak-pgsql-data"}}],"containers":[{"name":"pgsql","volumeMounts":[{"name":"data","mountPath":"/var/lib/pgsql/data"}]}]}}}}' >/dev/null || die "pgsql patch"
    oc rollout status deploy/keycloak-pgsql -n $K --timeout=240s || die "pgsql rollout"
    oc delete pod keycloak-0 -n $K --wait=true >/dev/null; oc wait pod/keycloak-0 -n $K --for=condition=Ready --timeout=300s >/dev/null || die "keycloak-0 not Ready"
    oc delete keycloakrealmimport maas -n $K --ignore-not-found >/dev/null
    oc apply -f "$GUIDE_DIR/manifests/09-external-oidc/keycloak/instance/keycloakrealmimport.yaml" >/dev/null || die "realm import"
    for i in $(seq 1 30); do [ "$(http_code "$ISSUER")" = 200 ] && break; sleep 10; done
  fi
  # Prove durability: restart both pods and the realm must still answer.
  oc delete pod -n $K -l app=keycloak-pgsql --wait=true >/dev/null; oc delete pod keycloak-0 -n $K --wait=true >/dev/null
  oc rollout status deploy/keycloak-pgsql -n $K --timeout=180s >/dev/null; oc wait pod/keycloak-0 -n $K --for=condition=Ready --timeout=300s >/dev/null
  for i in $(seq 1 18); do c=$(http_code "$ISSUER"); [ "$c" = 200 ] && break; sleep 10; done
  log "realm after restarting both pods: http=$c"; [ "$c" = 200 ] || die "Keycloak realm is not durable"
fi

log "users, groups, the openshift client and its claim mappers"
kc_admin_env
SECRET=$(oc get secret lr-keycloak-client -n openshift-config -o jsonpath='{.data.clientSecret}' 2>/dev/null | base64 -d)
if [ -z "$SECRET" ]; then
  SECRET=$(python3 -c "import secrets;print(secrets.token_urlsafe(32))")
  oc create secret generic lr-keycloak-client -n openshift-config --from-literal=clientSecret="$SECRET" >/dev/null
fi
python3 tools/kc_seed.py "$KC" "$USERS" "https://oauth-openshift.$DOMAIN/oauth2callback/keycloak" "$SECRET" || die "kc_seed"
# preferred_username, email and name must exist before anyone logs in, or OpenShift names users by UUID.
python3 tools/kc_mappers.py "$KC" || die "kc_mappers"

if oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}' | grep -qw keycloak; then
  log "OpenShift IdP keycloak already present"
else
  log "adding the keycloak OpenID IdP to OAuth/cluster, keeping existing IdPs"
  if [ -z "$(oc get oauth cluster -o jsonpath='{.spec.identityProviders}')" ]; then
    oc patch oauth cluster --type merge -p '{"spec":{"identityProviders":[]}}' >/dev/null
  fi
  oc patch oauth cluster --type json -p "[{\"op\":\"add\",\"path\":\"/spec/identityProviders/-\",\"value\":{\"name\":\"keycloak\",\"mappingMethod\":\"claim\",\"type\":\"OpenID\",\"openID\":{\"clientID\":\"openshift\",\"clientSecret\":{\"name\":\"lr-keycloak-client\"},\"issuer\":\"$KC/realms/maas\",\"claims\":{\"preferredUsername\":[\"preferred_username\"],\"name\":[\"name\"],\"email\":[\"email\"],\"groups\":[\"groups\"]}}}}]" >/dev/null || die "OAuth IdP"
  sleep 45
fi
for i in $(seq 1 40); do [ "$(oc get co authentication -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}')" = False ] && break; sleep 15; done

log "logging every user in once (creates User, Identity and Group objects)"
python3 tools/warm_login.py "oauth-openshift.$DOMAIN" "$(oc whoami --show-server)" "$USERS" keycloak || die "warm login"

oc patch auth.services.platform.opendatahub.io auth --type merge -p '{"spec":{"adminGroups":["rhods-admins","rhoai-admins"],"allowedGroups":["system:authenticated"]}}' >/dev/null || die "dashboard admin groups"
# Dashboard admins see other users' projects only with cluster-reader (PLAN.md §6).
oc adm policy add-cluster-role-to-group cluster-reader rhoai-admins >/dev/null
log "phase 50 done"
