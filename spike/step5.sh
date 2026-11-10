export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
P=$(oc get pods -n rhoai-model-registries -o name | grep model-catalog- | grep -v postgres | head -1)
oc exec -n rhoai-model-registries $P -c catalog -- cat /shared-data/redhat-mcp-servers-catalog.yaml > /tmp/mcp.yaml 2>/dev/null
python3 - <<'PY'
import re
t=open('/tmp/mcp.yaml').read()
print(len(t)); print(re.findall(r'^\s*(?:-\s*)?name:\s*(\S+)',t,re.M)[:20])
print(sorted(set(re.findall(r'(?:oci://)?[a-z0-9.\-]+\.(?:io|com)/[^\s"\']+',t)))[:14])
i=t.find('runtimeMetadata'); print(t[i:i+700] if i>0 else t[:900])
PY
rm -f /tmp/mcp.yaml
oc apply -n lr-smoke -f - <<'YAML'
apiVersion: ogx.io/v1beta1
kind: OGXServer
metadata: {name: ogx-smoke, namespace: lr-smoke}
spec:
  distribution: {name: rh-dev}
  providers:
    inference:
      remote:
        vllm:
        - {id: sim, endpoint: "http://isvc-running-predictor.lr-smoke.svc.cluster.local/v1"}
  resources:
    models: [{name: sim, provider: sim}]
  workload:
    replicas: 1
    resources: {requests: {cpu: 200m, memory: 512Mi}, limits: {cpu: "1", memory: 2Gi}}
YAML
sleep 60
oc get ogxserver ogx-smoke -n lr-smoke -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)['status']; print(d.get('phase')); [print(c['type'],c['status'],c.get('reason'),c.get('message','')[:170]) for c in d.get('conditions',[])]"
oc get pods -n lr-smoke --no-headers | grep -i ogx | cut -c1-90
