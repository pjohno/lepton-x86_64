#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Reuse the owned checkout; isolate all packaged outputs under a NEW test dir.
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
MODE=''; ID=''; OUTPUT=''; BUNDLE_ARGS=()
usage() {
    cat <<'HELP'
Usage: bash image-14/scripts/build-incremental-bundle-x86_64.sh --check|--execute --bundle-id ID --output-dir NEW_DIR [bundle options]

Reuses the prepared AOSP checkout and updates aosp/out/ incrementally.
Creates NEW_DIR/{images,rootfs,stage,bundles}; refuses existing output paths.
Never resets sources, runs installclean, replaces previous packaged artifacts,
transfers files or installs a tool. --check changes nothing.

Bundle options are forwarded unchanged to make-deck-bundle-x86_64.sh:
  --with-ndk [--ndk-payload DIR] --with-gapps [--google-images DIR]
  --with-widevine --services-jar FILE --tool-id ID --tool-name NAME
  --from-stage DIR | --adb-zip FILE
  --sysbake-rendering software|amd --sysbake-timeout SECONDS
Google/NDK inputs stay opt-in. A fresh sysbake is always generated.
HELP
}
fail() { echo "[FAIL] $*" >&2; exit 1; }
while (($#)); do
    case "$1" in
        --check|--execute) [[ -z "$MODE" ]] || fail 'Choose one mode'; MODE="$1"; shift ;;
        --bundle-id) ID="${2:?}"; shift 2 ;;
        --output-dir) OUTPUT="${2:?}"; shift 2 ;;
        --with-ndk|--with-gapps|--with-widevine) BUNDLE_ARGS+=("$1"); shift ;;
        --ndk-payload|--google-images|--services-jar|--tool-id|--tool-name|--from-stage|--adb-zip|--sysbake-rendering|--sysbake-timeout)
            BUNDLE_ARGS+=("$1" "${2:?}"); shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "Unknown option: $1" ;;
    esac
done
[[ -n "$MODE" && -n "$OUTPUT" && "$ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && ${#ID} -le 64 ]] || { usage >&2; exit 2; }
source "$ROOT/.build-env"
source "$SCRIPT_DIR/lib/workspace.sh"
lepton_workspace
OUTPUT="$(lepton_output_path "$OUTPUT")"
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || fail "Output directory already exists: $OUTPUT"
lepton_output_outside "$OUTPUT" "$ROOT" "$LEPTON_AOSP_DIR" "$LEPTON_IMAGES_DIR" "$LEPTON_ROOTFS_DIR" "$LEPTON_STAGES_DIR" "$LEPTON_DECK_BUNDLE_DIR" "$LEPTON_LOG_DIR" "$LEPTON_GOOGLE_INPUTS_DIR" || fail 'Unsafe output directory'
# Image preflight is read-only and checks the exact hwcomposer/source content.
bash "$SCRIPT_DIR/build-images-x86_64.sh" --check --images-dir "$OUTPUT/images" --rootfs-dir "$OUTPUT/rootfs"
if [[ "$MODE" == --check ]]; then
    # The new rootfs does not exist yet. Validate the forwarded option syntax
    # and inputs during the ordinary bundle preflight after compilation.
    echo '[PASS] Incremental image/output preflight passed; bundle input checks run after the new rootfs exists'
    exit 0
fi
bash "$SCRIPT_DIR/build-images-x86_64.sh" --execute --images-dir "$OUTPUT/images" --rootfs-dir "$OUTPUT/rootfs"
bash "$SCRIPT_DIR/make-deck-bundle-x86_64.sh" --execute --bundle-id "$ID" \
    --rootfs-source "$OUTPUT/rootfs" --stage-dir "$OUTPUT/stage" --bundle-dir "$OUTPUT/bundles" "${BUNDLE_ARGS[@]}"
