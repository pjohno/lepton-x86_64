#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -Eeuo pipefail
export LD_PRELOAD=

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMAND=test-0800
LEPTON_CONTEXT="test-0800-$$"
NAME="lepton-$LEPTON_CONTEXT"
PODMAN_CMDLINE=()

exec {LEPTON_LOCKFD}>/tmp/lepton.lock
flock --timeout 10 "$LEPTON_LOCKFD"

source "$HERE/liblepton/liblepton.sh"
create_prefix

finish() {
    result=$?
    trap - EXIT
    podman rm -f "$NAME" >/dev/null 2>&1 || true
    remove_prefix >/dev/null 2>&1 || true
    if (( result == 0 )); then
        echo "PASS: Test 0800"
    else
        echo "FAIL: Test 0800 (exit $result)"
    fi
    exit "$result"
}
trap finish EXIT

echo "TEST 0800: Android init lifecycle"

# Keep all test data separate from the real sysbake.
BAKED_SYSTEM_DATA_DIR="$LEPTON_PREFIX/test-data"
mkdir -p "$BAKED_SYSTEM_DATA_DIR"

LEPTON_TEST_ROOTFS="$(readlink -e "${LEPTON_TEST_ROOTFS:?Set LEPTON_TEST_ROOTFS}")"
[[ "$LEPTON_TEST_ROOTFS" != "$(readlink -f "$HERE/images/rootfs")" ]]
[[ -f "$LEPTON_TEST_ROOTFS/system/build.prop" ]]
[[ -f "$LEPTON_TEST_ROOTFS/vendor/lib64/hw/vulkan.radeon.so" ]]
export LEPTON_TEST_ROOTFS
echo "Testing reproduced rootfs: $LEPTON_TEST_ROOTFS"

setup_container
if [[ "${LEPTON_TEST_PASTEL:-false}" == "true" ]]; then
    grep -qx 'ro.hardware.gralloc=minigbm_gbm_mesa' "$LEPTON_PREFIX/lepton.prop"
    grep -qx 'ro.hardware.vulkan=radeon' "$LEPTON_PREFIX/lepton.prop"
    sed -i 's/^ro.hardware.vulkan=radeon$/ro.hardware.vulkan=pastel/' "$LEPTON_PREFIX/lepton.prop"
    grep -E '^ro.hardware.(egl|vulkan|gralloc)=' "$LEPTON_PREFIX/lepton.prop"
fi
if [[ "${LEPTON_TEST_DISABLE_DEFERRED:-false}" == "true" ]]; then
    grep -qx 'ro.hardware.vulkan=radeon' "$LEPTON_PREFIX/lepton.prop"
    grep -qx 'ro.hardware.gralloc=minigbm_gbm_mesa' "$LEPTON_PREFIX/lepton.prop"
    echo 'debug.angle.feature_overrides_disabled=supportsSwapchainMaintenance1' >> "$LEPTON_PREFIX/lepton.prop"
    echo "ANGLE: disabled supportsSwapchainMaintenance1"
fi

ROOTFS="$LEPTON_TEST_ROOTFS"

podman run -d \
    --read-only \
    --env-host=false \
    --init=false \
    --name "$NAME" \
    --userns=keep-id:uid=0,gid=0 \
    --user 0:0 \
    --group-add keep-groups \
    "${PODMAN_CMDLINE[@]}" \
    --rootfs "$ROOTFS:O" \
    /init

LOGCAT_CAPTURE="$LEPTON_PREFIX/android-logcat.txt"

for second in {1..30}; do
    sleep 1
    state="$(podman inspect -f '{{.State.Status}}' "$NAME")"
    echo "${second}s: $state"
    [[ "$state" == running ]] || break

    if [[ "$second" == 2 || "$second" == 3 ]]; then
        timeout 3 podman exec "$NAME" /system/bin/logcat -b all -d -t 300             >> "$LOGCAT_CAPTURE" 2>"$LEPTON_PREFIX/logcat-error.txt" || true
    fi
done

state="$(podman inspect -f '{{.State.Status}}' "$NAME")"
echo "Container state after 30 seconds: $state"

if [[ "$state" != running ]]; then
    echo "--- Container exit details ---"
    podman inspect "$NAME" --format         'ExitCode={{.State.ExitCode}} OOMKilled={{.State.OOMKilled}} Error={{.State.Error}}'
    echo "--- Container logs ---"
    podman logs "$NAME" 2>&1 | tail -80 || true
    echo "--- Native crash tombstones ---"
    tombstone_dir="$(data_mount_path)/tombstones"
    if [[ -d "$tombstone_dir" ]]; then
        for f in "$tombstone_dir"/tombstone_*; do
            [[ -f "$f" && "$f" != *.pb ]] || continue
            echo "=== $(basename "$f") ==="
            grep -aEm 16 '^(Cmdline:|pid:|signal |Abort message:| *#[0-9]+ pc)' "$f" || true
        done
    else
        echo "No tombstones at $tombstone_dir"
    fi

    echo "--- Captured Android errors ---"
    if [[ -s "$LOGCAT_CAPTURE" ]]; then
        tail -n 80 "$LOGCAT_CAPTURE"
    else
        cat "$LEPTON_PREFIX/logcat-error.txt" 2>/dev/null || true
    fi
    exit 1
fi

echo "PASS: Android init container remains running"
echo "Android boot completed: $(podman exec "$NAME" /system/bin/getprop sys.boot_completed)"
for process in surfaceflinger system_server com.android.systemui; do
    podman exec "$NAME" /system/bin/pidof "$process" >/dev/null || {
        echo "FAIL: $process is not running"
        exit 1
    }
    echo "PASS: $process running"
done

echo "--- Graphics backend verification ---"
for pair in     "ro.hardware.gralloc:minigbm_gbm_mesa"     "ro.hardware.vulkan:radeon"     "debug.angle.feature_overrides_disabled:supportsSwapchainMaintenance1"; do
    key="${pair%%:*}"
    expected="${pair#*:}"
    actual="$(podman exec "$NAME" /system/bin/getprop "$key")"
    echo "$key=$actual"
    [[ "$actual" == "$expected" ]] || exit 1
done

echo "--- Graphics allocator process ---"
podman exec "$NAME" /system/bin/ps -A -o ARGS |
    grep -F 'allocator@4.0-service.minigbm_gbm_mesa'

echo "PASS: Graphics configuration and allocator verified"

echo "--- GPU driver verification ---"
podman exec "$NAME" /system/bin/sh -c '
    set -eu
    pid="$(pidof com.android.systemui)"
    pid="${pid%% *}"
    echo "SystemUI PID: $pid"

    for lib in libGLESv2_angle.so vulkan.radeon.so; do
        grep -Fq "$lib" "/proc/$pid/maps" || {
            echo "FAIL: $lib not loaded"
            exit 1
        }
        echo "PASS: $lib loaded"
    done

    ls -l "/proc/$pid/fd" | grep "/dev/dri/renderD" || {
        echo "FAIL: No GPU render-node FD found"
        exit 1
    }
    echo "PASS: GPU render device open"
'

podman top "$NAME" | sed -n "1,12p"

echo "--- Android crash log ---"
podman exec "$NAME" /system/bin/logcat -b crash -d -v threadtime | tail -n 120 || true

echo "--- Native tombstone summaries ---"
tombstone_dir="$(data_mount_path)/tombstones"
if [[ -d "$tombstone_dir" ]]; then
    for f in "$tombstone_dir"/tombstone_*; do
        [[ -f "$f" && "$f" != *.pb ]] || continue
        echo "=== $(basename "$f") ==="
        grep -aEm 15 '^(Cmdline:|pid:|signal |Abort message:| *#[0-9]+ pc)' "$f" || true
    done
fi

podman stop --time 5 "$NAME" >/dev/null
state="$(podman inspect -f '{{.State.Status}}' "$NAME")"
echo "Container state after stop: $state"
[[ "$state" == exited ]]

podman rm "$NAME" >/dev/null
echo "PASS: Container stopped and removed"
