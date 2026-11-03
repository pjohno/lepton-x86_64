#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Stage a services.jar experiment without changing its source runtime stage.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SOURCE=''
STAGE=''
JAR=''
BASELINE=''
MODE=--check
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
while (($#)); do
    case "$1" in
        --source-stage) SOURCE="${2:?}"; shift 2 ;;
        --stage-dir) STAGE="${2:?}"; shift 2 ;;
        --services-jar) JAR="${2:?}"; shift 2 ;;
        --baseline-jar) BASELINE="${2:?}"; shift 2 ;;
        --check|--execute) MODE="$1"; shift ;;
        -h|--help)
            echo 'Usage: bash tests/runtime/stage-services-test.sh --source-stage DIR --stage-dir NEW_DIR --services-jar FILE --baseline-jar FILE [--check|--execute]'
            exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done
[[ -n "$SOURCE" && -n "$STAGE" && -n "$JAR" && -n "$BASELINE" ]] || fail 'Supply source, new stage, services jar and baseline jar'
SOURCE="$(realpath -e -- "$SOURCE")"
STAGE="$(realpath -m -- "$STAGE")"
JAR="$(realpath -e -- "$JAR")"
BASELINE="$(realpath -e -- "$BASELINE")"
[[ ! -e "$STAGE" && ! -L "$STAGE" && "$STAGE" != "$SOURCE/"* ]] || fail 'Destination must be new and outside source stage'
[[ -f "$JAR" && -f "$BASELINE" && -d "$SOURCE/tools" ]] || fail 'Missing jar or staged host tools'
cmp -s "$BASELINE" "$SOURCE/compat_tool/images/rootfs/system/framework/services.jar" || fail 'Source stage services.jar does not match experiment baseline'
unzip -Z1 "$JAR" | grep -Fx 'classes.dex' >/dev/null || fail 'Experimental services.jar has no DEX'
bash "$ROOT/image-14/scripts/deploy-compat-x86_64.sh" "$MODE" \
    --stage-dir "$STAGE" --rootfs-source "$SOURCE/compat_tool/images/rootfs"
if [[ "$MODE" == --check ]]; then
    echo '[PASS] New framework stage can be created; preoptimized services artifacts will be removed'
    exit 0
fi
FRAMEWORK="$STAGE/compat_tool/images/rootfs/system/framework"
cp -- "$JAR" "$FRAMEWORK/services.jar"
# Only in the newly created stage: ART must optimize the changed DEX afresh.
for abi in x86 x86_64 arm arm64; do
    for suffix in odex vdex art; do
        rm -f -- "$FRAMEWORK/oat/$abi/services.$suffix"
    done
done
rm -f -- "$FRAMEWORK/services.jar.prof" "$FRAMEWORK/services.jar.bprof"
cp -a --no-preserve=ownership -- "$SOURCE/tools" "$STAGE/tools"
sha256sum "$BASELINE" "$JAR" "$FRAMEWORK/services.jar" > "$STAGE/services-experiment.sha256"
printf '[PASS] Framework test stage: %s; generate fresh sysbake before testing\n' "$STAGE"
