#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MODE="${1:-fresh}"
CONFIG="$ROOT/.build-env"

pass() { printf '[PASS] %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
fail() {
    printf '[FAIL] %s\n' "$*"
    failures=$((failures + 1))
}

failures=0
warnings=0

if [[ "$MODE" != fresh && "$MODE" != existing && "$MODE" != full ]]; then
    echo "Usage: $0 [fresh|existing|full]" >&2
    exit 2
fi

if [[ ! -f "$CONFIG" ]]; then
    echo "[FAIL] Missing .build-env" >&2
    echo "Copy .build-env.example to .build-env first." >&2
    exit 1
fi

# This is a trusted, developer-controlled local configuration.
source "$CONFIG"
BUILDER="${LEPTON_BUILD_CONTAINER:-lepton-builder:latest}"
case "$BUILDER" in
    lepton-builder:latest|lepton-builder-ubuntu26:latest) ;;
    *) echo "[FAIL] Unsupported source builder: $BUILDER" >&2; exit 1 ;;
esac

for key in LEPTON_OUTPUT_DIR LEPTON_BUILD_TARGET \
           LEPTON_BUILD_JOBS LEPTON_MIN_FREE_GIB LEPTON_LOG_DIR; do
    if [[ -z "${!key:-}" ]]; then
        fail "Missing configuration: $key"
    fi
done

if (( failures > 0 )); then exit 1; fi

if [[ ! "$LEPTON_BUILD_JOBS" =~ ^[1-9][0-9]*$ ||
      ! "$LEPTON_MIN_FREE_GIB" =~ ^[0-9]+$ ]]; then
    echo "[FAIL] Invalid numeric configuration" >&2
    exit 1
fi

TARGET="$(realpath -m -- "$LEPTON_OUTPUT_DIR")"
PARENT="$(dirname "$TARGET")"
LOGS="$(realpath -m -- "$LEPTON_LOG_DIR")"

echo "=== Lepton Android 14 x86_64 Preflight ==="
echo "Mode:        $MODE"
echo "Destination: $TARGET"
echo "Build:       $LEPTON_BUILD_TARGET"
echo "Builder:     $BUILDER"
echo "Jobs:        $LEPTON_BUILD_JOBS"
echo "Logs:        $LOGS"
echo

# Reject dangerous destinations and overlapping source locations.
HOME_REAL="$(realpath -m "$HOME")"

case "$TARGET" in
    /|"$HOME_REAL"|"$ROOT"|"$ROOT"/*)
        fail "Unsafe output destination"
        ;;
    *)
        pass "Output destination outside repository"
        ;;
esac

if [[ -L "$LEPTON_OUTPUT_DIR" ]]; then
    fail "Output destination is a symbolic link"
fi

# A log directory must not contain or equal the AOSP destination.
case "$LOGS" in
    "$TARGET"|"$TARGET"/*)
        fail "Log directory overlaps AOSP output"
        ;;
    *)
        pass "Log directory separate from AOSP output"
        ;;
esac

# Destination validation.
if [[ "$MODE" == fresh ]]; then
    if [[ -e "$TARGET" || -L "$TARGET" ]]; then
        fail "Fresh destination already exists"
    elif [[ ! -d "$PARENT" || ! -w "$PARENT" ]]; then
        fail "Destination parent missing or unwritable"
    else
        pass "Fresh destination available"
    fi
else
    if [[ -f "$TARGET/.repo/manifest.xml" &&
          -f "$TARGET/build/envsetup.sh" ]]; then
        pass "Existing AOSP checkout detected"
    else
        fail "Existing AOSP checkout not detected"
    fi
fi

# Disk and inode capacity.
if [[ -d "$PARENT" ]]; then
    free_kib="$(df -Pk "$PARENT" | awk 'END {print $4}')"
    free_gib=$((free_kib / 1024 / 1024))
    free_inodes="$(df -Pi "$PARENT" | awk 'END {print $4}')"

    if (( free_gib >= LEPTON_MIN_FREE_GIB )); then
        pass "Disk: ${free_gib} GiB available"
    else
        fail "Disk: ${free_gib} GiB; minimum ${LEPTON_MIN_FREE_GIB}"
    fi

    if (( free_inodes >= 1000000 )); then
        pass "Free inodes: $free_inodes"
    else
        fail "Insufficient free inodes: $free_inodes"
    fi

    pass "Filesystem: $(findmnt -T "$PARENT" -no FSTYPE)"
fi

# Memory and CPU.
memory_kib="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
memory_gib=$((memory_kib / 1024 / 1024))

if (( memory_gib >= 24 )); then
    pass "RAM: ${memory_gib} GiB"
elif (( memory_gib >= 16 )); then
    warn "RAM: ${memory_gib} GiB; conservative parallelism advised"
    warnings=$((warnings + 1))
else
    fail "RAM below 16 GiB"
fi

cpus="$(nproc)"
if (( cpus >= LEPTON_BUILD_JOBS )); then
    pass "CPUs: $cpus available"
else
    fail "Build jobs exceed available CPUs"
fi

# The current image builder uses configurable -jN, not taskset.
info "CPU affinity is not required by the current build workflow"

# Host prerequisites.
for tool in git podman rsync realpath findmnt df awk cmp python3 tee mktemp; do
    if command -v "$tool" >/dev/null 2>&1; then
        pass "Host tool: $tool"
    else
        fail "Missing host tool: $tool"
    fi
done

# Container builder.
if command -v podman >/dev/null 2>&1; then
    if podman image exists "$BUILDER"; then
        pass "Podman builder image available"
        podman image inspect "$BUILDER" \
            --format 'Builder ID: {{.Id}}'
    else
        fail "Podman builder image missing: $BUILDER"
    fi
fi

# The derived builder is required for compilation, not source download.
if [[ "$BUILDER" == lepton-builder-ubuntu26:latest ]]; then
    info "Ubuntu 26.04 builder supplies glslangValidator; no legacy bootstrap required"
elif [[ "$MODE" == existing || "$MODE" == full ]]; then
    if command -v podman >/dev/null 2>&1 &&
       podman image exists lepton-builder-glslang14:latest; then
        pass "glslang-capable builder image available"
    else
        fail "Missing lepton-builder-glslang14:latest; build Containerfile.glslang14"
    fi
else
    info "Derived glslang builder checked in existing/full mode"
fi

# Git submodules: missing is normal before preparation.
for submodule in \
    image-14/android_hardware_waydroid \
    image-14/android_vendor_waydroid; do

    status="$(git -C "$ROOT" submodule status -- "$submodule")"
    marker="${status:0:1}"

    case "$marker" in
        " ")
            pass "Submodule pinned: $submodule"
            ;;
        "-")
            if [[ "$MODE" == fresh ]]; then
                info "Submodule needs initialization: $submodule"
            else
                fail "Submodule not initialized: $submodule"
            fi
            ;;
        "+"|"U")
            fail "Submodule revision mismatch/conflict: $submodule"
            ;;
        *)
            fail "Unexpected submodule status: $submodule"
            ;;
    esac
done

# Verify that an existing checkout belongs to this workflow.
if [[ "$MODE" == existing || "$MODE" == full ]]; then
    state="$TARGET/.lepton-clean14-state"
    if [[ -f "$TARGET/.lepton-clean14-owner" ]]; then
        pass "Owned clean-build checkout"
    else
        fail "Missing clean-build ownership marker"
    fi

    for marker in sync.done vendor.done patches.done; do
        if [[ -f "$state/$marker" ]]; then
            pass "Preparation checkpoint: $marker"
        else
            fail "Missing preparation checkpoint: $marker"
        fi
    done

    if [[ -e "$state/patches.started" ]]; then
        fail "Interrupted patch stage recorded"
    else
        pass "No interrupted patch operation"
    fi

    if [[ "$BUILDER" == lepton-builder-ubuntu26:latest ]]; then
        pass "Native glslang supplied by Ubuntu 26.04 builder"
    else
        glslang="$TARGET/out/host/glslang14/StandAlone/glslang"
        if [[ -x "$glslang" ]]; then
            pass "Compiled glslang available"
        elif [[ -d "$TARGET/external/angle/third_party/vulkan-deps/glslang/src" ]]; then
            info "glslang will be bootstrapped by build-images-x86_64.sh"
        else
            fail "Neither compiled glslang nor its source was found"
        fi
    fi
fi

# Full workflow: check packaging dependencies and finished images.
if [[ "$MODE" == full ]]; then
    echo
    info "=== Full build and packaging prerequisites ==="

    for tool in simg2img sqfs2tar tar unzip fuse2fs fusermount3 rsync; do
        if command -v "$tool" >/dev/null 2>&1; then
            pass "Packaging tool: $tool"
        else
            fail "Missing packaging tool: $tool"
        fi
    done

    if [[ -c /dev/fuse && -r /dev/fuse && -w /dev/fuse ]]; then
        pass "FUSE device accessible"
        info "Actual FUSE mounting is verified during packaging"
    else
        fail "FUSE device missing or inaccessible: /dev/fuse"
    fi

    product="$TARGET/out/target/product/lepton_x86_64"
    for part in system vendor; do
        if [[ -s "$product/$part.img" ]]; then
            pass "Built image present: $part.img"
        else
            fail "Missing built image: $part.img"
        fi
    done

    stage="$TARGET/repro-rootfs-auto"
    if [[ -e "$stage/rootfs" || -L "$stage/rootfs" ]]; then
        warn "Packaging output already exists; packaging script refuses overwrite"
        warnings=$((warnings + 1))
    else
        pass "Packaging output rootfs is available"
    fi

    if [[ -f "$ROOT/image-14/scripts/patch-binderfs-init.sh" &&
          -f "$ROOT/image-14/scripts/package-repro-rootfs.sh" ]]; then
        pass "Rootfs packaging and BinderFS scripts available"
    else
        fail "Rootfs packaging or BinderFS script missing"
    fi
fi

# Required source files.
for file in \
    image-14/.buildscripts/container.sh \
    image-14/.buildscripts/update_repositories.sh \
    image-14/.buildscripts/copy_vendored_projects.sh \
    image-14/android_vendor_valve/vendorsetup.sh \
    image-14/android_vendor_valve/patches/apply-patches.sh \
    image-14/scripts/bootstrap-glslang14.sh \
    image-14/scripts/build-images-x86_64.sh; do

    if [[ -f "$ROOT/$file" ]]; then
        pass "Source: $file"
    else
        fail "Missing source: $file"
    fi
done

echo
printf 'Results: %d failures, %d warnings\n' \
    "$failures" "$warnings"

if (( failures > 0 )); then
    echo "NOT READY"
    exit 1
fi

echo "PREFLIGHT PASSED ($MODE)"
