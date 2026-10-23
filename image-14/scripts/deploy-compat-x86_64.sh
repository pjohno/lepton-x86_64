#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CONFIG="$ROOT/.build-env"
DEST="$ROOT/compat_tool/images/rootfs"
EXTRACTOR="$ROOT/compat_tool/liblepton/apk_extractor"
MODE="${1:---check}"

die() {
    printf '[FAIL] %s\n' "$*" >&2
    exit 1
}

info() {
    printf '[INFO] %s\n' "$*"
}

[[ $# -le 1 ]] || die "Usage: $0 --check | --execute"

case "$MODE" in
    --check|--execute) ;;
    *) die "Usage: $0 --check | --execute" ;;
esac

[[ -f "$CONFIG" ]] || die "Missing .build-env"
source "$CONFIG"

SRC="$(realpath -m \
    "${LEPTON_OUTPUT_DIR:?}/repro-rootfs-auto/rootfs")"

[[ -d "$SRC" && ! -L "$SRC" ]] ||
    die "Packaged Android rootfs missing: $SRC"

[[ -x "$SRC/system/bin/sh" ]] ||
    die "Android shell missing"

[[ -f "$SRC/system/build.prop" ]] ||
    die "Android build.prop missing"

[[ -f "$SRC/vendor/lib64/hw/vulkan.radeon.so" ]] ||
    die "AMD Vulkan driver missing"

grep -qx 'ro.build.version.sdk=34' \
    "$SRC/system/build.prop" ||
    die "Expected Android API 34"

[[ -f "$ROOT/compat_tool/lepton" ]] ||
    die "Lepton launcher missing"

[[ -f "$EXTRACTOR/Makefile" ]] ||
    die "APK extractor Makefile missing"

[[ "$(uname -m)" == x86_64 ]] ||
    die "This deployment script requires an x86_64 host"

for tool in cargo cc make rsync realpath; do
    command -v "$tool" >/dev/null 2>&1 ||
        die "Missing dependency: $tool"
done

if [[ -e "$DEST" || -L "$DEST" ]]; then
    [[ -d "$DEST" && ! -L "$DEST" ]] ||
        die "Destination is not a normal directory: $DEST"

    if [[ "$MODE" == --execute ]]; then
        die "Destination already exists; refusing to overwrite: $DEST"
    fi

    [[ -x "$DEST/system/bin/sh" ]] ||
        die "Existing deployment has no Android shell"

    [[ -f "$DEST/vendor/lib64/hw/vulkan.radeon.so" ]] ||
        die "Existing deployment is missing AMD Vulkan"

    cmp -s "$SRC/system/build.prop" "$DEST/system/build.prop" ||
        die "Existing deployment differs from packaged Android build"

    info "[PASS] Existing Android 14 deployment detected"
fi

info "Mode: $MODE"
info "Source: $SRC"
info "Destination: $DEST"
info "Android: 14 (API 34)"
info "Target architecture: x86_64"

if [[ "$MODE" == --check ]]; then
    info "[PASS] Local deployment prerequisites satisfied"
    exit 0
fi

info "Building native x86_64 APK extractor"
make -C "$EXTRACTOR" install-native

BIN="$EXTRACTOR/bin/apk-info-extractor"
[[ -x "$BIN" ]] ||
    die "Native APK extractor build failed"

info "Staging Android rootfs"

IMAGE_DIR="$ROOT/compat_tool/images"
mkdir -p "$IMAGE_DIR"

TEMP="$(mktemp -d "$IMAGE_DIR/.rootfs-stage.XXXXXXXX")"

cleanup() {
    if [[ -n "${TEMP:-}" && -d "$TEMP" ]]; then
        rm -rf -- "$TEMP"
    fi
}
trap cleanup EXIT

rsync -a --no-owner --no-group \
    "$SRC/" "$TEMP/"

[[ -f "$TEMP/system/build.prop" ]] ||
    die "Staged rootfs verification failed"

[[ -x "$TEMP/system/bin/sh" ]] ||
    die "Staged Android shell missing"

[[ ! -e "$DEST" && ! -L "$DEST" ]] ||
    die "Destination appeared during staging; refusing overwrite"

mv -T -- "$TEMP" "$DEST"
TEMP=""

info "[PASS] Local x86_64 compatibility tool staged"
info "[PASS] Rootfs: $DEST"
info "[PASS] APK extractor: $BIN"
info "[INFO] Ready for repository rsync"
