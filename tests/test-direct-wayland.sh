#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Direct launch diagnostics/socket handoff/exit and signal handling, no Android.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin"
real_grep="$(command -v grep)"
cat > "$work/bin/grep" <<SHIM
#!/bin/bash
[[ "\${!#}" == /proc/filesystems ]] && exit \${NO_BINDER:-0}
exec '$real_grep' "\$@"
SHIM
cat > "$work/bin/kdialog" <<'GAME'
#!/bin/bash
printf 'dialog %s\n' "$*" >> "$LOG"
GAME
cat > "$work/bin/game" <<'GAME'
#!/bin/bash
printf 'game %s %s\n' "$GAMESCOPE_WAYLAND_DISPLAY" "$SteamAppId" >> "$LOG"
printf 'policy %s %s\n' "${LEPTON_LOCAL_FULLSCREEN:-unset}" "${LEPTON_LOCAL_OUTPUT:-unset}" >> "$LOG"
if [[ -n "${HOLD:-}" ]]; then
    trap 'echo terminated >> "$LOG"; exit 0' TERM
    touch "$READY"
    while :; do sleep 0.1; done
fi
[[ -z "${MESSAGE:-}" ]] || printf '%s\n' "$MESSAGE" > "$LEPTON_MESSAGE_FILE"
exit "${RESULT:-0}"
GAME
chmod +x "$work/bin/"*
python3 - "$work/wayland-test" <<'PY'
import socket, sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])
PY
base=(env -i PATH="$work/bin:/usr/bin:/bin" HOME="$work" LOG="$work/log" READY="$work/ready" SteamAppId=123 XDG_RUNTIME_DIR="$work" WAYLAND_DISPLAY=wayland-test)
launcher="$repo/compat_tool/tools/lepton-direct-wayland"
"${base[@]}" "$launcher" game > "$work/out"
grep -qx 'game wayland-test 123' "$work/log"
grep -q 'no Gamescope' "$work/out"
# Only the profile-selected direct path enables fullscreen policy.
cat > "$work/bin/kscreen-doctor" <<'KDE'
#!/bin/bash
printf '%s\n' '{"outputs":[{"name":"off","enabled":false,"primary":true},{"name":"DP-2","enabled":true,"priority":2},{"name":"DP-1","enabled":true,"priority":1}]}'
KDE
chmod +x "$work/bin/kscreen-doctor"
for mode in default 0 1; do
    : > "$work/log"
    extra=(); [[ "$mode" == default ]] || extra=(LEPTON_LOCAL_FULLSCREEN="$mode")
    "${base[@]}" LEPTON_LOCAL_DISPLAY_ACTIVE=1 "${extra[@]}" "$launcher" game > "$work/out"
    expected="$mode"; [[ "$mode" != default ]] || expected=1
    grep -qx "policy $expected DP-1" "$work/log"
done
for mode in '' 2 -1 yes; do
    : > "$work/log"
    if "${base[@]}" LEPTON_LOCAL_DISPLAY_ACTIVE=1 LEPTON_LOCAL_FULLSCREEN="$mode" "$launcher" game > "$work/out" 2>&1; then exit 1; else result=$?; fi
    [[ "$result" == 2 ]]
    grep -q 'LEPTON_LOCAL_FULLSCREEN must be' "$work/out"
    if grep -q '^game ' "$work/log"; then exit 1; fi
done
# Missing environment, a missing socket and a regular file all refuse to start.
touch "$work/not-a-socket"
for extra in WAYLAND_DISPLAY= XDG_RUNTIME_DIR= WAYLAND_DISPLAY=missing WAYLAND_DISPLAY=not-a-socket; do
    : > "$work/log"
    if "${base[@]}" "$extra" "$launcher" game > "$work/out" 2>&1; then exit 1; fi
    grep -q 'Direct Wayland requires' "$work/out"
    if grep -q '^game ' "$work/log"; then exit 1; fi
    grep -q 'dialog.*Wayland Unavailable' "$work/log"
done
: > "$work/log"
if "${base[@]}" NO_BINDER=1 "$launcher" game > "$work/out" 2>&1; then exit 1; fi
grep -q 'dialog.*Binder Unavailable' "$work/log"
if grep -q '^game ' "$work/log"; then exit 1; fi
: > "$work/log"
if "${base[@]}" MESSAGE='Profile refused; data retained' RESULT=7 "$launcher" game > "$work/out" 2>&1; then exit 1; else status=$?; fi
[[ "$status" == 7 ]]
grep -q 'dialog.*Profile refused; data retained' "$work/log"
[[ -z "$(find "$work" -name 'lepton-message.*' -print -quit)" ]]
# TERM reaches the existing launcher child and waits for normal child shutdown.
"${base[@]}" HOLD=1 "$launcher" game > "$work/out" 2>&1 &
pid=$!
for ((i=0; i<100; i++)); do [[ ! -e "$work/ready" ]] || break; sleep 0.02; done
[[ -e "$work/ready" ]]
kill -TERM "$pid"
wait "$pid" || true
grep -qx terminated "$work/log"
[[ -z "$(find "$work" -name 'lepton-message.*' -print -quit)" ]]
echo 'PASS: direct Wayland: socket validation, Binder, host socket/AppID, refusal popup, exit status, TERM forwarding and cleanup'
