#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd /Users/phayes/projects/loaded-rhoai/spike
sleep 30
for i in $(seq 1 40); do s=$(oc get co authentication -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}'); [ "$s" = False ] && break; sleep 15; done
echo "authentication progressing=$s after ${i} polls"; oc get co authentication --no-headers | cut -c1-120
DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
python3 login_test.py oauth-openshift.$DOMAIN "$(oc whoami --show-server)" generated/medium/users.json keycloak user0006 user0007 2>&1 | cut -c1-240
oc get groups --no-headers 2>/dev/null | head -5 | cut -c1-90
oc get identity --no-headers 2>/dev/null | head -4 | cut -c1-120
oc get co --no-headers 2>/dev/null | awk '$3!="True"||$4!="False"||$5!="False"' | cut -c1-120
