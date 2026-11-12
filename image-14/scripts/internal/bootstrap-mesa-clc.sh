#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build Mesa's host shader tools (mesa_clc, vtn_bindgen2) for the Android build.
#
# Mesa 26's Intel drivers (Iris, ANV) compile OpenCL C shaders while building.
# The Android cross build cannot build these host tools itself, so
# BoardConfig.mk selects -Dmesa-clc=system and build-images-x86_64.sh mounts
# the tools built here into /usr/local/bin of the Ubuntu 26 builder.
#
# The tools are built from the checkout's own external/mesa (with Lepton's
# patches applied), in the same Ubuntu 26 builder that later runs them, because
# they link against its LLVM 22, libclc and SPIRV-LLVM-Translator. They are
# rebuilt when the Mesa sources or the builder image change.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
CONFIG="$ROOT/.build-env"

[[ $# == 1 && ( "$1" == "--check" || "$1" == "--execute" ) ]] || {
  echo "Usage: $0 --check | --execute" >&2
  exit 2
}

ACTION="$1"
[[ -f "$CONFIG" ]] || { echo "Missing $CONFIG" >&2; exit 1; }
source "$CONFIG"

: "${LEPTON_OUTPUT_DIR:?}"
source "$ROOT/image-14/scripts/lib/workspace.sh"
lepton_workspace
TARGET="$LEPTON_AOSP_DIR"
LOG_DIR="$LEPTON_LOG_DIR"
BUILDER="lepton-builder-ubuntu26:latest"
SOURCE="$TARGET/external/mesa"
OUT="$TARGET/out/host/mesa-clc-ubuntu26"
TOOLS=(mesa_clc vtn_bindgen2)

info() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
fail() { info "[FAIL] $*"; exit 1; }

[[ "$TARGET" != / && -d "$TARGET" && ! -L "$TARGET" ]] ||
  fail "Unsafe or missing output directory"
[[ "$TARGET" != "$ROOT" && "$TARGET" != "$HOME" ]] ||
  fail "Unsafe output path"

STATE="$TARGET/.lepton-clean14-state"
[[ -f "$TARGET/.lepton-clean14-owner" &&
   -f "$STATE/sync.done" &&
   -f "$STATE/vendor.done" &&
   -f "$STATE/patches.done" &&
   ! -e "$STATE/reset.started" &&
   ! -e "$STATE/patches.started" ]] ||
  fail "Android source preparation is not complete"

[[ -f "$SOURCE/meson.build" && -f "$SOURCE/VERSION" ]] || fail "Mesa source missing: $SOURCE"
podman image exists "$BUILDER" || fail "Builder image missing: $BUILDER (see BUILDING.md, one-time setup)"

# What the tools were built from: Mesa version, commit, uncommitted (patched)
# changes and the builder image. Any difference rebuilds them.
stamp() {
  printf 'version=%s\n' "$(<"$SOURCE/VERSION")"
  printf 'commit=%s\n' "$(git -C "$SOURCE" rev-parse HEAD)"
  printf 'changes=%s\n' "$( { git -C "$SOURCE" diff HEAD; git -C "$SOURCE" ls-files --others --exclude-standard; } | sha256sum | cut -d' ' -f1)"
  printf 'builder=%s\n' "$(podman image inspect --format '{{.Id}}' "$BUILDER")"
}
WANT="$(stamp)"

info "Android checkout: $TARGET"
info "Mesa: $(<"$SOURCE/VERSION")"
info "Builder: $BUILDER"
info "Output: $OUT/bin"

current=true
for tool in "${TOOLS[@]}"; do [[ -x "$OUT/bin/$tool" ]] || current=false; done
[[ -f "$OUT/STAMP" && "$(<"$OUT/STAMP")" == "$WANT" ]] || current=false
if [[ "$current" == true ]]; then
  info "[PASS] mesa_clc and vtn_bindgen2 already built for these Mesa sources"
  exit 0
fi

if [[ "$ACTION" == "--check" ]]; then
  info "[INFO] mesa_clc and vtn_bindgen2 will be built during --execute"
  exit 0
fi

mkdir -p -- "$LOG_DIR"
LOG="$LOG_DIR/mesa-clc-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
exec > >(tee -a -- "$LOG") 2>&1
info "Persistent log: $LOG"
info "[START] Building mesa_clc and vtn_bindgen2"

rm -rf -- "$OUT"
mkdir -p -- "$OUT"

podman run --rm -i \
  --network=none \
  --userns=keep-id \
  --group-add keep-groups \
  --security-opt=label=disable \
  --hostname=lepton-build \
  -e TERM=xterm \
  -v "$SOURCE:/src:ro" \
  -v "$OUT:/out:rw" \
  -w /out \
  "$BUILDER" /bin/bash -se <<'INNER'
set -Eeuo pipefail
# Host-only build: no drivers or APIs, only the CLC compiler and its bindgen.
meson setup /out/build /src \
  --buildtype=release \
  --wrap-mode=nofallback \
  -Dmesa-clc=enabled \
  -Dinstall-mesa-clc=true \
  -Dllvm=enabled \
  -Dshared-llvm=enabled \
  -Dgallium-drivers= \
  -Dvulkan-drivers= \
  -Dplatforms= \
  -Dglx=disabled \
  -Degl=disabled \
  -Dgbm=disabled \
  -Dopengl=false \
  -Dgles1=disabled \
  -Dgles2=disabled \
  -Dvideo-codecs= \
  -Dtools= \
  -Dxmlconfig=disabled \
  -Dexpat=disabled
ninja -C /out/build src/compiler/clc/mesa_clc src/compiler/spirv/vtn_bindgen2
mkdir -p /out/bin
install -m 755 /out/build/src/compiler/clc/mesa_clc /out/bin/mesa_clc
install -m 755 /out/build/src/compiler/spirv/vtn_bindgen2 /out/bin/vtn_bindgen2
/out/bin/mesa_clc --help >/dev/null 2>&1 || /out/bin/mesa_clc -h >/dev/null 2>&1 || true
INNER

for tool in "${TOOLS[@]}"; do
  [[ -x "$OUT/bin/$tool" ]] || fail "$tool was not built"
done
printf '%s\n' "$WANT" > "$OUT/STAMP"
info "[PASS] Built $OUT/bin/mesa_clc and $OUT/bin/vtn_bindgen2"
