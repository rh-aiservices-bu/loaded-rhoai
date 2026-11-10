#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd /Users/phayes/projects/loaded-rhoai/spike
K=maas-keycloak; DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'); KC=https://keycloak-maas-keycloak.$DOMAIN
oc get imagestream -n redhat-ods-applications -l opendatahub.io/notebook-image=true -o json | python3 -c "
import json,sys
want={'s2i-minimal-notebook','s2i-generic-data-science-notebook','pytorch','code-server-notebook','odh-trustyai-notebook'}
out={}
for i in json.load(sys.stdin)['items']:
    if i['metadata']['name'] in want:
        for t in i['status']['tags']:
            if t['tag']=='3.5' and t.get('items'): out[i['metadata']['name']+':3.5']=t['items'][0]['dockerImageReference']
json.dump(out,open('generated/notebook-images.json','w'),indent=1); print(sorted(out))"
python3 generate.py --profile small
python3 generate.py --profile medium
export KC_ADMIN=$(oc get secret keycloak-initial-admin -n $K -o jsonpath='{.data.username}' | base64 -d)
export KC_ADMIN_PASSWORD=$(oc get secret keycloak-initial-admin -n $K -o jsonpath='{.data.password}' | base64 -d)
SECRET=$(oc get secret lr-keycloak-client -n openshift-config -o jsonpath='{.data.clientSecret}' 2>/dev/null | base64 -d)
if [ -z "$SECRET" ]; then SECRET=$(python3 -c "import secrets;print(secrets.token_urlsafe(32))"); oc create secret generic lr-keycloak-client -n openshift-config --from-literal=clientSecret="$SECRET"; fi
python3 kc_seed.py "$KC" generated/medium/users.json "https://oauth-openshift.$DOMAIN/oauth2callback/keycloak" "$SECRET"; echo "seed exit=$?"
if ! oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}' | grep -qw keycloak; then
oc patch oauth cluster --type json -p "[{\"op\":\"add\",\"path\":\"/spec/identityProviders/-\",\"value\":{\"name\":\"keycloak\",\"mappingMethod\":\"claim\",\"type\":\"OpenID\",\"openID\":{\"clientID\":\"openshift\",\"clientSecret\":{\"name\":\"lr-keycloak-client\"},\"issuer\":\"$KC/realms/maas\",\"claims\":{\"preferredUsername\":[\"preferred_username\"],\"name\":[\"name\"],\"email\":[\"email\"],\"groups\":[\"groups\"]}}}}]"
fi
oc get oauth cluster -o jsonpath='idps {.spec.identityProviders[*].name}{"\n"}'
