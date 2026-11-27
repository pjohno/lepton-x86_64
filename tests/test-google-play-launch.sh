#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Google Play launcher mode on the host side, with disposable fixtures only
# (no Android boot, no Podman, no Steam): launch-file handling, GApps
# requirement, no APK and no session-ending observer, the generated launch rc,
# and the unchanged profile safety checks (reuse on a matching runtime
# fingerprint, refusal with data preserved on a different one).
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
not() { if "$@"; then fail "unexpectedly succeeded: $*"; fi; }

# An inherited variable must never switch a launch into Google Play mode.
export LEPTON_LAUNCH_PACKAGE=com.android.vending
export LEPTON_DIR="$work/tool/liblepton" LEPTON_CONTEXT=steamlaunch-3000000001 SteamAppId=3000000001
export STEAM_COMPAT_DATA_PATH="$work/compatdata/3000000001"
export STEAM_COMPAT_INSTALL_PATH="$work/launcher"
export LEPTON_TEST_ROOTFS="$work/rootfs"
mkdir -p "$LEPTON_DIR" "$STEAM_COMPAT_DATA_PATH" "$STEAM_COMPAT_INSTALL_PATH"
source "$repo/compat_tool/liblepton/utils.sh"
source "$repo/compat_tool/liblepton/app_metadata.sh"
source "$repo/compat_tool/liblepton/google_games.sh"
source "$repo/compat_tool/liblepton/android_library.sh"
[[ -z "$LEPTON_LAUNCH_PACKAGE" ]] || fail 'inherited LEPTON_LAUNCH_PACKAGE kept'
[[ ! "$(declare -p LEPTON_LAUNCH_PACKAGE)" =~ -x ]] || fail 'LEPTON_LAUNCH_PACKAGE exported'
not google_play_mode
for fn in get_baked_app_data_dir app_install_complete_path is_app_baked app_install_needed; do
    eval "$(sed -n "/^function $fn()/,/^}/p" "$repo/compat_tool/liblepton/baking.sh")"
done
for fn in lepton_runtime_fingerprint existing_app_profile check_kept_app_data lepton_profile_refused lepton_tool_for_fingerprint; do
    eval "$(sed -n "/^function $fn()/,/^}/p" "$repo/compat_tool/liblepton/liblepton.sh")"
done
eval "$(sed -n '/^function generate_app_launch_rc()/,/^}/p' "$repo/compat_tool/liblepton/mounting.sh")"
is_sysbake() { return 1; }
extract_app_id() { echo com.example.game; }
podman_mount_entry() { echo "mount $*" >> "$work/mounts"; }
prefix() { printf '%s' "$work/prefix"; }
BASE_APK=base.apk
BAKED_SYSTEM_DATA_DIR="$work/sysbake"
export XDG_DATA_HOME="$work/data"   # never scan this computer's installed tools
mkdir -p "$XDG_DATA_HOME" "$work/prefix" "$LEPTON_TEST_ROOTFS/system/framework" "$LEPTON_TEST_ROOTFS/vendor" "$BAKED_SYSTEM_DATA_DIR/system"
echo android > "$LEPTON_TEST_ROOTFS/system/build.prop"
echo vendor > "$LEPTON_TEST_ROOTFS/vendor/build.prop"
echo services > "$LEPTON_TEST_ROOTFS/system/framework/services.jar"
echo packages > "$BAKED_SYSTEM_DATA_DIR/system/packages.xml"

launch="$STEAM_COMPAT_INSTALL_PATH/google-play.lepton-launch"
printf '# comment\npackage=com.android.vending\n' > "$launch"
is_launch_file_path "$launch"
is_launch_file_path /x/GOOGLE.LEPTON-LAUNCH
not is_launch_file_path /x/game.apk
not is_launch_file_path /x/google-play.lepton-launch.apk

# die() runs in a subshell; its message also goes to the player popup file.
refused() {  # refused EXPECTED_TEXT COMMAND...
    local expected="$1" status=0; shift
    : > "$work/popup"
    ( LEPTON_MESSAGE_FILE="$work/popup" "$@" ) 2> "$work/stderr" || status=$?
    [[ "$status" != 0 ]] || fail "accepted: $*"
    grep -q "$expected" "$work/popup" || fail "missing message '$expected': $(cat "$work/popup")"
}
# Non-GApps tool, other packages, unreadable file, no compatdata: refused.
refused 'needs a Lepton tool with Google services' prepare_launch_file "$launch"
mkdir -p "$LEPTON_TEST_ROOTFS/system/product/priv-app/PrebuiltGmsCore"
touch "$LEPTON_TEST_ROOTFS/system/product/priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk"
printf 'package=com.example.other\n' > "$work/other.lepton-launch"
refused 'Unsupported launch file' prepare_launch_file "$work/other.lepton-launch"
printf 'package=com.android.vending; rm -rf /\n' > "$work/evil.lepton-launch"
refused 'Unsupported launch file' prepare_launch_file "$work/evil.lepton-launch"
refused 'Cannot read' prepare_launch_file "$work/missing.lepton-launch"
( unset STEAM_COMPAT_DATA_PATH; refused 'needs a Steam launch' prepare_launch_file "$launch" )

# Accepted: no APK even if one is lying in the shortcut's folder.
cp /dev/null "$STEAM_COMPAT_INSTALL_PATH/stray.apk"
prepare_launch_file "$launch"
google_play_mode
not is_app
[[ -z "$(get_app_id)" ]] || fail 'Google Play mode has an app ID'
[[ "$(lepton_session_name)" == 'Google Play' ]]
[[ "$(lepton_launch_commands)" == 'am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p com.android.vending' ]]
rm "$STEAM_COMPAT_INSTALL_PATH/stray.apk"

# Launch rc: opens Google Play once Android is ready; no game install steps.
generate_app_launch_rc
rc="$work/prefix/lepton_app_launch.rc"
grep -Fqx 'on property:sys.boot_completed=1 && property:ro.lepton.app_baked=1' "$rc"
grep -Fq 'MEDIA_MOUNTED' "$rc"
grep -Fqx '    exec -- /system/bin/sh -c "am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p com.android.vending"' "$rc"
not grep -q 'fix_obb_symlink\|base.apk\|vulkan_layer_setup' "$rc"
[[ "$(stat -c %a "$rc")" == 644 ]]
grep -Fq "/vendor/etc/init/lepton_app_launch.rc" "$work/mounts"

# The launcher script itself: no APK required, Android released without an
# install, and no auto-installed dev APKs or session-ending app observer.
grep -Fq 'prepare_launch_file "$(realpath "${3:-}")"' "$repo/compat_tool/lepton"
grep -Fq '} && ! google_play_mode; then' "$repo/compat_tool/lepton"
grep -Fq 'if google_play_mode || { ! is_steamlaunch && ! is_app; }; then' "$repo/compat_tool/lepton"
grep -Fq 'if is_app || google_play_mode; then' "$repo/compat_tool/liblepton/liblepton.sh"
# The session waits for the container (Steam's Stop), not for an app exit.
grep -Fq 'if is_app && ! google_signin_mode; then' "$repo/compat_tool/liblepton/liblepton.sh"
grep -Fq 'if is_app; then
        # x86_64 port: in Google sign-in mode' "$repo/compat_tool/liblepton/properties.sh"

# Profile: created on first launch, reused while the runtime matches.
baked="$STEAM_COMPAT_DATA_PATH/baked"
# Its log lines (stdout and stderr) are kept for inspection.
eval "check_kept_app_data_impl() $(declare -f check_kept_app_data | tail -n +2)"
check_kept_app_data() { check_kept_app_data_impl >> "$work/messages" 2>&1; }
check_kept_app_data
[[ "$(cat "$baked/lepton-runtime-fingerprint")" =~ ^[0-9a-f]{64}$ ]]
grep -q 'package=(launcher: com.android.vending)' "$work/messages"
mkdir -p "$baked/data_overlay/data/com.yodo1.crossyroad/shared_prefs" "$baked/data_overlay/system"
echo 'top=42' > "$baked/data_overlay/data/com.yodo1.crossyroad/shared_prefs/save.xml"
echo '<packages/>' > "$baked/data_overlay/system/packages.xml"
check_kept_app_data
[[ "$APP_REUSE_VALIDATED" == yes ]] || fail 'matching profile not reused'
not app_install_needed

# A different Android image: refused, nothing touched, and explained.
stored="$(cat "$baked/lepton-runtime-fingerprint")"
echo 'ro.build.id=NEWER' >> "$LEPTON_TEST_ROOTFS/system/build.prop"
: > "$work/popup"
if LEPTON_MESSAGE_FILE="$work/popup" check_kept_app_data; then fail 'incompatible profile reused'; fi
[[ -z "$APP_REUSE_VALIDATED" ]]
[[ "$(cat "$baked/lepton-runtime-fingerprint")" == "$stored" ]]
[[ "$(cat "$baked/data_overlay/data/com.yodo1.crossyroad/shared_prefs/save.xml")" == 'top=42' ]]
grep -q '^Google Play can.t start with this Lepton tool. Nothing has been deleted.' "$work/popup"
grep -q 'every game' "$work/popup"
grep -q 'installed from Google Play' "$work/popup"
not grep -q 'installs the game again' "$work/popup"
# The original runtime is back: the same profile is reused again.
sed -i '$d' "$LEPTON_TEST_ROOTFS/system/build.prop"
check_kept_app_data
[[ "$APP_REUSE_VALIDATED" == yes ]]

# Sign-in mode for "Add Google game" is unchanged.
LEPTON_LAUNCH_PACKAGE=''
get_app_id() { echo com.example.game; }
get_app_activity() { echo .Main; }
[[ "$(LEPTON_GOOGLE_SIGNIN=true lepton_launch_commands)" == *'-p com.android.vending' ]]
[[ "$(lepton_launch_commands)" == 'am start com.example.game/.Main' ]]
[[ "$(lepton_observed_app_id)" == com.example.game ]]

echo 'PASS: Google Play launcher: launch file, GApps requirement, no APK or app observer, launch rc, profile reuse and safe refusal'
