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
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
while (($#)); do
    case "$1" in
        --aosp) AOSP="${2:?}"; shift 2 ;;
        --output-dir) OUTPUT="${2:?}"; shift 2 ;;
        --builder) BUILDER="${2:?}"; shift 2 ;;
        --jobs) JOBS="${2:?}"; shift 2 ;;
        --check|--execute) MODE="$1"; shift ;;
        --restore-build) RESTORE_ONLY=true; shift ;;
        -h|--help)
            echo 'Usage: bash tests/runtime/build-locale-services.sh --aosp DIR --output-dir NEW_DIR [--check|--execute] [--jobs N] [--builder IMAGE]'
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
    podman run --rm --network=none --userns=keep-id --group-add keep-groups \
        --security-opt=label=disable --hostname=lepton-build \
        -e "LEPTON_TEST_JOBS=$JOBS" \
        -v "$AOSP:/workspace/output:rw" \
        -v "$1:/workspace/output/$SOURCE:ro" \
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
    build_services "$OUTPUT/SystemServer.baseline.java"
    cmp -s "$OUTPUT/services-baseline.jar" "$AOSP/$JAR" || fail 'Rebuilt baseline differs; review original and current services.jar'
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
python3 - "$AOSP/$SOURCE" "$OUTPUT/SystemServer.java" <<'PY'
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
Path(sys.argv[2]).write_text(source.replace(block, block.removeprefix('        /*\n').removesuffix('\n        */'), 1))
PY
echo '[INFO] Building services with read-only SystemServer source override'
build_services "$OUTPUT/SystemServer.java"
cp -- "$AOSP/$JAR" "$OUTPUT/services-locale.jar"
sha256sum "$AOSP/$SOURCE" "$OUTPUT/SystemServer.java" "$OUTPUT/services-locale.jar" > "$OUTPUT/after.sha256"
echo "[PASS] Locale services jar: $OUTPUT/services-locale.jar"
restore_build
