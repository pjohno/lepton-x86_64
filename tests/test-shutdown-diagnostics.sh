#!/usr/bin/env bash
# Diagnostic collection must not delay graceful shutdown or profile cleanup.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
export TEST_DIR="$work" LEPTON_SOURCE="$repo/compat_tool/lepton" LIBLEPTON_SOURCE="$repo/compat_tool/liblepton/liblepton.sh"
cat > "$work/teardown-fixture" <<'FIXTURE'
set -Eeuo pipefail
eval "$(sed -n '/^        function teardown()/,/^        }/p' "$LEPTON_SOURCE")"
LEPTON_CONTEXT=steamlaunch-diagnostics
MOVED_INACCESSIBLE=''
app_start_time=$(( $(date +%s) - 10 ))
println() { printf '%s\n' "$*" >> "$TEST_DIR/teardown.log"; }
strace_enabled() { return 1; }
ndk_note_early_exit() { :; }
uninherit_lepton_lock() { :; }
logcat_debug_dir() { echo "$TEST_DIR/logcat"; }
dump_logcat() {
    # Synchronous capture here would deadlock before reaching kill_container.
    while [[ ! -e "$TEST_DIR/stop-started" ]]; do sleep 0.01; done
    touch "$TEST_DIR/capture-done"
}
stop_lepton_hotplug_watcher() { :; }
kill_container() { touch "$TEST_DIR/stop-started"; }
logcat_debug() { :; }
cleanup_container() { touch "$TEST_DIR/cleanup-done"; }
remove_prefix() { :; }
is_steamlaunch() { return 0; }
log_moved_dirs() { :; }
kill_descendants() { :; }
echo fixture-save > "$TEST_DIR/save"
teardown
[[ -f "$TEST_DIR/capture-done" && -f "$TEST_DIR/cleanup-done" ]]
[[ "$(cat "$TEST_DIR/save")" == fixture-save ]]
grep -q 'Early shutdown detected (<30s); profile retained' "$TEST_DIR/teardown.log"
FIXTURE
timeout 5 bash "$work/teardown-fixture"

# Exercise real timeout and non-interactive capture against an executable fake
# Podman. A hanging Android logcat cannot hold shutdown diagnostics indefinitely.
mkdir "$work/bin"
cat > "$work/bin/podman" <<'PODMAN'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_DIR/capture-commands"
[[ "$1 $2" == 'exec -i' && "$*" != *' -it '* ]] || exit 2
if [[ "${CAPTURE_MODE:-success}" == hang ]]; then exec sleep 60; fi
printf 'synthetic-logcat\n'
PODMAN
chmod +x "$work/bin/podman"
export PATH="$work/bin:$PATH"
eval "$(sed -n '/^function dump_logcat()/,/^}/p' "$LIBLEPTON_SOURCE")"
println() { printf '%s\n' "$*" >> "$work/capture.log"; }
container_running() { [[ "${IS_RUNNING:-yes}" == yes ]]; }
LEPTON_CONTEXT=steamlaunch-diagnostics
dump_logcat "$work/success"
[[ "$(find "$work/success" -name '*.log' | wc -l)" == 5 ]]
for buffer in main system kernel crash radio; do
    [[ "$(cat "$work/success/logcat-$buffer.log")" == synthetic-logcat ]]
done
SECONDS=0
CAPTURE_MODE=hang dump_logcat "$work/hang"
(( SECONDS < 6 ))
[[ "$(grep -c 'capture incomplete' "$work/capture.log")" == 5 ]]
IS_RUNNING=no dump_logcat "$work/stopped"
[[ ! -e "$work/stopped" ]]

# Absent containers are normal, errors from actual removal are actionable,
# and neither path touches saved profile data.
eval "$(sed -n '/^function cleanup_container()/,/^}/p' "$LIBLEPTON_SOURCE")"
podman() {
    case "$1 ${2:-}" in
        'container exists') return "${MOCK_EXISTS_STATUS:-1}" ;;
        'rm lepton-'*) echo 'synthetic removal failure'; return 125 ;;
    esac
}
kill_container() { :; }
cleanup_container
! grep -q 'stopped container retained' "$work/capture.log"
MOCK_EXISTS_STATUS=0 cleanup_container
grep -q 'stopped container retained.*synthetic removal failure' "$work/capture.log"
MOCK_EXISTS_STATUS=125 cleanup_container
grep -q 'cannot inspect.*container and profile retained' "$work/capture.log"
[[ "$(cat "$work/save")" == fixture-save ]]
echo 'PASS: diagnostics concurrent with shutdown, real bounded non-TTY capture, early-exit logging, informative cleanup warnings; saves intact'
