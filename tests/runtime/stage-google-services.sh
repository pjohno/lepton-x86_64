#!/usr/bin/env bash
# Local, opt-in Google-services experiment. Play Store requires an explicit flag.
# Source stages are unchanged; Google binaries remain in external build output.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SOURCE=''
STAGE=''
IMAGES=''
MODE=--check
WITH_STORE=false
WITH_BROWSER=false
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
while (($#)); do
    case "$1" in
        --source-stage) SOURCE="${2:?}"; shift 2 ;;
        --stage-dir) STAGE="${2:?}"; shift 2 ;;
        --google-images) IMAGES="${2:?}"; shift 2 ;;
        --check|--execute) MODE="$1"; shift ;;
        --with-browser) WITH_BROWSER=true; shift ;;
        --with-play-store) WITH_STORE=true; shift ;;
        -h|--help)
            echo 'Usage: bash tests/runtime/stage-google-services.sh --source-stage DIR --stage-dir NEW_DIR --google-images LOGICAL_PARTITIONS_DIR [--with-play-store] [--with-browser] [--check|--execute]'
            exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done
[[ -n "$SOURCE" && -n "$STAGE" && -n "$IMAGES" ]] || fail 'Supply source stage, new stage and Google logical images'
SOURCE="$(realpath -e -- "$SOURCE")"
STAGE="$(realpath -m -- "$STAGE")"
IMAGES="$(realpath -e -- "$IMAGES")"
[[ ! -e "$STAGE" && ! -L "$STAGE" && "$STAGE" != "$SOURCE/"* ]] || fail 'Stage must be new and outside the source stage'
[[ "$IMAGES" != "$STAGE/"* ]] || fail 'Google source images cannot be inside destination'
[[ -d "$SOURCE/tools" ]] || fail 'Source stage host tools missing'
source "$ROOT/image-14/scripts/lib/google-services.sh"
google_services_check "$IMAGES" "$WITH_STORE" "$WITH_BROWSER"
bash "$ROOT/image-14/scripts/deploy-compat-x86_64.sh" "$MODE" \
    --stage-dir "$STAGE" --rootfs-source "$SOURCE/compat_tool/images/rootfs"
if [[ "$MODE" == --check ]]; then
    echo '[PASS] Google-services staging preflight; no files changed'
    exit 0
fi
google_services_inject "$STAGE/compat_tool/images/rootfs" "$IMAGES" "$WITH_STORE" "$WITH_BROWSER" "$STAGE/compat_tool/provenance/gapps"
cp -a --no-preserve=ownership -- "$SOURCE/tools" "$STAGE/tools"
cp -- "$STAGE/compat_tool/provenance/gapps/SHA256SUMS" "$STAGE/google-services.sha256"
printf 'Google images: %s\nSource stage: %s\nPlay Store included: %s\nBrowser included: %s\n' \
    "$IMAGES" "$SOURCE" "$WITH_STORE" "$WITH_BROWSER" > "$STAGE/google-services-source.txt"
echo "[PASS] Google services staged at $STAGE; generate fresh sysbake"
