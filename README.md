# loaded-rhoai

Builds a "lived-in" Red Hat OpenShift AI cluster: a pinned RHOAI release, 300 Keycloak users,
hundreds of projects and workbenches, the AI workloads RHOAI ships, and continuous per-user
Models-as-a-Service traffic. Then it validates the result. The design is in [PLAN.md](PLAN.md);
what the spike clusters taught us is in [spike/FINDINGS.md](spike/FINDINGS.md).

**This release deploys RHOAI 3.5.2 only** (`versions/3.5.2/`). Every phase's content was applied to
and validated on a 3.5.2 cluster (OCP 4.22.18 on AWS). The full install hasn't yet been run end to
end on a fresh cluster.

## Before you start

- **Cluster:** OpenShift 4.19.9 or later, logged in as `cluster-admin`, with a default StorageClass
  and either no RHOAI or RHOAI 3.5.2 already installed (it's adopted, not reinstalled).
- **For `medium`:** at least 3 dedicated workers (3 × `m5a.8xlarge` was enough), each with a root
  disk of 240 GiB or more, and an unschedulable control plane. `--fix-topology` makes the control
  plane unschedulable for you; it never adds or resizes nodes.
- **Ingress certificate trusted by your machine:** the Keycloak tools verify TLS.
- **Local tools:** `oc`, `python3` (standard library only), `git`, `curl`, `helm`.
- **Network:** the install clones [rhoai-maas-guide](https://github.com/rh-aiservices-bu/rhoai-maas-guide)
  at a pinned commit into `.cache/`.

## Install

```bash
./loaded-rhoai.sh install --profile medium                       # profile counts: 150 models, 8 running
./loaded-rhoai.sh install --profile medium --models 9 --running-models 7   # exactly the verified cluster
./loaded-rhoai.sh validate
```

Most of the time goes on the population phase. On the spike, creating and stopping 350 workbenches
took about 30 minutes.

| Phase | What it does |
|---|---|
| `00-preflight` | Checks access, OCP version, storage, topology, disks, and any existing RHOAI or RHBK. Changes nothing unless `--fix-topology` |
| `10-operators` | RHCL (with raised memory and `AUTH_SERVICE_TIMEOUT=2s`), LWS, Kueue, JobSet, KEDA, Tempo, OpenTelemetry, COO, MCP Gateway |
| `20-rhoai` | RHOAI at exactly `rhods-operator.3.5.2`, approving only that install plan; JobSet and LWS operand CRs |
| `30-maas` | The guide's phases 2–7: Kuadrant, MaaS gateway, Postgres, DSC, a simulator model, observability and usage logging |
| `35-components` | The remaining DSC components, alerting, and per-user MaaS metrics (`captureUser`) |
| `40-controller-limits` | Raises nine RHOAI controllers' memory limits (sets `opendatahub.io/managed=false` on each) |
| `45-generate` | Reads this release's shipped names (presets, templates, older image tags, the OGX config), then renders users, projects, workloads and variants from profile and seed into `generated/` |
| `50-identity` | Keycloak on a persistent database, users and groups, claim mappers, the OpenShift IdP, one login per user |
| `55-maas-tiers` | Three simulator models behind MaaS, and free, standard and premium tiers on Keycloak groups |
| `58-mcp-gateway` | The MCP Gateway behind an edge-TLS Route, Keycloak or OpenShift tokens required, offered to Gen AI playgrounds |
| `60-population` | MinIO, workbench image pre-pull, the generated shards one at a time, then stopping the workbenches that should be stopped |
| `62-seed` | MLflow experiments and runs in each data team's workspace |
| `63-playgrounds` | Gen AI playgrounds, created by team members through the dashboard's own API |
| `65-settle` | Waits for DSC Ready with no controller restarts for 5 minutes |
| `68-load` | The load generator: 60 users at tier rates plus 2 power users who expect 429s |
| `70-maaspal` | maaspal 1.0.0, headless |
| `90-pin` | Switches every Subscription to Manual approval and compares installed CSVs with `versions/3.5.2/lock.txt` |

Resume after a failure with `--from NN`, or run one phase with `--only NN`. Every phase is safe to
re-run. Settings come from flags, environment variables or `loaded-rhoai.env`; the last install's
settings are kept in `generated/install.env`.

**What the population holds** at `medium`: 300 users in 30 teams, about 370 projects, 350 workbenches,
the models, pipeline servers, Feast stores, Ray clusters, training jobs, Spark applications, TrustyAI,
model registries, 2 OGX servers, 2 EvalHubs, InferenceGraphs, one MLflow server with seeded
experiments, 10 Gen AI playgrounds, 3 MCP servers registered with the gateway, and about 40
**customised variants**: one object per non-default configuration path, each labelled
`loaded-rhoai.io/variant` and carrying effect probes that prove the customisation is in force
(`tools/variants.py`). These are the upgrade canaries.

## Validate

```bash
./loaded-rhoai.sh validate                      # rotating sample of stopped workloads
./loaded-rhoai.sh validate --exhaustive         # every stopped workload through admission
./loaded-rhoai.sh validate --only functional,variants
```

Sections: platform (nodes, operators, Subscriptions, DSC conditions, alerts against
`versions/3.5.2/alert-allowlist.json`), inventory and per-kind status, functional probes (a real
request to every running model, graph, OGX server, EvalHub, MLflow workspace, playground and MCP
server, as the owning user where it matters), startability of stopped workloads, identity and RBAC,
load and per-user MaaS attribution, and every variant's effect probes. Reports go to
`reports/<time>/` as JUnit, a summary and an HTML page.

**Upgrade testing:** a passing run saves a baseline, locally and in `lr-infra/loaded-rhoai-baseline`.
Upgrade RHOAI the usual way, then run `validate` again: it detects the new version and adds an
upgrade section (objects that disappeared, specs the upgrade rewrote, LLMInferenceService presets that
moved, controller restarts). It refuses to run while an upgrade is still in progress.

## Day to day

```bash
./loaded-rhoai.sh status                # version, DSC, object counts, load generator
./loaded-rhoai.sh load status|pause|resume|usage
./loaded-rhoai.sh maaspal plan.json     # e.g. [["load_test", {}], ["usage_metrics_accuracy", {}]]
./loaded-rhoai.sh creds user0042        # a generated user's password
```

`load usage` compares what each load user sent with MaaS's per-user token counters. On the spike
cluster all 62 users matched exactly.

## Known issues on 3.5.2 that this release works around

- RHOAI controllers run out of memory at this scale with default limits (phase 40). Raising them
  needs `opendatahub.io/managed=false`, which matters for upgrade testing (PLAN.md §17 item 22).
- The guide's Keycloak database has no volume, so a restart silently wipes every user (phase 50).
- Notebooks created with the stop annotation lose it and start anyway, so phase 60 stops them after each shard.
- Feast store names must be unique cluster-wide, and TrustyAI and Feast must wait for the trusted
  CA bundle (the generator and `tools/apply_shards.sh` handle both).
- OGX servers need the image's own config and Postgres; the playground default of 4,096 completion
  tokens needs simulators with a larger context; MLflow needs a workspace header; InferenceGraphs
  need full step URLs in their own project; the MCP Gateway needs several OpenShift-specific
  settings. All handled, details in [spike/FINDINGS.md](spike/FINDINGS.md).
- maaspal is **not** registered in the dashboard. Its README's `oc set env` method overwrites the
  operator-owned module list on 3.5.2 and removes 11 shipped dashboard modules.

## Not in this release yet

- **Uninstall and the GitOps path:** deferred.
- **Variants not built yet:** TrustyAI on a database, a pipeline server on an external database,
  Feast with a SQL registry and Redis online store, LLMInferenceService prefill/decode and PVC or OCI
  model sources, OGX and EvalHub custom provider configs, playgrounds with a vector store,
  `OdhDashboardConfig` changes. Gated off on 3.5.2: the pipeline timezone setting (crashes).
- **Workloads:** LMEval, guardrails and the batch gateway; real CPU models; GPU workloads.
- **Validator gaps:** traces and logs end to end, the soak, dashboard-panel checks, UX timing
  (scripts still in `spike/`), and running the validator as an in-cluster Job.

MinIO and the generated connections use fixed test credentials. Use a throwaway cluster.
