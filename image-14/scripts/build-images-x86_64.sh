#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Reproducible Android 14 x86_64 system/vendor image build.
set -Eeuo pipefail

usage() {
  cat >&2 <<'HELP'
Usage: bash image-14/scripts/build-images-x86_64.sh --check | --execute | --repair
Compiles system.img and vendor.img in the prepared checkout (workspace aosp/),
copies them to the workspace's images/ and packages them as rootfs/, the
input of make-deck-bundle-x86_64.sh. Both are replaced on every build.

A stopped or failed build continues where it stopped when run again. If a
build was cut off (power cut, crash), --execute first deletes the files that
build left damaged. --repair does the same for the whole output folder; use it
only when --execute will not complete, e.g. it keeps failing with "neither
ET_REL nor LLVM bitcode" or "file truncated". It errs on the side of caution
and also deletes some good files, which the next --execute rebuilds quickly.
HELP
}

[[ $# == 1 ]] || { usage; exit 2; }
ACTION="$1"
[[ "$ACTION" == "--check" || "$ACTION" == "--execute" || "$ACTION" == "--repair" ]] || {
  usage
  exit 2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CONFIG="$ROOT/.build-env"

[[ -f "$CONFIG" ]] || {
  echo "Missing $CONFIG" >&2
  exit 1
}

source "$CONFIG"

: "${LEPTON_OUTPUT_DIR:?Missing LEPTON_OUTPUT_DIR}"
source "$ROOT/image-14/scripts/lib/workspace.sh"
lepton_workspace
: "${LEPTON_BUILD_TARGET:?Missing LEPTON_BUILD_TARGET}"
: "${LEPTON_BUILD_JOBS:?Missing LEPTON_BUILD_JOBS}"
: "${LEPTON_MIN_FREE_GIB:?Missing LEPTON_MIN_FREE_GIB}"

[[ "$LEPTON_BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] || {
  echo "Invalid LEPTON_BUILD_JOBS" >&2
  exit 1
}

[[ "$LEPTON_MIN_FREE_GIB" =~ ^[0-9]+$ ]] || {
  echo "Invalid LEPTON_MIN_FREE_GIB" >&2
  exit 1
}

[[ "$LEPTON_BUILD_TARGET" == "aosp_lepton_x86_64-ap2a-userdebug" ]] || {
  echo "Unexpected Android build target" >&2
  exit 1
}

info() {
  printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"
}

fail() {
  info "[FAIL] $*"
  exit 1
}

[[ ! -L "$LEPTON_OUTPUT_DIR" && ! -L "$LEPTON_AOSP_DIR" ]] ||
  fail "Workspace and checkout paths must not be symlinks"
[[ -d "$LEPTON_AOSP_DIR" ]] ||
  fail "No Android checkout at $LEPTON_AOSP_DIR (run prepare-x86_64.sh first)"

TARGET="$(realpath -e -- "$LEPTON_AOSP_DIR")"
LOG_DIR="$LEPTON_LOG_DIR"

[[ "$TARGET" != / &&
   "$TARGET" != "$HOME" &&
   "$TARGET" != "$ROOT" &&
   "$TARGET" != "$ROOT/"* &&
   "$ROOT" != "$TARGET/"* ]] ||
  fail "Unsafe Android output directory"

[[ "$LOG_DIR" != / &&
   "$LOG_DIR" != "$HOME" &&
   "$LOG_DIR" != "$TARGET" &&
   "$LOG_DIR" != "$TARGET/"* &&
   "$TARGET" != "$LOG_DIR/"* ]] ||
  fail "Unsafe log directory"

STATE="$TARGET/.lepton-clean14-state"
# Present while the compiler runs; left behind only if a build was cut off.
RUNNING="$STATE/build.running"
CHECK_OUTPUTS="$ROOT/image-14/scripts/internal/check-build-outputs.py"
GLSLANG="$TARGET/out/host/glslang14/StandAlone/glslang"
BOOTSTRAP="$ROOT/image-14/scripts/internal/bootstrap-glslang14.sh"
BUILDER="${LEPTON_BUILD_CONTAINER:-lepton-builder-glslang14:latest}"
case "$BUILDER" in
  lepton-builder-glslang14:latest|lepton-builder-ubuntu26:latest) ;;
  *) fail "Unsupported image builder: $BUILDER" ;;
esac
GLSLANG_MOUNT=()
if [[ "$BUILDER" == lepton-builder-glslang14:latest ]]; then
  GLSLANG_MOUNT=(-v "$GLSLANG:/usr/bin/glslangValidator:ro")
fi

[[ -f "$TARGET/.lepton-clean14-owner" ]] ||
  fail "Checkout is not owned by the preparation workflow"

for marker in sync.done vendor.done patches.done; do
  [[ -f "$STATE/$marker" ]] ||
    fail "Missing preparation checkpoint: $marker"
done

[[ ! -e "$STATE/patches.started" ]] ||
  fail "Interrupted patch operation detected"

[[ -f "$TARGET/build/envsetup.sh" ]] ||
  fail "Android environment missing"

[[ -d "$TARGET/device/waydroid/waydroid" &&
   -d "$TARGET/vendor/extra" ]] ||
  fail "Vendored sources missing"

podman image exists "$BUILDER" ||
  fail "Missing builder: $BUILDER"

free_kib="$(df -Pk "$TARGET" | awk 'END {print $4}')"
free_gib="$((free_kib / 1024 / 1024))"

info "Android source: $TARGET"
info "Build target: $LEPTON_BUILD_TARGET"
info "Parallel jobs: $LEPTON_BUILD_JOBS"
info "Available storage: $free_gib GiB"
info "Builder: $BUILDER"

if [[ "$ACTION" == "--repair" ]]; then
  [[ -d "$TARGET/out" ]] || { info "[PASS] No build output yet; nothing to repair"; exit 0; }
  info "[START] Checking every compiled file in $TARGET/out for damage (a few minutes)"
  mkdir -p -- "$LOG_DIR"
  python3 "$CHECK_OUTPUTS" "$TARGET/out" --delete \
    --report "$LOG_DIR/damaged-build-files-$(date -u +%Y%m%dT%H%M%SZ).txt" ||
    fail "Could not check the build output"
  rm -f -- "$RUNNING"
  info "[PASS] Repair finished. Continue with: bash image-14/scripts/build-images-x86_64.sh --execute"
  exit 0
fi

if [[ -f "$RUNNING" ]]; then
  info "[WARN] The previous image build did not finish (power cut, crash or forced stop)"
  if [[ "$ACTION" == "--execute" ]]; then
    info "[INFO] Its damaged files will be found and rebuilt first"
  else
    info "[INFO] --execute will first find and rebuild the files it left damaged"
  fi
fi

(( free_gib >= LEPTON_MIN_FREE_GIB )) ||
  fail "Insufficient free space"

if [[ "$ACTION" == "--check" ]]; then
  if [[ "$BUILDER" == lepton-builder-ubuntu26:latest ]]; then
    info "[PASS] Ubuntu 26.04 builder supplies glslangValidator"
  elif [[ -x "$GLSLANG" ]]; then
    info "[PASS] glslang already available"
  else
    info "[INFO] glslang will be bootstrapped during --execute"
    bash "$BOOTSTRAP" --check
  fi

  info "[PASS] Image-build preflight completed"
  info "No compilation started"
  exit 0
fi

# The legacy Ubuntu 22 builder needs the separately compiled glslang 14.
# Ubuntu 26 supplies glslangValidator directly and must not use the legacy mount.
if [[ "$BUILDER" == lepton-builder-glslang14:latest ]]; then
  if [[ ! -x "$GLSLANG" ]]; then
    info "[START] Bootstrapping glslang 14"
    bash "$BOOTSTRAP" --execute
  fi
  [[ -x "$GLSLANG" ]] ||
    fail "glslang bootstrap did not produce an executable"
fi

mkdir -p -- "$LOG_DIR"

LOG="$LOG_DIR/images-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
exec > >(tee -a -- "$LOG") 2>&1

info "Persistent log: $LOG"
info "[START] Android 14 x86_64 systemimage + vendorimage"

# A build cut off by a power cut or crash can leave files recorded as done
# whose contents never reached the disk; ninja would reuse them and fail
# much later. Delete the damaged ones so ninja rebuilds them.
if [[ -f "$RUNNING" && -d "$TARGET/out" ]]; then
  info "[START] Checking files written by the unfinished build for damage"
  python3 "$CHECK_OUTPUTS" "$TARGET/out" --since-file "$RUNNING" --delete \
    --report "${LOG%.log}-damaged-files.txt" ||
    fail "Could not check the unfinished build's files"
fi
printf 'Started %s; log %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LOG" > "$RUNNING"

# Run Podman as a managed child so interrupt traps execute promptly.
STARTED=$SECONDS
CID_FILE="$(mktemp "$LOG_DIR/.lepton-build-container.XXXXXXXX")"
HEARTBEAT_PID=""
PODMAN_PID=""

cleanup_build() {
  if [[ -n "$HEARTBEAT_PID" ]]; then
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    wait "$HEARTBEAT_PID" 2>/dev/null || true
  fi
  rm -f -- "$CID_FILE"
}

stop_build_container() {
  local cid="" attempt

  # Allow Podman a brief period to write its container ID.
  for attempt in {1..25}; do
    if [[ -s "$CID_FILE" ]]; then
      cid="$(cat "$CID_FILE")"
      break
    fi
    [[ -n "$PODMAN_PID" ]] &&
      kill -0 "$PODMAN_PID" 2>/dev/null || break
    sleep 0.2
  done

  if [[ -n "$cid" ]]; then
    info "[INFO] Requesting container shutdown (3s grace)"
    if ! timeout -k 2s 8s podman stop --time 3 "$cid"; then
      info "[WARN] Graceful stop unsuccessful; escalating"
      timeout -k 2s 5s podman kill "$cid" || true
    fi
  else
    info "[WARN] No container ID available; stopping Podman process"
  fi
}

interrupt_build() {
  local signal="$1" exit_code="$2" attempt
  trap - INT TERM

  info "[INTERRUPTED] Received $signal; stopping build"

  [[ -z "$HEARTBEAT_PID" ]] ||
    kill "$HEARTBEAT_PID" 2>/dev/null || true

  stop_build_container

  if [[ -n "$PODMAN_PID" ]]; then
    # Do not wait indefinitely for the Podman client.
    for attempt in {1..50}; do
      kill -0 "$PODMAN_PID" 2>/dev/null || break
      sleep 0.1
    done

    if kill -0 "$PODMAN_PID" 2>/dev/null; then
      info "[WARN] Podman client still running; terminating it"
      kill -TERM "$PODMAN_PID" 2>/dev/null || true
      sleep 1
    fi

    if kill -0 "$PODMAN_PID" 2>/dev/null; then
      kill -KILL "$PODMAN_PID" 2>/dev/null || true
    fi
    wait "$PODMAN_PID" 2>/dev/null || true
  fi

  info "[INFO] Existing Android build outputs preserved"
  info "[INFO] Log: $LOG"
  exit "$exit_code"
}

trap cleanup_build EXIT
trap 'interrupt_build SIGINT 130' INT
trap 'interrupt_build SIGTERM 143' TERM

(
  while sleep 60; do
    info "[HEARTBEAT] Image build running for $(( (SECONDS-STARTED)/60 ))m; log: $LOG"
  done
) &
HEARTBEAT_PID=$!

# BUILD_USERNAME/BUILD_HOSTNAME: Android records them in ro.build.user,
# ro.build.host and the build description; fixed values keep the builder's
# login name out of the images and make builds comparable across machines.
podman run --rm -i --cidfile "$CID_FILE" \
  --network=host \
  --userns=keep-id \
  --group-add keep-groups \
  --security-opt=label=disable \
  --hostname=lepton-build \
  -e TERM=xterm \
  -e BUILD_USERNAME=lepton \
  -e BUILD_HOSTNAME=lepton-build \
  -e LEPTON_BUILD_TARGET="$LEPTON_BUILD_TARGET" \
  -e LEPTON_BUILD_JOBS="$LEPTON_BUILD_JOBS" \
  -v "$ROOT/image-14:/workspace:ro" \
  -v "$TARGET:/workspace/output:rw" \
  "${GLSLANG_MOUNT[@]}" \
  -w /workspace/output \
  "$BUILDER" /bin/bash -se <<'INNER' &
set -Eeo pipefail

cd /workspace/output

echo "[INFO] Using glslang validator:"
/usr/bin/glslangValidator --version | head -4

echo "[INFO] Loading Android build environment"
# Android envsetup and build functions may access unset variables.
set +u
source build/envsetup.sh >/dev/null

echo "[INFO] Selecting $LEPTON_BUILD_TARGET"
lunch "$LEPTON_BUILD_TARGET"

echo "[START] Compiling systemimage and vendorimage"
m -j"$LEPTON_BUILD_JOBS" systemimage vendorimage

echo "[PASS] Android build command completed"
INNER
PODMAN_PID=$!

result=0
wait "$PODMAN_PID" || result=$?

trap - INT TERM
# The build ended by itself, so its files were written normally.
rm -f -- "$RUNNING"

if (( result != 0 )); then
  # Typical errors from build files damaged by an earlier power cut or crash.
  if grep -Eq 'neither ET_REL nor LLVM bitcode|file format not recognized|file truncated|unexpected end of file|is not an object|not a valid ELF|error in opening zip|zip END header not found|archive has no index' "$LOG"; then
    info "[HINT] These errors usually mean build files were damaged, e.g. by a power cut or"
    info "[HINT] crash during an earlier build. Repair, then continue (no full rebuild):"
    info "[HINT]   bash image-14/scripts/build-images-x86_64.sh --repair"
    info "[HINT]   bash image-14/scripts/build-images-x86_64.sh --execute"
  fi
  fail "Android image build failed (exit $result); log: $LOG"
fi

info "[PASS] Android image build completed"

# Bundles are made from these images' flattened rootfs; replace whatever an
# earlier build left so images/, rootfs/ and aosp/out never disagree.
PRODUCT="$TARGET/out/target/product/lepton_x86_64"
info "[START] Copying images to $LEPTON_IMAGES_DIR"
mkdir -p -- "$LEPTON_IMAGES_DIR"
for part in system vendor; do
  cp -f --sparse=always -- "$PRODUCT/$part.img" "$LEPTON_IMAGES_DIR/.$part.img.new"
  mv -f -- "$LEPTON_IMAGES_DIR/.$part.img.new" "$LEPTON_IMAGES_DIR/$part.img"
done
( cd "$LEPTON_IMAGES_DIR" && sha256sum system.img vendor.img > SHA256SUMS )

info "[START] Packaging the Android rootfs for bundles: $LEPTON_ROOTFS_DIR"
if [[ -e "$LEPTON_ROOTFS_DIR" || -L "$LEPTON_ROOTFS_DIR" ]]; then
  info "[INFO] Removing the rootfs packaged from the previous build"
  podman unshare rm -rf -- "$LEPTON_ROOTFS_DIR"
fi
bash "$ROOT/image-14/scripts/internal/package-repro-rootfs.sh" "$TARGET" "$LEPTON_ROOTFS_DIR" ||
  fail "Packaging the rootfs failed; log: $LOG"

info "[PASS] Android images built and packaged"
info "Next: bash image-14/scripts/make-deck-bundle-x86_64.sh --check --bundle-id ID"
info "Log: $LOG"
info "No Steam Deck deployment performed"
