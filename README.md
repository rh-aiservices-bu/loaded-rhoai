# loaded-rhoai

Builds a "lived-in" Red Hat OpenShift AI cluster: a pinned RHOAI release, 300 Keycloak users,
hundreds of projects and workbenches, the AI workloads RHOAI ships, and continuous per-user
Models-as-a-Service traffic. Then it validates the result. The design is in [PLAN.md](PLAN.md);
what the spike clusters taught us is in [spike/FINDINGS.md](spike/FINDINGS.md).

**This release deploys RHOAI 3.5.2** (`versions/3.5.2/`) and tests upgrading it to 3.6 EA2. The full
install has been run end to end on a fresh cluster (OCP 4.22.22 on AWS) and validated: 275 checks
pass on 3.5.2, and 2 fail on a real MaaS gateway fault (see [spike/FINDINGS.md](spike/FINDINGS.md)).

## Before you start

- **Cluster:** OpenShift 4.19.9 or later, logged in as `cluster-admin`, with a default StorageClass
  and either no RHOAI or RHOAI 3.5.2 already installed (it's adopted, not reinstalled).
- **For `medium`:** 3 dedicated workers, one per zone, each with a root disk of 240 GiB or more,
  and an unschedulable control plane. `--fix-topology` makes the control plane unschedulable; it
  never adds or resizes nodes. Use **Intel workers** (3 × `m6i.8xlarge` is verified): the real vLLM
  CPU models need AVX-512, which AMD `m5a` instances don't have.
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
experiments, 10 Gen AI playgrounds, 3 MCP servers registered with the gateway, two **real vLLM CPU
models** (an InferenceService from the shipped template and an LLMInferenceService using the preset's
configuration, both Qwen2.5-0.5B), and about 45 **customised variants**: one object per non-default
configuration path, each labelled `loaded-rhoai.io/variant` and carrying effect probes that prove the
customisation is in force (`tools/variants.py`). They include fixed scheduler configurations: one
written in an older format with a full pinned argument list, one in the current format. These are
the upgrade canaries.

## Validate

```bash
./loaded-rhoai.sh validate --expect-rhoai 3.5.2     # fails if RHOAI isn't at that release
./loaded-rhoai.sh validate --exhaustive             # every stopped workload through admission
./loaded-rhoai.sh validate --only functional,api    # some sections
./loaded-rhoai.sh validate --maaspal-plan plan.json # add a maaspal run to the maas section
```

| Section | What it checks |
|---|---|
| `platform` | Nodes, cluster operators, Subscriptions, the expected RHOAI release, DSC and DSCI conditions including `Degraded`, every component CR's Ready and Degraded, firing alerts in both Prometheus stacks against `versions/<release>/alert-allowlist.json` |
| `upgrade` | After an upgrade, the comparison with the baseline (below) |
| `inventory`, `status` | Every expected object exists and is in its expected state; a kind without a status check fails |
| `functional` | A real request to every running model, graph, OGX server, EvalHub, MLflow workspace, playground and MCP server, as the owning user where it matters |
| `api` | Streaming and non-streaming chat, and requests with invalid parameters (temperature -1, top_p 1.5, max_tokens -1, unknown model, malformed JSON), against the real vLLM models and through the MaaS gateway per tier. A gateway that hangs or fails on a client error fails the check |
| `startability` | Stopped workloads' images, PVCs and runtimes still exist, and a "start" passes admission (dry run) |
| `identity` | Users logged in, group membership synced, RoleBinding subjects exist, admins can see every project |
| `load` | The load generator's users are all sending, without unexpected errors, and MaaS attributes usage to each |
| `maas` | The guide's verify and OIDC scripts, and a fresh API key per tier that binds to the right subscription, lists its models and answers a chat |
| `variants` | Every variant's effect probes; variants gated off for the release are listed with the reason |

Reports go to `reports/<time>/` as JUnit, a summary and an HTML page.

### Sample results: RHOAI 3.5.2

A full validation of a fresh `medium` install (`--models 9 --running-models 7`) on OCP 4.22.22 with
3 × `m6i.8xlarge` workers, 2026-11-12:

```text
  platform                     pass    27  fail   0  warn   0  skip   0
  upgrade                      pass     1  fail   0  warn   0  skip   0
  inventory                    pass    41  fail   0  warn   0  skip   0
  status                       pass    21  fail   0  warn   0  skip   0
  functional                   pass    46  fail   0  warn   0  skip   0
  api                          pass    27  fail   2  warn   6  skip   0
  startability                 pass     9  fail   0  warn   0  skip   0
  identity                     pass     4  fail   0  warn   0  skip   0
  load                         pass     3  fail   0  warn   0  skip   0
  maas                         pass    29  fail   0  warn   0  skip   1
  variants                     pass    67  fail   0  warn   1  skip   0

  TOTAL                        pass   275  fail   2  warn   7  skip   1

  FAIL [api] MaaS gateway, maas-free (chat-a): answers max_tokens -1 promptly with a client error:
       http 0 Remote end closed connection without response after 59.33 s
  FAIL [api] MaaS gateway, maas-standard (chat-a): answers max_tokens -1 promptly with a client error:
       http 0 Remote end closed connection without response after 59.96 s
  WARN [api] MaaS gateway, <each tier> (chat-a): temperature -1 / top_p 1.5: http 200 (the simulator accepted it)
  WARN [variants] dspa-timezone (gated off for this release): scheduledworkflow fails with
       'unknown time zone Europe/Dublin' on 3.5.2 (no tzdata in the image)
```

**These failures are expected on 3.5.2.** They're real product behaviour that the validator is
meant to catch, not problems with the install, and the run is saved as the baseline with them included:

- **The 2 failures** are a MaaS gateway fault on this release's Connectivity Link (RHCL 1.4.3). A
  chat with `max_tokens: -1` makes the model return a 400, but on the free and standard tiers the
  gateway never delivers it: the client waits about 60 seconds and the connection closes with no
  response. Premium returns the 400 at once. It reproduces every time, and looks like the same class of
  fault as a non-streaming hang fixed in RHCL 1.5 and 1.4.4 (PLAN.md §17 item 30).
- **The warnings** aren't faults. Six are the MaaS simulator models accepting out-of-range
  `temperature` and `top_p`, which says nothing about the product (the real vLLM models reject them with
  400s, and those checks pass). The seventh is a variant switched off for 3.5.2 because the pipelines
  timezone setting crashes its controller.
- **The skip** is the optional maaspal run, which wasn't requested.

Because the baseline records these results, validating after an upgrade reports whether each failure
was fixed, is still present, or whether new ones appeared.

**Upgrade testing.** Every complete run on an unchanged release saves a **baseline**, failures
included, locally and in `lr-infra` (`loaded-rhoai-baseline`, `loaded-rhoai-baseline-schemas`). It
records every object's spec and generation, the images each model is running, each LLMInferenceService's
resolved presets, runtime-copy versions, the CRD schemas of the platform and of every kind we create,
and every check's result. After an upgrade, `validate` detects the new release and reports what the
upgrade changed: objects lost, specs rewritten, fields removed or retyped in the CRDs (calling out the
ones our objects set), presets and images that moved, runtime copies left behind their template,
controller restarts, and which failing checks the upgrade fixed, kept or introduced. It refuses to run
while an upgrade is in progress.

```bash
./loaded-rhoai.sh validate --expect-rhoai 3.5.2          # baseline on the starting release
bash tools/reinstall_rhoai.sh beta rhods-operator.3.6     # 3.5 -> 3.6 EA has no OLM upgrade edge: reinstall
./loaded-rhoai.sh validate --expect-rhoai 3.6.0-ea.2      # the cluster as the upgrade left it
./loaded-rhoai.sh upgrade-touch                           # change a few LLMInferenceServices' specs
./loaded-rhoai.sh validate --expect-rhoai 3.6.0-ea.2      # did a spec change move them to the new release?
```

`tools/reinstall_rhoai.sh` deletes only the RHOAI Subscription and CSV (the DSC, CRDs and workloads
stay), subscribes to the new channel with Manual approval, approves only the expected plan, and records
the state and load-generator counts before and after. It applies no fixes.

## Day to day

```bash
./loaded-rhoai.sh status                # version, DSC, object counts, load generator
./loaded-rhoai.sh load status|pause|resume|usage
./loaded-rhoai.sh maaspal plan.json     # e.g. [["load_test", {}], ["usage_metrics_accuracy", {}]]
./loaded-rhoai.sh creds user0042        # a generated user's password
./loaded-rhoai.sh upgrade-touch         # after an upgrade (see above)
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
- **Workloads:** LMEval, guardrails and the batch gateway; GPU workloads; a workload that brings its
  own service mesh (OSSM conflicts).
- **Validator gaps:** traces and logs end to end; Perses dashboard and panel checks; restart and
  OOM checks across Kuadrant, gateways and MCP on every run; a check that raised memory limits are
  still in force; a reconcile-loop detector; product-generated objects (TelemetryPolicy, dashboards) in
  the upgrade baseline; post-upgrade actions that actually start a stopped model and onboard a new
  one; dashboard smoke tests per persona (UX scripts are still in `spike/`); running the validator as
  an in-cluster Job. Most of these come from a customer engagement's issue log (PLAN.md §17 item 29).

MinIO and the generated connections use fixed test credentials. Use a throwaway cluster.
