export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
NS=lr-smoke
echo "--- spark"; oc get sparkapplication spark-pi -n $NS -o jsonpath='{.status.applicationState}{"\n"}' | cut -c1-300; oc logs -n $NS spark-pi-driver 2>/dev/null | grep -E 'Exception|ERROR|denied|Caused|Pi is' | head -6 | cut -c1-220; oc get pods -n $NS --no-headers | grep spark | cut -c1-80; oc get events -n $NS --field-selector reason=Failed 2>/dev/null | tail -3 | cut -c1-200
echo "--- ogx base config from image"
IMG=$(oc get deploy ogx-k8s-operator-controller-manager -n redhat-ods-applications -o json | python3 -c "
import json,sys
print([e['value'] for e in json.load(sys.stdin)['spec']['template']['spec']['containers'][0]['env'] if e['name']=='RELATED_IMAGE_ODH_OGX_CORE_IMAGE'][0])")
echo "$IMG"
oc delete pod ogx-peek -n $NS --ignore-not-found --wait=false >/dev/null
oc run ogx-peek -n $NS --image="$IMG" --restart=Never --command -- sleep 600 >/dev/null
oc wait pod/ogx-peek -n $NS --for=condition=Ready --timeout=240s
oc exec -n $NS ogx-peek -- sh -c 'find / -type f \( -name "config.yaml" -o -name "run.yaml" \) 2>/dev/null | grep -vE "^/(proc|sys)" | grep -iE "ogx|distribution|llama|opt" | head -12; env | grep -iE "ogx|config" | head'
