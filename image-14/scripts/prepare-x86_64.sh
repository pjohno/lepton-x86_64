#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Lepton Android 14 x86_64 -- isolated, logged source preparation.
set -Eeuo pipefail

usage() {
  cat <<'HELP'
Usage: prepare-x86_64.sh --check | --sync-only | --resume-sync | --vendor-only | --patch-only | --execute | --resume
  --check    Read-only inspection; no downloads or filesystem changes.
  --sync-only    Create fresh checkout and sync Android sources only.
  --resume-sync  Resume source synchronization, without copying or patching.
  --vendor-only  Install vendored projects in an already synced checkout.
  --patch-only   Apply patches after vendored projects are verified.
  --execute      Create new checkout, sync, vendor sources, and apply patches.
  --resume       Resume an interrupted download/copy; never replay interrupted patches.
Configuration: repository-root .build-env (copy .build-env.example and customize).
HELP
}
[[ $# == 1 ]] || { usage >&2; exit 2; }
ACTION=$1
case "$ACTION" in --check|--sync-only|--resume-sync|--vendor-only|--patch-only|--execute|--resume) ;; *) usage >&2; exit 2;; esac

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
IMAGE="$ROOT/image-14"
CONFIG="$ROOT/.build-env"
[[ -f "$CONFIG" ]] || { echo "ERROR: Missing $CONFIG" >&2; exit 1; }
# Trusted local developer-controlled shell configuration only.
source "$CONFIG"
BUILDER="${LEPTON_BUILD_CONTAINER:-lepton-builder:latest}"
case "$BUILDER" in
  lepton-builder:latest|lepton-builder-ubuntu26:latest) ;;
  *) echo "ERROR: Unsupported source builder: $BUILDER" >&2; exit 1 ;;
esac
for variable in LEPTON_OUTPUT_DIR LEPTON_BUILD_TARGET LEPTON_BUILD_JOBS LEPTON_MIN_FREE_GIB LEPTON_LOG_DIR; do
  [[ -n "${!variable:-}" ]] || { echo "ERROR: Missing config: $variable" >&2; exit 1; }
done
[[ $LEPTON_MIN_FREE_GIB =~ ^[0-9]+$ && $LEPTON_BUILD_JOBS =~ ^[1-9][0-9]*$ ]] || {
  echo 'ERROR: Invalid numeric configuration' >&2; exit 1;
}
TARGET=$(realpath -m -- "$LEPTON_OUTPUT_DIR")
PARENT=$(dirname -- "$TARGET")
LOG_DIR=$(realpath -m -- "$LEPTON_LOG_DIR")
HOME_REAL=$(realpath -m -- "$HOME")
ROOT_REAL=$(realpath -m -- "$ROOT")

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
under() { [[ "$1" == "$2" || "$1" == "$2/"* ]]; }

# Never allow the new output or log path to overlap repository, each other,
# existing working trees, or the user's home directory itself.
[[ "$TARGET" != / && "$TARGET" != "$HOME_REAL" ]] || err 'Unsafe output destination'
! under "$TARGET" "$ROOT_REAL" && ! under "$ROOT_REAL" "$TARGET" || err 'Output overlaps Git checkout'
! under "$TARGET" "$LOG_DIR" && ! under "$LOG_DIR" "$TARGET" || err 'Logs and output overlap'
[[ "$LOG_DIR" != / && "$LOG_DIR" != "$HOME_REAL" ]] || err 'Unsafe log directory'
[[ ! -L "$LEPTON_OUTPUT_DIR" ]] || err 'Output argument is a symlink'
[[ -d "$PARENT" ]] || err "Output parent does not exist: $PARENT"
[[ -w "$PARENT" ]] || err "Output parent not writable: $PARENT"

# Prevent a fresh checkout being created inside any existing AOSP checkout.
# Resolve the parent (not the future target) to account for symlinks.
CANONICAL_PARENT=$(realpath -e -- "$PARENT")
[[ "$CANONICAL_PARENT" == "$PARENT" ]] || err "Output parent uses an alias: $PARENT"
ancestor="$PARENT"
while [[ "$ancestor" != / ]]; do
  [[ ! -e "$ancestor/.repo" && ! -f "$ancestor/build/envsetup.sh" ]] || \
    err "Output nested in an existing AOSP checkout: $ancestor"
  ancestor=$(dirname -- "$ancestor")
done

# Defend against an existing protected AOSP checkout at any path, including
# path aliases.  No use of --force-* or cleanup flags anywhere in this script.
[[ ! -f "$TARGET/build/envsetup.sh" || -f "$TARGET/.lepton-clean14-owner" ]] || \
  err 'Unmarked existing AOSP checkout: refusing to modify'

SUBMODULES=(image-14/android_hardware_waydroid image-14/android_vendor_waydroid)
MANIFESTS="$IMAGE/android_vendor_valve/manifest_scripts/manifests-34"
for tool in git podman realpath df awk findmnt rsync cmp; do
  command -v "$tool" >/dev/null || err "Missing host tool: $tool"
done
[[ -d "$MANIFESTS" ]] || err 'Missing manifests directory'
for name in 00-remotes 01-removes 02-waydroid 10-valve-remotes 11-removes 12-valve-replacements; do
  [[ -f "$MANIFESTS/$name.xml" ]] || err "Missing manifest $name.xml"
done
for name in \
  "$IMAGE/android_device_valve_lepton/ubpf/ubpf_syscall.h" \
  "$IMAGE/.buildscripts/copy_vendored_projects.sh" \
  "$IMAGE/android_vendor_valve/patches/apply-patches.sh" \
  "$IMAGE/patches/0001-mesa-android-sdk34-link-libzstd.patch" \
  "$IMAGE/patches/0004-minigbm-gbm-mesa-driver.patch" \
  "$IMAGE/patches/0007-eventhub-preserve-evdev-axes.patch" \
  "$IMAGE/patches/0008-inputreader-separate-steam-input-pads.patch"; do
  [[ -f "$name" ]] || err "Missing required file: $name"
done
podman image exists "$BUILDER" || err "Missing builder image: $BUILDER"

# Pinned revision verification: never reset an initialized submodule.
PENDING=()
for path in "${SUBMODULES[@]}"; do
  state=$(git -C "$ROOT" submodule status -- "$path")
  [[ -n "$state" ]] || err "Unregistered submodule: $path"
  case "${state:0:1}" in
    ' ')
      [[ -z "$(git -C "$ROOT/$path" status --porcelain)" ]] || err "Dirty submodule: $path"
      info "[PASS] Pinned, clean submodule: $path" ;;
    '-')
      [[ ! -d "$ROOT/$path" || -z "$(find "$ROOT/$path" -mindepth 1 -maxdepth 1 -print -quit)" ]] || \
        err "Uninitialized submodule directory contains files: $path"
      info "[INFO] Will initialize pinned submodule: $path"
      PENDING+=("$path") ;;
    *) err "Mismatched/conflicted submodule: $path ($state)" ;;
  esac
done

free_kib=$(df -Pk "$PARENT" | awk 'END {print $4}')
free_gib=$((free_kib / 1024 / 1024))
info "Destination: $TARGET"
info "Available space: $free_gib GiB; required: $LEPTON_MIN_FREE_GIB GiB"
(( free_gib >= LEPTON_MIN_FREE_GIB )) || err 'Insufficient free space'
info "Builder: $BUILDER ($(podman image inspect "$BUILDER" --format '{{.Id}}'))"
info "Source commit: $(git -C "$ROOT" rev-parse HEAD)"

MARKER="$TARGET/.lepton-clean14-owner"
STATE="$TARGET/.lepton-clean14-state"
owner_content="$(git -C "$ROOT" rev-parse HEAD)"
if [[ "$ACTION" == --execute || "$ACTION" == --sync-only ]]; then
  [[ ! -e "$TARGET" && ! -L "$TARGET" ]] || err 'Fresh target exists; use --resume only for a marked checkout'
elif [[ "$ACTION" == --resume || "$ACTION" == --resume-sync || "$ACTION" == --vendor-only || "$ACTION" == --patch-only ]]; then
  [[ -f "$MARKER" && -d "$STATE" ]] || err 'No owned checkout state to resume'
  [[ "$(cat "$MARKER")" == "$owner_content" ]] || err 'Checkout belongs to a different repository commit'
  [[ ! -e "$STATE/patches.started" || -e "$STATE/patches.done" ]] || \
    err 'Inherited/custom patching was interrupted: inspect manually; auto-resume is disabled'
fi

if [[ "$ACTION" == --check ]]; then
  if [[ -e "$TARGET" || -L "$TARGET" ]]; then
    if [[ -f "$MARKER" ]]; then
      info '[INFO] Existing marked checkout; --execute is not allowed'
    else
      info '[FAIL] Destination already exists and is not owned by this workflow'
      exit 1
    fi
  else
    info '[PASS] New destination is absent'
  fi
  info '[PASS] Read-only preparation inspection completed; no downloads started'
  exit 0
fi

# Log preparation outside the AOSP directory so logs remain after failed stages.
mkdir -p -- "$LOG_DIR"
LOG_FILE="$LOG_DIR/prepare-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
exec > >(tee -a -- "$LOG_FILE") 2>&1
info "Persistent log: $LOG_FILE"
info "Action: $ACTION"

if (( ${#PENDING[@]} )); then
  git -C "$ROOT" submodule update --init -- "${PENDING[@]}"
fi
for path in "${SUBMODULES[@]}"; do
  state=$(git -C "$ROOT" submodule status -- "$path")
  [[ "${state:0:1}" == ' ' ]] || err "Submodule verification failed: $path"
  [[ -z "$(git -C "$ROOT/$path" status --porcelain)" ]] || err "Dirty submodule: $path"
done

if [[ "$ACTION" == --execute || "$ACTION" == --sync-only ]]; then
  mkdir -- "$TARGET" || err 'Failed to create fresh output directory'
  printf '%s\n' "$owner_content" > "$MARKER"
  mkdir -- "$STATE"
fi

# Read-only source checkout inside Podman and writable output mount are
# explicit; never invoke container.sh, which has optional SSH/root rewrites.
run_in_builder() {
  local started=$SECONDS heartbeat_pid result=0
  # A heartbeat is an elapsed-time indicator, not proof of network activity.
  (
    while sleep 60; do
      printf '[%s] [HEARTBEAT] Container stage running for %dm; log: %s\n' \
        "$(date -u +%H:%M:%SZ)" "$(( (SECONDS-started)/60 ))" "$LOG_FILE"
    done
  ) &
  heartbeat_pid=$!
  # --network=host avoids the observed pasta AVC on the Codes symlink.
  # Do not use :U or :Z on the shared family volume.
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
    "$BUILDER" /bin/bash -se; then
    result=0
  else
    result=$?
  fi
  kill "$heartbeat_pid" 2>/dev/null || true
  wait "$heartbeat_pid" 2>/dev/null || true
  if (( result != 0 )); then
    printf '[%s] [FAIL] Container stage failed (exit %d); log: %s\n' \
      "$(date -u +%H:%M:%SZ)" "$result" "$LOG_FILE" >&2
  fi
  return "$result"
}

# Detect whether repo synced completely before doing any vendored copies.
if [[ ! -f "$STATE/sync.done" ]]; then
  info "[$(date -u +%H:%M:%SZ)] [START] Stage 1: Android repo init and synchronization"
  run_in_builder <<'INNER'
set -Eeuo pipefail
cd /workspace/output
[[ -f /run/.containerenv || -f /.dockerenv ]] || { echo 'Not in container'; exit 1; }
[[ "$(readlink -f /workspace/output)" == /workspace/output ]] || { echo 'Unexpected output path'; exit 1; }
if [[ ! -f .repo/manifest.xml ]]; then
  echo "[$(date -u +%H:%M:%SZ)] [INFO] Initializing Android 14 manifest (android-14.0.0_r75)"
  repo init -u https://android.googlesource.com/platform/manifest \
    -b android-14.0.0_r75 -g default,-trusty --git-lfs
fi
echo "[$(date -u +%H:%M:%SZ)] [INFO] repo initialized; installing local manifests"
mkdir -p .repo/local_manifests
for source in /workspace/android_vendor_valve/manifest_scripts/manifests-34/*.xml; do
  destination=".repo/local_manifests/${source##*/}"
  if [[ -e "$destination" ]]; then
    cmp -s "$source" "$destination" || { echo "Changed local manifest: $destination"; exit 1; }
  else
    cp "$source" "$destination"
  fi
done
echo "[$(date -u +%H:%M:%SZ)] [START] Synchronizing Android repositories (4 jobs)"
.repo/repo/repo sync -j4
echo "[$(date -u +%H:%M:%SZ)] [PASS] Android source synchronization finished"
.repo/repo/repo manifest -r -o .lepton-resolved-manifest.xml
INNER
  touch "$STATE/sync.done"
  info "[$(date -u +%H:%M:%SZ)] [PASS] Stage 1 complete; resolved manifest recorded"
fi

if [[ "$ACTION" == --sync-only || "$ACTION" == --resume-sync ]]; then
  info "[$(date -u +%H:%M:%SZ)] [PASS] Source synchronization checkpoint reached"
  info "Resolved manifest: $TARGET/.lepton-resolved-manifest.xml"
  info 'No vendored projects copied and no patches or builds started.'
  exit 0
fi

if [[ "$ACTION" == --vendor-only || "$ACTION" == --patch-only ]]; then
  [[ -f "$STATE/sync.done" ]] || err 'Source synchronization incomplete'
fi
if [[ "$ACTION" == --patch-only ]]; then
  [[ -f "$STATE/vendor.done" ]] || err 'Vendored project installation incomplete'
fi

if [[ ! -f "$STATE/vendor.done" && "$ACTION" != --patch-only ]]; then
  info '=== Stage 2: Vendored project installation ==='
  # This stage deliberately runs only once after successful source sync.
  run_in_builder <<'INNER'
set -Eeuo pipefail
cd /workspace/output
[[ -f .repo/manifest.xml && -f build/envsetup.sh ]] || { echo 'Missing synced AOSP checkout'; exit 1; }
/workspace/.buildscripts/copy_vendored_projects.sh
INNER
  touch "$STATE/vendor.done"
fi

if [[ "$ACTION" == --vendor-only ]]; then
  info '[PASS] Vendored project checkpoint reached'
  info 'No inherited or custom patches applied.'
  exit 0
fi

if [[ ! -f "$STATE/patches.done" ]]; then
  [[ ! -e "$STATE/patches.started" ]] || err 'Patching was interrupted; manual recovery required'
  info '=== Stage 3: Inherited + custom x86_64 patches ==='
  touch "$STATE/patches.started"
  run_in_builder <<'INNER'
set -Eeuo pipefail
cd /workspace/output
# Android envsetup and inherited patches are not nounset-safe.
# Keep errexit and pipefail enabled.
# Use deterministic, build-only Git committer identity for git am.
export GIT_COMMITTER_NAME="Lepton Build Automation"
export GIT_COMMITTER_EMAIL="lepton-build@localhost"
set +u
source build/envsetup.sh >/dev/null
command -v apply-patches >/dev/null || { echo 'apply-patches missing from envsetup'; exit 1; }
apply-patches
set -u
apply_custom() {
  local project="$1" patch="$2" label="$3"
  [[ -d "$project/.git" || -f "$project/.git" ]] || { echo "No Git project: $project"; return 1; }
  if git -C "$project" apply --reverse --check "$patch" >/dev/null 2>&1; then
    echo "Already applied: $label"
  else
    git -C "$project" apply --check "$patch"
    git -C "$project" apply "$patch"
    echo "Applied: $label"
  fi
}
apply_custom /workspace/output/external/mesa /workspace/patches/0001-mesa-android-sdk34-link-libzstd.patch Mesa-zstd
apply_custom /workspace/output/external/minigbm /workspace/patches/0004-minigbm-gbm-mesa-driver.patch minigbm
apply_custom /workspace/output/frameworks/native /workspace/patches/0007-eventhub-preserve-evdev-axes.patch EventHub
apply_custom /workspace/output/frameworks/native /workspace/patches/0008-inputreader-separate-steam-input-pads.patch SteamInputPads
INNER
  touch "$STATE/patches.done"
  rm -- "$STATE/patches.started"
fi

info '=== Preparation complete ==='
info "Resolved manifest: $TARGET/.lepton-resolved-manifest.xml"
info "Logs: $LOG_FILE"
info 'No host glslang or Android images were built. No Steam Deck deployment occurred.'
