#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
echo "--- feast cluster-scoped RBAC"
oc get clusterrolebinding,clusterrole -o name | grep -i feast
oc get clusterrolebinding feast-features-cluster-binding --show-managed-fields -o json | python3 -c "
import json,sys
d=json.load(sys.stdin); m=d['metadata']
print('roleRef',d['roleRef']); print('subjects',d.get('subjects')); print('owners',m.get('ownerReferences')); print('labels',m.get('labels'))
print('created',m['creationTimestamp'],'resourceVersion',m['resourceVersion'])
for f in m.get('managedFields',[]): print(' field owner',f['manager'],f['operation'],f['time'])"
R=$(oc get clusterrolebinding feast-features-cluster-binding -o jsonpath='{.roleRef.name}')
oc get clusterrole $R -o json | python3 -c "
import json,sys
d=json.load(sys.stdin); print('clusterrole',d['metadata']['name'],'rules:'); [print('  ',r.get('apiGroups'),r.get('resources'),r.get('verbs')) for r in d.get('rules',[])]"
echo "--- each feature store: status and its service account"
for ns in lr-team-07 lr-team-08 lr-team-09; do
  oc get featurestore features -n $ns -o json | python3 -c "
import json,sys
d=json.load(sys.stdin); s=d.get('status',{})
print('$ns phase',s.get('phase'),'uid',d['metadata']['uid'][:8],'feastProject',d['spec']['feastProject'],[(c['type'],c['status']) for c in s.get('conditions',[]) if c['status']!='True'])"
  oc get deploy -n $ns -l feast.dev/name=features -o jsonpath='  sa={.items[0].spec.template.spec.serviceAccountName}{"\n"}' 2>/dev/null
  oc get rolebinding -n $ns -o name | grep -i feast | tr '\n' ' '; echo
done
echo "--- operator log for the conflict"
P=$(oc get pods -n redhat-ods-applications -o name | grep 'feast-operator-controller-manager' | head -1); echo "pod $P"
oc logs -n redhat-ods-applications $P --since=4h 2>/dev/null | grep -iE 'cluster-binding|conflict|lr-team-07' | head -6 | cut -c1-300
oc logs -n redhat-ods-applications $P --since=4h 2>/dev/null | grep -ciE 'lr-team-07' | sed 's/^/log lines mentioning lr-team-07: /'
oc logs -n redhat-ods-applications $P --since=30m 2>/dev/null | grep -ciE 'Reconcil' | sed 's/^/reconcile log lines in last 30 min: /'
