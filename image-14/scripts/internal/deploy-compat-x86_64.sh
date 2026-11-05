#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
CONFIG="$ROOT/.build-env"
EXTRACTOR="$ROOT/compat_tool/liblepton/apk_extractor"
MODE='--check'
STAGE_DIR=''
ROOTFS_SOURCE=''
WITH_NDK=false
NDK_PAYLOAD=''
PACKAGE_ONLY=false
BUNDLE_DIR=''
BUNDLE_ID=''
DECK_IP=''
DECK_REPLACE=''
TRANSFER_ONLY=false
WITH_GAPPS=false
WITH_WIDEVINE=false
GOOGLE_IMAGES=''
SERVICES_JAR=''
TOOL_ID=''
TOOL_NAME=''

fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }
usage() {
    cat <<'HELP'
Usage: bash image-14/scripts/internal/deploy-compat-x86_64.sh [--check|--execute] [--stage-dir DIR] [--rootfs-source DIR] [--with-ndk --ndk-payload DIR] [--with-gapps --google-images DIR] [--with-widevine] [--services-jar FILE]
       bash image-14/scripts/internal/deploy-compat-x86_64.sh --package-only [--check|--execute] --stage-dir DIR --bundle-id ID [--bundle-dir DIR] [--tool-id ID] [--tool-name NAME] [--deck-ip IPv4]
       bash image-14/scripts/internal/deploy-compat-x86_64.sh --transfer-only [--check|--execute] --bundle-id ID --deck-ip IPv4 [--bundle-dir DIR]

--stage-dir DIR: required. Assemble an isolated, complete compatibility-tool
                 stage under DIR/compat_tool, including a fresh rootfs and the
                 native APK extractor. DIR must NOT already exist for --execute
                 and must be outside this repository.
--rootfs-source DIR: stage an alternative Android 14 x86_64 rootfs (requires
                    --stage-dir).
--with-ndk: inject a local ARM64 NDK payload into a NEW stage and build the
            compatibility shim. Requires --stage-dir and a native source rootfs.
--ndk-payload DIR: extracted payload directory (or LEPTON_NDK_PAYLOAD in .build-env).
                  No translator is downloaded. NDK remains opt-in.
--with-gapps: add local Google Play services, GSF, Play Store and matching
              Chrome/Trichrome. Requires --stage-dir and --google-images.
              No downloads; Google services stay opt-in.
--google-images DIR: extracted API 34 system.img, product.img, system_ext.img
                     (and vendor.img for --with-widevine).
--with-widevine: add Widevine L3 (software DRM) from the same local Google
                 image's vendor.img. Opt-in; nothing is downloaded.
--services-jar FILE: materialize a tested framework override in the new stage;
                     discard stale services DEX preoptimization files.
--tool-id ID: unique Steam tool ID for side-by-side installation. GApps bundles
              default to lepton_gapps_<bundle-id>; legacy defaults are preserved.
--tool-name NAME: Steam display name for the packaged tool.
--check: inspect source and existing destination; never modify files.
--execute: refuse to overwrite existing rootfs/stage or Steam installation.
--package-only: package an existing complete stage with fresh sysbake and tools;
                does not rebuild images, generate sysbake or replace the stage.
--bundle-dir DIR: archive destination (default: the workspace's bundles/).
--bundle-id ID: required archive identifier for packaging/transfer.
--deck-ip IPv4: transfer the archive/checksum after packaging, only in --execute.
--deck-replace TOOL_ID: after transfer, install on the Deck over SSH, overwriting
                 the existing install TOOL_ID (its Steam shortcuts keep working).
--transfer-only: verify/send an existing archive without repackaging.
Packaging/transfer --check validates inputs without writing or connecting remotely.

Steam Deck host utilities and fresh sysbake require separate provisioning:
  image-14/scripts/internal/provision-deck-tools.sh --stage-dir DIR --execute
HELP
}
while (($#)); do
    case "$1" in
        --check|--execute) MODE="$1"; shift ;;
        --stage-dir) (($# >= 2)) || fail '--stage-dir requires a path'; STAGE_DIR="$2"; shift 2 ;;
        --rootfs-source) (($# >= 2)) || fail '--rootfs-source requires a path'; ROOTFS_SOURCE="$2"; shift 2 ;;
        --with-ndk) WITH_NDK=true; shift ;;
        --with-gapps) WITH_GAPPS=true; shift ;;
        --with-widevine) WITH_WIDEVINE=true; shift ;;
        --google-images) GOOGLE_IMAGES="${2:?}"; shift 2 ;;
        --services-jar) SERVICES_JAR="${2:?}"; shift 2 ;;
        --tool-id) TOOL_ID="${2:?}"; shift 2 ;;
        --tool-name) TOOL_NAME="${2:?}"; shift 2 ;;
        --ndk-payload) (($# >= 2)) || fail '--ndk-payload requires a path'; NDK_PAYLOAD="$2"; shift 2 ;;
        --package-only) PACKAGE_ONLY=true; shift ;;
        --bundle-dir) (($# >= 2)) || fail '--bundle-dir requires a path'; BUNDLE_DIR="$2"; shift 2 ;;
        --bundle-id) (($# >= 2)) || fail '--bundle-id requires ID'; BUNDLE_ID="$2"; shift 2 ;;
        --deck-ip) (($# >= 2)) || fail '--deck-ip requires IPv4'; DECK_IP="$2"; shift 2 ;;
        --deck-replace) DECK_REPLACE="${2:?--deck-replace requires a tool ID}"; shift 2 ;;
        --transfer-only) TRANSFER_ONLY=true; PACKAGE_ONLY=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done
# shellcheck source=/dev/null
if [[ -f "$CONFIG" ]]; then source "$CONFIG";
elif [[ "$PACKAGE_ONLY" == false ]]; then fail 'Missing .build-env'; fi
if [[ -n "${LEPTON_OUTPUT_DIR:-}" ]]; then
    source "$ROOT/image-14/scripts/lib/workspace.sh"
    lepton_workspace
fi
if [[ "$PACKAGE_ONLY" == true ]]; then
    [[ -z "$ROOTFS_SOURCE" && -z "$NDK_PAYLOAD" && "$WITH_NDK" == false && "$WITH_GAPPS" == false && "$WITH_WIDEVINE" == false && -z "$GOOGLE_IMAGES" && -z "$SERVICES_JAR" ]] || fail 'Packaging cannot be combined with rootfs/NDK staging options'
    [[ -n "$BUNDLE_ID" ]] || fail '--bundle-id is required for packaging/transfer'
    STAGE_DIR="${STAGE_DIR:-${LEPTON_DECK_STAGE_DIR:-}}"
    [[ -n "$BUNDLE_DIR" || -n "${LEPTON_DECK_BUNDLE_DIR:-}" ]] || fail 'Set LEPTON_OUTPUT_DIR in .build-env or pass --bundle-dir'
    BUNDLE_DIR="${BUNDLE_DIR:-$LEPTON_DECK_BUNDLE_DIR}"
    source "$ROOT/image-14/scripts/lib/deck-bundle.sh"
    if [[ -n "$DECK_REPLACE" ]]; then
        [[ "$DECK_REPLACE" =~ ^[A-Za-z0-9_]{1,96}$ ]] || fail 'Invalid --deck-replace tool ID'
        [[ -n "$DECK_IP" ]] || fail '--deck-replace requires --deck-ip'
    fi
    package_deck_bundle "$ROOT" "$STAGE_DIR" "$BUNDLE_DIR" "$BUNDLE_ID" "$DECK_IP" "$TRANSFER_ONLY" "$MODE" "$TOOL_ID" "$TOOL_NAME" "$DECK_REPLACE"
    exit 0
fi
[[ -z "$BUNDLE_DIR" && -z "$BUNDLE_ID" && -z "$DECK_IP" && -z "$DECK_REPLACE" && -z "$TOOL_ID" && -z "$TOOL_NAME" ]] || fail 'Bundle options require --package-only or --transfer-only'
[[ -n "$STAGE_DIR" ]] || fail '--stage-dir is required (make-deck-bundle-x86_64.sh sets it)'
[[ "$WITH_NDK" == true || -z "$NDK_PAYLOAD" ]] || fail '--ndk-payload requires --with-ndk'
if [[ "$WITH_NDK" == true ]]; then
    [[ -n "$STAGE_DIR" ]] || fail '--with-ndk requires --stage-dir'
    NDK_PAYLOAD="${NDK_PAYLOAD:-${LEPTON_NDK_PAYLOAD:-}}"
    [[ -n "$NDK_PAYLOAD" ]] || fail '--with-ndk requires --ndk-payload or LEPTON_NDK_PAYLOAD'
    NDK_PAYLOAD="$(realpath -e -- "$NDK_PAYLOAD")" || fail 'NDK payload not found'
fi
[[ "$WITH_GAPPS" == true || "$WITH_WIDEVINE" == true || -z "$GOOGLE_IMAGES" ]] || fail '--google-images requires --with-gapps or --with-widevine'
if [[ "$WITH_WIDEVINE" == true ]]; then
    [[ -n "$STAGE_DIR" ]] || fail '--with-widevine requires --stage-dir'
    GOOGLE_IMAGES="$(realpath -e -- "${GOOGLE_IMAGES:-${LEPTON_GOOGLE_IMAGES:-}}")" || fail 'Local Google logical images required for Widevine'
    source "$ROOT/image-14/scripts/lib/google-services.sh"
    widevine_check "$GOOGLE_IMAGES"
fi
if [[ "$WITH_GAPPS" == true ]]; then
    [[ -n "$STAGE_DIR" ]] || fail '--with-gapps requires --stage-dir'
    GOOGLE_IMAGES="$(realpath -e -- "${GOOGLE_IMAGES:-${LEPTON_GOOGLE_IMAGES:-}}")" || fail 'Local Google logical images required'
    source "$ROOT/image-14/scripts/lib/google-services.sh"
    google_services_check "$GOOGLE_IMAGES" true true
fi
if [[ -n "$SERVICES_JAR" ]]; then
    [[ -n "$STAGE_DIR" ]] || fail '--services-jar requires --stage-dir'
    SERVICES_JAR="$(realpath -e -- "$SERVICES_JAR")" || fail 'Services jar missing'
    python3 - "$SERVICES_JAR" <<'PYJAR'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as jar:
    if 'classes.dex' not in jar.namelist():
        raise SystemExit('Services jar has no classes.dex')
PYJAR
fi
if [[ -n "$ROOTFS_SOURCE" ]]; then
    [[ -n "$STAGE_DIR" ]] || fail '--rootfs-source requires --stage-dir'
    [[ -d "$ROOTFS_SOURCE" && ! -L "$ROOTFS_SOURCE" ]] || fail "Alternative rootfs must be a real directory: $ROOTFS_SOURCE"
    SRC="$(realpath -e -- "$ROOTFS_SOURCE")" || fail "Cannot resolve alternative rootfs: $ROOTFS_SOURCE"
else
    SRC="$(realpath -m -- "${LEPTON_ROOTFS_DIR:?Set LEPTON_OUTPUT_DIR in .build-env}")"
fi
[[ -d "$SRC" && ! -L "$SRC" ]] || fail "Packaged Android rootfs missing: $SRC"
[[ -x "$SRC/system/bin/sh" ]] || fail 'Android shell missing'
[[ -f "$SRC/system/build.prop" ]] || fail 'Android build.prop missing'
[[ -f "$SRC/vendor/lib64/hw/vulkan.radeon.so" ]] || fail 'AMD Vulkan driver missing'
grep -qx 'ro.build.version.sdk=34' "$SRC/system/build.prop" || fail 'Expected Android API 34'
if [[ "$WITH_GAPPS" == true ]]; then
    google_services_framework_check "${SERVICES_JAR:-$SRC/system/framework/services.jar}"
fi
[[ -f "$ROOT/compat_tool/lepton" ]] || fail 'Lepton launcher missing'
[[ -f "$EXTRACTOR/Makefile" ]] || fail 'APK extractor Makefile missing'
[[ "$(uname -m)" == x86_64 ]] || fail 'Requires x86_64 host'
for tool in cargo cc make rsync realpath; do
    command -v "$tool" >/dev/null 2>&1 || fail "Missing dependency: $tool"
done
source "$ROOT/compat_tool/liblepton/ndk_auxv/runtime.sh"
BUILD_NDK_SHIM=false
if [[ "$WITH_NDK" == true ]] || ndk_compat_supported "$SRC"; then
    [[ -x "${LEPTON_AOSP_DIR}/prebuilts/clang/host/linux-x86/clang-r510928/bin/clang" ]] || fail 'AOSP Clang required to build standard NDK compatibility shim'
    BUILD_NDK_SHIM=true
fi

STAGE_DIR="$(realpath -m -- "$STAGE_DIR")"
[[ "$STAGE_DIR" != / && "$STAGE_DIR" != "$ROOT" ]] || fail 'Unsafe stage destination'
[[ "$STAGE_DIR" != "$ROOT/"* && "$STAGE_DIR" != "$SRC" && "$STAGE_DIR" != "$SRC/"* ]] || fail 'Stage must not be inside repository or rootfs'
[[ "$SRC" != "$STAGE_DIR/"* ]] || fail 'Rootfs source must not be inside destination stage'
[[ -z "$GOOGLE_IMAGES" || "$GOOGLE_IMAGES" != "$STAGE_DIR/"* ]] || fail 'Google images cannot be inside stage'
DEST="$STAGE_DIR/compat_tool/images/rootfs"

if [[ "$WITH_NDK" == true ]]; then
    bash "$ROOT/image-14/scripts/internal/inject-ndk-translation.sh" --check \
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
if [[ -e "$STAGE_DIR" || -L "$STAGE_DIR" ]]; then
    fail "Stage already exists; refusing to overwrite: $STAGE_DIR"
fi

info 'Building native x86_64 APK extractor'
if [[ "$BUILD_NDK_SHIM" == true ]]; then
    bash "$ROOT/compat_tool/liblepton/ndk_auxv/build.sh" --aosp "$LEPTON_AOSP_DIR"
fi
make -C "$EXTRACTOR" install-native
BIN="$EXTRACTOR/bin/apk-info-extractor"
[[ -x "$BIN" ]] || fail 'Native APK extractor build failed'

# Stage everything atomically in a temporary sibling on the same filesystem.
parent="$(dirname -- "$STAGE_DIR")"
[[ -d "$parent" ]] || fail "Stage parent directory missing: $parent"
TEMP="$(mktemp -d "$parent/.lepton-deck-stage.XXXXXXXX")"
# Own group, no inherited setgid: a shared folder's setgid group cannot be
# mapped into rootless Podman and breaks the Android container's overlay.
chgrp "$(id -g)" "$TEMP" && chmod g-s "$TEMP"
cleanup() { [[ -z "${TEMP:-}" ]] || rm -rf -- "$TEMP"; }
trap cleanup EXIT
touch "$TEMP/.find-ignore"
mkdir -p "$TEMP/compat_tool/images"
# Never dereference existing compat_tool/images/rootfs symlinks.
rsync -a --no-owner --no-group --exclude='/images/rootfs' \
    --exclude='/sysbake' --exclude='/sysbake.xattrs' --exclude='/liblepton/apk_extractor/target/' --exclude=__pycache__/ \
    "$ROOT/compat_tool/" "$TEMP/compat_tool/"
if [[ "$WITH_NDK" == true ]]; then
    bash "$ROOT/image-14/scripts/internal/inject-ndk-translation.sh" --execute \
        --rootfs "$SRC" --payload "$NDK_PAYLOAD" --output "$TEMP/ndk-injection"
    mv -- "$TEMP/ndk-injection/rootfs" "$TEMP/compat_tool/images/rootfs"
    mv -- "$TEMP/ndk-injection" "$TEMP/compat_tool/ndk-provenance"
else
    mkdir "$TEMP/compat_tool/images/rootfs"
    rsync -a --no-owner --no-group "$SRC/" "$TEMP/compat_tool/images/rootfs/"
fi
if [[ -n "$SERVICES_JAR" ]]; then
    framework="$TEMP/compat_tool/images/rootfs/system/framework"
    install -m 644 "$SERVICES_JAR" "$framework/services.jar"
    for abi in x86 x86_64 arm arm64; do
        for suffix in odex vdex art; do rm -f -- "$framework/oat/$abi/services.$suffix"; done
    done
    rm -f -- "$framework/services.jar.prof" "$framework/services.jar.bprof"
    mkdir -p "$TEMP/compat_tool/provenance/framework"
    sha256sum "$SERVICES_JAR" > "$TEMP/compat_tool/provenance/framework/services-override.sha256"
fi
if [[ "$WITH_GAPPS" == true ]]; then
    google_services_inject "$TEMP/compat_tool/images/rootfs" "$GOOGLE_IMAGES" true true "$TEMP/compat_tool/provenance/gapps"
fi
if [[ "$WITH_WIDEVINE" == true ]]; then
    widevine_inject "$TEMP/compat_tool/images/rootfs" "$GOOGLE_IMAGES" "$TEMP/compat_tool/provenance/widevine"
    info '[PASS] Widevine L3 added (vendor/apex/com.google.android.widevine)'
fi
[[ -x "$TEMP/compat_tool/images/rootfs/system/bin/sh" ]] || fail 'Staged Android shell missing'
[[ -f "$TEMP/compat_tool/images/rootfs/vendor/lib64/hw/vulkan.radeon.so" ]] || fail 'Staged RADV driver missing'
[[ -x "$TEMP/compat_tool/liblepton/apk_extractor/bin/apk-info-extractor" ]] || fail 'Staged native extractor missing'
[[ ! -e "$STAGE_DIR" && ! -L "$STAGE_DIR" ]] || fail 'Stage appeared during copying; refusing overwrite'
mv -T -- "$TEMP" "$STAGE_DIR"
TEMP=''
info "[PASS] New isolated stage: $STAGE_DIR"
info '[INFO] Next: provision Deck tools; generate fresh sysbake in an isolated environment'
