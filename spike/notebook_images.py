#!/usr/bin/env python3
"""Choose workbench images for the generator from what this cluster ships.

Without GPUs, CUDA and ROCm builds are left out: they're large (the CUDA PyTorch image is 11.7 GB)
and can't use an accelerator anyway. Writes generated/notebook-images.json as {"stream:tag": "image"}.
Usage: notebook_images.py [--tag 3.5]
"""
import argparse
import json
import subprocess

ap = argparse.ArgumentParser()
ap.add_argument("--tag", default="3.5")
a = ap.parse_args()


def oc_json(*args):
    return json.loads(subprocess.run(["oc", *args, "-o", "json"], capture_output=True, text=True, check=True).stdout)


gpus = sum(int(n["status"].get("allocatable", {}).get("nvidia.com/gpu", "0")) + int(n["status"].get("allocatable", {}).get("amd.com/gpu", "0"))
           for n in oc_json("get", "nodes")["items"])
streams = oc_json("get", "imagestream", "-n", "redhat-ods-applications", "-l", "opendatahub.io/notebook-image=true")["items"]
chosen, skipped = {}, []
for s in streams:
    name = s["metadata"]["name"]
    if name.startswith("training-hub"):  # trainer runtimes, not workbenches
        continue
    tag = next((t for t in s["status"].get("tags", []) if t["tag"] == a.tag and t.get("items")), None)
    if not tag:
        continue
    ref = tag["items"][0]["dockerImageReference"]
    accelerated = "-cuda-" in ref or "-rocm-" in ref
    if accelerated and gpus == 0:
        skipped.append(name)
        continue
    chosen[f"{name}:{a.tag}"] = ref
json.dump(chosen, open("generated/notebook-images.json", "w"), indent=1)
print(f"gpus={gpus} chosen={sorted(chosen)}")
print(f"skipped (accelerator builds): {sorted(skipped)}")
