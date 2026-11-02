#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CONFIG="$ROOT/.build-env"
LEGACY_DEST="$ROOT/compat_tool/images/rootfs"
EXTRACTOR="$ROOT/compat_tool/liblepton/apk_extractor"
MODE='--check'
STAGE_DIR=''
ROOTFS_SOURCE=''
WITH_NDK=false
NDK_PAYLOAD=''

fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }
usage() {
    cat <<'HELP'
Usage: bash image-14/scripts/deploy-compat-x86_64.sh [--check|--execute] [--stage-dir DIR] [--rootfs-source DIR] [--with-ndk --ndk-payload DIR]

Default (legacy): stage Android rootfs under repository compat_tool/images/rootfs.
--stage-dir DIR: assemble an isolated, complete compatibility-tool source stage
                 under DIR/compat_tool, including fresh rootfs and native APK
                 extractor. DIR must NOT already exist for --execute.
--rootfs-source DIR: stage an alternative Android 14 x86_64 rootfs (requires
                    --stage-dir; does not affect the legacy destination).
--with-ndk: inject a local ARM64 NDK payload into a NEW stage and build the
            compatibility shim. Requires --stage-dir and a native source rootfs.
--ndk-payload DIR: extracted payload directory (or LEPTON_NDK_PAYLOAD in .build-env).
                  No translator is downloaded. NDK remains opt-in.
--check: inspect source and existing destination; never modify files.
--execute: refuse to overwrite existing rootfs/stage or Steam installation.

Steam Deck host utilities and fresh sysbake require separate provisioning:
  image-14/scripts/provision-deck-tools.sh --stage-dir DIR --execute
HELP
}
while (($#)); do
    case "$1" in
        --check|--execute) MODE="$1"; shift ;;
        --stage-dir) (($# >= 2)) || fail '--stage-dir requires a path'; STAGE_DIR="$2"; shift 2 ;;
        --rootfs-source) (($# >= 2)) || fail '--rootfs-source requires a path'; ROOTFS_SOURCE="$2"; shift 2 ;;
        --with-ndk) WITH_NDK=true; shift ;;
        --ndk-payload) (($# >= 2)) || fail '--ndk-payload requires a path'; NDK_PAYLOAD="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done
[[ -f "$CONFIG" ]] || fail 'Missing .build-env'
# shellcheck source=/dev/null
source "$CONFIG"
[[ "$WITH_NDK" == true || -z "$NDK_PAYLOAD" ]] || fail '--ndk-payload requires --with-ndk'
if [[ "$WITH_NDK" == true ]]; then
    [[ -n "$STAGE_DIR" ]] || fail '--with-ndk requires --stage-dir (existing deployments stay unchanged)'
    NDK_PAYLOAD="${NDK_PAYLOAD:-${LEPTON_NDK_PAYLOAD:-}}"
    [[ -n "$NDK_PAYLOAD" ]] || fail '--with-ndk requires --ndk-payload or LEPTON_NDK_PAYLOAD'
    NDK_PAYLOAD="$(realpath -e -- "$NDK_PAYLOAD")" || fail 'NDK payload not found'
fi
if [[ -n "$ROOTFS_SOURCE" ]]; then
    [[ -n "$STAGE_DIR" ]] || fail '--rootfs-source requires --stage-dir (legacy deployment is unchanged)'
    [[ -d "$ROOTFS_SOURCE" && ! -L "$ROOTFS_SOURCE" ]] || fail "Alternative rootfs must be a real directory: $ROOTFS_SOURCE"
    SRC="$(realpath -e -- "$ROOTFS_SOURCE")" || fail "Cannot resolve alternative rootfs: $ROOTFS_SOURCE"
else
    SRC="$(realpath -m -- "${LEPTON_OUTPUT_DIR:?}/repro-rootfs-auto/rootfs")"
fi
[[ -d "$SRC" && ! -L "$SRC" ]] || fail "Packaged Android rootfs missing: $SRC"
[[ -x "$SRC/system/bin/sh" ]] || fail 'Android shell missing'
[[ -f "$SRC/system/build.prop" ]] || fail 'Android build.prop missing'
[[ -f "$SRC/vendor/lib64/hw/vulkan.radeon.so" ]] || fail 'AMD Vulkan driver missing'
grep -qx 'ro.build.version.sdk=34' "$SRC/system/build.prop" || fail 'Expected Android API 34'
[[ -f "$ROOT/compat_tool/lepton" ]] || fail 'Lepton launcher missing'
[[ -f "$EXTRACTOR/Makefile" ]] || fail 'APK extractor Makefile missing'
[[ "$(uname -m)" == x86_64 ]] || fail 'Requires x86_64 host'
for tool in cargo cc make rsync realpath; do
    command -v "$tool" >/dev/null 2>&1 || fail "Missing dependency: $tool"
done
source "$ROOT/compat_tool/liblepton/ndk_auxv/runtime.sh"
BUILD_NDK_SHIM=false
if [[ "$WITH_NDK" == true ]] || ndk_compat_supported "$SRC"; then
    [[ -x "${LEPTON_OUTPUT_DIR}/prebuilts/clang/host/linux-x86/clang-r510928/bin/clang" ]] || fail 'AOSP Clang required to build standard NDK compatibility shim'
    BUILD_NDK_SHIM=true
fi

if [[ -n "$STAGE_DIR" ]]; then
    STAGE_DIR="$(realpath -m -- "$STAGE_DIR")"
    [[ "$STAGE_DIR" != / && "$STAGE_DIR" != "$ROOT" ]] || fail 'Unsafe stage destination'
    [[ "$STAGE_DIR" != "$ROOT/"* && "$STAGE_DIR" != "$SRC" && "$STAGE_DIR" != "$SRC/"* ]] || fail 'Stage must not be inside repository or rootfs'
    [[ "$SRC" != "$STAGE_DIR/"* ]] || fail 'Rootfs source must not be inside destination stage'
    DEST="$STAGE_DIR/compat_tool/images/rootfs"
else
    DEST="$LEGACY_DEST"
fi

if [[ "$WITH_NDK" == true ]]; then
    bash "$ROOT/image-14/scripts/inject-ndk-translation.sh" --check \
        --rootfs "$SRC" --payload "$NDK_PAYLOAD" --output "$STAGE_DIR"
fi

if [[ -e "$DEST" || -L "$DEST" ]]; then
    [[ -d "$DEST" && ! -L "$DEST" ]] || fail "Destination is not a normal directory: $DEST"
    [[ -x "$DEST/system/bin/sh" && -f "$DEST/vendor/lib64/hw/vulkan.radeon.so" ]] || fail 'Existing deployment lacks required Android files'
    cmp -s "$SRC/system/build.prop" "$DEST/system/build.prop" || fail 'Existing deployment differs from packaged Android build'
    [[ "$MODE" == --check ]] || fail "Destination exists; refusing overwrite: $DEST"
    info '[PASS] Matching Android 14 deployment detected'
fi
info "Mode: $MODE"
info "Source: $SRC"
info "Destination: $DEST"
info 'Android: 14 (API 34), target: x86_64'
if [[ "$MODE" == --check ]]; then
    info '[PASS] Local deployment prerequisites satisfied'
    exit 0
fi
if [[ -n "$STAGE_DIR" && ( -e "$STAGE_DIR" || -L "$STAGE_DIR" ) ]]; then
    fail "Stage already exists; refusing to overwrite: $STAGE_DIR"
fi

info 'Building native x86_64 APK extractor'
if [[ "$BUILD_NDK_SHIM" == true ]]; then
    bash "$ROOT/compat_tool/liblepton/ndk_auxv/build.sh" --aosp "$LEPTON_OUTPUT_DIR"
fi
make -C "$EXTRACTOR" install-native
BIN="$EXTRACTOR/bin/apk-info-extractor"
[[ -x "$BIN" ]] || fail 'Native APK extractor build failed'

if [[ -n "$STAGE_DIR" ]]; then
    # Stage everything atomically in a temporary sibling on the same filesystem.
    parent="$(dirname -- "$STAGE_DIR")"
    [[ -d "$parent" ]] || fail "Stage parent directory missing: $parent"
    TEMP="$(mktemp -d "$parent/.lepton-deck-stage.XXXXXXXX")"
    cleanup() { [[ -z "${TEMP:-}" ]] || rm -rf -- "$TEMP"; }
    trap cleanup EXIT
    mkdir -p "$TEMP/compat_tool/images"
    # Never dereference existing compat_tool/images/rootfs symlinks.
    rsync -a --no-owner --no-group --exclude='/images/rootfs' \
        --exclude='/sysbake' --exclude='/sysbake.xattrs' \
        "$ROOT/compat_tool/" "$TEMP/compat_tool/"
    if [[ "$WITH_NDK" == true ]]; then
        bash "$ROOT/image-14/scripts/inject-ndk-translation.sh" --execute \
            --rootfs "$SRC" --payload "$NDK_PAYLOAD" --output "$TEMP/ndk-injection"
        mv -- "$TEMP/ndk-injection/rootfs" "$TEMP/compat_tool/images/rootfs"
        mv -- "$TEMP/ndk-injection" "$TEMP/compat_tool/ndk-provenance"
    else
        mkdir "$TEMP/compat_tool/images/rootfs"
        rsync -a --no-owner --no-group "$SRC/" "$TEMP/compat_tool/images/rootfs/"
    fi
    [[ -x "$TEMP/compat_tool/images/rootfs/system/bin/sh" ]] || fail 'Staged Android shell missing'
    [[ -f "$TEMP/compat_tool/images/rootfs/vendor/lib64/hw/vulkan.radeon.so" ]] || fail 'Staged RADV driver missing'
    [[ -x "$TEMP/compat_tool/liblepton/apk_extractor/bin/apk-info-extractor" ]] || fail 'Staged native extractor missing'
    [[ ! -e "$STAGE_DIR" && ! -L "$STAGE_DIR" ]] || fail 'Stage appeared during copying; refusing overwrite'
    mv -T -- "$TEMP" "$STAGE_DIR"
    TEMP=''
    info "[PASS] New isolated stage: $STAGE_DIR"
    info '[INFO] Next: provision Deck tools; generate fresh sysbake in an isolated environment'
    exit 0
fi

# Original local development path: still refuses to replace a prior rootfs.
info 'Staging Android rootfs in repository compatibility-tool directory'
IMAGE_DIR="$ROOT/compat_tool/images"
mkdir -p "$IMAGE_DIR"
TEMP="$(mktemp -d "$IMAGE_DIR/.rootfs-stage.XXXXXXXX")"
cleanup() { [[ -z "${TEMP:-}" ]] || rm -rf -- "$TEMP"; }
trap cleanup EXIT
rsync -a --no-owner --no-group "$SRC/" "$TEMP/"
[[ -f "$TEMP/system/build.prop" && -x "$TEMP/system/bin/sh" ]] || fail 'Staged rootfs verification failed'
[[ ! -e "$DEST" && ! -L "$DEST" ]] || fail 'Destination appeared during staging; refusing overwrite'
mv -T -- "$TEMP" "$DEST"
TEMP=''
info '[PASS] Local x86_64 compatibility tool staged'
info "[PASS] Rootfs: $DEST"
info "[PASS] APK extractor: $BIN"
