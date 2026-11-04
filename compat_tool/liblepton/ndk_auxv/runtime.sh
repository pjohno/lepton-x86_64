#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
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
    # Translator mode, in order of precedence:
    #   LEPTON_NDK_TRANSLATION_MODE (e.g. in Steam launch options):
    #     light-translate-or-interpret, heavy-optimize, interpret-only, or
    #     "tiered" (the translator's own default: light JIT, then heavy
    #     optimization of hot code);
    #   the game's recorded choice (ndk_prepare_installed_app): "tiered" when
    #     its ARM64 code needs no shim-only instructions;
    #   light-translate-or-interpret (the shim can emulate everything).
    # LEPTON_ENV_NDK_TRANSLATION_FLAGS: default accurate-sigsegv; "none" = no flags.
    local tmode="${LEPTON_NDK_TRANSLATION_MODE:-}" game_mode=""
    export LEPTON_NDK_MODE_SOURCE=setting
    if [[ -z "$tmode" ]]; then
        game_mode="$(cat "$(ndk_game_mode_file)" 2>/dev/null || true)"
        if [[ "$game_mode" == tiered || "$game_mode" == light-translate-or-interpret ]]; then
            tmode="$game_mode"; LEPTON_NDK_MODE_SOURCE=game
        else
            tmode=light-translate-or-interpret; LEPTON_NDK_MODE_SOURCE=default
        fi
    fi
    export LEPTON_NDK_ACTIVE_MODE="$tmode"
    local tflags="${LEPTON_ENV_NDK_TRANSLATION_FLAGS:-accurate-sigsegv}"
    case "$tmode" in
        light-translate-or-interpret|heavy-optimize|interpret-only|tiered) ;;
        *) echo 'ERROR: LEPTON_NDK_TRANSLATION_MODE must be light-translate-or-interpret, heavy-optimize, interpret-only or tiered' >&2; return 1 ;;
    esac
    podman_mount_entry "$shim" /system/lib64/liblepton_ndk_auxv.so ro
    {
        printf '    setenv LD_PRELOAD /system/lib64/liblepton_ndk_auxv.so\n'
        [[ "$tmode" == tiered ]] || printf '    setenv NDK_TRANSLATION_MODE %s\n' "$tmode"
        [[ "$tflags" == none ]] || printf '    setenv NDK_TRANSLATION_FLAGS %s\n' "$tflags"
    } >> "$rc"
    echo "Enabled standard NDK CPU/timer compatibility (translation mode ${tmode} from ${LEPTON_NDK_MODE_SOURCE}, flags ${tflags})"
}

# Per-game translator choice, kept with the game's data.
function ndk_game_mode_file() { print "$(get_baked_app_data_dir)/lepton-ndk-mode"; }

# After installing an ARM64 game: turn the wait hints SEVL/SEV/WFE into NOP in
# its extracted libraries and record whether it can use the fast tiered mode
# (from the next launch). Only with the reviewed translator; never fatal.
function ndk_prepare_installed_app()
{
    local rootfs="${LEPTON_TEST_ROOTFS:-${LEPTON_DIR}/../images/rootfs}"
    local lib_dir mode
    [[ "${LEPTON_NDK_COMPAT:-auto}" != false ]] && ndk_compat_supported "$rootfs" || return 0
    lib_dir="$(app_datadir)/lib/arm64"
    if [[ ! -d "$lib_dir" ]]; then
        rm -f -- "$(ndk_game_mode_file)"
        return 0
    fi
    if mode="$(python3 "${LEPTON_DIR}/ndk_auxv/arm64_hints.py" patch "$lib_dir")"; then
        print "$mode" > "$(ndk_game_mode_file)"
        println "ARM64 game prepared for NDK translation; translator mode from next launch: ${mode}"
    else
        println "WARNING: could not prepare ARM64 libraries; keeping the light translator mode"
        print light-translate-or-interpret > "$(ndk_game_mode_file)"
    fi
    return 0
}

# A game that exits early while running in the automatically chosen tiered mode
# is switched back to the light mode (with the shim's emulation) for next time.
function ndk_note_early_exit()
{
    if [[ "${LEPTON_NDK_MODE_SOURCE:-}" == game && "${LEPTON_NDK_ACTIVE_MODE:-}" == tiered ]]; then
        print light-translate-or-interpret > "$(ndk_game_mode_file)"
        println "Game exited early in the tiered NDK translator mode; using the light mode from the next launch."
    fi
}
