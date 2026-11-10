#!/usr/bin/env bash
# Render the population from {profile, seed} (PLAN.md §6). Needs RHOAI installed, because the
# workbench images come from the ImageStreams this cluster ships. Writes generated/$POP/.
cd "$(dirname "$0")/../.." && . lib/common.sh

log "workbench images (tag $WORKBENCH_IMAGE_TAG; accelerator builds only when GPUs exist)"
python3 tools/notebook_images.py --tag "$WORKBENCH_IMAGE_TAG" || die "notebook_images"
log "OGX base config from this release's OGX image"
bash tools/ogx_base_config.sh "$GEN_DIR/ogx-base-config.yaml" || die "OGX base config"
log "shipped names the customised variants reference (presets, templates, older image tags)"
python3 tools/cluster_refs.py "$GEN_DIR/cluster-refs.json" || die "cluster refs"
log "population $POP, seed $SEED"
python3 tools/generate.py --profile "$PROFILE" --seed "$SEED" ${MODELS:+--models "$MODELS"} ${RUNNING_MODELS:+--running-models "$RUNNING_MODELS"} \
  --out "$GEN_DIR" --images "$GEN_DIR/notebook-images.json" --ogx-config "$GEN_DIR/ogx-base-config.yaml" \
  --refs "$GEN_DIR/cluster-refs.json" || die "generate"
[ -f "$GEN_DIR/$POP/users.json" ] || die "expected $GEN_DIR/$POP/users.json"
log "phase 45 done"
