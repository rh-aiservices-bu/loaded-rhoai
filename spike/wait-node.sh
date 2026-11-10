#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
for i in $(seq 1 90); do
  n=$(oc get nodes --no-headers 2>/dev/null | grep -c 'ip-10-0-66-2.*Ready')
  [ "$n" -ge 1 ] && break; sleep 10
done
date -u +%H:%M:%SZ; echo "joined=$n after $((i*10))s"
oc get machine -n openshift-machine-api --no-headers | grep 2c-compute | cut -c1-80
oc get csr --no-headers 2>/dev/null | grep -ci pending | sed 's/^/pending csrs: /'
oc get nodes --no-headers | cut -c1-90
