#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
python3 patch_ux2.py; rm patch_ux2.py
oc get pods -n redhat-ods-applications --no-headers | grep -E 'rhods-dashboard' | cut -c1-70
oc get nodes --no-headers | awk '{print $2}' | sort | uniq -c
oc get dsc default-dsc -o jsonpath='dsc ready={.status.conditions[?(@.type=="Ready")].status}{"\n"}'
bash stage_run.sh stage2-200ns 4 8
