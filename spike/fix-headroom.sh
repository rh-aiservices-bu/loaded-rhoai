#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
A=redhat-ods-applications
for D in spark-operator-controller ai-gateway-operator; do
  C=$(oc get deploy $D -n $A -o jsonpath='{.spec.template.spec.containers[0].name}')
  oc annotate deploy $D -n $A opendatahub.io/managed=false --overwrite >/dev/null
  oc patch deploy $D -n $A --type strategic -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$C\",\"resources\":{\"limits\":{\"memory\":\"2Gi\"}}}]}}}}" | cut -c1-80
  oc rollout status deploy/$D -n $A --timeout=180s | tail -1 | cut -c1-80
done
