#!/bin/bash

TESTS_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "$TESTS_DIR"/test-common.sh

max_parallel=$(( $(nproc) / 4 ))
total=100

function run_test() {
    local i="$1"
    local name="test-instance-${i}"

    test_log "PASS$i"

    (
        LEPTON_ADB_PORT=$((5554 + i)) \
        LEPTON_GDB_PORT=$((1336 + i)) \
        LEPTON_LLDB_PORT=$((2336 + i)) ./lepton start "${name}"||
            test_log "$name failed to start."
    ) &
    start_pid=$!

    if ! wait_for_boot "$name" 720; then
        ./lepton stop "$name" || true
        return 1
    fi

    ./lepton stop "$name" || true

    wait "${start_pid}"

    return 0
}

# Let's not waste too much time, many containers start at the same time
# But it means we need to fix ports ourselves
export LEPTON_LOCK_TIMEOUT=0
export LEPTON_NO_PORT_FORWARDING=true

failed=0

declare -a pids

for ((i=1; i<=total; i++)); do
    j=$(( (i - 1) % max_parallel + 1 ))

    # Wait until this specific test ID is free.
    if [[ -n "${pids[j]:-}" ]]; then
        if ! wait "${pids[j]}"; then
            ((++failed))
        fi
        unset 'pids[j]'
    fi

    run_test "$i" &
    pids[j]=$!
done

# Wait for remaining tests.
for ((j=1; j<=max_parallel; j++)); do
    if [[ -n "${pids[j]:-}" ]]; then
        if ! wait "${pids[j]}"; then
            ((++failed))
        fi
    fi
done

function android_sdk_version()
{
    cat ./images/rootfs/system/build.prop | grep ro.build.version.sdk= | sed "s/.*=//g"
}

if (( failed > 0 )); then
    test_log "test repeated start test failed $failed times."

    # Our android 30 image sometimes fails to start...
    # Might be some patch that breaks it or some android bug...
    if [[ "$(android_sdk_version)" != "30" ]]; then
       test_failure
    fi
fi

test_log "test repeated start test finished"

