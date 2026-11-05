#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Bootstrap glslang 14 inside the isolated Lepton Android 14 checkout.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
IMAGE="$ROOT/image-14"
CONFIG="$ROOT/.build-env"

[[ $# == 1 && ( "$1" == "--check" || "$1" == "--execute" ) ]] || {
  echo "Usage: $0 --check | --execute" >&2
  exit 2
}

ACTION="$1"
[[ -f "$CONFIG" ]] || { echo "Missing $CONFIG" >&2; exit 1; }
source "$CONFIG"

TARGET="$(realpath -m -- "${LEPTON_OUTPUT_DIR:?}")"
LOG_DIR="$(realpath -m -- "${LEPTON_LOG_DIR:?}")"
BUILDER="lepton-builder-glslang14:latest"
GLSLANG="$TARGET/out/host/glslang14/StandAlone/glslang"

info() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
fail() { info "[FAIL] $*"; exit 1; }

[[ "$TARGET" != / && -d "$TARGET" && ! -L "$LEPTON_OUTPUT_DIR" ]] ||
  fail "Unsafe or missing output directory"

[[ "$TARGET" != "$ROOT" && "$TARGET" != "$HOME" ]] ||
  fail "Unsafe output path"

[[ "$LOG_DIR" != / && "$LOG_DIR" != "$TARGET" &&
   "$LOG_DIR" != "$TARGET/"* ]] ||
  fail "Unsafe log path"

STATE="$TARGET/.lepton-clean14-state"
[[ -f "$TARGET/.lepton-clean14-owner" &&
   -f "$STATE/sync.done" &&
   -f "$STATE/vendor.done" &&
   -f "$STATE/patches.done" &&
   ! -e "$STATE/patches.started" ]] ||
  fail "Android source preparation is not complete"

[[ -d "$TARGET/external/angle/third_party/vulkan-deps/glslang/src" ]] ||
  fail "glslang source missing"

podman image exists "$BUILDER" || fail "Builder image missing: $BUILDER"

info "Android checkout: $TARGET"
info "Builder: $BUILDER"
info "Output executable: $GLSLANG"

if [[ -x "$GLSLANG" ]]; then
  "$GLSLANG" --version | head -4
  info "[PASS] glslang already built"
  exit 0
fi

if [[ "$ACTION" == "--check" ]]; then
  info "[PASS] Ready to bootstrap glslang"
  exit 0
fi

mkdir -p -- "$LOG_DIR"
LOG="$LOG_DIR/glslang-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
exec > >(tee -a -- "$LOG") 2>&1

info "Persistent log: $LOG"
info "[START] Configuring and building glslang 14"

STARTED=$SECONDS
(
  while sleep 60; do
    info "[HEARTBEAT] glslang stage running for $(( (SECONDS-STARTED)/60 ))m"
  done
) &
HEARTBEAT_PID=$!

result=0

if podman run --rm -i \
  --network=host \
  --userns=keep-id \
  --group-add keep-groups \
  --security-opt=label=disable \
  --hostname=lepton-build \
  -e TERM=xterm \
  -v "$IMAGE:/workspace:ro" \
  -v "$TARGET:/workspace/output:rw" \
  -w /workspace/output \
  "$BUILDER" /bin/bash -se <<'INNER'
set -Eeuo pipefail

SOURCE=/workspace/output/external/angle/third_party/vulkan-deps/glslang/src
BUILD=/workspace/output/out/host/glslang14

echo "[INFO] Configuring glslang with CMake and Ninja"

cmake \
  -S "$SOURCE" \
  -B "$BUILD" \
  -G Ninja \
  -DENABLE_OPT=OFF \
  -DGLSLANG_TESTS=OFF \
  -DENABLE_SPVREMAPPER=OFF \
  -DBUILD_EXTERNAL=OFF

echo "[INFO] Building glslang-standalone"
cmake --build "$BUILD" --target glslang-standalone

test -x "$BUILD/StandAlone/glslang"
ln -sfn glslang "$BUILD/StandAlone/glslangValidator"

echo "[INFO] Checking glslang version"
"$BUILD/StandAlone/glslang" --version | head -4
INNER
then
  result=0
else
  result=$?
fi

kill "$HEARTBEAT_PID" 2>/dev/null || true
wait "$HEARTBEAT_PID" 2>/dev/null || true

if (( result != 0 )); then
  fail "glslang bootstrap failed (exit $result); log: $LOG"
fi

[[ -x "$GLSLANG" ]] || fail "glslang executable not found"

info "[PASS] glslang 14 bootstrap completed"
info "Log: $LOG"
