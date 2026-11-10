#!/usr/bin/env python3
"""Seeded generator for the lived-in population (spike version of PLAN.md §6).

Usage: generate.py --profile small|medium [--seed 42] [--out generated]

The same seed always gives the same cluster. Profiles are NOT subsets of each other,
because team assignment depends on the team count. To compare UI timings at different
sizes, apply one profile's shards in stages.

Writes:
  <out>/users.json               every user, with team, persona, tier and password
  <out>/shards/NNN.yaml          namespaces and workloads, ~25 namespaces per shard
  <out>/expected-inventory.json  every object created, with its expected state
"""
import argparse
import hashlib
import json
import os
import random

import_yaml = None

PROFILES = {
    "small": dict(users=50, teams=8, wb_total=60, wb_running=5, sv_total=30, sv_running=4, dspas=2,
                  queued_teams=2, feast=1, mcp=1, trusty=1, spark=1),
    "medium": dict(users=300, teams=30, wb_total=350, wb_running=15, sv_total=150, sv_running=8, dspas=6,
                   queued_teams=6, feast=3, mcp=3, trusty=2, spark=3),
}
PERSONA_WEIGHTS = [("data-scientist", 55), ("ml-engineer", 25), ("viewer", 15), ("team-lead", 5)]
TIER_WEIGHTS = [("maas-free", 50), ("maas-standard", 35), ("maas-premium", 15)]
DASHBOARD_NS_LABEL = {"opendatahub.io/dashboard": "true"}
MANAGED = {"loaded-rhoai.io/managed": "true"}
HW = {"opendatahub.io/hardware-profile-name": "default-profile",
      "opendatahub.io/hardware-profile-namespace": "redhat-ods-applications"}


def rng_for(seed, *key):
    """A stable RNG per entity, so adding users never changes existing ones."""
    h = hashlib.sha256(f"{seed}:{':'.join(map(str, key))}".encode()).hexdigest()
    return random.Random(int(h[:16], 16))


def pick(rng, weighted):
    return rng.choices([w[0] for w in weighted], weights=[w[1] for w in weighted])[0]


def stable_sample(seed, label, n):
    """Indexes 0..n-1 in a stable shuffled order, used to choose what runs."""
    return sorted(range(n), key=lambda i: hashlib.sha256(f"{seed}:{label}:{i}".encode()).hexdigest())


class Pop:
    def __init__(self, cfg, seed, images):
        self.cfg, self.seed, self.images = cfg, seed, images
        self.docs = {}      # namespace -> list of manifests
        self.inventory = []

    def add(self, ns_key, doc, state="static", owner=None):
        self.docs.setdefault(ns_key, []).append(doc)
        self.inventory.append({"apiVersion": doc["apiVersion"], "kind": doc["kind"],
                               "namespace": doc["metadata"].get("namespace"),
                               "name": doc["metadata"]["name"], "state": state, "owner": owner})


def make_users(cfg, seed):
    users = {}
    for i in range(1, cfg["users"] + 1):
        name = f"user{i:04d}"
        r = rng_for(seed, "user", name)
        team = f"team-{(i - 1) % cfg['teams'] + 1:02d}"
        users[name] = {
            "team": team,
            "persona": pick(r, PERSONA_WEIGHTS),
            "tier": pick(r, TIER_WEIGHTS),
            "password": hashlib.sha256(f"{seed}:pw:{name}".encode()).hexdigest()[:20],
            "sandboxes": r.choices([0, 1, 2, 3], weights=[20, 55, 20, 5])[0],
        }
    # Every team has a lead who owns the team project; the first 5 users are admins.
    leads = set()
    for name, u in users.items():
        if u["team"] not in leads:
            u["persona"] = "team-lead"
            leads.add(u["team"])
    for i in range(1, 6):
        users[f"user{i:04d}"]["admin"] = True
    return users


def namespace(name, display, team, owner, dashboard=True, extra=None):
    labels = dict(MANAGED, **{"loaded-rhoai.io/team": team})
    if dashboard:
        labels.update(DASHBOARD_NS_LABEL)
    labels.update(extra or {})
    ann = {"openshift.io/display-name": display, "openshift.io/description": f"Generated project for {team}"}
    if owner:
        ann["openshift.io/requester"] = owner
    return {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": name, "labels": labels, "annotations": ann}}


def rolebinding(ns, name, role, kind, subject):
    return {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "RoleBinding",
            "metadata": {"name": name, "namespace": ns},
            "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": role},
            "subjects": [{"apiGroup": "rbac.authorization.k8s.io", "kind": kind, "name": subject}]}


def connection(ns):
    return {"apiVersion": "v1", "kind": "Secret",
            "metadata": {"name": "shared-minio", "namespace": ns, "labels": DASHBOARD_NS_LABEL,
                         "annotations": {"opendatahub.io/connection-type-ref": "s3",
                                         "openshift.io/display-name": "Shared MinIO"}},
            "stringData": {"AWS_ACCESS_KEY_ID": "lrminio", "AWS_SECRET_ACCESS_KEY": "lrminio-spike-only",
                           "AWS_S3_ENDPOINT": "http://minio.lr-infra.svc:9000", "AWS_S3_BUCKET": "lr-models",
                           "AWS_DEFAULT_REGION": "us-east-1"}}


def governance(ns, r):
    docs = []
    if r.random() < 0.33:
        docs.append({"apiVersion": "v1", "kind": "ResourceQuota", "metadata": {"name": "project-quota", "namespace": ns},
                     "spec": {"hard": {"requests.cpu": "20", "requests.memory": "60Gi", "persistentvolumeclaims": "30"}}})
        docs.append({"apiVersion": "v1", "kind": "LimitRange", "metadata": {"name": "project-limits", "namespace": ns},
                     "spec": {"limits": [{"type": "Container", "defaultRequest": {"cpu": "50m", "memory": "64Mi"},
                                          "default": {"cpu": "2", "memory": "4Gi"}}]}})
    return docs


def notebook(ns, name, owner, image_tag, image_ref, running, r, seed=42):
    # PVC size has its own random stream, so changing the image list can't change the size of an
    # existing (and immutable) PVC.
    size = rng_for(seed, "wb-size", ns, name).choice(["1Gi", "2Gi", "5Gi"])
    pvc = {"apiVersion": "v1", "kind": "PersistentVolumeClaim",
           "metadata": {"name": name, "namespace": ns, "labels": DASHBOARD_NS_LABEL},
           "spec": {"accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": size}}}}
    ann = dict(HW, **{"openshift.io/display-name": name, "notebooks.opendatahub.io/inject-auth": "true",
                      "notebooks.opendatahub.io/last-image-selection": image_tag, "opendatahub.io/username": owner})
    if not running:
        ann["kubeflow-resource-stopped"] = "2026-10-%02dT09:00:00Z" % r.randint(1, 28)
    base = f"/notebook/{ns}/{name}"
    nb = {"apiVersion": "kubeflow.org/v1", "kind": "Notebook",
          "metadata": {"name": name, "namespace": ns, "annotations": ann,
                       "labels": {"app": name, "opendatahub.io/dashboard": "true", "opendatahub.io/odh-managed": "true"}},
          "spec": {"template": {"spec": {
              "enableServiceLinks": False,
              "containers": [{
                  "name": name, "image": image_ref, "workingDir": "/opt/app-root/src",
                  "env": [{"name": "NOTEBOOK_ARGS", "value": f"--ServerApp.port=8888 --ServerApp.token='' --ServerApp.password='' --ServerApp.base_url={base} --ServerApp.quit_button=False"},
                          {"name": "JUPYTER_IMAGE", "value": image_ref}],
                  "ports": [{"name": "notebook-port", "containerPort": 8888, "protocol": "TCP"}],
                  "resources": {"requests": {"cpu": "100m", "memory": "512Mi"}, "limits": {"cpu": "1", "memory": "2Gi"}},
                  "volumeMounts": [{"name": name, "mountPath": "/opt/app-root/src"}],
                  "readinessProbe": {"httpGet": {"path": f"{base}/api", "port": "notebook-port"}, "initialDelaySeconds": 10, "periodSeconds": 5},
              }],
              "volumes": [{"name": name, "persistentVolumeClaim": {"claimName": name}}]}}}}
    return pvc, nb


def serving_runtime(ns):
    return {"apiVersion": "serving.kserve.io/v1alpha1", "kind": "ServingRuntime",
            "metadata": {"name": "lr-sim", "namespace": ns, "labels": DASHBOARD_NS_LABEL,
                         "annotations": {"openshift.io/display-name": "LR simulator runtime", "opendatahub.io/apiProtocol": "REST"}},
            "spec": {"supportedModelFormats": [{"name": "sim", "autoSelect": True}], "multiModel": False,
                     "containers": [{"name": "kserve-container", "image": "ghcr.io/llm-d/llm-d-inference-sim:v0.7.1",
                                     "command": ["/app/llm-d-inference-sim"], "args": ["--port", "8080", "--model", "sim", "--mode", "random"],
                                     "ports": [{"containerPort": 8080, "protocol": "TCP"}],
                                     "resources": {"requests": {"cpu": "50m", "memory": "128Mi"}, "limits": {"cpu": "500m", "memory": "256Mi"}}}]}}


def isvc(ns, name, running):
    ann = {"serving.kserve.io/deploymentMode": "RawDeployment", "openshift.io/display-name": name}
    if not running:
        ann["serving.kserve.io/stop"] = "true"
    return {"apiVersion": "serving.kserve.io/v1beta1", "kind": "InferenceService",
            "metadata": {"name": name, "namespace": ns, "labels": DASHBOARD_NS_LABEL, "annotations": ann},
            "spec": {"predictor": {"minReplicas": 1, "maxReplicas": 1,
                                   "model": {"modelFormat": {"name": "sim"}, "runtime": "lr-sim"}}}}


def dspa(ns):
    return [
        {"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "dspa-s3", "namespace": ns},
         "stringData": {"accesskey": "lrminio", "secretkey": "lrminio-spike-only"}},
        {"apiVersion": "datasciencepipelinesapplications.opendatahub.io/v1", "kind": "DataSciencePipelinesApplication",
         "metadata": {"name": "dspa", "namespace": ns},
         "spec": {"dspVersion": "v2", "apiServer": {"enableSamplePipeline": True},
                  "database": {"mariaDB": {"deploy": True, "pipelineDBName": "mlpipeline", "pvcSize": "5Gi", "username": "mlpipeline"}},
                  "objectStorage": {"externalStorage": {"host": "minio.lr-infra.svc", "port": "9000", "scheme": "http",
                                                        "bucket": f"dspa-{ns}", "region": "us-east-1",
                                                        "s3CredentialsSecret": {"accessKey": "accesskey", "secretKey": "secretkey", "secretName": "dspa-s3"}}}}},
    ]


RAY_IMAGE = "quay.io/modh/ray@sha256:0d715f92570a2997381b7cafc0e224cfa25323f18b9545acfd23bc2b71576d06"


def raycluster(ns, name, queue):
    def c(n):
        return {"name": n, "image": RAY_IMAGE, "resources": {"requests": {"cpu": "1", "memory": "2Gi"}, "limits": {"cpu": "1", "memory": "2Gi"}}}
    return {"apiVersion": "ray.io/v1", "kind": "RayCluster",
            "metadata": {"name": name, "namespace": ns, "labels": {"kueue.x-k8s.io/queue-name": queue}},
            "spec": {"rayVersion": "2.47.1", "suspend": True,
                     "headGroupSpec": {"rayStartParams": {"dashboard-host": "0.0.0.0"}, "template": {"spec": {"containers": [c("ray-head")]}}},
                     "workerGroupSpecs": [{"groupName": "small", "replicas": 1, "minReplicas": 1, "maxReplicas": 1, "rayStartParams": {},
                                           "template": {"spec": {"containers": [c("ray-worker")]}}}]}}


def trainjob(ns, name, queue):
    return {"apiVersion": "trainer.kubeflow.org/v1alpha1", "kind": "TrainJob",
            "metadata": {"name": name, "namespace": ns, "labels": {"kueue.x-k8s.io/queue-name": queue}},
            "spec": {"runtimeRef": {"name": "torch-distributed-cpu"},
                     "trainer": {"numNodes": 1,
                                 "command": ["python", "-c", "import torch; x=torch.ones(4,4); print('sum', x.sum().item())"],
                                 "resourcesPerNode": {"requests": {"cpu": "500m", "memory": "1Gi"}, "limits": {"cpu": "1", "memory": "2Gi"}}}}}


def spark_pi(ns):
    return [
        {"apiVersion": "v1", "kind": "ServiceAccount", "metadata": {"name": "spark", "namespace": ns}},
        rolebinding_sa(ns),
        {"apiVersion": "sparkoperator.k8s.io/v1beta2", "kind": "SparkApplication", "metadata": {"name": "spark-pi", "namespace": ns},
         "spec": {"type": "Scala", "mode": "cluster", "sparkVersion": "4.0.1", "image": "docker.io/library/spark:4.0.1",
                  "mainClass": "org.apache.spark.examples.SparkPi",
                  "mainApplicationFile": "local:///opt/spark/examples/jars/spark-examples.jar", "arguments": ["100"],
                  "sparkConf": {"spark.jars.ivy": "/tmp/.ivy2", "spark.kubernetes.driverEnv.HOME": "/tmp", "spark.executorEnv.HOME": "/tmp",
                                "spark.kubernetes.driver.volumes.emptyDir.work.mount.path": "/opt/spark/work-dir",
                                "spark.kubernetes.executor.volumes.emptyDir.work.mount.path": "/opt/spark/work-dir"},
                  "driver": {"cores": 1, "memory": "1g", "serviceAccount": "spark"},
                  "executor": {"cores": 1, "instances": 1, "memory": "1g"}}},
    ]


def rolebinding_sa(ns):
    return {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "RoleBinding", "metadata": {"name": "spark-edit", "namespace": ns},
            "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "edit"},
            "subjects": [{"kind": "ServiceAccount", "name": "spark", "namespace": ns}]}


def build(cfg, seed, images):
    pop = Pop(cfg, seed, images)
    users = make_users(cfg, seed)
    teams = sorted({u["team"] for u in users.values()})
    lead = {u["team"]: n for n, u in reversed(list(users.items())) if u["persona"] == "team-lead"}

    # Team projects
    project_slots = []  # (namespace, owner) that can hold workbenches and models
    for t in teams:
        ns = f"lr-{t}"
        pop.add(ns, namespace(ns, f"Team {t}", t, lead[t]))
        pop.add(ns, rolebinding(ns, "lead-admin", "admin", "User", lead[t]))
        pop.add(ns, rolebinding(ns, "members-edit", "edit", "Group", t))
        pop.add(ns, connection(ns))
        for d in governance(ns, rng_for(seed, "gov", ns)):
            pop.add(ns, d)
        project_slots.append((ns, lead[t]))

    # Personal sandboxes
    for name, u in users.items():
        for s in range(u["sandboxes"]):
            ns = f"lr-{name}-{s + 1}"
            r = rng_for(seed, "ns", ns)
            # About 5% of namespaces are not dashboard projects: noise RHOAI should ignore.
            dash = r.random() >= 0.05
            pop.add(ns, namespace(ns, f"{name} sandbox {s + 1}", u["team"], name, dashboard=dash))
            pop.add(ns, rolebinding(ns, "owner-admin", "admin", "User", name))
            if dash:
                pop.add(ns, connection(ns))
                for d in governance(ns, r):
                    pop.add(ns, d)
                project_slots.append((ns, name))

    # Workbenches: spread over projects, a stable subset running
    running = set(stable_sample(seed, "wb", cfg["wb_total"])[:cfg["wb_running"]])
    tags = list(images)
    for i in range(cfg["wb_total"]):
        ns, owner = project_slots[i % len(project_slots)]
        r = rng_for(seed, "wb", i)
        tag = r.choice(tags)
        pvc, nb = notebook(ns, f"wb-{i:04d}", owner, tag, images[tag], i in running, r, seed)
        pop.add(ns, pvc, state="bound" if i in running else "unbound-ok", owner=owner)
        pop.add(ns, nb, state="running" if i in running else "stopped", owner=owner)

    # Models: a runtime wherever a model lives. The first sv_running are running, so a smaller
    # model count is always a prefix of a larger one and the two can be compared directly.
    running = set(range(cfg["sv_running"]))
    with_runtime = set()
    for i in range(cfg["sv_total"]):
        ns, owner = project_slots[(i * 3) % len(project_slots)]
        if ns not in with_runtime:
            pop.add(ns, serving_runtime(ns))
            with_runtime.add(ns)
        pop.add(ns, isvc(ns, f"model-{i:04d}", i in running), state="running" if i in running else "stopped", owner=owner)

    # Pipelines
    buckets = []
    for t in teams[:cfg["dspas"]]:
        ns = f"lr-{t}"
        for d in dspa(ns):
            pop.add(ns, d, state="ready" if d["kind"] != "Secret" else "static")
        buckets.append(f"dspa-{ns}")

    # Kueue-managed work lives in its own namespaces: the managed label pulls in every pod (§18)
    pop.add("_cluster", {"apiVersion": "kueue.x-k8s.io/v1beta2", "kind": "ResourceFlavor", "metadata": {"name": "default-flavor"}})
    for t in teams[:cfg["queued_teams"]]:
        ns = f"lr-{t}-batch"
        pop.add(ns, namespace(ns, f"Team {t} batch", t, lead[t], extra={"kueue.openshift.io/managed": "true"}))
        pop.add(ns, rolebinding(ns, "members-edit", "edit", "Group", t))
        pop.add("_cluster", {"apiVersion": "kueue.x-k8s.io/v1beta2", "kind": "ClusterQueue", "metadata": {"name": f"cq-{t}"},
                             "spec": {"namespaceSelector": {"matchLabels": {"loaded-rhoai.io/team": t}},
                                      "resourceGroups": [{"coveredResources": ["cpu", "memory"],
                                                          "flavors": [{"name": "default-flavor", "resources": [
                                                              {"name": "cpu", "nominalQuota": "4"}, {"name": "memory", "nominalQuota": "8Gi"}]}]}]}})
        pop.add(ns, {"apiVersion": "kueue.x-k8s.io/v1beta2", "kind": "LocalQueue", "metadata": {"name": "team-queue", "namespace": ns},
                     "spec": {"clusterQueue": f"cq-{t}"}})
        # A suspended RayCluster on an open queue is admitted and started by Kueue. Idle clusters
        # sit on a held queue instead, so they stay suspended (FINDINGS.md).
        pop.add("_cluster", {"apiVersion": "kueue.x-k8s.io/v1beta2", "kind": "ClusterQueue", "metadata": {"name": f"cq-{t}-idle"},
                             "spec": {"stopPolicy": "Hold", "namespaceSelector": {"matchLabels": {"loaded-rhoai.io/team": t}},
                                      "resourceGroups": [{"coveredResources": ["cpu", "memory"],
                                                          "flavors": [{"name": "default-flavor", "resources": [
                                                              {"name": "cpu", "nominalQuota": "4"}, {"name": "memory", "nominalQuota": "8Gi"}]}]}]}})
        pop.add(ns, {"apiVersion": "kueue.x-k8s.io/v1beta2", "kind": "LocalQueue", "metadata": {"name": "idle-queue", "namespace": ns},
                     "spec": {"clusterQueue": f"cq-{t}-idle"}})
        pop.add(ns, raycluster(ns, "ray-idle", "idle-queue"), state="suspended")
        pop.add(ns, trainjob(ns, "train-history", "team-queue"), state="completed")

    # Other components, on later teams so they don't stack on the DSPA projects
    tail = teams[cfg["dspas"]:] or teams
    for i in range(cfg["feast"]):
        ns = f"lr-{tail[i % len(tail)]}"
        # The name must be unique cluster-wide: the Feast operator names a ClusterRoleBinding from it
        # alone, so same-named stores in different namespaces fight over one binding (FINDINGS.md).
        pop.add("_after_ca", {"apiVersion": "feast.dev/v1", "kind": "FeatureStore", "metadata": {"name": f"features-{ns}", "namespace": ns},
                     "spec": {"feastProject": ns.replace("-", "_")}}, state="ready")
    for i in range(cfg["mcp"]):
        ns = f"lr-{tail[(i + 1) % len(tail)]}"
        pop.add(ns, {"apiVersion": "mcp.x-k8s.io/v1alpha1", "kind": "MCPServer", "metadata": {"name": "openshift-mcp", "namespace": ns},
                     "spec": {"source": {"type": "ContainerImage", "containerImage": {"ref": "registry.redhat.io/openshift-mcp-tech-preview/openshift-mcp-server-rhel9:0.4"}},
                              "config": {"port": 8080, "path": "/mcp", "arguments": ["--port", "8080", "--read-only"]},
                              "runtime": {"replicas": 1, "resources": {"requests": {"cpu": "50m", "memory": "128Mi"}, "limits": {"cpu": "300m", "memory": "256Mi"}}}}}, state="ready")
    for i in range(cfg["trusty"]):
        ns = f"lr-{tail[(i + 2) % len(tail)]}"
        pop.add("_after_ca", {"apiVersion": "trustyai.opendatahub.io/v1", "kind": "TrustyAIService", "metadata": {"name": "trustyai", "namespace": ns},
                     "spec": {"storage": {"format": "PVC", "folder": "/inputs", "size": "1Gi"}, "data": {"filename": "data.csv", "format": "CSV"},
                              "metrics": {"schedule": "5s"}}}, state="ready")
    for i in range(cfg["spark"]):
        ns = f"lr-{tail[(i + 3) % len(tail)]}"
        for d in spark_pi(ns):
            pop.add(ns, d, state="completed" if d["kind"] == "SparkApplication" else "static")
    pop.add("_after_ca", {"apiVersion": "modelregistry.opendatahub.io/v1beta1", "kind": "ModelRegistry",
                          "metadata": {"name": "lr-registry", "namespace": "rhoai-model-registries"},
                          "spec": {"grpc": {}, "rest": {}, "kubeRBACProxy": {}, "postgres": {"generateDeployment": True}}}, state="ready")
    return pop, users, buckets


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile", choices=PROFILES, required=True)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out", default="generated")
    ap.add_argument("--images", default="generated/notebook-images.json", help="{'stream:tag': 'image reference'}")
    ap.add_argument("--models", type=int, help="override the number of InferenceServices")
    ap.add_argument("--running-models", type=int, help="override how many of them run")
    a = ap.parse_args()
    images = json.load(open(a.images))
    cfg = dict(PROFILES[a.profile])
    if a.models is not None:
        cfg["sv_total"] = a.models
    if a.running_models is not None:
        cfg["sv_running"] = a.running_models
    pop, users, buckets = build(cfg, a.seed, images)

    name = a.profile + (f"-m{cfg['sv_total']}" if a.models is not None else "")
    out = os.path.join(a.out, name)
    os.makedirs(os.path.join(out, "shards"), exist_ok=True)
    for f in os.listdir(os.path.join(out, "shards")):
        os.remove(os.path.join(out, "shards", f))
    with open(os.path.join(out, "users.json"), "w") as f:
        json.dump(users, f, indent=1)
    with open(os.path.join(out, "expected-inventory.json"), "w") as f:
        json.dump(pop.inventory, f, indent=0)
    with open(os.path.join(out, "buckets.json"), "w") as f:
        json.dump(buckets, f)

    # JSON is valid YAML, and needs no third-party module. Cluster-scoped objects go first.
    with open(os.path.join(out, "shards", "000-cluster.json"), "w") as f:
        json.dump({"apiVersion": "v1", "kind": "List", "items": pop.docs.pop("_cluster", [])}, f)
    # Workloads that mount the trusted CA bundle with subPath go in a last shard. apply_shards.sh waits
    # until each of their namespaces has ca-bundle.crt before applying it (FINDINGS.md).
    after_ca = pop.docs.pop("_after_ca", [])
    with open(os.path.join(out, "shards", "099-after-ca.json"), "w") as f:
        json.dump({"apiVersion": "v1", "kind": "List", "items": after_ca}, f)
    keys = sorted(pop.docs)
    for s in range(0, len(keys), 25):
        items = [d for k in keys[s:s + 25] for d in pop.docs[k]]
        items.sort(key=lambda d: 0 if d["kind"] == "Namespace" else 1)
        with open(os.path.join(out, "shards", f"{s // 25 + 1:03d}.json"), "w") as f:
            json.dump({"apiVersion": "v1", "kind": "List", "items": items}, f)

    kinds = {}
    for o in pop.inventory:
        kinds[o["kind"]] = kinds.get(o["kind"], 0) + 1
    dash = sum(1 for k in keys if any(d["kind"] == "Namespace" and "opendatahub.io/dashboard" in d["metadata"]["labels"] for d in pop.docs[k]))
    print(f"out={out} models={cfg['sv_total']} running={cfg['sv_running']} profile={a.profile} seed={a.seed} users={len(users)} namespaces={len(keys)} dashboard_projects={dash} objects={len(pop.inventory)}")
    print(json.dumps(kinds, indent=0, sort_keys=True))


if __name__ == "__main__":
    main()
