export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
NS=lr-smoke
D=/Users/phayes/projects/loaded-rhoai/spike
oc exec -n $NS ogx-peek -- cat /opt/app-root/config.yaml > $D/ogx-base-config.yaml
wc -l $D/ogx-base-config.yaml
oc delete pod ogx-peek -n $NS --wait=false
oc create configmap ogx-base -n $NS --from-file=config.yaml=$D/ogx-base-config.yaml --dry-run=client -o yaml | oc apply -f -
oc label configmap ogx-base -n $NS ogx.io/watch=true --overwrite
oc delete ogxserver ogx-smoke -n $NS --ignore-not-found
oc apply -n $NS -f - <<'YAML'
apiVersion: ogx.io/v1beta1
kind: OGXServer
metadata: {name: ogx-smoke, namespace: lr-smoke}
spec:
  distribution: {name: rh}
  baseConfig: {name: ogx-base, key: config.yaml}
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
  sparkConf:
    spark.jars.ivy: /tmp/.ivy2
    spark.kubernetes.driverEnv.HOME: /tmp
    spark.executorEnv.HOME: /tmp
    spark.kubernetes.driver.volumes.emptyDir.work.mount.path: /opt/spark/work-dir
    spark.kubernetes.executor.volumes.emptyDir.work.mount.path: /opt/spark/work-dir
  driver: {cores: 1, memory: 1g, serviceAccount: spark}
  executor: {cores: 1, instances: 1, memory: 1g}
YAML
for i in $(seq 1 12); do sleep 15; s=$(oc get sparkapplication spark-pi -n $NS -o jsonpath='{.status.applicationState.state}'); o=$(oc get ogxserver ogx-smoke -n $NS -o jsonpath='{.status.phase}'); case "$s" in COMPLETED|FAILED) [ "$o" = Ready ] && break;; esac; done
echo "spark=$s"; oc logs -n $NS spark-pi-driver 2>/dev/null | grep -E 'Pi is roughly|Exception' | head -3 | cut -c1-200
echo "ogx=$o"; oc get ogxserver ogx-smoke -n $NS -o json | python3 -c "
import json,sys
[print(c['type'],c['status'],c.get('reason'),c.get('message','')[:170]) for c in json.load(sys.stdin)['status'].get('conditions',[])]"
oc get pods -n $NS --no-headers | grep -iE 'ogx|spark' | cut -c1-80
