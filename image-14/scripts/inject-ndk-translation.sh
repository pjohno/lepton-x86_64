#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Experimental Android 14 x86_64 -> ARM64 bridge injection into a NEW rootfs copy.
# Never edits the source Lepton rootfs, translator payload, compiled images or sysbake.
set -Eeuo pipefail
umask 022

usage() {
    cat <<'HELP'
Usage:
  inject-ndk-translation.sh --check|--execute \
      --rootfs /path/to/original/lepton/rootfs \
      --payload /path/to/ndk-google-api34-r14/payload \
      --output /path/to/NEW/lepton-ndk-stage

--check (default) validates inputs, file collisions and hashes without writing.
--execute creates a NEW directory containing:
    rootfs/                  independent Lepton rootfs with the ARM64 bridge
    NDK-INJECTION-REPORT.txt audit and provenance details

This DOES NOT modify or launch a compatibility-tool stage. It does not touch
Podman, any Steam Deck installation, sysbake, or any source images.
Do not use this script against a live or working rootfs as --output.
HELP
}
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
info() { printf 'INFO: %s\n' "$*"; }
mode=--check
src=''
payload=''
out=''
while (($#)); do
    case "$1" in
        --check|--execute) mode=$1; shift ;;
        --rootfs) (($# >= 2)) || fail '--rootfs needs an argument'; src=$2; shift 2 ;;
        --payload) (($# >= 2)) || fail '--payload needs an argument'; payload=$2; shift 2 ;;
        --output) (($# >= 2)) || fail '--output needs an argument'; out=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done
[[ -n "$src" && -n "$payload" && -n "$out" ]] || { usage >&2; fail 'Missing required argument'; }
for cmd in rsync sha256sum realpath python3 find grep sort wc cmp mktemp; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Missing required tool: $cmd"
done
src=$(realpath -e -- "$src") || fail 'Source rootfs does not exist'
payload=$(realpath -e -- "$payload") || fail 'Payload does not exist'
out=$(realpath -m -- "$out")
parent=$(dirname -- "$out")
[[ -d "$src" && -d "$payload" && ! -L "$src" && ! -L "$payload" ]] || fail 'Inputs must be directories'
[[ -d "$parent" && ! -L "$parent" ]] || fail 'Output parent must exist and not be a symlink'
[[ "$out" != / && "$out" != "$HOME" && "$out" != "$src" && "$out" != "$payload" ]] || fail 'Unsafe output directory'
[[ "$out" != "$src/"* && "$out" != "$payload/"* && "$src" != "$out/"* && "$payload" != "$out/"* ]] || fail 'Overlapping source, payload and output paths'
[[ ! -e "$out" && ! -L "$out" ]] || fail "Output already exists: $out"

[[ -f "$src/system/build.prop" && -f "$src/vendor/build.prop" && -x "$src/system/bin/sh" ]] || fail 'Not a complete Android rootfs'
[[ -f "$src/vendor/lib64/hw/vulkan.radeon.so" ]] || fail 'Lepton RADV Vulkan driver missing'
grep -qx 'ro.build.version.sdk=34' "$src/system/build.prop" || fail 'Expected Android 14/API 34'
grep -qx 'ro.product.cpu.abi=x86_64' "$src/system/build.prop" || fail 'Expected x86_64 Lepton rootfs'
[[ $(grep -c '^ro.dalvik.vm.native.bridge=0$' "$src/system/build.prop") -eq 1 ]] || fail 'Expected exactly one disabled native bridge property in system/build.prop'
for spec in \
    'system/build.prop:ro.system.product.cpu.abilist=x86_64' \
    'system/build.prop:ro.system.product.cpu.abilist64=x86_64' \
    'system/build.prop:ro.system.product.cpu.abilist32=' \
    'vendor/build.prop:ro.vendor.product.cpu.abilist=x86_64' \
    'vendor/build.prop:ro.vendor.product.cpu.abilist64=x86_64' \
    'vendor/build.prop:ro.vendor.product.cpu.abilist32='; do
    file=${spec%%:*}
    property=${spec#*:}
    [[ $(grep -Fxc -- "$property" "$src/$file") -eq 1 ]] || fail "Expected exactly one '$property' in $file"
done
if grep -Eh '^ro\.(dalvik\.vm\.isa\.arm64|product\.cpu\.abilist(32|64)?)=' "$src/system/build.prop" "$src/vendor/build.prop" | grep -q .; then
    fail 'Existing explicit ARM64 mapping or final ABI list requires review'
fi
# On Lepton, ODM's real property file lives under vendor/odm/etc rather
# than at the rootfs's /odm/build.prop. ODM overrides vendor/system when
# Android computes ro.product.cpu.abilist64 for Zygote.
odm_prop='vendor/odm/etc/build.prop'
if [[ -f "$src/$odm_prop" ]]; then
    for property in \
        'ro.odm.product.cpu.abilist=x86_64' \
        'ro.odm.product.cpu.abilist64=x86_64' \
        'ro.odm.product.cpu.abilist32='; do
        [[ $(grep -Fxc -- "$property" "$src/$odm_prop") -eq 1 ]] ||
            fail "Unexpected ODM ABI property in $odm_prop: $property"
    done
fi
# Do not silently ignore another higher-priority ABI source. Common /odm
# paths may point to vendor/odm; allow only that same canonical file.
for extra in \
    product/build.prop product/etc/build.prop \
    system/product/build.prop system/product/etc/build.prop \
    odm/build.prop odm/etc/build.prop vendor/odm/build.prop; do
    candidate="$src/$extra"
    [[ -f "$candidate" ]] || continue
    if [[ -f "$src/$odm_prop" ]] &&
       [[ "$(realpath -e -- "$candidate")" == "$(realpath -e -- "$src/$odm_prop")" ]]; then
        continue
    fi
    if grep -Eq '^ro\.(product|odm)\.product\.cpu\.abilist(32|64)?=' "$candidate"; then
        fail "Unexpected higher-priority ABI properties in $extra"
    fi
done

[[ -f "$(dirname -- "$payload")/SHA256SUMS" ]] || fail 'Extraction checksum manifest missing'
manifest="$(dirname -- "$payload")/SHA256SUMS"
if ! (cd "$payload" && sha256sum -c -- "$manifest" >/dev/null); then
    fail 'Payload checksum verification failed'
fi
[[ ! -n $(find "$payload" -type l -print -quit) ]] || fail 'Unexpected symlink in payload'
expected=$(wc -l < "$manifest")
actual=$(find "$payload" -type f -print | wc -l)
[[ "$actual" -eq "$expected" && "$actual" -ge 50 ]] || fail "Payload count mismatch: manifest=$expected actual=$actual"
for path in \
    system/lib64/libndk_translation.so \
    system/lib64/libndk_translation_exec_region.so \
    system/lib64/libndk_translation_proxy_libEGL.so \
    system/lib64/libndk_translation_proxy_libvulkan.so \
    system/lib64/arm64/libc.so \
    system/lib64/arm64/libnative_bridge_vdso.so \
    system/bin/arm64/linker64 \
    system/bin/arm64/app_process64 \
    system/etc/ld.config.arm64.txt; do
    [[ -s "$payload/$path" ]] || fail "Required translator file missing: $path"
done

# The payload is deliberately allowlisted; neither Google core libraries nor
# init/binfmt_misc configuration may be silently transplanted.
count=0
while IFS= read -r -d '' file; do
    rel=${file#"$payload"/}
    case "$rel" in
        system/lib64/libndk_translation*.so|system/lib64/arm64/*|system/bin/arm64/*|\
        system/etc/ld.config.arm64.txt|system/etc/cpuinfo.arm64.txt) ;;
        *) fail "Unexpected payload entry: $rel" ;;
    esac
    [[ ! -e "$src/$rel" && ! -L "$src/$rel" ]] || fail "Would overwrite an existing Lepton file: $rel"
    ((count+=1))
done < <(find "$payload" -type f -print0)
[[ "$count" -eq "$expected" ]] || fail 'Payload inventory changed during preflight'
info "Original rootfs: $src"
info "Native bridge payload: $payload ($count verified files)"
info "New stage: $out"
if [[ "$mode" == --check ]]; then
    printf 'PASS: Injection preflight succeeded (no files modified)\n'
    exit 0
fi

work=$(mktemp -d "$parent/.lepton-ndk-inject.XXXXXXXX")
cleanup() { [[ -z "${work:-}" ]] || rm -rf -- "$work"; }
trap cleanup EXIT
mkdir "$work/rootfs"
info 'Copying source rootfs into private stage...'
rsync -a --no-owner --no-group -- "$src/" "$work/rootfs/"
info 'Adding translator-only files...'
rsync -a --no-owner --no-group -- "$payload/" "$work/rootfs/"

# Replace build-time read-only properties in the *copy* rather than appending
# conflicting properties via /vendor/waydroid.prop after Android init.
python3 - "$work/rootfs" <<'PY'
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
changes = {
    "system/build.prop": {
        "ro.dalvik.vm.native.bridge": ("0", "libndk_translation.so"),
        "ro.system.product.cpu.abilist": ("x86_64", "x86_64,arm64-v8a"),
        "ro.system.product.cpu.abilist64": ("x86_64", "x86_64,arm64-v8a"),
    },
    "vendor/build.prop": {
        "ro.vendor.product.cpu.abilist": ("x86_64", "x86_64,arm64-v8a"),
        "ro.vendor.product.cpu.abilist64": ("x86_64", "x86_64,arm64-v8a"),
    },
}
odm = "vendor/odm/etc/build.prop"
if (root / odm).is_file():
    changes[odm] = {
        "ro.odm.product.cpu.abilist": ("x86_64", "x86_64,arm64-v8a"),
        "ro.odm.product.cpu.abilist64": ("x86_64", "x86_64,arm64-v8a"),
    }
for relative, props in changes.items():
    target = root / relative
    original = target.read_text()
    lines = original.splitlines(keepends=True)
    for key, (old, new) in props.items():
        old_line = f"{key}={old}"
        matches = [i for i, line in enumerate(lines) if line.rstrip("\r\n") == old_line]
        if len(matches) != 1:
            raise SystemExit(f"Expected exactly one {old_line} in {relative}")
        index = matches[0]
        terminator = "\n" if lines[index].endswith("\n") else ""
        lines[index] = f"{key}={new}{terminator}"
        if key == "ro.dalvik.vm.native.bridge":
            lines.insert(index + 1, "ro.dalvik.vm.isa.arm64=x86_64\n")
            lines.insert(index + 2, "ro.ndk_translation.flags=accurate-sigsegv\n")
    target.write_text("".join(lines))
PY

# The AMD graphics payload must remain byte-for-byte unchanged.
cmp -s "$src/vendor/lib64/hw/vulkan.radeon.so" "$work/rootfs/vendor/lib64/hw/vulkan.radeon.so" || fail 'AMD Vulkan driver changed unexpectedly'
for prop in system vendor; do
    if cmp -s "$src/$prop/build.prop" "$work/rootfs/$prop/build.prop"; then
        fail "Expected $prop/build.prop to change"
    fi
done
if [[ -f "$src/vendor/odm/etc/build.prop" ]]; then
    cmp -s "$src/vendor/odm/etc/build.prop" \
        "$work/rootfs/vendor/odm/etc/build.prop" &&
        fail 'Expected vendor/odm/etc/build.prop to change'
fi
{
    printf 'Experimental Lepton Android 14 ARM64 Native Bridge rootfs\n'
    printf 'Original rootfs: %s\n' "$src"
    printf 'Bridge payload: %s\n' "$payload"
    printf 'Translator library: /system/lib64/libndk_translation.so\n'
    printf 'Native ISA: x86_64\n'
    printf 'Translated ABI: arm64-v8a\n'
    printf '32-bit ABIs: disabled\n'
    printf 'ODM ABI properties: adjusted when present under vendor/odm/etc/build.prop\n'
    printf 'Linux binfmt_misc: not enabled\n'
    printf 'Existing GPU driver: unchanged (byte-for-byte verified)\n'
    printf 'Pre-existing sysbake: not modified; fresh test data required for boot\n'
    printf 'WARNING: This is not a complete runnable Lepton stage.\n'
    printf 'WARNING: Validate Zygote startup and loaded native bridge via logs.\n'
    printf '\nPayload checksum manifest SHA256: '
    sha256sum "$manifest" | cut -d' ' -f1
    for propfile in system/build.prop vendor/build.prop vendor/odm/etc/build.prop; do
        [[ -f "$src/$propfile" ]] || continue
        printf 'Original %s SHA256: ' "$propfile"
        sha256sum "$src/$propfile" | cut -d' ' -f1
    done
} > "$work/NDK-INJECTION-REPORT.txt"
[[ ! -e "$out" && ! -L "$out" ]] || fail 'Destination appeared during preparation'
mv -T -- "$work" "$out"
work=''
printf 'PASS: Injected disposable rootfs at %s/rootfs\n' "$out"
printf 'PASS: Report at %s/NDK-INJECTION-REPORT.txt\n' "$out"
printf 'NOTE: Original rootfs, images, sysbake, Podman and Steam Deck untouched.\n'
