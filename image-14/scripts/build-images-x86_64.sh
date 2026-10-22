#!/usr/bin/env bash
set -euo pipefail

# Run from the image-14 source directory.
#
# Place the Mesa patch at:
#   image-14/patches/0001-mesa-android-sdk34-link-libzstd.patch
#
# Usage:
#   scripts/build-images-x86_64.sh /path/to/lepton-output

if [[ $# -ne 1 ]]; then
    echo "usage: $0 /path/to/lepton-output" >&2
    exit 2
fi

LEPTON_OUTPUT_DIR="$(readlink -f "$1")"
export LEPTON_OUTPUT_DIR

if [[ ! -x "${LEPTON_OUTPUT_DIR}/out/host/glslang14/StandAlone/glslang" ]]; then
    echo "glslang 14 host tool is missing; run scripts/bootstrap-glslang14.sh first" >&2
    exit 1
fi

./.buildscripts/container.sh '
set -e

# Mesa Android glue prepends /usr/bin to PATH, so override the old Ubuntu
# validator inside this ephemeral builder container only.
ln -sf \
  /workspace/output/out/host/glslang14/StandAlone/glslang \
  /usr/bin/glslangValidator

./.buildscripts/copy_vendored_projects.sh

apply_patch() {
    local tree="$1"
    local patch="$2"
    local name="$3"

    if [[ ! -f "$patch" ]]; then
        echo "Missing $patch" >&2
        exit 1
    fi

    cd "$tree"
    if git apply --reverse --check "$patch" >/dev/null 2>&1; then
        echo "$name already applied"
    else
        git apply "$patch"
        echo "Applied $name"
    fi
}

apply_patch /workspace/output/external/mesa     /workspace/patches/0001-mesa-android-sdk34-link-libzstd.patch     "Mesa libzstd patch"

apply_patch /workspace/output/external/minigbm     /workspace/patches/0004-minigbm-gbm-mesa-driver.patch     "minigbm GBM/Mesa backend"
apply_patch /workspace/output/frameworks/native /workspace/patches/0007-eventhub-preserve-evdev-axes.patch "EventHub native evdev axis metadata"

cd /workspace/output
taskset -c 0-5 bash -c "
  source build/envsetup.sh >/dev/null &&
  lunch aosp_lepton_x86_64-ap2a-userdebug >/dev/null &&
  m -j6 systemimage vendorimage
"
'
