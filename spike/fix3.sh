export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
NS=lr-smoke
oc delete sparkapplication spark-pi -n $NS
oc apply -n $NS -f - <<'YAML'
apiVersion: sparkoperator.k8s.io/v1beta2
kind: SparkApplication
metadata: {name: spark-pi, namespace: lr-smoke}
spec:
  type: Scala
  mode: cluster
  sparkVersion: "4.0.1"
  image: docker.io/library/spark:4.0.1
  mainClass: org.apache.spark.examples.SparkPi
  mainApplicationFile: local:///opt/spark/examples/jars/spark-examples.jar
  arguments: ["100"]
  sparkConf: {spark.jars.ivy: /tmp/.ivy2, spark.kubernetes.driverEnv.HOME: /tmp, spark.executorEnv.HOME: /tmp}
  volumes: [{name: work, emptyDir: {}}]
  driver:
    cores: 1
    memory: 1g
    serviceAccount: spark
    volumeMounts: [{name: work, mountPath: /opt/spark/work-dir}]
  executor:
    cores: 1
    instances: 1
    memory: 1g
    volumeMounts: [{name: work, mountPath: /opt/spark/work-dir}]
YAML
echo "--- mcp catalog"
oc get cm mcp-catalog-sources -n redhat-ods-applications -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)['data']
for k,v in d.items(): print('KEY',k,len(v)); print(v[:700])"
oc get cm -A 2>/dev/null | grep -iE 'mcp.*(catalog|registry)|catalog.*mcp' | cut -c1-100
echo "--- catalog pods"; oc get pods -n rhoai-model-registries --no-headers | cut -c1-70
echo "--- kueue label check"
oc get pods -n $NS -o json | python3 -c "
import json,sys
for p in json.load(sys.stdin)['items']:
    if any('kueue' in k for k in p['metadata'].get('labels',{})): print(p['metadata']['name'],p['status']['phase'],p['metadata'].get('deletionTimestamp'))"
oc get pods -n $NS --no-headers | grep -vE ' Running ' | cut -c1-90
oc get workloads.kueue.x-k8s.io -n $NS --no-headers 2>/dev/null | wc -l
