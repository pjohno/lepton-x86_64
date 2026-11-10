#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# lepton-gamescope-bridge: Desktop Mode is a movable window by default, fullscreen
# only on request; Gaming Mode keeps its SDL/X11 fullscreen command line and
# Steam window tagging. Fake gamescope/kscreen-doctor/X11 tools; clean env.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
bridge="$repo/compat_tool/tools/lepton-gamescope-bridge"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
real_grep="$(command -v grep)"
mkdir -p "$work/bin"
fake() { printf '#!/bin/bash\n%s\n' "$2" > "$work/bin/$1"; chmod +x "$work/bin/$1"; }
# Records its options (up to --) and Gaming Mode's environment, lives briefly
# so Gaming Mode can find and tag its window.
fake gamescope 'args=(); for a in "$@"; do [[ "$a" == -- ]] && break; args+=("$a"); done
echo "$$" > "$WORK/gamescope.pid"
echo "gamescope ${args[*]}" >> "$LOG"
echo "env SDL_VIDEODRIVER=${SDL_VIDEODRIVER:-} ENABLE_GAMESCOPE_WSI=${ENABLE_GAMESCOPE_WSI:-}" >> "$LOG"
# Like Lepton refusing a profile: leave a message for the bridge to show.
[[ -z "${FAKE_MESSAGE:-}" ]] || printf "%s\n" "$FAKE_MESSAGE" > "$LEPTON_MESSAGE_FILE"
[[ "${SDL_VIDEODRIVER:-}" != x11 ]] || sleep 0.6'
fake kscreen-doctor '[[ -n "${KSCREEN_JSON:-}" ]] || exit 1; printf "%s\n" "$KSCREEN_JSON"'
fake xdpyinfo 'echo "  dimensions:    1280x800 pixels (338x211 millimeters)"'
fake xwininfo 'echo "     0x400001 \"gamescope\": (\"gamescope\" \"gamescope\")  1280x800+0+0  +0+0"
echo "     0x500002 \"Lepton: game could not start\": (\"kdialog\")  600x300+0+0  +0+0"
echo "     0x500003 \"Lepton Binder Unavailable\": (\"kdialog\")  600x300+0+0  +0+0"'
fake xprop 'if [[ "$*" == *_NET_WM_PID* ]]; then echo "_NET_WM_PID(CARDINAL) = $(cat "$WORK/gamescope.pid" 2>/dev/null)"; else echo "xprop $*" >> "$LOG"; fi'
fake kdialog 'echo "kdialog QT=${QT_QPA_PLATFORM:-} SCALE=${QT_SCALE_FACTOR:-} DISPLAY=${DISPLAY:-} $*" >> "$LOG"; [[ "${QT_QPA_PLATFORM:-}" != xcb ]] || sleep 0.5'
# Binder present: the bridge's preflight reads /proc/filesystems with grep.
fake grep "[[ \"\${!#}\" == /proc/filesystems ]] && exit \${FAKE_NO_BINDER:-0}; exec '$real_grep' \"\$@\""
fake direct-game 'echo "direct GAMESCOPE_WAYLAND_DISPLAY=${GAMESCOPE_WAYLAND_DISPLAY:-}" >> "$LOG"'

deck='{"outputs":[{"enabled":true,"priority":0,"rotation":8,"scale":1,"currentModeId":"1","modes":[{"id":"1","size":{"width":800,"height":1280}}]}]}'
monitor() { printf '{"outputs":[{"enabled":true,"priority":1,"rotation":1,"scale":%s,"currentModeId":"m","modes":[{"id":"m","size":{"width":%s,"height":%s}}]}]}' "$3" "$1" "$2"; }
base=(env -i PATH="$work/bin:/usr/bin:/bin" HOME="$work" WORK="$work" LOG="$work/log" SteamAppId=123)
kde=(XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=KDE WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR="$work")
gaming=(DISPLAY=:0 GAMESCOPE_WAYLAND_DISPLAY=gamescope-0)
run() { rm -f "$work/log" "$work/gamescope.pid"; "${base[@]}" "$@" "$bridge" direct-game > "$work/out" 2> "$work/err" || fail "bridge failed: $* ($(cat "$work/err"))"; }
expect() { local got; got="$("$real_grep" '^gamescope ' "$work/log")"; [[ "$got" == "gamescope $1" ]] || fail "expected 'gamescope $1', got '$got'"; }
desktop_cmd() { echo "--backend wayland --expose-wayland ${2:+-f }-W ${1%x*} -H ${1#*x} -w ${1%x*} -h ${1#*x} --default-touch-mode 4"; }
gaming_cmd() { echo "--backend sdl --expose-wayland -f -W ${1%x*} -H ${1#*x} -w ${1%x*} -h ${1#*x} --default-touch-mode 4"; }
no_tagging() { ! "$real_grep" -q STEAM_GAME "$work/log" || fail 'desktop window tagged as a Steam X11 window'; }

# Desktop Mode default on a Steam Deck (panel 800x1280, rotated): 1024x640 window.
run "${kde[@]}" KSCREEN_JSON="$deck"
expect "$(desktop_cmd 1024x640)"; no_tagging
"$real_grep" -q 'mode: desktop; resolution: 1024x640; windowed' "$work/out"
"$real_grep" -qx 'env SDL_VIDEODRIVER= ENABLE_GAMESCOPE_WSI=0' "$work/log"
# Size unknown (no kscreen-doctor answer): same safe window.
run "${kde[@]}"
expect "$(desktop_cmd 1024x640)"
# Other screens: 80% of the logical desktop, 16:10, even sizes.
run "${kde[@]}" KSCREEN_JSON="$(monitor 1920 1080 1)"; expect "$(desktop_cmd 1382x864)"
run "${kde[@]}" KSCREEN_JSON="$(monitor 2560 1440 1.5)"; expect "$(desktop_cmd 1228x768)"
run "${kde[@]}" KSCREEN_JSON="$(monitor 2560 1600 1)"; expect "$(desktop_cmd 2048x1280)"
# The old opt-in is now the default and still accepted.
run "${kde[@]}" KSCREEN_JSON="$deck" LEPTON_DESKTOP_WINDOWED=1; expect "$(desktop_cmd 1024x640)"

# Explicit fullscreen: the main screen's real size, rotation applied.
run "${kde[@]}" KSCREEN_JSON="$deck" LEPTON_DESKTOP_FULLSCREEN=1
expect "$(desktop_cmd 1280x800 -f)"; no_tagging
"$real_grep" -q 'resolution: 1280x800; fullscreen' "$work/out"
run "${kde[@]}" KSCREEN_JSON="$(monitor 2560 1440 1.5)" LEPTON_DESKTOP_FULLSCREEN=1; expect "$(desktop_cmd 2560x1440 -f)"
# Both requested: stay windowed, say so.
run "${kde[@]}" KSCREEN_JSON="$deck" LEPTON_DESKTOP_FULLSCREEN=1 LEPTON_DESKTOP_WINDOWED=1
expect "$(desktop_cmd 1024x640)"; "$real_grep" -q 'both set; using a window' "$work/err"

# Custom resolution: Android's size and the window's; fullscreen only on request.
run "${kde[@]}" KSCREEN_JSON="$deck" LEPTON_RESOLUTION=1600x900; expect "$(desktop_cmd 1600x900)"
run "${kde[@]}" KSCREEN_JSON="$deck" LEPTON_RESOLUTION=1600x900 LEPTON_DESKTOP_FULLSCREEN=1; expect "$(desktop_cmd 1600x900 -f)"
run "${kde[@]}" KSCREEN_JSON="$deck" LEPTON_RESOLUTION=huge; expect "$(desktop_cmd 1024x640)"
"$real_grep" -q 'Invalid LEPTON_RESOLUTION: huge' "$work/err"

# Gaming Mode: SDL/X11 fullscreen at the X11 screen's size, Steam window tagged;
# Desktop Mode options do not apply.
for extra in "" LEPTON_DESKTOP_FULLSCREEN=1 LEPTON_DESKTOP_WINDOWED=1; do
    run "${gaming[@]}" ${extra:+"$extra"}
    expect "$(gaming_cmd 1280x800)"
    "$real_grep" -qx 'env SDL_VIDEODRIVER=x11 ENABLE_GAMESCOPE_WSI=0' "$work/log"
    "$real_grep" -qx 'xprop -id 0x400001 -f STEAM_GAME 32c -set STEAM_GAME 123' "$work/log" || fail 'Gaming Mode window not tagged'
    "$real_grep" -q 'mode: gaming; resolution: 1280x800; fullscreen' "$work/out"
done
run "${gaming[@]}" LEPTON_RESOLUTION=1920x1080; expect "$(gaming_cmd 1920x1080)"
run "${gaming[@]}" LEPTON_RESOLUTION=huge; expect "$(gaming_cmd 1280x800)"
# Explicit mode overrides detection.
run "${kde[@]}" "${gaming[@]}" LEPTON_DISPLAY_MODE=gaming; expect "$(gaming_cmd 1280x800)"

# Uncertain detection never picks Gaming Mode's fullscreen on a Wayland desktop.
run WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR="$work" DISPLAY=:0
expect "$(desktop_cmd 1024x640)"; "$real_grep" -q 'display mode uncertain' "$work/err"
# A Gamescope session is Gaming Mode even with Wayland variables present.
run "${gaming[@]}" WAYLAND_DISPLAY=gamescope-0 XDG_RUNTIME_DIR="$work"; expect "$(gaming_cmd 1280x800)"
# X11 only: the desktop Wayland backend cannot run; previous path, with a warning.
run DISPLAY=:0; expect "$(gaming_cmd 1280x800)"; "$real_grep" -q 'no Wayland display' "$work/err"

# Experimental direct desktop path stays opt-in and unchanged: no Gamescope.
run "${kde[@]}" LEPTON_DESKTOP_DIRECT=1
! "$real_grep" -q '^gamescope' "$work/log" || fail 'LEPTON_DESKTOP_DIRECT started Gamescope'
"$real_grep" -qx 'direct GAMESCOPE_WAYLAND_DISPLAY=wayland-0' "$work/log"

# Normal launches show no popup and leave no message file behind.
run "${kde[@]}" KSCREEN_JSON="$deck"
! "$real_grep" -q '^kdialog' "$work/log" || fail 'popup without a message'
# A launch Lepton refused: its message as a popup once Gamescope exits.
# Desktop: a regular Wayland dialog.
run "${kde[@]}" KSCREEN_JSON="$deck" FAKE_MESSAGE='com.example.game cannot start. Nothing has been deleted.'
"$real_grep" -qx 'kdialog QT=wayland SCALE= DISPLAY= --title Lepton: game could not start --error com.example.game cannot start. Nothing has been deleted.' "$work/log" || fail 'desktop popup missing'
"$real_grep" -qx 'Details: ~/.steam/steam/logs/lepton-steamlaunch-123.log' "$work/log" || fail 'popup lacks the log location'
[[ -z "$(find "$work" -maxdepth 1 -name 'lepton-message.*')" ]] || fail 'message file left behind'
# Gaming Mode: scaled X11 dialog on Steam's display, tagged so Steam shows it.
run "${gaming[@]}" FAKE_MESSAGE='com.example.game cannot start.'
"$real_grep" -qx 'kdialog QT=xcb SCALE=2 DISPLAY=:0 --title Lepton: game could not start --error com.example.game cannot start.' "$work/log" || fail 'Gaming Mode popup missing'
"$real_grep" -qx 'xprop -id 0x500002 -f STEAM_GAME 32c -set STEAM_GAME 123' "$work/log" || fail 'Gaming Mode popup not tagged'
"$real_grep" -qx 'xprop -id 0x400001 -f STEAM_GAME 32c -set STEAM_GAME 123' "$work/log"
# Binder preflight uses the same popup, before any Gamescope starts.
for mode in kde gaming; do
    declare -n envs="$mode"; rm -f "$work/log"
    if "${base[@]}" "${envs[@]}" FAKE_NO_BINDER=1 "$bridge" direct-game > "$work/out" 2> "$work/err"; then fail 'started without Binder'; fi
    "$real_grep" -q -- '--title Lepton Binder Unavailable --error Android Binder kernel support is unavailable.' "$work/log" || fail "$mode Binder popup missing"
    ! "$real_grep" -q '^gamescope' "$work/log" || fail 'Gamescope started without Binder'
    unset -n envs
done
"$real_grep" -qx 'xprop -id 0x500003 -f STEAM_GAME 32c -set STEAM_GAME 123' "$work/log" || fail 'Binder popup not tagged'

# The bridge never asks Gamescope for a borderless window.
! "$real_grep" -qE -- '(^|[[:space:]])(-b|--borderless)([[:space:]]|$)' "$bridge" || fail 'bridge passes --borderless'
echo 'PASS: gamescope bridge: desktop window by default (1024x640 on a Deck), fullscreen on request, custom resolution, Gaming Mode unchanged, uncertain detection stays windowed, refused launches and missing Binder shown as popups'
