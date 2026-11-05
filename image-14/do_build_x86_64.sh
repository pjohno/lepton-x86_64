#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Complete fresh Android 14 x86_64 -> Steam Deck bundle workflow.
# Never uses Valve's destructive CI sysbake helpers or deploys to Steam.
set -Eeuo pipefail

IMAGE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd -- "$IMAGE_DIR/.." && pwd -P)"
CONFIG="$REPO/.build-env"
MODE=''
BUNDLE_ID=''
SYSBAKE_TIMEOUT=600
SYSBAKE_RENDERING=software
WITH_NDK=false
NDK_PAYLOAD=''
WITH_GAPPS=false
GOOGLE_IMAGES=''
TOOL_ID=''
TOOL_NAME=''

usage() {
    cat <<'HELP'
Usage:
  bash image-14/do_build_x86_64.sh --check --bundle-id ID [--sysbake-timeout SECONDS]
  bash image-14/do_build_x86_64.sh --execute --bundle-id ID [--sysbake-timeout SECONDS]
  Optional: --with-ndk --ndk-payload /path/to/extracted/payload
            --with-gapps --google-images /path/to/logical-partitions
            --tool-id lepton_unique_id --tool-name "Lepton GApps"
            --sysbake-rendering software|amd (default software)
GApps includes Play services, GSF, Play Store, Chrome and Trichrome, extracted
only from local API 34 images. GApps and NDK remain independent opt-ins.

Set LEPTON_OUTPUT_DIR (the workspace) in the repository's ignored .build-env;
its aosp/ checkout must not exist yet before running either command.
The other build scripts source the same .build-env; this wrapper does not
silently override their settings or reuse an existing AOSP build.

--check: inspect host requirements and fresh output paths; change nothing.
--execute: prepare AOSP, compile system/vendor, package rootfs, stage host
           files, provision Deck utilities, generate isolated sysbake, and
           create/check a local Steam Deck bundle.

The Ubuntu 26.04 builder is created from .buildscripts_x86_64/ if absent.
This command NEVER transfers to Steam Deck or changes Steam installations.
HELP
}
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }
pass() { printf '[PASS] %s\n' "$*"; }
step() { printf '\n=== %s ===\n' "$*"; }

while (( $# )); do
    case "$1" in
        --check|--execute)
            [[ -z "$MODE" ]] || fail 'Choose exactly one mode'
            MODE="$1"; shift ;;
        --bundle-id)
            (( $# >= 2 )) || fail '--bundle-id requires an ID'
            BUNDLE_ID="$2"; shift 2 ;;
        --sysbake-timeout)
            (( $# >= 2 )) || fail '--sysbake-timeout requires seconds'
            SYSBAKE_TIMEOUT="$2"; shift 2 ;;
        --sysbake-rendering)
            (( $# >= 2 )) || fail '--sysbake-rendering requires software or amd'
            SYSBAKE_RENDERING="$2"; shift 2 ;;
        --with-ndk) WITH_NDK=true; shift ;;
        --with-gapps) WITH_GAPPS=true; shift ;;
        --google-images) GOOGLE_IMAGES="${2:?}"; shift 2 ;;
        --tool-id) TOOL_ID="${2:?}"; shift 2 ;;
        --tool-name) TOOL_NAME="${2:?}"; shift 2 ;;
        --ndk-payload)
            (( $# >= 2 )) || fail '--ndk-payload requires directory'
            NDK_PAYLOAD="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "Unknown argument: $1" ;;
    esac
done
[[ -n "$MODE" && -n "$BUNDLE_ID" ]] || { usage >&2; fail 'Mode and --bundle-id are required'; }
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && ${#BUNDLE_ID} -le 64 ]] ||
    fail 'Bundle ID must be 1-64 letters, digits, dots, hyphens or underscores'
[[ "$SYSBAKE_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || fail 'Invalid sysbake timeout'
[[ "$SYSBAKE_RENDERING" == software || "$SYSBAKE_RENDERING" == amd ]] || fail 'Invalid sysbake rendering mode'
[[ $(id -u) -ne 0 ]] || fail 'Run as a normal user (without sudo)'
[[ $(uname -m) == x86_64 ]] || fail 'x86_64 build host required'
[[ -f "$CONFIG" ]] || fail "Missing $CONFIG"
# .build-env is a trusted, developer-maintained shell configuration.
# shellcheck source=/dev/null
source "$CONFIG"
: "${LEPTON_OUTPUT_DIR:?Set LEPTON_OUTPUT_DIR in .build-env}"
source "$IMAGE_DIR/scripts/lib/workspace.sh"
lepton_workspace
: "${LEPTON_BUILD_TARGET:?Set LEPTON_BUILD_TARGET in .build-env}"
[[ "$WITH_NDK" == true || -z "$NDK_PAYLOAD" ]] || fail '--ndk-payload requires --with-ndk'
DEPLOY_ARGS=()
if [[ "$WITH_NDK" == true ]]; then
    NDK_PAYLOAD="$(realpath -e -- "${NDK_PAYLOAD:-${LEPTON_NDK_PAYLOAD:-}}")" || fail 'An existing local NDK payload is required'
    [[ -d "$NDK_PAYLOAD" && -f "$(dirname "$NDK_PAYLOAD")/SHA256SUMS" && -f "$NDK_PAYLOAD/system/lib64/libndk_translation.so" ]] || fail 'Incomplete extracted NDK payload'
    (cd "$NDK_PAYLOAD" && sha256sum -c "$(dirname "$NDK_PAYLOAD")/SHA256SUMS" >/dev/null) || fail 'NDK payload hash verification failed'
    DEPLOY_ARGS=(--with-ndk --ndk-payload "$NDK_PAYLOAD")
fi

[[ "$WITH_GAPPS" == true || -z "$GOOGLE_IMAGES" ]] || fail '--google-images requires --with-gapps'
if [[ "$WITH_GAPPS" == true ]]; then
    GOOGLE_IMAGES="$(realpath -e -- "${GOOGLE_IMAGES:-${LEPTON_GOOGLE_IMAGES:-}}")" || fail 'Local Google logical images required'
    source "$IMAGE_DIR/scripts/lib/google-services.sh"
    google_services_check "$GOOGLE_IMAGES" true true
    DEPLOY_ARGS+=(--with-gapps --google-images "$GOOGLE_IMAGES")
fi
BUNDLE_ARGS=()
if [[ -n "$TOOL_ID" ]]; then
    [[ "$TOOL_ID" =~ ^[A-Za-z0-9_]{1,96}$ ]] || fail 'Invalid tool ID'
    BUNDLE_ARGS+=(--tool-id "$TOOL_ID")
fi
if [[ -n "$TOOL_NAME" ]]; then
    [[ "$TOOL_NAME" != *$'\n'* && "$TOOL_NAME" != *$'\r'* ]] || fail 'Invalid tool name'
    BUNDLE_ARGS+=(--tool-name "$TOOL_NAME")
fi

BUILDER="${LEPTON_BUILD_CONTAINER:-lepton-builder-ubuntu26:latest}"
[[ "$BUILDER" == 'lepton-builder-ubuntu26:latest' ]] ||
    fail 'The clean AMD x86_64 workflow requires lepton-builder-ubuntu26:latest'
# Child scripts retain legacy defaults when invoked directly. The full pipeline
# must pass its selected builder through even with an older .build-env.
export LEPTON_BUILD_CONTAINER="$BUILDER"
[[ "$LEPTON_BUILD_TARGET" == 'aosp_lepton_x86_64-ap2a-userdebug' ]] ||
    fail 'Unexpected Android build target'

TARGET="$LEPTON_AOSP_DIR"
TARGET_PARENT="$(dirname -- "$TARGET")"
LOG_DIR="$LEPTON_LOG_DIR"
# prepare-x86_64.sh --execute creates the workspace if it does not exist yet.
while [[ ! -d "$TARGET_PARENT" && "$TARGET_PARENT" != / ]]; do TARGET_PARENT="$(dirname -- "$TARGET_PARENT")"; done
[[ "$TARGET" != / && "$TARGET" != "$HOME" && "$TARGET" != "$REPO" &&
   "$TARGET" != "$REPO/"* && "$REPO" != "$TARGET/"* ]] ||
    fail 'Unsafe Android source/output directory'
[[ "$LOG_DIR" != / && "$LOG_DIR" != "$TARGET" && "$LOG_DIR" != "$TARGET/"* &&
   "$TARGET" != "$LOG_DIR/"* ]] || fail 'Logs and build output must be separate'
[[ -d "$TARGET_PARENT" && -w "$TARGET_PARENT" ]] ||
    fail "Output parent does not exist or is not writable: $TARGET_PARENT"
[[ ! -e "$TARGET" && ! -L "$TARGET" ]] ||
    fail "Refusing to reuse an existing Android checkout: $TARGET"

STAGE="$LEPTON_STAGES_DIR/$BUNDLE_ID"
BUNDLE_DIR="$LEPTON_DECK_BUNDLE_DIR"
[[ "$BUNDLE_DIR" != / && "$BUNDLE_DIR" != "$HOME" &&
   "$BUNDLE_DIR" != "$REPO" && "$BUNDLE_DIR" != "$STAGE" &&
   "$BUNDLE_DIR" != "$STAGE/"* ]] || fail 'Unsafe bundle output directory'
ARCHIVE="$BUNDLE_DIR/lepton-x86_64-steamdeck-$BUNDLE_ID.tar.gz"
[[ ! -e "$ARCHIVE" && ! -L "$ARCHIVE" &&
   ! -e "$ARCHIVE.sha256" && ! -L "$ARCHIVE.sha256" ]] ||
    fail "Bundle already exists: $ARCHIVE"

BUILDER_DIR="$IMAGE_DIR/.buildscripts_x86_64"
BUILDER_FILE="$BUILDER_DIR/Containerfile.ubuntu26"
[[ -f "$BUILDER_FILE" ]] ||
    fail "Missing x86_64 builder Containerfile: $BUILDER_FILE (apply directory-layout change first)"
[[ -f "$IMAGE_DIR/scripts/internal/provision-deck-tools.sh" &&
   -f "$BUILDER_DIR/Containerfile.deck-tools" ]] || fail 'Missing Deck tools source files'

for cmd in bash git podman rsync realpath df awk grep sha256sum curl unzip \
           python3 make cargo cc weston systemctl getfattr setfattr \
           timeout flock fuse-overlayfs simg2img sqfs2tar fuse2fs \
           fusermount3 tar gzip; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Missing host dependency: $cmd"
done
[[ -c /dev/fuse && -r /dev/fuse && -w /dev/fuse ]] ||
    fail 'FUSE is not accessible to the current user'

info "Source commit: $(git -C "$REPO" rev-parse HEAD)"
info "Android checkout (must be new): $TARGET"
info "Builder: $BUILDER"
info "Stage: $STAGE"
info "Bundle: $ARCHIVE"
info "Sysbake: $SYSBAKE_RENDERING rendering, maximum runtime ${SYSBAKE_TIMEOUT}s"

if podman image exists "$BUILDER"; then
    pass "Builder available: $(podman image inspect "$BUILDER" --format '{{.Id}}')"
else
    info "Builder absent; --execute will build it from $BUILDER_FILE"
fi

if [[ "$MODE" == --check ]]; then
    # Valve-derived preflight requires an existing builder. Run it when possible;
    # otherwise --execute must first build that builder.
    if podman image exists "$BUILDER"; then
        bash "$IMAGE_DIR/scripts/preflight-x86_64.sh" fresh
        bash "$IMAGE_DIR/scripts/prepare-x86_64.sh" --check
    else
        info 'Full preflight requires the builder image; it will run after builder creation'
    fi
    pass 'Fresh pipeline paths/dependencies checked; no changes made'
    exit 0
fi

if ! podman image exists "$BUILDER"; then
    step 'Build Ubuntu 26.04 host toolchain (builder image not present)'
    podman build -t "$BUILDER" -f "$BUILDER_FILE" "$BUILDER_DIR"
fi

step 'Preflight: new AOSP checkout'
bash "$IMAGE_DIR/scripts/preflight-x86_64.sh" fresh
bash "$IMAGE_DIR/scripts/prepare-x86_64.sh" --check

step 'Prepare Android 14 source and patches'
bash "$IMAGE_DIR/scripts/prepare-x86_64.sh" --execute
bash "$IMAGE_DIR/scripts/preflight-x86_64.sh" existing

step 'Compile fresh x86_64 system/vendor images'
bash "$IMAGE_DIR/scripts/build-images-x86_64.sh" --check
bash "$IMAGE_DIR/scripts/build-images-x86_64.sh" --execute
# The full preflight applies the initial free-space threshold after compilation,
# which may be too strict for rootfs extraction; validate the outputs directly.
for part in system vendor; do
    [[ -s "$TARGET/out/target/product/lepton_x86_64/$part.img" ]] ||
        fail "Missing newly compiled Android image: $part.img"
done

# build-images-x86_64.sh also packaged the rootfs (workspace rootfs/).
[[ -f "$LEPTON_ROOTFS_DIR/system/build.prop" ]] ||
    fail 'Missing packaged rootfs after the image build'

step 'Create standalone compatibility-tool stage'
mkdir -p -- "$LEPTON_STAGES_DIR" "$BUNDLE_DIR"
bash "$IMAGE_DIR/scripts/internal/deploy-compat-x86_64.sh" --check --stage-dir "$STAGE" "${DEPLOY_ARGS[@]}"
bash "$IMAGE_DIR/scripts/internal/deploy-compat-x86_64.sh" --execute --stage-dir "$STAGE" "${DEPLOY_ARGS[@]}"

step 'Build and verify Steam Deck tools'
bash "$IMAGE_DIR/scripts/internal/provision-deck-tools.sh" --execute --stage-dir "$STAGE"
bash "$IMAGE_DIR/scripts/internal/provision-deck-tools.sh" --check --stage-dir "$STAGE"

step 'Bake Android system data with private Podman storage'
bash "$IMAGE_DIR/scripts/internal/sysbake-isolated-x86_64.sh" --check --stage-dir "$STAGE" --rendering "$SYSBAKE_RENDERING"
bash "$IMAGE_DIR/scripts/internal/sysbake-isolated-x86_64.sh" --execute \
    --stage-dir "$STAGE" --timeout "$SYSBAKE_TIMEOUT" --rendering "$SYSBAKE_RENDERING"

step 'Record build provenance in staged bundle'
MANIFEST="$TARGET/.lepton-resolved-manifest.xml"
[[ -s "$MANIFEST" ]] || fail 'Prepared AOSP manifest snapshot is missing'
PRODUCT="$TARGET/out/target/product/lepton_x86_64"
for part in system vendor; do
    [[ -s "$PRODUCT/$part.img" ]] || fail "Compiled Android image missing: $part.img"
done
[[ -s "$STAGE/compat_tool/sysbake/system/packages.xml" &&
   -s "$STAGE/compat_tool/sysbake.xattrs" ]] || fail 'Baked Android data missing'

PROVENANCE="$STAGE/tools/BUILD-PROVENANCE.txt"
{
    printf 'Lepton x86_64 Android 14 build provenance\n'
    printf 'Source commit: %s\n' "$(git -C "$REPO" rev-parse HEAD)"
    if [[ -n "$(git -C "$REPO" status --porcelain)" ]]; then
        printf 'Source working tree: dirty (not an exact source snapshot)\n'
    else
        printf 'Source working tree: clean\n'
    fi
    printf 'AOSP resolved manifest SHA256: %s\n' "$(sha256sum "$MANIFEST" | awk '{print $1}')"
    printf 'Android target: %s\n' "$LEPTON_BUILD_TARGET"
    printf 'Builder image ID: %s\n' "$(podman image inspect "$BUILDER" --format '{{.Id}}')"
    printf 'Android system.img SHA256: %s\n' "$(sha256sum "$PRODUCT/system.img" | awk '{print $1}')"
    printf 'Android vendor.img SHA256: %s\n' "$(sha256sum "$PRODUCT/vendor.img" | awk '{print $1}')"
    printf 'Baked packages.xml SHA256: %s\n' "$(sha256sum "$STAGE/compat_tool/sysbake/system/packages.xml" | awk '{print $1}')"
    printf 'Optional GApps: %s; NDK: %s\n' "$WITH_GAPPS" "$WITH_NDK"
    printf 'Google payload/image hashes: compat_tool/provenance/gapps/ (when enabled)\n'
    printf 'Google ADB and inotify versions: see tools/PROVENANCE.txt\n'
} > "$PROVENANCE"

step 'Package the distributable bundle (local only)'
bash "$IMAGE_DIR/scripts/internal/deploy-compat-x86_64.sh" --package-only --execute \
    --stage-dir "$STAGE" --bundle-dir "$BUNDLE_DIR" --bundle-id "$BUNDLE_ID" "${BUNDLE_ARGS[@]}"
( cd "$BUNDLE_DIR" && sha256sum -c "$(basename -- "$ARCHIVE").sha256" )
gzip -t "$ARCHIVE"
# Enumerate the archive fully, checking both critical content and excluded work.
tar -tzf "$ARCHIVE" | awk '
    /^\.\/compat_tool\/images\/rootfs\/system\/build.prop$/ {rootfs=1}
    /^\.\/compat_tool\/sysbake\/system\/packages.xml$/ {sysbake=1}
    /^\.\/compat_tool\/sysbake.xattrs$/ {xattrs=1}
    /^\.\/tools\/platform-tools\/adb$/ {adb=1}
    /^\.\/tools\/bin\/inotifywait$/ {inotify=1}
    /^\.\/tools\/BUILD-PROVENANCE.txt$/ {provenance=1}
    /\.sysbake-work\./ || /podman-storage/ {unwanted++}
    END {
        if (!rootfs || !sysbake || !xattrs || !adb || !inotify || !provenance || unwanted) {
            print "[FAIL] Archive content validation failed" > "/dev/stderr"
            exit 1
        }
        print "[PASS] Archive has rootfs, sysbake, attributes, Deck tools, and provenance; no temporary sysbake work"
    }
'
pass "Local Android 14 x86_64 Steam Deck bundle: $ARCHIVE"
info 'No transfer, Steam registration, or existing installation was modified.'
