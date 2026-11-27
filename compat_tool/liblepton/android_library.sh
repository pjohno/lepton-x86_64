#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Android Library support for the launcher. Two installation routes exist:
#
#   managed  an APK in the configured Android Library. Android's package
#            manager installs it natively in the profile (/data/app), so
#            Android verifies and updates it and keeps its data.
#   legacy   any other APK, Steam-distributed games and existing profiles:
#            Valve's baked overlay route in liblepton.sh/baking.sh.
#
# The rest of the launcher asks lepton_managed_app and calls the
# lepton_managed_* functions below instead of testing library variables.
# Container Storage is independent of the route: every non-sysbake launch
# shares it while the library is available, and launches without it when not.

LEPTON_LIBRARY_CONFIGURED=  # configured location, even while unavailable
LEPTON_LIBRARY_ROOT=        # set only while the library is available
LEPTON_MANAGED_APP=         # library directory of a managed launch
LEPTON_MANAGED_OBB=
LEPTON_MANAGED_ACTIVITY=
LEPTON_LIBRARY_LOCKFD=
LEPTON_LIBRARY_RESOLVED=

function lepton_library_helper()
{
    python3 -E "${LEPTON_DIR}/../tools/android-library-runtime" "$@"
}

function lepton_managed_app()
{
    [[ -n "${LEPTON_MANAGED_APP:-}" ]]
}

# Is TARGET a library APK path (ROOT/PACKAGE/FILE), whether or not the
# library's drive is connected?
function lepton_library_path()
{
    local TARGET="$1" ROOT="$LEPTON_LIBRARY_CONFIGURED"
    [[ -n "$ROOT" && -n "$TARGET" ]] || return 1
    local LOCATION RESOLVED
    LOCATION="$(realpath -sm -- "$TARGET")"
    RESOLVED="$(realpath -m -- "$TARGET")"
    [[ "${LOCATION%/*/*}" == "$ROOT" || "${RESOLVED%/*/*}" == "$ROOT" ]]
}

# Decide, once per launch, whether TARGET is managed and whether Container
# Storage can be shared. Only a managed launch requires the library.
function lepton_library_resolve()
{
    local TARGET="${1:-}" CONFIG DETAILS STATUS
    [[ -z "$LEPTON_LIBRARY_RESOLVED" ]] || return 0
    LEPTON_LIBRARY_RESOLVED=1
    is_sysbake && return 0
    CONFIG="${XDG_CONFIG_HOME:-${HOME}/.config}/lepton-x86_64/android-library.json"
    [[ -e "$CONFIG" || -L "$CONFIG" ]] || return 0
    if ! DETAILS="$(lepton_library_helper location)"; then
        println "WARNING: cannot read the Android Library configuration ($CONFIG); launching without Container Storage" >&2
        return 0
    fi
    { IFS= read -r LEPTON_LIBRARY_CONFIGURED; IFS= read -r STATUS; } <<< "$DETAILS"
    if lepton_library_path "$TARGET"; then
        [[ "$STATUS" == available ]] ||
            die "This game is in the Android Library, which is not available. Nothing was changed." \
                "$STATUS"
        LEPTON_LIBRARY_ROOT="$LEPTON_LIBRARY_CONFIGURED"
        lepton_managed_resolve "$TARGET"
    elif [[ "$STATUS" == available ]]; then
        LEPTON_LIBRARY_ROOT="$LEPTON_LIBRARY_CONFIGURED"
    else
        # Container Storage is a convenience: never stop an unrelated launch.
        println "Container Storage not shared this launch: $STATUS"
    fi
}

function lepton_managed_resolve()
{
    local DETAILS
    exec {LEPTON_LIBRARY_LOCKFD}<"$LEPTON_LIBRARY_ROOT"
    flock -sn "$LEPTON_LIBRARY_LOCKFD" ||
        die "The Android Library is busy (leptron is changing it). Try again when it has finished."
    DETAILS="$(lepton_library_helper app "$1" 2>&1)" ||
        die "The Android Library could not check this game. Nothing was changed." "${DETAILS##*$'\n'}"
    [[ -n "$DETAILS" ]] || return 0
    {
        IFS= read -r LEPTON_MANAGED_APP
        IFS= read -r LEPTON_MANAGED_OBB
        IFS= read -r LEPTON_MANAGED_ACTIVITY
        if [[ ! -v LEPTON_SHARED_FOLDERS ]]; then
            local OPTIONAL_SHARING
            IFS= read -r OPTIONAL_SHARING
            if [[ -n "$OPTIONAL_SHARING" ]]; then
                LEPTON_SHARED_FOLDERS="$OPTIONAL_SHARING"
            fi
        fi
    } <<< "${DETAILS}"$'\n'
    # Start the launcher activity of the version this launch installs; an
    # update can rename it.
    [[ -z "$LEPTON_MANAGED_ACTIVITY" ]] || APP_ACTIVITY="$LEPTON_MANAGED_ACTIVITY"
    println "Android Library: managed launch of $LEPTON_MANAGED_APP"
}

# Profile safety (check_kept_app_data): a managed profile keeps a receipt of
# what Android verified; an unmanaged launch must not reuse that profile.
function lepton_managed_profile()
{
    local DIR="$1" MODE="$2"
    if ! lepton_managed_app; then
        [[ ! -e "$DIR/lepton-managed.json" ]] && return 0
        die "This profile belongs to an Android Library app, but the launch is not a library launch. Nothing was changed." \
            "Launch it from its library shortcut, or run leptron status to check the library location."
    fi
    lepton_library_helper profile "$DIR" "$(get_app_id)" "$MODE"
}

function lepton_managed_refuse_reset()
{
    lepton_managed_app || return 0
    die "Refusing LEPTON_RESET_APP_DATA for an Android Library app. Its data was kept."
}

# Mount entries of a managed launch: Android owns the code in /data/app, so
# there is no app overlay. Library OBBs are mounted read-only.
function lepton_managed_mounts()
{
    [[ -z "$LEPTON_MANAGED_OBB" ]] || podman_mount_entry "$LEPTON_MANAGED_OBB" /lepton/managed-obb ro
}

# Launch rc lines run once the managed install finished (app_baked=1).
function lepton_managed_launch_rc()
{
    println "    exec -- /system/bin/cmd lepton mount_vulkan_layers"
}

# Container Storage, as a shared-folder entry, while the library is available.
function lepton_library_storage_entry()
{
    [[ -n "${LEPTON_LIBRARY_ROOT:-}" ]] || return 0
    printf '%s\t%s\t%s\trw\tok\tlibrary\n' "Container Storage" "${LEPTON_LIBRARY_ROOT}/Container Storage" \
        "${LEPTON_SHARED_GUEST_ROOT}/Container Storage"
}

# Will this launch install or replace the app's code? An install is followed
# by NDK preparation, so the previous translator choice does not apply.
function lepton_managed_install_pending()
{
    lepton_library_helper pending "$LEPTON_LIBRARY_ROOT" "$(get_app_id)" "$(get_baked_app_data_dir)"
}

# Install or update the app with Android's package manager, then prepare its
# installed ARM64 libraries for NDK translation.
function lepton_managed_install()
{
    local -a OPTIONS=() RESULT=()
    local OUT ERR STATUS=0 REASON
    [[ -z "$LEPTON_MANAGED_OBB" ]] || OPTIONS+=(--obb)
    OUT="$(mktemp)" && ERR="$(mktemp)" || return 1
    lepton_library_helper install "${OPTIONS[@]}" "$LEPTON_LIBRARY_ROOT" "$(get_app_id)" \
        "$(get_baked_app_data_dir)" "$LEPTON_CONTEXT" > "$OUT" 2> "$ERR" || STATUS=$?
    cat -- "$ERR" >&2
    mapfile -t RESULT < "$OUT"
    REASON="$(sed -n 's/^Android Library: //p' "$ERR" | tail -n 1)"
    rm -f -- "$OUT" "$ERR"
    if ((STATUS != 0 || ${#RESULT[@]} != 2)); then
        println "ERROR: Android Library installation failed; profile preserved. See leptron info $(get_app_id)." >&2
        lepton_tell_player "$(get_app_id) can't start: ${REASON:-its installation failed}" \
            "Nothing has been deleted. Run leptron info $(get_app_id) for details."
        return 1
    fi
    ndk_prepare_managed_app "${RESULT[0]}" "${RESULT[1]}"
}
