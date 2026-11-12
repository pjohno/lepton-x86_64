#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# x86_64 GPU selection: AMD (RADV) or Intel (ANV) from the host's render
# nodes, the render node Android is given on multi-GPU hosts, clear refusals
# (no usable GPU, missing Vulkan driver, Intel too old for ANV, impossible
# override) and the bundle installer's Intel handling. Fake sysfs trees and
# synthetic bundles; no Podman, Android or real GPU is used.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'chmod -R u+rwX -- "$work" 2>/dev/null; rm -rf -- "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ "$(uname -m)" == x86_64 ]] || { echo 'SKIP: x86_64 only'; exit 0; }

mounting="$repo/compat_tool/liblepton/mounting.sh"
eval "$(sed -n '/^LEPTON_INTEL_PRE_GEN9_IDS="/,/^"$/p' "$mounting")"
for fn in lepton_render_nodes lepton_host_gpu_vendor lepton_vulkan_hal lepton_selected_gpu \
          lepton_gpu_render_node check_host_gpu; do
    eval "$(sed -n "/^function $fn()/,/^}/p" "$mounting")"
done
eval "$(sed -n '/^function die()/,/^}/p; /^function lepton_tell_player()/,/^}/p' "$repo/compat_tool/liblepton/utils.sh")"
lepton_rootfs_dir() { echo "$LEPTON_TEST_ROOTFS"; }
[[ "$LEPTON_INTEL_PRE_GEN9_IDS" == *" 0x0416 "* && "$LEPTON_INTEL_PRE_GEN9_IDS" != *0x3e92* ]] ||
    fail 'pre-Gen9 Intel list not loaded'

# drm NAME "renderD128=0x1002:0x163f renderD129=..." -> fake /sys/class/drm.
drm() {
    local dir="$work/drm-$1" node spec; shift
    mkdir -p "$dir"
    for spec in "$@"; do
        node="${spec%%=*}"; mkdir -p "$dir/$node/device"
        echo "${spec#*=}" | cut -d: -f1 > "$dir/$node/device/vendor"
        echo "${spec#*=}" | cut -d: -f2 > "$dir/$node/device/device"
    done
    echo "$dir"
}
amd="$(drm amd renderD128=0x1002:0x163f)"
intel="$(drm intel renderD128=0x8086:0x3E92)"
hybrid="$(drm hybrid renderD128=0x8086:0x9a49 renderD129=0x1002:0x73df)"
nvidia_intel="$(drm nvidia-intel renderD128=0x10de:0x2484 renderD129=0x8086:0x4680)"
nvidia="$(drm nvidia renderD128=0x10de:0x2484)"
haswell="$(drm haswell renderD128=0x8086:0x0416)"
none="$(drm none)"

rootfs() {   # rootfs NAME DRIVER... -> rootfs with vendor/lib64/hw/vulkan.DRIVER.so
    local dir="$work/rootfs-$1" driver; shift
    mkdir -p "$dir/vendor/lib64/hw"
    for driver in "$@"; do : > "$dir/vendor/lib64/hw/vulkan.$driver.so"; done
    echo "$dir"
}
both="$(rootfs both radeon intel)"
amd_only="$(rootfs amd-only radeon)"
intel_only="$(rootfs intel-only intel)"

# selection SYSFS -> "vendor hal node"
selection() { LEPTON_SYSFS_DRM="$1" bash -c "$(declare -f lepton_render_nodes lepton_host_gpu_vendor lepton_vulkan_hal lepton_selected_gpu lepton_gpu_render_node)"'
    echo "$(lepton_host_gpu_vendor)|$(lepton_vulkan_hal)|$(lepton_gpu_render_node)"'; }
expect() { [[ "$(selection "$1")" == "$2" ]] || fail "$3: got '$(selection "$1")', expected '$2'"; }
expect "$amd"          'amd|radeon|/dev/dri/renderD128'   'AMD only'
expect "$intel"        'intel|intel|/dev/dri/renderD128'  'Intel only'
expect "$hybrid"       'amd|radeon|/dev/dri/renderD129'   'Intel iGPU + AMD dGPU uses the AMD node'
expect "$nvidia_intel" 'intel|intel|/dev/dri/renderD129'  'NVIDIA + Intel uses the Intel node'
expect "$nvidia"       '|radeon|'                          'NVIDIA only has no node'
expect "$none"         '|radeon|'                          'no render nodes'
# Overrides choose the driver, and with it the node.
[[ "$(LEPTON_VULKAN_DRIVER=intel selection "$hybrid")" == 'amd|intel|/dev/dri/renderD128' ]] || fail 'intel override'
[[ "$(LEPTON_VULKAN_DRIVER=bogus selection "$intel")" == 'intel|intel|/dev/dri/renderD128' ]] || fail 'bad override ignored'

# check SYSFS ROOTFS [VAR=VALUE...] -> runs check_host_gpu; output in $work/out.
check() {
    local sysfs="$1" root="$2"; shift 2
    # shellcheck disable=SC2163  # "$@" holds VAR=VALUE assignments
    (export LEPTON_SYSFS_DRM="$sysfs" LEPTON_TEST_ROOTFS="$root" "$@"
     unset LEPTON_MESSAGE_FILE; check_host_gpu) > "$work/out" 2>&1
}
refused() {   # refused MESSAGE SYSFS ROOTFS [VAR=VALUE...]
    local message="$1"; shift
    if check "$@"; then fail "accepted: $message"; fi
    grep -qF -- "$message" "$work/out" || { cat "$work/out"; fail "wrong refusal, wanted: $message"; }
}
check "$amd" "$both"        || fail 'AMD with full bundle'
check "$amd" "$amd_only"    || fail 'AMD with AMD-only bundle (existing behaviour)'
check "$intel" "$both"      || fail 'Intel with Intel bundle'
check "$hybrid" "$amd_only" || fail 'hybrid uses AMD, needs no Intel driver'
check "$nvidia_intel" "$both" || fail 'NVIDIA + Intel'
refused 'has no Intel graphics drivers (an AMD-only bundle)' "$intel" "$amd_only"
refused 'has no radeon Vulkan driver' "$amd" "$intel_only"
refused 'too old for Lepton' "$haswell" "$both"
refused 'device 0x0416' "$haswell" "$both"
refused 'no AMD or Intel GPU render node' "$nvidia" "$both"
refused 'no AMD or Intel GPU render node' "$none" "$both"
refused 'LEPTON_VULKAN_DRIVER=intel, but this computer has no matching GPU' "$amd" "$both" LEPTON_VULKAN_DRIVER=intel
check "$hybrid" "$both" LEPTON_VULKAN_DRIVER=intel || fail 'intel override on hybrid'
# Software rendering and the explicit skip need no GPU at all.
check "$none" "$amd_only" LEPTON_FORCE_SOFTWARE=true || fail 'software rendering refused'
check "$haswell" "$amd_only" LEPTON_SKIP_GPU_CHECK=true || fail 'skip refused'

# Android gets the selected node: gralloc is told, and other render nodes are not mounted.
props="$repo/compat_tool/liblepton/properties.sh"
grep -q 'ro.hardware.vulkan=$(lepton_vulkan_hal)' "$props" || fail 'vulkan HAL not from detection'
grep -q 'gralloc.gbm.device=${render_node}' "$props" || fail 'gralloc not given the render node'
mounts="$(sed -n '/^function setup_podman_mounts()/,/^}/p' "$mounting")"
grep -q 'render_node="$(lepton_gpu_render_node)"' <<< "$mounts" || fail 'mounts ignore the selected node'
grep -qF '[[ "${dev}" != /dev/dri/renderD* || -z "${render_node}" || "${dev}" == "${render_node}" ]] || continue' <<< "$mounts" ||
    fail 'other render nodes still mounted'

# The installer: an Intel host needs a bundle with vulkan.intel.so.
stage="$work/stage"; out="$work/bundles"
mkdir -p "$stage/compat_tool/liblepton" "$stage/compat_tool/sysbake/system" \
    "$stage/compat_tool/images/rootfs/system/etc/init/hw" "$stage/compat_tool/images/rootfs/vendor/lib64/hw" \
    "$stage/compat_tool/images/rootfs_overlay/system/bin" "$stage/tools/bin"
for file in lepton toolmanifest.vdf liblepton/liblepton.sh liblepton/app_metadata.sh liblepton/mounting.sh liblepton/baking.sh; do
    printf '#!/bin/sh\n' > "$stage/compat_tool/$file"
done
printf 'binderfs-ensure\n' > "$stage/compat_tool/images/rootfs/system/etc/init/hw/init.rc"
printf 'ro.build.version.sdk=34\nro.dalvik.vm.native.bridge=0\n' > "$stage/compat_tool/images/rootfs/system/build.prop"
printf 'test-radv\n' > "$stage/compat_tool/images/rootfs/vendor/lib64/hw/vulkan.radeon.so"
printf '#!/bin/sh\n' > "$stage/compat_tool/images/rootfs_overlay/system/bin/binderfs-ensure"
chmod +x "$stage/compat_tool/images/rootfs_overlay/system/bin/binderfs-ensure"
printf '<packages/>\n' > "$stage/compat_tool/sysbake/system/packages.xml"
printf '# file: sysbake/system/packages.xml\nuser.fake=0x31\n' > "$stage/compat_tool/sysbake.xattrs"
printf '#!/bin/sh\n' > "$stage/tools/bin/inotifywait"
mkdir -p "$stage/compat_tool/liblepton/ndk_auxv/bin"
printf 'void fixture(void) {}\n' | cc -x c -shared -nostdlib -fPIC \
    -Wl,-soname,liblepton_ndk_auxv.so -o "$stage/compat_tool/liblepton/ndk_auxv/bin/liblepton_ndk_auxv.so" -
package() {
    bash "$repo/image-14/scripts/internal/deploy-compat-x86_64.sh" --package-only --execute \
        --stage-dir "$stage" --bundle-dir "$out" --bundle-id "$1" > "$work/package-$1.log" 2>&1 ||
        { cat "$work/package-$1.log"; fail "packaging $1"; }
}
package amd-only
printf 'test-anv\n' > "$stage/compat_tool/images/rootfs/vendor/lib64/hw/vulkan.intel.so"
package intel
install_check() {   # install_check SYSFS BUNDLE [ARGS...] -> output in $work/out
    local sysfs="$1" bundle="$2"; shift 2
    mkdir -p "$work/home"
    env -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u DISPLAY -u WAYLAND_DISPLAY HOME="$work/home" \
        LEPTON_SKIP_HOST_CHECK=1 LEPTON_NO_DIALOGS=1 LEPTON_SYSFS_DRM="$sysfs" \
        bash "$repo/compat_tool/tools/lepton-install-bundle" --check "$@" "$out/lepton-x86_64-$bundle.tar.gz" > "$work/out" 2>&1
}
install_check "$intel" intel || { cat "$work/out"; fail 'Intel host refused an Intel bundle'; }
grep -q 'Intel GPU render node found and this bundle has Intel drivers' "$work/out"
if install_check "$intel" amd-only; then fail 'Intel host accepted an AMD-only bundle'; fi
grep -q 'Intel GPU found, but this bundle has no Intel drivers' "$work/out" || { cat "$work/out"; fail 'unclear Intel refusal'; }
install_check "$intel" amd-only --allow-non-amd || fail '--allow-non-amd on Intel'
grep -q 'LEPTON_FORCE_SOFTWARE=true' "$work/out"
for bundle in amd-only intel; do
    install_check "$amd" "$bundle" || { cat "$work/out"; fail "AMD host refused $bundle"; }
    grep -q 'AMD GPU render node found' "$work/out"
done
if install_check "$nvidia" intel; then fail 'NVIDIA host accepted'; fi
grep -q 'No AMD GPU found' "$work/out"
[[ ! -e "$work/home/.local/share/Steam/compatibilitytools.d" ]] || fail '--check installed something'

echo 'PASS: GPU selection (AMD/Intel/hybrid/NVIDIA), selected render node, missing-driver, old-Intel and override refusals, installer Intel bundle detection'
