#!/usr/bin/env bash
# Incrementally build services.jar with LocaleManagerService restored.
# Source is overlaid read-only in the builder; existing Android build outputs
# are updated, but source files, packaged images and runtime stages are untouched.
set -Eeuo pipefail
AOSP=''
OUTPUT=''
MODE=--check
BUILDER=lepton-builder-ubuntu26:latest
JOBS=6
RESTORE_ONLY=false
WITH_GOOGLE_SERVICES=false
FIX_VIEW_INTENTS=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
VIEW_SOURCE=frameworks/base/services/core/java/com/android/server/wm/ActivityStarter.java
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
while (($#)); do
    case "$1" in
        --aosp) AOSP="${2:?}"; shift 2 ;;
        --output-dir) OUTPUT="${2:?}"; shift 2 ;;
        --builder) BUILDER="${2:?}"; shift 2 ;;
        --jobs) JOBS="${2:?}"; shift 2 ;;
        --check|--execute) MODE="$1"; shift ;;
        --restore-build) RESTORE_ONLY=true; shift ;;
        --fix-view-intents) FIX_VIEW_INTENTS=true; shift ;;
        --with-google-services) WITH_GOOGLE_SERVICES=true; shift ;;
        -h|--help)
            echo 'Usage: bash tests/runtime/build-locale-services.sh --aosp DIR --output-dir NEW_DIR [--check|--execute] [--jobs N] [--builder IMAGE]'
            echo 'Optional: --with-google-services restores CrossProfileAppsService; --fix-view-intents retains internal VIEW launches.'
            echo 'Normally rebuilds the baseline afterward. Use --restore-build with an existing experiment to recover interrupted build outputs.'
            exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done
[[ -n "$AOSP" && -n "$OUTPUT" && "$JOBS" =~ ^[1-9][0-9]*$ ]] || fail 'Supply AOSP, new output directory and positive jobs'
AOSP="$(realpath -e -- "$AOSP")"
OUTPUT="$(realpath -m -- "$OUTPUT")"
SOURCE=frameworks/base/services/java/com/android/server/SystemServer.java
JAR=out/target/product/lepton_x86_64/system/framework/services.jar
[[ -f "$AOSP/$SOURCE" && -f "$AOSP/$JAR" && -f "$AOSP/build/envsetup.sh" ]] || fail 'Prepared and previously built Android checkout required'
if [[ "$RESTORE_ONLY" == true ]]; then
    [[ -f "$OUTPUT/services-baseline.jar" && -f "$OUTPUT/before.sha256" ]] || fail 'Missing original experiment baseline'
else
    [[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || fail 'Output must be new'
fi
[[ "$OUTPUT" != "$AOSP" && "$AOSP" != "$OUTPUT/"* ]] || fail 'Output cannot contain AOSP'
command -v podman >/dev/null || fail 'Podman missing'
podman image exists "$BUILDER" || fail 'Builder missing'
if [[ "$MODE" == --check ]]; then
    echo '[PASS] Existing build and builder available; execute updates services build outputs only'
    exit 0
fi
build_services() {
    local mounts=()
    if [[ -n "${2:-}" ]]; then mounts=(-v "$2:/workspace/output/$VIEW_SOURCE:ro"); fi
    podman run --rm --network=none --userns=keep-id --group-add keep-groups \
        --security-opt=label=disable --hostname=lepton-build \
        -e "LEPTON_TEST_JOBS=$JOBS" \
        -v "$AOSP:/workspace/output:rw" \
        -v "$1:/workspace/output/$SOURCE:ro" "${mounts[@]}" \
        -w /workspace/output "$BUILDER" /bin/bash -ec \
        'source build/envsetup.sh >/dev/null; lunch aosp_lepton_x86_64-ap2a-userdebug; m services -j"$LEPTON_TEST_JOBS"'
}
restore_build() {
    # A fresh-mtime copy forces ninja to rebuild the original source as well:
    # simply removing the experimental bind mount leaves newer cached outputs.
    original_source_hash="$(head -1 "$OUTPUT/before.sha256" | cut -d' ' -f1)"
    current_source_hash="$(sha256sum "$AOSP/$SOURCE")"
    [[ "${current_source_hash%% *}" == "$original_source_hash" ]] || fail 'Original source changed during experiment; review before restoring'
    cp -- "$AOSP/$SOURCE" "$OUTPUT/SystemServer.baseline.java"
    local original_view=()
    if [[ -f "$OUTPUT/ActivityStarter.before.sha256" ]]; then
        sha256sum -c "$OUTPUT/ActivityStarter.before.sha256" || fail 'Original ActivityStarter changed'
        cp -- "$AOSP/$VIEW_SOURCE" "$OUTPUT/ActivityStarter.baseline.java"
        original_view=("$OUTPUT/ActivityStarter.baseline.java")
    fi
    build_services "$OUTPUT/SystemServer.baseline.java" "${original_view[@]}"
    # ProtoLog deliberately chooses a random generated class name on each
    # rebuild, so equivalent baseline DEX need not be byte-identical. Sources
    # above are hash-checked and rebuilt; restore the exact original packaged
    # artifact from its separately hash-checked snapshot.
    local saved_jar_hash current_saved_jar_hash
    saved_jar_hash="$(sed -n '2p' "$OUTPUT/before.sha256" | cut -d' ' -f1)"
    current_saved_jar_hash="$(sha256sum "$OUTPUT/services-baseline.jar")"
    [[ "${current_saved_jar_hash%% *}" == "$saved_jar_hash" ]] || fail 'Saved baseline jar changed'
    cp -- "$OUTPUT/services-baseline.jar" "$AOSP/$JAR"
    echo '[PASS] Incremental services build restored to its original baseline'
}
if [[ "$RESTORE_ONLY" == true ]]; then
    exec > >(tee "$OUTPUT/restore-build.log") 2>&1
    restore_build
    exit 0
fi
mkdir -p -- "$OUTPUT"
exec > >(tee "$OUTPUT/build.log") 2>&1
sha256sum "$AOSP/$SOURCE" "$AOSP/$JAR" > "$OUTPUT/before.sha256"
cp -- "$AOSP/$JAR" "$OUTPUT/services-baseline.jar"
# Research outputs may contain live Podman overlay mounts. Keep Android's
# source finder out of the experiment subtree during incremental builds.
if [[ "$OUTPUT" == "$AOSP/native-bridge-research/"* ]]; then
    touch "$AOSP/native-bridge-research/.find-ignore"
fi
python3 - "$AOSP/$SOURCE" "$OUTPUT/SystemServer.java" "$WITH_GOOGLE_SERVICES" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
block = '''        /*
        t.traceBegin("StartLocaleManagerService");
        try {
            mSystemServiceManager.startService(LocaleManagerService.class);
        } catch (Throwable e) {
            reportWtf("starting LocaleManagerService service", e);
        }
        t.traceEnd();
        */'''
if source.count(block) != 1:
    raise SystemExit("Expected exactly one disabled LocaleManagerService block")
source = source.replace(block, block.removeprefix('        /*\n').removesuffix('\n        */'), 1)
if sys.argv[3] == 'true':
    cross = '''            /*
            t.traceBegin("StartCrossProfileAppsService");
            mSystemServiceManager.startService(CrossProfileAppsService.class);
            t.traceEnd();

            t.traceBegin("StartPeopleService");'''
    if source.count(cross) != 1:
        raise SystemExit('Expected exactly one disabled CrossProfileAppsService block')
    source = source.replace(cross, cross.removeprefix('            /*\n').replace(
        '            t.traceBegin("StartPeopleService");',
        '            /*\n            t.traceBegin("StartPeopleService");'), 1)
Path(sys.argv[2]).write_text(source)
PY
view_override=()
if [[ "$FIX_VIEW_INTENTS" == true ]]; then
    sha256sum "$AOSP/$VIEW_SOURCE" > "$OUTPUT/ActivityStarter.before.sha256"
    python3 "$SCRIPT_DIR/patch-view-intents.py" "$AOSP/$VIEW_SOURCE" "$OUTPUT/ActivityStarter.java"
    view_override=("$OUTPUT/ActivityStarter.java")
fi
echo '[INFO] Building services with read-only source overrides'
build_services "$OUTPUT/SystemServer.java" "${view_override[@]}"
cp -- "$AOSP/$JAR" "$OUTPUT/services-locale.jar"
sha256sum "$AOSP/$SOURCE" "$OUTPUT/SystemServer.java" "$OUTPUT/services-locale.jar" > "$OUTPUT/after.sha256"
echo "[PASS] Locale services jar: $OUTPUT/services-locale.jar"
restore_build
