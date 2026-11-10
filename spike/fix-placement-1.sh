#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
date -u +%H:%M:%SZ
oc patch subscription rhcl-operator -n openshift-operators --type merge -p '{"spec":{"config":{"resources":{"requests":{"cpu":"200m","memory":"512Mi"},"limits":{"cpu":"2","memory":"3Gi"}}}}}'
oc scale machineset ocp-5xv6t-worker-us-east-2c-compute -n openshift-machine-api --replicas=1
for i in $(seq 1 56); do
  n=$(oc get nodes -l topology.kubernetes.io/zone=us-east-2c,node-role.kubernetes.io/worker,'!node-role.kubernetes.io/control-plane' --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
  [ "$n" -ge 1 ] && break; sleep 10
done
date -u +%H:%M:%SZ; echo "2c workers ready: $n"
oc get machines -n openshift-machine-api --no-headers | cut -c1-80
oc get nodes --no-headers | cut -c1-90
oc get deploy kuadrant-operator-controller-manager -n openshift-operators -o jsonpath='kuadrant limit={.spec.template.spec.containers[0].resources.limits.memory} avail={.status.availableReplicas}{"\n"}'
