#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd /Users/phayes/projects/loaded-rhoai/spike
python3 patch_ux.py; rm patch_ux.py
oc adm policy add-cluster-role-to-group cluster-reader rhoai-admins 2>&1 | tail -1 | cut -c1-100
bash stage_run.sh stage0-admin-2projects 0 -1 admin
python3 - <<'PY' > /tmp/lr-b
import json;print(' '.join(json.load(open('generated/medium/buckets.json'))))
PY
oc exec -n lr-infra deploy/minio -- sh -c "mc alias set l http://localhost:9000 lrminio lrminio-spike-only >/dev/null; for b in $(cat /tmp/lr-b); do mc mb -p l/\$b; done" 2>&1 | tail -2 | cut -c1-90; rm -f /tmp/lr-b
bash stage_run.sh stage1-75ns 0 3
