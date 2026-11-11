#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Check missing/present sparse-image conversion tools before compilation.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
fake="$work/repo"
mkdir -p "$fake/image-14/scripts/lib" "$fake/image-14/scripts/internal" "$work/bin" "$work/ws"
cp "$repo/image-14/scripts/preflight-x86_64.sh" "$fake/image-14/scripts/"
cp "$repo/image-14/scripts/lib/"{workspace.sh,packaging-fuse.sh} "$fake/image-14/scripts/lib/"
# Host tools are checked by the shared capability checker (also used by do_build).
cp "$repo/image-14/scripts/internal/"{check-host-capabilities.py,probe-binderfs.py} "$fake/image-14/scripts/internal/"
cat > "$fake/.build-env" <<ENV
LEPTON_OUTPUT_DIR=$work/ws
LEPTON_BUILD_TARGET=aosp_lepton_x86_64-ap2a-userdebug
LEPTON_BUILD_JOBS=1
LEPTON_MIN_FREE_GIB=0
LEPTON_BUILD_CONTAINER=lepton-builder-ubuntu26:latest
ENV
# An isolated PATH makes this test independent of installed host packages.
for tool in bash dirname realpath awk cmp python3 tee mktemp; do
    ln -s "$(command -v "$tool")" "$work/bin/$tool"
done
for tool in podman rsync sqfs2tar tar unzip fuse2fs fusermount3; do
    printf '#!/bin/bash\nexit 0\n' > "$work/bin/$tool"; chmod +x "$work/bin/$tool"
done
printf '#!/bin/bash\necho " pinned"\n' > "$work/bin/git"
printf '#!/bin/bash\necho ext4\n' > "$work/bin/findmnt"
printf '#!/bin/bash\necho "fixture 100000000 0 100000000 0 fixture"\n' > "$work/bin/df"
printf '#!/bin/bash\necho 1\n' > "$work/bin/nproc"
chmod +x "$work/bin/"{git,findmnt,df,nproc}
# Source inventory checks must not mask the host-tool result.
while read -r file; do
    mkdir -p "$fake/$(dirname "$file")"; touch "$fake/$file"
done <<'FILES'
image-14/.buildscripts/container.sh
image-14/.buildscripts/update_repositories.sh
image-14/.buildscripts/copy_vendored_projects.sh
image-14/android_vendor_valve/vendorsetup.sh
image-14/android_vendor_valve/patches/apply-patches.sh
image-14/scripts/internal/bootstrap-glslang14.sh
image-14/scripts/build-images-x86_64.sh
FILES
for mode in fresh existing full; do
    if [[ "$mode" != fresh ]]; then
        aosp="$work/ws/aosp"
        mkdir -p "$aosp/.repo" "$aosp/build" "$aosp/.lepton-clean14-state" "$aosp/out/target/product/lepton_x86_64"
        touch "$aosp/.repo/manifest.xml" "$aosp/build/envsetup.sh" "$aosp/.lepton-clean14-owner" "$aosp/.lepton-clean14-state/"{sync,vendor,patches}.done
        printf image > "$aosp/out/target/product/lepton_x86_64/system.img"
        printf image > "$aosp/out/target/product/lepton_x86_64/vendor.img"
    fi
    rm -f "$work/bin/simg2img"
    if PATH="$work/bin" /bin/bash "$fake/image-14/scripts/preflight-x86_64.sh" "$mode" > "$work/result" 2>&1; then
        echo "FAIL: $mode accepted missing simg2img"; exit 1
    fi
    grep -Fq '[FAIL] Missing rootfs packaging executable: simg2img' "$work/result"
    grep -Fq 'android-tools' "$work/result"                 # Fedora package
    grep -Fq 'android-sdk-libsparse-utils' "$work/result"   # Ubuntu package
    printf '#!/bin/bash\nexit 0\n' > "$work/bin/simg2img"; chmod +x "$work/bin/simg2img"
    # Full mode additionally checks the real FUSE device; no device is created.
    PATH="$work/bin" /bin/bash "$fake/image-14/scripts/preflight-x86_64.sh" "$mode" > "$work/result" 2>&1 || true
    grep -Fq 'Rootfs packaging executables' "$work/result"   # the check ran
    if grep -Fq 'executable: simg2img' "$work/result"; then exit 1; fi
done
echo 'PASS: simg2img checked in fresh, existing and full preflight, with installation guidance'
