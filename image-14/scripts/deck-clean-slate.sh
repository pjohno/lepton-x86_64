#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Remove every x86_64 Lepton install and its traces from a Steam Deck, for a
# clean-slate test. Run from the build machine (over SSH) or on the Deck:
#
#   bash image-14/scripts/deck-clean-slate.sh --deck-ip IP --check     # list only
#   bash image-14/scripts/deck-clean-slate.sh --deck-ip IP --execute   # remove
#   bash image-14/scripts/deck-clean-slate.sh --local --check          # on the Deck
#
# Removes: ~/.local/share/lepton* installs, backups and unfinished installs;
# Steam registrations compatibilitytools.d/lepton*.vdf; self-contained Lepton
# installs, backups and unfinished installs in compatibilitytools.d (only
# folders containing Lepton; Proton and other tools are never touched);
# ~/.config/lepton-x86_64;
# ~/.local/bin/lepton-* ; Lepton menu/desktop icons; downloaded bundles in
# ~/Downloads; stopped lepton-* Podman containers. With --game-data, also
# Android app data that Lepton stored in Steam's compatdata (saves are lost).
#
# Never touches: Steam itself or its shortcuts (delete those in Steam), Valve's
# official Lepton (steamapps/common), or anything while a Lepton game runs.
# It never closes or starts Steam; Steam may stay open.
set -Eeuo pipefail

# Over SSH this script arrives on bash's standard input. Braces make bash read
# the whole script before running it, so no command can swallow the rest.
{
MODE=''
DECK_IP=''
LOCAL=false
GAME_DATA=false
usage() { sed -n '3,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
while (($#)); do
    case "$1" in
        --check|--execute) MODE="$1"; shift ;;
        --deck-ip) DECK_IP="${2:?--deck-ip needs an address}"; shift 2 ;;
        --local) LOCAL=true; shift ;;
        --game-data) GAME_DATA=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done
[[ -n "$MODE" ]] || { usage >&2; fail 'Choose --check or --execute'; }

if [[ "$LOCAL" == false ]]; then
    [[ "$DECK_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || fail 'Give --deck-ip IPv4 (or --local on the Deck)'
    extra=()
    [[ "$GAME_DATA" == false ]] || extra+=(--game-data)
    # Run this same script on the Deck.
    exec ssh "deck@$DECK_IP" bash -s -- --local "$MODE" "${extra[@]}" < "${BASH_SOURCE[0]}"
fi

# ---- runs on the Deck (or the local machine) ----
[[ $(id -u) -ne 0 ]] || fail 'Run as the normal user, not root'
share="$HOME/.local/share"
# Steam's folder: ~/.steam/root (usually a link to ~/.local/share/Steam).
steam="$share/Steam"
if [[ -e "$HOME/.steam/root" ]]; then
    root="$(realpath -e -- "$HOME/.steam/root")"
    if [[ -d "$steam" && "$(realpath -e -- "$steam")" != "$root" ]]; then
        fail "Two different Steam folders: ~/.steam/root -> $root and $steam. Nothing was removed."
    fi
    steam="$root"
fi

# Refuse while anything Lepton is running.
if pgrep -f '/compat_tool/(lepton|lepton-x86_64-entry|tools/lepton-gamescope-bridge)( |$)' >/dev/null 2>&1 < /dev/null; then
    fail 'A Lepton game or test is running; stop it first. Nothing was removed.'
fi
running=()
containers=()
if command -v podman >/dev/null 2>&1; then
    while read -r name state; do
        [[ "$name" == lepton-* ]] || continue
        containers+=("$name")
        [[ "$state" != running ]] || running+=("$name")
    done < <(podman ps -a --format '{{.Names}} {{.State}}' 2>/dev/null < /dev/null || true)
fi
((${#running[@]} == 0)) || fail "Lepton container(s) running: ${running[*]}; stop the game first. Nothing was removed."

targets=()
add() { [[ -e "$1" || -L "$1" ]] && targets+=("$1"); return 0; }
shopt -s nullglob dotglob
for path in "$share"/lepton* "$share"/.lepton-install.*; do
    # Only Lepton installs, backups and unfinished installs (and Lepton's logs dir).
    if [[ -e "$path/compat_tool/lepton" || "$path" == "$share/lepton" || "$path" == "$share"/.lepton-install.* ]]; then
        add "$path"
    fi
done
for path in "$steam"/compatibilitytools.d/*; do
    # Self-contained Lepton installs and their backups, never other tools.
    if [[ -d "$path" && ! -L "$path" && -e "$path/compat_tool/lepton" && -d "$path/compat_tool/liblepton" ]] ||
       [[ "$path" == "$steam"/compatibilitytools.d/.lepton-install.* ]]; then
        add "$path"
    fi
done
for path in "$steam"/compatibilitytools.d/lepton*.vdf "$HOME"/.local/bin/lepton-* \
            "$share"/applications/lepton-x86_64-*.desktop "$share"/applications/lepton-release-manager.desktop \
            "$HOME"/Desktop/lepton-*.desktop \
            "$HOME"/Downloads/lepton-x86_64-*.tar.gz* \
            "$HOME"/Downloads/lepton-x86_64-*.install.sh; do
    add "$path"
done
add "$HOME/.config/lepton-x86_64"
add "$share/lepton-release-manager"   # Lepton: Install / Update / Repair
add "$HOME/Downloads/lepton-deck-bundles"
game_data=()
for path in "$steam"/steamapps/compatdata/*; do
    # Lepton app data (baked Android data / external storage), never Proton prefixes.
    if [[ ( -d "$path/baked" || -e "$path/external" ) && ! -e "$path/pfx" ]]; then
        game_data+=("$path")
    fi
done
shopt -u nullglob dotglob

# SteamOS has no hostname command; bash provides $HOSTNAME.
printf 'Lepton items on %s (%s):\n' "${HOSTNAME:-this computer}" "$HOME"
for path in "${targets[@]}"; do printf '  %s\n' "$path"; done
((${#targets[@]})) || printf '  (none)\n'
for name in "${containers[@]}"; do printf '  podman container %s\n' "$name"; done
if ((${#game_data[@]})); then
    if [[ "$GAME_DATA" == true ]]; then
        printf 'Android game data (will be removed):\n'
    else
        printf 'Android game data (kept; add --game-data to remove it, saves are lost):\n'
    fi
    for path in "${game_data[@]}"; do printf '  %s\n' "$path"; done
fi

if [[ "$MODE" == --check ]]; then
    printf '[PASS] Nothing was changed. Re-run with --execute to remove the items above.\n'
    exit 0
fi

remove() {
    # Android data can contain mode-000 directories and files owned by the
    # user's subordinate IDs (from containers); podman unshare handles both.
    if command -v podman >/dev/null 2>&1 &&
       podman unshare sh -c 'chmod -R u+rwX -- "$1" 2>/dev/null; rm -rf -- "$1"' sh "$1" 2>/dev/null < /dev/null &&
       [[ ! -e "$1" && ! -L "$1" ]]; then
        return 0
    fi
    chmod -R u+rwX -- "$1" 2>/dev/null || true
    rm -rf -- "$1"
}
for name in "${containers[@]}"; do podman rm -f "$name" >/dev/null 2>&1 < /dev/null || true; done
[[ "$GAME_DATA" == true ]] && targets+=("${game_data[@]}")
failed=0
for path in "${targets[@]}"; do
    if remove "$path" && [[ ! -e "$path" && ! -L "$path" ]]; then
        printf 'Removed %s\n' "$path"
    else
        printf 'Could not remove %s\n' "$path" >&2
        failed=1
    fi
done
((failed == 0)) || fail 'Some items could not be removed (see above)'
printf '[PASS] Lepton removed. Restart Steam when convenient so it forgets the tools;\n'
printf '       delete the old game shortcuts in Steam (Library > Non-Steam).\n'
exit 0
}
