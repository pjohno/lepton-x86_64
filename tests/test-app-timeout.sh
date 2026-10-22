#!/bin/bash

set -euo pipefail

TESTS_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "$TESTS_DIR"/test-common.sh

monitor_logcat test-apk.apk &
LOGCAT_PID="$!"

cp tests/test-apk.apk .

sed -i "/am start/d" liblepton/app_metadata.sh

(./lepton start test-apk.apk || test_log "container test-apk.apk failed to start, test will timeout.") &
wait_for_boot test-apk.apk

# The launch timeout only starts once the app has been installed and may launch.
end=$((SECONDS + 120))
while [[ "$(./lepton run test-apk.apk getprop ro.lepton.app_baked 2>/dev/null || true)" != "1" ]]; do
    if (( SECONDS >= end )); then
        test_log "test-apk.apk was not allowed to launch within 120 seconds."
        test_failure
    fi
    sleep 1
done

# Allow 80 seconds for the 60-second launch timeout and container teardown.
sleep 80

if [[ "$(./lepton ps | grep "test-apk.apk" | grep "${_GREEN}")" != "" ]]; then
    test_log "test failed because the container was still active after the launch timeout"
    test_failure
fi

./lepton stop test-apk.apk

test_log "test-apk.apk container test finished."

kill $LOGCAT_PID || true
