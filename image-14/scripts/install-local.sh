#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Install a Lepton bundle on THIS computer (instead of sending it to a Deck):
# check the computer, package the stage if the bundle does not exist yet, then
# run the bundle's own installer here. Never closes or starts Steam.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
MODE=''
BUNDLE_ID=''
STAGE=''
BUNDLE_DIR=''
INSTALL_ARGS=()

usage() {
    cat <<'HELP'
Usage: bash image-14/scripts/install-local.sh --check|--execute --bundle-id ID [options]

Installs the bundle ID on this computer: the same installer a Steam Deck uses,
so it registers a Steam compatibility tool and adds the "Lepton: Add Android
game" menu entry. This installation uses direct host Wayland by default;
Steam Deck installations keep their normal Gamescope path.
Make the bundle (or at least its stage) first with
make-deck-bundle-x86_64.sh; a stage without a bundle is packaged here.

Options:
  --bundle-dir DIR    Where the bundle is or goes (default: workspace bundles/)
  --stage-dir DIR     Stage to package if the bundle is missing (default: workspace stages/ID)
  --allow-non-amd     Install without an AMD GPU (testing only: games need AMD graphics)
  --replace | --into TOOL_ID | --remove TOOL_ID | --keep-previous
                      Passed to the installer (see its --help)
  --adb-zip FILE      Use this Platform-Tools ZIP instead of downloading ADB

--check checks this computer, the bundle and the destination; it changes nothing.
--execute needs internet access: the installer downloads Google ADB (unless
--adb-zip is given), as on a Steam Deck.
Needs: Podman, Android Binder (BinderFS) kernel support, Gamescope, setfattr
(attr), Python 3, zenity or kdialog, and the native Steam package.
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
        --allow-non-amd|--replace|--keep-previous) INSTALL_ARGS+=("$1"); shift ;;
        --into|--remove) INSTALL_ARGS+=("$1" "${2:?$1 requires a tool ID}"); shift 2 ;;
        --adb-zip) INSTALL_ARGS+=("$1" "$(realpath -m -- "${2:?--adb-zip requires FILE}")"); shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "Unknown argument: $1" ;;
    esac
done
[[ -n "$MODE" && -n "$BUNDLE_ID" ]] || { usage >&2; fail 'A mode and --bundle-id are required'; }
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && ${#BUNDLE_ID} -le 64 ]] ||
    fail 'Bundle ID must be 1-64 letters, digits, dots, hyphens or underscores'
[[ $(id -u) -ne 0 ]] || fail 'Run as your normal user (without sudo)'
if [[ -z "$BUNDLE_DIR" || -z "$STAGE" ]]; then
    [[ -f "$ROOT/.build-env" ]] || fail "Missing $ROOT/.build-env; or pass --bundle-dir and --stage-dir"
    # shellcheck source=/dev/null
    source "$ROOT/.build-env"
    source "$SCRIPT_DIR/lib/workspace.sh"
    lepton_workspace
fi
BUNDLE_DIR="$(realpath -m -- "${BUNDLE_DIR:-$LEPTON_DECK_BUNDLE_DIR}")"
STAGE="$(realpath -m -- "${STAGE:-$LEPTON_STAGES_DIR/$BUNDLE_ID}")"
ARCHIVE="$BUNDLE_DIR/lepton-x86_64-steamdeck-$BUNDLE_ID.tar.gz"
INSTALLER="$BUNDLE_DIR/lepton-x86_64-steamdeck-$BUNDLE_ID.install.sh"

step 'Check this computer'
bash "$ROOT/compat_tool/tools/lepton-host-check" || fail 'Install the missing requirements above, then run this again'

step 'Bundle'
if [[ -f "$ARCHIVE" ]]; then
    [[ -f "$INSTALLER" && -f "$ARCHIVE.sha256" ]] || fail "Incomplete bundle in $BUNDLE_DIR (archive, .sha256 and .install.sh are needed)"
    info "Using existing bundle: $ARCHIVE"
elif [[ -d "$STAGE" ]]; then
    info "No bundle yet; packaging stage $STAGE"
    bash "$SCRIPT_DIR/internal/deploy-compat-x86_64.sh" --package-only "$MODE" \
        --stage-dir "$STAGE" --bundle-dir "$BUNDLE_DIR" --bundle-id "$BUNDLE_ID"
    if [[ "$MODE" == --check ]]; then
        printf '[PASS] Local install preflight passed (the installer check runs once the bundle exists); nothing was changed\n'
        exit 0
    fi
else
    fail "Neither bundle $ARCHIVE nor stage $STAGE exists; make it with make-deck-bundle-x86_64.sh"
fi

step 'Install on this computer'
# The bundled installer re-checks this computer with its own copy of the check.
grep -q -- '--install-profile' "$INSTALLER" || fail 'Bundle installer lacks local-desktop support; repackage with updated launcher scripts'
installer_args=(--install-profile local-desktop "${INSTALL_ARGS[@]}")
[[ "$MODE" == --execute ]] || installer_args+=(--check)
LEPTON_INSTALL_IN_TERMINAL=1 bash "$INSTALLER" "${installer_args[@]}"
if [[ "$MODE" == --check ]]; then
    printf '[PASS] Local install preflight passed; nothing was changed\n'
else
    printf '[PASS] Installed %s on this computer. Restart Steam to see the new tool.\n' "$BUNDLE_ID"
fi
