"""Thin, cached access to the cluster through `oc` (PLAN.md §10). Standard library only."""
import json
import subprocess
import time

_cache = {}

# Kinds whose plain name is ambiguous or not served under the kind name.
RESOURCE = {
    "Deployment": "deployments.apps", "Service": "services", "ConfigMap": "configmaps", "Secret": "secrets",
    "Namespace": "namespaces", "PersistentVolumeClaim": "persistentvolumeclaims", "ServiceAccount": "serviceaccounts",
    "RoleBinding": "rolebindings.rbac.authorization.k8s.io", "ResourceQuota": "resourcequotas", "LimitRange": "limitranges",
    "Notebook": "notebooks.kubeflow.org", "InferenceService": "inferenceservices.serving.kserve.io",
    "ServingRuntime": "servingruntimes.serving.kserve.io", "InferenceGraph": "inferencegraphs.serving.kserve.io",
    "LLMInferenceService": "llminferenceservices.serving.kserve.io", "LLMInferenceServiceConfig": "llminferenceserviceconfigs.serving.kserve.io",
    "DataSciencePipelinesApplication": "datasciencepipelinesapplications.datasciencepipelinesapplications.opendatahub.io",
    "FeatureStore": "featurestores.feast.dev", "MCPServer": "mcpservers.mcp.x-k8s.io", "TrustyAIService": "trustyaiservices.trustyai.opendatahub.io",
    "RayCluster": "rayclusters.ray.io", "TrainJob": "trainjobs.trainer.kubeflow.org", "TrainingRuntime": "trainingruntimes.trainer.kubeflow.org",
    "SparkApplication": "sparkapplications.sparkoperator.k8s.io", "ScheduledSparkApplication": "scheduledsparkapplications.sparkoperator.k8s.io",
    "LocalQueue": "localqueues.kueue.x-k8s.io", "ClusterQueue": "clusterqueues.kueue.x-k8s.io", "ResourceFlavor": "resourceflavors.kueue.x-k8s.io",
    "Cohort": "cohorts.kueue.x-k8s.io", "WorkloadPriorityClass": "workloadpriorityclasses.kueue.x-k8s.io",
    "ModelRegistry": "modelregistries.modelregistry.opendatahub.io", "OGXServer": "ogxservers.ogx.io",
    "EvalHub": "evalhubs.trustyai.opendatahub.io", "MLflow": "mlflows.mlflow.opendatahub.io",
    "HTTPRoute": "httproutes.gateway.networking.k8s.io", "MCPServerRegistration": "mcpserverregistrations.mcp.kuadrant.io",
    "MCPVirtualServer": "mcpvirtualservers.mcp.kuadrant.io", "RateLimitPolicy": "ratelimitpolicies.kuadrant.io",
    "TelemetryPolicy": "telemetrypolicies.extensions.kuadrant.io", "HardwareProfile": "hardwareprofiles.infrastructure.opendatahub.io",
    "ImageStream": "imagestreams.image.openshift.io", "CronJob": "cronjobs.batch", "HorizontalPodAutoscaler": "horizontalpodautoscalers.autoscaling",
    "Pod": "pods",
}


def resource(kind):
    return RESOURCE.get(kind, kind)


def oc(*args, timeout=240):
    r = subprocess.run(["oc", *args], capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout, r.stderr


class KubeError(Exception):
    """An oc call failed for a reason other than "not found", even after retrying."""


def _oc_json(args, not_found):
    # Only a real NotFound counts as absent. Anything else (API timeout, throttling, a dropped
    # connection) is retried, and if it persists it raises: it must never read as "missing".
    err = ""
    for attempt in range(3):
        try:
            rc, out, err = oc(*args)
        except subprocess.TimeoutExpired:
            rc, out, err = 1, "", "timed out"
        if rc == 0 and out.strip():
            return json.loads(out)
        if "NotFound" in err or "not found" in err.lower() or "doesn't have a resource type" in err:
            return not_found
        time.sleep(3 * (attempt + 1))
    raise KubeError(f"oc {' '.join(args[:3])}: {err.strip()[:200]}")


def get(kind, namespace, name):
    """One object as a dict, or None if it doesn't exist."""
    key = ("one", kind, namespace, name)
    if key not in _cache:
        args = ["get", resource(kind), name, "-o", "json"] + (["-n", namespace] if namespace else [])
        _cache[key] = _oc_json(args, None)
    return _cache[key]


def list_all(kind, namespace=None, selector=None):
    """All objects of a kind (cluster-wide unless namespace is given), cached per call shape."""
    key = ("list", kind, namespace, json.dumps(selector, sort_keys=True) if selector else None)
    if key not in _cache:
        args = ["get", resource(kind), "-o", "json"] + (["-n", namespace] if namespace else ["-A"])
        if selector:
            args += ["-l", ",".join(f"{k}={v}" for k, v in selector.items())]
        res = _oc_json(args, {"items": []})
        _cache[key] = res.get("items", [])
    return _cache[key]


def forget():
    _cache.clear()
