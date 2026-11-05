#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copy a finished bundle (made by make-deck-bundle-x86_64.sh) to a Steam Deck
# over SSH, and optionally install it there straight away.
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

usage() {
    cat <<'HELP'
Usage: bash image-14/scripts/transfer-deck-bundle.sh --bundle-id ID --deck-ip IPv4 [options]

Copies the bundle's archive, checksum and installer to
~/Downloads/lepton-deck-bundles/ on the Deck, verifies the checksum there and
puts an "Install Lepton ID" icon on the Deck desktop.

Options:
  --check              Verify the local bundle only; connect to nothing
  --replace TOOL_ID    Also install now over SSH, overwriting the Deck's
                       install TOOL_ID (its games keep working). Tool IDs are
                       listed by "lepton-manage-installs --list" on the Deck.
  --bundle-dir DIR     Where the bundle is (default: the workspace's bundles/)

Lepton never closes or starts Steam. Restart Steam after installing.
HELP
}
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

MODE=--execute
ARGS=()
while (($#)); do
    case "$1" in
        --check) MODE=--check; shift ;;
        --bundle-id|--deck-ip|--bundle-dir) ARGS+=("$1" "${2:?$1 requires a value}"); shift 2 ;;
        --replace) ARGS+=(--deck-replace "${2:?--replace requires a tool ID}"); shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "Unknown argument: $1" ;;
    esac
done
[[ " ${ARGS[*]} " == *" --bundle-id "* ]] || { usage >&2; fail '--bundle-id is required'; }
[[ " ${ARGS[*]} " == *" --deck-ip "* || "$MODE" == --check ]] || { usage >&2; fail '--deck-ip is required'; }
if [[ "$MODE" == --check ]]; then
    # Local verification only: the archive, its checksum and the installer.
    ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
    # shellcheck source=/dev/null
    [[ ! -f "$ROOT/.build-env" ]] || source "$ROOT/.build-env"
    if [[ -n "${LEPTON_OUTPUT_DIR:-}" ]]; then
        source "$SCRIPT_DIR/lib/workspace.sh"
        lepton_workspace
    fi
    id='' dir="${LEPTON_DECK_BUNDLE_DIR:-}"
    for ((i = 0; i < ${#ARGS[@]}; i += 2)); do
        case "${ARGS[i]}" in --bundle-id) id="${ARGS[i+1]}" ;; --bundle-dir) dir="${ARGS[i+1]}" ;; esac
    done
    [[ -n "$dir" ]] || fail 'Set LEPTON_OUTPUT_DIR in .build-env or pass --bundle-dir'
    archive="lepton-x86_64-steamdeck-$id.tar.gz"
    [[ -f "$dir/$archive" && -f "$dir/$archive.sha256" && -f "$dir/lepton-x86_64-steamdeck-$id.install.sh" ]] ||
        fail "Bundle $id not found in $dir (archive, .sha256 and .install.sh are needed)"
    ( cd "$dir" && sha256sum --quiet -c "$archive.sha256" ) || fail 'Checksum mismatch'
    printf '[PASS] Bundle %s is complete and verified; nothing was sent\n' "$id"
    exit 0
fi
exec bash "$SCRIPT_DIR/internal/deploy-compat-x86_64.sh" --transfer-only "$MODE" "${ARGS[@]}"
