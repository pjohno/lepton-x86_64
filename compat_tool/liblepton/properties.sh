#!/bin/bash

function props_file()
{
    print "$(prefix)/lepton.prop"
}

# x86_64 port: host DMA-BUF system heap for Codec2 buffers (world-accessible on
# SteamOS; the "video" group on e.g. Fedora). Overridable for tests.
function lepton_dma_heap_device() { print "${LEPTON_DMA_HEAP_DEVICE:-/dev/dma_heap/system}"; }
function lepton_dma_heap_usable()
{
    local DEVICE="$(lepton_dma_heap_device)"
    [[ "$(uname -m)" == "x86_64" && -c "${DEVICE}" && -r "${DEVICE}" && -w "${DEVICE}" ]]
}

function setup_props()
{
    local CONTEXT="${1:-${LEPTON_CONTEXT}}"
    PROPS_FILE="$(props_file)"
    PROPERTIES=""
    SOREPLACEMENTS_FILE="${LEPTON_DIR}/soreplacements.txt"
    function props_echo()
    {
        PROPERTIES+="$@"$'\n'
    }
    rm -f "${PROPS_FILE}"

    # Parse the list of so file replacements based on their buildid
    while read -r BUILDID SONAME; do
        [[ "${BUILDID}" == \#* ]] && continue
        props_echo "ro.lepton.soreplace.${BUILDID}=${SONAME}"
    done < "${SOREPLACEMENTS_FILE}"

    # If we don't have `ashmem`, tell android to use `memfd` instead.
    if [[ ! -e /dev/ashmem ]]; then
        props_echo "sys.use_memfd=true"
    fi

    if steamos_devmode_enabled; then
        props_echo "ro.lepton.devmode=true"
    else
        props_echo "ro.lepton.devmode=false"
    fi

    local VAR
    for VAR in $(compgen -A variable LEPTON_GFXRECON_); do
        local OPTION="${VAR#LEPTON_GFXRECON_}"
        local VALUE="${!VAR}"
        props_echo "debug.gfxrecon.${OPTION,,}=${VALUE}"
    done

    # Unpriv single user mode
    # bpfloader is disabled
    props_echo "bpf.progs_loaded=1"
    # ueventd is disabled
    props_echo "ro.cold_boot_done=true"

    # We have to use dex2oat64 as we are 64-bit only.
    props_echo "dalvik.vm.dex2oat64.enabled=true"
    props_echo "dalvik.vm.usejit=true"

    # Android handles browser/app-link flows by default. Steam forwarding is
    # an explicit option and never captures targeted or non-web VIEW intents.
    props_echo "persist.lepton.forward_web_intents=${LEPTON_FORWARD_WEB_INTENTS:-false}"

    # Video/Rendering props
    # Android 14 x86_64 exposes the Codec2 software store without an OMX HAL.
    # Disabling Codec2 there leaves MediaCodecList empty (including audio), so
    # games using SoundPool/MediaPlayer/WebView audio are silent.
    if [[ "$(uname -m)" == "x86_64" && "$(android_sdk_version)" -ge 34 && "${LEPTON_CODEC2:-auto}" == true ]]; then
        # Experimental (video): linear buffers via gralloc BLOB + BUFFERQUEUE.
        # Known to stop Android booting on current builds.
        props_echo "debug.stagefright.ccodec=4"
        props_echo "debug.stagefright.c2-poolmask=786432"
    elif [[ "$(uname -m)" == "x86_64" && "$(android_sdk_version)" -ge 34 && "${LEPTON_CODEC2:-auto}" != false ]] &&
         lepton_dma_heap_usable; then
        # Codec2 allocates linear (audio) buffers from the DMA-BUF system heap,
        # which setup_podman_mounts passes through when the user can open it.
        props_echo "debug.stagefright.ccodec=4"
    else
        props_echo "debug.stagefright.ccodec=0"
    fi
    props_echo "ro.opengles.version=196609"
    props_echo "ro.hardware.camera=v4l2"

    if [[ "${LEPTON_FORCE_SOFTWARE:-}" == "true" ]]; then
        # sysbake on gitlab
        if [[ "$(android_sdk_version)" == "30" ]]; then
            props_echo "ro.hardware.egl=swiftshader"
        else
            props_echo "ro.hardware.egl=angle"
            props_echo "ro.hardware.vulkan=pastel"
        fi
        props_echo "ro.hardware.gralloc=default"
        # tests on gitlab
        props_echo "ro.hardware.vulkan=pastel"
    else
        if [[ "$(uname -m)" == "x86_64" ]]; then
            # x86_64: ANGLE for EGL/GLES, RADV for Vulkan, generic minigbm.
            props_echo "ro.hardware.egl=angle"
            props_echo "ro.hardware.vulkan=radeon"
            props_echo "ro.hardware.gralloc=minigbm_gbm_mesa"
            props_echo "debug.angle.feature_overrides_disabled=supportsSwapchainMaintenance1"
        else
            # Default to using turnip as our driver, but allow using the qcom driver
            if [[ "${LEPTON_USE_QCOM_DRIVER:-false}" == "true" ]]; then
                props_echo "ro.hardware.egl=angle"
                props_echo "ro.hardware.vulkan=adreno"
                props_echo "ro.hardware.gralloc=qti-display"
                props_echo "vendor.gralloc.disable_ubwc=1"
            else
                props_echo "ro.hardware.egl=mesa"
                props_echo "ro.hardware.vulkan=freedreno"
                props_echo "ro.hardware.gralloc=minigbm_msm"

                # Zink + disable kopper to work with mesa
                props_echo "mesa.loader.driver.override=zink"
                props_echo "mesa.libgl.kopper.disable=true"
            fi
        fi

        # Tell Fossilize to write out shaders to this directory
        if is_app && [[ -n "${STEAM_FOSSILIZE_DUMP_PATH:-}" ]]; then
            local DUMP_SUBPATH="${STEAM_FOSSILIZE_DUMP_PATH#"${STEAM_COMPAT_SHADER_PATH}"/}"
            props_echo "debug.fossilize.dump_path=/data/shaders/${DUMP_SUBPATH}"
            props_echo "mesa.shader.cache.disable=false"
            props_echo "mesa.shader.cache.dir=/data/shaders"
        fi
    fi

    props_echo "ro.vndk.lite=true"
    props_echo "ro.product.model=Lepton"
    props_echo "ro.product.manufacturer=Valve"

    props_echo "ro.steam.running_in_app_container=true"

    # Set logcat to use a specific buffer size (useful when debugging)
    props_echo "ro.logd.size=${LEPTON_LOGCAT_BUFFER_SIZE:-256K}"
    props_echo "ro.logd.filter=disable"

    # Perhaps someday enable iorapd for I/O prefetching on apps
    # NOTE: In my testing, iorapd is so slow to start, we have to wait an extra 400ms
    # for it to be ready, which is a non-starter for us, as we always start from boot!
    #props_echo "ro.iorapd.enable=true"
    #props_echo "ro.iorapd.dexopt.enable=true"
    #props_echo "ro.iorapd.perfetto.enable=true"
    #props_echo "ro.iorapd.readahead.enable=true"

    # This is queried by the Android Vulkan loader at startup time
    # and is set by SurfaceFlinger. Our SurfaceFlinger is run using Zink.
    # Thus, set this ourselves to avoid a deadlock.
    props_echo "service.sf.present_timestamp=0"

    # Disable services we don't actually need
    # android/frameworks/base/services/java/com/android/server/SystemServer.java
    # prevents "connecting to camera service" spam
    props_echo "config.disable_cameraservice=true"
    props_echo "config.disable_otadexopt=true"
    props_echo "config.disable_systemtextclassifier=true"
    props_echo "config.disable_networktime=true"

    # Disable boot animation
    props_echo "debug.sf.nobootanimation=1"

    props_echo "waydroid.host.user=$(id -u -n)"
    props_echo "waydroid.host.uid=1000"
    props_echo "waydroid.host.gid=1000"
    props_echo "waydroid.xdg_runtime_dir=/waydroid/xdg"
    props_echo "waydroid.pulse_runtime_path=/waydroid/xdg/pulse"
    props_echo "waydroid.stub_sensors_hal=1"

    # Only show the 2d screen if we're not baking and our app requests it.
    if ! is_sysbake && app_wants_flatscreen; then
        # /vendor/waydroid.prop is mounted by Podman and imported by Android
        # init. Exported host variables alone cannot configure SurfaceFlinger.
        if [[ "${LEPTON_LOCAL_DISPLAY_ACTIVE:-0}" == 1 ]]; then
            props_echo "ro.lepton.local_display=true"
            props_echo "ro.lepton.local_fullscreen=${LEPTON_LOCAL_FULLSCREEN:-1}"
            props_echo "ro.lepton.local_output=${LEPTON_LOCAL_OUTPUT:-}"
        fi
        props_echo "waydroid.wayland_display=wayland-0"
        props_echo "waydroid.background_start=false"
        props_echo "lepton.headless=false"
    else
        props_echo "lepton.headless=true"
    fi

    props_echo "lepton.active_app_launch_timeout=${LEPTON_APP_LAUNCH_TIMEOUT:-60}"

    # Tell `libsteam_api.so` where to find `libsteamclient.so`
    props_echo "lepton.steamclient.path=/system/lib64/libsteamclient.so"

    # Tell renderdoc to flip certain behavioral switches for us:
    props_echo "debug.renderdoc.autograntpermissions=1"

    # Enable traced
    props_echo "persist.traced.enable=1"
    if is_app; then
        props_echo "debug.atrace.app_0=$(get_app_id)"
    fi

    # We have a system service that watches for a process exit matching
    # this package name, and then shuts down the container.
    if is_app; then
        # x86_64 port: in Google sign-in mode the session follows the Play Store.
        props_echo "lepton.app_id=$(lepton_observed_app_id)"

        # This one isn't watched by the process observer, but it is
        # used by other tools like the perfetto and renderdoc integrations
        props_echo "lepton.active_app_id=$(get_app_id)"
    fi

    if is_app_baked; then
        props_echo "ro.lepton.app_baked=1"
    fi

    # Set correct timezone
    local TIMEZONE_STR="$(readlink /etc/localtime)"
    TIMEZONE_STR="${TIMEZONE_STR#/usr/share/zoneinfo/}"
    props_echo "persist.sys.timezone=${TIMEZONE_STR}"

    if [[ -n "${LEPTON_ADB_PORT:-}" ]]; then
        props_echo "service.adb.tcp.port=${LEPTON_ADB_PORT}"
    fi

    println "${PROPERTIES}" >"${PROPS_FILE}"

    # Android `init` refuses to load a file with group-writable permissions
    chmod 0644 "${PROPS_FILE}"
}
