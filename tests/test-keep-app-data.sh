#!/usr/bin/env bash
# Disposable host fixtures: exercise real persistence functions, no Android boot.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"; [[ -z "${LEPTON_PREFIX:-}" ]] || rm -rf -- "$LEPTON_PREFIX"' EXIT
for fn in profile_has_no_mounts should_keep_app_data remove_baked_workdirs lepton_runtime_fingerprint existing_app_profile check_kept_app_data \
          remove_prefix clear_baked_app_data prepare_baked_data_for_removal data_mount_path data_workdir app_workdir app_datadir cleanup_container install_app; do
    eval "$(sed -n "/^function $fn()/,/^}/p" "$repo/compat_tool/liblepton/liblepton.sh")"
done
for fn in get_baked_app_data_dir app_install_complete_path app_apk_set_matches is_app_baked app_install_needed; do
    eval "$(sed -n "/^function $fn()/,/^}/p" "$repo/compat_tool/liblepton/baking.sh")"
done
for fn in extract_app_mount_dir extract_app_hash; do
    eval "$(sed -n "/^function $fn()/,/^}/p" "$repo/compat_tool/liblepton/app_metadata.sh")"
done
for fn in safe_storage_link continue_boot_after_bake; do
    eval "$(sed -n "/^function $fn()/,/^}/p" "$repo/compat_tool/liblepton/mounting.sh")"
done
print() { printf '%s' "$*"; }
println() { printf '%s\n' "$*" >> "$work/messages"; }
is_app() { true; }
is_sysbake() { return 1; }
is_steamlaunch() { [[ "$LEPTON_CONTEXT" == steamlaunch-* ]]; }
extract_app_id() { echo com.example.game; }
get_app_id() { echo com.example.game; }
get_apk_path() { echo "$work/game.apk"; }
get_app_mount_dir() { extract_app_mount_dir; }
kill_container() { :; }
findmnt() { if [[ "${MOUNTED:-no}" == yes ]]; then echo "$work overlay upperdir=$baked"; fi; }
podman() {
    echo "$*" >> "$work/podman.log"
    case "$1 ${2:-}" in
        'container exists') return "${CONTAINER_EXISTS:-1}" ;;
        'container inspect') [[ "${CONTAINER_EXISTS:-1}" == 0 ]] || return 125; echo "${RUNNING:-false}" ;;
        'unshare rm') [[ "${UNSHARE_FAIL:-no}" != yes ]] || return 1; shift; "$@" ;;
        'rm -f'|'rm lepton-'*) return 0 ;;
        *) return 0 ;;
    esac
}
export LEPTON_DIR="$work/tool/liblepton" LEPTON_CONTEXT=steamlaunch-123 SteamAppId=123
export LEPTON_TEST_ROOTFS="$work/rootfs" STEAM_COMPAT_DATA_PATH="$work/compatdata/123"
BAKED_SYSTEM_DATA_DIR="$work/sysbake"
baked="$STEAM_COMPAT_DATA_PATH/baked"
mkdir -p "$LEPTON_DIR" "$LEPTON_TEST_ROOTFS/system/framework" "$LEPTON_TEST_ROOTFS/vendor" "$BAKED_SYSTEM_DATA_DIR/system" "$STEAM_COMPAT_DATA_PATH"
echo android > "$LEPTON_TEST_ROOTFS/system/build.prop"
echo vendor > "$LEPTON_TEST_ROOTFS/vendor/build.prop"
echo services > "$LEPTON_TEST_ROOTFS/system/framework/services.jar"
echo packages > "$BAKED_SYSTEM_DATA_DIR/system/packages.xml"
echo apk > "$work/game.apk"
code='/data/app/~~92IMBVGz9LPLyu0rqw6EQA==/com.example.game-eL88PbfLTRbkvc0bFKfWAQ=='
check_kept_app_data
mkdir -p "$baked/data_overlay/system/users/0" "$baked/data_overlay/user/0/com.example.game/shared_prefs" "$baked/app_overlay" "$STEAM_COMPAT_DATA_PATH/external"
save="$baked/data_overlay/user/0/com.example.game/shared_prefs/KorgeNativeStorage.xml"
echo 'board=2048;level=7' > "$save"
echo shared > "$STEAM_COMPAT_DATA_PATH/external/save"
printf 'ABX\0\x2fR%s/\x00' "$code" > "$baked/data_overlay/system/packages.xml"
cp "$work/game.apk" "$baked/app_overlay/base.apk"
# Single-APK installs overlay the game's whole folder, rename its APK to base.apk
# and delete the other APKs, leaving overlay whiteouts (0:0 character devices)
# in app_overlay, as on the Deck. They are not installed code.
mknod "$baked/app_overlay/game.apk" c 0 0
mknod "$baked/app_overlay/OtherGame-arm64.apk" c 0 0
extract_app_hash > "$baked/app_hash"
touch "$baked/app_install_complete"
assert_saved() { [[ "$(cat "$save")" == 'board=2048;level=7' && "$(cat "$STEAM_COMPAT_DATA_PATH/external/save")" == shared ]]; }
refuses() { if check_kept_app_data; then echo 'FAIL: unsafe reuse accepted'; exit 1; fi; [[ -z "$APP_REUSE_VALIDATED" ]]; assert_saved; }
# Exercise the launcher's actual teardown body for session lengths and a signal.
eval "$(sed -n '/^        function teardown()/,/^        }/p' "$repo/compat_tool/lepton")"
eval "$(sed -n '/^        function handle_signal()/,/^        }/p' "$repo/compat_tool/lepton")"
strace_enabled() { return 1; }
uninherit_lepton_lock() { :; }
logcat_debug_dir() { echo "$work/logcat"; }
dump_logcat() { :; }
ndk_note_early_exit() { echo early >> "$work/early"; }
stop_lepton_hotplug_watcher() { :; }
logcat_debug() { :; }
log_moved_dirs() { :; }
kill_descendants() { :; }
MOVED_INACCESSIBLE=''
check_kept_app_data
# Android 14 renames packages.xml aside while rewriting it at boot. A post-start
# re-check during that window must not reinstall over a validated profile.
mv "$baked/data_overlay/system/packages.xml" "$work/packages-booting"
if app_install_needed; then echo 'FAIL: validated profile reinstalled after start'; exit 1; fi
if (APP_REUSE_VALIDATED=''; ! app_install_needed); then echo 'FAIL: unvalidated missing install not detected'; exit 1; fi
mv "$work/packages-booting" "$baked/data_overlay/system/packages.xml"
[[ -e "$baked/app_install_complete" ]]; assert_saved
for scenario in normal short long crash invalid-short; do
    LEPTON_PREFIX="$(mktemp -d /tmp/lepton-context.XXXXXXXXXX)"
    mkdir -p "$baked/data_workdir/work" "$baked/app_workdir/work"
    app_start_time=$(( $(date +%s) - 90 ))
    case "$scenario" in short|crash|invalid-short) app_start_time=$(( $(date +%s) - 10 ));; esac
    [[ "$scenario" != invalid-short ]] || mv "$baked/app_install_complete" "$work/marker"
    if [[ "$scenario" == crash ]]; then (handle_signal SIGTERM); else (teardown); fi
    [[ ! -e "$LEPTON_PREFIX" && ! -e "$baked/data_workdir" ]]
    assert_saved
    [[ "$scenario" != invalid-short ]] || mv "$work/marker" "$baked/app_install_complete"
done
[[ "$(wc -l < "$work/early")" == 3 ]]
# Legacy opt-out cannot authorise a reset; release metadata never invalidates.
LEPTON_KEEP_APP_DATA=false check_kept_app_data
printf 'compat_tool:new,rootfs:new,sdk:34' > "$baked/app_last_depot_version"
check_kept_app_data; assert_saved
# Identical APK, newer mtime; changed content refuses without touching saves.
touch -d '+2 days' "$work/game.apk"; check_kept_app_data
echo update >> "$work/game.apk"; refuses
sed -i '$d' "$work/game.apk"; check_kept_app_data
# Missing marker, unknown binary metadata, missing code path, missing code.
mv "$baked/app_install_complete" "$work/marker"; refuses
mv "$work/marker" "$baked/app_install_complete"
cp "$baked/data_overlay/system/packages.xml" "$work/packages"
printf 'ABX\0unknown' > "$baked/data_overlay/system/packages.xml"; refuses
cp "$work/packages" "$baked/data_overlay/system/packages.xml"
mv "$baked/app_overlay/base.apk" "$work/code"; refuses
mv "$work/code" "$baked/app_overlay/base.apk"
# Unknown and incompatible fingerprints preserve both bytes and old identity.
stored="$(cat "$baked/lepton-runtime-fingerprint")"
mv "$baked/lepton-runtime-fingerprint" "$work/fingerprint"; refuses
[[ ! -e "$baked/lepton-runtime-fingerprint" ]]
mv "$work/fingerprint" "$baked/lepton-runtime-fingerprint"
echo different >> "$LEPTON_TEST_ROOTFS/system/build.prop"; refuses
[[ "$(cat "$baked/lepton-runtime-fingerprint")" == "$stored" ]]
sed -i '$d' "$LEPTON_TEST_ROOTFS/system/build.prop"; check_kept_app_data
cp "$BAKED_SYSTEM_DATA_DIR/system/packages.xml" "$work/sys-packages"
echo new-sysbake > "$BAKED_SYSTEM_DATA_DIR/system/packages.xml"; refuses
cp "$work/sys-packages" "$BAKED_SYSTEM_DATA_DIR/system/packages.xml"; check_kept_app_data
mv "$LEPTON_TEST_ROOTFS/system/framework/services.jar" "$work/services"; refuses
mv "$work/services" "$LEPTON_TEST_ROOTFS/system/framework/services.jar"
# Actual install_app failure via fake ADB (the existing profile remains intact).
cat > "$work/adb" <<'ADB'
#!/bin/bash
case "$*" in *'install -g'*) exit 1;; esac
exit 0
ADB
chmod +x "$work/adb"
ADB="$work/adb"
apkm_split_paths() { :; }
uninherit_lepton_lock() { :; }
adb_port() { echo 5555; }
apk_path_in_container() { return 1; }
podman_attach() { :; }
if install_app; then echo 'FAIL: install failure not returned'; exit 1; fi
assert_saved
# continue_boot must never reset private storage.
continue_boot_after_bake; assert_saved
# Settings are persistent too; cleanup doesn't unlink them.
echo settings > "$baked/data_overlay/system/users/0/settings_secure.xml"
cleanup_container
[[ "$(cat "$baked/data_overlay/system/users/0/settings_secure.xml")" == settings ]]
# Workdirs retained while container exists, is active, or Podman status unknown.
mkdir -p "$baked/data_workdir/work"
CONTAINER_EXISTS=0 RUNNING=true remove_baked_workdirs
[[ -d "$baked/data_workdir/work" ]]
CONTAINER_EXISTS=125 remove_baked_workdirs
[[ -d "$baked/data_workdir/work" ]]
MOUNTED=yes remove_baked_workdirs
[[ -d "$baked/data_workdir/work" ]]; assert_saved
# Shared links: recognised link is idempotent; unknown link and real directory
# are retained. No recursive deletion or symlink following.
safe_storage_link "$STEAM_COMPAT_DATA_PATH/external" "$work/link"
safe_storage_link "$STEAM_COMPAT_DATA_PATH/external" "$work/link"
! safe_storage_link /other "$work/link"
mkdir "$work/real"; echo irreplaceable > "$work/real/save"
! safe_storage_link /other "$work/real"
[[ "$(cat "$work/real/save")" == irreplaceable ]]
# No implicit reset, no active reset; explicit reset only targets this baked dir.
! clear_baked_app_data error
CONTAINER_EXISTS=0 RUNNING=true LEPTON_RESET_APP_DATA=true check_kept_app_data && exit 1
assert_saved
if UNSHARE_FAIL=yes LEPTON_RESET_APP_DATA=true check_kept_app_data; then
    echo 'FAIL: failed reset accepted'; exit 1
fi
assert_saved
[[ "$(cat "$baked/lepton-runtime-fingerprint")" == "$stored" ]]
mkdir -p "$work/compatdata/456/baked"; echo neighbour > "$work/compatdata/456/baked/save"
LEPTON_RESET_APP_DATA=true check_kept_app_data
[[ ! -e "$save" && "$(cat "$work/compatdata/456/baked/save")" == neighbour ]]
[[ "$(cat "$STEAM_COMPAT_DATA_PATH/external/save")" == shared ]]
# Source invariant: a single deletion caller, solely under explicit reset.
[[ "$(rg -c 'clear_baked_app_data "' "$repo/compat_tool/liblepton/liblepton.sh")" == 1 ]]
! rg -q 'clear_baked_app_data|rm -rf /data/data' "$repo/compat_tool/lepton" "$repo/compat_tool/liblepton/mounting.sh"
echo 'PASS: preservation, validation refusal, timestamp/version independence, failed install, fingerprint switch-back, storage paths, settings, explicit reset isolation'
