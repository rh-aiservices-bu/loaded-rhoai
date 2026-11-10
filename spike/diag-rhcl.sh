#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
date -u +%H:%M:%SZ
oc get csv rhcl-operator.v1.4.3 -n openshift-operators -o json | python3 -c "
import json,sys
s=json.load(sys.stdin)['status']; print(s['phase'],s.get('reason'),(s.get('message') or '')[:200],s.get('lastTransitionTime'))
for c in s.get('conditions',[])[-5:]: print(' ',c.get('lastTransitionTime'),c['phase'],c.get('reason'),(c.get('message') or '')[:130])"
oc get deploy -n openshift-operators --no-headers | cut -c1-80
oc get pods -n openshift-operators --no-headers | cut -c1-85
oc get events -n openshift-operators --sort-by=.lastTimestamp 2>/dev/null | tail -6 | cut -c1-180
oc get kuadrant kuadrant -n kuadrant-system -o jsonpath='kuadrant ready={.status.conditions[?(@.type=="Ready")].status}{"\n"}'
oc get pods -n kuadrant-system --no-headers | cut -c1-70
H=maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'); curl -sk -m 15 -o /dev/null -w "maas health http=%{http_code}\n" https://$H/maas-api/health
oc get dsc default-dsc -o jsonpath='dsc ready={.status.conditions[?(@.type=="Ready")].status}{"\n"}'
