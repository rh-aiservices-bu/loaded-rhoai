#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
K=maas-keycloak; G=/Users/phayes/projects/rhoai-maas-guide/manifests/09-external-oidc/keycloak/instance
oc get route -n $K --no-headers | cut -c1-110
KC=https://$(oc get route -n $K -o jsonpath='{.items[0].spec.host}')
for p in /realms/maas/.well-known/openid-configuration /realms/master/.well-known/openid-configuration /; do curl -s -m 10 -o /dev/null -w "$p http=%{http_code}\n" "$KC$p"; done
echo "--- db storage"; oc get deploy keycloak-pgsql -n $K -o json | python3 -c "
import json,sys
s=json.load(sys.stdin)['spec']['template']['spec']; print(s['volumes']); print(s['containers'][0].get('volumeMounts'))"
oc get pvc -n $K --no-headers 2>&1 | cut -c1-100
grep -nE 'emptyDir|persistentVolumeClaim|kind:' $G/keycloak-postgresql.yaml
echo "--- admin secret and login"
AU=$(oc get secret keycloak-initial-admin -n $K -o jsonpath='{.data.username}' | base64 -d)
AP=$(oc get secret keycloak-initial-admin -n $K -o jsonpath='{.data.password}' | base64 -d)
curl -s -m 15 "$KC/realms/master/protocol/openid-connect/token" -d grant_type=password -d client_id=admin-cli --data-urlencode "username=$AU" --data-urlencode "password=$AP" | python3 -c "
import json,sys
d=json.load(sys.stdin); print('admin login:', 'ok' if 'access_token' in d else d)"
echo "--- db contents"
P=$(oc get pods -n $K -o name | grep pgsql | head -1); oc exec -n $K $P -- sh -c 'psql -U $POSTGRES_USER -d ${POSTGRES_DB:-keycloak} -tc "select name from realm" 2>&1 || psql -d keycloak -tc "select name from realm" 2>&1' | cut -c1-120
oc logs -n $K keycloak-0 --tail=8 2>&1 | cut -c1-170
oc get keycloak keycloak -n $K -o json | python3 -c "
import json,sys
[print(c['type'],c['status'],(c.get('message') or '')[:120]) for c in json.load(sys.stdin)['status']['conditions']]"
oc get keycloakrealmimport maas -n $K -o json | python3 -c "
import json,sys
[print(c['type'],c['status'],(c.get('message') or '')[:120]) for c in json.load(sys.stdin)['status']['conditions']]"
echo "--- maas oidc"; oc get aitenant models-as-a-service -n ai-tenants -o jsonpath='{.spec.oidc}{"\n"}'
oc get deploy -n keycloak keycloak-pgsql -o json | python3 -c "
import json,sys
print('rhdp keycloak db volumes:',json.load(sys.stdin)['spec']['template']['spec']['volumes'])"
