#!/usr/bin/env bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
echo "--- every database-like workload and its storage"
for k in deploy statefulset; do oc get $k -A -o json | python3 -c "
import json,sys,re
for d in json.load(sys.stdin)['items']:
    n=d['metadata']['name'];ns=d['metadata']['namespace']
    s=d['spec']['template']['spec']
    img=' '.join(c.get('image','') for c in s['containers'])
    if not re.search(r'postgres|pgsql|mariadb|mysql|redis|minio|sqlite',n+' '+img,re.I): continue
    if ns.startswith('openshift-') and 'gateway' not in ns: continue
    vols=[('PVC' if 'persistentVolumeClaim' in v else 'emptyDir' if 'emptyDir' in v else None) for v in s.get('volumes',[])]
    vct=len(d['spec'].get('volumeClaimTemplates') or [])
    kind='PVC' if ('PVC' in vols or vct) else 'emptyDir' if 'emptyDir' in vols else 'NONE'
    print(f'{kind:9}{ns}/{n}')
"; done | sort
echo "--- maas data"; P=$(oc get pods -n redhat-ods-applications -o name | grep '^pod/postgres' | head -1); echo $P; oc exec -n redhat-ods-applications $P -- sh -c 'psql -U maas -d maas -tc "select count(*) from api_keys" 2>&1 || true; psql -U maas -d maas -tc "\dt" 2>&1 | head -8' | cut -c1-100
