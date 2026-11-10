#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
python3 patch_ux4.py; rm -f patch_ux4.py
bash wait-stable.sh 2>&1 | grep -v 'short name' | tail -20 | cut -c1-150
python3 etcd_recent.py 2>&1 | cut -c1-200
bash stage_run.sh expA-357p-152m 1 0
python3 etcd_recent.py 2>&1 | cut -c1-200
