#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Exercise generated properties, preserving the default media behavior.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
LEPTON_DIR="$ROOT/compat_tool/liblepton"  # normally set by liblepton.sh
source "$ROOT/compat_tool/liblepton/properties.sh"
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
