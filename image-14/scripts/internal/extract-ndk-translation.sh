#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Extract only Android 14 x86_64 -> ARM64 native-bridge support files
# from an already-unpacked Google APIs emulator logical system.img.
# This script NEVER modifies the source image or any Lepton rootfs.
set -Eeuo pipefail
umask 022

usage() {
    cat <<'HELP'
Usage:
  extract-ndk-translation.sh --source-img /path/to/google/system.img \
      --output /path/to/new/ndk-payload

The source must be the Android 14/API 34 ext2/ext4 logical system.img
extracted by lpunpack, NOT the GPT disk image or an Android sparse image.

Creates a new, versioned extraction directory containing:
  payload/system/lib64/libndk_translation*.so
  payload/system/lib64/arm64/*
  payload/system/bin/arm64/*
  payload/system/etc/ld.config.arm64.txt
  payload/system/etc/cpuinfo.arm64.txt
  SHA256SUMS, SOURCE.txt, and GOOGLE-BRIDGE-PROPERTIES.txt

This is an EXTRACT-ONLY research tool. It does not install, enable,
run, or distribute the proprietary translator, nor modify Podman.
It intentionally excludes 32-bit ARM support and binfmt_misc init.
HELP
}
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

src=''
dst=''
while (($#)); do
    case "$1" in
        --source-img)
            (($# >= 2)) || fail '--source-img requires a value'
            src=$2; shift 2 ;;
        --output)
            (($# >= 2)) || fail '--output requires a value'
            dst=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done
[[ -n "$src" && -n "$dst" ]] || { usage >&2; fail 'Specify both arguments'; }
for tool in debugfs readelf sha256sum mktemp awk sed sort grep find xargs realpath; do
    command -v "$tool" >/dev/null 2>&1 || fail "Missing tool: $tool"
done
src=$(realpath -e -- "$src") || fail 'Source image not found'
[[ -f "$src" && ! -L "$src" ]] || fail 'Source must be a regular file (not a symlink)'
dst=$(realpath -m -- "$dst")
parent=$(dirname -- "$dst")
[[ -d "$parent" && ! -L "$parent" ]] || fail 'Destination parent must exist and not be a symlink'
[[ "$dst" != / && "$dst" != "$src" && "$dst" != "$parent" ]] || fail 'Unsafe destination'
[[ ! -e "$dst" && ! -L "$dst" ]] || fail "Destination already exists: $dst"

work=$(mktemp -d "$parent/.ndk-extract.XXXXXXXX")
cleanup() { if [[ -n "${work:-}" && -d "$work" ]]; then rm -rf -- "$work"; fi; }
trap cleanup EXIT
payload="$work/payload"
mkdir -p "$payload/system/lib64/arm64" "$payload/system/bin/arm64" "$payload/system/etc"
log="$work/debugfs.log"
: > "$log"

# debugfs is read-only unless specifically opened with -w (we never do so).
dbcat() { debugfs -R "cat $1" "$src" 2>>"$log"; }
dbls() { debugfs -R "ls -p $1" "$src" 2>>"$log"; }
copy_file() {
    local remote=$1 mode=$2 target="$payload/${1#/}"
    mkdir -p "$(dirname -- "$target")"
    [[ ! -e "$target" && ! -L "$target" ]] || fail "Duplicate extraction path: $remote"
    debugfs -R "dump \"$remote\" \"$target\"" "$src" >>"$log" 2>&1 || fail "debugfs couldn't read $remote"
    [[ -s "$target" ]] || fail "Missing or empty payload file: $remote (see $log)"
    chmod "$mode" "$target"
}

# Check this is the API 34 system image rather than the outer emulator disk.
if ! dbcat /system/build.prop > "$work/google-build.prop"; then
    fail 'Cannot read /system/build.prop; is this the logical system.img?'
fi
grep -qx 'ro.build.version.sdk=34' "$work/google-build.prop" || fail 'Source is not API 34'
grep -qx 'ro.dalvik.vm.native.bridge=libndk_translation.so' "$work/google-build.prop" || \
    fail 'Source image does not declare the expected native bridge'

# Exact translator prefix excludes unrelated AIDL libraries ending in -ndk.so.
mapfile -t ndk_files < <(
    dbls /system/lib64 |
    awk -F/ '$3 ~ /^10/ && $6 ~ /^libndk_translation[A-Za-z0-9_.-]*\.so$/ {print $6}' |
    sort -u
)
((${#ndk_files[@]} >= 4)) || fail 'Too few libndk_translation libraries found'
for name in "${ndk_files[@]}"; do
    copy_file "/system/lib64/$name" 0644
done
for name in libndk_translation.so libndk_translation_exec_region.so \
            libndk_translation_proxy_libEGL.so libndk_translation_proxy_libvulkan.so; do
    [[ -s "$payload/system/lib64/$name" ]] || fail "Missing required translator library: $name"
done

# Native ARM64 runtime libraries and launcher/linker (not x86 system libraries).
mapfile -t arm64_libs < <(
    dbls /system/lib64/arm64 |
    awk -F/ '$3 ~ /^10/ && $6 ~ /^[A-Za-z0-9_.@+-]+\.so$/ {print $6}' |
    sort -u
)
# Names are quoted for debugfs, so only quotes, backslashes and whitespace are
# unsafe. Real runtime names include '+' and '@' (libc++.so,
# android.hardware.renderscript@1.0.so); never filter those out.
((${#arm64_libs[@]} >= 20)) || fail 'ARM64 runtime library directory appears incomplete'
if dbls /system/lib64/arm64 | awk -F/ '$3 ~ /^10/ && $6 ~ /\.so$/ && $6 !~ /^[A-Za-z0-9_.@+-]+\.so$/ {found=1} END {exit !found}'; then
    fail 'ARM64 runtime library with an unsupported filename; refusing an incomplete payload'
fi
for name in "${arm64_libs[@]}"; do
    copy_file "/system/lib64/arm64/$name" 0644
done
for name in linker64 app_process64; do
    copy_file "/system/bin/arm64/$name" 0755
done
for name in ld.config.arm64.txt cpuinfo.arm64.txt; do
    copy_file "/system/etc/$name" 0644
done

# Basic ELF architecture assertions; the mixed host/guest payload is intentional.
readelf -h "$payload/system/lib64/libndk_translation.so" |
    grep -q 'Machine:.*Advanced Micro Devices X86-64' || fail 'Translator is not an x86_64 ELF'
readelf -h "$payload/system/lib64/arm64/libc.so" |
    grep -q 'Machine:.*AArch64' || fail 'Guest libc is not an ARM64 ELF'
readelf -h "$payload/system/bin/arm64/linker64" |
    grep -q 'Machine:.*AArch64' || fail 'Guest linker is not an ARM64 ELF'
for name in libc.so libc++.so; do
    [[ -s "$payload/system/lib64/arm64/$name" ]] || fail "Missing required ARM64 runtime library: $name"
done
# Every guest dependency must be in the payload (linux-vdso is kernel-provided).
mapfile -t missing_deps < <(
    for elf in "$payload"/system/lib64/arm64/*.so "$payload"/system/bin/arm64/*; do
        readelf -dW "$elf" | sed -n 's/.*(NEEDED).*\[\(.*\)\]$/\1/p'
    done | sort -u | while IFS= read -r needed; do
        [[ "$needed" == linux-vdso.so.1 || -s "$payload/system/lib64/arm64/$needed" ]] || printf '%s\n' "$needed"
    done
)
((${#missing_deps[@]} == 0)) || fail "ARM64 runtime dependencies missing from payload: ${missing_deps[*]}"

# Record exact Google configuration for review; do NOT install these properties.
grep -E '^(ro\.(system\.product\.cpu\.abilist(32|64)?|dalvik\.vm\.native\.bridge|dalvik\.vm\.isa\.arm64|ndk_translation\..*|enable\.native\.bridge\.exec))=' \
    "$work/google-build.prop" > "$work/GOOGLE-BRIDGE-PROPERTIES.txt" || true
rm -- "$work/google-build.prop"
{
    printf 'Source logical system.img: %s\n' "$src"
    printf 'Source SHA256: '
    sha256sum "$src" | awk '{print $1}'
    printf 'Source Android API: 34\n'
    printf 'Native bridge: libndk_translation.so\n'
    printf 'Native architecture: x86_64\n'
    printf 'Translated architecture: arm64-v8a only\n'
    printf 'binfmt_misc: intentionally excluded\n'
    printf 'Installed to Lepton: no\n'
} > "$work/SOURCE.txt"
(
    cd "$payload"
    find . -type f -print0 | sort -z | xargs -0 -r sha256sum
) > "$work/SHA256SUMS"

# Keep extraction diagnostics, then publish only if the destination is still free.
[[ ! -e "$dst" && ! -L "$dst" ]] || fail 'Destination appeared during extraction; refusing overwrite'
mv -T -- "$work" "$dst"
work=''
printf 'PASS: Extracted %d translator libraries and %d ARM64 libraries\n' \
       "${#ndk_files[@]}" "${#arm64_libs[@]}"
printf 'PASS: Payload: %s/payload\n' "$dst"
printf 'PASS: Manifest: %s/SHA256SUMS\n' "$dst"
printf 'NOTE: No Lepton rootfs, sysbake, or image was modified.\n'
