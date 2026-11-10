#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
python3 api_health.py 2>&1 | cut -c1-215
echo "--- ray/trustyai"; oc get dsc default-dsc -o json | python3 -c "
import json,sys
for c in json.load(sys.stdin)['status']['conditions']:
    if c['type'] in ('RayReady','TrustyAIReady','Ready'): print(c['type'],c['status'],c.get('reason'),c.get('lastTransitionTime'),(c.get('message') or '')[:170])"
oc get pods -n openshift-kube-apiserver --no-headers | grep -E '^kube-apiserver-ip' | awk '{print $1,$3,$4,$5,$6}' | cut -c1-80
oc get pods -n openshift-etcd --no-headers | grep -E '^etcd-ip' | awk '{print $1,$3,$4,$5,$6}' | cut -c1-80
oc get machines -n openshift-machine-api -o custom-columns=N:.metadata.name,T:.spec.providerSpec.value.instanceType,V:.spec.providerSpec.value.blockDevices[0].ebs.volumeType,S:.spec.providerSpec.value.blockDevices[0].ebs.volumeSize,I:.spec.providerSpec.value.blockDevices[0].ebs.iops --no-headers 2>&1 | cut -c1-90
