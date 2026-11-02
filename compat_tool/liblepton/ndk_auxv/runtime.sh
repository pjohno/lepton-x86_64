#!/usr/bin/env bash
# Host-side automatic setup; sourcing this file does not change runtime state.
function ndk_compat_supported()
{
    local rootfs="$1" digest
    [[ -f "$rootfs/system/lib64/libndk_translation.so" && -f "$rootfs/system/build.prop" ]] || return 1
    grep -qx 'ro.dalvik.vm.native.bridge=libndk_translation.so' "$rootfs/system/build.prop" || return 1
    digest="$(sha256sum "$rootfs/system/lib64/libndk_translation.so")" || return 1
    [[ "${digest%% *}" == a2086fbc807f697f9b91222065c9d9000ca9727748699c0d9b751319258cbb3e ]]
}

function configure_ndk_compat()
{
    local rc="$1" mode="${LEPTON_NDK_COMPAT:-auto}"
    local rootfs="${LEPTON_TEST_ROOTFS:-${LEPTON_DIR}/../images/rootfs}"
    local shim="${LEPTON_DIR}/ndk_auxv/bin/liblepton_ndk_auxv.so"
    case "$mode" in
        false) return 0 ;;
        auto|true) ;;
        *) echo 'ERROR: LEPTON_NDK_COMPAT must be auto, true or false' >&2; return 1 ;;
    esac
    if ! ndk_compat_supported "$rootfs"; then
        if [[ "$mode" == true ]]; then
            echo 'ERROR: NDK compatibility requires the reviewed Google API 34 r14 bridge' >&2
            return 1
        fi
        return 0
    fi
    if [[ ! -f "$shim" ]]; then
        echo 'ERROR: Build the standard NDK shim using compat_tool/liblepton/ndk_auxv/build.sh --aosp DIR (or set LEPTON_NDK_COMPAT=false)' >&2
        return 1
    fi
    if [[ -n "${LEPTON_ENV_LD_PRELOAD:-}" && "${LEPTON_ENV_LD_PRELOAD}" != /system/lib64/liblepton_ndk_auxv.so ]]; then
        echo 'ERROR: Custom LD_PRELOAD conflicts with automatic NDK compatibility; use LEPTON_NDK_COMPAT=false for a custom preload' >&2
        return 1
    fi
    if [[ -n "${LEPTON_ENV_NDK_TRANSLATION_MODE:-}" && "${LEPTON_ENV_NDK_TRANSLATION_MODE}" != light-translate-or-interpret ]]; then
        echo 'ERROR: Custom NDK translation mode conflicts with automatic compatibility; use LEPTON_NDK_COMPAT=false for comparisons' >&2
        return 1
    fi
    podman_mount_entry "$shim" /system/lib64/liblepton_ndk_auxv.so ro
    {
        printf '    setenv LD_PRELOAD /system/lib64/liblepton_ndk_auxv.so\n'
        printf '    setenv NDK_TRANSLATION_MODE light-translate-or-interpret\n'
        printf '    setenv NDK_TRANSLATION_FLAGS %s\n' "${LEPTON_ENV_NDK_TRANSLATION_FLAGS:-accurate-sigsegv}"
    } >> "$rc"
    echo 'Enabled standard NDK CPU/timer compatibility (light JIT + interpreter)'
}
