#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd /Users/phayes/projects/loaded-rhoai/spike
oc get auth.services.platform.opendatahub.io auth -o jsonpath='auth before {.spec}{"\n"}' 2>&1 | cut -c1-200
oc patch auth.services.platform.opendatahub.io auth --type merge -p '{"spec":{"adminGroups":["rhods-admins","rhoai-admins"],"allowedGroups":["system:authenticated"]}}' 2>&1 | cut -c1-160
oc get route -A --no-headers 2>/dev/null | grep -iE 'dashboard|data-science-gateway' | cut -c1-130
python3 -m venv .venv >/dev/null && .venv/bin/pip -q install playwright 2>&1 | tail -1 | cut -c1-120
.venv/bin/playwright install chromium 2>&1 | tail -1 | cut -c1-120
.venv/bin/python -c "import playwright; print('playwright', playwright.__version__)"
