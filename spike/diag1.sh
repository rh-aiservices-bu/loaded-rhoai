export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
NS=lr-smoke
echo "--- kueue workloads: owners and finalizers"
oc get workloads.kueue.x-k8s.io -n $NS -o json | python3 -c "
import json,sys
for w in json.load(sys.stdin)['items']:
    print(w['metadata']['name'][:50],[o['kind']+'/'+o['name'][:30] for o in w['metadata'].get('ownerReferences',[])],w['metadata'].get('finalizers'))"
echo "--- leftover kueue gates or labels on pods"
oc get pods -n $NS -o json | python3 -c "
import json,sys
for p in json.load(sys.stdin)['items']:
    l=[k for k in p['metadata'].get('labels',{}) if 'kueue' in k]; f=[x for x in p['metadata'].get('finalizers',[]) if 'kueue' in x]; g=p['spec'].get('schedulingGates')
    if l or f or g: print(p['metadata']['name'][:50],l,f,g)"
echo "--- notebook stop"
oc get notebook wb-stopped -n $NS -o json | python3 -c "
import json,sys
d=json.load(sys.stdin);print({k:v for k,v in d['metadata']['annotations'].items() if 'stop' in k});print('ready',d['status'].get('readyReplicas'))"
oc get statefulset wb-stopped -n $NS -o jsonpath='replicas={.spec.replicas}{"\n"}'
echo "--- mcp"
oc get mcpserver weather-mcp -n $NS -o json | python3 -c "
import json,sys
[print(c['type'],c['status'],c.get('reason'),c.get('message','')[:220]) for c in json.load(sys.stdin)['status']['conditions']]"
oc logs -n $NS deploy/weather-mcp --tail=4 2>&1 | cut -c1-160
echo "--- spark"
oc logs -n $NS spark-pi-driver --tail=12 2>&1 | cut -c1-180
oc get sparkapplication spark-pi -n $NS -o jsonpath='{.status.applicationState}{"\n"}' | cut -c1-400
echo "--- dspa not-true conditions"
oc get dspa dspa -n $NS -o json | python3 -c "
import json,sys
[print(c['type'],c['status'],c.get('reason'),c.get('message','')[:160]) for c in json.load(sys.stdin)['status']['conditions'] if c['status']!='True']"
echo "--- isvc probe, correct port"
oc exec -n $NS wb-running-0 -c wb-running -- curl -sk -m 15 -w '\nhttp %{http_code}\n' http://isvc-running-predictor.$NS.svc.cluster.local/v1/models 2>&1 | cut -c1-200
oc get svc isvc-running-predictor -n $NS -o jsonpath='{.spec.ports}{"\n"}'
