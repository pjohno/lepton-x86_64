#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 /path/to/aosp-checkout [/path/to/new/rootfs]" >&2
    exit 2
fi

aosp="$(readlink -f "$1")"
product="$aosp/out/target/product/lepton_x86_64"
target="$(readlink -m "${2:-$aosp/repro-rootfs-auto/rootfs}")"
stage="$(dirname -- "$target")"

[[ -d "$aosp/.repo" ]] || { echo "Not an AOSP checkout" >&2; exit 1; }
[[ -f "$product/system.img" && -f "$product/vendor.img" ]] || {
    echo "Missing Android images" >&2
    exit 1
}
[[ ! -e "$target" && ! -L "$target" ]] || {
    echo "Refusing to overwrite $target" >&2
    exit 1
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/../lib/packaging-fuse.sh"
lepton_packaging_requirements || exit 1
unmount_helper="$(lepton_fuse_unmount_helper)"
python3 "$script_dir/validate-android-images.py" "$product/system.img" "$product/vendor.img"

mkdir -p "$stage"
tmp="$(mktemp -d "$stage/.package-XXXXXXXX")"
mounted=''
current_apex='none'

cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$mounted" ]] && mountpoint -q -- "$mounted"; then
        if ! timeout 15 "$unmount_helper" -u "$mounted" || mountpoint -q -- "$mounted"; then
            echo "[FAIL] APEX $current_apex: cleanup unmount failed at $mounted; retaining $tmp" >&2
            exit 1
        fi
    fi
    lepton_remove_packaging_tree "$tmp" || status=1
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

apex_fail() { echo "[FAIL] APEX $current_apex: $*" >&2; exit 1; }

echo "Converting Android sparse images..."
for part in system vendor; do
    # Android normally emits sparse SquashFS; accept complete raw SquashFS too.
    if [[ "$(head -c 4 "$product/$part.img")" == hsqs ]]; then
        cp --sparse=always -- "$product/$part.img" "$tmp/$part.raw.img"
    else
        simg2img "$product/$part.img" "$tmp/$part.raw.img"
    fi
done

echo "Extracting system and vendor..."
sqfs2tar "$tmp/system.raw.img" > "$tmp/rootfs.tar"
sqfs2tar -r vendor "$tmp/vendor.raw.img" > "$tmp/vendor.tar"
tar -A -f "$tmp/rootfs.tar" "$tmp/vendor.tar"

mkdir "$tmp/rootfs"
tar -xf "$tmp/rootfs.tar" -C "$tmp/rootfs"

echo "Flattening APEX packages..."
shopt -s nullglob
count=0

for apex in "$tmp/rootfs"/{system,vendor}/apex/*.apex; do
    current_apex="${apex##*/}"
    unpack="$tmp/apex-unpack"
    mountdir="$tmp/apex-mount"
    dest="${apex%.apex}"

    mkdir -p "$unpack" "$mountdir" "$dest"
    unzip -q "$apex" -d "$unpack" || apex_fail 'payload extraction failed'
    # Set the candidate before mounting so signals/partial mount failures are
    # covered by cleanup. Do not copy an empty mount directory on failure.
    mounted="$mountdir"
    if ! timeout 30 fuse2fs -o fakeroot "$unpack/apex_payload.img" "$mountdir" ||
       ! mountpoint -q -- "$mountdir"; then
        apex_fail 'fuse2fs mount failed or did not produce a mounted filesystem'
    fi

    rsync -a --exclude='lost+found' "$mountdir/" "$dest/" || apex_fail 'copying mounted payload failed'

    # fuse2fs uses FUSE 2 on affected Fedora hosts; FUSE 3 is not a substitute.
    if ! timeout 15 "$unmount_helper" -u "$mounted" || mountpoint -q -- "$mounted"; then
        apex_fail "unmount failed at $mounted"
    fi
    mounted=''

    rm -rf -- "$unpack" "$mountdir"
    rm -- "$apex"
    ((count += 1))
done

"$(dirname -- "${BASH_SOURCE[0]}")/patch-binderfs-init.sh" "$tmp/rootfs"

[[ -s "$tmp/rootfs/system/build.prop" ]]
[[ -s "$tmp/rootfs/vendor/lib64/hw/vulkan.radeon.so" ]]
[[ ! -e "$target" && ! -L "$target" ]]

mv "$tmp/rootfs" "$target"

echo "PASS: Flattened $count APEX packages"
echo "PASS: Reproduced rootfs available at $target"
