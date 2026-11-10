#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
NS=lr-smoke; T=$(oc whoami -t)
ex() { oc exec -n $NS wb-running-0 -c wb-running -- "$@"; }
D=$(oc get route ds-pipeline-dspa -n $NS -o jsonpath='{.spec.host}'); RUN=$(cat logs/pipeline-run-id)
curl -sk -m 20 "https://$D/apis/v2beta1/runs/$RUN" -H "Authorization: Bearer $T" | python3 -c "import json,sys;d=json.load(sys.stdin);print('pipeline run state:',d.get('state'),d.get('error',''))"
ex curl -sk -m 10 -w ' feast http=%{http_code}\n' https://feast-fs-smoke-online.$NS.svc:443/health | cut -c1-100
ex curl -s -m 10 -o /dev/null -w 'trustyai http=%{http_code}\n' http://trustyai.$NS.svc/q/health
ex curl -sk -m 10 -w ' evalhub http=%{http_code}\n' https://evalhub.$NS.svc:8443/api/v1/health | cut -c1-120
ex curl -s -m 10 -o /dev/null -w 'notebook http=%{http_code}\n' http://localhost:8888/notebook/$NS/wb-running/api
ex curl -s -m 10 -o /dev/null -w 'isvc http=%{http_code}\n' http://isvc-running-predictor.$NS.svc.cluster.local/v1/models
ex curl -s -m 30 -o /dev/null -w 'ogx chat http=%{http_code}\n' http://ogx-smoke-service.$NS.svc:8321/v1/chat/completions -H 'Content-Type: application/json' -d '{"model":"sim/sim","messages":[{"role":"user","content":"hi"}],"max_tokens":5}'
R=$(oc get route lr-registry-https -n rhoai-model-registries -o jsonpath='{.spec.host}')
curl -sk -m 20 "https://$R/api/model_registry/v1alpha3/registered_models" -H "Authorization: Bearer $T" | python3 -c "import json,sys;d=json.load(sys.stdin);print('registry models after restart',d.get('size'))"
oc get svc mlflow -n redhat-ods-applications -o jsonpath='mlflow ports {.spec.ports}{"\n"}'
oc get deploy mlflow -n redhat-ods-applications -o json | python3 -c "
import json,sys
c=json.load(sys.stdin)['spec']['template']['spec']['containers'][0]; print(str(c.get('args',c.get('command')))[:300]); print(c.get('readinessProbe',{}).get('httpGet'))"
oc get httproute -A --no-headers 2>/dev/null | grep -i mlflow | cut -c1-110
echo "--- keycloak"
KC=https://$(oc get route -n maas-keycloak -o jsonpath='{.items[0].spec.host}')
AU=$(oc get secret keycloak-initial-admin -n maas-keycloak -o jsonpath='{.data.username}' | base64 -d)
AP=$(oc get secret keycloak-initial-admin -n maas-keycloak -o jsonpath='{.data.password}' | base64 -d)
AT=$(curl -sk "$KC/realms/master/protocol/openid-connect/token" -d grant_type=password -d client_id=admin-cli --data-urlencode "username=$AU" --data-urlencode "password=$AP" | python3 -c "import json,sys;print(json.load(sys.stdin)['access_token'])")
curl -sk -H "Authorization: Bearer $AT" "$KC/admin/realms/maas/clients?clientId=maas-oidc" | python3 -c "
import json,sys
c=json.load(sys.stdin)[0]; print('maas-oidc public',c['publicClient'],'dag',c['directAccessGrantsEnabled'],c.get('defaultClientScopes'))"
curl -sk -H "Authorization: Bearer $AT" "$KC/admin/realms/maas/client-scopes" | python3 -c "import json,sys;print([s['name'] for s in json.load(sys.stdin)])"
oc get oauth cluster -o jsonpath='idps {.spec.identityProviders[*].name}{"\n"}'
curl -s -m 8 -o /dev/null -w 'keycloak cert verify=%{ssl_verify_result} http=%{http_code}\n' "$KC/realms/maas/.well-known/openid-configuration"
