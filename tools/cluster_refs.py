#!/usr/bin/env python3
"""Collect what the customised variants copy or reference from the installed release (PLAN.md §6
"Pinned references are deliberate variants"). Names like v3-5-2-kserve-config-llm-template change
with every release, so they're read from the cluster, never hard-coded.
Usage: cluster_refs.py <out.json>"""
import json
import subprocess
import sys

APPS = "redhat-ods-applications"


def oc_json(*args):
    r = subprocess.run(["oc", *args, "-o", "json"], capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"oc {' '.join(args)}: {r.stderr.strip()[:200]}")
    return json.loads(r.stdout)


def clean(obj):
    md = obj["metadata"]
    obj["metadata"] = {k: v for k, v in md.items() if k in ("name", "namespace", "labels", "annotations")}
    obj["metadata"].get("annotations", {}).pop("kubectl.kubernetes.io/last-applied-configuration", None)
    obj.pop("status", None)
    return obj


refs = {}
presets = [c["metadata"]["name"] for c in oc_json("get", "llminferenceserviceconfig", "-n", APPS)["items"]]
refs["llmTemplatePreset"] = next(n for n in presets if n.endswith("-kserve-config-llm-template"))
refs["llmPresets"] = sorted(presets)

# The x86 vLLM CPU runtime (vllm-cpu-runtime-template is the ppc64le/s390x build). Its image is also
# what the real-vLLM LLMInferenceService runs, since the release's LLM presets are GPU builds only.
tmpl = oc_json("get", "template", "vllm-cpu-x86-runtime-template", "-n", APPS)
refs["runtimeTemplate"] = {"name": "vllm-cpu-x86-runtime-template", "object": clean(tmpl["objects"][0])}
refs["vllmCpuImage"] = refs["runtimeTemplate"]["object"]["spec"]["containers"][0]["image"]

refs["trainingRuntime"] = {"name": "torch-distributed-cpu", "spec": oc_json("get", "clustertrainingruntime", "torch-distributed-cpu")["spec"]}

s3 = clean(oc_json("get", "configmap", "s3", "-n", APPS))
refs["connectionTypeS3"] = s3

# An older shipped workbench image (n-1): the newest tag that isn't the release's own.
ist = oc_json("get", "imagestream", "s2i-minimal-notebook", "-n", APPS)
tags = {t["tag"]: t["items"][0]["dockerImageReference"] for t in ist["status"].get("tags", []) if t.get("items")}
older = sorted(t for t in tags if not t.startswith("3.5"))
refs["olderNotebook"] = {"stream": "s2i-minimal-notebook", "tag": older[-1], "image": tags[older[-1]]} if older else None
refs["currentNotebook"] = {"stream": "s2i-minimal-notebook", "tag": "3.5", "image": tags.get("3.5")}

hp = oc_json("get", "hardwareprofile", "default-profile", "-n", APPS)
refs["hardwareProfile"] = {"apiVersion": hp["apiVersion"], "spec": hp["spec"]}

json.dump(refs, open(sys.argv[1], "w"), indent=1)
print(f"  refs: preset={refs['llmTemplatePreset']} vllm-cpu={refs['vllmCpuImage'].split('@')[-1][:19]} older-notebook={refs['olderNotebook'] and refs['olderNotebook']['tag']} hw={hp['apiVersion']}")
