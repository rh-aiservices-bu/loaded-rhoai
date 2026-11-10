export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
NS=lr-smoke
oc rollout restart deploy -n $NS | wc -l
oc delete pod wb-running-0 -n $NS --wait=false
for i in $(seq 1 18); do b=$(oc get pods -n $NS -o json | python3 -c "
import json,sys
print(sum(1 for p in json.load(sys.stdin)['items'] if any('kueue' in k for k in p['metadata'].get('labels',{}))))"); [ "$b" = 0 ] && break; sleep 10; done; echo "pods still with kueue labels: $b"
for w in $(oc get workloads.kueue.x-k8s.io -n $NS -o name); do oc patch $w -n $NS --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null; done
oc get workloads.kueue.x-k8s.io -n $NS --no-headers 2>/dev/null | wc -l | sed 's/^/workloads left: /'
echo "--- spark root cause"; oc logs -n $NS spark-pi-driver 2>&1 | grep -m3 -E 'Exception|denied|Caused' | cut -c1-220
oc get pod spark-pi-driver -n $NS -o jsonpath='scc={.metadata.annotations.openshift\.io/scc} uid={.spec.containers[0].securityContext.runAsUser}{"\n"}'
echo "--- mcp alternatives"; oc patch mcpserver weather-mcp -n $NS --type merge -p '{"spec":{"mcp":{"stateless":false}}}'
oc get cm -A -o name 2>/dev/null | grep -i mcp | head -8
oc get crd mcpservers.mcp.x-k8s.io -o json | python3 -c "
import json,sys
s=[v for v in json.load(sys.stdin)['spec']['versions'] if v.get('storage')][0]['schema']['openAPIV3Schema']['properties']['spec']['properties']['mcp']
print(json.dumps(s)[:700])"
sleep 45
oc get mcpserver weather-mcp -n $NS -o json | python3 -c "
import json,sys
[print(c['type'],c['status'],c.get('reason'),c.get('message','')[:200]) for c in json.load(sys.stdin)['status']['conditions']]"
