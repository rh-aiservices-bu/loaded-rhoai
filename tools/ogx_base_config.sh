#!/usr/bin/env bash
# Extract the OGX distribution's own config.yaml from the image this RHOAI release ships.
# On 3.5.2 an OGXServer that relies on `distribution.name` fails (the operator gets HTTP 401
# reading image labels from registry.redhat.io), so every OGXServer gets this file as
# spec.baseConfig instead (spike/FINDINGS.md). Usage: ogx_base_config.sh <out file>
set -uo pipefail
OUT=$1
NS=lr-infra
IMG=$(oc get deploy ogx-k8s-operator-controller-manager -n redhat-ods-applications -o json | python3 -c "
import json,sys
print(next(e['value'] for c in json.load(sys.stdin)['spec']['template']['spec']['containers'] for e in c.get('env',[]) if e['name']=='RELATED_IMAGE_ODH_OGX_CORE_IMAGE'))") \
  || { echo "OGX operator or its core image not found" >&2; exit 1; }
oc get ns $NS >/dev/null 2>&1 || oc create ns $NS >/dev/null
oc label ns $NS loaded-rhoai.io/managed=true --overwrite >/dev/null
oc delete pod lr-ogx-peek -n $NS --ignore-not-found --wait=true >/dev/null
oc run lr-ogx-peek -n $NS --image="$IMG" --restart=Never \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"lr-ogx-peek","image":"'"$IMG"'","command":["sleep","600"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
  >/dev/null
oc wait pod/lr-ogx-peek -n $NS --for=condition=Ready --timeout=300s >/dev/null || { oc delete pod lr-ogx-peek -n $NS --wait=false >/dev/null; echo "OGX image pod not Ready" >&2; exit 1; }
oc exec -n $NS lr-ogx-peek -- cat /opt/app-root/config.yaml > "$OUT"; rc=$?
oc delete pod lr-ogx-peek -n $NS --wait=false >/dev/null
[ $rc = 0 ] && [ -s "$OUT" ] || { echo "could not read /opt/app-root/config.yaml from $IMG" >&2; exit 1; }
echo "  OGX base config: $(wc -l < "$OUT" | tr -d ' ') lines from ${IMG##*@}"
