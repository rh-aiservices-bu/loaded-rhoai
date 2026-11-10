#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
date -u +%H:%M:%SZ
oc api-resources --api-group=components.platform.opendatahub.io --no-headers 2>/dev/null | awk '{print $1}' | grep -i ogx
R=$(oc api-resources --api-group=components.platform.opendatahub.io --no-headers 2>/dev/null | awk '{print $1}' | grep -i ogx | head -1)
oc get $R.components.platform.opendatahub.io -o json | python3 -c "
import json,sys
for i in json.load(sys.stdin)['items']:
    print(i['metadata']['name'],'phase',i['status'].get('phase'))
    for c in i['status'].get('conditions',[]): print(' ',c['type'],c['status'],c.get('reason'),c.get('lastTransitionTime'),(c.get('message') or '')[:260])"
oc get dsc default-dsc -o jsonpath='dsc ready={.status.conditions[?(@.type=="Ready")].status} modules={.status.conditions[?(@.type=="ModulesReady")].status}{"\n"}'
oc get ogxserver -A --no-headers | cut -c1-80
P=$(oc get pods -n redhat-ods-applications -o name | grep opendatahub-ogx-operator | head -1); oc logs -n redhat-ods-applications $P --tail=15 2>/dev/null | cut -c1-260
oc logs -n redhat-ods-operator deploy/rhods-operator --since=40m 2>/dev/null | grep -iE 'degraded' | tail -4 | cut -c1-300
