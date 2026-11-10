# loaded-rhoai vs opendatahub-tests

Nov 10, 2026 · @Philip Hayes

## Summary

**No, opendatahub-tests does not build a loaded cluster.** It is a functional test suite: each test creates one or two namespaces with a handful of objects, checks one behaviour, and deletes everything. Its upgrade tests are the only exception: they leave a small, targeted set of workloads in place across the upgrade, about 27 namespaces holding 1 to 5 workload objects each, and check each one in depth afterwards.

The two projects are complementary rather than overlapping:

- **opendatahub-tests goes deep on a few objects.** Real CPU models answer real requests. Each object gets a saved baseline (generation, restart counts, images, config references), and it checks specific migrations such as TrustyAI PVC to database and legacy MaaS ExternalModels.
- **loaded-rhoai goes broad and realistic.** It builds 355 projects, 350 workbenches, 300 Keycloak users and continuous per-user MaaS load. It covers components that opendatahub-tests never takes through an upgrade (Ray, TrainJob, Feast, the pipelines server itself, MLflow and others), and measures what users see in the dashboard.

The best result comes from using both: run opendatahub-tests' pre- and post-upgrade suites on a cluster that loaded-rhoai has populated, and borrow its per-object baseline checks for our validator.

Analysis of opendatahub-tests at commit `edd87556` (2026-11-09), from reading its code.

## What opendatahub-tests is

It is the ODH/RHOAI pytest suite, run against a cluster that already has RHOAI installed. About 1,040 Python files cover every component, using openshift-python-wrapper.

- **Self-contained tests.** CONSTITUTION.md requires every resource to be created and deleted through context managers, with fixtures at the narrowest scope. A class's namespace is the usual unit.
- **It changes the cluster temporarily.** Fixtures set DSC components to Managed or Unmanaged, patch shared ConfigMaps, add htpasswd identity providers, and install helper operators (MariaDB, cert-manager, Kueue). These changes are reverted when the session ends.
- **It doesn't install RHOAI or run upgrades.** `docs/UPGRADE.md`: "product upgrade is out of scope for this project and should be done by the user". That's the same split as our plan.
- **Health checks are basic.** A session gate checks that nodes, the DSCI and the DSC are Ready, and exits on failure. Separate tests check that operator pods are Running.
- **Reporting:** pytest JUnit, plus `oc adm must-gather` on each failure. There's no per-object inventory and no HTML report.

**How upgrade testing works:**

1. `pytest --pre-upgrade` runs tests marked `pre_upgrade`. Teardown is switched off, so their resources stay in place.
2. Many suites save a **baseline** in a ConfigMap in their namespace. Depending on the suite it holds the RHOAI version, generations, restart counts per pod, container images, LLMInferenceService config pins and Kueue gating counts.
3. The user upgrades RHOAI.
4. `pytest --post-upgrade` finds the same objects by name, compares them with the baseline, checks they still work, then deletes them.

Nothing detects that an upgrade actually happened, and nothing watches the cluster during the upgrade. The exception is Spark, which keeps a task running across the upgrade (up to 4 hours) and checks it finishes on the same driver.

## Workloads it deploys for upgrade testing

In total the upgrade suites keep about 27 namespaces through an upgrade. Those hold about 10 InferenceServices, 5 LLMInferenceServices, 7 to 9 Notebooks, 2 model registries, 2 TrustyAI services, 2 OGX servers, 2 pipeline servers and 6 Spark applications. Everything runs on CPU, and every model is real: OVMS (S3 and OCI modelcar), MLServer sklearn and XGBoost, and TinyLlama on vLLM CPU.

| Area | What stays through the upgrade | Real work | Checked after the upgrade |
| --- | --- | --- | --- |
| KServe InferenceService | 8 ISVCs in 7 namespaces. One each for: S3, OCI modelcar, auth with SA token, private endpoint, request logger, metrics, Kueue gating (1 running, 1 gated), and MLServer sklearn | OVMS and sklearn inference | Generation unchanged, pods not restarted (by name and restart count), inference works, old and new tokens work, 401 without a token, metrics history kept, gating unchanged |
| Kueue admission | AdmissionCheck, queues and a suspended Job | None | Still gated; once approved, the Job runs |
| LLMInferenceService | 2: TinyLlama without auth, and TinyLlama with auth and Kueue. `baseRefs` are found at runtime | vLLM CPU chat, 11 requests | Generation, URL, replicas, model URI, **container images and config pins** unchanged; InferencePool and HTTPRoute present |
| MaaS | ModelRef, AuthPolicy and Subscription (1000 tokens/min); 1 LLMISVC behind the MaaS gateway with a pre-upgrade API key; 2 AITenants each with their own model and limits (30 vs 10,000 tokens/min); a legacy ExternalModel | TinyLlama through the gateway | Old API key still works, OpenAI compatibility, tenant isolation, 429 for the small tenant, DB schema migration logs, legacy ExternalModel migrated |
| Workbench controller | 4 Notebooks in 2 namespaces: running, stopped, and Kueue-queued with a HardwareProfile | Pod Ready only | Pod not recreated, generations unchanged, auth proxy, routes and CA bundle intact, stopped stays stopped, Kueue admission kept |
| Workbench images | 3 to 5 Notebooks, one per IDE (JupyterLab, Elyra, code-server, RStudio), on the N-1 image | Kernel variable, PVC marker file | Same image digest pinned, kernel state kept, PVC data kept; a bump to the new image works |
| Model registry and catalog | 2 registries (external MySQL and generated Postgres) with 1 model each; a custom catalog source and 3 MCP catalog entries | Metadata writes | Models fetchable (by name only), API version v1beta1, custom sources kept |
| TrustyAI | 2 services, PVC and MariaDB storage, each with an XGBoost ISVC | Inference logged, drift metric | Metrics re-registered; **PVC to database migration** keeps the observation count |
| EvalHub | 1 CR on SQLite | Health only | CRD versions and conversion (but see the weaknesses section) |
| OGX | 2 servers: chat, and RAG with Milvus and a vector store | Chat and RAG against an external vLLM | Still answers; vector store reused |
| AutoML and AutoRAG | 2 DSPAs with 5 pipeline runs started | Runs reach Running | Run records and Workflows still exist |
| Spark | 3 SparkApplications, 2 scheduled, 1 SparkConnect | **A task held running through the upgrade** | Same pod UIDs and restart counts; task completes; new jobs run |

## Side by side

The largest differences are scale, identity and load. opendatahub-tests checks more about each object; loaded-rhoai has far more objects and users, and keeps them running.

|  | opendatahub-tests | loaded-rhoai |
| --- | --- | --- |
| Purpose | Prove each feature works, and survives an upgrade | Build a realistic, busy cluster, then validate it, including after an upgrade |
| Installs RHOAI | No; expects it installed | Yes, a chosen version (or adopts an existing install) |
| Lifetime of what it creates | Deleted after each test; upgrade objects deleted after the post-upgrade run | Kept permanently |
| Scale | 1 to 2 namespaces per test; largest loop defaults to 1 | 355 projects, 350 workbenches, about 2,100 objects at `medium` |
| Users | 1 existing non-admin user, temporary htpasswd users, service account tokens. Keycloak only in 2 MaaS OIDC tests | 300 Keycloak users through the OpenShift IdP, in groups and personas, every one logged in |
| Models | Real CPU models (OVMS, sklearn, TinyLlama vLLM) | Mostly simulators (`llm-d-inference-sim`) |
| Load | Bursts of up to 8 concurrent requests; `soak` defaults to 10 s | Continuous per-user MaaS load from 62 users, with 429s expected only for power users |
| Upgrade checks | Per object: generation, restarts, images, config pins, data, tokens | Whole cluster: inventory, state, startability, MaaS keys and limits, metric continuity (planned, §10.13) |
| During the upgrade | Nothing watched, except Spark's held task | Planned: load errors, longest gap, restarts by component |
| Customised configs | Several per area (auth, private endpoint, logger, Kueue, DB backends) | Mostly defaults today; variants planned (§6) |
| Dashboard / UI | No UI tests | Page timing and API call counts as admin, lead and user at scale |
| Observability | Dashboard-panel release contract; Authorino alerts | Per-user token panels, alerts, traces and logs, end to end (planned) |
| Reporting | JUnit and must-gather | JUnit, summary, HTML report, per-object inventory (planned) |
| GPU | Many GPU-marked tests, none in upgrade suites | None yet |

## Component coverage

Nine components have no upgrade test in opendatahub-tests; loaded-rhoai already populates six of them. "Populated" means running on the 3.5.2 spike cluster.

| Component | opendatahub-tests upgrade coverage | loaded-rhoai population |
| --- | --- | --- |
| InferenceService | Strong: 8 configurations | 9 ISVCs on a simulator runtime |
| LLMInferenceService | Strong: config pins, images | 4 simulators behind MaaS |
| MaaS | Strong: keys, tenants, migration | 3 tiers, 62 users under load, maaspal |
| Notebook | Strong: controller and N-1 images | 350 (335 stopped, 15 running) |
| Kueue | Yes: ISVC, LLMISVC, notebooks, admission checks | Queues per team, held RayClusters, TrainJobs |
| Model registry | Yes, shallow | 1 registry |
| TrustyAI | Yes, including PVC to DB migration | 2 services |
| OGX | Yes, needs an external vLLM | Smoke set only |
| Spark | Yes, including a job held through the upgrade | 3 SparkPi applications |
| EvalHub | Effectively no (CR recreated) | Smoke set only |
| AutoML, AutoRAG | Run records only | Not populated |
| Pipelines server (DSPA) itself | **None** | 6 DSPAs |
| RayCluster | **None** | 6 (held suspended) |
| TrainJob | **None** | 6 completed |
| Feast FeatureStore | **None** | 3 |
| MLflow | **None** | Smoke set only |
| InferenceGraph | **None** | Smoke set only |
| LMEvalJob, GuardrailsOrchestrator, NemoGuardrails | **None** | Not yet |
| LLMBatchGateway | **None** | Not yet |
| Dashboard | **None** (no UI tests) | Page timings at scale |

## What to borrow, and what we add

**Worth borrowing from opendatahub-tests:**

- **Per-object baseline fields.** Our plan saves a baseline before the upgrade (§10.13); theirs shows which fields catch real problems: `observedGeneration`, ServingRuntime generation, restart counts by pod name, container images, and LLMInferenceService config pins. We should capture these for every object, not a sample.
- **LLMInferenceService config pins.** `verify_llmisvc_config_refs_unchanged` reads the `serving.kserve.io/config-llm-*` status annotations and fails if any pin present before the upgrade is missing or changed, while allowing new ones. That's exactly our risk 24 (version-named presets such as `v3-5-2-kserve-config-llm-template`). Their check implies existing services are expected to keep their pins; a z-stream upgrade test will show whether that holds.
- **Real CPU models.** A few real models (TinyLlama on vLLM CPU, OVMS, sklearn) alongside our simulators would test runtime images and storage initialisation, which a simulator skips.
- **Credentials made before the upgrade.** Service account tokens and MaaS API keys from before the upgrade must still work afterwards, and a request with no token must still fail. We plan this for MaaS keys; extend it to ISVC and LLMISVC tokens.
- **Work held running through the upgrade.** Spark's held task proves that in-flight work survives. The same idea fits a running pipeline, RayJob and TrainJob.
- **Specific migration checks.** These include TrustyAI PVC to database, legacy MaaS ExternalModels, model registry `v1beta1` conversion, the MaaS EnvoyFilter attachment change, and MaaS DB schema logs. They belong in our upgrade path files (§5) as required steps.
- **Their customised configurations** (auth, private endpoint, logger, Kueue gating, admission checks, DB backends, multi-tenant MaaS) are a ready-made list for our customised variants (§6).
- **must-gather on failure**, and the openshift-python-wrapper resource classes in `utilities/resources/` for our Python validator.

**What loaded-rhoai adds that opendatahub-tests doesn't have:**

- Scale: hundreds of projects, workbenches and objects, and the problems that only appear at scale. The 3.5.2 spike found the Deployments page making about 10,000 API calls, controllers running out of memory, etcd stalls, and evictions from full disks.
- Real identity: 300 Keycloak users through the OpenShift IdP, with group-based RBAC.
- Continuous per-user load, with token counts that match MaaS exactly per user.
- Upgrade coverage for the nine components above.
- Dashboard timings at scale, measuring what users actually see.
- Measuring disruption during the upgrade: load errors and gaps while it runs (planned).
- A whole-cluster view: expected inventory, alerts, restarts and controller memory.

## Weaknesses in its upgrade tests

Reading the code turned up seven places where a post-upgrade test checks less than its name suggests. Each is worth confirming with the owning team before relying on it.

| Area | What the code does | Effect |
| --- | --- | --- |
| EvalHub | The `evalhub_cr` fixture is a plain `with EvalHub(...)` with no pre/post-upgrade handling (`tests/ai_safety/evalhub/conftest.py`) | The CR is probably deleted after the pre-upgrade run and recreated, so "survived the upgrade" is tested on a new CR |
| AutoML, AutoRAG | Pre-upgrade waits only for Running; post-upgrade checks that the run record exists. AutoRAG uses fake `*.invalid` endpoints | No pipeline run is shown to finish across an upgrade |
| Model registry | Post-upgrade compares only the model name | Lost descriptions, owners or versions would pass |
| MLServer | Compares restart counts of `predictor_pods[0]`, not pod identity | A replaced pod (restart count back to 0) passes |
| MaaS basic upgrade | The MaaSModelRef points at an LLMInferenceService that's never created | Governance objects survive, but nothing is served through them |
| Elyra runtime config | Nothing creates a runtime config, and the check returns early without one | Always passes |
| JupyterLab image bump | Skips on z-stream upgrades unless the old tag is pinned | No coverage for the most common upgrade |

## Recommendations

Run opendatahub-tests' upgrade suites on a loaded-rhoai cluster, and borrow its per-object checks into our validator.

1. **Add a `validate --odh-tests` step.** Before the upgrade, `pytest --pre-upgrade` adds its roughly 27 namespaces to our population. After the upgrade, `pytest --post-upgrade` gives a deep per-object result next to our cluster-wide one. Its results go into our report as a separate layer.
2. **Check where the two could collide first.** Their fixtures make changes that could disturb a loaded cluster:
   - set DSC components to Managed or Unmanaged (Kueue to Unmanaged)
   - patch `oauth/cluster` to add htpasswd users, alongside our Keycloak IdP
   - patch, then delete, the shared `model-catalog-sources` ConfigMap
   - patch user-workload monitoring

   Run them once on the spike cluster and diff the cluster before and after.
3. **Adopt their baseline fields** in our upgrade comparison (§10.13): generations, restart counts by pod, images, LLMISVC config pins, and credentials issued before the upgrade.
4. **Add a few real CPU models** next to the simulators (TinyLlama on vLLM CPU, an OVMS model and an sklearn model), and **hold in-flight work through the upgrade**: a pipeline run, a RayJob and a TrainJob, like their Spark task.
5. **Take their customised configurations** into our variants list (§6), and their migration checks into our upgrade path files (§5).
6. **Feed back our findings:** the nine components with no upgrade coverage, the seven weak checks above, and the 3.5.2 spike issues that only appear at scale.
