#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# install-local.sh: host check first, package a stage when the bundle is
# missing, then the bundle's own installer into a throwaway home. Synthetic
# stage and stand-in host tools; no real Steam, Podman or desktop is touched.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
script="$repo/image-14/scripts/install-local.sh"
work="$(mktemp -d)"
trap 'chmod -R u+rwX -- "$work" 2>/dev/null; rm -rf -- "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$repo/image-14/tests/lib/fake-google-adb.sh"

# A minimal complete stage (as in test-deploy-packaging.sh).
stage="$work/stage"; out="$work/bundles"
mkdir -p "$stage/compat_tool/liblepton" "$stage/compat_tool/sysbake/system" \
    "$stage/compat_tool/images/rootfs/system/etc/init/hw" "$stage/compat_tool/images/rootfs/vendor/lib64/hw" \
    "$stage/compat_tool/images/rootfs_overlay/system/bin" "$stage/tools/platform-tools" "$stage/tools/bin"
for file in lepton toolmanifest.vdf liblepton/liblepton.sh liblepton/app_metadata.sh liblepton/mounting.sh liblepton/baking.sh; do
    printf '#!/bin/sh\n' > "$stage/compat_tool/$file"
done
printf 'binderfs-ensure\n' > "$stage/compat_tool/images/rootfs/system/etc/init/hw/init.rc"
printf 'ro.build.version.sdk=34\nro.dalvik.vm.native.bridge=0\n' > "$stage/compat_tool/images/rootfs/system/build.prop"
printf 'test-radv\n' > "$stage/compat_tool/images/rootfs/vendor/lib64/hw/vulkan.radeon.so"
printf '#!/bin/sh\n' > "$stage/compat_tool/images/rootfs_overlay/system/bin/binderfs-ensure"
chmod +x "$stage/compat_tool/images/rootfs_overlay/system/bin/binderfs-ensure"
printf '<packages/>\n' > "$stage/compat_tool/sysbake/system/packages.xml"
# A host-local marker in a reused stage must not leak into a Deck bundle.
printf '%s\n' local-desktop > "$stage/compat_tool/install-profile"
printf '# file: sysbake/system/packages.xml\nuser.fake=0x31\n' > "$stage/compat_tool/sysbake.xattrs"
printf '#!/bin/sh\n' > "$stage/tools/platform-tools/adb"
printf '#!/bin/sh\n' > "$stage/tools/bin/inotifywait"

# A computer that meets the requirements: stand-in tools, Binder, AMD, Steam.
mkdir -p "$work/bin" "$work/drm/renderD128/device" "$work/home/.local/share/Steam"
for tool in podman gamescope setfattr zenity xdpyinfo xprop; do printf '#!/bin/sh\n' > "$work/bin/$tool"; chmod +x "$work/bin/$tool"; done
# Google ADB: a fake download (no network); the installer is pinned to it below.
fake_sha="$(fake_adb_zip "$work/fake-adb")"
install_fake_curl "$work/bin"
export FAKE_ADB_ZIP="$work/fake-adb/platform-tools.zip" FAKE_CURL_LOG="$work/curl.log"
echo 0x1002 > "$work/drm/renderD128/device/vendor"
printf 'nodev\tbinder\n' > "$work/binder"
printf 'nodev\tproc\n' > "$work/no-binder"
home="$work/home"; dest="$home/.local/share/lepton_x86_64_local"
local_install() {
    env -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u LEPTON_SKIP_HOST_CHECK -u DISPLAY -u WAYLAND_DISPLAY \
        -u XDG_CURRENT_DESKTOP LEPTON_NO_DIALOGS=1 HOME="$home" PATH="$work/bin:$PATH" \
        LEPTON_HOST_FILESYSTEMS="${FILESYSTEMS:-$work/binder}" LEPTON_SYSFS_DRM="$work/drm" \
        bash "$script" --bundle-id local --stage-dir "$stage" --bundle-dir "$out" --allow-non-amd "$@" > "$work/out" 2>&1
}

bash "$script" --help | grep -q 'Installs the bundle ID on this computer'
# A computer without Binder is refused before anything is packaged.
if FILESYSTEMS="$work/no-binder" local_install --execute; then fail 'installed without Binder'; fi
grep -q 'Android Binder (BinderFS) kernel support is not available' "$work/out"
[[ ! -e "$out" && ! -e "$dest" ]]
# --check packages nothing and installs nothing.
local_install --check || { cat "$work/out"; fail 'check failed'; }
grep -q 'Local install preflight passed' "$work/out"
[[ ! -e "$out" && ! -e "$dest" ]]
# --execute packages the stage (no bundle yet) and installs it here. The
# shipped installer's ADB pin rejects the fake download: nothing is installed.
if local_install --execute; then fail 'accepted an unpinned ADB'; fi
grep -q 'No bundle yet; packaging stage' "$work/out"
grep -q 'Checking that this computer can run Lepton games' "$work/out"  # installer's own check
grep -q 'does not match the pinned SHA256' "$work/out" && grep -q 'dl.google.com' "$work/curl.log"
[[ ! -e "$dest" ]] || fail 'partial install after a rejected ADB'
installer="$out/lepton-x86_64-steamdeck-local.install.sh"
pin_installer "$installer" "$work/pinned.install.sh" "$fake_sha"
mv -- "$work/pinned.install.sh" "$installer"
sums="$out/lepton-x86_64-steamdeck-local.tar.gz.sha256"   # it also lists the installer
(cd "$out" && sed -i "/ lepton-x86_64-steamdeck-local.install.sh\$/d" "$sums" && sha256sum lepton-x86_64-steamdeck-local.install.sh >> "$sums")
local_install --execute || { cat "$work/out"; fail 'install failed'; }
grep -q 'Using existing bundle' "$work/out"
"$dest/tools/platform-tools/adb" version | grep -qx 'Version 37.0.1-15733141'
[[ -f "$out/lepton-x86_64-steamdeck-local.tar.gz" && -x "$dest/compat_tool/lepton" ]]
grep -qx local-desktop "$dest/compat_tool/install-profile"
[[ -x "$dest/compat_tool/tools/lepton-direct-wayland" ]]
! tar -tzf "$out/lepton-x86_64-steamdeck-local.tar.gz" | grep -q '/install-profile$'
grep -Fq "\"$dest/compat_tool\"" "$home/.local/share/Steam/compatibilitytools.d/lepton_x86_64_local.vdf"
grep -Fqx "Exec=\"$home/.local/bin/lepton-add-game-gui\"" "$home/.local/share/applications/lepton-x86_64-add-game.desktop"
# The existing bundle is reused; installing again needs --replace.
if local_install --execute; then fail 'overwrote an existing install'; fi
grep -q 'Using existing bundle' "$work/out" && grep -q -- '--replace' "$work/out"
touch "$dest/marker"
# --adb-zip is passed on: no download.
: > "$FAKE_CURL_LOG"
local_install --execute --replace --adb-zip "$FAKE_ADB_ZIP" || { cat "$work/out"; fail 'replace failed'; }
[[ ! -s "$FAKE_CURL_LOG" ]] || fail 'downloaded despite --adb-zip'
[[ ! -e "$dest/marker" && -x "$dest/compat_tool/lepton" ]]
grep -qx local-desktop "$dest/compat_tool/install-profile"
# An ordinary bundle replacement also preserves this installation's profile.
env -u DISPLAY -u WAYLAND_DISPLAY HOME="$home" PATH="$work/bin:$PATH" \
    LEPTON_SKIP_HOST_CHECK=1 LEPTON_NO_DIALOGS=1 \
    bash "$installer" --replace --adb-zip "$FAKE_ADB_ZIP" > "$work/out" 2>&1 || { cat "$work/out"; fail 'ordinary replacement failed'; }
grep -qx local-desktop "$dest/compat_tool/install-profile"
# Nothing to install from.
rm -rf "$stage" "$out"
if local_install --execute; then fail 'accepted a missing bundle and stage'; fi
grep -q 'make it with make-deck-bundle-x86_64.sh' "$work/out"
if bash "$script" --execute > /dev/null 2>&1; then fail 'accepted no bundle ID'; fi
echo 'PASS: install-local: host check first, check mode changes nothing, packages a stage, fake ADB download, installs and registers locally, reuse, replace with --adb-zip'
