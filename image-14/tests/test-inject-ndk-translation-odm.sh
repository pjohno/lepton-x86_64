#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Regress the Lepton 64-bit native-bridge ABI behaviour without Android/AOSP.
set -Eeuo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
injector="$repo/image-14/scripts/inject-ndk-translation.sh"
[[ -f "$injector" ]] || { echo "FAIL: missing injector" >&2; exit 1; }
for command in rsync python3 sha256sum cmp; do command -v "$command" >/dev/null || exit 1; done
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
src="$scratch/source"; pay="$scratch/translator/payload"
mkdir -p "$src/system/bin" "$src/vendor/lib64/hw" "$src/vendor/odm/etc" "$pay/system/lib64/arm64" "$pay/system/bin/arm64" "$pay/system/etc"
printf '#!/bin/sh\n' > "$src/system/bin/sh"; chmod +x "$src/system/bin/sh"
printf 'radeon intact\n' > "$src/vendor/lib64/hw/vulkan.radeon.so"
ln -s vendor/odm "$src/odm"
cat > "$src/system/build.prop" <<'EOF'
ro.build.version.sdk=34
ro.product.cpu.abi=x86_64
ro.dalvik.vm.native.bridge=0
ro.system.product.cpu.abilist=x86_64
ro.system.product.cpu.abilist32=
ro.system.product.cpu.abilist64=x86_64
EOF
cat > "$src/vendor/build.prop" <<'EOF'
ro.vendor.product.cpu.abilist=x86_64
ro.vendor.product.cpu.abilist32=
ro.vendor.product.cpu.abilist64=x86_64
EOF
cat > "$src/vendor/odm/etc/build.prop" <<'EOF'
ro.odm.product.cpu.abilist=x86_64
ro.odm.product.cpu.abilist32=
ro.odm.product.cpu.abilist64=x86_64
EOF
for name in libndk_translation.so libndk_translation_exec_region.so libndk_translation_proxy_libEGL.so libndk_translation_proxy_libvulkan.so; do printf 'fake %s\n' "$name" > "$pay/system/lib64/$name"; done
for name in libc.so libnative_bridge_vdso.so; do printf 'fake %s\n' "$name" > "$pay/system/lib64/arm64/$name"; done
for name in linker64 app_process64; do printf 'fake %s\n' "$name" > "$pay/system/bin/arm64/$name"; done
printf 'fake config\n' > "$pay/system/etc/ld.config.arm64.txt"
for number in $(seq 1 50); do printf 'fake %s\n' "$number" > "$pay/system/lib64/arm64/test-$number.so"; done
(cd "$pay" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$scratch/translator/SHA256SUMS"
bash "$injector" --check --rootfs "$src" --payload "$pay" --output "$scratch/new" > /dev/null
bash "$injector" --execute --rootfs "$src" --payload "$pay" --output "$scratch/new" > /dev/null
for partition in system vendor; do
  grep -qx "ro.$partition.product.cpu.abilist64=x86_64,arm64-v8a" "$scratch/new/rootfs/$partition/build.prop"
  grep -qx "ro.$partition.product.cpu.abilist32=" "$scratch/new/rootfs/$partition/build.prop"
done
grep -qx 'ro.odm.product.cpu.abilist=x86_64,arm64-v8a' "$scratch/new/rootfs/vendor/odm/etc/build.prop"
grep -qx 'ro.odm.product.cpu.abilist64=x86_64,arm64-v8a' "$scratch/new/rootfs/vendor/odm/etc/build.prop"
grep -qx 'ro.odm.product.cpu.abilist32=' "$scratch/new/rootfs/vendor/odm/etc/build.prop"
grep -qx 'ro.dalvik.vm.native.bridge=libndk_translation.so' "$scratch/new/rootfs/system/build.prop"
grep -qx 'ro.dalvik.vm.isa.arm64=x86_64' "$scratch/new/rootfs/system/build.prop"
grep -qx 'ro.ndk_translation.flags=accurate-sigsegv' "$scratch/new/rootfs/system/build.prop"
grep -qx 'ro.odm.product.cpu.abilist64=x86_64' "$src/vendor/odm/etc/build.prop"
cmp "$src/vendor/lib64/hw/vulkan.radeon.so" "$scratch/new/rootfs/vendor/lib64/hw/vulkan.radeon.so" >/dev/null
if bash "$injector" --execute --rootfs "$src" --payload "$pay" --output "$scratch/new" > "$scratch/overwrite.log" 2>&1; then
    echo 'FAIL: existing output could be overwritten' >&2; exit 1
fi
# An unexpected ODM ABI set must be refused, never silently patched.
sed -i 's/ro.odm.product.cpu.abilist64=x86_64$/ro.odm.product.cpu.abilist64=armeabi-v7a/' "$src/vendor/odm/etc/build.prop"
if bash "$injector" --check --rootfs "$src" --payload "$pay" --output "$scratch/refused" > "$scratch/reject.log" 2>&1; then
    echo 'FAIL: unexpected ODM property accepted' >&2; exit 1
fi
grep -q 'Unexpected ODM ABI property' "$scratch/reject.log"
sed -i 's/ro.odm.product.cpu.abilist64=armeabi-v7a$/ro.odm.product.cpu.abilist64=x86_64/' "$src/vendor/odm/etc/build.prop"
mkdir -p "$src/product/etc"
printf 'ro.product.product.cpu.abilist64=x86_64\n' > "$src/product/etc/build.prop"
if bash "$injector" --check --rootfs "$src" --payload "$pay" --output "$scratch/another-refused" > "$scratch/product-reject.log" 2>&1; then
    echo 'FAIL: unexpected product property accepted' >&2; exit 1
fi
grep -q 'Unexpected higher-priority ABI properties' "$scratch/product-reject.log"
echo 'PASS: ODM ABI override corrected, 32-bit disabled, original/AMD preserved, fail-closed guards'
