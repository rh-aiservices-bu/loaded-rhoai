export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
NS=lr-smoke
oc get ogxserver ogx-smoke -n $NS -o jsonpath='{.status.conditions[0].message}{"\n"}' | fold -w 170
oc explain ogxserver.spec.baseConfig --api-version=ogx.io/v1beta1 | sed -n 8,24p
oc explain ogxserver.spec.overrideConfig --api-version=ogx.io/v1beta1 | sed -n 8,24p
oc logs -n redhat-ods-applications deploy/ogx-k8s-operator-controller-manager --tail=200 2>/dev/null | grep -iE 'oci|unauthor|denied|pull' | tail -3 | cut -c1-300
oc get deploy ogx-k8s-operator-controller-manager -n redhat-ods-applications -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)['spec']['template']['spec']; print('sa',d.get('serviceAccountName'),'pullsecrets',d.get('imagePullSecrets')); print([e['name'] for e in d['containers'][0].get('env',[])][:15])"
oc delete mcpserver weather-mcp -n $NS
oc apply -n $NS -f - <<'YAML'
apiVersion: mcp.x-k8s.io/v1alpha1
kind: MCPServer
metadata: {name: openshift-mcp, namespace: lr-smoke}
spec:
  source: {type: ContainerImage, containerImage: {ref: "registry.redhat.io/openshift-mcp-tech-preview/openshift-mcp-server-rhel9:0.4"}}
  config: {port: 8080, path: /mcp, arguments: [--port, "8080", --read-only]}
  runtime: {replicas: 1, resources: {requests: {cpu: 50m, memory: 128Mi}, limits: {cpu: 300m, memory: 256Mi}}}
YAML
sleep 50
oc get mcpserver openshift-mcp -n $NS -o json | python3 -c "
import json,sys
[print(c['type'],c['status'],c.get('reason'),c.get('message','')[:180]) for c in json.load(sys.stdin)['status']['conditions']]"
oc get pods -n $NS --no-headers | grep mcp | cut -c1-80; oc logs -n $NS deploy/openshift-mcp --tail=4 2>&1 | cut -c1-170
oc get sparkapplication spark-pi -n $NS -o jsonpath='spark={.status.applicationState.state}{"\n"}'; oc logs -n $NS spark-pi-driver 2>/dev/null | grep -m1 'Pi is roughly'
