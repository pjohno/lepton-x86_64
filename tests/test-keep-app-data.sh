#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Kept Steam-launch app data: kept between launches, cleared when the Android
# image changes or a reset is requested, upstream behaviour otherwise.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
lib="$repo/compat_tool/liblepton/liblepton.sh"
for fn in should_keep_app_data remove_baked_workdirs lepton_runtime_fingerprint check_kept_app_data \
          remove_prefix clear_baked_app_data prepare_baked_data_for_removal data_mount_path data_workdir \
          app_workdir app_datadir; do
    eval "$(sed -n "/^function $fn()/,/^}/p" "$lib")"
    declare -F "$fn" > /dev/null || { echo "missing $fn"; exit 1; }
done
eval "$(sed -n '/^function get_baked_app_data_dir()/,/^}/p' "$repo/compat_tool/liblepton/baking.sh")"
print() { printf '%s' "$*"; }
println() { printf '%s\n' "$*" >> "$work/messages"; }
is_steamlaunch() { [[ "${LEPTON_CONTEXT}" == steamlaunch-* ]]; }
is_app() { true; }

work="$(mktemp -d)"
trap 'chmod -R u+rwX "$work"; rm -rf -- "$work"' EXIT
export LEPTON_DIR="$work/compat_tool/liblepton" LEPTON_CONTEXT=steamlaunch-123
BAKED_SYSTEM_DATA_DIR="$work/compat_tool/sysbake"
mkdir -p "$LEPTON_DIR" "$work/compat_tool/images/rootfs/system/framework" "$work/compat_tool/images/rootfs/vendor" \
         "$BAKED_SYSTEM_DATA_DIR/system"
echo 'ro.build.fingerprint=a' > "$work/compat_tool/images/rootfs/system/build.prop"
echo 'vendor' > "$work/compat_tool/images/rootfs/vendor/build.prop"
echo 'dex' > "$work/compat_tool/images/rootfs/system/framework/services.jar"
echo '<packages/>' > "$BAKED_SYSTEM_DATA_DIR/system/packages.xml"
export STEAM_COMPAT_DATA_PATH="$work/compatdata/123"
baked="$STEAM_COMPAT_DATA_PATH/baked"
game_data() {  # a game that was installed and played
    mkdir -p "$baked/data_overlay/data/com.example.game" "$baked/app_overlay" "$baked/data_workdir/work" "$baked/app_workdir/work" \
             "$STEAM_COMPAT_DATA_PATH/external"
    echo 'level=7' > "$baked/data_overlay/data/com.example.game/save"
    echo 'shared' > "$STEAM_COMPAT_DATA_PATH/external/save"
}

# Launch end: data and app overlays kept, scratch work dirs and prefix removed.
game_data
LEPTON_PREFIX="$work/prefix"; mkdir -p "$LEPTON_PREFIX"
remove_prefix
[[ -f "$baked/data_overlay/data/com.example.game/save" && -d "$baked/app_overlay" ]]
[[ ! -e "$baked/data_workdir" && ! -e "$baked/app_workdir" && ! -e "$LEPTON_PREFIX" ]]

# Opt-out and non-Steam contexts keep the upstream "fresh every launch" cleanup.
mkdir -p "$LEPTON_PREFIX"; LEPTON_KEEP_APP_DATA=false remove_prefix
[[ ! -e "$baked/data_overlay" && ! -e "$baked/app_overlay" ]]
game_data; mkdir -p "$LEPTON_PREFIX"; LEPTON_CONTEXT=dev remove_prefix
[[ ! -e "$baked/data_overlay" ]]

# First launch records the image; the next launch with the same image keeps data.
command rm -rf "$baked"; check_kept_app_data
[[ -s "$baked/lepton-runtime-fingerprint" ]]
game_data; check_kept_app_data
[[ -f "$baked/data_overlay/data/com.example.game/save" ]]

# A different Android image (another bundle/tool) clears kept data, not external saves.
echo 'ro.build.fingerprint=b' > "$work/compat_tool/images/rootfs/system/build.prop"
before="$(cat "$baked/lepton-runtime-fingerprint")"
check_kept_app_data
[[ ! -e "$baked/data_overlay" && -f "$STEAM_COMPAT_DATA_PATH/external/save" ]]
[[ "$(cat "$baked/lepton-runtime-fingerprint")" != "$before" ]]
grep -q 'Android runtime changed' "$work/messages"
# A changed baked system or framework counts too.
game_data; check_kept_app_data; [[ -d "$baked/data_overlay" ]]
echo '<packages v="2"/>' > "$BAKED_SYSTEM_DATA_DIR/system/packages.xml"; check_kept_app_data
[[ ! -e "$baked/data_overlay" ]]

# Kept data without a recorded image (older Lepton) is not trusted.
game_data; command rm -f "$baked/lepton-runtime-fingerprint"; check_kept_app_data
[[ ! -e "$baked/data_overlay" ]]

# Reset on request.
game_data; check_kept_app_data; [[ -d "$baked/data_overlay" ]]
LEPTON_RESET_APP_DATA=true check_kept_app_data
[[ ! -e "$baked/data_overlay" ]]
grep -q 'LEPTON_RESET_APP_DATA=true' "$work/messages"

# A quick exit of an installed game no longer clears its data in the launcher.
grep -q 'if \[\[ "${EARLY_SHUTDOWN}" == "1" \]\] && ! { should_keep_app_data && is_app_baked; }; then' "$repo/compat_tool/lepton"
grep -q '    check_kept_app_data' "$lib"
# Android 14 writes packages.xml as binary XML (ABX): the installed check and
# the codePath used to mount the kept app back must both work on it.
eval "$(sed -n '/^function extract_app_mount_dir()/,/^}/p' "$repo/compat_tool/liblepton/app_metadata.sh")"
eval "$(sed -n '/^function is_app_baked()/,/^}/p' "$repo/compat_tool/liblepton/baking.sh")"
get_app_id() { echo com.example.game; }
mkdir -p "$baked/data_overlay/system"
code='/data/app/~~92IMBVGz9LPLyu0rqw6EQA==/com.example.game-eL88PbfLTRbkvc0bFKfWAQ=='
printf 'ABX\0\x2fR%s/\x00\x2fVcom.example.gameX%s/lib/\x00' "$code" "$code" > "$baked/data_overlay/system/packages.xml"
[[ "$(extract_app_mount_dir)" == "$code" ]]
printf '<package name="com.example.game" codePath="%s" />\n' "$code" > "$work/text.xml"
cp "$work/text.xml" "$baked/data_overlay/system/packages.xml"
[[ "$(extract_app_mount_dir)" == "$code" ]]
printf 'ABX\0com.example.gameother' > "$baked/data_overlay/system/packages.xml"
[[ -z "$(extract_app_mount_dir)" ]]   # no codePath: not considered installed
get_apk_path() { echo "$work/game.apk"; }
get_app_mount_dir() { extract_app_mount_dir; }
app_install_complete_path() { echo "$baked/app_install_complete"; }
touch "$work/game.apk"; sleep 1; touch "$baked/app_install_complete"
printf 'ABX\0\x2fR%s/\x00' "$code" > "$baked/data_overlay/system/packages.xml"
is_app_baked
printf 'ABX\0com.example.gameother' > "$baked/data_overlay/system/packages.xml"
! is_app_baked
echo 'PASS: kept app data: kept between launches, cleared on image change/reset/unknown, upstream when opted out, binary packages.xml'
