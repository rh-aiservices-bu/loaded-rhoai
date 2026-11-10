#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd /Users/phayes/projects/loaded-rhoai/spike
K=maas-keycloak; G=/Users/phayes/projects/rhoai-maas-guide/manifests/09-external-oidc/keycloak/instance
cat > 50-keycloak-persistent.yaml <<'YAML'
# The guide's keycloak-pgsql has no volume, so any pod restart wipes the realm and all users.
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: keycloak-pgsql-data, namespace: maas-keycloak}
spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 10Gi}}}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: ogx-pg-data, namespace: lr-smoke}
spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 5Gi}}}
YAML
oc apply -f 50-keycloak-persistent.yaml
oc patch deploy keycloak-pgsql -n $K --type strategic -p '{"spec":{"strategy":{"type":"Recreate"},"template":{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"keycloak-pgsql-data"}}],"containers":[{"name":"pgsql","volumeMounts":[{"name":"data","mountPath":"/var/lib/pgsql/data"}]}]}}}}'
oc rollout status deploy/keycloak-pgsql -n $K --timeout=240s
oc delete pod keycloak-0 -n $K
oc wait pod/keycloak-0 -n $K --for=condition=Ready --timeout=300s 2>&1 | tail -1
oc delete keycloakrealmimport maas -n $K
oc apply -f $G/keycloakrealmimport.yaml
for i in $(seq 1 24); do sleep 10; c=$(curl -s -m 8 -o /dev/null -w '%{http_code}' https://keycloak-maas-keycloak.apps.ocp.5sblg.sandbox3574.opentlc.com/realms/maas/.well-known/openid-configuration); [ "$c" = 200 ] && break; done; echo "realm http=$c"
oc get pods -n $K --no-headers | cut -c1-70
echo "--- durability test: restart db and keycloak"
oc delete pod -n $K -l app=keycloak-pgsql --wait=true; oc delete pod keycloak-0 -n $K --wait=true
oc rollout status deploy/keycloak-pgsql -n $K --timeout=180s; oc wait pod/keycloak-0 -n $K --for=condition=Ready --timeout=300s | tail -1
c=$(curl -s -m 8 -o /dev/null -w '%{http_code}' https://keycloak-maas-keycloak.apps.ocp.5sblg.sandbox3574.opentlc.com/realms/maas/.well-known/openid-configuration); echo "realm after restart http=$c"
oc patch deploy ogx-pg -n lr-smoke --type strategic -p '{"spec":{"strategy":{"type":"Recreate"},"template":{"spec":{"volumes":[{"name":"d","emptyDir":null,"persistentVolumeClaim":{"claimName":"ogx-pg-data"}}]}}}}'
oc rollout status deploy/ogx-pg -n lr-smoke --timeout=180s
oc rollout restart deploy/ogx-smoke -n lr-smoke; oc rollout status deploy/ogx-smoke -n lr-smoke --timeout=240s
sleep 10; oc exec -n lr-smoke wb-running-0 -c wb-running -- curl -s -m 30 -o /dev/null -w 'ogx chat http=%{http_code}\n' http://ogx-smoke-service.lr-smoke.svc:8321/v1/chat/completions -H 'Content-Type: application/json' -d '{"model":"sim/sim","messages":[{"role":"user","content":"hi"}],"max_tokens":5}'
cd /Users/phayes/projects/rhoai-maas-guide && bash manifests/09-external-oidc/test-external-oidc.sh 2>&1 | tail -8 | cut -c1-120
oc get dsc default-dsc -o jsonpath='dsc ready={.status.conditions[?(@.type=="Ready")].status}{"\n"}'
