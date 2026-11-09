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
rm "$work/baked/app_install_complete"; refuses
[[ ! -e "$work/baked/app_hash" ]]
echo 'PASS: legacy base/archive/stale metadata verified against complete APK set; base/split changes, missing/extra/symlink code refused; data and metadata preserved'
