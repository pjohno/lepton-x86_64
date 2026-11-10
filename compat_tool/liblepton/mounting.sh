#!/bin/bash

LEPTON_IMAGE_DIR=$(realpath "${LEPTON_DIR}/../images")
source "${LEPTON_DIR}/ndk_auxv/runtime.sh"

PODMAN_CMDLINE=()
function podman_cmdline()
{
    PODMAN_CMDLINE+=("$@")
}
function podman_mount_entry_optional()
{
    local SRC="${1}"
    local DST="${2}"
    local OPT="${3}"
    if [[ -e "${SRC}" ]]; then
        podman_cmdline --mount "type=bind,source=${SRC},destination=${DST},${OPT}"
    fi
}
function podman_mount_entry()
{
    local SRC="${1}"
    local DST="${2}"
    local OPT="${3}"
    podman_cmdline --mount "type=bind,source=${SRC},destination=${DST},${OPT}"
}
function podman_mount_entry_type()
{
    local TYPE="${1}"
    local DST="${2}"
    local OPT="${3}"
    podman_cmdline --mount "type=${TYPE},destination=${DST},${OPT}"
}

BASE_APK=base.apk

function android_sdk_version()
{
    cat "${LEPTON_TEST_ROOTFS:-${LEPTON_DIR}/../images/rootfs}/system/build.prop" | grep ro.build.version.sdk= | sed "s/.*=//g"
}

# Replace only a recognised symlink. A real directory/file is user data.
function safe_storage_link()
{
    local TARGET="$1" LINK="$2"
    if [[ -L "$LINK" ]]; then
        [[ "$(readlink -- "$LINK")" == "$TARGET" ]] && return 0
        println "ERROR: unexpected storage link retained: $LINK; inspect it before changing storage mapping" >&2
        return 1
    elif [[ -e "$LINK" ]]; then
        println "ERROR: real storage path retained: $LINK; back it up and resolve the mapping manually" >&2
        return 1
    fi
    ln -s -- "$TARGET" "$LINK"
}

function setup_mounts()
{
    mkdir -p "$(data_mount_path)"
    mkdir -p "$(data_mount_path)/steam_app"

    local APP_ID="$(get_app_id)"

    if is_app; then
        BASE_APK=base.apk
        APP_APK_DIR="$(dirname "$(get_apk_path)")"
        # x86_64 port: an unpacked .apkm already has base.apk; its splits share
        # the package ID, so the rename-to-base.apk search must not run.
        if [[ -n "${APP_APK_DIR}" && -z "${LEPTON_APKM_DIR:-}" ]]; then
            # Annoyingly, we need to rename our `.apk` to `base.apk`, since Appdome expects that.
            # Android always does this, but Android is also totally okay with loading a random
            # `.apk` name.
            mapfile -t APKS < <(compgen -G "${APP_APK_DIR}/*.apk" || true)
            for APK in "${APKS[@]}"; do
                if [[ "$(extract_app_id "${APK}")" == "${APP_ID}" ]]; then
                    BASE_APK="$(lepton_basename "${APK}")"
                fi
            done
        fi
    else
        APP_APK_DIR="$(get_baked_app_data_dir)/app_lowerdir"
        mkdir -p "${APP_APK_DIR}"
    fi

    if steamos_devmode_enabled; then
        mkdir -p "${HOME}/.cache/debuginfod_client"
        podman_mount_entry "${HOME}/.cache/debuginfod_client" "/debuginfo.cache" rw
    fi

    println "Setting up overlays"

    LEPTON_ROOTFS="${LEPTON_TEST_ROOTFS:-${LEPTON_DIR}/../images/rootfs}"
    LEPTON_OVERLAY="${LEPTON_DIR}"/../images/rootfs_overlay

    # Mount some directories that are overlays over our rootfs
    # However do this using bind mounts because we cannot use multiple
    # lowerdirs with the rootfs
    GUESTOS_OVERLAY="/usr/share/guestos/android"

    for OVERLAY in "${LEPTON_OVERLAY}" "${GUESTOS_OVERLAY}"; do
        [[ -d "${OVERLAY}" ]] || continue
        pushd "${OVERLAY}" >/dev/null || exit
        while IFS= read -r -d '' file; do
            DST="${file#./}"

            # Don't mount in `XrApiLayer_VALVE_fdm_injection.json` unless the FDM layer is enabled
            if [[ "$(lepton_basename "${DST}")" == "XrApiLayer_VALVE_fdm_injection.json" ]] && ! vulkan_layer_enabled "${FDM_INJECTION_LAYER_NAME}" ; then
                continue
            fi

            podman_mount_entry "${OVERLAY}/${DST}" "/${DST}" ro
        done < <(find . -type f -print0)
        popd > /dev/null || exit
    done

    # If we're baked, put our app in the correct location, otherwise just plop it into `/data/steam_app`
    # for future installation.  NOTE: Do not call this `APP_MOUNT_DIR` as then the `local` takes no effect
    # as there's already a global `APP_MOUNT_DIR` and we end up confusing `get_app_mount_dir`.  Sigh.
    local APP_MOUNT_TARGET="data/steam_app"
    if is_app_baked; then
        APP_MOUNT_TARGET="$(get_app_mount_dir)"
    fi

    if is_sysbake; then
        podman_cmdline --mount "type=bind,source="$(data_mount_path)",target=/data"
    else
        local DATA_OVERLAY_UPPERDIR="$(data_mount_path)"
        local DATA_WORKDIR="$(data_workdir)"
        mkdir -p "${DATA_OVERLAY_UPPERDIR}"
        mkdir -p "${DATA_WORKDIR}"
        podman_cmdline -v "${BAKED_SYSTEM_DATA_DIR}:/data:O,upperdir=${DATA_OVERLAY_UPPERDIR},workdir=${DATA_WORKDIR}"

        # We need to mount this dir for dev contexts/*.apk contexts
        mkdir -p "${LEPTON_DATA_DIR}"
        podman_mount_entry "${LEPTON_DATA_DIR}" "${LEPTON_DATA_DIR}" rw

        # Also mount the whole STEAM_COMPAT_CLIENT_INSTALL_PATH into the container to avoid having to do path translations
        if [[ -n "${STEAM_COMPAT_CLIENT_INSTALL_PATH:-}" ]]; then
            podman_mount_entry "${STEAM_COMPAT_CLIENT_INSTALL_PATH}" "${STEAM_COMPAT_CLIENT_INSTALL_PATH}" rw
        fi

        # Now mount the apps library paths
        IFS=: read -ra library_paths <<< "${STEAM_COMPAT_LIBRARY_PATHS:-}"
        for library_path in "${library_paths[@]}"; do
            podman_mount_entry "${library_path}" "${library_path}" rw
        done

        # Symlink the /data/media/0 external storage location and mount relevant xdg dirs
        if [[ -d "${STEAM_COMPAT_DATA_PATH:-}" ]]; then
            if [[ -d "${STEAM_COMPAT_DATA_PATH}/media0" ]]; then
                if [[ ! -d "${STEAM_COMPAT_DATA_PATH}/external" ]]; then
                    mv "${STEAM_COMPAT_DATA_PATH}/media0" "${STEAM_COMPAT_DATA_PATH}/external"
                fi
            fi
            mkdir -p "${STEAM_COMPAT_DATA_PATH}/external"
        fi
        # x86_64 port: with kept app data, Android leaves this host-owned upper
        # directory at 0550 after shutdown; make it writable to replace the link.
        if [[ -d "$(data_mount_path)/media" ]]; then
            chmod u+rwx -- "$(data_mount_path)/media"
        fi
        mkdir -p "$(data_mount_path)/media"
        local TARGET_PATH="$(data_mount_path)/media/0"
        if [[ -d "${STEAM_COMPAT_DATA_PATH:-}" ]]; then
            TARGET_PATH="${STEAM_COMPAT_DATA_PATH}/external"
        else
            mkdir -p "${TARGET_PATH}"
        fi
        if [[ -d "${HOME}/Documents" ]]; then
            safe_storage_link "${HOME}/Documents" "${TARGET_PATH}/Documents" || die "Shared storage preserved; launch stopped"
        fi
        if [[ -d "${HOME}/Downloads" ]]; then
            safe_storage_link "${HOME}/Downloads" "${TARGET_PATH}/Download" || die "Shared storage preserved; launch stopped"
        fi
        if [[ -d "${HOME}/Videos" ]]; then
            safe_storage_link "${HOME}/Videos" "${TARGET_PATH}/Movies" || die "Shared storage preserved; launch stopped"
        fi
        if [[ -d "${STEAM_COMPAT_DATA_PATH:-}" ]]; then
            local GUEST_EXTERNAL_PATH="${STEAM_COMPAT_DATA_PATH}/external"
            if [[ -n "${LEPTON_PROFILE_EXTERNAL_STORAGE:-}" ]]; then
                [[ "$LEPTON_PROFILE_EXTERNAL_STORAGE" == /lepton/* && "$LEPTON_PROFILE_EXTERNAL_STORAGE" != *'/../'* && "$LEPTON_PROFILE_EXTERNAL_STORAGE" != */.. ]] || die 'Invalid profile external-storage path'
                # Android mounts its own /mnt during init. Experimental profiles
                # stored on host /mnt need a guest alias outside that subtree.
                GUEST_EXTERNAL_PATH="$LEPTON_PROFILE_EXTERNAL_STORAGE"
                podman_mount_entry "${STEAM_COMPAT_DATA_PATH}/external" "$GUEST_EXTERNAL_PATH" rw
            fi
            safe_storage_link "$GUEST_EXTERNAL_PATH" "$(data_mount_path)/media/0" || die "Shared storage preserved; launch stopped"
        fi
        podman_mount_entry_optional "${HOME}/Documents" "${HOME}/Documents" rw
        podman_mount_entry_optional "${HOME}/Videos" "${HOME}/Videos" rw
        podman_mount_entry_optional "${HOME}/Downloads" "${HOME}/Downloads" rw
    fi

    if steamos_devmode_enabled; then
        if perfetto_installed; then
            podman_mount_entry_optional /tmp/perfetto-producer /dev/socket/traced_producer rw
        else
            echo "Skipping perfetto setup due to missing tracebox binary ('sudo pacman -S perfetto perfetto-android' if you need it)"
        fi
    fi

    if ! is_sysbake; then
        local APP_WORKDIR="$(app_workdir)"
        local APP_OVERLAY_UPPERDIR="$(app_datadir)"
        mkdir -p "${APP_WORKDIR}"
        mkdir -p "${APP_OVERLAY_UPPERDIR}"
        podman_cmdline -v "${APP_APK_DIR}:/${APP_MOUNT_TARGET#/}:O,upperdir=${APP_OVERLAY_UPPERDIR},workdir=${APP_WORKDIR}"
        # A persistent development profile installs through pm rather than the
        # Steam bake path. Restore its code directory before package scanning.
        if [[ -n "${LEPTON_PROFILE_CODE_PATH:-}" ]]; then
            [[ "$LEPTON_PROFILE_CODE_PATH" == /data/app/* && "$LEPTON_PROFILE_CODE_PATH" != *'/../'* && "$LEPTON_PROFILE_CODE_PATH" != */.. ]] || die 'Invalid profile code path'
            podman_mount_entry "$APP_OVERLAY_UPPERDIR" "$LEPTON_PROFILE_CODE_PATH" ro
        fi
    fi

    if [[ -n "${LEPTON_MOUNT_OBB_DIR:-}" ]]; then
        podman_mount_entry "${LEPTON_MOUNT_OBB_DIR}" "/${APP_MOUNT_TARGET}/obb" ro
    fi

    podman_mount_entry "${HOME}/.steam/steam.pipe" "/lepton/steam.pipe" rw
}

# Give podman some of its boilerplate information
function setup_podman_base()
{
    # namespaces
    podman_cmdline --security-opt label=disable
    podman_cmdline --pid=private --ipc=private --uts=private

    if [[ "$(android_sdk_version)" != "30" ]]; then
        if [[ -d "/sys/fs/cgroup/lepton-${LEPTON_CONTEXT}" ]]; then
            # On gitlab CI
            podman_cmdline --cgroupns=host
            podman_cmdline --cgroup-parent="/lepton-${LEPTON_CONTEXT}"
            podman_mount_entry "/sys/fs/cgroup/lepton-${LEPTON_CONTEXT}" "/sys/fs/cgroup" rw
        else
            systemctl --user start "lepton-${LEPTON_CONTEXT}.slice"

            podman_cmdline --cgroupns=host
            podman_cmdline --cgroup-parent="lepton-${LEPTON_CONTEXT}".slice
            podman_mount_entry "/sys/fs/cgroup/$(systemctl --user show -P ControlGroup "lepton-${LEPTON_CONTEXT}.slice")" "/sys/fs/cgroup" rw,U
        fi
    else
        podman_cmdline --cgroupns=private
    fi

    # capabilities
    podman_cmdline --cap-drop ALL
    podman_cmdline --cap-add audit_control
    podman_cmdline --cap-add sys_nice
    podman_cmdline --cap-add wake_alarm
    podman_cmdline --cap-add setpcap
    podman_cmdline --cap-add setgid
    podman_cmdline --cap-add setuid
    podman_cmdline --cap-add sys_ptrace
    podman_cmdline --cap-add sys_admin
    podman_cmdline --cap-add block_suspend
    podman_cmdline --cap-add sys_time
    podman_cmdline --cap-add net_admin
    podman_cmdline --cap-add net_raw
    podman_cmdline --cap-add net_bind_service
    podman_cmdline --cap-add kill
    podman_cmdline --cap-add dac_override
    podman_cmdline --cap-add dac_read_search
    podman_cmdline --cap-add fsetid
    podman_cmdline --cap-add mknod
    podman_cmdline --cap-add syslog
    podman_cmdline --cap-add chown
    podman_cmdline --cap-add sys_resource
    podman_cmdline --cap-add fowner
    podman_cmdline --cap-add ipc_lock
    podman_cmdline --cap-add sys_chroot

    # hostname
    podman_cmdline --hostname "lepton-${LEPTON_CONTEXT}"

    # seccomp
    podman_cmdline --security-opt seccomp="${LEPTON_DIR}"/lepton.seccomp.json
}

function podman_extract_rootfs_file()
{
    local FILE="$1"
    local TARGET="$2"
    cp "${LEPTON_TEST_ROOTFS:-${LEPTON_DIR}/../images/rootfs}/${FILE#/}" "${TARGET}"
}

function generate_app_launch_rc()
{
    local APP_LAUNCH_RC="$(prefix "${1:-}")/lepton_app_launch.rc"

    local APP_MOUNT_TARGET="data/steam_app"
    if is_app_baked; then
        APP_MOUNT_TARGET="$(get_app_mount_dir)"
    fi

    if ! is_app_baked && [[ "${BASE_APK}" != "base.apk" ]]; then
        println "on early-init" >>"${APP_LAUNCH_RC}"
        println "    exec -- /system/bin/sh -c \"mv \"/${APP_MOUNT_TARGET#/}/${BASE_APK}\" \"/${APP_MOUNT_TARGET#/}/base.apk\"\"" >>"${APP_LAUNCH_RC}"
        println "    exec -- /system/bin/sh -c \"find \"/${APP_MOUNT_TARGET#/}\" -name '*.apk' -a ! -name 'base.apk' -type f -exec rm -f {} +\"" >>"${APP_LAUNCH_RC}"
    fi

    if ! is_app || is_app_baked; then
        println "on property:sys.boot_completed=1" >>"${APP_LAUNCH_RC}"
        println "    exec -- /system/bin/cmd lepton mount_vulkan_layers" >>"${APP_LAUNCH_RC}"
    fi

    # Only do this if we actually have an app we're trying to launch
    if is_app; then
        println "on property:sys.boot_completed=1 && property:ro.lepton.app_baked=1" >>"${APP_LAUNCH_RC}"

        # Make sure the obb symlink is in order.
        local APP_ID="$(get_app_id)"
        println "    exec -- /vendor/bin/fix_obb_symlink.sh \"${APP_ID}\"" >>"${APP_LAUNCH_RC}"

        # Add install commands for vulkan layers
        local HOST_LAYER_INSTALL_SCRIPT="$(prefix "${1:-}")/vulkan_layer_setup.sh"
        local CONTAINER_LAYER_INSTALL_SCRIPT="/vendor/share/vulkan_layer_setup.sh"
        generate_vulkan_settings_script > "${HOST_LAYER_INSTALL_SCRIPT}"
        chmod 0755 "${HOST_LAYER_INSTALL_SCRIPT}"
        println "    exec -- /system/bin/sh ${CONTAINER_LAYER_INSTALL_SCRIPT}" >>"${APP_LAUNCH_RC}"
        podman_mount_entry "${HOST_LAYER_INSTALL_SCRIPT}" "${CONTAINER_LAYER_INSTALL_SCRIPT}" ro,U

        # Wait for storage to be mounted
        println "    exec -- /system/bin/timeout 10 /system/bin/logcat -e \"End Intent.*android.intent.action.MEDIA_MOUNTED\" -m 1" >>"${APP_LAUNCH_RC}"

        if debugger_wait_enabled || strace_enabled; then
            println "Adding debugger wait to app launch"
            println "    exec -- /system/bin/sh -c \"$(debugger_wait_commands)\"" >>"${APP_LAUNCH_RC}"
        fi

        # Run the actual app
        println "    exec -- /system/bin/sh -c \"$(lepton_launch_commands)\"" >>"${APP_LAUNCH_RC}"

        if debugger_wait_enabled || strace_enabled; then
            if strace_enabled; then
                println "Adding strace to app launch"
                println "on property:ro.lepton.ready_for_debugger=true" >>"${APP_LAUNCH_RC}"
                println "    exec -- /system/bin/sh -c \"$(strace_zygote_commands)\"" >>"${APP_LAUNCH_RC}"
            fi
    fi
        chmod 0644 "${APP_LAUNCH_RC}"
    fi
    podman_mount_entry "${APP_LAUNCH_RC}" "/vendor/etc/init/$(lepton_basename "${APP_LAUNCH_RC}")" ro,U
}


function generate_zygote_launch_rc()
{
    local TURNIP_VARS=(
        TU_GPU_TRACEPOINT
        _TU_DEBUG
        TU_BREADCRUMBS
        TU_DEBUG_STALE_REGS_RANGE
        TU_DEBUG_STALE_REGS_FLAGS
        FD_DEV_FEATURES
        FD_RD_DUMP
        IR3_SHADER_DEBUG
        IR3_SHADER_OVERRIDE_PATH
        MESA_VK_ABORT_ON_DEVICE_LOSS
        MESA_GPU_TRACES
        MESA_VK_ENABLE_SUBMIT_THREAD
        MESA_VK_TRACE
        MESA_VK_TRACE_TRIGGER
        NIR_DEBUG
        NIR_SKIP
    )
    local ZINK_VARS=(
        MESA_EXTENSION_OVERRIDE
        MESA_GLSL_VERSION_OVERRIDE
        MESA_GLES_VERSION_OVERRIDE
        MESA_SHADER_CACHE_MAX_SIZE
        MESA_DISK_CACHE_SINGLE_FILE
        MESA_DISK_CACHE_READ_ONLY_FOZ_DBS
        ZINK_DEBUG
        ZINK_DESCRIPTORS
        ZINK_RENDERDOC
        GALLIUM_THREAD
        ZINK_HANG_ABORT
    )
    local PASSTHROUGH_VARS=(
        "${TURNIP_VARS[@]}"
        "${ZINK_VARS[@]}"

        # FDM injection layer debug options
        FDM_DEBUG
        FOVE_LEVEL

        # Pass through `SteamAppId` so `steamvr` can get at it in `CVRClient::SendConnectMessage()`
        SteamAppId

        # Pass through debugging variables that vrclient can use
        EnableFrameEndMarkers
        DisableTimelineSemaphoreWait

        # Pass through proxy variables
        HTTP_PROXY
        HTTPS_PROXY
        http_proxy
        https_proxy
        NO_PROXY
        no_proxy
    )
    local ZYGOTE_LAUNCH_RC="$(prefix "${1:-}")/init.zygote64.rc"
    podman_extract_rootfs_file "/system/etc/init/hw/init.zygote64.rc" "${ZYGOTE_LAUNCH_RC}"
    for VAR in ${PASSTHROUGH_VARS[@]}; do
        if [[ -v "${VAR}" ]]; then
            println "    setenv ${VAR} ${!VAR}" >> "${ZYGOTE_LAUNCH_RC}"
        fi
    done

    # User LEPTON_ENV_* passthrough variables.
    for VAR in $(compgen -v); do
        if [[ "${VAR}" == "LEPTON_ENV_"* ]]; then
            VARNAME="${VAR#LEPTON_ENV_}"
            println "    setenv ${VARNAME} ${!VAR}" >> "${ZYGOTE_LAUNCH_RC}"
        fi
    done

    configure_ndk_compat "${ZYGOTE_LAUNCH_RC}"

    # provide a vr config file
    println "    setenv VR_PATHREG_OVERRIDE /vendor/etc/openvrpaths.vrpath" >> "${ZYGOTE_LAUNCH_RC}"
    podman_mount_entry "${LEPTON_DIR}/openvrpaths.vrpath" "/vendor/etc/openvrpaths.vrpath" ro,U

    # tell vrclient where to find our steamvr config/logs
    println "    setenv VR_CONFIG_PATH /data/steamvr/config" >> "${ZYGOTE_LAUNCH_RC}"
    println "    setenv VR_LOG_PATH /data/steamvr/logs" >> "${ZYGOTE_LAUNCH_RC}"

    # Tell Mesa where to slurp up its shaders
    #println "    setenv MESA_SHADER_CACHE_DIR /data/shaders" >> "${ZYGOTE_LAUNCH_RC}"
    println "    setenv Steam3Master $(podman_subnet).1:57343" >> "${ZYGOTE_LAUNCH_RC}"

    chmod 0644 "${ZYGOTE_LAUNCH_RC}"
    podman_mount_entry "${ZYGOTE_LAUNCH_RC}" "/system/etc/init/hw/init.zygote64.rc" ro,U
}

function disable_default_allocator()
{
    println "<manifest version=\"1.0\" type=\"device\"></manifest>" > $(prefix)/allocator.xml
    podman_mount_entry "$(prefix)/allocator.xml" "/vendor/etc/vintf/manifest/android.hardware.graphics.allocator@4.0.xml" rw,U
}

function disable_minigbm()
{
    rm -f $(prefix)/minigbm_msm.rc
    touch $(prefix)/minigbm_msm.rc
    podman_mount_entry "$(prefix)/minigbm_msm.rc" "/vendor/etc/init/allocator.rc" rw,U
    podman_mount_entry "$(prefix)/minigbm_msm.rc" "/vendor/etc/init/android.hardware.graphics.allocator@4.0-service.minigbm_msm.rc" rw,U
    podman_mount_entry "$(prefix)/minigbm_msm.rc" "/vendor/etc/init/android.hardware.graphics.allocator@4.0-service.minigbm.rc" rw,U
}

function disable_qti_display()
{
    println "<manifest version=\"1.0\" type=\"device\"></manifest>" > $(prefix)/qti-display.xml
    rm -f $(prefix)/qti-display.rc
    touch $(prefix)/qti-display.rc
    podman_mount_entry "$(prefix)/qti-display.xml" "/vendor/etc/vintf/manifest/android.hardware.graphics.mapper-impl-qti-display.xml" rw,U
    podman_mount_entry "$(prefix)/qti-display.xml" "/vendor/etc/vintf/manifest/vendor.qti.hardware.display.allocator-service.xml" rw,U
    podman_mount_entry "$(prefix)/qti-display.rc" "/vendor/etc/init/vendor.qti.hardware.display.allocator-service.rc" rw,U
}

# x86_64 port: the Android image ships only AMD (RADV/radeonsi) GPU drivers.
# Stop early with a clear message instead of an opaque Android graphics failure.
function check_host_gpu()
{
    [[ "$(uname -m)" == "x86_64" ]] || return 0
    [[ "${LEPTON_FORCE_SOFTWARE:-}" != "true" && "${LEPTON_SKIP_GPU_CHECK:-false}" != "true" ]] || return 0
    local vendor_file
    for vendor_file in /sys/class/drm/renderD*/device/vendor; do
        [[ -r "${vendor_file}" ]] || continue
        [[ "$(<"${vendor_file}")" == "0x1002" ]] && return 0
    done
    die "Lepton x86_64: no AMD GPU render node (/dev/dri/renderD*, vendor 0x1002) found." \
        "This build only includes AMD RADV/radeonsi drivers (Steam Deck and AMD Radeon GPUs)." \
        "Set LEPTON_FORCE_SOFTWARE=true to try slow software rendering instead."
}

function setup_podman_mounts()
{
    local PREFIX="$(prefix)"

    # Tell podman to setup a bunch of dev and bind-mounts for us, mostly dev nodes and whatnot.
    # We obviously can't bake these into the `.img` files, which is why we ask podman to do them at container creation time.

    # Set the rootfs path

    podman_cmdline --env-file /dev/null

    # tmpfs mounts.  `/dev` is special, as it's going to get `dev` devices so it can't be `nodev`.
    local TMPFS_NODES=(tmp var run)
    podman_cmdline --tmpfs /dev:rw,nosuid,noexec,U
    podman_cmdline --tmpfs /dev/socket:rw,nosuid,noexec,U

    for tmpfs in "${TMPFS_NODES[@]}"; do
        podman_cmdline --tmpfs /"${tmpfs}":rw,nosuid,nodev,noexec,U
    done
    podman_cmdline --tmpfs /waydroid/xdg

    local DEV_NODES=(
        zero null full fuse tty char

        # V4L2 video devices (Note: explicitly do not share 99, we use that for screen broadcasting)
        # Update: Elliot is explicitly disabling this for now, until we decide that we _want_
        # to support reading in video in Lepton.
        #video{0..11} video-dec0

        # Shared memory
        shm

        # Sound
        snd

        # Necessary for adb
        uhid

        # Necessary for VPN
        net/tun

        random urandom
    )

    # On gitlab we run via swiftshader.
    if [[ "${LEPTON_FORCE_SOFTWARE:-}" != "true" ]]; then
        if [[ "$(uname -m)" == "x86_64" ]]; then
            for dev in /dev/dri/renderD* /dev/dri/card*; do
                [[ -e "${dev}" ]] || continue
                podman_mount_entry "${dev}" "${dev}" rw
            done
        else
            for dev in renderD128 card0; do
                if [[ -e "/dev/dri/${dev}" ]]; then
                    podman_mount_entry "/dev/dri/${dev}" "/dev/dri/${dev}" rw
                fi
            done

            # KGSL blob driver compatibility.
            podman_mount_entry "/dev/dri/renderD128" "/dev/kgsl-3d0" rw
        fi
    fi

    for dev in "${DEV_NODES[@]}"; do
        if [[ -e "/dev/${dev}" ]]; then
            podman_mount_entry "/dev/${dev}" "/dev/${dev}" rw
        fi
    done
    # x86_64 port: media decoders (Codec2) allocate from the DMA-BUF system heap.
    if lepton_dma_heap_usable && [[ "${LEPTON_CODEC2:-auto}" != false ]]; then
        podman_mount_entry "$(lepton_dma_heap_device)" "/dev/dma_heap/system" rw
    fi

    # Bind each Steam Input virtual controller present at container startup.
    # Podman's --device nodes are hidden by Android's /dev tmpfs, so explicit
    # per-device binds are needed. This does not expose unrelated host inputs.
    # Later controller connections still require experimental hotplug opt-in.
    # Passthrough defaults to enabled; set LEPTON_GAMEPAD_PASSTHROUGH=false
    # to opt out.
    if ! is_sysbake && [[ "${LEPTON_GAMEPAD_PASSTHROUGH:-true}" == "true" ]]; then
        local gamepad_event gamepad_sysfs gamepad_name gamepad_vendor gamepad_product
        for gamepad_event in /dev/input/event*; do
            [[ -c "${gamepad_event}" ]] || continue
            gamepad_sysfs="/sys/class/input/${gamepad_event##*/}/device"
            [[ -r "${gamepad_sysfs}/name" &&
               -r "${gamepad_sysfs}/id/vendor" &&
               -r "${gamepad_sysfs}/id/product" ]] || continue

            gamepad_name="$(cat "${gamepad_sysfs}/name")"
            gamepad_vendor="$(cat "${gamepad_sysfs}/id/vendor")"
            gamepad_product="$(cat "${gamepad_sysfs}/id/product")"

            if [[ "${gamepad_name}" == "Microsoft X-Box 360 pad "* &&
                  "${gamepad_vendor}" == "28de" &&
                  "${gamepad_product}" == "11ff" ]]; then
                println "Passing Steam Input controller ${gamepad_event} to Android"
                podman_mount_entry "${gamepad_event}" "${gamepad_event}" rw
            fi
        done
        # One shared keylayout for every matching Steam Input virtual pad.
        podman_mount_entry \
            "${LEPTON_DIR}/Vendor_28de_Product_11ff.kl" \
            "/system/usr/keylayout/Vendor_28de_Product_11ff.kl" ro
    fi

    # Experimental hotplug proof: make host evdev nodes visible at a stable
    # path, separate from Android's own /dev/input FIFOs and input registry.
    # No additional Android devices are registered until a selected symlink
    # is explicitly created under /dev/input. Opt-in because this directory
    # exposes more host input devices to Android than the individual bind.
    if ! is_sysbake &&
       [[ "${LEPTON_GAMEPAD_PASSTHROUGH:-true}" == "true" ]] &&
       [[ "${LEPTON_GAMEPAD_HOTPLUG:-false}" == "true" ]] &&
       [[ -d /dev/input ]]; then
        podman_mount_entry /dev/input /lepton/host-input ro
    fi

    # By default, we do not allow writes to msg
    local KMSG_MOUNT="/dev/null"
    if [[ "${LEPTON_ALLOW_KMSG:-false}" != "false" ]]; then
        KMSG_MOUNT="/dev/kmsg"
    fi
    podman_mount_entry "${KMSG_MOUNT}" /dev/container_kmsg rw
    podman_mount_entry "${KMSG_MOUNT}" /dev/kmsg rw

    # devpts mount
    podman_mount_entry_type "devpts" /dev/pts "mode=644,ptmxmode=666"

    # debugfs mount
    podman_mount_entry "/sys/kernel/debug" "/sys/kernel/debug" rw
    podman_mount_entry "/sys/kernel/tracing" "/sys/kernel/tracing" rw
    podman_cmdline --tmpfs /sys/fs/bpf:rw,mode=700

    podman_mount_entry_optional "${APK_AUTO_INSTALL_DIR}" "/data/auto_install" rw,U

    DATA_OVERLAY="$(data_mount_path)"

    # Generate `ipconfig.txt` for our ethernet device:
    generate_ipconfig_txt > "$(prefix)/ipconfig.txt"
    mkdir -p "${DATA_OVERLAY}/misc/ethernet"
    touch "${DATA_OVERLAY}/misc/ethernet/ipconfig.txt"
    podman_mount_entry "$(prefix)/ipconfig.txt" "/data/misc/ethernet/ipconfig.txt" rw

    # Android 14 prefers the Tethering APEX configuration over the legacy path.
    # Override both with this container's current IP, not an address from sysbake.
    if [[ "$(android_sdk_version)" -ge 34 ]]; then
        local ETHERNET_APEX_CONFIG="misc/apexdata/com.android.tethering/misc/ethernet/ipconfig.txt"
        mkdir -p "${DATA_OVERLAY}/$(dirname "${ETHERNET_APEX_CONFIG}")"
        touch "${DATA_OVERLAY}/${ETHERNET_APEX_CONFIG}"
        podman_mount_entry "$(prefix)/ipconfig.txt" "/data/${ETHERNET_APEX_CONFIG}" rw
    fi

    if ! is_sysbake && command -v steamvr >/dev/null 2>&1; then
        mkdir -p "${DATA_OVERLAY}/steamvr/runtime"
        # Add our steamvr build into `/data/steamvr/runtime` and `/data/steamvr/config`
        podman_mount_entry "$(steamvr path)" "/data/steamvr/runtime" rw

        podman_mount_entry "${STEAM_LOG_PATH}" "/data/steamvr/logs" rw
        podman_mount_entry "$(steamvr configpath)" "/data/steamvr/config" ro
    fi

    # Mount shader cache directory
    if [[ -d "${STEAM_COMPAT_SHADER_PATH:-}" ]]; then
        podman_mount_entry "${STEAM_COMPAT_SHADER_PATH}" "/data/shaders" rw,U
    fi

    # Mount persistent data path
    if [[ -d "${STEAM_COMPAT_DATA_PATH:-}" ]]; then
        PERSISTENT_DATA_PATH="${STEAM_COMPAT_DATA_PATH}/internal/$(get_app_id)"
        if [[ -n "$(get_app_id)" && -d "${STEAM_COMPAT_DATA_PATH}/$(get_app_id)" ]]; then
            if [[ ! -d "${PERSISTENT_DATA_PATH}" ]]; then
                mkdir -p "$(dirname "${PERSISTENT_DATA_PATH}")"
                mv "${STEAM_COMPAT_DATA_PATH}/$(get_app_id)" "${PERSISTENT_DATA_PATH}"
            fi
        fi
        mkdir -p "${PERSISTENT_DATA_PATH}"
        chmod 700 "${PERSISTENT_DATA_PATH}"
    fi

    mkdir -p "${PREFIX}/mounts"
    # Mount steamclient.so directory.  Note that we have to add `libsteamclient` and friends
    # to `/system/etc/public.libraries.txt` so that it's all loadable.
    podman_extract_rootfs_file "/system/etc/public.libraries.txt" "${PREFIX}/mounts/public.libraries.txt"
    if [[ -f "${STEAM_COMPAT_CLIENT_INSTALL_PATH:-}/androidarm64/libsteamclient.so" ]]; then
        for LIBNAME in "${STEAM_COMPAT_CLIENT_INSTALL_PATH}/androidarm64/"*.so; do
            LIBNAME="$(lepton_basename "${LIBNAME}")"
            println "${LIBNAME} nopreload" >>"${PREFIX}/mounts/public.libraries.txt"
            podman_mount_entry "${STEAM_COMPAT_CLIENT_INSTALL_PATH}/androidarm64/${LIBNAME}" "/system/lib64/${LIBNAME}" ro,U
        done
    fi
    podman_mount_entry "${PREFIX}/mounts/public.libraries.txt" "/system/etc/public.libraries.txt" ro,U

    # We need to insert our vulkan loader libraries here so that libopenxr_loader.so can load them.
    # The vulkan loader can load them no problem (sigh) but our plebian libopenxr_loader.so cannot.
    for LIBPATH in "${ENABLED_VULKAN_LAYER_PATHS[@]}"; do
        podman_mount_entry "${LIBPATH}" "/vendor/enabled_vulkan_layers/$(lepton_basename "${LIBPATH}")" ro
    done

    # If we have renderdoc .apk's, mount them in to where we expect them within the container
    if vulkan_layer_enabled "${RENDERDOC_LAYER_NAME}" && [[ -f "/usr/share/renderdoc/plugins/android/${RENDERDOC_APP_ID}.apk" ]]; then
        println "Mounting in renderdoc .apk"
        podman_mount_entry "/usr/share/renderdoc/plugins/android/${RENDERDOC_APP_ID}.apk" "/vendor/apps_to_install/${RENDERDOC_APP_ID}.apk" ro
    fi

    # Mount in our prop file
    podman_mount_entry "$(props_file)" "/vendor/waydroid.prop" ro,U

    # Next, mounts for things like pulse, wayland, etc...
    podman_mount_entry "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" "/waydroid/xdg/wayland-0" rw,U
    if ! is_sysbake; then
        podman_mount_entry "${PULSE_RUNTIME_PATH}/native" "/waydroid/xdg/pulse/native" rw,U
    fi

    # Disable incompatible services depending on the gfx mode.
    if [[ "${LEPTON_FORCE_SOFTWARE:-}" == "true" ]]; then
        if [[ "$(android_sdk_version)" == "30" ]]; then
            disable_default_allocator
        fi
        disable_minigbm
        disable_qti_display

        # x86_64 software mode: the GBM 4.0 HAL is declared in VINTF
        # and may be started lazily even with gralloc=default.
        # Hide these HAL declarations so Android uses software gralloc.
        if [[ "$(uname -m)" == "x86_64" ]]; then
            local empty_manifest="${PREFIX}/gbm-software-vintf.xml"
            printf '%s\n' '<manifest version="1.0" type="device"></manifest>' > "${empty_manifest}"

            local fragment
            for fragment in gbm_mesa.allocator@4.0.xml gbm_mesa.mapper@4.0.xml; do
                if [[ -f "${LEPTON_DIR}/../images/rootfs/vendor/etc/vintf/manifest/${fragment}" ]]; then
                    podman_mount_entry "${empty_manifest}" "/vendor/etc/vintf/manifest/${fragment}" ro,U
                fi
            done
        fi
    else
        if [[ "${LEPTON_USE_QCOM_DRIVER:-false}" == "true" ]]; then
            disable_minigbm
        else
            disable_qti_display
        fi
    fi

    if [[ -n "${DEBUGINFOD_URLS:-}" ]]; then
        # Tell crash dump the debuginfod urls (env does not get inherited from zygote).
        println "${DEBUGINFOD_URLS}" > "$(prefix)/debuginfod_urls.txt"
        podman_mount_entry "$(prefix)/debuginfod_urls.txt" "/vendor/etc/debuginfod_urls.txt" rw,U
    fi
}

function log_moved_dirs()
{
    if [[ -n "${1:-}" ]]; then
        echo "WARNING: lepton moved some files because they had incorrect permissions."
        echo "If you lost something, try looking here: ${1:-}"
    fi
}

MOVED_INACCESSIBLE=""
function ensure_permissions_ok()
{
    local APP_ID="$(get_app_id)"
    if ! is_sysbake && [[ "${LEPTON_CONTEXT:-}" == "steamlaunch-"* ]]; then
        if [[ -n "${STEAM_LOG_PATH}" ]]; then
            # Log files we touch but are not owned by us will cause trouble
            for not_owned_by_us in $(find "${STEAM_LOG_PATH}" ! -uid "$(id -u)" -name "*app_process64*" -type f); do
                # Since the dir is owned by us, we can rm files within it.
                rm -f "${not_owned_by_us}"
            done

            if [[ -n "${APP_ID}" ]]; then
                for not_owned_by_us in $(find "${STEAM_LOG_PATH}" ! -uid "$(id -u)" -name "*${APP_ID}*" -type f); do
                    # Since the dir is owned by us, we can rm files within it.
                    rm -f "${not_owned_by_us}"
                done
            fi
        fi

        # Android-owned profile directories must keep their location and owner.
        # Moving one aside can silently make a subsequent launch look empty.
        if [[ -n "${STEAM_COMPAT_SHADER_PATH:-}" ]]; then
            SHADER_PATH_STAT="$(stat --format "%u:%g" "${STEAM_COMPAT_SHADER_PATH:-}" 2>/dev/null || true)"
            if [[ -n "${SHADER_PATH_STAT}" ]] && [[ "${SHADER_PATH_STAT}" != "$(id -u):$(id -g)" ]]; then
                # If it's a directory it may not be empty, so we can't rm it => move it.
                mv "${STEAM_COMPAT_SHADER_PATH:-}" "${STEAM_COMPAT_SHADER_PATH:-}"-backup
                MOVED_INACCESSIBLE+="${STEAM_COMPAT_SHADER_PATH:-}-backup "
            fi
            for not_owned_by_us in $(find "${STEAM_COMPAT_SHADER_PATH:-}" -maxdepth 1 -type d ! -uid "$(id -u)" 2>/dev/null || true); do
                # If it's a directory it may not be empty, so we can't rm it => move it.
                # Also since we mount the whole dir as is, we cannot just mv
                # the subdirectories since podman wants to lchown the whole dir
                mv "${STEAM_COMPAT_SHADER_PATH:-}" "${STEAM_COMPAT_SHADER_PATH:-}"-backup
                MOVED_INACCESSIBLE+="${STEAM_COMPAT_SHADER_PATH:-}-backup "
                break
            done
        fi
    fi
}

function continue_boot_after_bake()
{
    # Android's package manager owns app-private data. Never replace it with
    # a fresh legacy host directory after installation or repair.
    podman_attach sh -c "setprop ro.lepton.app_baked 1"
}
