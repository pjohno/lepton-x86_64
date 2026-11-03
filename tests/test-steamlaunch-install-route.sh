#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Steam launches may use Valve's "pm install <host path>" shortcut only when
# the APK is inside a folder mounted into the container; otherwise adb install.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
lib="$repo/compat_tool/liblepton/liblepton.sh"
eval "$(sed -n '/^function apk_path_in_container()/,/^}/p' "$lib")"
declare -F apk_path_in_container > /dev/null
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/Steam/steamapps/common/Game" "$work/lib2/common/G2" "$work/Steam2" "$work/Downloads" "$work/real-lib/common/G3"
ln -s "$work/real-lib" "$work/link-lib"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$work/Steam"
export STEAM_COMPAT_LIBRARY_PATHS="$work/Steam/steamapps:$work/lib2:$work/link-lib"

apk_path_in_container "$work/Steam/steamapps/common/Game/game.apk"     # client path
apk_path_in_container "$work/lib2/common/G2/game.apk"                  # second library
apk_path_in_container "$work/link-lib/common/G3/game.apk"              # visible at the mounted (link) path
! apk_path_in_container "$work/real-lib/common/G3/game.apk"            # resolved path is not mounted
! apk_path_in_container "$work/Downloads/2048.apk"                     # non-Steam shortcut location
! apk_path_in_container "$work/Steam2/game.apk"                        # prefix look-alike
! STEAM_COMPAT_CLIENT_INSTALL_PATH='' STEAM_COMPAT_LIBRARY_PATHS='' apk_path_in_container "$work/Steam/x.apk"

# install_app gates Valve's shortcut on it; the adb fallback remains.
grep -q 'if is_steamlaunch && apk_path_in_container "${APK_PATH}"; then' "$lib"
grep -q 'install -g "${APK_PATH}"' "$lib"
echo 'PASS: Steam-launch install route: pm shortcut only for mounted APKs, adb otherwise'
