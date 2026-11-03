#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Local regression suite: synthetic stages, no Android build/boot or network.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
for test_name in test-build-pipeline-cli test-deploy-compat-rootfs-source test-deploy-packaging test-inject-ndk-translation-odm; do
    bash "$repo/image-14/tests/$test_name.sh"
done
bash "$repo/compat_tool/liblepton/ndk_auxv/test.sh"
python3 -B "$repo/tests/test-build-integration.py"
python3 -B "$repo/tests/test-add-game-tool-selection.py"
bash "$repo/tests/test-add-game-gui.sh"
bash "$repo/tests/test-manage-installs-gui.sh"
bash "$repo/tests/test-tool-entry.sh"
bash "$repo/tests/test-deck-clean-slate.sh"
bash "$repo/tests/test-steamlaunch-install-route.sh"
python3 -B "$repo/tests/test-register-tool.py"
python3 -B "$repo/tests/runtime/test-apkm.py"
python3 -B "$repo/tests/runtime/test-locale-build.py"
python3 -B "$repo/tests/runtime/test-view-intents.py"
python3 -B "$repo/tests/runtime/test-framework-patches.py"
python3 -B "$repo/tests/runtime/test-google-services.py"
bash "$repo/tests/runtime/test-network-sysctls.sh"
bash "$repo/tests/runtime/test-runtime-properties.sh"
python3 -B "$repo/tests/runtime/test-profile-lifecycle.py"
for script in "$repo/image-14/do_build_x86_64.sh" \
              "$repo/image-14/scripts/deploy-compat-x86_64.sh" \
              "$repo/image-14/scripts/lib/deck-bundle.sh" \
              "$repo/tests/runtime/"*.sh; do
    bash -n "$script"
done
if [[ -n "$(find "$repo" -maxdepth 1 -type f -name '*.sh' -print -quit)" ]]; then
    echo 'FAIL: standalone shell script found at repository root' >&2
    exit 1
fi
echo 'PASS: workflow regression suite; no Android images, host services or remote installations modified'
