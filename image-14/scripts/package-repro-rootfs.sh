#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 /path/to/aosp-checkout" >&2
    exit 2
fi

aosp="$(readlink -f "$1")"
product="$aosp/out/target/product/lepton_x86_64"
stage="$aosp/repro-rootfs-auto"
target="$stage/rootfs"

[[ -d "$aosp/.repo" ]] || { echo "Not an AOSP checkout" >&2; exit 1; }
[[ -f "$product/system.img" && -f "$product/vendor.img" ]] || {
    echo "Missing Android images" >&2
    exit 1
}
[[ ! -e "$target" && ! -L "$target" ]] || {
    echo "Refusing to overwrite $target" >&2
    exit 1
}

for tool in simg2img sqfs2tar tar unzip fuse2fs fusermount3 rsync; do
    command -v "$tool" >/dev/null || {
        echo "Missing required tool: $tool" >&2
        exit 1
    }
done

mkdir -p "$stage"
tmp="$(mktemp -d "$stage/.package-XXXXXXXX")"
mounted=''

cleanup() {
    if [[ -n "$mounted" ]]; then
        fusermount3 -u "$mounted" || true
    fi
    rm -rf -- "$tmp"
}
trap cleanup EXIT

echo "Converting Android sparse images..."
for part in system vendor; do
    simg2img "$product/$part.img" "$tmp/$part.raw.img"
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
    unpack="$tmp/apex-unpack"
    mountdir="$tmp/apex-mount"
    dest="${apex%.apex}"

    mkdir -p "$unpack" "$mountdir" "$dest"
    unzip -q "$apex" -d "$unpack"
    fuse2fs -o fakeroot "$unpack/apex_payload.img" "$mountdir"
    mounted="$mountdir"

    rsync -a --exclude='lost+found' "$mountdir/" "$dest/"

    fusermount3 -u "$mounted"
    mounted=''

    rm -rf -- "$unpack" "$mountdir"
    rm -- "$apex"
    ((count += 1))
done

"$(dirname -- "${BASH_SOURCE[0]}")/patch-binderfs-init.sh" "$tmp/rootfs"

[[ -f "$tmp/rootfs/system/build.prop" ]]
[[ -f "$tmp/rootfs/vendor/lib64/hw/vulkan.radeon.so" ]]
[[ ! -e "$target" && ! -L "$target" ]]

mv "$tmp/rootfs" "$target"

echo "PASS: Flattened $count APEX packages"
echo "PASS: Reproduced rootfs available at $target"
