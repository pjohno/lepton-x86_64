#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# One command from an already packaged Android 14 rootfs to an installable
# Steam Deck bundle: stage -> Deck tools -> isolated sysbake -> package
# (-> optional transfer). Every step is an existing, separately testable script.
# Never modifies an existing stage, bundle or Steam installation.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
CONFIG="$ROOT/.build-env"
MODE=''
BUNDLE_ID=''
STAGE=''
BUNDLE_DIR=''
DECK_IP=''
SYSBAKE_RENDERING=software
SYSBAKE_TIMEOUT=600
DEPLOY_ARGS=()
PROVISION_ARGS=()
BUNDLE_ARGS=()

usage() {
    cat <<'HELP'
Usage: bash image-14/scripts/make-deck-bundle-x86_64.sh --check|--execute --bundle-id ID [options]

Builds a Steam Deck bundle from the workspace's packaged rootfs (rootfs/,
made by build-images-x86_64.sh), or --rootfs-source DIR.
Use image-14/do_build_x86_64.sh instead to also compile Android from source.

Options:
  --stage-dir DIR             New stage (default: workspace stages/ID)
  --bundle-dir DIR            Archive directory (default: workspace bundles/)
  --rootfs-source DIR         Alternative packaged Android 14 x86_64 rootfs
  --with-ndk [--ndk-payload DIR]          Add local ARM64 NDK translation
  --with-gapps [--google-images DIR]      Add local Google Play services
                              (default inputs: workspace google-inputs/)
  --with-widevine              Add Widevine L3 DRM from the same Google image
  --services-jar FILE         Tested framework override (older rootfs + GApps)
  --tool-id ID / --tool-name NAME         Steam tool identity
  --from-stage DIR | --adb-zip FILE       Offline Deck tool provisioning
  --sysbake-rendering software|amd        (default software; no GPU needed)
  --sysbake-timeout SECONDS               (default 600)
  --deck-ip IPv4              Transfer archive, checksum and installer after packaging

--check validates inputs and destinations without writing anything.
Afterwards on the Deck: bash ~/Downloads/lepton-deck-bundles/<name>.install.sh
HELP
}
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }
step() { printf '\n=== %s ===\n' "$*"; }

while (($#)); do
    case "$1" in
        --check|--execute) [[ -z "$MODE" ]] || fail 'Choose one mode'; MODE="$1"; shift ;;
        --bundle-id) BUNDLE_ID="${2:?--bundle-id requires ID}"; shift 2 ;;
        --stage-dir) STAGE="${2:?--stage-dir requires DIR}"; shift 2 ;;
        --bundle-dir) BUNDLE_DIR="${2:?--bundle-dir requires DIR}"; shift 2 ;;
        --deck-ip) DECK_IP="${2:?--deck-ip requires IPv4}"; shift 2 ;;
        --rootfs-source|--ndk-payload|--google-images|--services-jar)
            DEPLOY_ARGS+=("$1" "${2:?$1 requires a value}"); shift 2 ;;
        --with-ndk|--with-gapps|--with-widevine) DEPLOY_ARGS+=("$1"); shift ;;
        --tool-id|--tool-name) BUNDLE_ARGS+=("$1" "${2:?$1 requires a value}"); shift 2 ;;
        --from-stage|--adb-zip) PROVISION_ARGS+=("$1" "${2:?$1 requires a value}"); shift 2 ;;
        --sysbake-rendering) SYSBAKE_RENDERING="${2:?}"; shift 2 ;;
        --sysbake-timeout) SYSBAKE_TIMEOUT="${2:?}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "Unknown argument: $1" ;;
    esac
done
[[ -n "$MODE" && -n "$BUNDLE_ID" ]] || { usage >&2; fail 'A mode and --bundle-id are required'; }
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && ${#BUNDLE_ID} -le 64 ]] ||
    fail 'Bundle ID must be 1-64 letters, digits, dots, hyphens or underscores'
[[ "$SYSBAKE_RENDERING" == software || "$SYSBAKE_RENDERING" == amd ]] || fail 'Invalid --sysbake-rendering'
[[ "$SYSBAKE_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || fail 'Invalid --sysbake-timeout'
[[ $(id -u) -ne 0 ]] || fail 'Run as a normal user (without sudo)'
[[ -f "$CONFIG" ]] || fail "Missing $CONFIG (copy .build-env.example)"
# shellcheck source=/dev/null
source "$CONFIG"
: "${LEPTON_OUTPUT_DIR:?Set LEPTON_OUTPUT_DIR in .build-env}"
source "$SCRIPT_DIR/lib/workspace.sh"
lepton_workspace

STAGE="$(realpath -m -- "${STAGE:-$LEPTON_STAGES_DIR/$BUNDLE_ID}")"
BUNDLE_DIR="$(realpath -m -- "${BUNDLE_DIR:-$LEPTON_DECK_BUNDLE_DIR}")"
ARCHIVE="$BUNDLE_DIR/lepton-x86_64-steamdeck-$BUNDLE_ID.tar.gz"
[[ ! -e "$STAGE" && ! -L "$STAGE" ]] || fail "Stage already exists (choose another --bundle-id or --stage-dir): $STAGE"
[[ ! -e "$ARCHIVE" && ! -L "$ARCHIVE" ]] || fail "Bundle already exists: $ARCHIVE"
[[ "$BUNDLE_DIR" != "$STAGE" && "$BUNDLE_DIR" != "$STAGE/"* ]] || fail 'Bundle directory must be outside the stage'
TRANSFER_ARGS=()
[[ -z "$DECK_IP" ]] || TRANSFER_ARGS=(--deck-ip "$DECK_IP")

info "Bundle ID: $BUNDLE_ID"
info "Stage: $STAGE"
info "Bundle: $ARCHIVE"
info "Sysbake: $SYSBAKE_RENDERING rendering"
[[ -z "$DECK_IP" ]] || info "Transfer to: deck@$DECK_IP (after packaging)"

step 'Check: stage inputs'
bash "$SCRIPT_DIR/internal/deploy-compat-x86_64.sh" --check --stage-dir "$STAGE" "${DEPLOY_ARGS[@]}"
if [[ "$MODE" == --check ]]; then
    info 'Tool provisioning, sysbake and packaging checks need the stage; they run during --execute'
    printf '[PASS] Bundle pipeline preflight passed; nothing was changed\n'
    exit 0
fi

step '1/4 Stage Android rootfs and launcher'
mkdir -p -- "$(dirname -- "$STAGE")" "$BUNDLE_DIR"
bash "$SCRIPT_DIR/internal/deploy-compat-x86_64.sh" --execute --stage-dir "$STAGE" "${DEPLOY_ARGS[@]}"

step '2/4 Provision Steam Deck tools (ADB, inotify-tools)'
bash "$SCRIPT_DIR/internal/provision-deck-tools.sh" --execute --stage-dir "$STAGE" "${PROVISION_ARGS[@]}"
bash "$SCRIPT_DIR/internal/provision-deck-tools.sh" --check --stage-dir "$STAGE"

step '3/4 Bake Android system data (private Podman storage)'
bash "$SCRIPT_DIR/internal/sysbake-isolated-x86_64.sh" --check --stage-dir "$STAGE" --rendering "$SYSBAKE_RENDERING"
bash "$SCRIPT_DIR/internal/sysbake-isolated-x86_64.sh" --execute --stage-dir "$STAGE" \
    --timeout "$SYSBAKE_TIMEOUT" --rendering "$SYSBAKE_RENDERING"

step '4/4 Package bundle and installer'
bash "$SCRIPT_DIR/internal/deploy-compat-x86_64.sh" --package-only --execute --stage-dir "$STAGE" \
    --bundle-dir "$BUNDLE_DIR" --bundle-id "$BUNDLE_ID" "${BUNDLE_ARGS[@]}" "${TRANSFER_ARGS[@]}"

printf '\n[PASS] Bundle ready: %s\n' "$ARCHIVE"
if [[ -z "$DECK_IP" ]]; then
    info "The stage is no longer needed: podman unshare rm -rf \"$STAGE\""
    info "Send it with: bash image-14/scripts/transfer-deck-bundle.sh --bundle-id $BUNDLE_ID --deck-ip DECK_IP"
fi
