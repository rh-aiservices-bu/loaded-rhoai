# loaded-rhoai — Plan

Deploy a **"lived-in" Red Hat OpenShift AI cluster**: a chosen RHOAI version, hundreds of users and namespaces, every component the release ships, a full observability stack (metrics, traces, alerting, dashboards, and optionally logs), and a realistic mix of AI workloads and custom resources. Then **validate** it, using [MaaS:PAL](https://github.com/rh-ai-community-plugins/maaspal) for Models-as-a-Service and a companion validator for the rest of RHOAI (workbenches, inference, pipelines, training, evaluation, observability, RBAC and so on).

Two entry points produce the same end state:

- `./loaded-rhoai.sh install`, run by a `cluster-admin` on a fresh OpenShift cluster
- `./loaded-rhoai.sh bootstrap-gitops`, which installs OpenShift GitOps and hands the rest to Argo CD

---

## 1. Goals and non-goals

### Goals

1. **Pick the version.** `RHOAI_VERSION=3.4.1` or `3.5.2` installs exactly that operator CSV, with the matching DSC shape, MaaS wiring and component set.
2. **Install or adopt.** If RHOAI is already installed, use it and don't reinstall it. Otherwise install it.
3. **Make it lived-in, and healthy.** Hundreds of users, groups and namespaces. A mix of running and cleanly stopped workloads, with real usage history. Many custom resource types. **Nothing broken or failed:** every resource we create works once the install finishes (§6, "Healthy by construction").
4. **Cover everything.** Enable every DSC component the version ships, along with its dependency operators (§8). Run full observability, with metrics, traces, alerting and dashboards working end to end, plus logs at the `full` level (§9).
5. **Validate it.** Run maaspal against MaaS, and run platform checks on every other enabled component and every observability signal. Produce a single pass/fail report (JUnit, a readable summary and a browsable HTML page).
6. **Two delivery paths.** An imperative script and GitOps, built from **one set of manifests** so they can't drift apart.
7. **Make it repeatable.** A seeded, deterministic generator: the same seed and profile always produce the same cluster. Re-runs are idempotent, and there's a clean uninstall.
8. **Validate upgrades, both z-stream and minor.** Install a lived-in cluster at a chosen version such as 3.5.0 or 3.4.3. The user upgrades it the usual way, and `validate` then proves the upgraded cluster works and nothing was lost (§5, §10.13). Each z-stream can carry its own corrections and test record (§4), and each minor upgrade path has its own definition of what should change (§5).

### Non-goals (v1)

- Disconnected or air-gapped installs. This can be added later through mirror config.
- **Performing upgrades or migrations.** This repo never upgrades RHOAI: the user does that through the usual mechanism, including a minor's channel change and migration steps. We only set the cluster up beforehand and validate it afterwards.
- Real GPU inference at scale. GPUs are used when present, reusing `05-gpu` (§8, "GPU"), with a few real models. Without GPUs, serving uses CPU simulators plus at most one small real CPU model.
- Components that need external licences or accounts: the ISV tiles, and NIM unless an NGC key is supplied.
- Performance benchmarking as a deliverable. We collect scale signals and report them as advisory.

---

## 2. What we reuse from `rhoai-2254-install`

| Reuse as-is or lightly adapted | Change or drop |
|---|---|
| `lib/common.sh`: `log/die`, `wait_for_csv_succeeded`, `approve_installplan` with **fully-qualified CSV filter**, `wait_for_dsc_ready`, `preflight_cluster` | 2.x prerequisites (SM v2, Serverless, standalone Authorino, ModelMesh) are dropped. 3.x prerequisites come from version profiles (§4) |
| Pinned Manual-approval Subscription pattern and the **InstallPlan approver Job** (approves only the pinned CSV, leaves z-stream plans pending) | `TARGET_CSV` and channel come from `RHOAI_VERSION` and are no longer hard-coded |
| Argo tuning: `retry.limit` with backoff, `SkipDryRunOnMissingResource`, `RespectIgnoreDifferences`, controller memory bump to 6Gi, the Subscription health override for a deliberately pending plan | `render.sh` and committed `REPO_URL` are replaced by Helm parameters on the root Application (§12). This also makes the `LoadRestrictionsNone` patch unnecessary |
| Sample CR shapes: Notebook SA/PVC ordering, custom `vllm-cpu` ServingRuntime, RawDeployment ISVC, Feast, Llama Stack, TrustyAI, Model Registry, Ray, KFTO | Fixed per-sample namespaces are replaced by templated, generated namespaces (§5) |
| `05-gpu` phase (NFD and GPU Operator, opt-in) | — |
| **`rhoai-maas-guide`**: `scripts/setup-maas.sh` phases 2–7 and `manifests/` 02, 03, 05, 07 and 09 (MaaS gateway, Kuadrant, Authorino TLS, Postgres, models, observability and usage logging, Keycloak and MaaS OIDC). Run end to end on the spike cluster: all verification checks passed | Ported into charts rather than called as a script. Changes: RHBK channel from the version profile (the guide pins 26.4, §18); `captureUser`/`captureGroup` added to telemetry; tier subscriptions for generated Keycloak groups; the observability OperatorGroup names are the guide's, so the two never collide |
| Per-sample failure collection ("continue, report at end") | Dropped for install. A layer that can't reach a healthy state is retried, then the install **fails loudly** instead of finishing with broken resources. The pattern survives only in the validator's per-check result model |

---

## 3. Architecture

```
                    ┌──────────────────────── config ────────────────────────┐
                    │ RHOAI_VERSION=3.5.2  PROFILE=medium  SEED=42  MODE=...  │
                    └──────────────┬──────────────────────────┬──────────────┘
                                   │                          │
                     loaded-rhoai.sh install        loaded-rhoai.sh bootstrap-gitops
                     (helm template | oc apply)     (root Application w/ helm params)
                                   │                          │
                                   ▼                          ▼
   ┌─────────────────────────────────────────────────────────────────────────────┐
   │ charts/ (single source of truth)                                            │
   │  00 preflight  →  10 prereq + dependency + observability operators          │
   │  →  20 rhoai-operator (or ADOPT)                                            │
   │  →  30 platform (DSCI/DSC with all components, HW profiles, flags, MinIO)   │
   │  →  35 observability (metrics, traces, alerting, dashboards, logs)          │
   │  →  40 maas (gateway, models, subscriptions, auth policies)                 │
   │  →  50 identity (Keycloak + realm, OIDC IdP, warm-login, groups)            │
   │  →  60 population (N namespaces × workload mix, sharded)                    │
   │  →  65 settle (wait until every managed resource is healthy; fail if not)   │
   │  →  68 load (continuous per-user MaaS + workload traffic)                   │
   │  →  70 maaspal (helm chart + dashboard registration)                        │
   │  →  80 validate (in-cluster Job: platform checks + maaspal runs) → report   │
   └─────────────────────────────────────────────────────────────────────────────┘
```

Design decisions:

- **Use Helm for generated content and plain YAML for static content.** Templating hundreds of namespaces from `{profile, seed}` is a natural fit for Helm `range` loops, and Argo CD renders Helm natively. The script path uses `helm template … | oc apply --server-side` and never `helm install`, because release Secrets hit the 1 MB limit at this scale and Argo doesn't use releases either.
- **The validator always runs in-cluster as a Job,** in both paths. It behaves the same everywhere, the user's machine needs nothing beyond `oc`, `jq` and `helm`, and GitOps can trigger it as a final-wave hook.
- **Everything we create is labelled `loaded-rhoai.io/managed=true`,** plus `loaded-rhoai.io/seed` and `loaded-rhoai.io/layer`. Uninstall and adopt mode depend on this.

---

## 4. Version handling

### Input

`RHOAI_VERSION=X.Y.Z` is parsed into:

- **Version profile** `versions/X.Y/profile.yaml`, which holds everything that differs between minors, plus an optional z-stream override (see "Z-streams" below)
- **CSV** `rhods-operator.X.Y.Z`
- **Channel** from the profile, for example `stable-3.5`, overridable with `RHOAI_CHANNEL`

### Version profile contents (example keys)

```yaml
# versions/3.5/profile.yaml   (✓ = confirmed on a live 3.5.1 cluster, 2026-11-02)
channel: stable-3.5                                   # ✓
minOCP: "4.19.9"
dsc:
  apiVersion: datasciencecluster.opendatahub.io/v2    # ✓ storage version; v1 still served
  maasFieldPath: aigateway.modelsAsAService           # ✓ (kserve.modelsAsService still exists, deprecated)
dependencyOperators:        # package / channel / namespace / approval
  - {pkg: openshift-cert-manager-operator, channel: stable-v1}      # ✓ installed
  - {pkg: rhcl-operator, channel: stable, ns: openshift-operators}   # ✓ v1.4.3; pulls authorino, limitador, dns-operator
  - {pkg: leader-worker-set, channel: stable-v1.0,
     postInstall: "LeaderWorkerSetOperator/cluster"}                 # ✓ 3.5.2: without the CR the LWS CRD never appears
  - {pkg: servicemeshoperator3, channel: stable}                     # ✓ (3.5.0 after the RHCL plan, see §18)
  - {pkg: kueue-operator, channel: stable-v1.5, ns: openshift-kueue-operator}   # ✓ DSC kueue: Unmanaged
  - {pkg: job-set, channel: stable-v1.0, ns: openshift-jobset-operator, ownNamespace: true,
     postInstall: "JobSetOperator/cluster"}                          # ✓ required by trainer
  - {pkg: openshift-custom-metrics-autoscaler-operator, channel: stable, ns: openshift-keda}  # ✓ wva
  - {pkg: rhbk-operator, channel: match-installed, ns: maas-keycloak, ownNamespace: true}  # ✓ must equal any RHBK already on the cluster (26.6 on the 3.5.1 spike, 26.4 on the 3.5.2 RHDP clusters)
  - {pkg: mcp-gateway, channel: preview}   # in the 3.5.2 spike catalog as v0.7.1, preview channel only; not yet installed or tested. Owns MCPGatewayExtension, MCPServerRegistration, MCPVirtualServer (mcp.kuadrant.io/v1alpha1)
ordering:                   # ✓ learned on the spike, see §18
  - rhcl-operator before DSC kserve (or restart llmisvc/kserve/odh-model controllers)
  - GatewayClass openshift-default before the Kuadrant CR (or restart kuadrant-operator)
  - maas-default-gateway + MaaS Postgres before aigateway.modelsAsAService: Managed
observabilityOperators:
  - {pkg: cluster-observability-operator, channel: stable}           # ✓ in catalog
  - {pkg: opentelemetry-product, channel: stable}                    # ✓ in catalog
  - {pkg: tempo-product, channel: stable}                            # ✓ in catalog
  - {pkg: cluster-logging, channel: stable-6.6, level: full}         # ✓ in catalog
  - {pkg: loki-operator, level: full}
components:                 # see §8 for the full table
  aigateway: {managementState: Managed, modelsAsAService: Managed, batchGateway: Managed}
  kueue: {managementState: Unmanaged}
  trainingoperator: Removed   # deprecated → trainer
  llamastackoperator: Removed # deprecated → ogx
  ...
controllerResources:        # ✓ measured at ~355 projects on 3.5.2 (§19). Applied with opendatahub.io/managed=false (§17 item 22)
  ai-gateway-operator: 2Gi                 # used 493Mi of 512Mi
  dashboard-operator: 2Gi                  # used 458Mi, default 256Mi, OOMKilled
  kserve-module-controller-manager: 3Gi    # used 1013Mi of 1Gi
  kuberay-operator: 2Gi                    # used 549Mi, default 512Mi
  llm-d-batch-gateway-operator: 2Gi        # used 490Mi, default 256Mi
  maas-controller: 2Gi                     # used 626Mi, default 512Mi
  opendatahub-feast-operator: 2Gi          # used 782Mi, default 512Mi, OOMKilled
  spark-operator-controller: 2Gi           # used 496Mi of 512Mi
  trustyai-service-operator-controller-manager: 2Gi
  rhcl/kuadrant-operator: 3Gi              # via Subscription.spec.config; OOMKilled at 300Mi and again at 1Gi
rhclEnv:
  AUTH_SERVICE_TIMEOUT: 2s                 # Subscription.spec.config.env; guide Issue 7, confirmed on 3.5.2: maaspal load_test 55.7% errors → 0%
workbenchImages:            # ✓ CUDA/ROCm builds only when the cluster has matching GPUs (CUDA PyTorch is 11.7 GB)
  cpuOnly: [s2i-minimal-notebook, s2i-generic-data-science-notebook, code-server-notebook, odh-trustyai-notebook]
dashboardFlags: {ga: [...], techPreview: [...], devPreview: [...]}
population:                 # CR kinds valid for this version
  trainingKind: TrainJob
  externalModelApi: inference.opendatahub.io/v1alpha1
  playground:               # found in the 3.5.2 gen-ai BFF binary; confirm by creating one in the dashboard (M3)
    kind: OGXServer
    name: lsd-genai-playground
    settingsConfigMaps: [gen-ai-aa-mcp-servers, gen-ai-aa-vector-stores, gen-ai-aa-custom-model-endpoints]
observability:
  keyMetrics: {vllm: [...], maas: [...], trustyai: [...], gpu: [...]}
  traceHops: [gateway, router, model-server, ogx]
  metricNames: {rhoaiStack: authorized_hits_total, clusterThanos: authorized_hits}   # ✓
  alertAllowlist:           # each entry needs a reason and evidence; reviewed per z-stream
    - {alert: Watchdog}
    - {alert: AlertmanagerReceiversNotConfigured, reason: "cluster default, no receivers configured"}
    - {alert: PrometheusOperatorRejectedResources, reason: "UWM rejects bearerTokenFile ServiceMonitors shipped by odh-model-controller, nfd and lws (product)"}
    - {alert: GoogleCloudExporterDeprecationWarning, reason: "emitted by the OpenTelemetry operator 0.158 itself"}
    - {alert: TargetDown, match: {namespace: openshift-ingress, job: istio-pod-monitor}, reason: "Kuadrant PodMonitor also scrapes health port 15021 (404); 15020 and 15090 are up"}
maaspal:
  supported: true            # maaspal plugin.yaml: min_version 3.5.0
```

The 3.4 profile sets `maaspal.supported: advisory`. maaspal will install and run, but scenarios that touch 3.5-only APIs (`ExternalModel`/`ExternalProvider`) are skipped, and the report marks all maaspal results as advisory.

### Z-streams

A fact confirmed on 3.5.1 isn't automatically true of 3.5.2, so each z-stream can carry its own corrections and its own test record:

```
versions/3.5/
├── profile.yaml      # the base for every 3.5.z
├── z/3.5.2.yaml      # optional: only what differs in 3.5.2
└── locks/3.5.1.yaml  # what a validated run actually used
```

```yaml
# versions/3.5/z/3.5.2.yaml   (illustrative only: nothing here has been checked on 3.5.2)
maaspal: {chartVersion: <pinned>}
observability:
  alertAllowlist:
    - {alert: GoogleCloudExporterDeprecationWarning, remove: true}
upgrade:
  expectedChanges: []       # spec fields this upgrade is known to change (§10.13)
```

- **Resolving a profile:** the base plus the override for that exact z-stream. Overrides never stack, so 3.5.3 doesn't inherit from `3.5.2.yaml`. Maps are merged, list entries are matched on their key (`pkg`, `alert`), and `remove: true` deletes one. `loaded-rhoai.sh profile show --version 3.5.2` prints the result.
- **Which version gets resolved:** the validator and every layer use the **installed** CSV, not the requested version, so checks and the allowlist always match what's running.
- **Lock file:** written by a passing full `validate`. It records the OCP version, the exact RHOAI and dependency CSVs, the date, the report and, if the cluster was upgraded, the version it came from.
- **`verified` or `unverified`:** a z-stream is `verified` only if it has a lock file. An unverified one still installs from the base profile, and the report says so clearly. `--require-verified` makes that a failure for CI. **3.5.1 is currently unverified:** the spike confirmed many facts, but the full validator hasn't run yet.
- **Dependency versions:** many dependency channels float (`stable`), so the same profile can install different versions over time.
  - A fresh install of a verified z-stream pins the locked CSVs where the catalog still offers them, using the same Manual approval and approver Job as RHOAI. If one has gone from the catalog, it takes the channel head and the report records the difference.
  - Adopt mode never changes existing operators, and doesn't add Manual Subscriptions to a shared namespace (§5). It only reports differences from the lock.
  - **A fresh install sets every Subscription to Manual right after install, even without a lock file.** On the 3.5.2 spike, a catalog update moved RHBK from 26.4.16 to 26.4.17 mid-test, restarting both Keycloaks, including the cluster's own login (§19). The validator reports any CSV that changed during a run.
- **Workarounds expire:** allowlist entries and ordering workarounds link to an issue and can set `fixedIn: 3.5.2`, which turns them off from that version on. The report flags any allowlisted alert that didn't fire, so stale entries get removed.
- **Adding a z-stream:** usually nothing is needed up front. Install or upgrade to it, read the report, add an override for whatever differs, and commit it with the lock file.

### Preflight checks (fail fast)

- `packagemanifest rhods-operator` must offer the channel, and the channel must contain the CSV.
- OCP version must meet the profile's minimum.
- There must be a default StorageClass. Capacity is estimated against the profile (§15).
- For `X.Y` with no profile file, stop and list the supported versions.
- **Topology (✓ from the 3.5.2 spike, §19).** For `medium` and above:
  - Refuse to populate while the control plane is schedulable. On these clusters, etcd and container images share one disk, so image pulls and workloads on control-plane nodes stalled etcd: commit p99 reached 3,000 ms, and about 15 controllers lost leader election together.
  - Require a worker in every zone that will hold volumes, because EBS volumes are zonal. With no worker in a zone, those pods can only run on the control plane.
  - `--fix-topology` adds the missing workers and sets `mastersSchedulable: false` before any workload exists. It then deletes DaemonSet pods left on control-plane nodes that their DaemonSet no longer targets. Otherwise `ingress-canary` and `insights-runtime-extractor` keep them, and `KubeDaemonSetMisScheduled` and `RolloutStuck` fire indefinitely (§19).
- **Worker root disk.** Warn below 250 GB. The 100 GB default filled to 0 GB free on every worker during the first `medium` apply, and 69 pods were evicted.
- **GPUs.** With none present, workbench images are restricted to CPU builds (`workbenchImages.cpuOnly`).

> **Must verify per version during M1:** the remaining unverified items (marked "verify" above and in §8), the CRD kinds for components that are currently Removed, and the whole 3.4 profile. Check the RHOAI docs and the community MaaS guide, and treat profiles as data that gets corrected as releases land.

---

## 5. Install-or-adopt logic

```
CSV rhods-operator.* Succeeded in redhat-ods-operator?
├─ no  → MODE=install: prereqs → Subscription (Manual, startingCSV) → approver → DSCI/DSC
└─ yes → MODE=adopt
         ├─ installed == requested            → continue
         ├─ installed != requested, same minor → warn, use the installed z-stream's profile, never upgrade or downgrade
         ├─ different minor                    → stop (unless --accept-installed)
         ├─ DSC exists → never replace; record component states
         │   └─ component we need is Removed → stop, or patch if --enable-missing
         ├─ MaaS not enabled → stop, or enable via profile's field path if --enable-maas
         └─ RHOAI objects owned by an Argo Application → stop, or --take-over-gitops
```

**Adopt-mode hazards found on the spike cluster (§18):**

- **The existing RHOAI may already be GitOps-managed.** The spike cluster's DSC belonged to an Argo Application (`openshift-ai`, `selfHeal: true`), which would revert every component we enable.
  - **How we detect it:** the `app.kubernetes.io/instance` label or `argocd.argoproj.io/*` annotations on the DSC, DSCI or Subscription, or an Application whose `status.resources` lists them.
  - **What we do:** stop and name the Application, unless `--take-over-gitops` is given. That flag turns off `automated` sync on that one Application and records it in the report.
  - The spike's Application wasn't reverting anything yet only because it was stuck waiting for the pinned `rhods-operator` Subscription to become healthy.
- **Shared operator namespaces turn Automatic installs Manual.** OLM batches every pending CSV in a namespace into one InstallPlan, and uses Manual approval if *any* Subscription there is Manual.
  - On the spike, `openshift-operators` had Manual Subscriptions (Service Mesh, Grafana). The RHCL InstallPlan therefore needed approval, **and it also contained an unrelated Service Mesh 3.1.0 → 3.5.0 upgrade**.
  - The approver Job reports every CSV in a plan before approving it. Approving a plan that contains unrelated upgrades needs `--approve-bundled-upgrades`. Otherwise the install stops and explains why.
  - The pinned `rhods-operator` plan (3.5.2 pending) is never approved by us. Approving it is how the user upgrades (below).
- **OperatorGroup collisions.** Two OperatorGroups in one namespace break every operator there. Before creating one, we reuse the namespace's existing OperatorGroup if it has one.
- **RHBK CRD version.** RHBK's CRDs are cluster-wide, so a second Keycloak operator on an older channel fails to install. We reuse the channel that's already installed.

In adopt mode we **never** delete or downgrade pre-existing objects, and uninstall only removes objects carrying our label. On the GitOps path the bootstrap script runs the same detection and passes `rhoai.manage=false`. The operator and DSC Applications are then not rendered at all, so Argo never takes ownership of a pre-existing install.

### Upgrade workflow

This repo sets up the cluster and validates it afterwards. The upgrade itself belongs to the user, so we never approve its InstallPlan or change the Subscription.

1. **Install.** `install --version 3.5.0` builds the lived-in cluster and runs `validate`. A pass saves the **baseline** on the cluster, in the reports PVC, so it doesn't depend on any one laptop. The install output says how to upgrade, and notes that the next version's pending InstallPlan is expected.
2. **Upgrade.** The user approves the InstallPlan as usual, in the console or with `oc`. OLM decides the path, which may go through intermediate versions (3.5.0 → 3.5.1 → 3.5.2). A minor upgrade also needs a channel change first and migration steps afterwards (see "Minor upgrades" below). The cluster keeps running its load throughout.
3. **Validate.** The user runs `validate`, with no special flags. It reads the installed CSV, uses that version's profile, and compares against the baseline (§10.13).

**How `validate` decides what to do:**

| State found | What it does |
|---|---|
| RHOAI CSV or DSC still changing | Stops and says the upgrade looks in progress. Results now wouldn't mean anything |
| Same version as the baseline | Normal validation. A pass refreshes the baseline, so re-running it just before upgrading captures recent changes |
| Newer version than the baseline | Normal validation plus the upgrade comparison. A pass moves the baseline to the new version. A failure keeps the old baseline, so re-runs still compare against it. `--reset-baseline` accepts the current state instead |
| Newer minor, with migration steps outstanding | Result is `migration incomplete`, which exits non-zero but is reported differently from a failure. It lists each step's status, then runs what's meaningful so far, including whether existing models still serve. Checks that depend on an unfinished step are skipped with that reason |
| Newer minor with no upgrade path file | Normal validation. The comparison is skipped, with the reason in the report, because it can't tell expected changes from losses |
| No baseline (e.g. an adopted cluster already upgraded) | Normal validation. The comparison is skipped, with the reason in the report |

**What changes after the upgrade:**

- **Nothing on the platform gets re-applied.** The upgrade is being tested, so we don't repair anything. If an upgrade resets a setting we made, such as `captureUser`/`captureGroup` or the `sno` Alertmanager patch, validation fails and the report names the setting and the command to restore it.
- **Test tools are the one exception.** They aren't what's being tested, so `validate` may update the load generator and maaspal to the versions the new profile pins, and re-register maaspal with the dashboard.
- **The expected inventory stays as it was at install.** Objects created at 3.5.0 are what the upgraded cluster should still have, and they're checked using the new version's status rules. For a minor, the upgrade path file maps objects that are meant to change kind.
- **Only what was enabled is expected.** Components new in the target version aren't required on an upgraded cluster unless the path file says the migration needs them. The report lists them as available but not enabled.
- **Re-running `install` after an upgrade stops,** unless `--accept-installed` is given, because re-applying layers would hide what the upgrade changed.
- **A dependency a newer version needs** is the user's to upgrade, as on any cluster. Validation reports it through the DSC conditions if it's missing.
- **Workarounds that block upgrades:** the guide says `opendatahub.io/managed=false` annotations must be removed before upgrading. `validate` warns about any it finds, so the user sees this before they start.

**On the GitOps path,** the user upgrades the same way and `rhoaiVersion` on the root Application stays at the installed version. Three things need care, and all are M7 exit criteria:

- **The approver hook must not block later syncs.** It has to exit cleanly once the installed version is at or past its `TARGET_CSV`. The Job it's ported from waits for the pinned CSV to reach `Succeeded`, and that CSV is gone after an upgrade.
- **Argo mustn't undo the upgrade.** A minor upgrade has the user change the Subscription's channel and patch the DSC, and self-heal would revert both. So the Applications holding the RHOAI Subscription and DSC have automated sync off: Argo creates them once and the user owns them from then on.
- **Argo mustn't recreate migrated objects.** The user deletes old `ExternalModel`s during migration, and self-heal would bring them back. Migration fixtures (below) are therefore created by a one-time Job, not owned by an Application.

### Minor upgrades (3.4 → 3.5)

A minor upgrade uses the same workflow, but a healthy result looks different, and the user has work to do beyond OLM. The facts below come from `rhoai-maas-guide` chapters 10 and 12. **We haven't reproduced them ourselves.**

**The user's steps:** change the Subscription channel, approve the InstallPlan, then do the migration. The migration includes these steps:

| Step | Detail | Why it matters |
|---|---|---|
| Add `aigateway.modelsAsAService: Managed` | Replaces `kserve.modelsAsService`, which is frozen and can only move to `Removed` after migration | Without it, non-admin users silently lose the AI asset endpoints page |
| Set `ogx: Managed` **and** `llamastackoperator: Removed` | Both Managed makes the operator abort the module batch containing `aigateway` and `mlflowoperator` | MaaS CRDs never install, and the error doesn't mention MaaS |
| Check `maas-api` moved | From `redhat-ods-applications` to `redhat-ai-gateway-infra`, with `maas-db-config` copied and the gateway-access label on the namespace | Routes show `NotAccepted`, and the dashboard shows "Error loading components" |
| Migrate each LLMInferenceService | Existing ones keep their pinned preset and path-based routing until re-rendered | Body-based requests fail against them. Re-rendering can cause downtime |
| Recreate `ExternalModel`s as `ExternalProvider`s | No automatic migration. Secret names can no longer contain dots | External models disappear from the dashboard |
| Remove `maasAuthPolicies` from `OdhDashboardConfig` | The 3.5 webhook rejects it | Later dashboard config changes fail |

**One upgrade path file per pair:** `versions/3.5/upgrade-from-3.4.yaml` defines what the validator should expect:

```yaml
from: "3.4"
channels: {from: stable-3.4, to: stable-3.x}       # the guide says stable-3.x; §4 records stable-3.5. Verify in M6b
migrationSteps:             # each has an id, a doc link, a read-only check and required: true|false
  - {id: aigateway-enabled, required: true, check: ...}
  - {id: kserve-maas-field-removed, required: false, check: ...}   # guide: a warning until cleared
objectMappings:             # meant to change, so not counted as lost
  - {from: ExternalModel.maas.opendatahub.io, to: ExternalProvider.inference.opendatahub.io}
renamedConditions: {ModelsAsServiceReady: ModelsAsAServiceReady}
metricMappings: {}          # filled in from the first real run
expectedChanges: []         # each with a reason
knownIssues:                # names a likely cause in the report; never turns a failure into a pass
  - {id: RHOAIENG-82694, symptom: "mcp-lifecycle-operator OOMKilled and DSC not Ready"}
```

**What the 3.4 install has to include:** the test only means something if the cluster holds what the migration has to deal with. The 3.4 profile therefore adds **migration fixtures**, all healthy on 3.4:

- `ExternalModel`s pointing at a simulator, a few with dots in their secret names
- The `maasAuthPolicies` dashboard flag, set where 3.4 supports it
- `LlamaStackDistribution`s, because leftovers cause duplicate Playground endpoints on 3.5
- LLMInferenceServices on 3.4 presets, spread across running and stopped
- `Tenant`-based OIDC (`spec.externalOIDC`), because 3.5 is meant to carry those values over
- Scale that matters: hundreds of namespaces' worth of Secrets is what's expected to trigger the MCP Lifecycle Operator OOM, which a small test cluster would miss

**The load generator has to follow routing per model.** A model starts path-based (`/llm/<ns>/<name>`) and moves to `/v1/chat/completions` when the user migrates it, and different models change at different times. The load generator looks up each model's current route rather than assuming one. Errors caused by the user's migration, such as an LLMInferenceService being recreated, are expected and count toward disruption rather than failure.

**maaspal:** it declares `min_version 3.5.0`, so MaaS at 3.4 is baselined by our own checks, with maaspal advisory. After the upgrade, a full maaspal run is required and blocking.

---

## 6. The "lived-in" population

### Profiles

All counts are deterministic from `SEED`, so the same seed and profile give an identical cluster.

| Profile | Users | Teams (groups) | Namespaces | Workbenches (running / total) | ISVC + LLMISVC (running / total) | DSPAs | Approx. objects |
|---|---|---|---|---|---|---|---|
| `small` | 50 | 8 | ~80 | 5 / 60 | 4 / 30 | 2 | ~3k |
| `medium` | 300 | 30 | ~400 | 15 / 350 | 8 / 150 | 6 | ~15k |
| `large` | 1000 | 80 | ~1200 | 30 / 1100 | 12 / 400 | 10 | ~50k |

Any count can be overridden individually. The "running" columns bound real CPU and memory use. **The model column splits about 80/20 between InferenceServices and LLMInferenceServices:** at `medium`, 120 ISVCs (4 running) and 30 LLMISVCs (4 running behind MaaS), matching what the 3.5.2 spike ran. The split is a proposal, not yet measured. Everything else is **stopped or scaled to zero**, which is realistic: most notebooks on real clusters are stopped.

### Identity: Keycloak OIDC (layer 50)

**Keycloak is the identity source for every generated user.** There are two OIDC paths, both from the **same realm**. Both were exercised on the spike cluster (§18).

```
                      ┌─ client "maas-oidc" (public, direct access grants, groups scope) ─┐
Keycloak realm ───────┤                                                                    ├─▶ MaaS
  users, groups,      │   AITenant.spec.oidc → MaaS validates Keycloak tokens itself.     │   API key
  tier attributes     │   MaaS consumers need NO OpenShift account. The token's `groups`  │   (per user)
                      │   claim selects the MaaSSubscription.                    ✓ verified│
                      └─ client "openshift" (confidential) ─▶ OAuth OpenID IdP (claims.groups)
                             → User/Identity/Group sync → dashboard, workbenches, projects
```

1. **MaaS-native OIDC (primary for MaaS users).**
   - `AITenant/models-as-a-service` in `ai-tenants` gets `spec.oidc: {clientId: maas-oidc, issuerUrl: https://<keycloak>/realms/<realm>, ttl: 300}`.
   - A user gets a token from Keycloak (the password grant works for headless clients) and exchanges it for a MaaS API key at `POST /maas-api/v1/api-keys`. The key is bound to the highest-priority subscription that the user's `groups` claim matches.
   - **Most of the hundreds of generated MaaS consumers exist only in Keycloak,** like external API customers in a real deployment.
   - Verified: Keycloak-only users minted keys and inferred, and they resolved to the right tier subscription by priority.
   - OIDC users **also match `system:authenticated`**, so tier priorities must sit above any `system:authenticated` subscriptions.
2. **OpenShift OAuth OpenID IdP (for dashboard and workbench users).** Users who own projects, notebooks and models also log in to OpenShift through the realm's `openshift` client. OpenShift's groups are synced from the token on login (`claims.groups`, available on OCP 4.20).

**Keycloak deployment** (reusing `rhoai-maas-guide/manifests/09-external-oidc`)

- **Operator:**
  - Red Hat build of Keycloak in namespace `maas-keycloak`, with its own OperatorGroup.
  - **The channel must match any RHBK already on the cluster.** RHBK's CRDs are cluster-scoped, so every RHBK install on a cluster must use the same channel. On the 3.5.1 spike that was 26.6, and the guide's `stable-v26.4` pin failed with "risk of data loss… removes version v2beta1" (§18). The RHDP clusters for the 3.5.2 spike already had 26.4. Detect it, don't hard-code it.
- **Database and CR:**
  - PostgreSQL (`keycloak-pgsql`) **on a PVC, with a `Recreate` strategy, before the realm is imported.** The guide's database has no volume, so a cluster restart on the 3.5.2 spike wiped the realm and every user while `Keycloak Ready=True` and `RealmImport Done=True` (§19). Install proves durability by restarting both pods and checking that the realm still answers.
  - A `Keycloak` CR whose hostname is `keycloak-maas-keycloak.<apps domain>`.
  - RHBK creates an Ingress, which OpenShift turns into an edge Route.
- **Realm configuration:**
  - The first realm is created with a `KeycloakRealmImport`.
  - `KeycloakRealmImport` only creates realms and never updates them, so users, groups, clients and mappers are then upserted by an idempotent **realm-config Job** that calls the Keycloak admin REST API. The spike's `kc_seed.py` is the starting point.
  - The realm keeps the guide's `maas` realm name, groups claim scope and `maas-oidc` client.
- **Realm contents:**
  - **Users:** every generated user, with seed-derived passwords stored in `loaded-rhoai/credentials`. Each has `team`, `persona` and `maasTier` attributes, and email and name.
  - **Groups:** one per team, plus `maas-free`, `maas-standard`, `maas-premium`, `maas-enterprise`, `rhoai-admins` and `rhoai-users`.
  - **Client `maas-oidc`:** public, with direct access grants on and the `groups` scope (as in the guide).
  - **Client `openshift`:** confidential, standard flow and direct access grants, redirect URI `https://oauth-openshift.<apps domain>/oauth2callback/keycloak`. Its secret is generated in-cluster.
  - **Claims mappers, before any user logs in.** The guide's realm has only the `groups` and `offline_access` scopes, so tokens carry no `preferred_username`. OpenShift then names users by their Keycloak UUID, and RoleBindings by username silently grant nothing. Add `preferred_username`, `email` and `name` mappers to the `openshift` client first (✓ 3.5.2 spike).

**OpenShift OAuth (path 2)**

- **The IdP:** an OpenID identity provider named `keycloak` is added **additively** to `OAuth/cluster`. Existing IdPs (`htpasswd_provider` on the inspected cluster) are kept.
  - Settings: `mappingMethod: claim`, `claims.preferredUsername: [preferred_username]`, `claims.groups: [groups]`, `claims.email: [email]`, `claims.name: [name]`.
  - The client Secret goes in `openshift-config`. A CA ConfigMap is added only if the ingress certificate isn't publicly trusted.
  - **Verified on OCP 4.20:** `claims.groups` is supported and syncs group membership from the OIDC provider on each login.
- **Warm-login Job:** logs in **every** generated user once, through the OAuth password-challenge flow against the Keycloak IdP (✓ verified on OCP 4.22: 300 users logged in within 22 s, with Users, Identities and Groups created). Logins can fail briefly while the OAuth server rolls out the new IdP, so the Job retries. This creates real `User`, `Identity` (`keycloak:<sub>`) and synced `Group` memberships, exactly as if each person had logged in, which makes user and group listings genuinely lived-in. It replaces pre-creating User and Identity objects.
- **HTPasswd** is kept for break-glass admin accounts only. `--idp keycloak|htpasswd|both` (default `keycloak`) controls which IdPs generated users go into.
- **Direct OIDC is not the default.** OCP 4.20 also supports `Authentication.spec.type: OIDC`, where the API server trusts Keycloak tokens directly with no OAuth server. That removes `kubeadmin` and htpasswd logins and changes how RHOAI and MaaS see tokens, so it's offered only as `--auth-mode direct-oidc` (see risks).

**Users, groups and dashboard access**

- **Personas:** `rhoai-admins` (5), team leads, data scientists, ML engineers, and viewers or auditors. Each MaaS-consuming user has a `maasTier`, and belongs to the matching `maas-*` group in Keycloak.
- **Dashboard config:** `adminGroups` and `allowedGroups` are set to the Keycloak-sourced groups. Optional on adopt.
- **Admins see every project only with `cluster-reader`.** Being a dashboard admin grants no view of other users' projects, so `rhoai-admins` also gets `cluster-reader`. That's the "worst case" user for UX testing (§10.14).

### Namespace mix (layer 60)

| Kind | Share | Contents |
|---|---|---|
| Team shared project | 1 per team | Admin rolebinding for the lead, edit for members, view for the auditor group |
| Personal sandbox | ~1 per user (0–3, seeded) | Admin for the owner. Some shared with a colleague |
| MaaS model namespaces | 3–5 | `maas.opendatahub.io/gateway-access=true`, hosting LLMInferenceServices |
| Shared infra | 1–2 | MinIO (S3 for connections, pipeline artifacts and models) and the model registry DB |
| Non-dashboard namespaces | ~5% | No `opendatahub.io/dashboard` label (noise that RHOAI should ignore) |

### Workloads and custom resources per namespace

Each kind is drawn from weighted distributions per persona.

- **Workbenches:** `Notebook` CRs across the shipped images (CPU builds only when there are no GPUs, see §4 `workbenchImages`), plus custom BYON `ImageStream`s. A spread of hardware profiles. Most are stopped (`kubeflow-resource-stopped`), some running. PVCs at 1–5 Gi, with a few extra shared data PVCs.
  - **Create, then stop (✓ 3.5.2).** A Notebook created with the stop annotation loses it and starts. The annotation is also stripped again while the Notebook is first being reconciled. Population creates Notebooks running, then annotates them and re-checks until every one stays stopped. At 350 Notebooks applied at once, that took about 30 minutes, and the brief starts are what filled the worker disks (§19).
- **Connections:** S3 (MinIO) and OCI/URI connection Secrets with the dashboard labels.
- **Serving:**
  - Custom `ServingRuntime`s
  - `InferenceService` (RawDeployment), mostly stopped through the stop annotation, a few running `vllm-cpu` or sklearn
  - `LLMInferenceService` simulators (`llm-d-inference-sim`, CPU only) for MaaS
- **Pipelines:** a few `DataSciencePipelinesApplication`s on shared MinIO, with **historical pipeline runs** submitted by a seeding Job: successful runs and scheduled recurring runs (which also succeed).
- **Model Registry:** 1–3 registries, populated through REST with registered models, versions and artifacts that link to deployed ISVCs.
- **Distributed workloads:**
  - **Queue-managed work gets its own namespaces** (`<team>-batch`). Labelling a namespace `kueue.openshift.io/managed=true` puts **every** pod in it under Kueue: pipelines, Feast and serving too. They count against quota, and Spark is suspended. A LocalQueue named `default` makes it worse, because it becomes the namespace default. Removing the label later doesn't fully undo it (✓ 3.5.2, §19).
  - Kueue `ResourceFlavor`s, a `ClusterQueue` per team, and a `LocalQueue` per batch namespace, never named `default`
  - Completed `RayCluster`s, plus **idle** ones. A RayCluster created with `suspend: true` is admitted and started by Kueue whenever its queue has room, so "suspended" doesn't hold. Idle clusters go in a ClusterQueue with `stopPolicy: Hold`, so Kueue never admits them (✓ 3.5.2: 6 stayed suspended through a full re-apply).
  - Training jobs (`TrainJob` or `PyTorchJob`, chosen by the version profile)
- **Platform-scoped:**
  - Cluster-wide and project-scoped `HardwareProfile`s
  - `OdhDashboardConfig` customisations
  - Custom notebook images
  - Model catalog sources (version-gated)
- **Gen AI playgrounds:** about one per team that uses gen AI (`small` 3, `medium` 10, `large` 25), a few running and the rest scaled to zero. On 3.5.2 the dashboard's Gen AI studio creates a playground as an `OGXServer` named `lsd-genai-playground` in the user's project, and keeps its settings in the `gen-ai-aa-mcp-servers`, `gen-ai-aa-vector-stores` and `gen-ai-aa-custom-model-endpoints` ConfigMaps. Each playground is wired to MaaS models and at least one MCP server, and some have a vector store. **Create the first one through the dashboard in M3**, record exactly what it creates, then generate the same objects. Those names came from the gen-ai BFF binary, not from a created playground.
- **MCP Gateway:** one gateway (`MCPGatewayExtension`) in front of the MCP servers, an `MCPServerRegistration` for every `MCPServer` the population creates, and 1–2 `MCPVirtualServer`s that give different teams different tool sets. The gateway route gets an `AuthPolicy` against the Keycloak realm, so tool calls are per user like MaaS calls. The operator is a new dependency (§4) and is preview-only on 3.5.2 (§17 item 26).
- **Kuadrant policies:**
  - `TelemetryPolicy`: the MaaS one (§7) on `maas-default-gateway`, plus a variant (below).
  - `TokenRateLimitPolicy` and `AuthPolicy`: MaaS generates these per model and subscription. **The population never hand-writes policies on MaaS-managed routes,** because MaaS owns them and would fight the change. Hand-written ones go on a non-MaaS route only (a variant).
  - `RateLimitPolicy` (request count): one, on a non-MaaS route.
  - `PlanPolicy`, `OIDCPolicy` and the developer portal kinds (`APIProduct`, `APIKey`, `APIKeyRequest`) are installed by RHCL with no instances. Leave them out until we know whether RHOAI 3.5 uses them.
- **Every other component** (§8): Feast `FeatureStore`s, OGX distributions, TrustyAI services, evaluations and guardrails, MLflow experiments, Spark applications, MCP servers, `InferenceGraph`s and GPU workloads. Each is spread across team projects by persona: data scientists get MLflow and evaluation, ML engineers get Spark, Feast and training.
- **Governance:** `ResourceQuota` and `LimitRange` on about a third of projects, `NetworkPolicy` on some, and mixed user and group RoleBindings
- **Product constraints the generator must respect (✓ 3.5.2, §19):**
  - **FeatureStore names must be unique cluster-wide** (`features-<namespace>`). The Feast operator names a cluster-scoped ClusterRoleBinding from the FeatureStore name alone, so same-named stores in different projects overwrite each other's binding indefinitely, and their status flips between Ready and Failed.
  - **Wait for the namespace's trusted CA bundle** before creating TrustyAI or Feast. Both mount `odh-trusted-ca-bundle` with `subPath: ca-bundle.crt`, and the network operator adds that key a few seconds after RHOAI creates the ConfigMap. A pod that mounts in that gap fails with `Not a directory`, and never recovers until deleted.
  - **Spark on restricted SCC** needs `spark.kubernetes.{driver,executor}.volumes.emptyDir.work.mount.path=/opt/spark/work-dir`, because the upstream image's work dir isn't writable by a random UID. `spec.driver.volumeMounts` wasn't applied.
  - **MCP servers** must speak the protocol the operator's readiness check expects. The catalog's `openshift-mcp-server-rhel9` works. The guide's `mcp-weather` sample, which uses legacy SSE, never turns Ready.
  - **OGXServer** needs `spec.baseConfig`, a ConfigMap holding the image's own `/opt/app-root/config.yaml`, plus Postgres through `workload.overrides.env`. The default `distribution.name` path fails with HTTP 401, because the operator can't read the image's labels from `registry.redhat.io`.

### Customised variants (upgrade canaries)

Defaults are the path every upgrade is tested on. Customisations are where upgrades break: a field the new operator drops or rewrites, a webhook that now rejects an old spec, a reference to something the new version no longer ships, or a user config the controller stops merging. So, alongside the bulk population (which stays mostly default, for realism and scale), **every kind gets a small set of customised variants**, each exercising one non-default configuration path.

**Rules:**

- **A fixed set per profile, not scaled.** One object per variant at every profile, from `small` up, placed deterministically in team projects so they live among ordinary objects. Each carries `loaded-rhoai.io/variant: <kind>-<variant>`.
- **Healthy by construction, like everything else.** CPU-only where there are no GPUs. A variant that can't reach its healthy state on this cluster isn't created, and the report says why.
- **Every variant has an effect probe**, recorded in `expected-inventory.json`. The probe proves the customisation is actually in effect, not just present in the spec. For example, the env var from a user config is in the pod, an HPA exists with the right bounds, or an unauthenticated call is refused.
- **Version-gated in the profile.** Each version profile lists which variants apply (`population.variants`, with `minVersion` and `fixedIn` like other overrides), so a variant for a 3.5-only field never renders on 3.4.
- **Pinned references are deliberate variants.** Some objects refer to something the product ships under a version-specific or release-specific name: an LLMInferenceServiceConfig, a serving runtime template, a workbench image tag or a ClusterTrainingRuntime. The population includes objects that reference these explicitly, so the upgrade check can report what happened to each reference.

**Evidence that this matters (3.5.2 spike):** the shipped LLMInferenceServiceConfigs carry the release in their names (`v3-5-2-kserve-config-llm-template`, `…-llm-scheduler`, `…-llm-router-route` and 16 others in `redhat-ods-applications`). Every LLMInferenceService records the versions it resolved in `status.annotations` and `status.appliedConfigs`, with `source: Preset`. What an upgrade does to these is untested: whether default services re-resolve to the new names and roll their pods, whether the old configs are removed, and what happens to a service whose `baseRefs` names a `v3-5-2-…` config (§17 item 24).

**Variants per kind** (fields checked against the 3.5.2 CRDs; none of these have been run yet, so each is "verify" until it passes on a cluster):

| Kind | Variants | What an upgrade could break |
|---|---|---|
| `LLMInferenceService` | **(a)** default, with resolved config names recorded. **(b)** `baseRefs` to a user-owned `LLMInferenceServiceConfig` in the project (custom env, resources and labels). **(c)** `baseRefs` naming a shipped versioned config explicitly. **(d)** `router.scheduler` with a custom `config` (the simulator supports the endpoint picker). **(e)** `prefill` plus decode (P/D) with simulators. **(f)** `scaling` bounds, `replicas: 2`, and `tracing` on. **(g)** model from `pvc://` and `oci://` as well as `hf://` | Preset renames, user config no longer merged, removed configs, scheduler config schema changes, an unexpected pod rollout |
| `LLMInferenceServiceConfig` | A project-scoped config used by (b), and one shared by several services | Merge order or schema changes |
| `InferenceService` | `autoScaling` with `scaleMetric`/`scaleTarget` and min 1, max 2. A real sklearn model from MinIO through a connection and a custom `serviceAccountName`. A `logger`. A hardware profile annotation, with its tolerations and node selector. `timeout` and `deploymentStrategy` | HPA ownership, storage initializer changes, hardware profile reconciliation |
| `ServingRuntime` | One copied from a shipped template that keeps `opendatahub.io/template-name`, one edited copy with changed args, and one fully custom | Template updates that do or don't reach existing runtimes |
| `InferenceGraph` | One each of `Sequence`, `Switch`, `Ensemble` and `Splitter` | Router image and routing semantics |
| `DataSciencePipelinesApplication` | `podToPodTLS` on and off. External database instead of MariaDB. `mlmd` deployed. `apiServer` with a custom CA bundle and caching off. `scheduledWorkflow` timezone. The `mlflow` integration | DB schema migration, TLS changes, run history lost |
| `Notebook` | Cluster-wide and project-scoped hardware profiles. A BYON image. **An older shipped image tag** (n−1). Env from a connection Secret. An extra shared data PVC. Tolerations | Image tags dropped by the new version, hardware profile rewrites, culler or auth changes |
| `FeatureStore` | Online store on Redis, offline store and registry on PVC, a SQL registry. `authz` Kubernetes and OIDC. `cronJob` materialisation. `feastProjectDir` from git. UI on. 2 replicas | Store config schema, authorisation changes |
| `TrustyAIService` | `DATABASE` storage through `databaseConfigurations`, as well as `PVC` | TrustyAI's PVC → database migration |
| `ModelRegistry` | Generated Postgres and an external database. Populated entries in both | Schema migration, data kept |
| `RayCluster` | `enableInTreeAutoscaling` with `autoscalerOptions`. GCS fault tolerance on Redis. `authOptions`. Two worker groups | KubeRay CRD and operator changes |
| `TrainJob` | A namespaced custom `TrainingRuntime`. `initializer` for dataset and model. `podTemplateOverrides`. **The shipped `torch-distributed-cpu` reference** | Renamed or removed ClusterTrainingRuntimes |
| Kueue | A cohort with borrowing, preemption, `WorkloadPriorityClass`, and a hardware profile backed by a LocalQueue | Kueue API version moves (`v1beta1` → `v1beta2`) |
| `SparkApplication` | Dynamic allocation, and a `ScheduledSparkApplication` | Spark operator upgrades |
| `MCPServer` | Custom args, `extraLabels`, 2 replicas | Alpha API changes |
| `MLflow` | External Postgres through `backendStoreUriFrom`, S3 artifacts, `workspaceLabelSelector` | `migration` handling, backend schema |
| `EvalHub`, `OGXServer` | Custom providers and collections; a custom `baseConfig` with extra providers | Config schema changes |
| Gen AI playground | One with an MCP server, a vector store and a custom model endpoint all attached. One pointing at a MaaS model by its `publishers/…` ID | Playground settings ConfigMaps reset or reshaped, OGX image or config changes, dropped MCP or vector store links |
| MCP Gateway | A virtual server exposing a subset of tools. A registration with a credential Secret. Keycloak `AuthPolicy` on the gateway route | Alpha API changes (`v1alpha1`), registration or auth lost |
| `TelemetryPolicy` | Extra metric labels on a non-MaaS gateway (for example `cost_center` from a request header) | Label set reset, so per-user or per-team metrics go missing |
| `TokenRateLimitPolicy`, `AuthPolicy`, `RateLimitPolicy` | One hand-written each, on a non-MaaS route | Kuadrant API or enforcement changes outside MaaS |
| `LMEvalJob`, `GuardrailsOrchestrator`, `NemoGuardrails`, `LLMBatchGateway` | Not populated yet (§19). Add each with one default and one customised variant | |
| MaaS | `ExternalModel`/`ExternalProvider` (3.5+). Overlapping subscriptions resolved by priority. Different token limits per model in one subscription. An auth policy granting users rather than groups. API keys with an expiry | Policy translation into Kuadrant objects, key validity |
| Platform | A custom `HardwareProfile` per scope. `OdhDashboardConfig` with non-default flags and sizes. A custom connection type ConfigMap. DSCI with a `customCABundle` | Profile and config migrations, settings reset to defaults |

**Effect probes, examples:**

| Variant | Probe |
|---|---|
| LLMISVC with a user config | The config's env var is in the running pod, and `status.appliedConfigs` lists the user config |
| ISVC with autoscaling | An HPA exists with min 1, max 2, owned by the ISVC |
| Notebook with a hardware profile | The pod has the profile's tolerations and node selector |
| FeatureStore with `authz` | An unauthenticated feature request is refused, and an authorised one succeeds |
| TrustyAI on a database | Inference data written before the probe is read back from the database |
| Kueue cohort | A Workload borrows quota from its cohort |

### Healthy by construction (layer 65, "settle")

"Lived-in" means **volume, variety and history**, never breakage. Once the install finishes, every resource we created is in a working state:

- **Allowed states** are Ready or Running, cleanly **stopped** (notebooks, ISVCs), **Succeeded or Completed** (Jobs, pipeline runs, training jobs), or **suspended** (Kueue-managed RayClusters). Every stopped or suspended workload must be startable, and the validator proves this (§10.4).
- **Never created:**
  - Failed or not-Ready ISVCs and LLMISVCs
  - Pods in `CrashLoopBackOff`, `ImagePullBackOff` or long `Pending`
  - Failed Jobs or failed pipeline runs
  - Unbound or orphaned PVCs
  - RoleBindings to users or groups that don't exist
  - Dangling references (connections, model refs, hardware profiles, images)
  - MaaS misconfigurations: every subscription has a matching auth policy, every model ref resolves, priorities are unique per model, and every model namespace carries the gateway-access label
- **Every reference is checked before render.** The generator only references images, hardware profiles, runtimes, connections and groups that it also creates, or that the version profile lists as shipped.
- **Seeding Jobs keep no failures.** They retry internally and are deleted on success through `ttlSecondsAfterFinished`, so no Failed Job objects are left behind. If a seeding Job ultimately fails, the install fails.
- **The settle step:** after population and seeding, `settle` waits (with a per-layer timeout) until the validator's inventory and per-kind status checks (§10.1, §10.2) pass. If it isn't clean in time, it prints the offending objects and exits non-zero. The install never reports success with broken resources.

### Expected inventory

The generator writes `expected-inventory.json` alongside the rendered manifests. It lists every object we create (kind, namespace, name) with its expected state (`running`, `stopped`, `completed`, `suspended` or `static`) and its owner user. This file is the contract the validator checks against (§10.1). Because it's generated from the same templates and the same seed, it can't drift from what was deployed.

### Scaling the apply

- Population is rendered in **shards** of about 25 namespaces each.
- **Images are pulled first.** A temporary DaemonSet on workers pulls each workbench image in turn, through ordered init containers, and is deleted once every node has them.
- **Shards are applied one at a time,** with server-side apply, and Notebooks are stopped after each shard. Applying 6 shards in parallel started all 350 Notebooks at once on the 3.5.2 spike, filled every worker's 100 GB root disk to 0 GB, and caused 69 evictions (§19).
- On the GitOps path each shard is one Application from an `ApplicationSet` (list generator), which keeps per-app resource counts manageable for the Argo controller.
- The seeding Jobs for pipeline runs, model registry entries and API keys run after their target CRs report Ready, and they're idempotent.

---

## 7. MaaS layer (layer 40)

**Source of truth: [`rhoai-maas-guide`](../rhoai-maas-guide).** Its `scripts/setup-maas.sh` (phases 2–7) and `manifests/` are reused the same way the rhoai-2254-install pieces are (§2), as manifests and charts rather than by shelling out. They were run on the spike cluster on top of an existing RHOAI 3.5.1, and every verification check passed (§18). These 3.5 specifics were confirmed live:

1. **Platform** (guide phase 2). The order matters:
   - **Create the `openshift-default` GatewayClass first,** because it provisions Istio. Then create the `Kuadrant` CR in `kuadrant-system`, with **`spec.observability.enable: true`** so Limitador and Authorino get their monitors. If the Kuadrant CR is created first, it sits in `MissingDependency` until the kuadrant-operator pod is restarted.
   - `Authorino` gets TLS from a service-serving cert, plus the `SSL_CERT_FILE` environment variable.
   - User workload monitoring is turned on.
   - `Gateway/maas-default-gateway` in `openshift-ingress`:
     - Class `openshift-default`, listeners on `maas.<apps domain>`, and the ingress default certificate.
     - `allowedRoutes` selects namespaces labelled `maas.opendatahub.io/gateway-access=true`.
     - Annotations: `opendatahub.io/managed: "false"` and `security.opendatahub.io/authorino-tls-bootstrap: "true"`.
     - On AWS it gets an ELB, and OpenShift publishes DNS for the listener hostname. Clusters without a load-balancer provider use MetalLB plus a passthrough Route.
   - **MaaS won't start without this Gateway.** Until it exists, `ModelsAsAServiceReady=False: gateway openshift-ingress/maas-default-gateway not found`.
2. **Database** (phase 3): PostgreSQL in `redhat-ods-applications`. The `maas-db-config` Secret is **mirrored to `redhat-ai-gateway-infra`**, where maas-api runs on 3.5.
3. **Enablement** (phase 4): `aigateway.modelsAsAService: Managed` (and `batchGateway`). The 3.5 tenant objects are `AITenant/models-as-a-service` (in `ai-tenants`), `MaaSTenantConfig/default-tenant` (in `models-as-a-service`) and `Config/default` (cluster-scoped).
4. **KServe must already see RHCL.** The `llmisvc-controller-manager` only checks for the `AuthPolicy` CRD when it starts. If RHCL is installed after RHOAI, every LLMInferenceService sits in `GatewayPreconditionNotMet: AuthPolicy CRD is not available` until `llmisvc-controller-manager`, `kserve-controller-manager` and `odh-model-controller` are restarted. Install RHCL before enabling KServe, or restart them in adopt mode (§18).
5. **Models:**
   - **Simulators:** about 6–12 `LLMInferenceService`s (`llm-d-inference-sim`, as `facebook-opt-125m-simulated` in the guide).
   - **Real models:** a real GPU model when GPUs are present. The guide's `--model auto` picks `gpt-oss-20b` for 24 GB L4s, and it reached Ready on the spike. Without GPUs, `qwen3-06b` runs on CPU.
   - **Registration:** a `MaaSModelRef` for each model.
   - **External models:** an `ExternalModel` and `ExternalProvider` (`inference.opendatahub.io`, which 3.5.1 serves alongside `maas.opendatahub.io`).
   - **How clients call them:** model IDs are `publishers/<ns>/models/<name>`, and **all inference goes through one endpoint**, `https://maas.<domain>/v1/chat/completions`, with the ID in the body.
6. **Subscriptions and auth policies:**
   - **Tiers:** owned by **Keycloak groups**, for example `tier-free` at priority 50, `tier-standard` at 60 and `tier-premium` at 70, each covering every model. A matching `MaaSAuthPolicy` per tier.
   - **Priorities:** must be unique for each model, and above the guide's default `system:authenticated` tiers (10 and 20), because OIDC users match those too.
7. **Telemetry and usage** (guide phase 7, plus one thing the guide misses):
   - `Config/default`: `usageLogging: true`. The operator then creates a usage OTel collector, `LokiStack/usage` on MinIO, and Perses usage dashboards.
   - `MaaSTenantConfig.spec.telemetry`: `enabled: true` **and `metrics.captureUser: true` and `captureGroup: true`**. Without `captureUser`, the generated TelemetryPolicy has no `user` label, every `authorized_hits_total` series has `user=""`, and the **per-user token panels stay empty**. This was found and fixed on the spike (§18).
   - **The generated TelemetryPolicy** (✓ 3.5.2): `maas-telemetry` in `openshift-ingress`, targeting `maas-default-gateway`, with metric labels `user`, `group`, `subscription`, `model`, `cost_center` and `organization_id`. The validator checks this label set, because a missing `user` label empties the per-user panels without any error.
8. **API keys:** a seeding Job logs each MaaS user in to Keycloak (`maas-oidc` client) and exchanges the token for that user's own API key. Every key is valid; some earlier keys are already revoked, as normal key rotation. The load generator uses these keys (§9).

---

## 8. Full component coverage (layer 30)

The goal is to enable **every DSC component the version ships**, plus its dependencies, and give each one lived-in workloads (§6). Each component must reach Ready and pass the §10 checks.

**Verified on a live 3.5.1 cluster** (OCP 4.20, 2026-11-02): DSC `v2` is the storage version and exposes the components below. A component with unmet dependencies reports them as DSC conditions; for example, `KserveLLMInferenceServiceDependencies=False: Red Hat Connectivity Link not installed`. **Any False condition for an enabled component fails validation (§10.0).**

**Spike result:** with the dependencies below in place, **every component reached Ready** on 3.5.1 (all DSC conditions True; `trainingoperator` was Removed on purpose). The CRD kinds that appear when each component is enabled are recorded in the table.

| DSC component (v2) | loaded-rhoai default | Dependencies we install | What the population gets |
|---|---|---|---|
| `dashboard` | Managed | — | Feature flags (below), connection types, hardware profiles, custom images, project sharing |
| `workbenches` | Managed | — | Notebooks across the shipped images (minimal, datascience, pytorch, pytorch-llmcompressor, tensorflow, code-server, trustyai, minimal-gpu). ROCm images are used only when AMD GPUs are present |
| `aipipelines` (+ `argoWorkflowsControllers`) | Managed | — | DSPAs, `Pipeline`/`PipelineVersion` CRs, run history, recurring runs, Elyra runtime images (`runtime-*`) |
| `kserve` | Managed | **RHCL** (Connectivity Link), **LWS** plus a `LeaderWorkerSetOperator/cluster` CR, cert-manager | ISVCs across runtimes (vLLM CPU, OVMS, MLServer sklearn/xgboost), LLMISVCs (simulators, plus real vLLM on GPU when present), an `InferenceGraph`, `enableLLMInferenceServiceConsoleDashboards: true` |
| `kserve.modelCache` | Managed when a GPU node exists | — | One pre-cached model, used by a GPU LLMISVC |
| `kserve.wva` (workload variant autoscaler) | Managed on GPU profiles | Custom Metrics Autoscaler (`openshift-custom-metrics-autoscaler-operator`, `stable`, ns `openshift-keda`). ✓ `KedaController/keda` present, `workload-variant-autoscaler-controller-manager` running | One autoscaled LLMISVC |
| `kserve.nim` | Removed, unless `NGC_API_KEY` is given | NGC account | One NIM deployment when enabled |
| `aigateway.modelsAsAService` | Managed | RHCL | MaaS layer (§7) |
| `aigateway.batchGateway` | Managed | RHCL | `LLMBatchGateway` (`batch.llm-d.ai`) with batch requests against MaaS models. ✓ Operator running; no default instance is created, so the population creates one |
| `modelregistry` | Managed | — | 1–3 registries, model catalog sources |
| `trustyai` | Managed | — | `TrustyAIService` (bias metrics), `LMEvalJob` (offline datasets, `permitOnline: deny` kept), `GuardrailsOrchestrator`, `NemoGuardrails`, `EvalHub` |
| `feastoperator` | Managed | — | `FeatureStore` (`feast.dev`) with features materialised from MinIO parquet |
| `kueue` | **Unmanaged** | **Red Hat build of Kueue** (`kueue-operator`, `stable-v1.5`, ns `openshift-kueue-operator`). ✓ RHOAI creates `Kueue/cluster` itself when the component is `Unmanaged` | Cohorts, a `ClusterQueue` per team, `LocalQueue`s, `WorkloadPriorityClass`es |
| `ray` | Managed | Kueue | `RayCluster`s and `RayJob`s admitted through Kueue |
| `trainer` (Kubeflow Trainer v2) | Managed | **JobSet**: package **`job-set`** (`stable-v1.0`, ns `openshift-jobset-operator`, OwnNamespace) **plus a cluster-scoped `JobSetOperator` CR named `cluster`**. Without that CR: `TrainerReady=False: JobSetOperator CR with name 'cluster' not found` | `TrainJob` (`trainer.kubeflow.org`), using the 12 shipped `ClusterTrainingRuntime`s (CPU, CUDA and ROCm torch-distributed, and training-hub) |
| `trainingoperator` (v1) | Removed | — | Deprecated in favour of `trainer`. Enabled in the 3.4 profile if it ships there (verify), so upgrades carry them, with `PyTorchJob`s |
| `sparkoperator` | Managed | — | `SparkApplication`, `ScheduledSparkApplication` and `SparkConnect` (`sparkoperator.k8s.io`), for ETL feeding Feast |
| `mlflowoperator` | Managed | None to set. `gateway.domain` is **filled in by the DSC controller** from `GatewayConfig` | `MLflow` (`mlflow.opendatahub.io`) and `MLflowConfig` (`mlflow.kubeflow.org`), with experiments and runs logged by seeded notebooks and pipelines. The `mlflow-ui` deployment comes up by itself |
| `ogx` | Managed | A served model and a vector store | `OGXServer` (`ogx.io`), the successor to Llama Stack, wired to a served model. Gen AI Studio playgrounds (`lsd-genai-playground` per project, §6) |
| `llamastackoperator` | Removed | — | Deprecated in favour of `ogx` |
| `mcplifecycleoperator` | Managed | **MCP Gateway** (`mcp-gateway`, `preview`), for the gateway only | `MCPServer` (`mcp.x-k8s.io`), plus MCP catalog and registry entries. Every server registered with the MCP Gateway (§6) |

Not deployed: the ISV application tiles (Starburst, watsonx.ai, Elastic, Pachyderm, EDB, Intel AI Kit), because they need external licences or accounts.

> **No default instances.** MLflow, OGX, MCP, the batch gateway and Feast install only their operators. The population must create every instance it wants, and each one counts toward the inventory (§6).

### Dashboard feature flags

`OdhDashboardConfig.spec.dashboardConfig` on 3.5.1 has about 70 flags. Examples: `genAiStudio`, `modelAsService`, `maasAuthPolicies`, `mlflow`, `observabilityDashboard`, `genAiTracing`, `trainingJobs`, `mcpCatalog`, `mcpRegistry`, `promptManagement`, `agentsCatalog`, `automl`, `autorag`, `guardrails`, `externalModels`, `featureStoreAdmin`, `projectRBAC`, and the `disable*` flags.

- The version profile classifies each flag as **GA, Tech Preview or Dev Preview** for that release.
- `--feature-level ga` (the default) enables GA features only. `techpreview` adds Tech Preview features. Dev Preview flags are never enabled.
- Every flag that ends up enabled gets a check: its dashboard page or API answers correctly for a user (§10.3).

### GPU

GPUs are detected automatically. On this cluster, NFD and the NVIDIA GPU Operator are installed, and the node is a `g6.12xlarge` with 4 × L4.

When GPUs are present:

- The `accelerated-profile` hardware profile is used.
- Real vLLM CUDA LLMISVCs are deployed, with models sized to fit an L4's 24 GB.
- There's a GPU workbench, a GPU `TrainJob` and DCGM metrics.

GPU time-slicing (through the ClusterPolicy device plugin config) can be turned on with `--gpu-sharing` to fit more concurrent GPU workloads. It's off by default, because it changes how GPUs are scheduled.

---

## 9. Observability (layer 35)

Observability is installed **before** any workloads, so metrics, traces and logs record the cluster's history from the start. It must be working end to end (§10.8).

**State on the inspected 3.5.1 cluster:** DSCI `monitoring.managementState: Managed`, but the Monitoring service reports `MonitoringStackAvailable=False (Metrics not configured in DSCI CR)` and `TempoAvailable=False (Traces not configured)`. User workload monitoring is enabled. **This plan configures both.**

**Spike result (§18):** with the configuration below (the guide's phase 7 plus `alerting: {}`), **every Monitoring service condition went True**: MonitoringStack, Tempo, OTel collector, Instrumentation, Alerting, ThanosQuerier, Perses, the Perses Tempo and Prometheus datasources, and the node metrics endpoint. RHOAI creates all of these in `redhat-ods-monitoring`:

- `MonitoringStack/data-science-monitoringstack`
- `TempoMonolithic/data-science-tempomonolithic` (pv backend)
- `OpenTelemetryCollector/data-science-collector`
- Thanos querier, Perses, and the Perses datasources

**RHOAI's own Perses dashboards** include `llm-d-traffic`, `llm-d-utilization`, `llm-d-performance`, `maas-usage-admin`, `maas-usage-logs` and `data-science-tempo-traces`. Our §9 usage dashboards are added **only where these leave gaps**.

**Fixes needed on a single node:**

- **Alertmanager:** the generated MonitoringStack runs 2 Alertmanager replicas with a *required* hostname anti-affinity, so on SNO one pod stays Pending forever. `DSCI.spec.monitoring.alerting` has no replicas field. The `sno` profile patches `MonitoringStack.spec.alertmanagerConfig.replicas: 1`. That held across the spike, but the validator re-checks it, in case RHOAI's reconcile puts it back.
- **Metric names differ by path:** RHOAI's stack scrapes Limitador through the OTel collector, which gives `authorized_hits_total`, `authorized_calls_total` and `limited_calls_total`. The cluster Thanos (user workload monitoring, which maaspal uses) has the same counters without `_total`. Every validator query names its backend.

### Operators

All are available in `redhat-operators` on the inspected cluster.

| Operator | Package / channel | Used for |
|---|---|---|
| Cluster Observability Operator | `cluster-observability-operator` / `stable` | The RHOAI `MonitoringStack` and console UI plugins (dashboards, logging, tracing) |
| Red Hat build of OpenTelemetry | `opentelemetry-product` / `stable` | The OTel collector that DSCI traces and exporters configure |
| Tempo Operator | `tempo-product` / `stable` | Trace storage |
| Logging + Loki *(full only)* | `cluster-logging` / `stable-6.6`, `loki-operator` | `ClusterLogForwarder` and `LokiStack` (on MinIO S3) |
| Network Observability *(full only)* | `netobserv-operator` | Flow metrics between tenants, gateway and models |
| Grafana Operator *(optional, if present)* | `grafana-operator` | `GrafanaDatasource` (Thanos) and RHOAI, vLLM, MaaS and GPU dashboards |

### Configuration

1. **Platform metrics:** `DSCI.spec.monitoring.metrics`, with storage size, retention and replicas taken from the profile. This creates the COO `MonitoringStack` in `redhat-ods-monitoring`.
2. **Traces:** `DSCI.spec.monitoring.traces`, with `storage.backend: s3` on MinIO (`pv` on `small`), `sampleRatio`, TLS, and `collectorReplicas`. Tracing is switched on for vLLM and LLMISVC (OTLP), OGX and Gen AI tracing (`genAiTracing`), and the gateway where supported (**verify**).
3. **Alerting:** `DSCI.spec.monitoring.alerting` loads the RHOAI `PrometheusRule`s. Alertmanager gets an **in-cluster webhook receiver** (`loaded-rhoai/alert-sink`), so alert delivery can be tested end to end.
4. **User workload monitoring:** enabled if it's off, which is a cluster-level change made only with `--enable-uwm` in adopt mode. `ServiceMonitor`s and `PodMonitor`s cover vLLM, OVMS, MLServer, DSPA, Ray, TrustyAI, Feast and MLflow. `disableKServeMetrics: false` and `disablePerformanceMetrics: false` are set, so the dashboard's model metrics pages have data.
5. **Dashboards:**
   - The dashboard's `observabilityDashboard` flag
   - KServe console dashboards (`enableLLMInferenceServiceConsoleDashboards`)
   - COO UI plugins (monitoring, distributed tracing, and logging on `full`)
   - The NVIDIA DCGM console dashboard
   - Optional Grafana
6. **Logs** *(full only)*: `LokiStack` (size `1x.demo` on SNO and `small`, `1x.small` above that) on MinIO. A `ClusterLogForwarder` sends application and infrastructure logs.
7. **Continuous load** (layer 68, next section): a long-running load generator keeps the dashboards full. It gets a head start of at least `OBS_WARMUP` (30 minutes by default) before validation runs.

### Continuous load (layer 68)

**The dashboards need real, per-user activity that keeps going,** not one burst at install time. A `loadgen` Deployment in namespace `loaded-rhoai-load` runs **permanently** and acts as the cluster's users.

**MaaS traffic: per-user token usage**

- **Who sends it:** a seeded subset of MaaS users is "active", about 20% (`LOAD_ACTIVE_USERS`). Each uses **their own API key**, minted through their own Keycloak login (§7). Usage is therefore attributed to real usernames, subscriptions and tiers in `authorized_hits{user, subscription, model}`.
- **How it varies, per user (seeded):**
  - **Request rate:** Poisson arrivals, scaled by tier and persona. Some users are light, some heavy, a few bursty.
  - **Daily rhythm:** traffic follows a day-shaped curve, compressed to a configurable `LOAD_DAY_LENGTH` (2 hours by default), so dashboards show peaks and quiet periods rather than a flat line.
  - **Request shape:** prompt and `max_tokens` sizes come from a long-tailed distribution, so token-per-request histograms are realistic.
  - **Models:** each user only calls models their subscription covers.
  - **Request mix:** chat, completions and embeddings; streaming and non-streaming.
- **Rate limiting:** a small, designated set of free-tier "power users" (`LOAD_RATE_LIMITED_USERS`, default 2) deliberately exceed their token limit, so `limited_calls` and the rate-limit panels show real enforcement. **MaaS token limits apply per user *per model*,** because each model gets its own TokenRateLimitPolicy entry. Power users are therefore pinned to a single model. On the spike, a power user spread across two models used 3,400 tokens a minute against a 2,000-a-minute limit and was never throttled (§18). These 429s are **expected outcomes**. The load generator labels every request `expected` or `unexpected`, and only unexpected errors count as failures.
- **Key rotation:** a few users rotate keys on a schedule (create new, switch, revoke old), so API key metrics and lists change over time.
- **Real GPU models:** when present, they get a fixed share of traffic, so vLLM token throughput, time to first token and KV-cache panels show real numbers.

**Other activity, so every dashboard has data**

- Direct (non-MaaS) inference against running ISVCs, as their owning teams
- OGX chat sessions with retrieval, which also produce Gen AI traces
- MLflow runs logged from scheduled notebook jobs
- Feast online lookups
- A nightly-style `LMEvalJob` CronJob against one served model, which keeps its last 3 completed jobs
- Pipeline recurring runs (already in §6)

**Capacity and control**

- **Rates per profile:** aggregate request rate scales with the profile (for example about 2–5 requests per second on `sno`, 20+ on `medium`). Simulators carry most of the traffic, and real GPU models are capped below saturation.
- **Load can't be the cause of failure:** the load generator must never push a component into an unhealthy state. The soak checks this (§10.9).
- **Commands:** `loaded-rhoai.sh load status|pause|resume|set-rate <x>`.
- **During maaspal runs:** the load generator **pauses traffic to the models under test** while latency- and load-sensitive maaspal scenarios run (`load_test`, `gateway_overhead`, `multi_model_load`), so it doesn't skew their results.
- **Its own metrics:** the load generator exposes requests and tokens sent, broken down by user, model, status class and expected/unexpected. These are scraped by user workload monitoring and used for cross-checks (§10.8).

### Usage dashboards

The `standard` and `full` levels provision these dashboards. They're **Perses dashboards** through the Cluster Observability Operator (Observe → Dashboards; **verify** the CRD name for the installed COO version), and are mirrored to Grafana when it's enabled.

| Dashboard | Panels |
|---|---|
| **MaaS token usage** | Tokens per user (top-N and a searchable table), tokens per subscription and tier, tokens per model, requests vs rate-limited requests per user, quota used against each tier's limit, active users, API keys created, validated and revoked (`maas_api_*`) |
| **Model serving** | Tokens per second (prompt and generation), time to first token and end-to-end latency percentiles, queue depth, KV-cache usage, success rate per model |
| **Gateway and auth** | Authorino decisions by status, Limitador health and latency, gateway request rate and latency |
| **Identity** | Keycloak logins and failed logins per realm and client, token issuance, active sessions (Keycloak metrics) |
| **Platform** | Running workbenches and ISVCs per team, pipeline runs by state, Kueue admitted and pending workloads, GPU utilisation per pod |

These sit alongside RHOAI's own dashboards (the `observabilityDashboard` flag and the KServe console dashboards).

### Levels

| `--observability` | Includes |
|---|---|
| `minimal` | User workload monitoring, platform metrics, alerting |
| `standard` (default) | `minimal` plus traces (Tempo and OTel), console and RHOAI dashboards, GPU metrics |
| `full` | `standard` plus Logging and Loki, Network Observability, Grafana |

---

## 10. Validation (layer 80)

A single in-cluster **validator Job** (image `loaded-rhoai-validator`: Python + pytest + kubernetes client + `oc`) produces JUnit XML, `summary.md` and `report.html`. These are stored in the PVC `loaded-rhoai/reports`, with JUnit and the summary also in a ConfigMap, and the script copies them to `./reports/<timestamp>/`. Every check has a category, severity and expected outcome. Version-gated checks are skipped with a reason rather than failed.

**`validate` is headless and doesn't depend on the caller staying connected.** It creates the Job and follows its logs. If the laptop disconnects, the run continues, and re-running `validate` attaches to the active run rather than starting a second one. The exit code reflects the run's result. The CLI, the Job and CI are the only ways to start a run in v1. There's no web UI for starting runs, because it would add a privileged endpoint on the cluster under test (§16, M8).

**Principle:** a Ready status alone doesn't prove a workload works. Every workload is checked in up to five layers: is it there (§10.1), does it report healthy (§10.2), does it actually work (§10.3, §10.4), does it stay healthy (§10.9), and does the user see the same thing (§10.10). Observability is checked by tracing known activity all the way through to where it's stored and displayed (§10.8).

Order of execution: 10.0 → 10.1 → 10.2 (stop on failure) → 10.3–10.7 → 10.8 → 10.9 → 10.10 → 10.14 → 10.11, then 10.13 if the cluster has been upgraded since the baseline.

### 10.0 Platform health

**Lessons from the 3.5.2 spike (§19) that shape these checks:**
- **Status alone can be wrong in both directions.** Keycloak was `Ready` with its realm wiped. Healthy components showed not Ready for 10–40 minutes, because module operators don't re-check after an instance recovers. So identity is checked by a real login, and before failing on a not-Ready component, the validator annotates its component CR to force a fresh status, and records that it did.
- **Controllers can fail while the DSC is Ready.** Report restarts in the last hour, and any controller over 80% of its memory limit (`controllerResources` in §4).
- **The control plane is part of platform health.** etcd commit p99 above 100 ms, or API lease updates above 1 s, fail the run, because they cause cluster-wide leader-election loss.
- **Evictions and disk.** Any eviction for ephemeral storage during the run fails it, with the node's free-disk minimum in the report.
- **Operator versions.** Any CSV that changed during the run is reported.

- CSV Succeeded, at the requested version, with no unexpected pending InstallPlans apart from the pinned-ahead one
- Every prerequisite, observability and dependency operator CSV is Succeeded (§8, §9)
- DSCI and DSC Ready, and component states match the profile. **Every condition for an enabled component and its dependencies is True**, including `Kserve*Dependencies`, `ModelsAsAServiceReady`, `BatchGatewayReady`, and the Monitoring service's `MonitoringStackAvailable` and `TempoAvailable`
- Operator pods are not crash-looping. Dashboard, kube-rbac-proxy and gateway endpoints answer
- **No alerts firing** at warning or critical severity, checked in **both** the cluster Prometheus and RHOAI's MonitoringStack. Alerts are allowed only through the version profile's `alertAllowlist`, where each entry carries a reason and evidence. The 3.5.1 entries found on the spike are in §4. The report lists every allowlisted alert that fired, so known issues stay visible rather than hidden
- **Scope of pod checks:** RHOAI, dependency, observability, MaaS, Keycloak and managed namespaces only. The spike cluster had leftover `Error` installer pods in `openshift-kube-apiserver` from OCP install time, which aren't ours to judge
- On the GitOps path, no Argo Application is Degraded or OutOfSync

### 10.1 Expected inventory (blocking)

When the generator renders the cluster from `{profile, seed}`, it also writes **`expected-inventory.json`**. This file goes into a ConfigMap on the script path and is a chart output on the GitOps path. It lists every object we create with its **expected state**: `running`, `stopped`, `completed`, `suspended` or `static`. Static objects are things like Secrets, RoleBindings and queues.

The validator compares the live cluster against it, and **any difference fails the run**:

- **Missing:** an object was rendered but isn't on the cluster (for example a lost CR, or a shard that never synced).
- **Unexpected:** an object carries `loaded-rhoai.io/managed=true` but isn't in the inventory.
- **Wrong state:** for example, a notebook that should be stopped is running, or a model that should be running is stopped.

### 10.2 Per-kind status checks (blocking)

The validator has a **check registry** keyed by resource type (`validator/checks/<kind>.py`). For each object in the inventory it runs that type's status check against the expected state. **If a managed object's type has no registered check, validation fails,** so nobody can add a new workload type without adding its check. The settle step in §6 runs this same layer, with a timeout.

| Kind | Healthy when |
|---|---|
| Notebook | Running ones: the StatefulSet is ready and the pod is Ready on every container. Stopped ones: the stop annotation is set and no pod exists |
| InferenceService | Running ones: `Ready` and `PredictorReady` are True. Stopped ones: the stop annotation is set, with no failing conditions |
| LLMInferenceService | `WorkloadsReady`, `RouterReady`, `HTTPRoutesReady`, `GatewaysReady` and `MainWorkloadReady` are all True. A `GatewayPreconditionNotMet` reason **while the `AuthPolicy` CRD exists** gets its own diagnosis in the report: "KServe controllers started before RHCL; restart them" (§7) |
| ServingRuntime / HardwareProfile / ImageStream | The referenced images resolve. ImageStream tags have an `items[]` entry, with no import errors |
| MaaSModelRef / MaaSSubscription / MaaSAuthPolicy | Ready, Active and Ready respectively, with no `SpecPriorityDuplicate` condition |
| TokenRateLimitPolicy / AuthPolicy / RateLimitPolicy / HTTPRoute | `Accepted` and `Enforced` are True / the route is `Accepted` |
| TelemetryPolicy | `Accepted` and `Enforced` are True. The MaaS policy carries the `user`, `group`, `subscription` and `model` labels |
| Gen AI playground | The `OGXServer` is Ready (running ones) or scaled to zero (stopped ones). Every MCP server, vector store and model in its settings ConfigMaps exists |
| MCPGatewayExtension / MCPServerRegistration / MCPVirtualServer | Ready. Every registration's server is reachable, and every `MCPServer` in the inventory has a registration |
| DSPA | `Ready` is True, plus the conditions for its API server, persistence agent, scheduled workflows and database. `WebhookReady` and `ManagedPipelineValid` are False with reason `NotApplicable` on a healthy DSPA, which counts as a pass |
| Pipeline runs | Historical runs are `SUCCEEDED`. Recurring runs are enabled, and their latest run succeeded |
| ModelRegistry | `Available` is True. The REST endpoint is reachable |
| FeatureStore / OGX distribution / TrustyAIService / GuardrailsOrchestrator / NemoGuardrails / EvalHub | `Ready` or `Available` (per the version profile) |
| LMEvalJob | `Complete`, with results recorded |
| InferenceGraph | `Ready` |
| MLflow instance | `Ready`. The tracking server answers through the gateway |
| MCP servers | `Ready`, and registered in the MCP catalog or registry |
| SparkApplication | `COMPLETED` (history) or `RUNNING` (streaming) |
| RayCluster / RayJob | `ready`, or suspended through Kueue as expected / `SUCCEEDED` |
| TrainJob / PyTorchJob | `Succeeded` or `Complete` |
| MonitoringStack / TempoStack or TempoMonolithic / OpenTelemetryCollector | `Available` or `Ready`, with every component replica up |
| LokiStack / ClusterLogForwarder *(full)* | `Ready` / `Ready` and every output `Valid` |
| ServiceMonitor / PodMonitor | Every target it selects is `up == 1` (from the Prometheus targets API) |
| PrometheusRule | Loaded with rule health `ok` (no evaluation errors) |
| Keycloak / KeycloakRealmImport / PostgreSQL | `Ready` / `Done` (initial import) / pod Ready. The realm's OIDC discovery endpoint answers through the Route |
| OAuth IdP | The `authentication` ClusterOperator is Available, and neither Progressing nor Degraded. The `keycloak` IdP is present |
| loadgen | Deployment available. Its own metrics show traffic in the last 2 minutes, and **zero unexpected errors** |
| Kueue Workload / ClusterQueue / LocalQueue | Workloads are Admitted or Finished, never stuck waiting for quota. Queues are `Active` |
| PVC | Bound, or `WaitForFirstConsumer` and only referenced by stopped workloads |
| Secret (connections) | The required keys are present, and the endpoint resolves (S3 `HeadBucket` against MinIO) |
| RoleBinding | Every subject is a User or Group that exists |
| Pods (all of the above) | Every container Ready, no `Waiting` reason, restart counts unchanged across two samples taken 60 s apart. A `CreateContainerError` mentioning `odh-trusted-ca-bundle ... Not a directory` is diagnosed in the report as the CA bundle race (§6), with the fix (delete the pod) |
| Jobs (seeding, history) | None Failed. Succeeded ones are already removed by TTL |

The same layer also scans **RHOAI-owned namespaces** (operator, applications, model registries, MaaS) for the pod and condition rules above.

### 10.3 Functional probes: every running workload

Only a few workloads run at once (about 15 notebooks and 8 models on `medium`), so **every** running workload gets a real request, not just a sample:

| Workload | Probe |
|---|---|
| Notebook | Open its URL with the **owner's token** (expect 200), execute a Python cell through the kernel API (`2+2` returns `4`, then a check that the PVC is writable), and open it as a user from another team (expect 403) |
| InferenceService | Send a real prediction request in the runtime's protocol and check the response shape. A request without a token gets 401 where token auth is enabled |
| LLMInferenceService (MaaS) | Send a chat completion through the MaaS gateway with an API key from **each** tier that covers the model (non-empty `choices`, `usage.total_tokens > 0`), and a direct request to the workload service |
| DSPA | API server `/healthz`, list runs as a team member, and download an artifact from a historical run's MinIO path |
| ModelRegistry | List and get registered models and versions as an authorised user, and expect 403 as an unauthorised one |
| FeatureStore / OGX / TrustyAI / Guardrails | One request each: a feature lookup, a `/v1/models` list plus a chat completion that retrieves from the vector store, a metrics endpoint, and a guardrail detection request |
| MLflow | Log a run with a parameter and a metric as a team member, read it back, and expect 403 from another team |
| MCP server | `tools/list` returns the tools that were registered |
| GPU LLMISVC | A real completion, plus a DCGM `DCGM_FI_DEV_GPU_UTIL` reading above 0 for its GPU during the request |
| Dashboard feature flags | For every enabled flag, its page route and backing API return 200 for a normal user, with content that isn't empty (for example, Gen AI Studio lists the OGX distributions) |

### 10.4 Stopped workloads: would they start?

Starting hundreds of stopped workloads isn't practical, so there are three levels.

1. **Every stopped workload** gets a static check. The validator checks that everything it depends on exists: image or ImageStream tag, hardware profile, PVC, ServiceAccount, connection Secret and ServingRuntime. It then sends the "start" patch (removing the stop annotation) with `--dry-run=server`, which passes it through the admission webhooks without applying it.
2. **A rotating sample** gets a full start, probe and stop cycle, using the §10.3 probes. Each run picks a different set from `hash(seed, run_number)`, so repeated runs eventually cover the whole population. The default is 5 notebooks and 3 ISVCs, set by `--sample-size`.
3. **`--exhaustive`** starts, probes and stops **every** stopped workload in batches. The batch size is set by the cluster's spare allocatable CPU and memory, which the validator measures before each batch. This is for nightly runs or release sign-off.

Every workload is returned to its expected state afterwards, and the §10.1 inventory check runs again at the end.

### 10.5 Component end-to-end

These checks exercise each component with new work, not just existing objects:

- **Pipelines:** submit a hello-world run through the KFP API as a team member and wait for Succeeded.
- **Model Registry:** register a version, then delete it.
- **Kueue, Ray and training:** submit a tiny job to a team LocalQueue and check admission and completion. Submit an over-quota request and check it's held, not run. Run a `TrainJob` and a `RayJob` to completion.
- **Spark, Feast and MLflow:** a `SparkApplication` writes parquet to MinIO. Feast materialises it, and the online store serves the new values. The run is logged to MLflow.
- **Evaluation:** an `LMEvalJob` against a served model completes with scores.
- **Workbench lifecycle:** create a new notebook in a sandbox as its owner, through the dashboard API, then delete it.

### 10.6 Identity, RBAC and multi-tenancy at scale

- **OIDC login:** for a seeded sample of users from every persona and tier, log in through the Keycloak IdP. Check the `User` and `Identity` (`keycloak:<sub>`) exist and that **OpenShift group membership exactly matches Keycloak**.
- **Every user has logged in:** each generated user has a `User` object, which shows the warm-login reached everyone.
- **MaaS tier comes from Keycloak:** for each tier, a Keycloak user logs in, creates an API key, and infers. The request is attributed to that user and tier's subscription (`X-MaaS-Subscription`, and `authorized_hits{user, subscription}`). A Keycloak user in no `maas-*` group gets no subscription and is denied.
- **Group changes take effect:** move a dedicated test user from `maas-free` to `maas-premium` in Keycloak. After they log in again, OpenShift's group sync and MaaS both reflect the new tier, with the premium limit applied. Then move them back, so nothing is left changed.
- **Disabled users:** a temporary Keycloak user is disabled and can't log in. The user is then deleted, along with their `User` and `Identity`.
- **Permissions:** `oc auth can-i --as=<user>` matrix over a seeded sample of users × namespaces × verbs, covering both expected allow and expected deny.
- **Dashboard project list:** call the dashboard's project-list API **as several users** and check each sees exactly their projects. Record latency for the user with the most projects.
- **Admins:** admin-group users see admin pages and non-admins don't.

### 10.7 MaaS via maaspal

maaspal has no CLI. The runner drives the BFF API from inside the BFF pod, which sidesteps the NetworkPolicy:

```
oc exec -n cp-maaspal deploy/maaspal-bff -- python -c '…httpx.post(
  "http://localhost:3000/api/runs",
  headers={"Authorization": f"Bearer {TOKEN}"},          # SSAR-checked token
  json={"scenario": S, "config_overrides": {"send_from_browser": False, …}})'
```

The runner then polls `/api/runs/{id}` until the run is terminal, collects `/api/runs/{id}/assertions`, and maps each run to JUnit test cases.

- `send_from_browser` is always forced off, because no browser is attached.
- **Assertion status** is read from each assertion's `status` (`PASSING`, `FAILING`, `PENDING`). Treat `PENDING` at the end of a run as a failure.
- **`usage_metrics_accuracy`'s `limitador_namespace`** must be `<namespace>/<route>` (Limitador's label value), not a namespace.
- **Known failures on 3.5.2 (spike, §19 row 17):** `keys_share_user_budget` and `gateway_overhead`. Report them as known issues with the evidence rather than as blocking until maaspal or MaaS changes. A new failure in any other scenario is blocking.
- **Results survive a dropped `oc exec`:** the runner records each run ID and recovers results from `GET /api/runs` if the stream resets.
- **Suites** (`MAASPAL_SUITE`):
  - `quick`: `smoke_test`, `model_config_health`, `verify_subscription`, `request_types`
  - `standard` (default): quick plus `verify_subscription_rate_limit`, `keys_share_user_budget`, `rate_limit_window_recovery`, `subscription_auto_selection`, `denied_without_auth_policy`, `api_key_lifecycle`, `usage_metrics_accuracy`
  - `full`: standard plus `load_test`, `gateway_overhead`, `multi_model_load`, and `rate_limit_per_user_or_shared` (which sets `rbac.userProvisioning=true` on the chart)
- **Parametrised runs:** `verify_subscription` and `verify_subscription_rate_limit` run **once per generated tier**, using a user from that tier's group, so priority resolution across overlapping groups is exercised.
- **Overview cross-check:** read `/api/maas/subscriptions`, `/models` and `/auth-policies`, and assert that every seeded subscription and model appears **with no warnings**. That means for each one: `model_exists`, `model_ready` and `has_auth_policy` are true, `gateway_access_label` is true, no `SpecPriorityDuplicate` condition is set, and on 3.5+ `credential_secret_label_ok` is true.
- **Cleanup check:** explore scenarios such as `denied_without_auth_policy` create temporary misconfigurations by design. After each run, the runner checks that maaspal's cleanup removed them, then re-runs §10.1 and §10.2, so the cluster is left as healthy as before.
- **Fallback:** if the BFF API changes, create the harness Job directly with the BFF image (`python -m harness.main --scenario … --run-id …`) and read `/data/results/<id>.json`. This mirrors `api/k8s.py:create_job`, including node pinning to the RWO PVC.

### 10.8 Observability end to end

Each signal is checked by **creating known activity and finding it where it's stored and where it's displayed**. A healthy collector that stores nothing still fails.

| Signal | Check |
|---|---|
| **Metrics: scraping** | Every target in the platform `MonitoringStack`, cluster monitoring and user workload monitoring that belongs to an RHOAI, dependency or managed namespace is `up == 1` |
| **Metrics: freshness** | For each enabled component, its key metrics (listed in the version profile, for example vLLM `vllm:num_requests_running`, Limitador `authorized_hits`, TrustyAI `trustyai_spd`, DCGM `DCGM_FI_DEV_GPU_UTIL`) return series with a sample from the last 2 minutes |
| **Metrics: accuracy** | Send exactly N requests to a model, then check its request counter rose by N. maaspal's `usage_metrics_accuracy` does the same for MaaS |
| **Token usage per user** | For **every** active load user, `authorized_hits{user=<name>}` rose over the last 10 minutes, with the `subscription` label matching their Keycloak tier. Over the same window, the load generator's tokens per user and Limitador's token counts per user agree within a tolerance (5% by default). **Measured as a raw counter delta between two quiet periods, not with `increase()`.** On the spike, `increase()` read +39% because it extrapolates and its window overlapped earlier traffic. The raw delta matched the load generator exactly: 4,615 tokens against 4,615 (§18). On the 3.5.2 spike, 62 users over 8 minutes also matched exactly, per user, including 429 counts (§19 row 16). The load generator's `/tmp/pause` switch makes the quiet periods; never compare across a load generator restart. The rate-limited power users show `limited_calls > 0`, and nobody else does |
| **Usage dashboards** | Every panel of the §9 usage dashboards returns data. The tokens-per-user panel returns at least `LOAD_ACTIVE_USERS` series, and those names are Keycloak usernames |
| **Traces** | Send an inference request (direct, and through MaaS) and an OGX chat with a **known `traceparent`**. Query the Tempo API for that trace ID, and expect spans from each hop listed in the version profile (gateway, router, model server, OGX) |
| **Logs** *(full)* | The validator writes a unique marker line from a pod in a tenant namespace, and from an infrastructure pod. LogQL through the logging API finds both within 2 minutes, labelled with the right namespace |
| **Alerting: rules** | Every RHOAI and managed `PrometheusRule` is loaded with health `ok` |
| **Alerting: delivery** | Create a synthetic `PrometheusRule` (`vector(1)`, labelled `loaded_rhoai_test`). Check it fires, is routed, and arrives at the in-cluster alert sink. Then delete it and check it resolves. This is the only alert excluded from the "no firing alerts" check |
| **Dashboards: RHOAI** | For each running model, the dashboard's model metrics API returns data when called **as the owning user**. Gen AI tracing views show the traces sent above |
| **Dashboards: console and Grafana** | Read every RHOAI, KServe, MaaS and GPU dashboard definition (console dashboard ConfigMaps, Perses, Grafana), run **each panel's query**, and fail on any panel for an enabled component that returns no data. Grafana's datasource health API returns OK |
| **Network flows** *(full)* | Flow records exist between a tenant namespace and the MaaS gateway |

### 10.9 Stability soak

After all of the active tests, the validator watches the cluster for a period (`--soak`, 10 minutes by default). **The run fails if any of these happen:**

- A container restart count goes up.
- A Ready condition flips to False, even briefly.
- A new `Warning` event appears on a managed object or in an RHOAI namespace.
- An alert starts firing (warning or critical, apart from the allowlist).
- A scrape target goes down.
- The load generator records an **unexpected** error (any 5xx, a 401 or 403 for a valid key, or a 429 for a user who isn't a designated power user), or its traffic stops.
- An Argo Application leaves Synced/Healthy.

The soak runs **with the load generator running at its normal rate**. That's what shows the cluster stays healthy under ongoing use.

The soak runs at the end because §10.4 and §10.7 deliberately change the cluster. It shows that the cluster settles back to healthy after them.

### 10.10 User's view matches the cluster

For each user sampled in §10.6, the validator calls the dashboard API **with that user's token** and checks that the status shown for their workbenches, models and pipeline servers (Running, Stopped and so on) matches the §10.2 result. This catches cases where the cluster is fine but users would see something wrong.

### 10.11 Scale signals (advisory)

Queried from Thanos:

- API server p99 request latency
- etcd object counts by resource
- Dashboard and operator memory and CPU
- Operator reconcile durations
- Time to Ready for each layer, recorded during install

These are reported with thresholds as warnings, not failures. Dashboard responsiveness as users experience it is tested separately (§10.14).

### 10.12 Report

- **`summary.md`:** pass/fail for each layer, then a **per-object table**. Each row has the namespace, kind and name, expected state, actual state, the checks run (status, probe, start-cycle) and, if one failed, the status message and the last relevant events. When something fails, you go straight to the object instead of re-investigating.
- **`junit.xml`:** one test case per object per check, for CI.
- **`coverage.json`:** which stopped workloads have had a full start cycle across all runs so far, so the rotating sample's coverage can be tracked.
- **`report.html`:** a single self-contained file with no external assets, generated from the same results as `junit.xml` and `summary.md`, so the three can't disagree. It shows pass/fail by layer with failures first, and a searchable, filterable per-object table. Failed rows link to the object's logs and the relevant dashboard. It's stored on the PVC only, because at `large` it can exceed a ConfigMap's 1 MiB limit.

**Viewing reports on the cluster:** a small read-only `report-server` Deployment serves the reports PVC through a Route, behind OpenShift login, and is limited to `rhoai-admins`. It can only read reports: it can't start runs and has no cluster permissions of its own. Because the PVC is ReadWriteOnce, the validator Job uses pod affinity to run on the same node. The server is part of the expected inventory and is checked like any other workload. If it's down, `loaded-rhoai.sh report` still fetches the files, and the run's result doesn't depend on it.

**Reports never contain secrets.** Report generation redacts passwords, tokens and API keys from status messages and events, and a test checks this against a run with seeded credentials.

### 10.13 Upgrade comparison (runs when an upgrade is detected)

The normal checks show the cluster is healthy after an upgrade. This shows the upgrade didn't quietly change or lose anything, by comparing against the baseline saved before it (§5). The baseline holds every managed object's spec and state, plus the workbench markers, registry entries, run history and MaaS key checks below:

| Check | Passes when | Severity |
|---|---|---|
| **Objects** | Every managed object still exists, matched by name, or has its mapped replacement. No spec changed apart from the profile's `upgrade.expectedChanges` and, for a minor, the path file's | Blocking |
| **Migration** (minor only) | Every required step in the path file passes its check | Blocking. Optional steps are warnings |
| **Non-admin view** (minor only) | A regular user sees AI asset endpoints and MaaS pages in the dashboard, since the guide describes this as a failure admins can't see | Blocking |
| **Model routing** | Each model answers on its current route, and the response comes from the model requested. The guide's RHOAIENG-93709 describes traffic reaching the wrong model on 3.5 with several models on one gateway | Blocking |
| **Workload state** | Running workloads are running and stopped ones are still stopped, with none started by the upgrade | Blocking |
| **Customised variants** (§6) | Every variant's customisation is still in its spec (or converted as `upgrade.expectedChanges` says) and its effect probe still passes. The report states, per variant, whether the operator kept, rewrote, dropped or rejected it | Blocking |
| **Pinned references** | For each object that names a versioned shipped artifact (LLMInferenceServiceConfig, runtime template, image tag, ClusterTrainingRuntime), the report shows the reference before and after, whether the target still exists, and whether the object re-resolved and rolled its pods. For LLMInferenceServices, compare `status.annotations` and `status.appliedConfigs` | Blocking if the object is broken. Otherwise advisory, as a finding |
| **User data** | Marker files on workbench PVCs, model registry entries and pipeline run history are all still there | Blocking |
| **Identity and MaaS** | Keycloak users can still log in. MaaS API keys issued before the upgrade still work. Limits are actually enforced, proved by the power users still getting 429s, because the guide reports a policy can show `Enforced` with no effect | Blocking |
| **Startability** | A rotating sample of stopped workloads goes through a full start cycle on the new version | Blocking |
| **Metric continuity** | Per-user token panels show data on both sides of the upgrade, and the counters still match the load generator | Blocking |
| **Stability** | The soak (§10.9) passes after the upgrade | Blocking |
| **Disruption** | Reports load errors during the upgrade, the longest gap in traffic, and pod restarts by component | Advisory until M6a gives a measured baseline |

We don't run the upgrade, so its time window comes from the cluster: the InstallPlan and CSV timestamps. The metric checks query Prometheus for that window. If the user validates after retention has dropped it, those two checks are skipped with the reason, not passed, so `validate` should run soon after the upgrade.

The report header shows the upgrade path, such as `3.5.0 → 3.5.2`, and that detected window. Legitimate changes go in the new version's `upgrade.expectedChanges`, each with a reason, rather than being ignored.

### 10.14 UX testing: does the dashboard stay usable at scale?

A lived-in cluster is where a slow UI shows up: pages that are instant with 5 projects may crawl with 500. API checks can't catch this, because much of the wait can be in the browser fetching, filtering and rendering. So this runs a **real headless browser** (Playwright with Chromium), logged in through the real Keycloak and OpenShift login flow. It has its own image, `loaded-rhoai-ux`, because Chromium is large.

**Who it logs in as.** Results depend on what a user can see, so each journey runs as:

| User | Why |
|---|---|
| `rhoai-admin` | Sees every project, so this is the worst case |
| Team lead | Sees a team's projects and some shared ones |
| Regular user | Sees a few projects, but the dashboard may still do cluster-wide work on their behalf |

**What it measures, on each page:**

- **Time to usable:** from navigation until the page's real content is on screen and the loading indicators have gone. A spinner or empty table doesn't count. This is the main number.
- **Content is right:** the page shows the number of items the expected inventory says this user should see, so a fast page with missing data fails.
- **Interaction time:** for example, typing in the project search until the list has filtered, and opening a project from the list.
- **API calls:** the count, size and duration of each request the page makes, so a slow page points straight at its cause, such as a call that lists every namespace.
- **Errors:** browser console errors and failed API calls.

**Pages covered** (the version profile holds each page's URL and "content is ready" selector, since these change between releases):

- Sign-in to the first usable page
- Projects list, including search, and a project's detail page with its tabs
- Workbenches and model deployments, across projects
- Pipelines and runs
- Model registry and catalog
- MaaS: AI asset endpoints, API keys, subscriptions
- Gen AI Studio, including the Playground
- Distributed workloads and training jobs
- Observability dashboards
- Settings: hardware profiles, user management, cluster settings

**How it runs:**

- **Cold and warm:** each journey runs in a fresh browser profile, then again with its cache. Five runs each, reporting median and p95.
- **Under load:** the load generator keeps running, and the check is also run with several browser sessions at once (5 by default, `--ux-sessions`), to see whether the dashboard backend degrades when people share it.
- **Failure evidence:** a screenshot, the browser trace, and a network log with tokens removed. The redaction rule in §10.12 applies to all of them.
- **Backend correlation:** the report includes the dashboard pods' CPU, memory and restarts during the run.

**Pass criteria.** The budgets below are starting proposals, not measurements, so they're advisory until real results from `small`, `medium` and `large` (M7) show what's reasonable. After that, they become blocking.

| Measure (p95, admin user) | Proposed budget |
|---|---|
| Sign-in to first usable page | 10 s |
| Projects list, time to usable | 5 s |
| Other page, time to usable | 5 s |
| Project search responding | 1 s |
| Any single API call | 3 s |

Three checks block from the start, because they don't depend on knowing a good number:

- Every page reaches usable within a hard timeout (60 s).
- The content matches the inventory.
- No console errors or failed API calls, apart from an allowlist with reasons.

**Two comparisons matter more than the absolute numbers:**

- **Across profiles:** the report plots time to usable against project count. A page that gets much slower as projects are added is flagged even if it's still inside budget, because customers can have far more projects than we test.
- **Across upgrades:** the baseline (§5) stores these timings, and §10.13 flags pages that became noticeably slower after an upgrade.

Measurements run from inside the cluster, so they leave out the user's own network delay. They're best compared with each other, not treated as what a user on a remote connection would see.

---

## 11. maaspal install (layer 70)

- `helm upgrade --install maaspal oci://quay.io/rh-ai-community-plugins/maaspal-chart --version <pinned>` into `cp-maaspal`
  - Label the namespace `maas.opendatahub.io/gateway-access=true`
  - Set `maas.defaultModel` to a seeded simulator model and `access.groups[0]=rhoai-admins`
- **Dashboard registration:** add an entry to `MODULE_FEDERATION_CONFIG` on `deployment/rhods-dashboard`, merging it with existing entries rather than replacing them.
  - On the GitOps path this runs as a PostSync Job, because the Deployment is operator-owned and can't live in git.
  - The maaspal Application `ignoreDifferences` on that env var.
- The maaspal chart version is pinned per version profile (`maaspal.chartVersion`).

---

## 12. GitOps path

```
loaded-rhoai.sh bootstrap-gitops
  ├─ detect install/adopt (same code as §5)
  ├─ install OpenShift GitOps, ArgoCD CR tuning (controller 6Gi+, Subscription health override, resource exclusions)
  └─ apply root Application:
       source: { repoURL: $REPO_URL, path: gitops/root, helm.valuesObject:
                 { rhoaiVersion: 3.5.2, profile: medium, seed: 42, rhoai.manage: true|false, … } }
```

- **Root chart:** renders child Applications by sync wave. It uses the same waves as §3 plus an `ApplicationSet` for population shards. `repoURL` and `targetRevision` are passed down as values, so no fork rendering or committing is needed.
- **Population self-heal policy:** the `kubeflow-resource-stopped` annotation, ISVC stop annotations and replica counts change through normal user activity. Population apps `ignoreDifferences` on those fields, so Argo doesn't undo a user stopping their notebook.
- **Validation:** a final-wave Application whose `Sync` hook is the validator Job. Re-run it with `loaded-rhoai.sh validate`, which works the same on either path.
- **Day 2:** change `profile` or `seed` on the root app and Argo converges. Shard Apps that are no longer generated get pruned. RHOAI upgrades are the user's and don't go through the root app (§5).
- **Secrets never go in git.** Keycloak's admin and database credentials, the `openshift` client secret, user passwords and API keys are all generated by in-cluster Jobs. The `OAuth/cluster` IdP entry is added by a Job, which merges it with the existing IdPs, rather than being an Argo-owned resource. Argo would otherwise overwrite the cluster's other IdPs.
- **Keycloak changes go through the realm-config Job,** which Argo re-runs as a Sync hook whenever the identity values change.

---

## 13. CLI surface

```
./loaded-rhoai.sh install          [--version 3.5.2] [--profile medium] [--seed 42]
                                   [--accept-installed] [--enable-missing] [--enable-maas]
                                   [--settle-timeout 45m] [--gpu auto|1|0] [--gpu-sharing]
                                   [--observability minimal|standard|full] [--enable-uwm]
                                   [--feature-level ga|techpreview] [--components all|<list>]
                                   [--idp keycloak|htpasswd|both|none] [--auth-mode oauth|direct-oidc]
                                   [--load-active-users 20%] [--load-rate <rps>] [--no-load]
                                   [--ngc-api-key-file <path>] [--skip-maaspal]
                                   [--require-verified]
./loaded-rhoai.sh profile          show --version 3.5.2   # the resolved profile and its verified status
./loaded-rhoai.sh load             status|pause|resume|set-rate <rps>
./loaded-rhoai.sh creds            <user>   # print a generated user's Keycloak password
./loaded-rhoai.sh bootstrap-gitops [same flags] --repo-url <git> [--revision main]
./loaded-rhoai.sh validate         [--maaspal-suite quick|standard|full] [--sample-size 5]
                                   [--exhaustive] [--soak 10m] [--reset-baseline]
                                   [--skip-ux] [--ux-sessions 5]
./loaded-rhoai.sh report           [--url]   # fetch latest report to ./reports/; --url prints the report Route
./loaded-rhoai.sh status           # per-layer progress, object counts
./loaded-rhoai.sh uninstall        # only loaded-rhoai.io/managed=true; RHOAI only if we installed it
```

Configuration can come from flags, from environment variables (`RHOAI_VERSION`, `PROFILE`, …) or from `loaded-rhoai.env`, in that precedence order. Each phase is also runnable on its own, as `phases/NN-*/run.sh`, matching the existing repo's convention.

---

## 14. Repo layout

**Built so far (2026-11-10): the script path for RHOAI 3.5.2,** converted from the spike. It has `loaded-rhoai.sh`, `lib/common.sh`, `phases/NN-*/run.sh`, `tools/` (generator, Keycloak seeding, sweep, maaspal runner), `loadgen/`, `manifests/`, and `versions/3.5.2/`, which holds the pins, manifests and lock file. It differs from the layout below in four ways:
- **No Helm charts yet:** manifests are plain YAML or JSON, and the population is generated JSON shards.
- **Version pins are a shell `version.env`** per exact release, not `profile.yaml` with z-stream overrides.
- **MaaS, observability and Keycloak** still run the guide's scripts at a pinned commit, rather than being ported into charts.
- **Validation is the spike's sweep plus the guide's checks,** not the §10 validator.

Its README lists what isn't deployed yet.

```
loaded-rhoai/
├── loaded-rhoai.sh
├── lib/common.sh                 # ported from rhoai-2254-install + version/adopt helpers
├── versions/{3.4,3.5}/           # profile.yaml, z/<x.y.z>.yaml overrides, locks/<x.y.z>.yaml (§4),
│                                 # upgrade-from-<x.y>.yaml minor upgrade paths (§5)
├── profiles/{small,medium,large}.yaml
├── charts/
│   ├── prereqs/                  # operators per version profile
│   ├── rhoai/                    # Subscription, approver Job, DSCI/DSC
│   ├── platform/                 # HW profiles, dashboard config/flags, Kueue, MinIO
│   ├── observability/            # DSCI monitoring, Tempo/OTel, alert sink, UWM, dashboards, Loki
│   ├── components/               # per-component config + dependencies (§8)
│   ├── maas/                     # models, subscriptions, auth policies, seeding Job
│   ├── identity/                 # RHBK operator, Postgres, Keycloak CR, realm import +
│   │                             # realm-config Job, OAuth OpenID IdP, warm-login Job
│   ├── load/                     # loadgen Deployment, ServiceMonitor, CronJobs
│   ├── dashboards/               # Perses (COO) + Grafana usage dashboards (§9)
│   ├── population/               # sharded namespaces + workloads (seed-driven)
│   └── validate/                 # validator Job, RBAC, report PVC, read-only report-server + Route
├── validator/                    # Python pytest suite; Containerfile
│   ├── inventory.py              # expected-inventory diff (§10.1)
│   ├── checks/<kind>.py          # per-kind status check + functional probe + start-cycle (§10.2–10.4)
│   ├── maaspal_runner.py         # §10.7
│   ├── observability/            # metrics, traces, logs, alerts, dashboard-panel checks (§10.8)
│   └── soak.py, report.py, upgrade_compare.py   # upgrade_compare: §10.13
├── ux/                           # Playwright journeys, page definitions, budgets (§10.14); Containerfile
├── loadgen/                      # Python asyncio load generator + Containerfile
├── gitops/
│   ├── bootstrap/                # GitOps operator, ArgoCD CR tuning
│   └── root/                     # app-of-apps chart + ApplicationSet
├── phases/NN-*/run.sh            # script path, one per layer
└── docs/
```

---

## 15. Cluster sizing (to be measured in M7)

**Measured on the 3.5.2 spike (§19), `medium`-sized population** (355 projects, 350 workbenches with 15 running, 300 users, 10 models):
- **Layout:** 3 unschedulable control-plane nodes (`m6a.4xlarge`) and 3 workers (`m5a.8xlarge`, 32 vCPU and 128 GiB), one per zone, was comfortably enough. Workers ran at 3–20% CPU and 12–40% memory once settled.
- **What limits these clusters isn't CPU.** It's control-plane disk, while workloads share it; worker root disk, which needs 250 GB; and the memory limits of RHOAI's own controllers (§4 `controllerResources`).

**Snapshot of the same cluster, 2026-11-10** (after a restart, with continuous MaaS load):

| | Workers (3 × m5a.8xlarge) | Control plane (3 × m6a.4xlarge) |
|---|---|---|
| CPU requested / used | 32 of 94 cores (34%) / about 4 cores | about 15% / 6% |
| Memory requested / used | 71 of 347 GiB (20%) / 48 GiB | about 16% / 34–39% of 64 GB each |
| Pods | 250 of 750 | 184 of 750 |
| `/var` disk | 19–22% of 250 GB | |
| EBS volume attachments | **37 of 78** (8, 10 and 19 on the three workers; limit 26 per node) | |
| PVCs | 372, 455 GiB in total | |

**Estimate for the full `medium` population,** adding the remaining models, customised variants, playgrounds, MCP Gateway, Kuadrant policies and the four unpopulated components (unmeasured):
- 150 models cost little, because only 8 run. This cluster already ran 152 in the model-count test (§19).
- The additions need roughly **25–35 cores and 60–90 GiB of requests** and about 100 more pods. The heaviest are the 6 pipeline server variants, the P/D and scheduler LLMInferenceServices, an autoscaling RayCluster, guardrails, and a few running playgrounds. A real TinyLlama on vLLM CPU adds 4–8 cores and 8–16 GiB.
- That brings worker CPU requests to about **65–70%**, memory under half and pods about half. It fits, but with little room for more running workloads.
- **Volume attachments bind first.** Each running pod with a PVC uses one, and the additions bring about 15–20 more (databases for pipelines, Feast, model registry, MLflow, TrustyAI and playgrounds), so about 55 of 78. Larger AWS instances have about the same per-node limit, so more attachment room means more workers.
- **Recommendation:** 3 × m5a.8xlarge workers for `medium` at the profile's running counts. Add a fourth when the validator shows attachment or CPU pressure, or to run real CPU models alongside everything else. Preflight counts projected PVC-backed running pods against `26 × workers` and refuses the profile when it doesn't fit.

| Profile | Workers (non-GPU) | Storage | Notes |
|---|---|---|---|
| `sno` | 1 × 48 vCPU / 180 GiB (for example `g6.12xlarge` with 4 × L4) | ~300 GiB | Matches the inspected cluster. **Limited by pods per node (250 by default) and EBS volume attachments per node, not CPU.** Caps running workloads at about 60 pods' worth on top of the platform, `--observability standard`, `LokiStack 1x.demo` if `full` |
| small | 3 × 16 vCPU / 64 GiB | ~300 GiB | Fits a typical RHDP or demo cluster |
| medium | 3 × 32 vCPU / 128 GiB (measured, above), or 6 × 16 vCPU / 64 GiB | ~1.5 TiB | PVC count is the main storage driver. Six smaller workers also give twice the volume attachments |
| large | 10+ × 16 vCPU / 64 GiB | ~5 TiB | Watch EBS volume quotas and etcd size |

Observability adds roughly 4–8 vCPU and 16–24 GiB at `standard`, and Loki adds more at `full`. Preflight adds this to the profile's estimate and **refuses to start a profile the cluster can't hold healthily**, rather than producing Pending pods. It also chooses `sno` automatically when there's a single node.

PVCs are only bound when the provisioner is `Immediate`. Preflight warns when the projected PVC total exceeds a configurable budget, and `--pvc-mode=lazy` creates PVCs only for running workbenches.

---

## 16. Milestones

| # | Deliverable | Exit criteria |
|---|---|---|
| **M0** | Repo scaffold, `lib/common.sh` port, config precedence, version profile schema with z-stream overrides, `profile show`, preflight | `preflight` passes or fails correctly for 3.4.x, 3.5.x and unknown versions. Unit tests cover override merging, including `remove` and `fixedIn` |
| **M1** | Install-or-adopt RHOAI (script path) for 3.4 and 3.5, version profiles verified against the docs. **The 3.4 profile is verified on a real 3.4 cluster,** since every minor-upgrade test starts there | Fresh install reaches DSC Ready at the exact CSV, on both minors. Adopt mode leaves a pre-existing install unchanged |
| **M2** | Platform layer with **all components and their dependencies** (§8), observability layer at `standard` (§9), validator skeleton (§10.0), check registry, the JUnit, summary and HTML reports, and the read-only report server | Every DSC and Monitoring condition is True. No firing alerts. `validate` green on a bare install and survives the CLI disconnecting. The report is viewable through its Route by `rhoai-admins` only, and the secret-redaction test passes |
| **M3** | Keycloak identity (operator, Postgres, realm, OAuth OpenID IdP with group sync, warm-login of every user), population chart at `small`, sharded apply, seeding Jobs, `expected-inventory.json`, per-kind status checks for every kind (§10.1, §10.2), settle step, customised variants with effect probes (§6), Gen AI playgrounds, MCP Gateway with every MCP server registered, Kuadrant policies | Deterministic: same seed gives an identical inventory (diffed). Re-run is a no-op. Zero inventory differences and zero failing status checks. No managed kind is missing a check. Every variant the profile lists is created and its effect probe passes, or is skipped with a reason. A generated playground matches one created through the dashboard (diffed) |
| **M4** | MaaS layer (models, Keycloak-group tiers, policies, per-user key seeding, Kuadrant metrics), **continuous load generator**, **usage dashboards** | MaaS REST lists models. A Keycloak user in each tier can infer, attributed to the right subscription. The tokens-per-user panel shows every active load user. Load generator and Limitador token counts agree |
| **M5** | maaspal install, registration, headless runner, `quick` and `standard` suites, overview cross-check | maaspal results appear in the report. The overview shows zero warnings. The sweep is still clean after the runs |
| **M6** | Functional probes for every running workload and enabled dashboard feature (§10.3), startability checks with rotating sample and `--exhaustive` (§10.4), component end-to-end, RBAC, **observability end-to-end** (§10.8), soak, user's-view check, per-object report (§10.5–10.12), `--observability full` | Every running workload probed. Every dashboard panel for an enabled component has data. A known trace ID, log line and synthetic alert are each found. `--exhaustive` passes on `small`. Soak clean after maaspal `standard`. Version-gated skips explained |
| **M6a** | **Upgrade validation** on the script path: baseline saved by `validate`, upgrade detection, upgrade comparison (§10.13), lock files | Install 3.5.0 on a populated `small` or `sno` cluster, approve the upgrade by hand under load, and `validate` passes every blocking check in §10.13. A deliberately reset setting and a deleted object are both caught, and so is a variant whose customisation is removed by hand. Validating mid-upgrade stops with a clear message. Disruption numbers are recorded |
| **M6b** | **Minor upgrade validation, 3.4 → 3.5:** migration fixtures, `upgrade-from-3.4.yaml`, migration status in `validate`, per-model routing in the load generator, MaaS checks at 3.4 | Install 3.4 at `small`, follow the guide's upgrade and migration by hand under load. `validate` reports `migration incomplete` at each stage with the right steps outstanding, then passes every blocking check in §10.13 with maaspal `standard` passing. Each skipped migration step is caught when deliberately left out. Real results replace the guide-derived facts in §5 |
| **M6c** | **UX testing** (§10.14): Playwright journeys for all three users, timing and API capture, report section, baseline comparison | Every listed page reaches usable with the right content on `small`, under load. A deliberately slowed dashboard is flagged, and a page showing the wrong item count fails. Network logs contain no tokens |
| **M7** | GitOps path at parity (root chart, ApplicationSet shards, hooks) and `medium`/`large` scale tuning | UX budgets are set from measured `small`, `medium` and `large` runs and become blocking. Both paths produce the same inventory and the same validation result on `medium`, and after manual z-stream and minor upgrades of a GitOps-installed cluster, §10.13 passes, Argo hasn't reverted or recreated anything and later syncs still succeed |
| **M8** (optional) | **Thin validation UI**: list past runs, compare them, and start a run by creating the same validator Job, behind OpenShift login. Build it only if people without cluster-admin need to start runs (demos, shared QE clusters), or if comparing runs over time becomes a real need | A run started from the UI gives the same results as one from the CLI. Only an authorized group can start a run, and concurrent starts are refused. The UI's service account can only create the validator Job, and the UI doesn't hold the validator's permissions itself |

Each milestone ends with a run on a real cluster. Confirmed facts go into the version profiles, following maaspal's "empirical verification" practice.

---

## 17. Risks and open questions

1. **maaspal on 3.4.x.** The plugin declares `min_version 3.5.0`. 3.4 runs maaspal in advisory mode, with 3.5-only scenarios skipped, and our own checks provide the MaaS baseline. After upgrading to 3.5, maaspal is blocking (§5). *To confirm in M1: whether maaspal installs on 3.4 at all. If it doesn't, it's installed for the first time after the upgrade.*
2. **Headless maaspal.** We depend on the BFF REST shape and `oc exec` access to the pod. Proposal: contribute a supported headless or CI entry point upstream, such as a `maaspal-run` CLI in the BFF image or a token-authenticated route.
3. **Identity provider changes on adopted clusters.** Adding the Keycloak IdP is additive, but some customer-like clusters won't allow IdP changes at all. Fallback: `--idp none`, with ServiceAccount-backed users and impersonation-only validation. MaaS per-user attribution then uses ServiceAccount names.
4. ~~**Password-grant logins.**~~ **Resolved on the 3.5.2 spike:** OpenShift's password challenge works for the OpenID IdP when the client allows direct access grants. 300 users logged in within 22 s (§19). The grant is limited to the one `openshift` client, and generated passwords live only in in-cluster Secrets.
5. **Argo at about 50k objects** (large profile). Controller memory, sharding, and status churn on Notebook and ISVC resources may need resource exclusions or `ignoreDifferences` tuning.
6. **Exact 3.x prerequisites and DSC fields** change between minors. The version profiles must be verified against the docs for each release we support.
7. **Real model.** One small CPU vLLM model makes `request_types` meaningful but costs about 4 vCPU and 8 GiB. It's on by default for `medium` and above.
8. **Single-node clusters** (like the one inspected). Pods-per-node and EBS attachment limits bind long before CPU does. Raising `maxPods` through a `KubeletConfig` reboots the only node. Proposal: never change it automatically; the `sno` profile fits inside the defaults.
9. ~~**Trainer v2 dependency on JobSet.**~~ **Resolved on the spike:** the package is `job-set` (`stable-v1.0`), and it needs a `JobSetOperator/cluster` CR (§8).
10. ~~**Components still to be enabled and checked.**~~ **Resolved on the spike for 3.5.1:** every component reached Ready, and their CRDs and dependencies are recorded in §8. The rule still applies to other versions: a component that can't reach Ready is dropped from that version profile with a recorded reason, never left enabled and broken.
11. **Tech Preview features.** `--feature-level techpreview` enables features that may change between z-streams. The validator records the feature level in the report so results are compared like for like.
12. **Direct OIDC mode** (`--auth-mode direct-oidc`). OpenShift's external OIDC authentication removes the OAuth server, and with it `kubeadmin` and htpasswd. It also changes the tokens RHOAI's dashboard and MaaS's token review receive. RHOAI 3.5 support needs confirming before this is offered as more than experimental.
13. **Metric labels per user.** `authorized_hits` carries a `user` label, which gives one series per user × subscription × model. That's fine at hundreds of users. At `large` (1000 users) it should be checked against Prometheus memory, with tokens-per-user panels limited to top-N.
14. **Load and maaspal interference.** Shared models carry background load. The load generator pauses traffic to the models under test during latency-sensitive maaspal scenarios. Rate-limit scenarios use their own users and keys, so they're unaffected.
15. **Product issues found on the spike that need upstream fixes**, tracked rather than worked around silently:
    - `llmisvc-controller-manager` only checks for the `AuthPolicy` CRD at startup.
    - The generated MonitoringStack can't run on SNO (two Alertmanager replicas with a required anti-affinity).
    - Kuadrant's `istio-pod-monitor` scrapes port 15021.
    - RHOAI, NFD and LWS ServiceMonitors use `bearerTokenFile`.
    - The guide's RHBK 26.4 pin.
    - The guide's `setup-maas.sh --dry-run` still labels `redhat-ai-gateway-infra`.

    Each one gets an issue, and the allowlist entry or workaround links to it.
16. **Where this lives.** A standalone repo, or alongside `rhoai-migrations` (which the minor-upgrade work might favour)? Should the validator image be published to quay under `rh-ai-community-plugins`?
17. **The upgrade workflow is untested.** The design in §5 hasn't been run on a cluster. The main things to confirm in M6a:
    - Whether the older starting versions, such as 3.5.0, are still in the catalog channel. If they've gone, those versions can't be used as a starting point.
    - Which settings an upgrade actually resets.
    - Whether MaaS API keys survive an upgrade. If a release deliberately invalidates them, that goes in `upgrade.expectedChanges` rather than being treated as a pass.
18. **Minor upgrades rest on unverified facts.** §5's migration table comes from the MaaS guide, which focuses on MaaS. Things to settle in M6b:
    - **Other components:** we have no equivalent list for workbenches, pipelines, serving and so on. The official upgrade docs and release notes need checking, and the first real run will show the rest.
    - **Starting version:** the guide's example shows `rhods-operator.3.5.0` replacing `3.4.3`, so earlier 3.4.z may need to reach 3.4.3 first.
    - **Per-user metrics on 3.4:** `MaaSTenantConfig`, which holds `captureUser`, is new in 3.5. How 3.4 attributes usage per user, and whether those metrics line up across the upgrade, is unknown. The same goes for which usage dashboards 3.4 has.
    - **Dependency versions:** the guide suggests pinning RHCL to 1.3.4 because of a rate-limiting bug in 1.4.x, but limits were enforced on our 3.5.1 spike with 1.4.3. The 3.4 profile needs a tested choice.
19. **Known 3.5 issues could block a clean pass.** *3.5.2 spike update: the MCP Lifecycle Operator didn't OOM at 355 projects and about 2,300 Secrets. Wrong-model routing is still untested.* The guide lists the MCP Lifecycle Operator OOM (RHOAIENG-82694) and wrong-model routing with several models on one gateway (RHOAIENG-93709, no workaround listed). Both could also hit a **fresh** 3.5 install at our scale, which §8 and §10 assume stays clean. A real failure stays a failure, so `medium` and `large` may not be able to pass until these are fixed. The first scale run in M7 should measure this, and each z-stream's `knownIssues` should record the outcome.
20. **Who keeps z-streams verified, and how many minors we support.** Without an owner and a source of clusters, most z-streams will stay `unverified`. Proposal: the latest two minors, with a full run for each new z-stream. *Owner and cluster source are still to be decided.*
21. **A slow dashboard may be a real product finding.** If a page misses its budget at `medium` or `large`, the cause may be in the product and not fixable here. It stays visible, gets an issue with the API call evidence, and goes in `knownIssues`. It isn't removed by loosening the budget without a recorded reason. UX journeys also depend on dashboard pages and selectors that change between releases, so each new version may need its page definitions updated.
22. **Raised controller limits versus upgrade testing.** At `medium` scale, nine RHOAI controllers and Kuadrant need more memory than their defaults (§4). Raising them on RHOAI-owned Deployments requires `opendatahub.io/managed=false`, and the MaaS guide says to remove that annotation before an upgrade, which brings back the limits that crash. *Decision needed:* either upgrade tests run with the annotations removed and accept, or record, the resulting restarts as findings, or the raised limits are re-applied immediately after the upgrade. Long term, this needs a supported way to set controller resources, which is an RFE.
23. **Product issues found on the 3.5.2 spike** (§19). Each needs an issue, and a link from the workaround:
    - Admin Deployments page: about 10,000 per-namespace API calls at 355 projects, then `ChunkLoadError`. The cost scales with projects, not models.
    - Observe dashboard: all Perses queries failed at 196 projects. Seen once.
    - Trusted CA bundle `subPath` race (TrustyAI, Feast).
    - Feast ClusterRoleBinding named from the FeatureStore name only.
    - Module status not re-checked after recovery (OGX, aigateway, Spark).
    - Notebook stop annotation stripped at create.
    - OGXServer's `distribution.name` path fails with HTTP 401.
    - Controller default memory limits too low at scale.
    - The guide's Keycloak database isn't persistent, its realm has no standard scopes, and its `mcp-weather` sample never turns Ready.
    - Three RHOAI ServiceMonitors (`controller-manager`, `odh-model-controller`, `mcp-lifecycle-operator`) are rejected by user-workload monitoring for using a bearer token file, so their metrics are lost. RHOAI's own Prometheus fails to scrape itself (x509). The validator's alert check must list these as known until fixed, not hide them.
    - maaspal: `gateway_overhead` sends before its model's limits are ready, and `keys_share_user_budget` overshoots the budget before enforcement.
24. **Version-named LLMInferenceService presets.** RHOAI 3.5.2 ships its LLMInferenceServiceConfigs as `v3-5-2-kserve-config-…`, and each LLMInferenceService records the preset names it resolved. Unknown until the first z-stream upgrade test: whether existing services move to the new presets (rolling every model's pods, which would show up as disruption), whether the old presets are deleted, and whether a service that names one in `baseRefs` breaks. The variants in §6 make each case visible. *To confirm in M6a.*
25. **Variants that can't be healthy on CPU.** Some variants may not reach Ready without GPUs or real models: P/D disaggregation and scheduler configs with the simulator, and GCS fault tolerance without Redis. Each is verified in M3; any that can't be made healthy is gated off in the profile with the reason, rather than created broken.
26. **MCP Gateway is preview-only.** On 3.5.2 the `mcp-gateway` operator (v0.7.1) is only on a `preview` channel, and its APIs are `v1alpha1`. Installing it adds a dependency that may change or break between releases, and an upgrade failure there may be expected rather than a product bug. *Proposal:* install it by default, mark its results with their support level in the report (like Tech Preview features, item 11), and pin its version per version profile.
27. **EBS volume attachments limit running workloads.** AWS allows about 26 EBS volumes per worker here, and only running pods with PVCs use them. The full `medium` population is estimated at about 55 of 78 on three workers (§15), and the scheduler can strand pods when one node fills (one worker is already at 19). Raising running workbench counts, or switching notebooks to `--pvc-mode=eager` with more running, needs more workers, not bigger ones.
28. **Playground objects are inferred, not observed.** The playground kind, name and settings ConfigMaps came from strings in the gen-ai BFF binary (§4 `population.playground`). If the dashboard creates more than that (a Secret, a vector store database, RoleBindings), generated playgrounds won't match real ones. *To confirm in M3* by creating one through the dashboard and diffing the project.

---

## 18. Spike log: live 3.5.1 cluster (2026-11-02)

**Cluster:** a throwaway SNO, `g6.12xlarge` with 4 × L4, OCP 4.20.0, with RHOAI 3.5.1 already installed (pinned, with 3.5.2 pending). It was provisioned by RHDP through Argo CD. Everything was done in adopt mode. The spike manifests and scripts are in the session scratchpad: operator Subscriptions, `kc_seed.py`, MaaS tier objects, and `loadgen.py`.

### What was done, in order

1. **Operators.** Installed RHCL, Kueue, JobSet, Custom Metrics Autoscaler, COO, OpenTelemetry, Tempo and RHBK, using the channels and namespaces in §4.
2. **Components.** Enabled every DSC component (§8). Everything reached Ready once `JobSetOperator/cluster` was created.
3. **MaaS.** Ran `rhoai-maas-guide/scripts/setup-maas.sh --from-phase 2 --model auto --with-observability`. Its MaaS verification reported **ALL CHECKS PASSED**: Gateway, Postgres, maas-api, API keys, inference, 401 enforcement and rate limiting.
4. **Observability.** Added `alerting: {}` to the DSCI, which turned every Monitoring service condition True.
5. **Keycloak.** Ran the guide's `09-external-oidc/setup-keycloak.sh`, with RHBK on 26.6. Its `test-external-oidc.sh` reported **ALL CHECKS PASSED**: a Keycloak-only user logged in, minted a MaaS key, resolved to the right subscription by group, and inferred.
6. **Tiers.** Seeded Keycloak with `maas-free`, `maas-standard` and `maas-premium` groups and 10 users, and created matching tier subscriptions and auth policies on both models.
7. **Load.** Ran 12 minutes of per-user load (`loadgen.py`), with every request made by a Keycloak user using their own API key.

### Problems hit, and how the plan changed

| # | Symptom | Cause | Plan change |
|---|---|---|---|
| 1 | RHCL Subscription stuck waiting for approval | `openshift-operators` holds Manual Subscriptions, so OLM made RHCL's plan Manual too, **and bundled a Service Mesh 3.1.0 → 3.5.0 upgrade into it** | §5: the approver reports bundled CSVs; `--approve-bundled-upgrades` |
| 2 | `TrainerReady=False: JobSetOperator CR with name 'cluster' not found` | JobSet needs its operator CR, not just the Subscription | §4 and §8: `job-set` package plus `JobSetOperator/cluster` |
| 3 | `ModelsAsAServiceReady=False: gateway … maas-default-gateway not found` | MaaS needs an admin-created Gateway | §7: the guide's Gateway and Kuadrant order |
| 4 | Kuadrant `MissingDependency` | Kuadrant CR created before the GatewayClass provisioned Istio | §4 ordering |
| 5 | LLMISVC `GatewayPreconditionNotMet: AuthPolicy CRD is not available` while RHCL was installed | `llmisvc-controller-manager` only checks for the CRD at startup (started at 19:13; CRD created at 20:45) | §7 item 4, §10.2 diagnosis, §17 item 15 |
| 6 | Two OperatorGroups in one namespace | My spike used different OperatorGroup names from the guide's | §5: reuse the existing OperatorGroup |
| 7 | RHBK install failed: "removes version v2beta1 … stored version" | Guide pins `stable-v26.4`, but 26.6 CRDs were already on the cluster | §6: one RHBK channel cluster-wide |
| 8 | Alertmanager pod Pending forever | Generated MonitoringStack runs 2 replicas with a required hostname anti-affinity; impossible on SNO | §9: patch to 1 replica on `sno` |
| 9 | Per-user token panels empty; `authorized_hits_total{user=""}` | `MaaSTenantConfig.spec.telemetry.metrics.captureUser` defaults to off | §7 item 7: `captureUser` and `captureGroup` on |
| 10 | Five warning alerts firing | Four product issues plus the cluster-default `AlertmanagerReceiversNotConfigured` | §4 `alertAllowlist` with reasons, §17 item 15 |
| 12 | Power user never rate-limited despite ~2,450 tokens/min on a 2,000/min tier | Limits apply per user per model, and the user's traffic was split across two models | §9: pin power users to one model. Re-run: 4 × 429, all `expected`, and `limited_calls_total{user="power-free1",subscription="tier-free"}=4` |
| 11 | DSC OutOfSync in an Argo Application with `selfHeal: true` | RHDP manages RHOAI through GitOps. The revert was only held off by the stalled pinned Subscription | §5: detect Argo ownership; `--take-over-gitops` |

### Load results

- **12-minute run:** 10 Keycloak users (3 free, 3 standard, 3 premium and 1 power user) sent **2,465 requests and about 186k tokens, with 0 errors**. Request rates followed the tiers (free about 95 requests, standard about 220, premium about 370).
- **Per-user attribution:** once `captureUser` was on, `authorized_hits_total` carried the Keycloak username, the tier subscription and the groups (`system:authenticated,maas-<tier>`) for every user, so the usage dashboards' tokens-per-user panels have data.
- **Accuracy:** the raw Limitador counter delta for a user matched the load generator's token count exactly (4,615 against 4,615).

**Two suspected maaspal incompatibilities were checked and ruled out:**

- 3.5.1 serves `externalmodels`/`externalproviders` in `inference.opendatahub.io`, which is what maaspal reads.
- The cluster Thanos has `authorized_hits` and `authorized_calls` without `_total`, which is what maaspal queries.

### Not yet exercised on the spike

- The population at scale (§6)
- The OpenShift OAuth OpenID IdP and warm-login (path 2 in §6)
- The maaspal install and its scenario runs
- The full validator
- The GitOps path
- Z-stream overrides, lock files and upgrades. The spike cluster had the 3.5.2 plan pending, which suggests a 3.5.1 → 3.5.2 path exists, but it was never approved

---

## 19. Spike log: fresh 3.5.2 install at scale (2026-11-05 to 2026-11-09)

**Clusters:** two RHDP clusters on OCP 4.22.18 on AWS, with no GPUs. Each started with 3 schedulable control-plane nodes (`m6a.4xlarge`) and 2 workers (`m5a.8xlarge`), and nothing in `us-east-2c`. RHOAI 3.5.2 was installed fresh, with `stable-3.5` and Manual approval. The first cluster was torn down mid-test, and the second was rebuilt with every fix applied up front, using `spike/rebuild.sh`. Full detail and evidence are in `spike/FINDINGS.md`. The scripts are in `spike/`.

### What was done

1. **Install.** Dependency operators, then RHOAI pinned to 3.5.2, the guide's MaaS and observability phases, the remaining DSC components, and Keycloak with 300 users through the OpenShift IdP.
2. **Smoke set.** One of each workload type, each checked with a real request or job: workbench, ISVC, pipeline run, model registry, TrainJob, Ray, Spark, OGX chat, Feast, EvalHub and MCP.
3. **Population.** The generator's `medium` profile: 355 dashboard projects, 350 workbenches (15 running), 9 InferenceServices plus the MaaS simulator, 6 DSPAs, Kueue batch namespaces, and Feast, TrustyAI, MCP and Spark.
4. **Dashboard timing.** Playwright, as an admin who sees every project, a team lead and a regular user, at 2, 77, 196 and 357 projects.
5. **Rebuild.** On the second cluster, everything was redone with the fixes in place, followed by a controlled model-count experiment and a full sweep.

### Problems hit, and how the plan changed

| # | Symptom | Cause | Plan change |
|---|---|---|---|
| 1 | About 15 controllers restarting together. API lease updates up to 15.5 s. etcd commit p99 up to 3,000 ms on one control-plane node | Workloads and image pulls on schedulable control-plane nodes, sharing a disk with etcd. With the topology fixed first, a full 2,134-object apply peaked at 46 ms with no restarts | §4 preflight topology, §15 |
| 2 | Kuadrant, dashboard, Feast, batch-gateway, MaaS, KubeRay and KServe-module controllers crash-looping or OOMKilled while the DSC said Ready | Default memory limits too low at about 355 projects | §4 `controllerResources`, §10.0, §17 item 22 |
| 3 | All three workers at 0 GB free, 69 evictions | 100 GB root disks. 350 Notebooks started at once (row 5), pulling multi-GB images, including the 11.7 GB CUDA PyTorch image on a cluster with no GPUs | §4 preflight disk and `workbenchImages`, §6 prepull and staggered apply |
| 4 | Keycloak realm and users gone after a cluster restart, while status stayed green | The guide's Keycloak Postgres has no volume | §6 Keycloak on a PVC, proved by a restart |
| 5 | Stopped workbenches running | The stop annotation is stripped at create, and during early reconciles | §6 create, then stop |
| 6 | Kueue managing pipelines, Feast and serving pods, and suspending Spark | The namespace label plus a LocalQueue named `default` | §6 batch namespaces |
| 7 | "Suspended" RayClusters running | Kueue admits them and clears `suspend` | §6 a `Hold` queue (verified: 6 stayed suspended) |
| 8 | TrustyAI pods stuck in `CreateContainerError` for 86 minutes | Trusted CA bundle `subPath` mounted 4 s before the network operator added the key | §6 wait for the bundle, §10.2 diagnosis |
| 9 | Feature stores flipping between Ready and Failed | One ClusterRoleBinding per FeatureStore *name*, shared across namespaces | §6 unique names |
| 10 | `DSC Ready=False` on healthy components for 10–40 minutes | Module status isn't re-checked after recovery | §10.0 force a re-check before failing |
| 11 | RHBK upgraded mid-test, restarting both Keycloaks | `Automatic` Subscriptions | §4 Manual from the start |
| 12 | Users named by UUID, so RoleBindings granted nothing | The guide's realm has no standard OIDC scopes | §6 mappers before first login |
| 13 | LWS CRD missing | Needs `LeaderWorkerSetOperator/cluster` | §4, §8 |
| 14 | Spark, MCP and OGX failing on defaults | Restricted SCC, a legacy-SSE sample, and HTTP 401 reading image labels | §6 product constraints |
| 15 | maaspal `load_test`: 55.7% errors (HTTP 500) | Authorino's default auth timeout. The guide's Issue 7 still applies on 3.5.2. With `AUTH_SERVICE_TIMEOUT=2s` it passed: 0% errors, p99 1.4 s | §4 set it on the `rhcl-operator` Subscription at install |
| 16 | Per-user token counts off by −2.9% to +8.4% | The measurement, not MaaS: live counters and a load generator restart. Between two quiet points, all 62 users matched exactly | §10.8 compare raw counters between paused points |
| 17 | maaspal `keys_share_user_budget` and `gateway_overhead` failing every run | Over-budget tokens pass before enforcement catches up; `gateway_overhead` sends before its new model's limits are ready (MaaS correctly returns 403) | §10.7 known failures, raised with maaspal |

### Dashboard results

- **Admin Deployments page fails at 355 projects:** about 10,000 per-namespace API calls, then `ChunkLoadError`. With projects fixed at 355, changing from 10 to 152 to 10 models moved the call count by about 8%, within run-to-run spread, so **project count drives it, not models**. Leads and regular users load it in 1.2–1.6 s.
- **Admin page times grow with projects:** Projects took 0.97 s at 2 projects and 5.5 s at 357. Observe failed all its queries in one test at 196 projects.
- **Timings need a settled cluster.** Observe measured 24.7 s while workbenches were starting and 2.1 s once settled. **A fast error screen must count as a failure**: the first harness missed one, and caught it only from a screenshot.

### Verified working on 3.5.2

- **End-to-end tests:** MaaS verification 15/15, and Keycloak OIDC 6/6.
- **Logins:** 300 scripted logins through the OpenShift IdP.
- **Real requests and jobs succeeded:** workbench, ISVC, start-and-stop of both, pipeline run, model registry, TrainJob, Ray, Spark, OGX chat, Feast and EvalHub.
- **Population:** after a cluster restart, every component recovered except Keycloak (row 4). On the rebuilt cluster, all 2,134 objects in the expected inventory were present.
- **MaaS tiers and per-user load:** 3 tiers over 4 models. 62 users each logged in to Keycloak and sent from their own API key. Every key resolved to the user's tier, only the power users were rate-limited, and Limitador's per-user tokens and 429s matched the load generator exactly.
- **maaspal 1.0.0:** 13 of 15 scenarios passed headlessly through the BFF (rows 15 and 17 cover the rest).

### Not yet exercised on 3.5.2

- MaaS usage dashboards (Grafana/Perses) with the per-user load
- `LMEvalJob`, guardrails, `LLMBatchGateway` instances and `RayJob`
- Gen AI playgrounds, the MCP Gateway operator, and hand-written Kuadrant policies
- GPU workloads
- The validator itself; the spike used one-off scripts
- Upgrades, and the GitOps path
