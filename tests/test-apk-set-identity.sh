#!/usr/bin/env bash
# Legacy base/APKM hashes must not invalidate identical installed split code.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
for fn in app_install_complete_path app_apk_set_matches is_app_baked; do
    eval "$(sed -n "/^function $fn()/,/^}/p" "$repo/compat_tool/liblepton/baking.sh")"
done
for fn in extract_app_hash extract_app_mount_dir; do
    eval "$(sed -n "/^function $fn()/,/^}/p" "$repo/compat_tool/liblepton/app_metadata.sh")"
done
print() { printf '%s' "$*"; }
println() { printf '%s\n' "$*" >> "$work/messages"; }
is_app() { return 0; }
get_baked_app_data_dir() { print "$work/baked"; }
get_app_id() { print com.roblox.client; }
get_apk_path() { print "$LEPTON_APKM_DIR/base.apk"; }
export LEPTON_APKM_DIR="$work/cache" LEPTON_APKM_HASH=archive-identity
mkdir -p "$LEPTON_APKM_DIR" "$work/baked/app_overlay" "$work/baked/data_overlay/system" "$work/baked/data_overlay/user/0/com.roblox.client"
echo synthetic-account-state > "$work/baked/data_overlay/user/0/com.roblox.client/save"
echo base-binary > "$LEPTON_APKM_DIR/base.apk"
echo split-binary > "$LEPTON_APKM_DIR/split_config.x86_64.apk"
cp "$LEPTON_APKM_DIR/"*.apk "$work/baked/app_overlay/"
printf 'ABX\0/data/app/~~92IMBVGz9LPLyu0rqw6EQA==/com.roblox.client-eL88PbfLTRbkvc0bFKfWAQ==\0' > "$work/baked/data_overlay/system/packages.xml"
touch "$work/baked/app_install_complete"
base_hash="$(sha256sum "$LEPTON_APKM_DIR/base.apk" | cut -d' ' -f1)"
[[ "$(extract_app_hash)" == "$base_hash" ]] # archive hash cannot change base-hash semantics
for recorded in "$base_hash" archive-identity stale-identity; do
    printf '%s' "$recorded" > "$work/baked/app_hash"
    is_app_baked
    [[ "$(cat "$work/baked/app_hash")" == "$recorded" ]] # read-only validation
    [[ "$(cat "$work/baked/data_overlay/user/0/com.roblox.client/save")" == synthetic-account-state ]]
done
rm "$work/baked/app_hash"; is_app_baked; [[ ! -e "$work/baked/app_hash" ]]
touch -d '+2 days' "$LEPTON_APKM_DIR/"*.apk; is_app_baked
# Every real difference refuses, leaving all profile data intact.
refuses() {
    if is_app_baked; then echo 'FAIL: differing or uncertain code accepted'; exit 1; fi
    [[ "$(cat "$work/baked/data_overlay/user/0/com.roblox.client/save")" == synthetic-account-state ]]
}
echo changed-base >> "$LEPTON_APKM_DIR/base.apk"; refuses
cp "$work/baked/app_overlay/base.apk" "$LEPTON_APKM_DIR/base.apk"
echo changed-split >> "$LEPTON_APKM_DIR/split_config.x86_64.apk"; refuses
cp "$work/baked/app_overlay/split_config.x86_64.apk" "$LEPTON_APKM_DIR/split_config.x86_64.apk"
mv "$LEPTON_APKM_DIR/split_config.x86_64.apk" "$work/split"; refuses
mv "$work/split" "$LEPTON_APKM_DIR/split_config.x86_64.apk"
echo extra > "$LEPTON_APKM_DIR/split_extra.apk"; refuses
rm "$LEPTON_APKM_DIR/split_extra.apk"
echo extra > "$work/baked/app_overlay/split_extra.apk"; refuses
rm "$work/baked/app_overlay/split_extra.apk"
mv "$work/baked/app_overlay/split_config.x86_64.apk" "$work/split"
ln -s "$LEPTON_APKM_DIR/split_config.x86_64.apk" "$work/baked/app_overlay/split_config.x86_64.apk"; refuses
rm "$work/baked/app_overlay/split_config.x86_64.apk"
mv "$work/split" "$work/baked/app_overlay/split_config.x86_64.apk"
is_app_baked
# Overlay whiteouts record APKs removed from the merged view; Android cannot
# load them. Ignore them as extras, but never accept one in place of real code.
mknod "$work/baked/app_overlay/OtherGame-arm64.apk" c 0 0
mknod "$work/baked/app_overlay/original-name.apk" c 0 0
is_app_baked
mv "$work/baked/app_overlay/split_config.x86_64.apk" "$work/split"
mknod "$work/baked/app_overlay/split_config.x86_64.apk" c 0 0; refuses
rm "$work/baked/app_overlay/split_config.x86_64.apk"
mv "$work/split" "$work/baked/app_overlay/split_config.x86_64.apk"
mv "$work/baked/app_overlay/base.apk" "$work/base"
mknod "$work/baked/app_overlay/base.apk" c 0 0; refuses
rm "$work/baked/app_overlay/base.apk"
mv "$work/base" "$work/baked/app_overlay/base.apk"
is_app_baked
rm "$work/baked/app_install_complete"; refuses
[[ ! -e "$work/baked/app_hash" ]]
# An interrupted first unpack leaves <key>.tmp; only that scratch copy is
# replaced, and other completed (possibly installed) caches are retained.
eval "$(sed -n "/^function prepare_apkm()/,/^}/p" "$repo/compat_tool/liblepton/google_games.sh")"
die() { echo "FAIL: $*"; exit 1; }
rootfs_has_arm_translation() { return 0; }
unset LEPTON_APKM_DIR LEPTON_APKM_HASH APP_PATH
export STEAM_COMPAT_DATA_PATH="$work/compatdata"
python3 -I - "$work/game.apkm" <<'PY2'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("base.apk", "base-binary\n")
    z.writestr("split_config.x86_64.apk", "split-binary\n")
    z.writestr("split_config.arm64_v8a.apk", "arm-binary\n")
PY2
key="$(sha256sum "$work/game.apkm" | cut -c1-16)"
mkdir -p "$STEAM_COMPAT_DATA_PATH/lepton-apkm/$key.tmp" "$STEAM_COMPAT_DATA_PATH/lepton-apkm/0123456789abcdef"
echo partial > "$STEAM_COMPAT_DATA_PATH/lepton-apkm/$key.tmp/base.apk"
echo older-installed > "$STEAM_COMPAT_DATA_PATH/lepton-apkm/0123456789abcdef/base.apk"
prepare_apkm "$work/game.apkm"
[[ "$LEPTON_APKM_DIR" == "$STEAM_COMPAT_DATA_PATH/lepton-apkm/$key" && ! -e "$LEPTON_APKM_DIR.tmp" ]]
[[ "$(cat "$LEPTON_APKM_DIR/base.apk")" == base-binary && -f "$LEPTON_APKM_DIR/split_config.x86_64.apk" && ! -e "$LEPTON_APKM_DIR/split_config.arm64_v8a.apk" ]]
[[ "$(cat "$STEAM_COMPAT_DATA_PATH/lepton-apkm/0123456789abcdef/base.apk")" == older-installed ]]
echo 'PASS: legacy base/archive/stale metadata verified against complete APK set; base/split changes, missing/extra/symlink code refused; overlay whiteouts ignored but never accepted as code; interrupted APKM unpack recovered; data, metadata and other caches preserved'
