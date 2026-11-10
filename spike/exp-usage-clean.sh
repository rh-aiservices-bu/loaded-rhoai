#!/usr/bin/env bash
# Per-user token accuracy with no restart: compare the change in both counters between two quiet points.
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")"
N=loaded-rhoai-load; P=$(oc get pods -n $N -o name | grep loadgen | head -1)
snap() {  # $1 label: load generator counters (read directly) and MaaS counters (Thanos, now)
  oc exec -n $N $P -- python3 -c "import urllib.request;print(urllib.request.urlopen('http://localhost:9100/metrics').read().decode())" > logs/lg-$1.txt
  TQ=$(oc get pods -n openshift-monitoring -l app.kubernetes.io/name=thanos-query -o jsonpath='{.items[0].metadata.name}')
  oc exec -n openshift-monitoring $TQ -c thanos-query -- curl -s --max-time 40 'http://localhost:9090/api/v1/query?query=sum%20by%20(user)%20(authorized_hits)' > logs/maas-$1.json
  oc exec -n openshift-monitoring $TQ -c thanos-query -- curl -s --max-time 40 'http://localhost:9090/api/v1/query?query=sum%20by%20(user)%20(limited_calls)' > logs/maaslim-$1.json
}
oc exec -n $N $P -- touch /tmp/pause; echo "[$(date -u +%H:%M:%S)] paused, settling 150 s"; sleep 150; snap a
oc exec -n $N $P -- rm -f /tmp/pause; echo "[$(date -u +%H:%M:%S)] resumed for 8 minutes"; sleep 480
oc exec -n $N $P -- touch /tmp/pause; echo "[$(date -u +%H:%M:%S)] paused, settling 150 s"; sleep 150; snap b
oc exec -n $N $P -- rm -f /tmp/pause; echo "[$(date -u +%H:%M:%S)] resumed"
python3 - <<'PY'
import json,re,collections
def lg(f):
    tok,lim,tier=collections.Counter(),collections.Counter(),{}
    for l in open(f):
        m=dict(re.findall(r'(\w+)="([^"]*)"',l))
        if l.startswith('loadgen_tokens_total'): tok[m['user']]+=float(l.split()[-1]); tier[m['user']]=m['tier']
        elif l.startswith('loadgen_requests_total') and m.get('code')=='429': lim[m['user']]+=float(l.split()[-1])
    return tok,lim,tier
def maas(f): return {s['metric'].get('user'):float(s['value'][1]) for s in json.load(open(f))['data']['result']}
ta,la,_=lg('logs/lg-a.txt'); tb,lb,tier=lg('logs/lg-b.txt')
ma,mb=maas('logs/maas-a.json'),maas('logs/maas-b.json'); qa,qb=maas('logs/maaslim-a.json'),maas('logs/maaslim-b.json')
users=sorted(tb)
d={u:(tb[u]-ta.get(u,0), mb.get(u,0)-ma.get(u,0)) for u in users}
sent=sum(a for a,b in d.values()); seen=sum(b for a,b in d.values())
exact=sum(1 for a,b in d.values() if round(a)==round(b))
print(f"users {len(users)}: tokens sent {int(sent)}, MaaS counted {int(seen)} ({(seen-sent)/sent*100:+.2f}%), exact per user {exact} of {len(users)}")
for x,u,a,b in sorted(((abs(b-a),u,a,b) for u,(a,b) in d.items()),reverse=True)[:5]:
    print(f"  {u} {tier[u]:14} sent={int(a)} maas={int(b)} diff={int(b-a)}")
print("rate-limited, load generator vs MaaS limited_calls:",{u:(int(lb[u]-la.get(u,0)),int(qb.get(u,0)-qa.get(u,0))) for u in lb})
PY
