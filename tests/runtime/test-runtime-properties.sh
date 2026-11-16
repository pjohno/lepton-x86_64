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
setup_props
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
LEPTON_CODEC2=true LEPTON_FORWARD_WEB_INTENTS=true setup_props
grep -qx 'persist.lepton.forward_web_intents=true' "$work/lepton.prop"
grep -qx 'debug.stagefright.ccodec=4' "$work/lepton.prop"
grep -qx 'debug.stagefright.c2-poolmask=786432' "$work/lepton.prop"
probe_sdk=30
LEPTON_CODEC2=true setup_props
grep -qx 'debug.stagefright.ccodec=0' "$work/lepton.prop"
# A usable DMA heap (a read/write character device) enables Codec2 for audio,
# without the boot-breaking BLOB pool mask; LEPTON_CODEC2=false opts out.
probe_sdk=34
LEPTON_DMA_HEAP_DEVICE=/dev/null setup_props
grep -qx 'debug.stagefright.ccodec=4' "$work/lepton.prop"
! grep -q 'c2-poolmask' "$work/lepton.prop"
LEPTON_DMA_HEAP_DEVICE=/dev/null LEPTON_CODEC2=false setup_props
grep -qx 'debug.stagefright.ccodec=0' "$work/lepton.prop"
LEPTON_DMA_HEAP_DEVICE=/dev/null probe_sdk=30 setup_props
grep -qx 'debug.stagefright.ccodec=0' "$work/lepton.prop"
# The heap is passed into the container under the same conditions.
grep -q 'if lepton_dma_heap_usable && \[\[ "${LEPTON_CODEC2:-auto}" != false \]\]; then' "$ROOT/compat_tool/liblepton/mounting.sh"
grep -q 'podman_mount_entry "$(lepton_dma_heap_device)" "/dev/dma_heap/system" rw' "$ROOT/compat_tool/liblepton/mounting.sh"
printf 'PASS: Android URL routing default, explicit Steam opt-in, codec opt-in, DMA-heap Codec2 audio and legacy SDK properties, so replacements\n'

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
