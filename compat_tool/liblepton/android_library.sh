#!/bin/bash
# SPDX-License-Identifier: MIT

LEPTON_LIBRARY_ROOT=
LEPTON_MANAGED_APP=
LEPTON_MANAGED_OBB=
LEPTON_LIBRARY_LOCKFD=

function lepton_library_helper()
{
    python3 -E "${LEPTON_DIR}/../tools/lepton-library-runtime" "$@"
}

function lepton_library_location()
{
    local CONFIG="${XDG_CONFIG_HOME:-${HOME}/.config}/lepton-x86_64/android-library.json"
    [[ -e "$CONFIG" || -L "$CONFIG" ]] || return 0
    LEPTON_LIBRARY_ROOT="$(lepton_library_helper location)" || die "Android Library is unavailable"
}

function lepton_library_launch()
{
    local DETAILS LOCATION
    is_sysbake && return 0
    lepton_library_location
    [[ -n "$LEPTON_LIBRARY_ROOT" && -n "${1:-}" ]] || return 0
    LOCATION="$(realpath -sm -- "$1")"
    local RESOLVED
    RESOLVED="$(realpath -m -- "$1")"
    [[ "${LOCATION%/*/*}" == "$LEPTON_LIBRARY_ROOT" || "${RESOLVED%/*/*}" == "$LEPTON_LIBRARY_ROOT" ]] || return 0
    exec {LEPTON_LIBRARY_LOCKFD}<"$LEPTON_LIBRARY_ROOT"
    flock -sn "$LEPTON_LIBRARY_LOCKFD" || die "Android Library is busy. Retry after the current operation finishes."
    DETAILS="$(lepton_library_helper app "$1")" || die "Managed APK validation failed"
    [[ -n "$DETAILS" ]] || return 0
    {
        IFS= read -r LEPTON_MANAGED_APP
        IFS= read -r LEPTON_MANAGED_OBB
        if [[ ! -v LEPTON_SHARED_FOLDERS ]]; then
            local OPTIONAL_SHARING
            IFS= read -r OPTIONAL_SHARING
            if [[ -n "$OPTIONAL_SHARING" ]]; then
                LEPTON_SHARED_FOLDERS="$OPTIONAL_SHARING"
            fi
        fi
    } <<< "${DETAILS}"$'\n'
}

function lepton_install_managed_app()
{
    local -a SPLITS=() OPTIONS=()
    mapfile -t SPLITS < <(apkm_split_paths)
    [[ -z "$LEPTON_MANAGED_OBB" ]] || OPTIONS+=(--obb)
    lepton_library_helper install "${OPTIONS[@]}" "$LEPTON_LIBRARY_ROOT" "$(get_app_id)" \
        "$(get_baked_app_data_dir)" "$LEPTON_CONTEXT" "$(get_apk_path)" "${SPLITS[@]}"
}
