#!/bin/bash

if [[ "${LIBLEPTON_STRICT:-true}" == "true" ]]; then
    set -euo pipefail
fi
LEPTON_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Global storage locations
LEPTON_ENTRYPOINT="${LEPTON_DIR}/../lepton"
LEPTON_DATA_DIR="${HOME}/.local/share/lepton/contexts"

STEAM_PATH="${HOME}/.local/share/Steam"
STEAMAPPS_PATH="${STEAM_PATH}/steamapps"

APK_AUTO_INSTALL_DIR="${HOME}/lepton_auto_install_apks"

ADB="${LEPTON_ADB:-/usr/lib/android-sdk/platform-tools/adb}"

MDNS_PUBLISH_PATH="${LEPTON_DIR}/mdns_publisher/bin/lepton-mdns-publish"

# Include our libraries of functionality
source "${LEPTON_DIR}/utils.sh"
source "${LEPTON_DIR}/networking.sh"
source "${LEPTON_DIR}/mounting.sh"
source "${LEPTON_DIR}/app_metadata.sh"
source "${LEPTON_DIR}/google_games.sh"
source "${LEPTON_DIR}/properties.sh"
source "${LEPTON_DIR}/baking.sh"
source "${LEPTON_DIR}/vulkan_layers.sh"
source "${LEPTON_DIR}/perfetto.sh"
source "${LEPTON_DIR}/performance_debugging.sh"
source "${LEPTON_DIR}/gdb.sh"
source "${LEPTON_DIR}/strace.sh"
source "${LEPTON_DIR}/debug.sh"

function steamos_devmode_enabled()
{
    [[ -e "/etc/steamos-devkit-enabled" ]]
}

function create_prefix()
{
    if [[ -z "${LEPTON_PREFIX:-}" ]]; then
        export LEPTON_PREFIX=$(mktemp -d -t lepton-context.XXXXXXXXXX)
    fi
}

# Ordinary cleanup never owns the Android overlays. Deletion is reset-only.
function prepare_baked_data_for_removal()
{
    remove_baked_workdirs "$@"
}

function profile_has_no_mounts()
{
    local MOUNTS
    MOUNTS="$(findmnt -rn -o TARGET,OPTIONS)" || {
        println "WARNING: cannot inspect mounts; cleanup refused" >&2
        return 1
    }
    [[ "$MOUNTS" != *"$1"* ]]
}

function clear_baked_app_data()
{
    local REASON="$1" DIR BASE
    shift
    [[ "${LEPTON_RESET_APP_DATA:-false}" == true ]] || {
        println "ERROR: refusing profile deletion without LEPTON_RESET_APP_DATA=true" >&2
        return 1
    }
    [[ $# == 0 && -n "${STEAM_COMPAT_DATA_PATH:-}" ]] || return 1
    BASE="$(realpath -e -- "${STEAM_COMPAT_DATA_PATH}")" || return 1
    DIR="$(get_baked_app_data_dir)"
    [[ "$BASE" != / && "$BASE" != "$HOME" && "$DIR" == "${STEAM_COMPAT_DATA_PATH}/baked" && ! -L "$DIR" ]] || return 1
    [[ "$(realpath -m -- "$DIR")" == "$BASE/baked" ]] || return 1
    # Fail closed if Podman cannot establish that this profile is inactive.
    local STATE
    STATE="$(podman container inspect -f '{{.State.Running}}' "lepton-${LEPTON_CONTEXT}" 2>/dev/null)" || {
        local EXISTS_STATUS=0
        podman container exists "lepton-${LEPTON_CONTEXT}" || EXISTS_STATUS=$?
        [[ $EXISTS_STATUS == 1 ]] || return 1
        STATE=false
    }
    [[ "$STATE" == false ]] || { println "ERROR: stop the game before resetting" >&2; return 1; }
    podman rm "lepton-${LEPTON_CONTEXT}" >/dev/null 2>&1 || true
    local REMAINING_STATUS=0
    podman container exists "lepton-${LEPTON_CONTEXT}" || REMAINING_STATUS=$?
    [[ $REMAINING_STATUS == 1 ]] || {
        println "ERROR: container removal unverified; reset refused" >&2
        return 1
    }
    if ! profile_has_no_mounts "$BASE"; then
        println "ERROR: profile still mounted; reset refused" >&2
        return 1
    fi
    println "Explicit reset: ${REASON}; Android baked profile only: $DIR; external and internal retained"
    podman unshare rm -rf --one-file-system -- "$DIR" || {
        println "ERROR: partial reset at $DIR; preserved remaining files; do not launch" >&2
        return 1
    }
    [[ ! -e "$DIR" && ! -L "$DIR" ]] || return 1
}

function should_keep_app_data()
{
    # Legacy opt-out must never silently erase an existing profile.
    return 0
}

function remove_baked_workdirs()
{
    # A stopped container can still own mounted overlays. Retain workdirs until
    # its removal has succeeded; do not chmod any persistent data.
    local DIR BASE
    BASE="$(get_baked_app_data_dir "$@")"
    [[ ! -L "$BASE" ]] || return 0
    if podman container exists "lepton-${LEPTON_CONTEXT}"; then
        println "Retaining overlay workdirs: container still exists"
        return 0
    else
        [[ $? == 1 ]] || { println "WARNING: cannot verify overlay inactivity; workdirs retained" >&2; return 0; }
    fi
    for DIR in "$BASE/data_workdir" "$BASE/app_workdir"; do
        [[ -d "$DIR" && ! -L "$DIR" && "$(realpath -m -- "$DIR")" == "$(realpath -m -- "$BASE")/"* ]] || continue
        if ! profile_has_no_mounts "$BASE"; then
            println "WARNING: overlay still mounted; workdirs retained" >&2
            return 0
        fi
        podman unshare rm -rf --one-file-system -- "$DIR" || println "WARNING: could not remove scratch directory $DIR" >&2
    done
}

# Keep the legacy digest format so identical released images remain compatible.
function lepton_runtime_fingerprint()
{
    local ROOTFS="${LEPTON_TEST_ROOTFS:-${LEPTON_DIR}/../images/rootfs}" FILE
    for FILE in "$ROOTFS/system/build.prop" "$ROOTFS/vendor/build.prop" \
        "$ROOTFS/system/framework/services.jar" "$BAKED_SYSTEM_DATA_DIR/system/packages.xml"; do
        [[ -r "$FILE" ]] || { println "ERROR: fingerprint input unreadable: $FILE" >&2; return 1; }
    done
    cat "$ROOTFS/system/build.prop" "$ROOTFS/vendor/build.prop" \
        "$ROOTFS/system/framework/services.jar" "$BAKED_SYSTEM_DATA_DIR/system/packages.xml" | sha256sum | cut -d' ' -f1
}

function existing_app_profile()
{
    local DIR="$(get_baked_app_data_dir)" ENTRY
    [[ ! -L "$DIR" ]] || return 0
    [[ -d "$DIR" ]] || return 1
    [[ -r "$DIR" && -x "$DIR" ]] || return 0
    # Even incomplete/unknown state is valuable. Empty scratch directories are
    # harmless, but their contents are not grounds to assume a fresh profile.
    for ENTRY in "$DIR"/* "$DIR"/.[!.]* "$DIR"/..?*; do
        [[ -e "$ENTRY" || -L "$ENTRY" ]] || continue
        [[ "$ENTRY" == "$DIR/lepton-runtime-fingerprint" ]] || return 0
    done
    return 1
}

# Prints the display name of an installed Lepton tool whose Android runtime
# has fingerprint $1 (the tool that created a refused profile), if any.
function lepton_tool_for_fingerprint()
{
    local WANT="$1" ROOT SUM
    [[ "$WANT" =~ ^[0-9a-f]{64}$ ]] || return 1
    for ROOT in "${XDG_DATA_HOME:-$HOME/.local/share}"/*/; do
        [[ -f "${ROOT}BUNDLE.json" && -d "${ROOT}compat_tool/sysbake" ]] || continue
        SUM="$(LEPTON_TEST_ROOTFS="${ROOT}compat_tool/images/rootfs" \
               BAKED_SYSTEM_DATA_DIR="${ROOT}compat_tool/sysbake" \
               lepton_runtime_fingerprint 2>/dev/null)" || continue
        [[ "$SUM" == "$WANT" ]] || continue
        python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["display_name"])' \
            "${ROOT}BUNDLE.json" 2>/dev/null || basename -- "$ROOT"
        return 0
    done
    return 1
}

# A refused profile otherwise only shows in the log: the game seems to do
# nothing. Tell the player why and what they can do: the Gamescope bridge
# passes LEPTON_MESSAGE_FILE and shows its contents as a popup once Lepton
# exits (on Steam's display in Gaming Mode, as a window on the desktop).
# It only explains; nothing is deleted.
function lepton_profile_refused()
{
    local REASON="$1" STORED="${2:-}" GAME TOOL MESSAGE
    GAME="$(get_app_id)"
    local RESET="To use this tool instead, reset the game's data: add
LEPTON_RESET_APP_DATA=true %command%
to its launch options (Properties > General), launch it once, then remove
the option. This permanently deletes the game's Android data (saves, logins,
settings) and installs the game again. Shared storage is kept."
    case "$REASON" in
        fingerprint)
            if TOOL="$(lepton_tool_for_fingerprint "$STORED")"; then
                println "Profile was created by installed tool: $TOOL"
                MESSAGE="$GAME can't start with this Lepton tool. Nothing has been deleted.

Its Android data was created by another Lepton tool:
$TOOL

To keep your data, select that tool in the game's Properties > Compatibility.

$RESET"
            else
                println "Profile's runtime is not provided by any installed tool"
                MESSAGE="$GAME can't start with this Lepton tool. Nothing has been deleted.

Its Android data was created by a different Lepton Android build, which is not
installed. To keep your data, reinstall that Lepton version and select it in
the game's Properties > Compatibility.

$RESET"
            fi ;;
        installation)
            MESSAGE="$GAME can't start: its APK no longer matches the copy installed in its
Android data, for example because the game was updated. Lepton can't update an
installed game yet. Nothing has been deleted.

To keep your data, put back the original APK.

$RESET" ;;
        *)
            MESSAGE="$GAME can't start: its Lepton data folder is not in the expected form.
Nothing has been deleted. Details are in ~/.steam/steam/logs/." ;;
    esac
    if [[ -n "${LEPTON_MESSAGE_FILE:-}" && -f "$LEPTON_MESSAGE_FILE" && ! -L "$LEPTON_MESSAGE_FILE" ]]; then
        printf '%s\n' "$MESSAGE" > "$LEPTON_MESSAGE_FILE" || true
    fi
}

function check_kept_app_data()
{
    is_sysbake && return 0
    local DIR FINGERPRINT_FILE CURRENT STORED
    DIR="$(get_baked_app_data_dir)"
    FINGERPRINT_FILE="$DIR/lepton-runtime-fingerprint"
    APP_REUSE_VALIDATED=""
    if [[ -L "$DIR" || -L "$DIR/data_overlay" || -L "$DIR/app_overlay" ]]; then
        println "ERROR: unexpected profile symlink; profile preserved but not mounted: $DIR" >&2
        lepton_profile_refused layout
        return 1
    fi
    println "Profile: Steam AppID=${SteamAppId:-unknown}; package=$(get_app_id); tool=${LEPTON_ENTRYPOINT:-$LEPTON_DIR}; data=$DIR"
    [[ "${LEPTON_KEEP_APP_DATA:-true}" != false ]] || println "WARNING: LEPTON_KEEP_APP_DATA=false ignored; use an explicit per-game reset"
    if [[ "${LEPTON_RESET_APP_DATA:-false}" == true ]]; then
        clear_baked_app_data "LEPTON_RESET_APP_DATA=true" || return 1
    fi
    CURRENT="$(lepton_runtime_fingerprint)" || return 1
    if existing_app_profile; then
        println "Existing profile detected: yes"
        STORED="$(cat "$FINGERPRINT_FILE" 2>/dev/null || true)"
        if [[ -z "$STORED" || "$STORED" != "$CURRENT" ]]; then
            println "ERROR: previous fingerprint=${STORED:-unknown}; runtime fingerprint mismatch/unknown; profile preserved but not mounted: $DIR. Select the original Android runtime and sysbake; back up before diagnosing compatibility." >&2
            lepton_profile_refused fingerprint "$STORED"
            return 1
        fi
        println "Runtime fingerprint match; previous fingerprint known"
        if is_app && ! is_app_baked; then
            println "ERROR: installation validation failed; profile preserved but not mounted. Restore the original APK or diagnose the installed code/metadata after backup. Automatic repair is not yet validated for this overlay." >&2
            lepton_profile_refused installation
            return 1
        fi
        println "Existing profile validated for reuse"
        APP_REUSE_VALIDATED=yes
    else
        println "Existing profile detected: no; creating new profile; runtime fingerprint=$CURRENT"
        mkdir -p "$DIR"
        print "$CURRENT" > "$FINGERPRINT_FILE"
    fi
}

function remove_prefix()
{
    if [[ -n "${LEPTON_PREFIX:-}" ]]; then
        remove_baked_workdirs
        # Only delete launcher-created temporary directories, never an arbitrary
        # inherited path or a symlink (including a parent symlink).
        if [[ ! -L "$LEPTON_PREFIX" && "$(realpath -m -- "$LEPTON_PREFIX")" == "$LEPTON_PREFIX" && "$LEPTON_PREFIX" =~ ^/tmp/lepton-context\.[A-Za-z0-9]+$ ]]; then
            rm -rf --one-file-system -- "$LEPTON_PREFIX" || println "WARNING: temporary prefix cleanup failed" >&2
        else
            println "WARNING: retaining unrecognised prefix: $LEPTON_PREFIX" >&2
        fi
    fi
}

function prefix()
{
    if [[ -z "${LEPTON_PREFIX:-}" ]]; then
        export LEPTON_PREFIX="$(podman inspect -f '{{ index .Config.Labels "PREFIX" }}' "lepton-${1:-${LEPTON_CONTEXT}}" 2>/dev/null || true)"
    fi

    if [[ -z "${LEPTON_PREFIX:-}" ]]; then
        die "${1:-${LEPTON_CONTEXT}}: no prefix!"
    fi

    print "${LEPTON_PREFIX}"
}

function data_mount_path()
{
    print "$(get_baked_app_data_dir $@)/data_overlay"
}

# The workdir must be in the same filesystem as the upperdir
function data_workdir()
{
    print "$(get_baked_app_data_dir $@)/data_workdir"
}

function app_workdir()
{
    print "$(get_baked_app_data_dir $@)/app_workdir"
}

function app_datadir()
{
    print "$(get_baked_app_data_dir $@)/app_overlay"
}

function setup_container()
{
    check_host_gpu
    if google_signin_mode && ! rootfs_has_google_services; then
        die "Google sign-in needs a Lepton tool with Google services (a GApps bundle)."
    fi
    check_kept_app_data || die "Profile safety check failed; existing data preserved"
    cleanup_container

    # Mount in vulkan layers, if requested by certain environment variables
    enable_vulkan_layers

    setup_mounts

    export WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}"
    export PULSE_RUNTIME_PATH="$XDG_RUNTIME_DIR/pulse"

    # Workaround for users who are stuck on older OS versions; drop this
    # once everyone is post https://swarm.valve.org/changes/9821351
    # Once that is true, also drop explicit `PULSE_RUNTIME_PATH` and just
    # assume it'll always be relative to `XDG_RUNTIME_DIR`.  This will require
    # a change to `mounting.sh` as well.
    if [[ ! -e "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ]]; then
        if [[ -e "/home/$(id -u -n)/xdg/${WAYLAND_DISPLAY}" ]]; then
            export XDG_RUNTIME_DIR="/home/$(id -u -n)/xdg"
        fi
    fi
    if [[ ! -e "${PULSE_RUNTIME_PATH}" ]]; then
        if [[ -e "/run/user/$(id -u)/pulse" ]]; then
            export PULSE_RUNTIME_PATH="/run/user/$(id -u)/pulse"
        fi
    fi

    setup_podman_base
    setup_podman_mounts
    setup_podman_network
    setup_props
}

function onexit_path()
{
    print "$(data_mount_path)/lepton-on-app-exit"
}

function start_container()
{
    local CONTEXT="${1:-${LEPTON_CONTEXT}}"
    println "Launching lepton-${CONTEXT}"

    rm -f "$(onexit_path)"

    ROOTFS="$(readlink -f "${LEPTON_DIR}"/../images/rootfs)"
    # --init=false is used to make sure our container init runs as PID=1,
    # and to avoid spawning multiple "init" processes.
    # --read-only and --rootfs with the :O option make sure that we don't
    # accidentally modify the rootfs storage itself.
    USERNS_ARGS=(--userns=keep-id:uid=0,gid=0 --user 0:0 --group-add keep-groups)
    LOG_LEVEL_ARGS=()
    if [[ "${LEPTON_DEBUG:-false}" != "false" ]]; then
        LOG_LEVEL_ARGS=(--log-level=debug)
    fi

    (
        uninherit_lepton_lock

        exec stdbuf -o0 podman events \
            --filter container="lepton-${CONTEXT}" \
            --filter event=create | head -n0 >/dev/null 2>/dev/null || true
    ) &
    WAIT_CONTAINER_CREATION_PID="$!"

    # We need to remove the container now, before starting the new one
    # otherwise our podman commands running simultaneously would get
    # the wrong state
    podman rm -fi "lepton-${CONTEXT}" 2>/dev/null || true

    (
        uninherit_lepton_lock

        podman run \
            "${LOG_LEVEL_ARGS[@]}" \
            --replace \
            --read-only \
            --env-host=false \
            --init=false \
            --name "lepton-${CONTEXT}" \
            "${USERNS_ARGS[@]}" \
            "${PODMAN_CMDLINE[@]}" \
            --label lepton=true \
            --label lepton_pid="$$" \
            --label gdb_port=$(gdb_port) \
            --label lldb_port=$(lldb_port) \
            --label adb_port=$(adb_port) \
            --label STEAM_COMPAT_DATA_PATH="${STEAM_COMPAT_DATA_PATH:-}" \
            --label PREFIX="${LEPTON_PREFIX:-}" \
            --label IP="$(podman_ip)" \
            --rootfs "${ROOTFS}":O \
                /init
    ) &

    # Fallback for when the above podman events was executed after podman run.
    (
        uninherit_lepton_lock

        while ! podman container exists "lepton-${CONTEXT}"; do
            sleep 0.1
        done

        kill "${WAIT_CONTAINER_CREATION_PID}" 2>/dev/null >/dev/null || true
    ) &

    wait "${WAIT_CONTAINER_CREATION_PID}" 2>/dev/null >/dev/null || true

    # When the container has been created, we can safely unlock, since the
    # labels will be inspectable.
    unlock_lepton

    ONBOOT_PATH="/data/lepton-onboot"

    # This waits for our `lepton_onboot.rc` to trigger, then deletes the file
    println "Waiting for boot..."
    (
        uninherit_lepton_lock

        wait_for_container_file "${ONBOOT_PATH}"
    ) &
    WAIT_FILE_PID="$!"

    (
        while [[ -z "$(podman_attach pidof logd)" ]]; do
            sleep 1
        done
        # Check if CryptKeeper failed to start (bug!)
        logcat_container "${CONTEXT}" | grep --line-buffered "Killing.*CryptKeeper.*start timeout" |
            while IFS= read -r line; do
                podman_attach am start -n com.android.settings/.CryptKeeper
            done
    ) &
    START_WORKAROUND_PID="$!"

    (
        while [[ -z "$(podman_attach pidof logd)" ]]; do
            sleep 1
        done
        # Check if a service failed to start (bug!)
        logcat_container "${CONTEXT}" | grep --line-buffered "Forcing bringing down service" |
            while IFS= read -r line; do
                FAILED_SERVICE="$(printf '%s\n' "$line" |
                    grep -o 'ServiceRecord{[^}]*}' |
                    awk '{print $3}' |
                    sed 's/}//')"

                [[ -n "$FAILED_SERVICE" ]] &&
                    podman_attach am start -n "${FAILED_SERVICE}"
            done
    ) &
    START_WORKAROUND2_PID="$!"

    # If the container exits before the file lepton-onboot has been created
    # it may have been stopped before it finished booting and we need to
    # handle that
    (
        uninherit_lepton_lock

        podman wait "lepton-${CONTEXT}" 2>/dev/null >/dev/null || true
        pkill -P "${WAIT_FILE_PID}" 2>/dev/null || true
    ) &
    WAIT_PID="$!"

    wait "${WAIT_FILE_PID}" 2>/dev/null >/dev/null
    kill "${WAIT_PID}" 2>/dev/null || true
    kill "${START_WORKAROUND_PID}" 2>/dev/null || true
    kill "${START_WORKAROUND2_PID}" 2>/dev/null || true

    rm -f "$(data_mount_path)/${ONBOOT_PATH#/data/}"
    println "Boot complete!"

    (
        # Wait 10s for app to start up, so that we can filter to only our PID's messages, if possible.
        local T_START=$(date "+%s")
        while [[ -z "$(guess_app_pid)" ]] && (( $(date "+%s") < ${T_START} + 10)); do
            sleep 0.1
        done
        logcat_container | tee -a "$(lepton_log_file)"
    ) &

    if ! is_sysbake; then
        (
            uninherit_lepton_lock

            if ! "${MDNS_PUBLISH_PATH}" "lepton-${CONTEXT}" _adb._tcp "$(adb_port)" device=Lepton model=Valve version=\"$(android_sdk_version)\" >/dev/null 2>/dev/null; then
                if command -v avahi-publish-service > /dev/null; then
                    echo "WARNING: Activating mdns via avahi-publish-service fallback."
                    exec "avahi-publish-service" "lepton-${CONTEXT}" _adb._tcp "$(adb_port)" device=Lepton model=Valve version="$(android_sdk_version)" >/dev/null 2>/dev/null
                else
                    echo "WARNING: Could not publish mdns service, with either systemd-resolved or avahi-publish-service"
                fi
            fi
        ) &
    fi
}

function wait_for_container()
{
    local CONTEXT="${1:-${LEPTON_CONTEXT}}"
    local WAIT_FILE_PID=""

    unlock_lepton

    # x86_64 port: during Google sign-in the Play Store (and Play services,
    # which update themselves) restart several times; only Done (SIGTERM) or the
    # container stopping ends the session, not the observed app exiting.
    if is_app && ! google_signin_mode; then
        println "Waiting for app $(get_app_id) to exit..."

        (
            uninherit_lepton_lock

            wait_for_file "$(onexit_path)"
        ) &

        WAIT_FILE_PID="$!"
    else
        # (The Google game window also waits for this line in sign-in mode.)
        println "Waiting for ${CONTEXT} to exit..."
    fi

    # NOTE: We intentionally do this `background-then-wait` pattern to ensure that SIGINT still works.
    (
        uninherit_lepton_lock

        podman wait "lepton-${CONTEXT}" 2>/dev/null >/dev/null || true
        touch "$(onexit_path)"
    ) &
    WAIT_PID="$!"

    if [[ -n "${WAIT_FILE_PID}" ]]; then
        wait "${WAIT_FILE_PID}" 2>/dev/null >/dev/null

        pkill -P "${WAIT_PID}" 2>/dev/null || true
    else
        wait "${WAIT_PID}" 2>/dev/null >/dev/null
    fi

    # After the container has stopped, grab the lock
    lock_lepton

    println "Exited!"
}

function start_early_debug_container()
{
    local ROOTFS="$(readlink -f "${LEPTON_DIR}"/../images/rootfs)"
    # Manually symlink com.android.runtime so that `sh` can startup
    ln -vs "../system/apex/com.android.runtime" "${ROOTFS}/apex/com.android.runtime"
    trap "rm -f ${ROOTFS}/apex/com.android.runtime 2>/dev/null" INT TERM ERR EXIT

    unlock_lepton
    podman run \
        --replace \
        --env-host=false \
        --init=false \
        --name "lepton-${LEPTON_CONTEXT}" \
        --userns=keep-id:uid=0,gid=0 \
        --user 0:0 \
        --group-add keep-groups \
        --label lepton=true \
        --label lepton_pid="$$" \
        --label PREFIX="${LEPTON_PREFIX:-}" \
        "${PODMAN_CMDLINE[@]}" \
        -it \
        --rootfs "${ROOTFS}"\
            /system/bin/sh
}

function podman_attach_no_context_check()
{
    ANDROID_PATH=(
        /product/bin
        /apex/com.android.runtime/bin
        /apex/com.android.art/bin
        /system_ext/bin
        /system/bin
        /system/xbin
        /odm/bin
        /vendor/bin
        /vendor/xbin
    )

    # --no-term prevents extra \r to be appended to the output
    if [[ "$1" == "--no-term" ]]; then
        TERM_ARGS="-i"
        shift
    else
        TERM_ARGS="-it"
    fi

    function join_by { local IFS="$1"; shift; println "$*"; }
    env -i PATH="$(join_by ":" "${ANDROID_PATH[@]}")" $(which podman) exec "${TERM_ARGS}" "lepton-${LEPTON_CONTEXT}" "$@"
}

function podman_attach()
{
    if ! is_context_live "${LEPTON_CONTEXT}"; then
        println "ERROR: '${LEPTON_CONTEXT}' is not a running context, use 'lepton ps' to list them, like this:" >&2
        println >&2
        list_containers >&2
        exit 1
    fi
    podman_attach_no_context_check "$@"
}

function guess_app_pid()
{
    local PID="$(podman_attach --no-term sh -c "getprop ro.lepton.application_pid" 2>/dev/null)"
    if [[ -n "${PID}" ]]; then
         echo -n "${PID}"
         return
    fi
    local APP_ID="$(podman_attach --no-term sh -c "getprop lepton.active_app_id" 2>/dev/null)"
    if [[ -n "${APP_ID}" ]]; then
         local PID=$(podman_attach --no-term sh -c "pgrep -f ${APP_ID}" | head -1 | awk '{ print $1 }')
         echo -n "${PID}"
    fi
}

function attach_container()
{
    println "Attaching to lepton-${LEPTON_CONTEXT}"
    # During long running commands, we cannot hold the lock
    unlock_lepton
    podman_attach sh
}

function run_in_container()
{
    # Even if this is not a long running command, unlock, as the user might run
    # sh or logcat through the run/exec command.
    unlock_lepton
    podman_attach --no-term "$@"
}

function auto_install_apps()
{
    # Only auto-install apps if this is a dev context
    if is_app; then
        return;
    fi

    shopt -s globstar
    local APK_PATHS=( $(compgen -G "${APK_AUTO_INSTALL_DIR}/**/*.apk") )
    shopt -u globstar

    for APK_PATH in "${APK_PATHS[@]}"; do
        if ! test -r "${APK_PATH}"; then
            println "ERROR: ${APK_PATH} is not readable!  Skipping..." >&2
        else
            println "Installing $(lepton_basename "${APK_PATH}")"
            install_app "${APK_PATH}"
        fi
    done
}

# x86_64 port: true if PATH is inside a host directory that setup_mounts
# bind-mounts at the same path (STEAM_COMPAT_CLIENT_INSTALL_PATH and
# STEAM_COMPAT_LIBRARY_PATHS), i.e. Android can read it directly.
function apk_path_in_container()
{
    local path root roots=()
    # install_app passes the resolved APK path; Android must see exactly it.
    path="$(realpath -s -m -- "$1")"
    [[ -z "${STEAM_COMPAT_CLIENT_INSTALL_PATH:-}" ]] || roots+=("${STEAM_COMPAT_CLIENT_INSTALL_PATH}")
    local library_paths=()
    IFS=: read -ra library_paths <<< "${STEAM_COMPAT_LIBRARY_PATHS:-}"
    roots+=("${library_paths[@]}")
    for root in "${roots[@]}"; do
        [[ -n "${root}" ]] || continue
        # Mount targets keep the path as given, so do not resolve symlinks here.
        root="$(realpath -s -m -- "${root}")"
        [[ "${path}" == "${root}/"* ]] && return 0
    done
    return 1
}

function install_app()
{
    local APK_PATH="${1:-$(get_apk_path)}"
    APK_PATH="$(realpath "${APK_PATH}")"
    local APP_ID_FILE="$(dirname "${APK_PATH}")/steam_appid.txt"
    local UE_COMMANDLINE_FILE="$(dirname "${APK_PATH}")/UECommandLine.txt"
    local OBB_DIR="$(dirname "${APK_PATH}")/obb"
    local OBB_DIR_IS_APK_DIR=false

    if [[ ! -d "${OBB_DIR}" ]]; then
        OBB_DIR="$(dirname "${APK_PATH}")"
        OBB_DIR_IS_APK_DIR=true
    fi

    println "Installing ${APK_PATH}..."

    podman_attach sh -c "setprop lepton.active_app_id $(extract_app_id "${APK_PATH}")" 2>/dev/null

    # Standalone development installation: use Podman directly instead of
    # relying on the host-to-container ADB connection.
    # x86_64 port: split bundles always use the adb route below.
    if [[ -z "${LEPTON_APKM_DIR:-}" ]] && [[ "${LEPTON_CONTEXT}" == "dev" || "${LEPTON_CONTEXT}" == *.apk || "${LEPTON_CONTEXT}" == "steamlaunch-0" ]]; then
        local CONTAINER_APK="/data/local/tmp/$(basename "${APK_PATH}")"
        # Android's early boot marker can precede package-manager readiness.
        # Do not wait for sys.boot_completed: Lepton releases startup after installation.
        local READY_DEADLINE=$((SECONDS + 60))
        println "Waiting for Android package manager and Settings provider..."
        until podman exec "lepton-${LEPTON_CONTEXT}" /system/bin/sh -c \
            'pm path android >/dev/null 2>&1 && settings get global airplane_mode_on >/dev/null 2>&1'; do
            if (( SECONDS >= READY_DEADLINE )); then
                println "ERROR: Android package services not ready within 60 seconds"
                return 1
            fi
            sleep 1
        done

        podman cp "${APK_PATH}" "lepton-${LEPTON_CONTEXT}:${CONTAINER_APK}"
        podman_attach --no-term pm install -r -g "${CONTAINER_APK}"
        return $?
    fi

    (
        uninherit_lepton_lock

        ret=0

        # Deliberately using a different port as to not mess with the users
        # adb server.
        local ADB_PORT="$(adb_port)"
        local TEMP_PORT=$((ADB_PORT + 10000))
        # Installing copies the .apk several times and can take minutes on slow
        # storage. Give up if it takes far longer than that instead of hanging.
        local INSTALL_TIMEOUT="${LEPTON_APP_INSTALL_TIMEOUT:-600}"
        # Kill first to remove old connections
        "$ADB" -P "${TEMP_PORT}" kill-server 2>/dev/null
        "$ADB" -P "${TEMP_PORT}" connect localhost:"${ADB_PORT}" >/dev/null 2>/dev/null
        if ! timeout "${INSTALL_TIMEOUT}" "$ADB" -P "${TEMP_PORT}" -s "localhost:${ADB_PORT}" wait-for-device; then
            println "Device did not become available, installation will likely fail!"
        fi
        if ! is_steamlaunch; then
            if [[ -f "${APP_ID_FILE}" ]]; then
                "$ADB" -P "${TEMP_PORT}" -s localhost:"${ADB_PORT}" push "${APP_ID_FILE}" /data/steam_app
            fi
            if [[ -f "${UE_COMMANDLINE_FILE}" ]]; then
                "$ADB" -P "${TEMP_PORT}" -s localhost:"${ADB_PORT}" push "${UE_COMMANDLINE_FILE}" /data/steam_app
            fi
            if [[ -z "${LEPTON_MOUNT_OBB_DIR:-}" ]]; then
                if [[ -n "${OBB_DIR_IS_APK_DIR}" ]]; then
                    "$ADB" -P "${TEMP_PORT}" -s localhost:"${ADB_PORT}" push "${OBB_DIR}/"*.obb /data/steam_app 2>/dev/null || true
                else
                    "$ADB" -P "${TEMP_PORT}" -s localhost:"${ADB_PORT}" shell mkdir /data/steam_app/obb
                    "$ADB" -P "${TEMP_PORT}" -s localhost:"${ADB_PORT}" push "${OBB_DIR}/"*.obb /data/steam_app/obb 2>/dev/null || true
                fi
            fi
        fi
        local INSTALL_RET=0
        # x86_64 port: the shortcut only works when the APK lies in a folder
        # mounted into the container (Steam client or library paths). Non-Steam
        # shortcuts usually point at ~/Downloads etc., so stream those via adb.
        local SPLITS=()
        mapfile -t SPLITS < <(apkm_split_paths)
        if ((${#SPLITS[@]})); then
            # x86_64 port: split-APK bundle (.apkm): install base and splits
            # together; the post-install hook keeps every installed file.
            timeout "${INSTALL_TIMEOUT}" "$ADB" -P "${TEMP_PORT}" -s localhost:"${ADB_PORT}" install-multiple -g "${APK_PATH}" "${SPLITS[@]}" || INSTALL_RET=$?
        elif is_steamlaunch && apk_path_in_container "${APK_PATH}"; then
            # If it's a steamlaunch we can use a shortcut:
            # Since we mount the apk folder into the container,
            # there is no streaming via adb needed.
            timeout "${INSTALL_TIMEOUT}" "$ADB" -P "${TEMP_PORT}" -s localhost:"${ADB_PORT}" shell pm install -g "\"${APK_PATH}\"" || INSTALL_RET=$?
        else
            timeout "${INSTALL_TIMEOUT}" "$ADB" -P "${TEMP_PORT}" -s localhost:"${ADB_PORT}" install -g "${APK_PATH}" || INSTALL_RET=$?
        fi
        if [[ "${INSTALL_RET}" != "0" ]]; then
            if [[ "${INSTALL_RET}" == "124" ]]; then
                println "App installation timed out after ${INSTALL_TIMEOUT} seconds!"
            fi
            println "App installation failed!"
            # We dump logcat if the container exits in less than <30s but just to
            # be safe (in case the startup took longer for some reason), we set
            # LEPTON_DUMP_LOGCAT here, to make sure the logcat is dumped in this
            # error situation.
            export LEPTON_DUMP_LOGCAT=1
            kill_container "${LEPTON_CONTEXT}"

            # Installation failure never authorises deleting the profile.
            println "Installation failed; existing profile preserved; no data reset performed"
            ret=1
        fi
        # Can't leave processes around, otherwise we'd break closing the app.
        "$ADB" -P "${TEMP_PORT}" kill-server 2>/dev/null

        return $ret
    )

    return $?
}

function logcat_container()
{
    local filtered=()

    FULL_LOGCAT=false
    for arg in "$@"; do
        if [[ "$arg" != "--full" ]]; then
            filtered+=("$arg")
        else
            FULL_LOGCAT=true
        fi
    done

    APP_PID="$(guess_app_pid)"

    unlock_lepton
    if [[ "${FULL_LOGCAT}" == "true" ]] || [[ -z "${APP_PID}" ]]; then
        podman_attach logcat -v threadtime,color "${filtered[@]}"
    else
        podman_attach logcat -v threadtime,color --pid="${APP_PID}" "${filtered[@]}"
    fi
}


function parent_pid()
{
    awk '/PPid:/ {print $2}' "/proc/${1}/status" 2>/dev/null
}

function is_ancestor_of()
{
    local PARENT="$1"
    local CHILD="$2"

    if [[ -z "${PARENT}" ]] || [[ ! -d "/proc/${PARENT}" ]] || [[ -z "${CHILD}" ]] || [[ ! -d "/proc/${CHILD}" ]]; then
        return 1
    fi

    while [[ -n "${CHILD}" ]] && [[ "${CHILD}" -gt 1 ]]; do
        if [[ "${CHILD}" == "${PARENT}" ]]; then
            return 0
        fi
        CHILD="$(parent_pid "${CHILD}" || true)"
    done
    return 1
}


function container_running()
{
    [[ "$(podman container inspect -f '{{.State.Running}}' "lepton-${1}" 2>/dev/null || true)" == "true" ]]
}

# x86_64 port: CHANGE TO VALVE'S STOP SEQUENCE (check when merging Valve's
# kill_container). Valve runs `reboot -p` and then `podman stop -t 0` straight
# away. `reboot -p` returns at once, leaving little opportunity for games
# that save on backgrounding to finish. Send HOME first, allow Android to
# shut down, then use Valve's instant-stop fallback. Each game controls its
# save triggers: 2048 needs an in-game save (Exit or going back through moves)
# to commit new progress; HOME does not guarantee that it writes a save.
#   LEPTON_STOP_SAVE_WAIT=<s>      wait after HOME (default 3; 0 skips HOME)
#   LEPTON_STOP_SHUTDOWN_WAIT=<s>  wait for Android to power off (default 5)
# Both 0 gives Valve's behaviour. sysbake keeps Valve's behaviour unchanged.
function graceful_stop_container()
{
    local CONTEXT="$1"
    local SAVE_WAIT="${LEPTON_STOP_SAVE_WAIT:-3}"
    local SHUTDOWN_WAIT="${LEPTON_STOP_SHUTDOWN_WAIT:-5}"
    [[ "${SAVE_WAIT}" =~ ^[0-9]+$ ]] || SAVE_WAIT=3
    [[ "${SHUTDOWN_WAIT}" =~ ^[0-9]+$ ]] || SHUTDOWN_WAIT=5

    if [[ "${CONTEXT}" == sysbake ]]; then
        return 0
    elif ! container_running "${CONTEXT}"; then
        println "Stopping ${CONTEXT}: container already stopped"
        return 0
    fi

    if (( SAVE_WAIT > 0 )); then
        println "Stopping ${CONTEXT}: sending HOME so the game can save (${SAVE_WAIT}s)..."
        timeout 5 podman exec "lepton-${CONTEXT}" /system/bin/input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
        sleep "${SAVE_WAIT}"
    fi

    STOP_OUTPUT+="$(timeout 5 podman exec -i "lepton-${CONTEXT}" /system/bin/reboot -p 2>&1 || true)"
    local end=$((SECONDS + SHUTDOWN_WAIT))
    while (( SECONDS < end )) && container_running "${CONTEXT}"; do
        sleep 0.5
    done
    if container_running "${CONTEXT}"; then
        println "Stopping ${CONTEXT}: Android did not power off within ${SHUTDOWN_WAIT}s, forcing stop"
    else
        println "Stopping ${CONTEXT}: Android powered off cleanly"
    fi
}

function kill_container()
{
    local CONTEXT="${1:-${LEPTON_CONTEXT}}"

    local LEPTON_PID=$(podman inspect -f '{{ index .Config.Labels "lepton_pid" }}' "lepton-${CONTEXT}" 2>/dev/null || true)

    STOP_OUTPUT=""
    graceful_stop_container "${CONTEXT}"
    STOP_OUTPUT+="$(podman exec -i "lepton-${CONTEXT}" /system/bin/reboot -p 2>&1 || true)"
    STOP_OUTPUT+="$(podman stop -t 0 "lepton-${CONTEXT}" 2>&1 || true)"

    # Can't wait for ourselves:
    if ! is_ancestor_of "${LEPTON_PID}" "$$"; then
        unlock_lepton

        end=$((SECONDS + 15))
        while [[ $SECONDS -lt $end ]] && kill -0 "${LEPTON_PID}" 2>/dev/null; do
            println "Waiting for ""${CONTEXT}"" (PID '${LEPTON_PID}') to exit..."
            sleep 1
        done

        lock_lepton
    fi

    systemctl --user stop "lepton-${CONTEXT}.slice" 2>/dev/null || true
}

function kill_all()
{
    for CONTEXT in $(list_live_contexts); do
        kill_container "${CONTEXT}"
    done
}

function dump_logcat()
{
    if ! container_running "${LEPTON_CONTEXT}"; then
        println "Logcat unavailable: ${LEPTON_CONTEXT} is no longer running"
        return 0
    fi
    local OUTPUT_DIR="$1" BUFFER_NAME PID
    local -a LOGCAT_PIDS=()
    mkdir -p "$OUTPUT_DIR" || return 1
    # No TTY: Steam shutdown diagnostics run without an interactive terminal.
    # All five captures run concurrently, bounded to 2s plus a 1s kill grace.
    for BUFFER_NAME in main system kernel crash radio; do
        (
            if ! timeout --kill-after=1 2 podman exec -i "lepton-${LEPTON_CONTEXT}" \
                /system/bin/logcat -b "$BUFFER_NAME" -d \
                > "$OUTPUT_DIR/logcat-${BUFFER_NAME}.log" \
                2> "$OUTPUT_DIR/logcat-${BUFFER_NAME}.stderr"; then
                println "WARNING: logcat $BUFFER_NAME capture incomplete (timeout or container stopped); partial log retained"
            fi
        ) &
        LOGCAT_PIDS+=( "$!" )
    done
    for PID in "${LOGCAT_PIDS[@]}"; do
        wait "$PID" || true
    done
}

function list_android_games()
{
    STEAMAPPS_PATH="${HOME}/.local/share/Steam/steamapps"
    for GAME in ${STEAMAPPS_PATH}/appmanifest_*.acf; do
        INSTALLDIR="$(grep "\"installdir\"" "${GAME}" | cut -d'"' -f4)"
        if compgen -G "${STEAMAPPS_PATH}/common/${INSTALLDIR}/*.apk" >/dev/null; then
            println "\"$(grep "\"name\"" "${GAME}" | cut -d'"' -f4)\""
        fi
    done
}

function list_live_android_games()
{
    STEAMAPPS_PATH="${HOME}/.local/share/Steam/steamapps"
    for GAME in ${STEAMAPPS_PATH}/appmanifest_*.acf; do
        GAMENAME="$(grep "\"name\"" "${GAME}" | cut -d'"' -f4)"
        if [[ "${GAMENAME}" == "${1:-}"* ]]; then
            INSTALLDIR="$(grep "\"installdir\"" "${GAME}" | cut -d'"' -f4)"
            APPID="$(grep "\"appid\"" "${GAME}" | cut -d'"' -f4)"
            if is_context_live steamlaunch-"${APPID}" && compgen -G "${STEAMAPPS_PATH}/common/${INSTALLDIR}/*.apk" >/dev/null; then
                println "\"${GAMENAME}\""
            fi
        fi
    done
}

function list_contexts()
{
    podman ps -a \
        --filter label=lepton=true \
        --format "{{.Names}}" | sed "s/^lepton-//"
}

function list_live_contexts()
{
    podman ps -a \
      --filter label=lepton=true \
      --format "{{.Names}} {{.Status}}" | grep "Up" | awk '{print $1}' | sed "s/^lepton-//" || true
}

function is_context_live()
{
    local CONTEXT="${1:-${LEPTON_CONTEXT}}"

    list_live_contexts | grep -Fxq "${CONTEXT}" && return 0

    if ! is_steamlaunch "${CONTEXT}"; then
        for GAME in ${STEAMAPPS_PATH}/appmanifest_*.acf; do
            if [[ "$(grep "\"name\"" "${GAME}" | cut -d'"' -f4)" == "${CONTEXT}" ]]; then
                local STEAMLAUNCH_CONTEXT="steamlaunch-$(grep "\"appid\"" "${GAME}" | cut -d'"' -f4)"
                list_live_contexts | grep -Fxq "${STEAMLAUNCH_CONTEXT}"
                return $?
            fi
        done
    fi

    return 1
}

function list_containers()
{
    for CONTEXT in $(list_contexts); do
        if is_context_live "${CONTEXT}"; then
            IP=$(podman_ip "${CONTEXT}" || print "<?>")
            PACKAGES="$(LEPTON_CONTEXT="${CONTEXT}" podman_attach_no_context_check pm list packages -3 2>/dev/null |grep -o "package:.*" || true)"
            if [[ -n "${PACKAGES}" ]]; then
                APP_STR="packages: $(println "${PACKAGES}" | sed "s/package://g" | sed -z 's/\r/,/g' | sed "s/,$//g")"
            else
                APP_STR=""
            fi
            ADB_PORT="$(adb_port "${CONTEXT}")"
            GDB_PORT="$(gdb_port "${CONTEXT}")"
            LLDB_PORT="$(lldb_port "${CONTEXT}")"
            IP_STR="(${IP}, "
            if [[ -n "${ADB_PORT}" ]]; then
                IP_STR+="adb on ${ADB_PORT}, "
            fi
            if [[ -n "${GDB_PORT}" ]]; then
                IP_STR+="gdb on ${GDB_PORT}, "
            fi
            if [[ -n "${LLDB_PORT}" ]]; then
                IP_STR+="lldb on ${LLDB_PORT}, "
            fi
            IP_STR+="${APP_STR})"
            println "${_GREEN}${CONTEXT} ${IP_STR}${_PLAIN}"
        else
            println "${_RED}${CONTEXT}${_PLAIN}"
        fi
    done
}

function cleanup_container()
{
    local CONTEXT="${1:-${LEPTON_CONTEXT}}"

    local EXISTS_STATUS=0 REMOVE_OUTPUT
    podman container exists "lepton-${CONTEXT}" || EXISTS_STATUS=$?
    case "$EXISTS_STATUS" in
        0) ;;
        1) println "Container already absent: lepton-${CONTEXT}"; return 0 ;;
        *) println "WARNING: cannot inspect lepton-${CONTEXT}; container and profile retained" >&2; return 0 ;;
    esac
    kill_container "${CONTEXT}"

    # Removing the stopped container releases its overlay mounts. Android's
    # Settings provider state belongs to the profile and must remain intact.
    if REMOVE_OUTPUT="$(podman rm "lepton-${CONTEXT}" 2>&1)"; then
        println "Stopped container removed: lepton-${CONTEXT}; profile retained"
    else
        println "WARNING: stopped container retained: lepton-${CONTEXT}: ${REMOVE_OUTPUT}" >&2
    fi
}

function cleanup_all()
{
    println "Cleaning stopped containers; all Android profiles are retained"
    local CONTEXT
    for CONTEXT in $(list_contexts); do
        cleanup_container "$CONTEXT"
    done
    if [[ " $* " != *" --keep-logcats "* ]]; then
        logcat_debug_clear_all
    fi
}

function extract_file()
{
    local CONTEXT="${1}"
    local FILE_PATH="${2}"
    local DEST_DIR="${3}"

    local DATA_DIR="$(data_mount_path "${CONTEXT}")"

    if [[ "${FILE_PATH}" == "/data/"* ]] && [[ -e "${DATA_DIR}/${FILE_PATH#/data/}" ]]; then
        # File already in `/data`? Copy it out now
        cp -r "${DATA_DIR}/${FILE_PATH#/data/}" "${DEST_DIR}/"
    else
        # Otherwise, get it into `/data`, then copy it out
        podman_attach sh -c "mkdir -p /data/extracted; cp -r '${FILE_PATH}' /data/extracted/"
        cp -r "${DATA_DIR}/extracted/$(lepton_basename "${FILE_PATH}")" "${DEST_DIR}/"
    fi
}

function determine_app()
{
    IS_START=false
    if [[ "$1" == "--start" ]]; then
        IS_START=true
        shift
    fi

    local APP="${1}"

    # If STEAM_COMPAT_CLIENT_INSTALL_PATH is still unset, "guess" it now, to
    # make sure we mount libsteamclient.so if the guessed path is right.
    if [[ -z "${STEAM_COMPAT_CLIENT_INSTALL_PATH:-}" ]]; then
        export STEAM_COMPAT_CLIENT_INSTALL_PATH="${STEAM_PATH}"
    fi

    if ! is_sysbake && [[ "${LEPTON_CONTEXT}" != "dev" ]] && ! is_steamlaunch "${LEPTON_CONTEXT}" && [[ "${LEPTON_CONTEXT}" != *".apk" ]]; then
        # Might be the name of a game, let's see.
        # This might be slow when there's a ton of games, but it's kind of a debug option anyways.
        for GAME in ${STEAMAPPS_PATH}/appmanifest_*.acf; do
            if [[ "$(grep "\"name\"" "${GAME}" | cut -d'"' -f4)" == "${LEPTON_CONTEXT}" ]]; then
                export SteamAppId="$(grep "\"appid\"" "${GAME}" | cut -d'"' -f4)"
                export STEAM_COMPAT_INSTALL_PATH="${STEAMAPPS_PATH}/common/$(grep "\"installdir\"" "${GAME}" | cut -d'"' -f4)"
                export STEAM_COMPAT_DATA_PATH="${STEAMAPPS_PATH}/compatdata/${SteamAppId}"
                # We don't know what the library paths would be, so just make sure we mount everything
                export STEAM_COMPAT_LIBRARY_PATHS="${STEAMAPPS_PATH}"
                export STEAM_COMPAT_SHADER_PATH="${STEAMAPPS_PATH}/shadercache/${SteamAppId}"
                export STEAM_FOSSILIZE_DUMP_PATH="${STEAMAPPS_PATH}/shadercache/${SteamAppId}/fozpipelinesv6/steamapp_pipeline_cache"
                if [[ -n "${APP}" ]]; then
                    export APP_PATH="${STEAM_COMPAT_INSTALL_PATH}/${APP}"
                else
                    APK_FILES=("${STEAM_COMPAT_INSTALL_PATH}"/*.apk)
                    export APP_PATH="$(println "${APK_FILES[0]}")"
                fi
                LEPTON_CONTEXT="steamlaunch-${SteamAppId}"
                break
            fi
        done
    elif [[ "${LEPTON_CONTEXT}" == *".apk" ]]; then
        local APK_FULL_PATH="${LEPTON_CONTEXT}"
        export LEPTON_CONTEXT="$(basename "${APK_FULL_PATH}" | sed 's/[^a-zA-Z0-9_.-]/_/g')"

        if [[ "${IS_START}" == "true" ]]; then
            create_prefix
            local LEPTON_APK_TMPDIR="${LEPTON_PREFIX}/tmp"
            mkdir -p "${LEPTON_APK_TMPDIR}"
            cp "${APK_FULL_PATH}" "${LEPTON_APK_TMPDIR}/"
            cp "$(dirname "${APK_FULL_PATH}")"/steam_appid.txt "${LEPTON_APK_TMPDIR}/" 2>/dev/null || true
            cp "$(dirname "${APK_FULL_PATH}")"/UECommandLine.txt "${LEPTON_APK_TMPDIR}/" 2>/dev/null || true

            if [[ ! -d "$(dirname "${APK_FULL_PATH}")/obb" ]]; then
                echo "WARNING: lepton start foo.apk cannot mount obbs from the same directory as the apk due to overlayfs limitations."
                echo "If you need any obb files, put them into "$(dirname "${APK_FULL_PATH}")/obb", otherwise ignore this message."
            else
                export LEPTON_MOUNT_OBB_DIR="$(cd "$(dirname "${APK_FULL_PATH}")/obb" && pwd)"
            fi

            export APP_PATH="${LEPTON_APK_TMPDIR}/$(basename "${APK_FULL_PATH}")"
            export STEAM_COMPAT_DATA_PATH="${LEPTON_DATA_DIR}/${1:-${LEPTON_CONTEXT}}/compatdata/${LEPTON_CONTEXT}"
            export STEAM_COMPAT_LIBRARY_PATHS="${LEPTON_DATA_DIR}/${1:-${LEPTON_CONTEXT}}/compatdata/${LEPTON_CONTEXT}"
            export STEAM_COMPAT_SHADER_PATH="${LEPTON_DATA_DIR}/${1:-${LEPTON_CONTEXT}}/shadercache/${LEPTON_CONTEXT}"
            export STEAM_FOSSILIZE_DUMP_PATH="${LEPTON_DATA_DIR}/${1:-${LEPTON_CONTEXT}}/shadercache/${LEPTON_CONTEXT}/fozpipelinesv6/steamapp_pipeline_cache"
            mkdir -p "${STEAM_COMPAT_DATA_PATH}"
            mkdir -p "${STEAM_COMPAT_SHADER_PATH}"
        elif is_context_live; then
            export STEAM_COMPAT_DATA_PATH="$(podman inspect -f '{{ index .Config.Labels "STEAM_COMPAT_DATA_PATH" }}' "lepton-${LEPTON_CONTEXT}" 2>/dev/null || true)"
            export STEAM_COMPAT_SHADER_PATH="$(readlink -f "${STEAM_COMPAT_DATA_PATH:-}/../shadercache/${LEPTON_CONTEXT}")"
        fi
    fi

    if is_context_live; then
        export LEPTON_PREFIX="$(podman inspect -f '{{ index .Config.Labels "PREFIX" }}' "lepton-${LEPTON_CONTEXT}" 2>/dev/null || true)"
    elif [[ "${IS_START}" == "true" ]]; then
        create_prefix
    fi
}

function remove_context()
{
    local CONTEXT="${1:-${LEPTON_CONTEXT}}"
    podman rm -fi "lepton-${CONTEXT}" || true
}

function print_apk_info()
{
    if [[ -n "${APP_PACKAGE_ID:-}" ]]; then
        echo "APP ID: ${APP_PACKAGE_ID}"
    else
        echo "APP ID: $("${APK_INFO_EXTRACTOR_PATH}" --print-app-id "$1")"
    fi
    echo "ACTIVITY NAME: $("${APK_INFO_EXTRACTOR_PATH}" --print-activity-name "$1")"
    echo "APP VERSION: $("${APK_INFO_EXTRACTOR_PATH}" --print-app-version "$1")"
    echo "MIN SDK VERSION: $("${APK_INFO_EXTRACTOR_PATH}" --print-min-sdk-version "$1")"
}
