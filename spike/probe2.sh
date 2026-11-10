#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
NS=lr-smoke; T=$(oc whoami -t)
ex() { oc exec -n $NS wb-running-0 -c wb-running -- "$@"; }
echo "--- model registry write+read"
R=$(oc get route lr-registry-https -n rhoai-model-registries -o jsonpath='{.spec.host}')
curl -sk -m 20 -X POST "https://$R/api/model_registry/v1alpha3/registered_models" -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"name":"lr-smoke-model","description":"smoke"}' -w ' http=%{http_code}\n' | cut -c1-180
curl -sk -m 20 "https://$R/api/model_registry/v1alpha3/registered_models" -H "Authorization: Bearer $T" | python3 -c "import json,sys;d=json.load(sys.stdin);print('models',d.get('size'),[i['name'] for i in d.get('items',[])])"
echo "--- pipeline run"
D=$(oc get route ds-pipeline-dspa -n $NS -o jsonpath='{.spec.host}')
curl -sk -m 20 "https://$D/apis/v2beta1/pipelines" -H "Authorization: Bearer $T" | python3 -c "
import json,sys
d=json.load(sys.stdin); print([p['display_name'] for p in d.get('pipelines',[])]); open('/tmp/lr-pid','w').write(d['pipelines'][0]['pipeline_id'])"
PID=$(cat /tmp/lr-pid); VID=$(curl -sk -m 20 "https://$D/apis/v2beta1/pipelines/$PID/versions" -H "Authorization: Bearer $T" | python3 -c "import json,sys;print(json.load(sys.stdin)['pipeline_versions'][0]['pipeline_version_id'])")
EXP=$(curl -sk -m 20 "https://$D/apis/v2beta1/experiments" -H "Authorization: Bearer $T" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('experiments',[{}])[0].get('experiment_id',''))")
RUN=$(curl -sk -m 30 -X POST "https://$D/apis/v2beta1/runs" -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d "{\"display_name\":\"smoke-run\",\"pipeline_version_reference\":{\"pipeline_id\":\"$PID\",\"pipeline_version_id\":\"$VID\"},\"experiment_id\":\"$EXP\"}" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('run_id') or d)")
echo "run=$RUN"; echo "$RUN" > /Users/phayes/projects/loaded-rhoai/spike/logs/pipeline-run-id; rm -f /tmp/lr-pid
echo "--- mlflow"; oc get svc -n redhat-ods-applications --no-headers | grep -i mlflow | cut -c1-90
ex curl -sk -m 15 -w ' http=%{http_code}\n' -H "Authorization: Bearer $T" -H 'X-MLFLOW-WORKSPACE: lr-smoke' 'https://mlflow.redhat-ods-applications.svc:8443/api/2.0/mlflow/experiments/search?max_results=5' 2>&1 | cut -c1-200
echo "--- feast"; oc get svc -n $NS --no-headers | grep -i feast | cut -c1-90
ex curl -s -m 10 -w ' http=%{http_code}\n' http://feast-fs-smoke-online.$NS.svc:80/health 2>&1 | cut -c1-120
echo "--- trustyai"; oc get svc -n $NS --no-headers | grep -i trusty | cut -c1-90
ex curl -s -m 10 -o /dev/null -w 'info http=%{http_code}\n' http://trustyai-service.$NS.svc:80/q/health 2>&1
echo "--- evalhub"; oc get svc -n $NS --no-headers | grep -i evalhub | cut -c1-90; oc get evalhub evalhub -n $NS -o jsonpath='{.status.url}{"\n"}'
echo "--- ray"; H=$(oc get pods -n lr-smoke-queued -l ray.io/node-type=head -o name | head -1); oc exec -n lr-smoke-queued $H -c ray-head -- ray status 2>&1 | grep -E 'Healthy|node_|CPU' | head -5 | cut -c1-80
echo "--- start cycle: workbench"
oc annotate notebook wb-stopped -n $NS kubeflow-resource-stopped-
for i in $(seq 1 24); do r=$(oc get notebook wb-stopped -n $NS -o jsonpath='{.status.readyReplicas}'); [ "$r" = 1 ] && break; sleep 10; done; echo "wb-stopped readyReplicas=$r after $((i*10))s"
oc exec -n $NS wb-stopped-0 -c wb-stopped -- curl -s -o /dev/null -w 'api http=%{http_code}\n' http://localhost:8888/notebook/$NS/wb-stopped/api
oc annotate notebook wb-stopped -n $NS kubeflow-resource-stopped="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
echo "--- start cycle: isvc"
oc annotate isvc isvc-stopped -n $NS serving.kserve.io/stop=false --overwrite
for i in $(seq 1 18); do r=$(oc get isvc isvc-stopped -n $NS -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'); [ "$r" = True ] && break; sleep 10; done; echo "isvc-stopped Ready=$r after $((i*10))s"
ex curl -s -m 10 -o /dev/null -w 'isvc http=%{http_code}\n' http://isvc-stopped-predictor.$NS.svc.cluster.local/v1/models
oc annotate isvc isvc-stopped -n $NS serving.kserve.io/stop=true --overwrite
