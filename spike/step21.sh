#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
python3 patch_ux3.py; rm patch_ux3.py
N=openshift-operators
oc patch subscription rhcl-operator -n $N --type merge -p '{"spec":{"config":{"selector":{"matchLabels":{"app":"kuadrant"}},"resources":{"requests":{"cpu":"200m","memory":"300Mi"},"limits":{"cpu":"2","memory":"1Gi"}}}}}' 2>&1 | cut -c1-120
for i in $(seq 1 30); do s=$(oc get deploy kuadrant-operator-controller-manager -n $N -o jsonpath='{.status.availableReplicas}'); l=$(oc get deploy kuadrant-operator-controller-manager -n $N -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'); [ "$s" = 1 ] && [ "$l" = 1Gi ] && break; sleep 15; done; echo "kuadrant available=$s limit=$l after $((i*15))s"
oc get deploy -n $N -o custom-columns='N:.metadata.name,MEM:.spec.template.spec.containers[0].resources.limits.memory,CPU:.spec.template.spec.containers[0].resources.limits.cpu,READY:.status.readyReplicas' --no-headers
sleep 240
P=$(oc get pods -n $N -o name | grep kuadrant-operator-controller)
oc get $P -n $N -o jsonpath='restarts={.status.containerStatuses[0].restartCount} ready={.status.containerStatuses[0].ready}{"\n"}'
oc adm top pod ${P#pod/} -n $N --no-headers | cut -c1-80
oc get csv rhcl-operator.v1.4.3 -n $N -o jsonpath='csv {.status.phase}{"\n"}'
oc logs -n $N $P --tail=2 | cut -c1-170
python3 stop_notebooks.py medium | tail -1
bash stage_run.sh stage2-200ns-settled 1 0
