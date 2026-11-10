"""Customised variants: upgrade canaries (PLAN.md §6 "Customised variants").

Defaults are the path every upgrade is tested on; customisations are where upgrades break. Each
variant exercises one non-default configuration path, carries loaded-rhoai.io/variant, lives in a
team project among ordinary objects, and records effect probes in the expected inventory: checks
that prove the customisation is in force, not just present in the spec. The validator runs them.

Probe types (validator/probes.py):
  field    {kind, namespace, name, path, op: eq|ne|contains|exists|absent, value}
  pod      {namespace, labels, path, op, value}           a running pod matching labels
  pod_env  {namespace, labels, env, value}                an env var in a running pod's containers
  owned    {kind, namespace, owner_kind, owner, path?, op?, value?}   an object owned by another
Paths are dotted; `conditions[Ready]` picks a condition by type, `containers[*]` any element.
"""

SIM_IMAGE = "ghcr.io/llm-d/llm-d-inference-sim:v0.7.1"
LABEL = "loaded-rhoai.io/variant"


def label(doc, variant):
    # Copy: generator builders share label dicts between objects, so never mutate one in place.
    doc["metadata"]["labels"] = {**(doc["metadata"].get("labels") or {}), LABEL: variant}
    return doc


def field(kind, ns, name, path, op="exists", value=None):
    return {"type": "field", "kind": kind, "namespace": ns, "name": name, "path": path, "op": op, "value": value}


def ready(kind, ns, name, cond="Ready"):
    return field(kind, ns, name, f"status.conditions[{cond}].status", "eq", "True")


def sim_container(model, env=None, extra_args=None):
    return {"name": "main", "image": SIM_IMAGE, "imagePullPolicy": "IfNotPresent", "command": ["/app/llm-d-inference-sim"],
            "args": ["--port", "8000", "--model", model, "--max-model-len", "8192", *(extra_args or []), "--mode", "random",
                     "--ssl-certfile", "/var/run/kserve/tls/tls.crt", "--ssl-keyfile", "/var/run/kserve/tls/tls.key"],
            "env": [{"name": "POD_NAME", "valueFrom": {"fieldRef": {"fieldPath": "metadata.name"}}},
                    {"name": "POD_NAMESPACE", "valueFrom": {"fieldRef": {"fieldPath": "metadata.namespace"}}}, *(env or [])],
            "ports": [{"name": "https", "containerPort": 8000, "protocol": "TCP"}],
            "livenessProbe": {"httpGet": {"path": "/health", "port": "https", "scheme": "HTTPS"}},
            "readinessProbe": {"httpGet": {"path": "/ready", "port": "https", "scheme": "HTTPS"}},
            "resources": {"requests": {"cpu": "50m", "memory": "128Mi"}, "limits": {"cpu": "500m", "memory": "512Mi"}}}


def llmisvc(ns, name, model, variant, spec_extra=None, template=True, env=None):
    spec = {"model": {"uri": "hf://sshleifer/tiny-gpt2", "name": model}, "replicas": 1,
            "router": {"route": {}, "gateway": {"refs": [{"name": "maas-default-gateway", "namespace": "openshift-ingress"}]}}}
    if template:
        spec["template"] = {"containers": [sim_container(model, env)]}
    spec.update(spec_extra or {})
    return label({"apiVersion": "serving.kserve.io/v1alpha1", "kind": "LLMInferenceService",
                  "metadata": {"name": name, "namespace": ns}, "spec": spec}, variant)


def build(pop, refs, ctx):
    """Add every variant. ctx: teams, running_models, seed, postgres(ns, name, db, pw), secret_value."""
    teams, running = ctx["teams"], ctx["running_models"]
    t = lambda i: f"lr-{teams[i % len(teams)]}"
    LLM = "lr-models"   # labelled for MaaS gateway access, which LLMInferenceService routes need

    # ---- LLMInferenceService and LLMInferenceServiceConfig -------------------------------------
    cfg_name = "lr-user-sim-config"
    pop.add(LLM, label({"apiVersion": "serving.kserve.io/v1alpha1", "kind": "LLMInferenceServiceConfig",
                        "metadata": {"name": cfg_name, "namespace": LLM},
                        "spec": {"template": {"containers": [sim_container("user-config", [{"name": "LR_VARIANT", "value": "user-config"}])]},
                                 "labels": {"loaded-rhoai.io/from-config": cfg_name}}}, "llmisvcconfig-user"),
            state="static", variant="llmisvcconfig-user")
    for name, var in (("lr-var-userconfig", "llmisvc-user-config"), ("lr-var-sharedconfig", "llmisvc-shared-config")):
        pop.add(LLM, llmisvc(LLM, name, f"variant/{name}", var, {"baseRefs": [{"name": cfg_name}]}, template=False),
                state="ready", variant=var,
                probes=[ready("LLMInferenceService", LLM, name),
                        field("LLMInferenceService", LLM, name, "status.appliedConfigs[*].name", "contains", cfg_name),
                        {"type": "pod_env", "namespace": LLM, "labels": {"app.kubernetes.io/name": name, "kserve.io/component": "workload"}, "env": "LR_VARIANT", "value": "user-config"}])
    preset = refs["llmTemplatePreset"]   # e.g. v3-5-2-kserve-config-llm-template: renamed every release
    pop.add(LLM, llmisvc(LLM, "lr-var-pinnedpreset", "variant/pinned-preset", "llmisvc-pinned-preset", {"baseRefs": [{"name": preset}]}),
            state="ready", variant="llmisvc-pinned-preset",
            probes=[ready("LLMInferenceService", LLM, "lr-var-pinnedpreset"),
                    field("LLMInferenceService", LLM, "lr-var-pinnedpreset", "spec.baseRefs[*].name", "contains", preset)])
    pop.add(LLM, llmisvc(LLM, "lr-var-replicas", "variant/replicas", "llmisvc-replicas", {"replicas": 2}),
            state="ready", variant="llmisvc-replicas",
            probes=[ready("LLMInferenceService", LLM, "lr-var-replicas"),
                    field("Deployment", LLM, "lr-var-replicas-kserve", "status.readyReplicas", "eq", 2)])
    pop.add(LLM, llmisvc(LLM, "lr-var-scheduler", "variant/scheduler", "llmisvc-scheduler",
                         {"router": {"route": {}, "scheduler": {},
                                     "gateway": {"refs": [{"name": "maas-default-gateway", "namespace": "openshift-ingress"}]}}}),
            state="ready", variant="llmisvc-scheduler",
            probes=[ready("LLMInferenceService", LLM, "lr-var-scheduler"),
                    field("Deployment", LLM, "lr-var-scheduler-kserve-router-scheduler", "status.readyReplicas", "eq", 1)])

    # ---- InferenceService, ServingRuntime, InferenceGraph --------------------------------------
    sns = t(4)
    pop.add(sns, label(ctx["serving_runtime"](sns, "lr-sim-variant"), "servingruntime-custom"), state="static", variant="servingruntime-custom")
    ro = refs["runtimeTemplate"]["object"]
    copy = {"apiVersion": ro["apiVersion"], "kind": ro["kind"], "spec": ro["spec"],
            "metadata": {"name": "lr-vllm-cpu-copy", "namespace": sns, "labels": dict(ro["metadata"].get("labels", {})),
                         "annotations": dict(ro["metadata"].get("annotations", {}), **{"opendatahub.io/template-name": refs["runtimeTemplate"]["name"],
                                                                                       "opendatahub.io/template-display-name": "vLLM CPU (copied)"})}}
    pop.add(sns, label(copy, "servingruntime-template-copy"), state="static", variant="servingruntime-template-copy",
            probes=[field("ServingRuntime", sns, "lr-vllm-cpu-copy", "metadata.annotations.opendatahub\\.io/template-name", "eq", refs["runtimeTemplate"]["name"])])
    edited = {**copy, "metadata": {**copy["metadata"], "name": "lr-vllm-cpu-edited"},
              "spec": {**copy["spec"], "containers": [dict(copy["spec"]["containers"][0], args=copy["spec"]["containers"][0]["args"] + ["--max-model-len=2048"])]}}
    pop.add(sns, label(edited, "servingruntime-edited"), state="static", variant="servingruntime-edited",
            probes=[field("ServingRuntime", sns, "lr-vllm-cpu-edited", "spec.containers[*].args", "contains", "--max-model-len=2048")])

    def var_isvc(name, var, predictor_extra, annotations=None):
        ann = {"serving.kserve.io/deploymentMode": "RawDeployment", "openshift.io/display-name": name, **(annotations or {})}
        pred = {"minReplicas": 1, "maxReplicas": 1, "model": {"modelFormat": {"name": "sim"}, "runtime": "lr-sim-variant"}}
        pred.update(predictor_extra)
        return label({"apiVersion": "serving.kserve.io/v1beta1", "kind": "InferenceService",
                      "metadata": {"name": name, "namespace": sns, "labels": {"opendatahub.io/dashboard": "true"}, "annotations": ann},
                      "spec": {"predictor": pred}}, var)

    pop.add(sns, var_isvc("var-autoscale", "isvc-autoscale", {"minReplicas": 1, "maxReplicas": 2, "scaleMetric": "cpu", "scaleTarget": 80}),
            state="running", variant="isvc-autoscale",
            probes=[ready("InferenceService", sns, "var-autoscale"),
                    {"type": "owned", "kind": "HorizontalPodAutoscaler", "namespace": sns, "owner_kind": "InferenceService", "owner": "var-autoscale",
                     "path": "spec.maxReplicas", "op": "eq", "value": 2}])
    pop.add(sns, {"apiVersion": "v1", "kind": "ServiceAccount", "metadata": {"name": "lr-model-sa", "namespace": sns}})
    pop.add(sns, var_isvc("var-custom-sa", "isvc-service-account", {"serviceAccountName": "lr-model-sa"}),
            state="running", variant="isvc-service-account",
            probes=[ready("InferenceService", sns, "var-custom-sa"),
                    {"type": "pod", "namespace": sns, "labels": {"serving.kserve.io/inferenceservice": "var-custom-sa"},
                     "path": "spec.serviceAccountName", "op": "eq", "value": "lr-model-sa"}])
    logger_url = f"http://{running[0][1]}-predictor.{running[0][0]}.svc.cluster.local"
    pop.add(sns, var_isvc("var-logger", "isvc-logger", {"logger": {"mode": "all", "url": logger_url}}),
            state="running", variant="isvc-logger",
            probes=[ready("InferenceService", sns, "var-logger"),
                    {"type": "pod", "namespace": sns, "labels": {"serving.kserve.io/inferenceservice": "var-logger"},
                     "path": "spec.containers[*].name", "op": "contains", "value": "agent"}])
    hw = {"apiVersion": refs["hardwareProfile"]["apiVersion"], "kind": "HardwareProfile",
          "metadata": {"name": "lr-project-small", "namespace": sns,
                       "annotations": {"opendatahub.io/display-name": "Project small (variant)"}},
          "spec": {"identifiers": [{"identifier": "cpu", "displayName": "CPU", "resourceType": "CPU", "minCount": "100m", "defaultCount": "200m", "maxCount": "1"},
                                   {"identifier": "memory", "displayName": "Memory", "resourceType": "Memory", "minCount": "128Mi", "defaultCount": "256Mi", "maxCount": "1Gi"}],
                   "scheduling": {"type": "Node", "node": {"nodeSelector": {"node-role.kubernetes.io/worker": ""},
                                                           "tolerations": [{"key": "loaded-rhoai.io/variant", "operator": "Exists", "effect": "NoSchedule"}]}}}}
    pop.add(sns, label(hw, "hardwareprofile-project"), state="static", variant="hardwareprofile-project")
    pop.add(sns, var_isvc("var-hwprofile", "isvc-hardware-profile", {},
                          {"opendatahub.io/hardware-profile-name": "lr-project-small", "opendatahub.io/hardware-profile-namespace": sns}),
            state="running", variant="isvc-hardware-profile",
            probes=[ready("InferenceService", sns, "var-hwprofile"),
                    {"type": "pod", "namespace": sns, "labels": {"serving.kserve.io/inferenceservice": "var-hwprofile"},
                     "path": "spec.tolerations[*].key", "op": "contains", "value": "loaded-rhoai.io/variant"}])

    # A graph may only call InferenceServices in its own project (admission webhook on 3.5.2), so
    # the graphs use this project's variant models.
    urls = [f"http://{m}-predictor.{sns}.svc.cluster.local/v1/chat/completions" for m in ("var-custom-sa", "var-hwprofile")]
    if True:
        graphs = {
            "graph-switch": {"routerType": "Switch", "steps": [{"name": "a", "serviceUrl": urls[0], "condition": "[@this].#(model==\"sim\")"},
                                                               {"name": "b", "serviceUrl": urls[1]}]},
            "graph-ensemble": {"routerType": "Ensemble", "steps": [{"name": "a", "serviceUrl": urls[0]}, {"name": "b", "serviceUrl": urls[1]}]},
            "graph-splitter": {"routerType": "Splitter", "steps": [{"name": "a", "serviceUrl": urls[0], "weight": 80},
                                                                   {"name": "b", "serviceUrl": urls[1], "weight": 20}]},
        }
        for gname, root in graphs.items():
            var = "inferencegraph-" + root["routerType"].lower()
            pop.add(sns, label({"apiVersion": "serving.kserve.io/v1alpha1", "kind": "InferenceGraph",
                                "metadata": {"name": gname, "namespace": sns, "annotations": {"serving.kserve.io/deploymentMode": "RawDeployment"}},
                                "spec": {"nodes": {"root": root}}}, var),
                    state="ready", variant=var,
                    probes=[ready("InferenceGraph", sns, gname),
                            field("InferenceGraph", sns, gname, "spec.nodes.root.routerType", "eq", root["routerType"])])

    # ---- Workbenches -------------------------------------------------------------------------
    wns = t(5)
    old = refs.get("olderNotebook")
    if old:
        pvc, nb = ctx["notebook"](wns, "var-older-image", "user0006", f"{old['stream']}:{old['tag']}", old["image"], False)
        pop.add(wns, pvc, state="unbound-ok")
        pop.add(wns, label(nb, "notebook-older-image"), state="stopped", variant="notebook-older-image",
                probes=[field("Notebook", wns, "var-older-image", "spec.template.spec.containers[*].image", "contains", old["image"])])
    cur = refs["currentNotebook"]
    pop.add("redhat-ods-applications", label({"apiVersion": "image.openshift.io/v1", "kind": "ImageStream",
                                               "metadata": {"name": "lr-byon-minimal", "namespace": "redhat-ods-applications",
                                                            "labels": {"opendatahub.io/notebook-image": "true", "opendatahub.io/dashboard": "true"},
                                                            "annotations": {"opendatahub.io/notebook-image-name": "LR custom minimal (BYON)",
                                                                            "opendatahub.io/notebook-image-desc": "Bring-your-own-notebook variant",
                                                                            "opendatahub.io/notebook-image-creator": "loaded-rhoai"}},
                                               "spec": {"lookupPolicy": {"local": True},
                                                        "tags": [{"name": "1.0", "from": {"kind": "DockerImage", "name": cur["image"]},
                                                                  "annotations": {"opendatahub.io/notebook-python-dependencies": "[]"}}]}},
                                              "notebook-byon"), state="static", variant="notebook-byon",
            probes=[field("ImageStream", "redhat-ods-applications", "lr-byon-minimal", "status.tags[*].tag", "contains", "1.0")])
    pvc, nb = ctx["notebook"](wns, "var-byon", "user0006", "lr-byon-minimal:1.0", cur["image"], False)
    pop.add(wns, pvc, state="unbound-ok")
    pop.add(wns, label(nb, "notebook-byon"), state="stopped", variant="notebook-byon-workbench")
    pvc, nb = ctx["notebook"](wns, "var-extras", "user0006", f"{cur['stream']}:{cur['tag']}", cur["image"], False)
    c = nb["spec"]["template"]["spec"]["containers"][0]
    c["envFrom"] = [{"secretRef": {"name": "shared-minio"}}]
    c["volumeMounts"].append({"name": "shared-data", "mountPath": "/opt/app-root/src/shared"})
    nb["spec"]["template"]["spec"]["volumes"].append({"name": "shared-data", "persistentVolumeClaim": {"claimName": "lr-shared-data"}})
    nb["metadata"]["annotations"].update({"opendatahub.io/hardware-profile-name": "lr-project-small", "opendatahub.io/hardware-profile-namespace": wns})
    pop.add(wns, {"apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": {"name": "lr-shared-data", "namespace": wns},
                  "spec": {"accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "2Gi"}}}}, state="unbound-ok")
    pop.add(wns, label({**hw, "metadata": {**hw["metadata"], "namespace": wns}}, "hardwareprofile-project"), state="static", variant="hardwareprofile-project-2")
    pop.add(wns, pvc, state="unbound-ok")
    pop.add(wns, label(nb, "notebook-connection-data-hwprofile"), state="stopped", variant="notebook-connection-data-hwprofile",
            probes=[field("Notebook", wns, "var-extras", "spec.template.spec.containers[*].envFrom[*].secretRef.name", "contains", "shared-minio"),
                    field("Notebook", wns, "var-extras", "metadata.annotations.opendatahub\\.io/hardware-profile-name", "eq", "lr-project-small")])

    # ---- Pipelines ---------------------------------------------------------------------------
    # Gated off on 3.5.2: ds-pipeline-scheduledworkflow crashes with "unknown time zone Europe/Dublin"
    # (no tzdata in the image), so the documented cronScheduleTimezone setting can't be healthy.
    pop.skip("dspa-timezone", "scheduledworkflow fails with 'unknown time zone Europe/Dublin' on 3.5.2 (no tzdata in the image)")
    for i, (var, extra) in enumerate((("dspa-mlmd-nocache-notls", {"mlmd": {"deploy": True}, "podToPodTLS": False}),)):
        ns = t(12 + i)
        docs = ctx["dspa"](ns)
        d = docs[1]
        d["spec"].update(extra)
        if var == "dspa-mlmd-nocache-notls":
            d["spec"]["apiServer"]["cacheEnabled"] = False
        pop.add(ns, docs[0], state="static")
        pop.add(ns, label(d, var), state="ready", variant=var,
                probes=[ready("DataSciencePipelinesApplication", ns, "dspa")] +
                       ([field("Deployment", ns, "ds-pipeline-metadata-grpc-dspa", "status.readyReplicas", "eq", 1)] if "mlmd" in extra else []))
        ctx["buckets"].append(f"dspa-{ns}")

    # ---- Feast --------------------------------------------------------------------------------
    fns = t(14)
    pop.add("_after_ca", label({"apiVersion": "feast.dev/v1", "kind": "FeatureStore", "metadata": {"name": f"features-{fns}-authz", "namespace": fns},
                                "spec": {"feastProject": fns.replace("-", "_") + "_authz", "services": {"ui": {}},
                                         "authz": {"kubernetes": {"roles": ["feast-reader", "feast-writer"]}},
                                         "cronJob": {"schedule": "0 3 * * *"}}}, "featurestore-authz-ui-cron"),
            state="ready", variant="featurestore-authz-ui-cron",
            probes=[field("FeatureStore", fns, f"features-{fns}-authz", "status.phase", "eq", "Ready"),
                    field("CronJob", fns, f"feast-features-{fns}-authz", "spec.schedule", "eq", "0 3 * * *")])

    # ---- Model registry on an external Postgres -----------------------------------------------
    mr = "rhoai-model-registries"
    for d in ctx["postgres"](mr, "lr-registry-db", "registry", ctx["secret_value"](ctx["seed"], "registry-db")):
        pop.add(mr, d, state="ready" if d["kind"] == "Deployment" else "static")
    pop.add("_after_ca", label({"apiVersion": "modelregistry.opendatahub.io/v1beta1", "kind": "ModelRegistry",
                                "metadata": {"name": "lr-registry-extdb", "namespace": mr},
                                "spec": {"grpc": {}, "rest": {}, "kubeRBACProxy": {},
                                         "postgres": {"host": "lr-registry-db", "port": 5432, "database": "registry", "username": "registry",
                                                      "passwordSecret": {"name": "lr-registry-db", "key": "POSTGRES_PASSWORD"}}}}, "modelregistry-external-db"),
            state="ready", variant="modelregistry-external-db",
            probes=[ready("ModelRegistry", mr, "lr-registry-extdb", "Available"),
                    field("ModelRegistry", mr, "lr-registry-extdb", "spec.postgres.host", "eq", "lr-registry-db")])

    # ---- Ray, training, Kueue -----------------------------------------------------------------
    bns, team = f"lr-{teams[0]}-batch", teams[0]
    # Autoscaling isn't allowed for a Kueue-managed RayCluster unless it's an elastic job (feature gate
    # ElasticJobsViaWorkloadSlices, off on 3.5.2), so this one lives in a project outside Kueue,
    # where suspend: true holds by itself.
    rns = t(18)
    rc = ctx["raycluster"](rns, "ray-autoscale", None)
    rc["metadata"].pop("labels", None)
    rc["spec"]["enableInTreeAutoscaling"] = True
    rc["spec"]["autoscalerOptions"] = {"upscalingMode": "Default", "idleTimeoutSeconds": 60}
    second = dict(rc["spec"]["workerGroupSpecs"][0], groupName="burst", replicas=0, minReplicas=0, maxReplicas=2)
    rc["spec"]["workerGroupSpecs"].append(second)
    pop.add(rns, label(rc, "raycluster-autoscale-two-groups"), state="suspended", variant="raycluster-autoscale-two-groups",
            probes=[field("RayCluster", rns, "ray-autoscale", "spec.workerGroupSpecs[*].groupName", "contains", "burst"),
                    field("RayCluster", rns, "ray-autoscale", "status.state", "eq", "suspended")])
    pop.add(bns, label({"apiVersion": "trainer.kubeflow.org/v1alpha1", "kind": "TrainingRuntime",
                        "metadata": {"name": "lr-torch-cpu", "namespace": bns}, "spec": refs["trainingRuntime"]["spec"]}, "trainingruntime-namespaced"),
            state="static", variant="trainingruntime-namespaced")
    tj = ctx["trainjob"](bns, "train-custom-runtime", "team-queue")
    tj["spec"]["runtimeRef"] = {"name": "lr-torch-cpu", "kind": "TrainingRuntime", "apiGroup": "trainer.kubeflow.org"}
    tj["spec"]["trainer"]["env"] = [{"name": "LR_VARIANT", "value": "namespaced-runtime"}]
    pop.add(bns, label(tj, "trainjob-namespaced-runtime"), state="completed", variant="trainjob-namespaced-runtime",
            probes=[field("TrainJob", bns, "train-custom-runtime", "status.conditions[Complete].status", "eq", "True")])
    pop.add("_cluster", label({"apiVersion": "kueue.x-k8s.io/v1beta2", "kind": "WorkloadPriorityClass", "metadata": {"name": "lr-high"},
                               "value": 1000, "description": "Urgent team work (variant)"}, "kueue-priority-class"),
            state="static", variant="kueue-priority-class")
    pop.add("_cluster", label({"apiVersion": "kueue.x-k8s.io/v1beta2", "kind": "Cohort", "metadata": {"name": "lr-shared"}}, "kueue-cohort"),
            state="static", variant="kueue-cohort")
    for name, quota, borrow in (("cq-lr-shared-a", "2", "2"), ("cq-lr-shared-b", "2", "1")):
        pop.add("_cluster", label({"apiVersion": "kueue.x-k8s.io/v1beta2", "kind": "ClusterQueue", "metadata": {"name": name},
                                   "spec": {"cohortName": "lr-shared", "namespaceSelector": {"matchLabels": {"loaded-rhoai.io/team": team}},
                                            "preemption": {"reclaimWithinCohort": "Any", "withinClusterQueue": "LowerPriority"},
                                            "resourceGroups": [{"coveredResources": ["cpu", "memory"], "flavors": [{"name": "default-flavor", "resources": [
                                                {"name": "cpu", "nominalQuota": quota, "borrowingLimit": borrow},
                                                {"name": "memory", "nominalQuota": "4Gi", "borrowingLimit": "2Gi"}]}]}]}}, "kueue-cohort-borrowing"),
                state="static", variant="kueue-cohort-borrowing",
                probes=[field("ClusterQueue", None, name, "status.conditions[Active].status", "eq", "True")])

    # ---- Spark --------------------------------------------------------------------------------
    kns = t(16)
    sp = ctx["spark"](kns)
    for d in sp:
        if d["kind"] != "SparkApplication":
            pop.add(kns, d)
    app = sp[-1]
    dyn = {**app, "metadata": {"name": "spark-dynamic", "namespace": kns},
           "spec": {**app["spec"], "dynamicAllocation": {"enabled": True, "initialExecutors": 1, "minExecutors": 1, "maxExecutors": 2}}}
    pop.add(kns, label(dyn, "spark-dynamic-allocation"), state="completed", variant="spark-dynamic-allocation",
            probes=[field("SparkApplication", kns, "spark-dynamic", "spec.dynamicAllocation.enabled", "eq", True)])
    pop.add(kns, label({"apiVersion": "sparkoperator.k8s.io/v1beta2", "kind": "ScheduledSparkApplication",
                        "metadata": {"name": "spark-nightly", "namespace": kns},
                        "spec": {"schedule": "30 2 * * *", "concurrencyPolicy": "Forbid", "successfulRunHistoryLimit": 2,
                                 "template": app["spec"]}}, "spark-scheduled"),
            state="static", variant="spark-scheduled",
            probes=[field("ScheduledSparkApplication", kns, "spark-nightly", "status.scheduleState", "eq", "Scheduled")])

    # ---- MCP server ---------------------------------------------------------------------------
    mns = t(17)
    pop.add(mns, label({"apiVersion": "mcp.x-k8s.io/v1alpha1", "kind": "MCPServer", "metadata": {"name": "openshift-mcp-ha", "namespace": mns},
                        "spec": {"source": {"type": "ContainerImage", "containerImage": {"ref": "registry.redhat.io/openshift-mcp-tech-preview/openshift-mcp-server-rhel9:0.4"}},
                                 "config": {"port": 8080, "path": "/mcp", "arguments": ["--port", "8080", "--read-only", "--log-level", "2"]},
                                 "runtime": {"replicas": 2, "resources": {"requests": {"cpu": "50m", "memory": "128Mi"}, "limits": {"cpu": "300m", "memory": "256Mi"}}}}},
                       "mcpserver-replicas-args"),
            state="ready", variant="mcpserver-replicas-args",
            probes=[ready("MCPServer", mns, "openshift-mcp-ha"),
                    field("Deployment", mns, "openshift-mcp-ha", "status.readyReplicas", "eq", 2)])

    # ---- Kuadrant policies outside MaaS (on the MCP gateway) ----------------------------------
    pop.add("mcp-system", label({"apiVersion": "kuadrant.io/v1", "kind": "RateLimitPolicy", "metadata": {"name": "mcp-per-caller", "namespace": "mcp-system"},
                                 "spec": {"targetRef": {"group": "gateway.networking.k8s.io", "kind": "HTTPRoute", "name": "mcp-gateway-route"},
                                          "limits": {"per-caller": {"rates": [{"limit": 600, "window": "1m"}],
                                                                    "counters": [{"expression": "request.headers.authorization"}]}}}}, "ratelimitpolicy-mcp"),
            state="ready", variant="ratelimitpolicy-mcp",
            probes=[field("RateLimitPolicy", "mcp-system", "mcp-per-caller", "status.conditions[Enforced].status", "eq", "True")])
    pop.add("openshift-ingress", label({"apiVersion": "extensions.kuadrant.io/v1alpha1", "kind": "TelemetryPolicy",
                                        "metadata": {"name": "mcp-telemetry", "namespace": "openshift-ingress"},
                                        "spec": {"targetRef": {"group": "gateway.networking.k8s.io", "kind": "Gateway", "name": "mcp-gateway"},
                                                 "metrics": {"default": {"labels": {
                                                     "virtual_server": "has(request.headers['x-mcp-virtualserver']) ? request.headers['x-mcp-virtualserver'] : \"\"",
                                                     "path": "request.path"}}}}}, "telemetrypolicy-mcp"),
            state="ready", variant="telemetrypolicy-mcp",
            probes=[field("TelemetryPolicy", "openshift-ingress", "mcp-telemetry", "status.conditions[Accepted].status", "eq", "True")])

    # ---- Platform -----------------------------------------------------------------------------
    apps = "redhat-ods-applications"
    pop.add(apps, label({"apiVersion": refs["hardwareProfile"]["apiVersion"], "kind": "HardwareProfile",
                         "metadata": {"name": "lr-cluster-large", "namespace": apps, "annotations": {"opendatahub.io/display-name": "Large CPU (variant)"}},
                         "spec": {"identifiers": [{"identifier": "cpu", "displayName": "CPU", "resourceType": "CPU", "minCount": 2, "defaultCount": 4, "maxCount": 8},
                                                  {"identifier": "memory", "displayName": "Memory", "resourceType": "Memory", "minCount": "8Gi", "defaultCount": "16Gi", "maxCount": "32Gi"}]}},
                        "hardwareprofile-cluster"), state="static", variant="hardwareprofile-cluster")
    ct = refs["connectionTypeS3"]
    ctype = {"apiVersion": "v1", "kind": "ConfigMap", "data": ct["data"],
             "metadata": {"name": "lr-s3-team-buckets", "namespace": apps,
                          "labels": {"opendatahub.io/connection-type": "true", "opendatahub.io/dashboard": "true"},
                          "annotations": {"openshift.io/display-name": "Team S3 buckets (variant)",
                                          "openshift.io/description": "A custom connection type copied from S3"}}}
    pop.add(apps, label(ctype, "connectiontype-custom"), state="static", variant="connectiontype-custom")
