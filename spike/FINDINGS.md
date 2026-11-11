# RHOAI 3.5.2 at scale: what we've learned so far

Interim findings from installing RHOAI 3.5.2 on a real cluster and growing it to about 360 projects.
Status as of 2026-11-06 21:05 UTC. Testing is still in progress.

## Summary

1. **RHOAI 3.5.2 installs and works on a fresh cluster.** Every component reached Ready, and the core workloads passed real functional checks before the full population went on.
2. **The first thing to break was the control plane, not the UI.** Workloads on schedulable control-plane nodes shared a disk with etcd. During bulk changes, one etcd member stalled, API writes slowed to as much as 15 s, and about 15 unrelated controllers restarted together.
3. **Several controllers' default memory limits are too low at this size.** Nine controllers were over or within a few percent of their limits, and some crash-looped while the DSC reported Ready.
4. **For an admin, one page fails outright at 357 projects.** The Deployments page made 10,744 API calls in 154 s, then ended on "An error occurred". A regular user with 1 project gets the same page in about 1 s.
5. **Status conditions can't be trusted alone, in either direction.** A wiped Keycloak realm showed green, and healthy components showed as not Ready for 10 minutes or more.
6. **The Deployments page cost is driven by project count, not model count.** On a rebuilt cluster with projects fixed at 355, the admin's page crashed with 10, 152 and then 10 models again. Going from 10 to 152 models changed the call count by less than run-to-run variation.

## Test environment

| | |
|---|---|
| Platform | OCP 4.22.18 on AWS, no GPUs |
| Nodes at start | 3 schedulable control-plane (`m6a.4xlarge`), 2 workers (`m5a.8xlarge`) |
| Nodes now | 3 unschedulable control-plane, 3 workers (one added in `us-east-2c`) |
| RHOAI | `rhods-operator.3.5.2`, `stable-3.5`, Manual approval |
| Population | 357 dashboard projects, 300 users, 352 workbenches (16 running) |
| Models | 152 during baseline A, now 10 (9 InferenceServices, 1 LLMInferenceService) |

## What broke at scale

### Control plane stalled by shared disk

**Evidence level: strong, not fully proven.**

Etcd and container images share one disk on these nodes (`/dev/nvme0n1p4`). 93 non-system pods ran on control-plane nodes, and `us-east-2c` had no worker at all, so pods with volumes there could only run on a control-plane node.

| Measure | During bulk applies | After moving workloads off |
|---|---|---|
| etcd commit p99 on `10.0.58.127` | up to 2,997 ms | 7 ms |
| etcd WAL fsync p99 on `10.0.58.127` | up to 426 ms | 4 ms |
| API lease update p99, worst API server | up to 15.5 s | 0.6 s or less |
| Controller restarts | about 29 in 2 minutes at the peak | 0 in 15 minutes |

- **What it looked like:** controllers logged `leader election lost ... context deadline exceeded` and restarted together, with no etcd leader changes and no flow-control rejections.
- **Why it's not fully proven:** the "after" numbers were taken on a quieter cluster. Deleting 143 models caused no spike, but those were mostly stopped. We haven't repeated a bulk apply that starts many pods and pulls images.
- **Fix used:** added a `us-east-2c` worker, set `mastersSchedulable: false`, and moved 95 pods.

### Controller memory limits

Usage on about 360 projects, mostly measured after raising the limits (the last two rows and `kserve-module-controller-manager` were measured at their default limits):

| Controller | Used | Default limit | Symptom |
|---|---|---|---|
| `kuadrant-operator` | 441 Mi, then OOMKilled at a raised 1 Gi | 300 Mi | 51 restarts, killed by its liveness probe |
| `kserve-module-controller-manager` | 1,013 Mi | 1 Gi | 10 restarts |
| `opendatahub-feast-operator` | 782 Mi | 512 Mi | OOMKilled, CrashLoopBackOff |
| `maas-controller` | 626 Mi | 512 Mi | Restarting |
| `kuberay-operator` | 549 Mi | 512 Mi | Deployment unavailable |
| `llm-d-batch-gateway-operator` | 490 Mi | 256 Mi | CrashLoopBackOff |
| `dashboard-operator` | 458 Mi | 256 Mi | 25 restarts |
| `spark-operator-controller` | 496 Mi | 512 Mi | At 97%, raised before it failed |
| `ai-gateway-operator` | 493 Mi | 512 Mi | At 96%, raised before it failed |

- `kuadrant-operator` started crash-looping the minute namespaces went from 99 to 174, and MaaS kept serving throughout. With that controller down, new auth and rate-limit policies wouldn't reconcile.
- Some restarts in this period came from the control-plane stalls, so the restart counts overstate the memory problem. The used-versus-limit figures are the better evidence.

### Dashboard: admin Deployments page fails

**Evidence level: confirmed, measured once with no time limit and once in the timing run.**

`/ai-hub/models/deployments`, as an admin who can see all 357 projects, with 152 models:

- 10,744 API calls, of which 10,698 were per-namespace.
- About 1,200 requests in flight, with a median of about 19 s per call. Most of that is probably queuing in the browser.
- The page ended on "An error occurred. This is likely the result of a recent update."

| Requests | Count |
|---|---|
| `namespaces/*/pods` | 3,560 |
| `namespaces/*/llminferenceservices` | 1,969 |
| `namespaces/*/llminferenceserviceconfigs` | 1,967 |
| `namespaces/*/inferenceservices` | 1,594 |
| `namespaces/*/servingruntimes` | 1,590 |

That's several requests per project for each type. `/api/builds` and `/api/config` were called 6 times each, which suggests the app restarted itself during the load.

Users with few projects aren't affected: this page took 1.0–1.5 s for a lead with 2 projects and a regular user with 1.

**Model count test (rebuilt cluster, 2026-11-09).** Projects were fixed at 355. Only the models changed, and each step was measured twice as an admin:

| Models | Admin calls | Admin result | Lead (2 projects) | Regular (1 project) |
|---|---|---|---|---|
| 10 | 10,879 and 9,814 | Error screen at 192–199 s | 35 calls, 1.4 s | 31 calls, 1.2 s |
| 152 | 11,520 and 11,050 | Error screen at 173–175 s | 35 calls, 1.6 s | 32 calls, 1.2 s |
| 10 again | 10,429 and 11,786 | Error screen at 172–175 s | 35 calls, 1.4 s | 31 calls, 1.4 s |

- **Models make little difference.** Adding 142 models raised the admin's calls by about 8%, which is within the run-to-run spread at a fixed size. The page fails at both sizes.
- **Projects drive the cost.** The page lists 5 types once per project, so 355 projects means at least 1,775 requests. The admin made about 30 per project, while the lead made exactly 1 per type per project. The extra calls are probably retries and refreshes caused by the backlog, which held at over 1,000 requests in flight. That's a guess, not something measured.
- **What fails first is the page's own JavaScript.** The error is `ChunkLoadError: Loading chunk ... failed (timeout)`, presumably because the API calls hold every browser connection.
- **The `inferenceservices` list alone ran 1,444–1,720 times per load.**

### Dashboard: admin Observe page

**Evidence level: one test at 196 projects, not yet repeated at 357 or since the control-plane fix.**

At 196 projects, the page's 10 Perses queries all failed: 6 returned 504 at about 30 s, 1 returned 400, and 3 failed outright. The last finished at 63.6 s. Requests were up to 6 KB, because the namespace regex lists every project.

### Dashboard: unexplained 30 s stalls

**Evidence level: seen repeatedly, cause unknown.**

As admin, one of two visits to Observe or Workload metrics often takes about 30.7 s, while the other takes 1–3 s. In one trace, the page's HTML document itself took 29.47 s. Workload metrics follows Observe in the test order, so unfinished Observe queries are the leading theory, but my direct test was inconclusive. Regular users don't see it.

## Dashboard timings

Median seconds to usable, admin who sees all projects:

| Page | 2 projects, 2 models | 196 projects, 99 models | 357 projects, 152 models |
|---|---|---|---|
| Login | 2.39 | 4.90 | 5.90 |
| Home | 0.71 | 1.11 | 1.34 |
| Projects | 0.97 | 1.99 | **5.50** |
| Models (catalog) | 2.60 | 3.31 | 4.97 |
| Deployments | not measured | not measured | **fails** |
| Playground | 3.66 | 4.12 | 7.07 |
| AI asset endpoints | 1.96 | 2.34 | 2.79 |
| MaaS API keys | 1.41 | 1.78 | 2.04 |
| Pipeline runs | 0.80 | 1.13 | 1.58 |
| MLflow | 1.00 | 2.10 | 2.19 |
| Observe | 4.16 | **16.98** | **17.92** |
| Workload metrics | 0.79 | **15.92** | **16.02** |
| Hardware profiles | 0.52 | 0.59 | 0.53 |

**How to read these:**

- **Projects and models grew together here,** so this table can't separate their effects.
- **Each is a median of only 2 runs.** The 16–18 s medians are an average of a fast run and a run of about 30 s.
- **The 196-project column predates the control-plane fix,** so it isn't strictly comparable.
- **The 357-project column used a harness that could count an error screen as usable,** which has since been fixed. The Deployments result was caught from a screenshot.
- **Timings ran from a laptop,** so compare them with each other, not as absolute numbers. Pages also call `console.redhat.com` from the browser.
- **Row counts:** the Projects page showed the correct total at every stage (77, 196 and 357 for the admin; 2 and 1 for the others).

Timings taken while the cluster was still settling were badly wrong: Observe read 24.7 s during churn and 2.1 s settled. All numbers above are from settled runs.

## Product and guide issues to raise

| Issue | Impact | Workaround | Evidence |
|---|---|---|---|
| Guide's Keycloak Postgres has no volume | A restart wiped the realm and all users, while `Keycloak Ready=True` and `RealmImport Done=True`. MaaS OIDC login broke | PVC and `Recreate` strategy. Survived a pod-restart test | Reproduced |
| Module status doesn't re-check after recovery | `DSC Ready=False` on healthy components: OGX for 20+ minutes, `aigateway` for 40, Spark for 10 | Restart the module operator, or for `sparkoperator` annotate its CR | Seen 3 times |
| Notebook created as stopped loses the annotation and starts | Stopped workbenches briefly run. Later annotations were also stripped while it reconciled, taking up to 5 passes | Create, then annotate and retry until it holds | Reproduced. Cause is a guess |
| OGXServer fails with `distribution.name` | The operator gets HTTP 401 reading image labels from `registry.redhat.io` | `spec.baseConfig` from the image's config, plus Postgres through `overrides.env` | Reproduced |
| Guide's `mcp-weather` sample never turns Ready | Serves legacy SSE, which the readiness check doesn't accept | Catalog's `openshift-mcp-server-rhel9:0.4` | Reproduced |
| Guide's realm has no standard OIDC scopes | OpenShift names users by UUID, so RoleBindings by username silently grant nothing | Add protocol mappers before first login | Reproduced |
| Upstream `spark:4.0.1` fails under restricted SCC | `work-dir` isn't writable. `spec.driver.volumeMounts` wasn't applied | Spark's own `spark.kubernetes.*.volumes.emptyDir` config | Reproduced |
| `stable-3.x` appears to stop at 3.4.3 while `stable-3.4` reaches 3.4.6 | 3.4.4–3.4.6 may have no path to 3.5 | Check before choosing a 3.4 starting version | From catalog listing only |
| Guide's Issue 7 (Authorino auth timeout) still applies on 3.5.2 | maaspal `load_test`: 55.7% HTTP 500s under load | `AUTH_SERVICE_TIMEOUT=2s` on the `rhcl-operator` Subscription: 0% errors | Before and after, same scenario |
| Three RHOAI ServiceMonitors rejected by user-workload monitoring | `controller-manager`, `odh-model-controller` and `mcp-lifecycle-operator` metrics in `redhat-ods-applications` aren't collected; `PrometheusOperatorRejectedResources` fires. They read a bearer token from a file, which that Prometheus forbids | None yet | Operator log: "accesses file system via bearer token file" |
| RHOAI's own Prometheus can't scrape itself | `prometheus-self` target down with an x509 error in `redhat-ods-monitoring` | None yet | Target list |
| maaspal `gateway_overhead` sends before limits are ready | Scenario always fails: every request through MaaS gets 403 | None; MaaS is right to refuse | 2 runs |
| maaspal `keys_share_user_budget` overshoots | 1,227–4,206 tokens pass a 100-token budget before the first 429 | None | 3 runs, cause unconfirmed |

## Trusted CA bundle race: pods stuck in CreateContainerError

**Evidence level: confirmed, with a control.**

On the rebuilt cluster, both `TrustyAIService` pods (in `lr-team-09` and `lr-team-10`) were stuck for 86 minutes, with `kube-rbac-proxy` failing on: `mount .../volume-subpaths/odh-trusted-ca-bundle/kube-rbac-proxy/2 to etc/ssl/certs/ca-bundle.crt: Not a directory`.

Timeline in `lr-team-09`, from the ConfigMap's field owners and the pod's own timestamps:

| Time (UTC) | Event |
|---|---|
| 16:47:02 | RHOAI (`platform.opendatahub.io/trustedcabundle`) creates `odh-trusted-ca-bundle` with only `odh-ca-bundle.crt` |
| 16:47:05 | TrustyAI pod created |
| 16:47:08 | Pod scheduled. Kubelet mounts `subPath: ca-bundle.crt`, a key that doesn't exist yet |
| 16:47:12 | `cluster-network-operator` injects `ca-bundle.crt`, 4 s too late |

**How it fails:**

- **The pod never recovers by itself.** Kubelet reuses the bad subPath on every retry, so the pod would have stayed stuck indefinitely.
- **Deleting the pod fixes it.** The replacement ran 2/2, TrustyAI reported `Available`, and its readiness endpoint returned 200. The untouched pod in `lr-team-10` stayed broken until it was deleted too.

**When it happens:** anything that mounts `odh-trusted-ca-bundle` with a `subPath`, and is created within about 10 s of its namespace. It's latent anywhere namespaces and workloads are created together, as in GitOps or project templates.

**Who's at risk:**

| Workload | How it mounts the bundle | Status here |
|---|---|---|
| TrustyAI `kube-rbac-proxy` | `subPath` | Hit by the race |
| Feast `online`, `feast-init`, `feast-apply` | `subPath` | Same risk, won the race on all 3 feature stores |
| Dashboard and UI modules | `subPath` | Not exposed, because `redhat-ods-applications` exists long before they start |

`subPath` mounts also never pick up later changes to the bundle, such as CA rotation.

**Suggested product fixes:**

- Mount the ConfigMap without `subPath`, as one RHOAI controller already does.
- Or have operators wait until `ca-bundle.crt` exists before creating the workload.

**Workaround in population:** don't create a workload that mounts the bundle until the namespace's `odh-trusted-ca-bundle` has `ca-bundle.crt`. The validator should report `CreateContainerError` with this signature and name the cause.

## Feast: same-named FeatureStores in different projects fight over one ClusterRoleBinding

**Evidence level: collision and flapping confirmed. Effect on permissions not established.**

Three FeatureStores named `features`, in `lr-team-07`, `lr-team-08` and `lr-team-09`. Each runs, serves `/health` and registered its features, yet their status keeps flipping between Ready and Failed.

**What's confirmed:**

- **One cluster-scoped binding for all of them.** The operator creates `ClusterRoleBinding/feast-<name>-cluster-binding`, here `feast-features-cluster-binding`, named from the FeatureStore's name alone. It binds `ClusterRole/feast-token-review-cluster-role` (create `tokenreviews`, read namespaces, and list RoleBindings, ClusterRoles and ClusterRoleBindings) to the store's service account. Every store's service account is `feast-features` in its own namespace.
- **The binding holds one subject, and it keeps changing.** Over about one minute, its single subject went `lr-team-08` → `lr-team-07` → `lr-team-09`, with the resourceVersion changing each time. It has no owner reference, so deleting a FeatureStore can't clean it up either.
- **Status follows whoever wrote last.** The losers report `Authorization=False` / `FeatureStoreFailed`: "Operation cannot be fulfilled on clusterrolebindings ... feast-features-cluster-binding: the object has been modified". Earlier `lr-team-07` was Failed. A minute later `lr-team-07` was Ready, and the other two were Failed.
- **The operator never stops trying.** It logged about 4,000 reconcile lines in 30 minutes.

**What isn't established:** whether a store's service account actually lacks these permissions while it's not the subject. `oc auth can-i --as` and a SubjectAccessReview both returned "not allowed" even for the currently bound service account, and for `prometheus-k8s` listing namespaces, so my check isn't reliable. Feast's Kubernetes authorization needs this role, so this is worth testing properly.

**Suggested product fix:** name the binding after namespace and name (or the UID), or give it one subject per store.

**Workaround in population:** give every FeatureStore a cluster-unique name, such as `features-<namespace>`.

**Applied and verified (2026-11-09 19:10 UTC):**

- **The generator now uses `features-<namespace>`.** The three stores were recreated under those names, and the orphaned `feast-features-cluster-binding` was deleted by hand, because it survived deleting all three stores.
- **Each store has its own binding.** All three were Ready within 50 s and stayed Ready for over 2 minutes. Each has its own `feast-features-<namespace>-cluster-binding` with exactly one matching subject, and none of the bindings changed in a 30 s check.
- **The operator calmed down.** It dropped from about 130 reconciles a minute to 36.
- **All three feature servers work.** Each answers `/health` with 200 on port 6567.

## Behaviour to design around

- **Automatic Subscriptions change versions mid-test.** A catalog update moved RHBK from 26.4.16 to 26.4.17 during a timing run, restarting both Keycloaks, including the cluster's own login. One login failed as a result. This matters for upgrade testing.
- **The Kueue label captures a whole namespace.** `kueue.openshift.io/managed=true` with a LocalQueue named `default` put every pod under Kueue and suspended Spark. Removing the label doesn't fully undo it, because Workloads hold finalizers and Deployment templates keep the labels.
- **Operand CRs are required.** `leader-worker-set` needs `LeaderWorkerSetOperator/cluster`, like JobSet. Without it, the CRD never appears.
- **Dashboard admin isn't cluster-wide read.** A dashboard admin saw 0 projects until given `cluster-reader`.
- **Scripted logins work.** Password login through the OpenID IdP works when the client allows direct access grants. All 300 users logged in within 22 s, creating real Users, Identities and synced Groups.
- **`NotApplicable` isn't a failure.** A healthy DSPA reports `WebhookReady=False` with that reason.
- **Making the control plane unschedulable leaves DaemonSet pods behind.** `ingress-canary` and `insights-runtime-extractor` kept their 3 pods on control-plane nodes, so each ran 6 against 3 desired, and `KubeDaemonSetMisScheduled` and `KubeDaemonSetRolloutStuck` fired for hours. Delete those pods after the topology change.
- **LLMInferenceService presets are named by release.** The 19 shipped `LLMInferenceServiceConfig`s are `v3-5-2-kserve-config-…`, and each service records the ones it resolved in `status.annotations` and `status.appliedConfigs` (`source: Preset`). What an upgrade does to existing services is unknown; see PLAN.md §6 "Customised variants" and §17 item 24.
- **MaaS usage lives in two stores.** The cluster Thanos has `authorized_hits`; RHOAI's Prometheus in `redhat-ods-monitoring`, which the MaaS dashboards read, has `authorized_hits_total`. Both showed all 62 load users with correct tiers. RHOAI's Prometheus is only reachable by port-forward over HTTPS with a bearer token, because a NetworkPolicy blocks the API server proxy.

## What's verified working

These sent a real request or ran real work on 3.5.2, on the small smoke set before the full population:

| Workload | Check | Result |
|---|---|---|
| MaaS | Guide's verification, including keys, inference, 401s and rate limiting | 15/15 |
| Keycloak OIDC | Guide's test | 6/6, also after restoring the realm |
| Workbench | API call. A stopped one started, answered and re-stopped | Pass |
| InferenceService | API call. A stopped one started, answered and re-stopped | Pass |
| Pipelines | Sample pipeline run through the API | Succeeded |
| Model registry | Write and read through REST. Data survived a restart | Pass |
| TrainJob and RayCluster | Ran under Kueue | Complete; 2 healthy Ray nodes |
| Spark | SparkPi | Completed |
| OGX | Chat completion through to a served model | 200 |
| Feast, EvalHub | Health endpoints | 200 |

**Status only, no functional check yet:** MLflow, MCP (its own protocol check passes), InferenceGraph. **TrustyAI:** my probe timed out, so it's unverified.

**Cluster restart:** nodes, operators and most workloads recovered on their own. The exceptions were the Keycloak data loss and the stale OGX status above.

## Current cluster state

Healthy as of this write-up: DSC Ready, no controller restarts in the last 15 minutes, etcd commit p99 about 7 ms.

**It depends on these non-default changes:**

| Change | Note |
|---|---|
| `opendatahub.io/managed=false` on 9 RHOAI controllers, with raised limits | `ai-gateway-operator`, `dashboard-operator`, `kserve-module-controller-manager`, `kuberay-operator`, `llm-d-batch-gateway-operator`, `maas-controller`, `opendatahub-feast-operator`, `spark-operator-controller`, `trustyai-service-operator-controller-manager`. **The guide says to remove this annotation before an upgrade.** That would restore the low limits, so upgrade testing needs a plan for it |
| `rhcl-operator` Subscription override | 3 Gi for all of its operator pods |
| Control plane unschedulable, plus one worker | Topology change |
| Keycloak and OGX Postgres on PVCs | |
| OAuth IdP `keycloak` added, `rhoai-admins` as dashboard admins with `cluster-reader` | The existing `rhbk` IdP is unchanged |

## Not done yet

- **Model count test:** done on the rebuilt cluster. See the Deployments section. The first cluster was torn down before its test finished.
- **TrustyAI on the rebuilt cluster:** solved, see "Trusted CA bundle race" below.

## Rebuilt cluster, 2026-11-09

The same layout was rebuilt with the fixes applied up front, using `rebuild.sh`:

- **Topology fixed first:** a worker in every zone and an unschedulable control plane, before any workloads. Applying all 2,134 objects at once then peaked etcd commit p99 at 46 ms, against about 3,000 ms on the old layout, with 0 controller restarts. **This is the evidence that was missing for the control-plane root cause.**
- **Pinning:** every Subscription was set to Manual approval after install, including the cluster's own RHBK.
- **Keycloak:** made persistent before any users, and checked by restarting both pods.
- **Controller limits:** the nine raised limits and Kuadrant at 3 Gi held with no restarts.
- **Stopped workbenches got harder at full scale:** creating all 350 at once, 77 still wouldn't stay stopped after 5 passes. It took several more passes, about 30 minutes, to reach 335 stopped and 15 running.
- **One-off OIDC failure:** the guide's OIDC test failed once ("Failed to list models (HTTP 200)") straight after the MaaS verification, then passed 6/6 on re-run.

**Disk fix, verified (2026-11-09 20:10 UTC).** Workers were replaced one zone at a time with 250 GB root disks, with no pods left pending. Workbenches are now restricted to CPU images when there are no GPUs. Images are pulled first by a DaemonSet (337 s for 3 nodes), then shards are applied one at a time. Re-applying the population, which changed the image on 182 workbenches:

| | Before (100 GB, parallel apply, CUDA image) | After (250 GB, prepull, staggered, CPU images) |
|---|---|---|
| Lowest free disk on a worker | 0 GB on all three | 104.5 GB (the node that had been pulling the 10 GB Ray image), 183 and 195 GB on the others |
| Evictions | 69 | 0 |

**Also verified in the same run:**
- **Held queue:** the 6 idle RayClusters on the `stopPolicy: Hold` queue stayed suspended, with 0 pods and no Kueue admission.
- **Model registry:** `lr-registry` was created and is `Available`.
- **CA-bundle wait:** TrustyAI and Feast, created after the wait, all came up Running.

**Generator bug found by this run:** a workbench's PVC size used the same random stream as its image, so shrinking the image list changed the size of existing PVCs. Applying that was rejected for 42 bound PVCs, because PVC specs are immutable. Size now has its own stream. The cluster's PVCs still have the old sizes: 253 differ from the generator, 200 of them unbound. That's harmless, because the inventory check doesn't compare sizes.

**Still not done on this cluster:**
- **Full-size checks:** comparing the population to the expected inventory, and re-running end-to-end tests at 357 projects.
- **Workload kinds not attempted:** `LMEvalJob`, `GuardrailsOrchestrator`, `NemoGuardrails`, `LLMBatchGateway` instances, `RayJob`, and anything needing GPUs.
- **Repeat tests:** a bulk apply and another cluster restart with the fixes in place.
- **Other dashboard pages:** not re-timed on this cluster.
- **MaaS dashboards:** their data is present, but the panels haven't been opened and checked in the console.
- **Restart test:** a cluster shutdown and restart with all the fixes in place.

## MaaS tiers, per-user load and maaspal (2026-11-09)

**Setup** (`60-maas-tiers.json`, `loadgen.py`):

- **Models:** 3 simulators (`llm-d-inference-sim`) in `lr-models`, plus the guide's `facebook-opt-125m` simulator, all behind MaaS.
- **Tiers:** each tier is a MaaSSubscription and MaaSAuthPolicy for one Keycloak group, covering all 4 models.

  | Tier | Group | Priority | Token limit per user per model |
  |---|---|---|---|
  | `tier-free` | `maas-free` | 50 | 2,000 / min |
  | `tier-standard` | `maas-standard` | 60 | 20,000 / min |
  | `tier-premium` | `maas-premium` | 70 | 200,000 / min |

- **Load:** a Deployment in `loaded-rhoai-load` runs one thread per user. Each of 60 users plus 2 power users logs in to Keycloak, mints their own API key and sends chat requests at a tier rate (free 0.03, standard 0.08, premium 0.15 requests/s). The power users send 1 request/s to one model, so they hit their limit. It exports `loadgen_requests_total` and `loadgen_tokens_total` per user, tier, model and status code, and stops sending while `/tmp/pause` exists.

**Results:**

- **Tier selection is right.** Every user's key resolved to their tier's subscription and listed 4 models. In Limitador's metrics, all 62 users appear with a `user` label and their own tier's subscription, with no empty labels.
- **Only the intended users are limited.** The power users got 429s; nobody else did, and there were 0 unexpected errors.
- **Per-user token counts are exact.** Over an 8-minute window between two quiet points, MaaS's `authorized_hits` for each user matched the tokens the load generator received: 115,648 against 115,648, exact for all 62 users. Rate-limited requests also matched exactly: 94 and 74 for the two power users, against `limited_calls` of 94 and 74. The earlier differences of −2.9% to +8.4% came from comparing live counters and across a load generator restart. **Validator rule:** measure between two quiet points from raw counter values, never live and never with `increase()`.
- **Label gotcha:** Limitador's `limitador_namespace` label holds `<namespace>/<route>` (here `llm/facebook-opt-125m-simulated-kserve-route`), not a namespace. maaspal's setting of that name needs the route form.

**maaspal 1.0.0** (Helm chart, registered in the dashboard; runs driven headlessly through its BFF with `maaspal_run.py`). 23 runs over all 15 scenarios: every scenario passed at least once except the two below. The earlier failures were my configuration: `send_from_browser` must be off for a headless run, two scenarios need `rbac.userProvisioning=true`, and `usage_metrics_accuracy` needs the route form above.

| Finding | Evidence | Status |
|---|---|---|
| **The guide's Issue 7 (auth timeout) still applies on 3.5.2.** `load_test` failed with 55.7% errors (642 × 500). With `AUTH_SERVICE_TIMEOUT=2s` in the `rhcl-operator` Subscription it passed with 0% errors and p99 1,389 ms | Before and after, same scenario | Confirmed. Make it part of install |
| **Keys don't share one budget until enforcement catches up.** `keys_share_user_budget` let 4,206, 1,227 and 3,313 tokens through against a 100-token budget before the first 429. After that, all of the user's keys were blocked together, as intended | 3 runs, all failing the same way | Reproducible. Cause not confirmed; likely enforcement lag after the scenario's new subscription turns Active |
| **`gateway_overhead` sends before limits are ready.** All 50 requests through MaaS got 403 "subscription rate limiting policies are not ready", while direct requests all succeeded. MaaS is failing closed correctly; the scenario doesn't wait for its new model's TokenRateLimitPolicy. Overhead p50 was about 70 ms | 2 runs | maaspal issue to raise |
| `model_config_health` failed once on a TokenRateLimitPolicy status that was still updating, then passed | 1 of 2 runs | Transient |
| `usage_metrics_accuracy`: requests and tokens matched within 5% | 1 run with the correct route | Pass |

## Changes this implies for the plan

1. **Install:**
   - Refuse or warn on schedulable control-plane nodes for large profiles, and require a worker in every zone holding volumes.
   - Set controller resources per profile.
   - Pin dependencies from the first install.
2. **Population:**
   - Create notebooks, then stop them.
   - Put Kueue work in its own namespaces.
   - Create operand CRs.
3. **Validator:**
   - Test real logins, not conditions.
   - Treat an error screen as a failure.
   - Require a settled cluster before timing, and record cluster state with each result.
   - Accept `NotApplicable`.
   - Alert on restarts and on memory near limits.
   - Report any CSV that changed during a run.
4. **Upgrades:** decide how raised limits and `managed=false` are handled before and after the upgrade under test.
5. **Risk 19 in the plan:** the MCP operator OOM hasn't appeared here at 357 projects (no restarts from memory), but wrong-model routing hasn't been tested.

## Gen AI, MCP Gateway and upgrade variants (2026-11-10)

Added to the running 3.5.2 cluster, then converted into deploy phases and checked by the new validator: OGX, MLflow, EvalHub and InferenceGraph workloads, 10 Gen AI playgrounds, the MCP Gateway, and 40 customised variants with 49 effect probes.

**Working, and how:**

- **OGX servers** chat through to a model in their own project. Their network policy admits only the same project and `redhat-ods-applications`, so probes run inside the OGX pod.
- **MLflow** is one cluster-wide server with a workspace per project. Every API call needs an `X-MLflow-Workspace: <project>` header; without it: `400 Workspace context is required`. Workspaces are separate: a project sees only its own experiments. 10 workspaces seeded with 60 runs.
- **Gen AI playgrounds** are created through the dashboard's gen-ai API (`POST /gen-ai/api/v1/lsd/install?namespace=…`, body `{"models": [{"model_name": "<MaaS id>", "model_source_type": "maas"}]}`) as a team member with a token from the OpenShift login. The product then creates the `OGXServer` (`lsd-genai-playground`), a pgvector Postgres with PVC, `llama-stack-config`, a service account and role binding, a ServiceMonitor, a PrometheusRule and two network policies. `lsd/delete` removes all of it. Chat goes through `lsd/responses` with the model id the playground reports (`maas-vllm-inference-1/publishers/…`), and the user's MaaS token is passed per request.
- **MCP Gateway** (operator `mcp-gateway` 0.7.1, `preview`): three team MCP servers registered (13 tools each), two virtual servers, Keycloak or OpenShift tokens required, offered to playgrounds through `gen-ai-aa-mcp-servers`. Tool calls run as the calling user: the gateway passes the caller's token to the OpenShift MCP server, which uses it against the Kubernetes API.
- **Variants:** a user-owned `LLMInferenceServiceConfig` is merged (its env var reaches the pod), a service naming the shipped `v3-5-2-kserve-config-llm-template` preset is Ready, the endpoint-picker scheduler runs in front of the simulator, and ISVC autoscaling, logger, custom service account and project hardware profile all take effect.

**Product issues and behaviour found:**

| Issue | Impact | Workaround | Evidence |
|---|---|---|---|
| Playground reports MaaS 429 as HTTP 500 "Too Many Requests" | The user sees a server error, not a rate limit | None | Playground log: `Provider SDK error … Too Many Requests` |
| Playground asks for up to 4,096 completion tokens by default | Fails with HTTP 400 against a model with a smaller context (the simulator's default 1,024); burns a free tier's per-minute token budget in a couple of chats | Simulators run with `--max-model-len 8192`; playground owners are paid-tier users | Reproduced |
| `cronScheduleTimezone` on a DSPA crashes the scheduled-workflow controller | `unknown time zone Europe/Dublin`: the image has no tzdata, so the documented setting is unusable | Variant gated off | Reproduced |
| Kueue-managed RayCluster can't autoscale | Admission denies `enableInTreeAutoscaling` unless it's an elastic job (`ElasticJobsViaWorkloadSlices` gate, off) | Autoscaling variant lives outside Kueue | Webhook message |
| InferenceGraph can't call InferenceServices in other projects | Admission rejects cross-namespace `serviceUrl`s | Graphs use models in their own project | Webhook message |
| InferenceGraph step with `serviceName` alone | Router POSTs to the model's root URL; an OpenAI-style server returns 404 | Steps use `serviceUrl` with `/v1/chat/completions` | Reproduced |
| MCP Gateway: listeners must share a port | The controller only accepts server routes on the extension listener's port; tool-call re-routing needs one Istio route table, so both listeners are plain HTTP | ClusterIP gateway behind an edge-TLS Route | v0.7.1 source |
| MCP Gateway: `privateHost` default assumes upstream Istio naming | Tool calls fail posting to `mcp-gateway-istio…:80`; OpenShift names it `<gateway>-openshift-default` | Set `privateHost` | Reproduced |
| MCP Gateway: virtual servers only work from `mcp-system` | The v0.7.1 controller writes their config to `mcp-system/mcp-gateway-config` regardless of the extension's namespace | Extension in `mcp-system` | v0.7.1 source and controller log |
| Any gateway with an AuthPolicy needs `security.opendatahub.io/authorino-tls-bootstrap` | Without it every request gets HTTP 500 (Kuadrant can't reach Authorino over TLS) | Annotate the gateway | Reproduced |
| OpenShift gateway DNS records outlive a LoadBalancer | After switching the gateway Service to ClusterIP, its DNSRecords kept pointing at the deleted ELB, shadowing `*.apps` | Delete them; create the gateway as ClusterIP from the start | Reproduced |
| OpenShift tries to publish DNS for an internal wildcard listener | `*.mcp.local` DNSRecord stays `Unknown` | Harmless | DNSRecord status |
| OLM: a new operator in a pinned namespace waits for approval | Install plans become Manual for the whole namespace once any Subscription there is Manual | Approve plans whose CSVs are all expected (phase 10) | Reproduced |
| Playground MCP check needs `X-MCP-Bearer` | Without it the gen-ai service reports the gateway as `unauthorized` | Send the user's token in that header | Reproduced |

**Behaviour to design around:**

- OGX restarts until its Postgres is up. Postgres goes in an earlier shard than the OGXServer.
- Generator builders share label dicts between objects; anything that adds labels must copy them. A variant label briefly leaked onto hundreds of objects before this was fixed (caught by diffing against the previous render).
- First full validator run: 174 checks passed. The failures were two validator bugs (system groups in RoleBindings, MaaS metrics read from the wrong Prometheus), leftover control-plane DaemonSet pods (cleaned by `fix_topology.py`), and the playground rate-limit issue above.
| RHOAI's own alerting fires for healthy operators | Six alerts fire in `redhat-ods-monitoring` while the operators are Running: "KubeRay Operator / Kubeflow Trainer / Kueue Operator is not running" test `absent(up{job="…"})` for jobs that RHOAI's Prometheus never scrapes (it only scrapes its OpenTelemetry collector), and "… Probe Success Burn Rate" (two critical) follow `probe_success = 0` for TrustyAI, Model Registry and Spark operators | Allowlisted with reasons; the validator now reads RHOAI's Prometheus over HTTPS, which the spike's sweep never did | Rules API and pod state |

## Upgrade to 3.6.0-ea.2 (2026-11-11)

New cluster, `medium` with 9 models, validated clean on 3.5.2 (181 checks), then moved to `rhods-operator.3.6.0-ea.2` from the `beta` channel by reinstalling the operator (`tools/reinstall_rhoai.sh beta rhods-operator.3.6`). None of the guide's post-upgrade fixes were applied. The new CSV was Succeeded 57 s after the old one was deleted. Validation 13 minutes later: 182 passed, 2 failed, 4 warnings (`reports/2026-11-11T181414Z`).

**Survived:** every one of the 2,226 baseline objects; every functional probe (models, graphs, OGX chat, EvalHub, MLflow workspaces, all 10 playground chats, MCP tool calls); all 49 variant probes; identity; MaaS. The load generator saw no errors across the reinstall (only 200s and the power users' expected 429s).

**Broke or changed:**

| What | Detail |
|---|---|
| DSC not Ready | TrustyAI component apply fails (the guide's boolean/string `permitOnline` mismatch); AIPipelines waiting; KServe briefly not ready (`odh-model-controller` 0 available, recovered) |
| Every OGXServer reports `Failed`, including all 10 playgrounds | `RoleBinding … roleRef: Invalid value`: 3.6 changes an immutable roleRef. The 3.5-era pods keep serving, so chats still work, but the servers can't be updated or reconciled |
| A user's TrainingRuntime was rewritten | `lr-torch-cpu` (copied from 3.5.2's `torch-distributed-cpu`) lost `mlPolicy.torch.numProcPerNode: "auto"`: the 3.6 CRD prunes it. A customised object silently changed by an upgrade, caught by the variant baseline |
| Presets | 3.6 adds 20 `v3-6-0-ea-2-*` LLMInferenceServiceConfigs and keeps the 20 `v3-5-2-*` ones. No existing LLMInferenceService moved to the new presets (13 minutes after the upgrade) |
| Controller memory limits lost for a renamed controller | 3.6's `spark-operator-module-controller-manager` (new name) runs at the 512 Mi default and is OOMKilled at this scale; phase 40 only knows the 3.5 name. Feast operator restarted 7 times |
| `odh-observability` | New in 3.6; in CrashLoopBackOff, cause not investigated |
