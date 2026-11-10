#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd /Users/phayes/projects/loaded-rhoai/spike
K=maas-keycloak; DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
export KC_ADMIN=$(oc get secret keycloak-initial-admin -n $K -o jsonpath='{.data.username}' | base64 -d)
export KC_ADMIN_PASSWORD=$(oc get secret keycloak-initial-admin -n $K -o jsonpath='{.data.password}' | base64 -d)
python3 kc_mappers.py https://keycloak-$K.$DOMAIN
for u in 630555f7-607d-491e-8cbb-74318f5742cd de7362d7-4d0f-4689-9dcb-76e0eca4c9c2; do oc delete user $u; oc delete identity keycloak:$u; done
time python3 warm_login.py oauth-openshift.$DOMAIN "$(oc whoami --show-server)" generated/medium/users.json keycloak
echo "users=$(oc get users --no-headers | wc -l) identities=$(oc get identity --no-headers | wc -l) groups=$(oc get groups --no-headers | wc -l)"
oc get group team-01 -o jsonpath='team-01 {.users}{"\n"}' | cut -c1-120
