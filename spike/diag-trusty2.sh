#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
for ns in lr-team-09 lr-team-10; do
  oc get cm odh-trusted-ca-bundle -n $ns --show-managed-fields -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
for m in d['metadata']['managedFields']:
    keys=list(m.get('fieldsV1',{}).get('f:data',{}).keys())
    print('  $ns cm field owner',m['manager'],m['operation'],m['time'],keys)"
  P=$(oc get pods -n $ns -o name | grep trustyai | head -1)
  oc get $P -n $ns -o jsonpath="  $ns pod created={.metadata.creationTimestamp} scheduled={.status.conditions[?(@.type==\"PodScheduled\")].lastTransitionTime}{\"\n\"}"
  oc get events -n $ns --field-selector involvedObject.name=${P#pod/} --sort-by=.firstTimestamp 2>/dev/null | head -4 | cut -c1-170
done
echo "--- delete the pod in lr-team-09 only, keep lr-team-10 as the control"
oc delete $(oc get pods -n lr-team-09 -o name | grep trustyai) -n lr-team-09
for i in $(seq 1 18); do s=$(oc get pods -n lr-team-09 --no-headers | grep trustyai | awk '{print $2,$3}'); echo "$s" | grep -q '2/2 Running' && break; sleep 10; done
echo "lr-team-09 now: $s"; oc get pods -n lr-team-10 --no-headers | grep trustyai | awk '{print "lr-team-10 (untouched): "$2,$3}'
echo "--- does lr-team-09 work?"
oc get trustyaiservice trustyai -n lr-team-09 -o json | python3 -c "
import json,sys
print([(c['type'],c['status'],c.get('reason')) for c in json.load(sys.stdin).get('status',{}).get('conditions',[])])"
oc exec -n lr-team-09 deploy/trustyai -c trustyai-service -- curl -s -m 10 -o /dev/null -w 'trustyai /q/health/ready http=%{http_code}\n' http://localhost:8080/q/health/ready 2>&1 | tail -1
