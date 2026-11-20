#!/bin/bash

function props_file()
{
    print "$(prefix)/lepton.prop"
}

# x86_64 port: Android 14's only media decoders are Codec2's. Their buffers
# come either from gralloc BLOB allocations (Valve's upstream pool mask, needs
# no host access) or from the host DMA-BUF system heap, which only some users
# may open (root-only on SteamOS, the "video" group on Fedora).
#   blob: AMD with an image whose gbm_mesa allocator never maps buffers
#         itself (patch 0013); allocators without it crash on BLOB buffers
#         on AMD, so the image is checked, overlay first. Intel also needs
#         patch 0014: older gralloc imports BLOB buffers with a row wider
#         than their stride, which iris rejects (lock(BLOB) fails).
#         Software rendering uses gralloc.default, which handles BLOB
#         buffers in every image.
#   heap: older images when the user can open the heap.
#   off:  no media decoders.
# LEPTON_CODEC2=false forces off; LEPTON_CODEC2=true forces blob (testing).
LEPTON_GBM_NO_MAP_MARKER='lepton-gbm-allocator-no-map-probe'
LEPTON_GBM_BLOB_CPU_SURFACE_MARKER='lepton-gbm-blob-cpu-surface'
# lepton_image_has_marker LIB MARKER: the library Android loads (overlay
# first, then the rootfs) contains MARKER.
function lepton_image_has_marker()
{
    local LIB="$1" MARKER="$2" FILE
    for FILE in "${LEPTON_DIR}/../images/rootfs_overlay/${LIB}" \
                "${LEPTON_TEST_ROOTFS:-${LEPTON_DIR}/../images/rootfs}/${LIB}"; do
        if [[ -f "${FILE}" ]]; then
            grep -qaF "${MARKER}" -- "${FILE}"
            return
        fi
    done
    return 1
}
function lepton_gralloc_blob_safe()
{
    [[ "${LEPTON_FORCE_SOFTWARE:-}" == "true" ]] && return 0
    local HAL
    HAL="$(lepton_vulkan_hal)"
    [[ "${HAL}" == radeon || "${HAL}" == intel ]] || return 1
    lepton_image_has_marker vendor/lib64/libgbm_mesa_wrapper.so "${LEPTON_GBM_NO_MAP_MARKER}" || return 1
    [[ "${HAL}" == radeon ]] && return 0
    lepton_image_has_marker vendor/lib64/libminigbm_gralloc_gbm_mesa.so "${LEPTON_GBM_BLOB_CPU_SURFACE_MARKER}"
}
function lepton_codec2_mode()
{
    if [[ "$(uname -m)" != "x86_64" || "$(android_sdk_version)" -lt 34 || "${LEPTON_CODEC2:-auto}" == false ]]; then
        print off
    elif [[ "${LEPTON_CODEC2:-auto}" == true ]] || lepton_gralloc_blob_safe; then
        print blob
    elif lepton_dma_heap_usable; then
        print heap
    else
        print off
    fi
}

# Host DMA-BUF system heap (older images only). Overridable for tests.
function lepton_dma_heap_device() { print "${LEPTON_DMA_HEAP_DEVICE:-/dev/dma_heap/system}"; }
function lepton_dma_heap_usable()
{
    local DEVICE="$(lepton_dma_heap_device)"
    [[ "$(uname -m)" == "x86_64" && -c "${DEVICE}" && -r "${DEVICE}" && -w "${DEVICE}" ]]
}
# Diagnostics only: why the heap is unusable. Without it Codec2 stays off and
# Android 14 x86_64 has no media decoders, so apps that play music or video
# (MediaPlayer, ExoPlayer, WebView) are silent, while games that mix their own
# PCM are not. Says which, so a silent media app can be traced to the host.
function lepton_dma_heap_problem()
{
    local DEVICE
    DEVICE="$(lepton_dma_heap_device)"
    if [[ ! -e "${DEVICE}" ]]; then
        print "${DEVICE} does not exist on this host"
    elif [[ ! -c "${DEVICE}" ]]; then
        print "${DEVICE} is not a character device"
    elif [[ ! -r "${DEVICE}" || ! -w "${DEVICE}" ]]; then
        print "${DEVICE} is not readable and writable by $(id -un) ($(stat -c '%U:%G %A' -- "${DEVICE}" 2>/dev/null || print 'owner unknown'))"
    fi
}

# Hardware video decoding (experimental): the image's Codec2 FFmpeg service
# decodes video with VA-API on the GPU gralloc uses (gralloc.gbm.device).
# Off by default: the service then lists no components and Android's own
# codecs are unchanged. LEPTON_VIDEO_HWACCEL=true ranks FFmpeg's video
# decoders (256) ahead of Android's software ones (512); FFmpeg's audio
# decoders stay off. Needs hardware rendering and Codec2 (not mode off).
LEPTON_FFMPEG_RANK_DISABLED=4294967295
# lepton_video_va_driver: the image's VA-API drivers for the selected GPU, in
# the order libva tries them (vendor/lib64, overlay first), or nothing.
# Intel: iHD (Gen 8 and newer), then i965 (Gen 4 to 9.5); AMD: Mesa's radeonsi.
function lepton_video_va_driver()
{
    local LIB FILE FOUND=()
    local -a LIBS
    case "$(lepton_vulkan_hal)" in
        intel) LIBS=(iHD_drv_video.so i965_drv_video.so) ;;
        radeon) LIBS=(radeonsi_drv_video.so) ;;
        *) return 1 ;;
    esac
    for LIB in "${LIBS[@]}"; do
        for FILE in "${LEPTON_DIR}/../images/rootfs_overlay/vendor/lib64/${LIB}" \
                    "${LEPTON_TEST_ROOTFS:-${LEPTON_DIR}/../images/rootfs}/vendor/lib64/${LIB}"; do
            [[ -f "${FILE}" ]] && { FOUND+=("${LIB}"); break; }
        done
    done
    ((${#FOUND[@]})) || return 1
    print "${FOUND[*]}"
}
function lepton_video_hwaccel_mode()
{
    if [[ "${LEPTON_VIDEO_HWACCEL:-false}" != true ]]; then
        print off
    elif [[ "$(uname -m)" != x86_64 || "$(android_sdk_version)" -lt 34 ]]; then
        print unsupported
    elif [[ "${LEPTON_FORCE_SOFTWARE:-}" == true ]]; then
        print no-gpu
    elif [[ "$(lepton_codec2_mode)" == off ]]; then
        print no-codec2
    elif ! lepton_video_va_driver >/dev/null; then
        # FFmpeg would decode in software instead of Android's decoders.
        print no-driver
    else
        print vaapi
    fi
}
function lepton_video_hwaccel_props()
{
    local MODE
    MODE="$(lepton_video_hwaccel_mode)"
    if [[ "${MODE}" == vaapi ]]; then
        props_echo "debug.ffmpeg-codec2.rank=256"
        props_echo "debug.ffmpeg-codec2.rank.video=256"
        props_echo "debug.ffmpeg-codec2.rank.audio=${LEPTON_FFMPEG_RANK_DISABLED}"
        props_echo "media.sf.hwaccel=1"
        # Copy-back: FFmpeg decodes into its own VA surfaces and the frames
        # are copied into Android's buffers. The service's DRM PRIME mode
        # (zero-copy, its default) fails to create VA surfaces on i965.
        props_echo "debug.ffmpeg-codec2.hwaccel.drm=false"
        println "Hardware video decoding (VA-API, experimental): on, $(lepton_video_va_driver) using $(lepton_gpu_render_node 2>/dev/null || print 'the default render node')"
    else
        props_echo "debug.ffmpeg-codec2.rank=${LEPTON_FFMPEG_RANK_DISABLED}"
        props_echo "media.sf.hwaccel=0"
        case "${MODE}" in
            unsupported) println "Hardware video decoding: LEPTON_VIDEO_HWACCEL needs Android 14 x86_64; off" ;;
            no-gpu) println "Hardware video decoding: off with software rendering (LEPTON_FORCE_SOFTWARE)" ;;
            no-codec2) println "Hardware video decoding: off because Android's media decoders (Codec2) are off" ;;
            no-driver) println "Hardware video decoding: off; this image has no VA-API driver for the $(lepton_vulkan_hal) GPU" ;;
        esac
    fi
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
    local CODEC2_MODE
    CODEC2_MODE="$(lepton_codec2_mode)"
    case "${CODEC2_MODE}" in
        blob)
            # Valve's upstream mask: BUFFERQUEUE, BLOB and newer allocators,
            # never ION/DMA-BUF heap, so no host device is needed.
            props_echo "debug.stagefright.ccodec=4"
            props_echo "debug.stagefright.c2-poolmask=0xfc0000"
            ;;
        heap)
            # Linear buffers from the host DMA-BUF heap (mounted in setup).
            props_echo "debug.stagefright.ccodec=4"
            ;;
        *)
            props_echo "debug.stagefright.ccodec=0"
            if [[ "$(uname -m)" == "x86_64" && "$(android_sdk_version)" -ge 34 ]]; then
                if [[ "${LEPTON_CODEC2:-auto}" == false ]]; then
                    println "Android media decoders (Codec2): off (LEPTON_CODEC2=false); music and video apps will be silent"
                elif [[ "$(lepton_vulkan_hal)" == intel ]]; then
                    println "Android media decoders (Codec2): off: on Intel graphics this Android image needs host heap access for them, and $(lepton_dma_heap_problem); music and video apps will be silent, games' own audio is unaffected. Images with patches 0013 and 0014 need no host access."
                else
                    println "Android media decoders (Codec2): off: this Android image needs host heap access for them, and $(lepton_dma_heap_problem); music and video apps will be silent, games' own audio is unaffected. Images with patch 0013 need no host access."
                fi
            fi
            ;;
    esac
    lepton_video_hwaccel_props

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
            # x86_64: ANGLE for EGL/GLES, RADV (AMD) or ANV (Intel) for
            # Vulkan, generic minigbm.
            props_echo "ro.hardware.egl=angle"
            props_echo "ro.hardware.vulkan=$(lepton_vulkan_hal)"
            props_echo "ro.hardware.gralloc=minigbm_gbm_mesa"
            # minigbm otherwise opens the first render node it finds.
            local render_node
            render_node="$(lepton_gpu_render_node)"
            [[ -z "${render_node}" ]] || props_echo "gralloc.gbm.device=${render_node}"
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
