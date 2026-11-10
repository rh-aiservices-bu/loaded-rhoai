export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
NS=lr-smoke
PG=$(oc get deploy postgres -n redhat-ods-applications -o jsonpath='{.spec.template.spec.containers[0].image}'); echo "pg image $PG"
oc get deploy postgres -n redhat-ods-applications -o json | python3 -c "
import json,sys
c=json.load(sys.stdin)['spec']['template']['spec']['containers'][0]; print([e['name'] for e in c.get('env',[])],[e for e in c.get('envFrom',[])],c.get('volumeMounts'))"
cat > /tmp/ogx-pg.yaml <<YAML
apiVersion: v1
kind: Secret
metadata: {name: ogx-pg, namespace: $NS}
stringData: {POSTGRES_USER: ogx, POSTGRES_PASSWORD: ogx-spike-only, POSTGRES_DB: ogx}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: ogx-pg, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: ogx-pg}}
  template:
    metadata: {labels: {app: ogx-pg}}
    spec:
      containers:
      - name: pg
        image: $PG
        envFrom: [{secretRef: {name: ogx-pg}}]
        env:
        - {name: POSTGRESQL_USER, value: ogx}
        - {name: POSTGRESQL_PASSWORD, value: ogx-spike-only}
        - {name: POSTGRESQL_DATABASE, value: ogx}
        - {name: PGDATA, value: /var/lib/pgsql/data/pgdata}
        ports: [{containerPort: 5432}]
        readinessProbe: {tcpSocket: {port: 5432}}
        resources: {requests: {cpu: 50m, memory: 128Mi}, limits: {memory: 512Mi}}
        volumeMounts: [{name: d, mountPath: /var/lib/pgsql/data}, {name: d, mountPath: /var/lib/postgresql/data}]
      volumes: [{name: d, emptyDir: {}}]
---
apiVersion: v1
kind: Service
metadata: {name: ogx-pg, namespace: $NS}
spec: {selector: {app: ogx-pg}, ports: [{port: 5432}]}
---
apiVersion: ogx.io/v1beta1
kind: OGXServer
metadata: {name: ogx-smoke, namespace: $NS}
spec:
  distribution: {name: rh}
  baseConfig: {name: ogx-base, key: config.yaml}
  providers:
    inference:
      remote:
        vllm:
        - {id: sim, endpoint: "http://isvc-running-predictor.$NS.svc.cluster.local/v1"}
  resources:
    models: [{name: sim, provider: sim}]
  workload:
    replicas: 1
    resources: {requests: {cpu: 200m, memory: 512Mi}, limits: {cpu: "1", memory: 2Gi}}
    overrides:
      env:
      - {name: POSTGRES_HOST, value: ogx-pg}
      - {name: POSTGRES_PORT, value: "5432"}
      - {name: POSTGRES_DB, value: ogx}
      - {name: POSTGRES_USER, value: ogx}
      - {name: POSTGRES_PASSWORD, valueFrom: {secretKeyRef: {name: ogx-pg, key: POSTGRES_PASSWORD}}}
YAML
oc apply -f /tmp/ogx-pg.yaml; rm -f /tmp/ogx-pg.yaml
oc rollout status deploy/ogx-pg -n $NS --timeout=120s
for i in $(seq 1 14); do sleep 15; o=$(oc get ogxserver ogx-smoke -n $NS -o jsonpath='{.status.phase}'); [ "$o" = Ready ] && break; done; echo "ogx=$o"
oc get ogxserver ogx-smoke -n $NS -o json | python3 -c "
import json,sys
[print(c['type'],c['status'],c.get('reason'),c.get('message','')[:150]) for c in json.load(sys.stdin)['status'].get('conditions',[])]"
P=$(oc get pods -n $NS -o name | grep ogx-smoke | grep -v Terminating | tail -1); oc get pods -n $NS --no-headers | grep -E 'ogx' | cut -c1-80; oc logs -n $NS $P --tail=5 2>&1 | cut -c1-200
S=$(oc get svc -n $NS -o name | grep ogx-smoke | head -1); echo $S; oc get $S -n $NS -o jsonpath='{.spec.ports}{"\n"}'
oc exec -n $NS wb-running-0 -c wb-running -- sh -c 'curl -sk -m 20 http://ogx-smoke-service.lr-smoke.svc:8321/v1/models; echo; curl -sk -m 30 http://ogx-smoke-service.lr-smoke.svc:8321/v1/chat/completions -H "Content-Type: application/json" -d "{\"model\":\"sim/sim\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":10}"; echo' 2>&1 | cut -c1-400
