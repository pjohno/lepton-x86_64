#!/usr/bin/env bash
set -euo pipefail

# Run from the image-14 source directory.
# Usage:
#   scripts/bootstrap-glslang14.sh /path/to/lepton-output

if [[ $# -ne 1 ]]; then
    echo "usage: $0 /path/to/lepton-output" >&2
    exit 2
fi

LEPTON_OUTPUT_DIR="$(readlink -f "$1")"
export LEPTON_OUTPUT_DIR

./.buildscripts/container.sh '
set -e
apt-get update >/dev/null
apt-get install -y cmake >/dev/null

cmake \
  -S /workspace/output/external/angle/third_party/vulkan-deps/glslang/src \
  -B /workspace/output/out/host/glslang14 \
  -G Ninja \
  -DENABLE_OPT=OFF \
  -DGLSLANG_TESTS=OFF \
  -DENABLE_SPVREMAPPER=OFF \
  -DBUILD_EXTERNAL=OFF

cmake --build /workspace/output/out/host/glslang14 --target glslang-standalone

ln -sf glslang \
  /workspace/output/out/host/glslang14/StandAlone/glslangValidator

/workspace/output/out/host/glslang14/StandAlone/glslang --version | head -4
'
