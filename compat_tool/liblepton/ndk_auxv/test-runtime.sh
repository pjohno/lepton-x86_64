#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=compat_tool/liblepton/ndk_auxv/runtime.sh
source "$HERE/runtime.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
LEPTON_DIR="$work/tool/liblepton"
LEPTON_TEST_ROOTFS="$work/rootfs"
rc="$work/zygote.rc"
mkdir -p "$LEPTON_DIR/ndk_auxv/bin" "$LEPTON_TEST_ROOTFS/system/lib64"
mounts=()
podman_mount_entry() { mounts+=("$*"); }
sha256sum() { printf '%s  %s\n' "$test_sha" "$1"; }
test_sha=a2086fbc807f697f9b91222065c9d9000ca9727748699c0d9b751319258cbb3e
unset LEPTON_NDK_COMPAT LEPTON_ENV_LD_PRELOAD LEPTON_ENV_NDK_TRANSLATION_MODE LEPTON_ENV_NDK_TRANSLATION_FLAGS
: > "$rc"
configure_ndk_compat "$rc"
[[ ! -s "$rc" && ${#mounts[@]} == 0 ]] # Native runtime stays untouched.
printf 'ro.dalvik.vm.native.bridge=libndk_translation.so\n' > "$LEPTON_TEST_ROOTFS/system/build.prop"
: > "$LEPTON_TEST_ROOTFS/system/lib64/libndk_translation.so"
if configure_ndk_compat "$rc" 2> "$work/missing.log"; then echo 'FAIL: missing shim accepted'; exit 1; fi
grep -q 'Build the standard NDK shim' "$work/missing.log"
: > "$LEPTON_DIR/ndk_auxv/bin/liblepton_ndk_auxv.so"
configure_ndk_compat "$rc" > "$work/enabled.log"
[[ ${#mounts[@]} == 1 ]]
grep -qx '    setenv LD_PRELOAD /system/lib64/liblepton_ndk_auxv.so' "$rc"
grep -qx '    setenv NDK_TRANSLATION_MODE light-translate-or-interpret' "$rc"
grep -qx '    setenv NDK_TRANSLATION_FLAGS accurate-sigsegv' "$rc"
: > "$rc"; mounts=()
LEPTON_NDK_COMPAT=false configure_ndk_compat "$rc"
[[ ! -s "$rc" && ${#mounts[@]} == 0 ]]
test_sha=unknown
configure_ndk_compat "$rc"
[[ ! -s "$rc" && ${#mounts[@]} == 0 ]]
if LEPTON_NDK_COMPAT=true configure_ndk_compat "$rc" 2> "$work/version.log"; then echo 'FAIL: unsupported bridge forced'; exit 1; fi
test_sha=a2086fbc807f697f9b91222065c9d9000ca9727748699c0d9b751319258cbb3e
if LEPTON_ENV_LD_PRELOAD=/other.so configure_ndk_compat "$rc" 2> "$work/preload.log"; then echo 'FAIL: conflicting preload accepted'; exit 1; fi
if LEPTON_ENV_NDK_TRANSLATION_MODE=heavy-optimize configure_ndk_compat "$rc" 2> "$work/mode.log"; then echo 'FAIL: incompatible mode accepted'; exit 1; fi
[[ ! -s "$rc" && ${#mounts[@]} == 0 ]]
echo 'PASS: default matching-bridge activation, native/unknown skip, opt-out, missing binary and conflicting settings'
