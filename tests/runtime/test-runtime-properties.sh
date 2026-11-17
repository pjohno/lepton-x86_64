#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Exercise generated properties, preserving the default media behavior.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
LEPTON_DIR="$ROOT/compat_tool/liblepton"  # normally set by liblepton.sh
source "$ROOT/compat_tool/liblepton/properties.sh"
# GPU selection comes from mounting.sh; a fake host with one AMD GPU.
for fn in lepton_render_nodes lepton_host_gpu_vendor lepton_vulkan_hal lepton_selected_gpu lepton_gpu_render_node; do
    eval "$(sed -n "/^function $fn()/,/^}/p" "$ROOT/compat_tool/liblepton/mounting.sh")"
done
mkdir -p "$work/drm/renderD128/device"
echo 0x1002 > "$work/drm/renderD128/device/vendor"; echo 0x163f > "$work/drm/renderD128/device/device"
export LEPTON_SYSFS_DRM="$work/drm"
prefix() { printf '%s' "$work"; }
print() { printf '%s' "$*"; }
println() { printf '%s\n' "$*"; }
steamos_devmode_enabled() { return 1; }
is_app() { return 1; }
is_app_baked() { return 1; }
is_sysbake() { return 0; }
android_sdk_version() { printf '%s' "$probe_sdk"; }
export LEPTON_CONTEXT='test'
export LEPTON_FORCE_SOFTWARE=false
probe_sdk=34
unset LEPTON_CODEC2 LEPTON_FORWARD_WEB_INTENTS
export LEPTON_DMA_HEAP_DEVICE="$work/no-dma-heap"   # host without a usable DMA heap
# Fake images: an allocator wrapper without and with patch 0013's marker.
mkdir -p "$work/rootfs-old/vendor/lib64" "$work/rootfs-new/vendor/lib64"
printf 'ELF...gbm_mesa_alloc...' > "$work/rootfs-old/vendor/lib64/libgbm_mesa_wrapper.so"
printf 'ELF...\0lepton-gbm-allocator-no-map-probe\0...' > "$work/rootfs-new/vendor/lib64/libgbm_mesa_wrapper.so"
export LEPTON_TEST_ROOTFS="$work/rootfs-old"
setup_props > "$work/log"
# The silent-media cause is logged, naming the heap; properties are unchanged.
grep -qx "Android media decoders (Codec2): off: this Android image needs host heap access for them, and $work/no-dma-heap does not exist on this host; music and video apps will be silent, games' own audio is unaffected. Images with patch 0013 need no host access." "$work/log"
touch "$work/plain-file"
LEPTON_DMA_HEAP_DEVICE="$work/plain-file" setup_props > "$work/log"
grep -q "heap access for them, and $work/plain-file is not a character device;" "$work/log"
grep -qx 'debug.stagefright.ccodec=0' "$work/lepton.prop"
grep -qx 'persist.lepton.forward_web_intents=false' "$work/lepton.prop"
grep -qx 'debug.stagefright.ccodec=0' "$work/lepton.prop"
! grep -q 'c2-poolmask' "$work/lepton.prop"
# x86_64 hardware graphics: the detected GPU's Vulkan driver and render node.
grep -qx 'ro.hardware.vulkan=radeon' "$work/lepton.prop"
grep -qx 'gralloc.gbm.device=/dev/dri/renderD128' "$work/lepton.prop"
# NVIDIA first, Intel second: ANV, and gralloc on the Intel node.
mkdir -p "$work/drm-intel/renderD128/device" "$work/drm-intel/renderD129/device"
echo 0x10de > "$work/drm-intel/renderD128/device/vendor"; echo 0x8086 > "$work/drm-intel/renderD129/device/vendor"
LEPTON_SYSFS_DRM="$work/drm-intel" setup_props
grep -qx 'ro.hardware.vulkan=intel' "$work/lepton.prop"
grep -qx 'gralloc.gbm.device=/dev/dri/renderD129' "$work/lepton.prop"
# Software rendering: no hardware HAL and no render node.
LEPTON_FORCE_SOFTWARE=true setup_props
grep -qx 'ro.hardware.vulkan=pastel' "$work/lepton.prop"
! grep -q 'gralloc.gbm.device' "$work/lepton.prop"
LEPTON_SYSFS_DRM="$work/drm" setup_props
# Valve upstream: shared-library replacements by GNU build ID.
grep -qx 'ro.lepton.soreplace.25f52dbf904d24e2=/data/steamvr/runtime/bin/androidarm64/libopenxr_loader.so' "$work/lepton.prop"
LEPTON_FORWARD_WEB_INTENTS=true setup_props > /dev/null
grep -qx 'persist.lepton.forward_web_intents=true' "$work/lepton.prop"

# Media decoders (Codec2). Images with patch 0013 use Valve's gralloc pool
# mask and need no host device, whatever the user's groups.
assert_mode() {  # expected-mode expected-ccodec expected-mask|none
    [[ "$(lepton_codec2_mode)" == "$1" ]] || { echo "FAIL: mode $(lepton_codec2_mode), expected $1"; exit 1; }
    setup_props > "$work/log"
    grep -qx "debug.stagefright.ccodec=$2" "$work/lepton.prop" || { echo "FAIL: ccodec for $1"; exit 1; }
    if [[ "$3" == none ]]; then
        if grep -q 'c2-poolmask' "$work/lepton.prop"; then echo "FAIL: pool mask set for $1"; exit 1; fi
    else
        grep -qx "debug.stagefright.c2-poolmask=$3" "$work/lepton.prop" || { echo "FAIL: mask for $1"; exit 1; }
    fi
}
LEPTON_TEST_ROOTFS="$work/rootfs-new" assert_mode blob 4 0xfc0000
if grep -q 'media decoders' "$work/log"; then echo 'FAIL: decoders reported off on a fixed image'; exit 1; fi
LEPTON_TEST_ROOTFS="$work/rootfs-new" LEPTON_DMA_HEAP_DEVICE=/dev/null assert_mode blob 4 0xfc0000
# Older images: the heap if usable (no BLOB mask: it crashes their AMD
# allocator at boot), otherwise off with the reason.
assert_mode off 0 none
LEPTON_DMA_HEAP_DEVICE=/dev/null assert_mode heap 4 none
if grep -q 'media decoders' "$work/log"; then echo 'FAIL: decoders reported off with a usable heap'; exit 1; fi
LEPTON_TEST_ROOTFS="$work/missing" LEPTON_DMA_HEAP_DEVICE=/dev/null assert_mode heap 4 none
# Software rendering uses gralloc.default, which handles BLOB in any image.
LEPTON_FORCE_SOFTWARE=true assert_mode blob 4 0xfc0000
# The overlay's wrapper is the one Android loads, so it decides first.
mkdir -p "$work/tool/liblepton" "$work/tool/images/rootfs_overlay/vendor/lib64"
cp "$work/rootfs-old/vendor/lib64/libgbm_mesa_wrapper.so" "$work/tool/images/rootfs_overlay/vendor/lib64/"
if LEPTON_DIR="$work/tool/liblepton" LEPTON_TEST_ROOTFS="$work/rootfs-new" lepton_gralloc_blob_safe; then
    echo 'FAIL: unfixed overlay wrapper ignored'; exit 1
fi
cp "$work/rootfs-new/vendor/lib64/libgbm_mesa_wrapper.so" "$work/tool/images/rootfs_overlay/vendor/lib64/"
LEPTON_DIR="$work/tool/liblepton" LEPTON_TEST_ROOTFS="$work/rootfs-old" lepton_gralloc_blob_safe
# Explicit choices: false always off; true forces blob (testing).
LEPTON_TEST_ROOTFS="$work/rootfs-new" LEPTON_CODEC2=false assert_mode off 0 none
grep -qx 'Android media decoders (Codec2): off (LEPTON_CODEC2=false); music and video apps will be silent' "$work/log"
LEPTON_CODEC2=true assert_mode blob 4 0xfc0000
# Android 11 has its own decoders: Codec2 off, nothing to report.
probe_sdk=30
LEPTON_TEST_ROOTFS="$work/rootfs-new" assert_mode off 0 none
if grep -q 'media decoders' "$work/log"; then echo 'FAIL: decoders reported off on Android 11'; exit 1; fi
probe_sdk=34
# The heap is passed into the container only in heap mode.
grep -q 'if \[\[ "$(lepton_codec2_mode)" == heap \]\]; then' "$ROOT/compat_tool/liblepton/mounting.sh"
grep -q 'podman_mount_entry "$(lepton_dma_heap_device)" "/dev/dma_heap/system" rw' "$ROOT/compat_tool/liblepton/mounting.sh"
printf 'PASS: Android URL routing default, explicit Steam opt-in, Codec2 modes (gralloc on fixed images, heap or off on older ones, overlay first, software, opt-out/opt-in, Android 11), so replacements\n'

# Local window policy crosses Podman via the generated property file, not env.
LEPTON_LOCAL_DISPLAY_ACTIVE=1 setup_props
if grep -q '^ro.lepton.local_' "$work/lepton.prop"; then echo 'FAIL: sysbake received local display policy'; exit 1; fi
is_sysbake() { return 1; }
app_wants_flatscreen() { return 0; }
LEPTON_LOCAL_DISPLAY_ACTIVE=0 setup_props
if grep -q '^ro.lepton.local_' "$work/lepton.prop"; then echo 'FAIL: Deck received local display policy'; exit 1; fi
LEPTON_LOCAL_DISPLAY_ACTIVE=1 LEPTON_LOCAL_FULLSCREEN=1 LEPTON_LOCAL_OUTPUT=DP-1 setup_props
grep -qx 'ro.lepton.local_display=true' "$work/lepton.prop"
grep -qx 'ro.lepton.local_fullscreen=1' "$work/lepton.prop"
grep -qx 'ro.lepton.local_output=DP-1' "$work/lepton.prop"
LEPTON_LOCAL_DISPLAY_ACTIVE=1 LEPTON_LOCAL_FULLSCREEN=0 setup_props
grep -qx 'ro.lepton.local_fullscreen=0' "$work/lepton.prop"
echo 'PASS: local fullscreen/windowed policy reaches Android properties; Deck and sysbake excluded'
