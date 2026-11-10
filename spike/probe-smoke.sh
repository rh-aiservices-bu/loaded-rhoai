#!/usr/bin/env bash
# Functional probes for the smoke workloads: each sends a real request where possible.
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
NS=lr-smoke
ex() { oc exec -n $NS wb-running-0 -c wb-running -- "$@"; }
echo "--- trainjob"; oc get trainjob train-smoke -n $NS -o json | python3 -c "import json,sys;print([(c['type'],c['status']) for c in json.load(sys.stdin)['status'].get('conditions',[])])"
oc get pods -n $NS -l trainer.kubeflow.org/trainjob-name=train-smoke -o name | head -1 | xargs -I{} oc logs -n $NS {} --tail=2
echo "--- notebook"; ex curl -s -o /dev/null -w 'api %{http_code}\n' http://localhost:8888/notebook/$NS/wb-running/api
oc get notebook -n $NS -o custom-columns=N:.metadata.name,STOP:.metadata.annotations.kubeflow-resource-stopped --no-headers
oc get pods -n $NS --no-headers | grep -c wb-stopped | sed 's/^/stopped workbench pods: /'
echo "--- isvc"; oc get isvc -n $NS --no-headers | cut -c1-110; oc get svc -n $NS --no-headers | grep -E 'isvc|graph' | cut -c1-90
for u in http://isvc-running-predictor.$NS.svc:8080/v1/models https://isvc-running-predictor.$NS.svc:8443/v1/models; do echo "$u -> $(ex curl -sk -m 10 -o /dev/null -w '%{http_code}' $u)"; done
echo "--- graph"; oc get inferencegraph -n $NS -o json | python3 -c "import json,sys;[print(i['metadata']['name'],i['status'].get('url'),[(c['type'],c['status']) for c in i['status'].get('conditions',[])]) for i in json.load(sys.stdin)['items']]"
echo "--- dspa"; oc get dspa dspa -n $NS -o json | python3 -c "import json,sys;print([(c['type'],c['status']) for c in json.load(sys.stdin)['status']['conditions']])"; oc get pipelines.pipelines.kubeflow.org -n $NS --no-headers 2>&1 | head -3
echo "--- others"; oc get mcpserver,featurestore,trustyaiservice,evalhub,raycluster,sparkapplication -n $NS 2>&1 | cut -c1-130
oc get modelregistry -n rhoai-model-registries 2>&1 | cut -c1-120; oc get modelregistry lr-registry -n rhoai-model-registries -o json | python3 -c "import json,sys;print([(c['type'],c['status']) for c in json.load(sys.stdin)['status'].get('conditions',[])])"
oc get mlflow mlflow -o json | python3 -c "import json,sys;print('mlflow',[(c['type'],c['status'],c.get('message','')[:80]) for c in json.load(sys.stdin)['status'].get('conditions',[])])"
echo "--- pods not running"; oc get pods -n $NS --no-headers | grep -vE ' (Running|Completed) ' | cut -c1-100
oc get pods -n rhoai-model-registries --no-headers | cut -c1-90; oc get pods -A --no-headers | grep -i mlflow | cut -c1-110
echo "--- workload"; oc get workloads.kueue.x-k8s.io -n $NS 2>&1 | cut -c1-120
