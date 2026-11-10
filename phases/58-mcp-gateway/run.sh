#!/usr/bin/env bash
# MCP Gateway (PLAN.md §6): the gateway, its edge TLS Route, per-user auth, and the entry that
# offers it to Gen AI playgrounds. The MCP servers' HTTPRoutes and registrations, and the virtual
# servers, come with the population (phase 60). Needs the mcp-gateway operator (phase 10).
cd "$(dirname "$0")/../.." && . lib/common.sh
D=$(domain)

log "MCP Gateway"
sed -e "s/__DOMAIN__/$D/g" -e "s/__PORT_NAME__/mcp/" manifests/mcp-gateway/gateway.yaml | oc apply -f - >/dev/null || die "apply MCP gateway"
for i in $(seq 1 40); do
  g=$(oc get gateway mcp-gateway -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')
  e=$(oc get mcpgatewayextension mcp-gateway -n mcp-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  [ "$g" = True ] && [ "$e" = True ] && oc get httproute mcp-gateway-route -n mcp-system >/dev/null 2>&1 && break; sleep 10
done
[ "$g" = True ] && [ "$e" = True ] || die "MCP gateway not ready (gateway programmed=$g, extension ready=$e)"
sed "s/__DOMAIN__/$D/g" manifests/mcp-gateway/auth-and-playground.yaml | oc apply -f - >/dev/null || die "apply MCP auth and playground entry"
for i in $(seq 1 30); do
  [ "$(oc get authpolicy mcp-gateway-users -n mcp-system -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}')" = True ] && break; sleep 10
done
log "  gateway programmed, extension ready, auth policy enforced=$(oc get authpolicy mcp-gateway-users -n mcp-system -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}')"
# The gateway's Service is ClusterIP, so no DNS record should exist for it. If one was created
# while it was a LoadBalancer, it shadows *.apps with a dead address (3.5.2 spike).
for r in $(oc get dnsrecord -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=mcp-gateway -o name 2>/dev/null); do
  oc delete "$r" -n openshift-ingress >/dev/null && warn "removed stale $r"
done
log "phase 58 done"
