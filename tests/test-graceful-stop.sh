#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Steam Stop: kill_container sends HOME, waits for the game to save, lets
# Android power off, and only then falls back to Valve's instant stop.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
lib="$repo/compat_tool/liblepton/liblepton.sh"
for fn in container_running graceful_stop_container kill_container parent_pid is_ancestor_of; do
    eval "$(sed -n "/^function $fn()/,/^}/p" "$lib")"
    declare -F "$fn" > /dev/null || { echo "missing $fn"; exit 1; }
done

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
log="$work/podman.log"
println() { printf '%s\n' "$*" >> "$work/messages"; }
unlock_lepton() { :; }
lock_lepton() { :; }
systemctl() { :; }
sleep() { echo "sleep $1" >> "$log"; }
timeout() { shift; "$@"; }
# Fake container: running until `reboot -p`, then it powers off unless
# POWER_OFF=never (a hung Android).
podman() {
    echo "podman $*" >> "$log"
    case "$1 ${2:-}" in
        "container inspect") [[ -e "$work/running" ]] && echo true || echo false ;;
        "inspect -f") echo 4242 ;;
        "exec -i"|"exec lepton-"*)
            [[ -e "$work/running" ]] || return 125
            if [[ "$*" == *"reboot -p"* && "${POWER_OFF:-yes}" == yes ]]; then rm -f "$work/running"; fi ;;
        "stop -t") rm -f "$work/running" ;;
    esac
}
reset() { : > "$log"; : > "$work/messages"; touch "$work/running"; }

# Running game: HOME, save wait, reboot, clean power-off, then the fallback.
reset; kill_container steamlaunch-123
grep -n . "$log" > "$work/order"
home=$(grep -m1 'input keyevent KEYCODE_HOME' "$work/order" | cut -d: -f1)
save=$(grep -m1 'sleep 3$' "$work/order" | cut -d: -f1)
reboot=$(grep -m1 'reboot -p' "$work/order" | cut -d: -f1)
stop=$(grep -m1 'stop -t 0' "$work/order" | cut -d: -f1)
(( home < save && save < reboot && reboot < stop ))
grep -q 'Android powered off cleanly' "$work/messages"
[[ ! -e "$work/running" ]]

# Android hangs: the wait is bounded, then Valve's podman stop -t 0 runs.
reset; SECONDS=0; POWER_OFF=never LEPTON_STOP_SHUTDOWN_WAIT=0 kill_container steamlaunch-123
grep -q 'did not power off within 0s, forcing stop' "$work/messages"
grep -q 'stop -t 0 lepton-steamlaunch-123' "$log"
[[ ! -e "$work/running" ]]

# Both waits 0: no HOME, no extra sleeps (Valve's behaviour).
reset; LEPTON_STOP_SAVE_WAIT=0 LEPTON_STOP_SHUTDOWN_WAIT=0 kill_container steamlaunch-123
! grep -q KEYCODE_HOME "$log"
! grep -q '^sleep' "$log"
grep -q 'stop -t 0' "$log"

# Bad values fall back to the defaults instead of failing.
reset; LEPTON_STOP_SAVE_WAIT=abc kill_container steamlaunch-123
grep -q 'sleep 3$' "$log"

# sysbake and an already stopped container keep Valve's instant stop.
reset; kill_container sysbake
! grep -q KEYCODE_HOME "$log"
reset; rm -f "$work/running"; kill_container steamlaunch-123
! grep -q KEYCODE_HOME "$log"
grep -q 'stop -t 0' "$log"

# Steam's Stop path still goes through kill_container from teardown.
grep -q 'kill_container "${LEPTON_CONTEXT}" --quiet' "$repo/compat_tool/lepton"
echo 'PASS: graceful stop: HOME and save wait before reboot, bounded power-off wait, Valve fallback, sysbake unchanged'
