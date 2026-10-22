#!/bin/bash

set -euo pipefail

TESTS_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "$TESTS_DIR"/test-common.sh

function check_debugger()
{
    local app_pid tracer_pid tracer_comm

    for app_pid in /proc/[0-9]*; do
        app_pid=${app_pid##*/}

        tracer_pid="$(awk '/^TracerPid:/ {print $2}' "/proc/${app_pid}/status")"

        if [[ -z "${tracer_pid}" ]]; then
            continue
        fi

        tracer_comm="$(ps -p "${tracer_pid}" -o comm= 2>/dev/null)"

        test_log "FOUND TRACER PID: ${app_pid} $(ps -p "${app_pid}" -o comm=) ${tracer_pid} ${tracer_comm} ... $2"

        if [[ "${tracer_pid}" -gt 1 ]] &&
           [[ "${tracer_comm}" == "$2" ]]; then
            return 0
        fi
    done

    return 1
}

./lepton start_early_debug &

sleep 2

if [[ "$(./lepton ps | grep "early_debug" | grep "${_GREEN}")" == "" ]]; then
    test_log "lepton ps command failed due to color!"
    test_failure
fi

kill -9 $(podman inspect -f '{{ .State.Pid }}' lepton-early_debug)

if [[ "$(./lepton ps | grep "early_debug" | grep "${_RED}")" == "" ]]; then
    test_log "lepton ps command failed due to color!"
    test_failure
fi

cp tests/test-apk.apk .

test_log "Testing install_app"

monitor_logcat dev &
LOGCAT_PID="$!"

(./lepton start dev || test_log "container dev failed to start, test will timeout.") &

wait_for_boot dev

# steam_appid.txt/UECommandLine.txt next to the apk should be copied into the container
touch steam_appid.txt
touch UECommandLine.txt

./lepton install_app dev test-apk.apk

if [[ "$(./lepton ps | grep "dev" | grep com.example.neon42 | grep "${_GREEN}")" == "" ]]; then
    test_log "lepton install_app failed!"
    test_failure
fi

APP_PATH="$(./lepton run dev pm path com.example.neon42)"
APP_PATH="${APP_PATH#package:}"
APP_PATH="${APP_PATH%/base.apk}"

rm steam_appid.txt
./lepton extract dev "${APP_PATH}/steam_appid.txt"

if [[ ! -f steam_appid.txt ]]; then
    test_log "steam_appid.txt was not copied into the APP_PATH: ${APP_PATH} as expected!"
    test_failure
fi

rm UECommandLine.txt
./lepton extract dev "${APP_PATH}/UECommandLine.txt"

if [[ ! -f UECommandLine.txt ]]; then
    test_log "UECommandLine.txt was not copied into the APP_PATH: ${APP_PATH} as expected!"
    test_failure
fi

./lepton stop dev

kill "${LOGCAT_PID}"

test_log "Testing lepton start"

monitor_logcat dev &
LOGCAT_PID="$!"

# Lepton start with no argument should be the same as lepton start dev
(./lepton start || test_log "container failed to start, test will timeout.") &

wait_for_boot dev

./lepton stop dev

kill "${LOGCAT_PID}"

test_log "Testing gdb_server"

monitor_logcat test-apk.apk &
LOGCAT_PID="$!"

(./lepton start test-apk.apk || test_log "container test-apk.apk failed to start, test will timeout.") &

wait_for_boot test-apk.apk

wait_for_app test-apk.apk com.example.neon42

./lepton gdb_server test-apk.apk &

sleep 10

if [[ -z "$(pgrep gdbserver64)" ]]; then
    test_log "lepton gdb_server failed!"
    test_failure
fi

./lepton stop test-apk.apk

kill "${LOGCAT_PID}"

if [[ "$(pgrep gdbserver64)" != "" ]]; then
    test_log "lepton gdb_server failed after stopping!"
    test_failure
fi

test_log "Testing kill_gdb_server"

monitor_logcat test-apk.apk &
LOGCAT_PID="$!"

(./lepton start test-apk.apk || test_log "container test-apk.apk failed to start, test will timeout.") &

wait_for_boot test-apk.apk

wait_for_app test-apk.apk com.example.neon42

./lepton gdb_server test-apk.apk &

sleep 10

if [[ -z "$(pgrep gdbserver64)" ]]; then
    test_log "lepton gdb_server failed (2)!"
    test_failure
fi

./lepton kill_gdb_server test-apk.apk

if [[ "$(pgrep gdbserver64)" != "" ]]; then
    test_log "lepton gdb_server failed after kill!"
    test_failure
fi

./lepton stop test-apk.apk

kill "${LOGCAT_PID}"

test_log "Testing gdb_attach"

monitor_logcat test-apk.apk &
LOGCAT_PID="$!"

(./lepton start test-apk.apk || test_log "container test-apk.apk failed to start, test will timeout.") &

wait_for_boot test-apk.apk

wait_for_app test-apk.apk com.example.neon42

unbuffer ./lepton gdb_attach test-apk.apk &

sleep 10

if [[ -z "$(pgrep gdbserver64)" ]]; then
    test_log "lepton gdb_attach failed, no gdbserver!"
    test_failure
fi

sleep 3

if [[ -z "$(pidof gdb)" ]]; then
    test_log "lepton gdb_attach failed, no gdb!"
    test_failure
fi

if ! check_debugger com.example.neon42 gdbserver64; then
    test_log "lepton gdb_attach failed, not attached to right process!"
    test_failure
fi

./lepton stop test-apk.apk

killall gdb || true
kill "${LOGCAT_PID}"

test_log "Testing gdb_attach after gdb_server"

monitor_logcat test-apk.apk &
LOGCAT_PID="$!"

(./lepton start test-apk.apk || test_log "container test-apk.apk failed to start, test will timeout.") &

wait_for_boot test-apk.apk

wait_for_app test-apk.apk com.example.neon42

./lepton gdb_server test-apk.apk

sleep 10

if [[ -z "$(pgrep gdbserver64)" ]]; then
    test_log "lepton gdb_attach after gdb_server test failed, no gdbserver!"
    test_failure
fi

sleep 3

if [[ "$(pidof gdb)" != "" ]]; then
    test_log "lepton gdb_attach after gdb_server test failed, gdb already present!"
    test_failure
fi

unbuffer ./lepton gdb_attach test-apk.apk &

sleep 10

if [[ -z "$(pgrep gdbserver64)" ]]; then
    test_log "lepton gdb_attach after gdb_server failed, no gdbserver after attach!"
    test_failure
fi

sleep 3

if [[ -z "$(pidof gdb)" ]]; then
    test_log "lepton gdb_attach (gdb_server test) failed, no gdb!"
    test_failure
fi

if ! check_debugger com.example.neon42 gdbserver64; then
    test_log "lepton gdb_attach failed, not attached to right process (2)!"
    test_failure
fi

./lepton stop test-apk.apk

killall gdb || true
kill "${LOGCAT_PID}"

test_log "Testing lldb_server"

monitor_logcat test-apk.apk &
LOGCAT_PID="$!"

(./lepton start test-apk.apk || test_log "container test-apk.apk failed to start, test will timeout.") &

wait_for_boot test-apk.apk

wait_for_app test-apk.apk com.example.neon42

./lepton lldb_server test-apk.apk &

sleep 10

if [[ -z "$(pgrep lldb-server)" ]]; then
    test_log "lepton lldb_server failed!"
    test_failure
fi

./lepton stop test-apk.apk

kill "${LOGCAT_PID}"

if [[ "$(pgrep lldb-server)" != "" ]]; then
    test_log "lepton lldb_server failed after stopping!"
    test_failure
fi

test_log "Testing kill_lldb_server"

monitor_logcat test-apk.apk &
LOGCAT_PID="$!"

(./lepton start test-apk.apk || test_log "container test-apk.apk failed to start, test will timeout.") &

wait_for_boot test-apk.apk

wait_for_app test-apk.apk com.example.neon42

./lepton lldb_server test-apk.apk &

sleep 10

if [[ -z "$(pgrep lldb-server)" ]]; then
    test_log "lepton lldb_server failed!"
    test_failure
fi

./lepton kill_lldb_server test-apk.apk

if [[ "$(pgrep lldb-server)" != "" ]]; then
    test_log "lepton lldb_server failed after kill!"
    test_failure
fi

./lepton stop test-apk.apk

kill "${LOGCAT_PID}"

test_log "Testing lldb_attach"

monitor_logcat test-apk.apk &
LOGCAT_PID="$!"

(./lepton start test-apk.apk || test_log "container test-apk.apk failed to start, test will timeout.") &

wait_for_boot test-apk.apk

wait_for_app test-apk.apk com.example.neon42

unbuffer ./lepton lldb_attach test-apk.apk &

timeout 20s bash -c '
  until pgrep "lldb-server" >/dev/null; do
    sleep 1
  done
'

if [[ -z "$(pgrep lldb-server)" ]]; then
    test_log "lepton lldb_attach failed, no lldbserver!"
    test_failure
fi

timeout 20s bash -c '
  until pgrep -x "lldb" >/dev/null; do
    sleep 1
  done
'

if [[ -z "$(pgrep -x lldb)" ]]; then
    test_log "lepton lldb_attach failed, no lldb!"
    test_failure
fi

if ! check_debugger com.example.neon42 lldb-server; then
    test_log "lepton lldb_attach failed, not attached to right process!"
    test_failure
fi

./lepton stop test-apk.apk

killall -9 lldb || true
kill "${LOGCAT_PID}"

test_log "Testing lldb_attach after lldb_server"

monitor_logcat test-apk.apk &
LOGCAT_PID="$!"

(./lepton start test-apk.apk || test_log "container test-apk.apk failed to start, test will timeout.") &

wait_for_boot test-apk.apk

wait_for_app test-apk.apk com.example.neon42

./lepton lldb_server test-apk.apk

if [[ -z "$(pgrep lldb-server)" ]]; then
    test_log "lepton lldb_attach after lldb_server test failed, no lldbserver!"
    test_failure
fi

if [[ "$(pgrep -x lldb)" != "" ]]; then
    test_log "lepton lldb_attach after lldb_server test failed, lldb already present!"
    test_failure
fi

unbuffer ./lepton lldb_attach test-apk.apk &

timeout 20s bash -c '
  until pgrep "lldb-server" >/dev/null; do
    sleep 1
  done
'

if [[ -z "$(pgrep lldb-server)" ]]; then
    test_log "lepton lldb_attach after lldb_server failed, no lldbserver after attach!"
    test_failure
fi

timeout 20s bash -c '
  until pgrep -x "lldb" >/dev/null; do
    sleep 1
  done
'

if [[ -z "$(pgrep -x lldb)" ]]; then
    test_log "lepton lldb_attach failed, no lldb (2)!"
    test_failure
fi

if ! check_debugger com.example.neon42 lldb-server; then
    test_log "lepton lldb_attach failed, not attached to right process (2)!"
    test_failure
fi

./lepton stop test-apk.apk

killall lldb || true
kill "${LOGCAT_PID}"

test_log "Testing whether perfetto is setup during startup"

monitor_logcat test-apk.apk &
LOGCAT_PID="$!"

sudo /usr/bin/steamos-polkit-helpers/steamos-devkit-mode --enable

# TODO: atrace does not work in gitlab CI
mv images/rootfs/system/bin/atrace .
printf '#!/bin/sh\n\nexit 0' > images/rootfs/system/bin/atrace
chmod +x images/rootfs/system/bin/atrace

PERFETTO_PRODUCER_SOCK_NAME=/tmp/perfetto-producer,0.0.0.0:20000 /usr/bin/tracebox traced --set-socket-permissions=perf:0660:perf:0660 --enable-relay-endpoint &
TRACEBOX_PID="$!"

(./lepton start test-apk.apk || test_log "container test-apk.apk failed to start, test will timeout.") &

wait_for_boot test-apk.apk

wait_for_app test-apk.apk com.example.neon42

sudo mkdir -p /sys/kernel/tracing
sudo mount -t tracefs tracefs /sys/kernel/tracing

sudo mkdir -p /sys/kernel/debug
sudo mount -t debugfs debugfs /sys/kernel/debug

if [[ "$(pgrep tracebox | wc -l)" != "2" ]]; then
    test_log "lepton perfetto test failed, tracebox traced_probes or tracebox traced missing!"
    ps fax
    test_log "$(ps fax)"
    test_failure
fi

./lepton perfetto --config=system test-apk.apk

if [[ "$(ls -1 /tmp | grep lepton-test-apk.apk-system|grep pftrace)" == "" ]]; then
    test_log "lepton perfetto test failed, no pftrace file created!"
    test_failure
fi

./lepton stop test-apk.apk

if [[ "$(pgrep tracebox | wc -l)" != "1" ]]; then
    test_log "lepton perfetto failed, tracebox did not exit"
    test_failure
fi

kill "${LOGCAT_PID}"
kill "${TRACEBOX_PID}"

mv atrace images/rootfs/system/bin/atrace

test_log "Testing adb install"

monitor_logcat dev &
LOGCAT_PID="$!"

(./lepton start dev || test_log "container dev failed to start, test will timeout.") &

wait_for_boot dev

sleep 3

/usr/lib/android-sdk/platform-tools/adb devices
/usr/lib/android-sdk/platform-tools/adb connect localhost:5555
/usr/lib/android-sdk/platform-tools/adb -s localhost:5555 install test-apk.apk

if [[ "$(./lepton ps | grep "dev" | grep com.example.neon42 | grep "${_GREEN}")" == "" ]]; then
    test_log "adb install failed!"
    test_failure
fi

./lepton stop dev

kill "${LOGCAT_PID}"

test_log "renderdoc"

monitor_logcat dev &
LOGCAT_PID="$!"

(ENABLE_VULKAN_RENDERDOC_CAPTURE=1 EnableFrameEndMarkers=1 ./lepton start dev || test_log "container dev failed to start, test will timeout.") &

wait_for_boot dev

./lepton install_app dev test-apk.apk --renderdoc

sleep 3

if [[ "$(pgrep -f org.renderdoc.renderdoccmd.arm64)" == "" ]]; then
    test_log "renderdoc test failed, org.renderdoc.renderdoccmd.arm64 not running!"
    test_failure
fi

./lepton stop dev

kill "${LOGCAT_PID}"

test_log "Testing strace"

if [[ -f "/home/steamos/.local/share/Steam/logs/lepton-logcats/test-apk.apk/strace-com.example.neon42.log" ]]; then
    test_log "test failed because the strace log existed before the test!"
    test_failure
fi

monitor_logcat test-apk.apk &
LOGCAT_PID="$!"

(LEPTON_STRACE=true ./lepton start test-apk.apk || test_log "container test-apk.apk failed to start, test will timeout.") &

wait_for_boot test-apk.apk

# Wait for some app action to capture in strace
sleep 30

./lepton stop test-apk.apk

cat /home/steamos/.local/share/Steam/logs/lepton-logcats/test-apk.apk/strace-com.example.neon42.debug

if [[ ! -f "/home/steamos/.local/share/Steam/logs/lepton-logcats/test-apk.apk/strace-com.example.neon42.log" ]]; then
    test_log "test failed because the strace log does not exist after the test!"
    test_failure
fi

kill "${LOGCAT_PID}"

test_log "Testing LEPTON_DEBUG_LAUNCH"

monitor_logcat test-apk.apk &
LOGCAT_PID="$!"

(LEPTON_DEBUG_LAUNCH=true ./lepton start test-apk.apk || test_log "container test-apk.apk failed to start, test will timeout.") &

wait_for_boot test-apk.apk
echo "BEFORE WAIT_FOR_DEBUGGER $SECONDS"
timeout 20s bash -c '
  until [[ "$(./lepton run test-apk.apk getprop ro.lepton.wait_for_debugger)" == "true" ]]; do
    sleep 1
  done
'
echo "BEFORE READY_FOR_DEBUGGER $SECONDS"

if ! timeout 10s bash -c '
    while [[ "$(./lepton run test-apk.apk getprop ro.lepton.ready_for_debugger)" != "true" ]]; do
        sleep 1
    done
'; then
    test_log "test failed because ro.lepton.ready_for_debugger is not true!"
    test_failure
fi

unbuffer ./lepton lldb_attach test-apk.apk &
echo "BEFORE LLDB_SERVER $SECONDS"

timeout 20s bash -c '
  until pgrep "lldb-server" >/dev/null; do
    sleep 1
  done
'

if [[ -z "$(pgrep lldb-server)" ]]; then
    test_log "lepton lldb_attach failed, no lldbserver (2)!"
    test_failure
fi

echo "BEFORE LLDB $SECONDS"
timeout 20s bash -c '
  until pgrep -x "lldb" >/dev/null; do
    sleep 1
  done
'

if [[ -z "$(pgrep -x lldb)" ]]; then
    test_log "lepton lldb_attach (LEPTON_DEBUG_LAUNCH) failed, no lldb!"
    test_failure
fi
echo "BEFORE DEADLINE $SECONDS"

deadline=$((SECONDS + 120))
while ! check_debugger com.example.neon42 lldb-server; do
    if (( SECONDS >= deadline )); then
        test_log "lepton lldb_attach failed during wait_for_debugger test, not attached to right process!"
        ./lepton run test-apk.apk ps -A
        ps fax
        test_failure
        break
    fi
    sleep 0.5
done
echo "BEFORE STOP $SECONDS"

./lepton stop test-apk.apk

killall lldb || true
kill "${LOGCAT_PID}"

test_log "Testing APP_WANTS_FLATSCREEN"

monitor_logcat test-apk.apk &
LOGCAT_PID="$!"

(./lepton start test-apk.apk || test_log "container test-apk.apk failed to start, test will timeout.") &

wait_for_boot test-apk.apk

if [[ "$(./lepton run test-apk.apk getprop lepton.headless)" != "true" ]]; then
    test_log "test failed, because lepton.headless != true"
    test_failure
fi

./lepton stop test-apk.apk

kill "${LOGCAT_PID}"

monitor_logcat test-apk.apk &
LOGCAT_PID="$!"

(APP_WANTS_FLATSCREEN=true ./lepton start test-apk.apk || test_log "container test-apk.apk failed to start, test will timeout.") &

wait_for_boot test-apk.apk

if [[ "$(./lepton run test-apk.apk getprop lepton.headless)" != "false" ]]; then
    test_log "test failed, because lepton.headless != false"
    test_failure
fi

./lepton stop test-apk.apk

kill "${LOGCAT_PID}"

test_log "test finished."
