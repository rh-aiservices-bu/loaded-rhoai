export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
oc get cm mcp-catalog-sources -n rhoai-model-registries -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)['data']
for k,v in d.items(): print('KEY',k,len(v)); print(v[:500])"
oc get pods -n rhoai-model-registries -l component=model-catalog -o name | head -1
P=$(oc get pods -n rhoai-model-registries -o name | grep model-catalog- | grep -v postgres | head -1)
oc exec -n rhoai-model-registries $P -c catalog -- sh -c 'ls /shared-data /data /catalog 2>/dev/null; grep -rl "oci://\|containerImage\|quay.io" /shared-data 2>/dev/null | head' 2>&1 | cut -c1-200 | head -20
oc get route -n rhoai-model-registries --no-headers | cut -c1-110
oc get sparkapplication spark-pi -n lr-smoke -o jsonpath='spark={.status.applicationState.state}{"\n"}'
oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications -o json | python3 -c "
import json,sys
c=json.load(sys.stdin)['spec']['dashboardConfig']; print({k:v for k,v in c.items() if k in ('mcpCatalog','mcpRegistry','genAiStudio','modelAsService','observabilityDashboard','mlflow','trainingJobs','guardrails','disableMCP')})"
oc explain ogxserver.spec.providers.inference.remote.vllm --api-version=ogx.io/v1beta1 | sed -n 8,50p
oc get crd ogxservers.ogx.io -o json | python3 -c "
import json,sys
v=[x for x in json.load(sys.stdin)['spec']['versions'] if x.get('storage')][0]
print([r.get('rule')[:120] for r in v['schema']['openAPIV3Schema']['properties']['spec'].get('x-kubernetes-validations',[])])"
oc logs -n redhat-ods-applications deploy/ogx-k8s-operator-controller-manager --tail=1 2>&1 | cut -c1-120
oc get deploy -n redhat-ods-applications -o name | grep -iE 'ogx|llama'
P=$(oc get pods -n redhat-ods-applications -o name | grep -iE 'ogx.*controller|ogx-k8s' | head -1); echo "op pod: $P"; oc exec -n redhat-ods-applications $P -- sh -c 'cat /distributions.json 2>/dev/null || find / -name "distributions.json" 2>/dev/null | head -2' 2>&1 | cut -c1-500
