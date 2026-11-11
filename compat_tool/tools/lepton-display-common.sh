#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# shellcheck disable=SC2154 # display_mode and outer_display belong to the caller.
# Shared display preflight and player diagnostics; sourced by launchers.
# Error popup for the player: TITLE MESSAGE [TIMEOUT]. Gaming Mode only shows
# windows tagged with the running game's AppID, so there it is a scaled Qt
# dialog on Steam's X11 display, tagged STEAM_GAME; on the desktop a regular
# Wayland dialog.
lepton_dialog() {
    local title="$1" message="$2" limit="${3:-60s}"

    # Desktop Wayland has no outer X11 window to tag; show a regular dialog.
    if [[ "$display_mode" == desktop ]]; then
        if command -v kdialog >/dev/null 2>&1; then
            QT_QPA_PLATFORM=wayland timeout "$limit" kdialog \
                --title "$title" --error "$message" || true
        elif command -v zenity >/dev/null 2>&1; then
            timeout "$limit" zenity --error --no-markup --title="$title" --text="$message" || true
        fi
        return 0
    fi

    # Show a scaled Qt dialog through X11, tagged for Steam Gamescope.
    local win="" dialog_pid

    DISPLAY="$outer_display" QT_QPA_PLATFORM=xcb QT_SCALE_FACTOR=2 \
        timeout "$limit" kdialog \
        --title "$title" --error "$message" &
    dialog_pid=$!

    for ((i=0; i<80; i++)); do
        kill -0 "$dialog_pid" 2>/dev/null || break

        win=$(DISPLAY="$outer_display" xwininfo -root -tree 2>/dev/null |
            awk -v title="$title" \
                'index($0, "\"" title "\"") {print $1; exit}')

        [[ -n "$win" ]] && break
        sleep 0.1
    done

    if [[ -n "$win" ]]; then
        DISPLAY="$outer_display" xprop -id "$win" \
            -f STEAM_GAME 32c -set STEAM_GAME "$app_id"
        echo "Assigned Steam AppID $app_id to dialog window $win"
    else
        echo "WARNING: Could not identify the kdialog window" >&2
        kill "$dialog_pid" 2>/dev/null || true
    fi

    wait "$dialog_pid" 2>/dev/null || true
}

# Lepton BinderFS preflight. Never load or install kernel modules.
lepton_check_binder() {
    grep -qw binder /proc/filesystems 2>/dev/null && return 0

    local message
    message="Android Binder kernel support is unavailable.

Lepton requires BinderFS, provided by rust_binder, binder_linux,
or another compatible kernel implementation.

Please initialize Binder support and launch the game again.

Lepton will not install or load kernel modules."

    printf 'ERROR: %s\n' "$message" >&2
    lepton_dialog "Lepton Binder Unavailable" "$message"
    return 1
}

# Lepton writes why a game could not start (for example a refused profile) to
# LEPTON_MESSAGE_FILE; show it once Lepton and the nested Gamescope have exited.
message_file=""
show_launch_message() {
    [[ -n "$message_file" && -s "$message_file" ]] || return 0
    lepton_dialog "Lepton: game could not start" "$(cat "$message_file")
Details: ~/.steam/steam/logs/lepton-steamlaunch-$app_id.log" 180s
}
cleanup_message_file() { [[ -z "$message_file" ]] || rm -f -- "$message_file"; }

app_id="${SteamAppId:-}"
if [[ ! "$app_id" =~ ^[1-9][0-9]*$ && "${SteamGameId:-}" =~ ^[0-9]+$ ]]; then
    printf -v game_id_hex '%016x' "$SteamGameId"
    app_id="$((16#${game_id_hex:0:8}))"
fi
[[ "$app_id" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: A real SteamAppId is required" >&2
    exit 1
}

export SteamAppId="$app_id"

