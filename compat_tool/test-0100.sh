#!/usr/bin/env bash
set -Eeuo pipefail
export LD_PRELOAD=

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMAND=test-0100
LEPTON_CONTEXT="test-0100-$$"
PODMAN_CMDLINE=()

exec {LEPTON_LOCKFD}>/tmp/lepton.lock
flock --timeout 10 "$LEPTON_LOCKFD"

source "$HERE/liblepton/liblepton.sh"

create_prefix
TEST_PREFIX="$LEPTON_PREFIX"

finish() {
    result=$?
    trap - EXIT
    set +e

    cleanup_container "$LEPTON_CONTEXT" >/dev/null 2>&1
    remove_prefix >/dev/null 2>&1

    if [[ -e "$TEST_PREFIX" ]] ||
       podman container exists "lepton-$LEPTON_CONTEXT"; then
        echo "FAIL: cleanup left temporary state"
        result=1
    fi

    if (( result == 0 )); then
        echo "PASS: setup and cleanup"
    else
        echo "FAIL: setup or cleanup (exit $result)"
    fi
    exit "$result"
}
trap finish EXIT

echo "TEST 0100: Filesystem setup and cleanup"

test -x "$HERE/images/rootfs/system/bin/sh"

setup_container

mount_count=0
for arg in "${PODMAN_CMDLINE[@]}"; do
    if [[ "$arg" == type=bind,* ]]; then
        ((mount_count += 1))
    fi
done

echo "Configured bind mounts: $mount_count"
(( mount_count > 0 ))
echo "PASS: mount configuration generated"
