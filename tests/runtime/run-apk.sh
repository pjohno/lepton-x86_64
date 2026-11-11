#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Run the same JNI smoke APK against either a known-good x86_64 Lepton stage
# or an experimental NDK-enabled stage without using the host Podman store.
set -Eeuo pipefail

MODE=--check
STAGE=''
APK=''
EXPECT_ABI=''
TIMEOUT=180
APP_MODE=false
MEDIA_SMOKE=false
RENDERING=software
DISPLAY_MODE=headless
OBSERVE_SECONDS=20
UNTIL_EXIT=false
NDK_AUXV_SHIM=''
RUNTIME_SOURCE=''
SERVICES_JAR=''
SCRIPT_DIR="$(dirname -- "$(realpath -e -- "${BASH_SOURCE[0]}")")"
RENDERING_SET=false
DISPLAY_SET=false
GPU_CHECK=false
APK_PREFLIGHT_DIR=''
APKM=false
NETWORK_SYSCTLS=false
CODEC2=false
PROFILE=''
SETUP_ONLY=false
FRESH_PROFILE=true
ACCEPT_RUNTIME_UPDATE=false

usage() {
    cat <<'HELP'
Usage: bash tests/runtime/run-apk.sh [--stage-dir DIR] --apk FILE --expect-abi x86_64|arm64-v8a [--check|--execute] [--timeout SECONDS]
       bash tests/runtime/run-apk.sh [--stage-dir DIR] --gpu-check [--check|--execute]

Without --stage-dir, an installed bundle is used: the one containing this
script, else ~/.config/lepton-x86_64/default.env. Installed bundles default to
--rendering amd --display desktop (from the env file) and --expect-abi x86_64.

--gpu-check boots Android without an APK and verifies that ANGLE is running on
the expected driver (RADV for --rendering amd, SwiftShader for software).

For a regular game APK, add --app. Optional game/debug settings:
  --apk FILE                 Single APK or APKMirror .apkm bundle (app mode)
  --rendering software|amd    Android graphics driver (default software)
  --display headless|desktop  Headless Weston or current Wayland desktop
  --seconds N                Observe the game for N seconds (default 20)
  --until-exit               Keep an app session open until it exits or is stopped
  --media-smoke              Require offline audio/video decode and video rendering markers
  --ndk-auxv-shim FILE        Preload experimental guest auxv compatibility shim
  --services-jar FILE        Overlay experimental services.jar without changing the stage
  --runtime-dir DIR          Test updated compat_tool scripts with stage images/sysbake
  --codec2                  Enable experimental Codec2/gralloc media allocation
  --network-sysctls          Allow netd sysctl writes in the private network namespace
  --profile NAME             Reuse private Android data; install only changed APKs
  --setup-only               Boot a profile for registration/sign-in; no APK required
  --accept-runtime-update    Explicitly retain a profile across a framework update
App mode records all logcat buffers, package/activity diagnostics and a screenshot.
It checks process survival, which does not prove rendering or gameplay works.

--check    Read-only preflight; neither source stage nor Podman is changed.
--execute  Copy launcher and sysbake data into a private workspace, reference
           existing rootfs read-only, boot Android, and install APK.
           JNI mode asserts LEPTON_JNI_SMOKE_PASS value=42 in logcat.
           App mode checks launch status and watches for crashes/process exit.

Does not use the host's default Podman graphroot/runroot, modify the source
rootfs/sysbake, or deploy to Steam Deck. Work/logs remain under DIR after test.
HELP
}
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }
pass() { printf '[PASS] %s\n' "$*"; }
while (($#)); do
    case "$1" in
        --check|--execute) MODE="$1"; shift ;;
        --stage-dir) (($# >= 2)) || fail '--stage-dir requires path'; STAGE="$2"; shift 2 ;;
        --apk) (($# >= 2)) || fail '--apk requires file'; APK="$2"; shift 2 ;;
        --expect-abi) (($# >= 2)) || fail '--expect-abi requires name'; EXPECT_ABI="$2"; shift 2 ;;
        --timeout) (($# >= 2)) || fail '--timeout requires integer'; TIMEOUT="$2"; shift 2 ;;
        --app) APP_MODE=true; shift ;;
        --until-exit) UNTIL_EXIT=true; shift ;;
        --media-smoke) APP_MODE=true; MEDIA_SMOKE=true; shift ;;
        --network-sysctls) NETWORK_SYSCTLS=true; shift ;;
        --codec2) CODEC2=true; shift ;;
        --profile) PROFILE="${2:?}"; shift 2 ;;
        --setup-only) SETUP_ONLY=true; shift ;;
        --gpu-check) GPU_CHECK=true; shift ;;
        --accept-runtime-update) ACCEPT_RUNTIME_UPDATE=true; shift ;;
        --rendering) (($# >= 2)) || fail '--rendering requires mode'; RENDERING="$2"; RENDERING_SET=true; shift 2 ;;
        --display) (($# >= 2)) || fail '--display requires mode'; DISPLAY_MODE="$2"; DISPLAY_SET=true; shift 2 ;;
        --seconds) (($# >= 2)) || fail '--seconds requires integer'; OBSERVE_SECONDS="$2"; shift 2 ;;
        --ndk-auxv-shim) (($# >= 2)) || fail '--ndk-auxv-shim requires file'; NDK_AUXV_SHIM="$2"; shift 2 ;;
        --services-jar) SERVICES_JAR="${2:?}"; shift 2 ;;
        --runtime-dir) (($# >= 2)) || fail '--runtime-dir requires directory'; RUNTIME_SOURCE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "Unknown argument: $1" ;;
    esac
done
if [[ -z "$STAGE" ]]; then
    # Installed bundle: this script lives in <install>/tests/runtime.
    env_file="${XDG_CONFIG_HOME:-$HOME/.config}/lepton-x86_64/default.env"
    if [[ -f "$SCRIPT_DIR/../../BUNDLE.json" ]]; then
        STAGE="$(realpath -e -- "$SCRIPT_DIR/../..")"
        tool_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tool_id"])' "$STAGE/BUNDLE.json")"
        env_file="${XDG_CONFIG_HOME:-$HOME/.config}/lepton-x86_64/$tool_id.env"
    fi
    if [[ -f "$env_file" ]]; then
        # Written by lepton-install-bundle (printf %q values).
        # shellcheck source=/dev/null
        source "$env_file"
        STAGE="${STAGE:-${LEPTON_X86_INSTALL_DIR:-}}"
        [[ "$RENDERING_SET" == true ]] || RENDERING="${LEPTON_X86_RENDERING:-amd}"
        [[ "$DISPLAY_SET" == true ]] || DISPLAY_MODE="${LEPTON_X86_DISPLAY:-desktop}"
    elif [[ -n "$STAGE" ]]; then
        [[ "$RENDERING_SET" == true ]] || RENDERING=amd
        [[ "$DISPLAY_SET" == true ]] || DISPLAY_MODE=desktop
    fi
    [[ -n "$STAGE" ]] || fail 'No --stage-dir given and no installed bundle found (run the bundle installer first)'
    [[ -n "$EXPECT_ABI" ]] || EXPECT_ABI=x86_64
    info "Using installed bundle: $STAGE (rendering $RENDERING, display $DISPLAY_MODE)"
fi
if [[ "$GPU_CHECK" == true ]]; then
    [[ -z "$APK" && "$SETUP_ONLY" == false && "$APP_MODE" == false && -z "$PROFILE" ]] ||
        fail '--gpu-check cannot be combined with an APK, --app, --setup-only or --profile'
    EXPECT_ABI="${EXPECT_ABI:-x86_64}"
fi
[[ "$EXPECT_ABI" == x86_64 || "$EXPECT_ABI" == arm64-v8a ]] || fail 'Expected ABI must be x86_64 or arm64-v8a'
[[ "$UNTIL_EXIT" == false || ( "$APP_MODE" == true && "$SETUP_ONLY" == false && "$MEDIA_SMOKE" == false ) ]] || fail '--until-exit requires a regular --app session'
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || fail 'Timeout must be a positive integer'
[[ "$OBSERVE_SECONDS" =~ ^[1-9][0-9]*$ ]] || fail 'Seconds must be a positive integer'
[[ "$RENDERING" == software || "$RENDERING" == amd ]] || fail 'Rendering must be software or amd'
[[ "$DISPLAY_MODE" == headless || "$DISPLAY_MODE" == desktop ]] || fail 'Display must be headless or desktop'
[[ -n "$STAGE" && ( -n "$APK" || "$SETUP_ONLY" == true || "$GPU_CHECK" == true ) ]] || { usage >&2; fail 'Supply stage and APK, --setup-only or --gpu-check'; }
if [[ -n "$PROFILE" ]]; then
    [[ "$PROFILE" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$ ]] || fail 'Invalid profile name'
    [[ "$APP_MODE" == true || "$SETUP_ONLY" == true ]] || fail 'Profiles require --app or --setup-only'
fi
[[ "$SETUP_ONLY" == false || ( -n "$PROFILE" && -z "$APK" ) ]] || fail '--setup-only requires --profile and no APK'
[[ "$ACCEPT_RUNTIME_UPDATE" == false || -n "$PROFILE" ]] || fail '--accept-runtime-update requires --profile'
[[ $(id -u) != 0 ]] || fail 'Run as an ordinary user, without sudo'
[[ $(uname -m) == x86_64 ]] || fail 'x86_64 host required'
STAGE="$(realpath -e -- "$STAGE")" || fail 'Stage not found'
if [[ -n "$APK" ]]; then
    APK="$(realpath -e -- "$APK")" || fail 'APK not found'
    [[ -f "$APK" && ! -L "$APK" ]] || fail 'APK must be a regular file'
    [[ "$APK" != "$STAGE/"* ]] || fail 'Put test APK outside the source stage'
fi
[[ -d "$STAGE" && ! -L "$STAGE" ]] || fail 'Stage must be a real directory'
TOOL="$STAGE/compat_tool"
RUNTIME_SOURCE="$(realpath -e -- "${RUNTIME_SOURCE:-$TOOL}")"
[[ -f "$RUNTIME_SOURCE/lepton" && -f "$RUNTIME_SOURCE/liblepton/mounting.sh" ]] || fail 'Runtime source must be a compat_tool directory'
ROOTFS="$TOOL/images/rootfs"
if [[ -n "$SERVICES_JAR" ]]; then
    SERVICES_JAR="$(realpath -e -- "$SERVICES_JAR")"
    [[ -f "$SERVICES_JAR" ]] || fail 'Services override must be a regular jar'
    unzip -Z1 "$SERVICES_JAR" | grep -Fx 'classes.dex' >/dev/null || fail 'Services override has no DEX'
    [[ ! -e "$ROOTFS/system/framework/oat/x86_64/services.odex" ]] ||
        fail 'Services override requires a stage with stale services dexpreopt artifacts removed'
fi
if [[ -n "$NDK_AUXV_SHIM" ]]; then
    NDK_AUXV_SHIM="$(realpath -e -- "$NDK_AUXV_SHIM")"
    [[ -f "$NDK_AUXV_SHIM" && "$EXPECT_ABI" == arm64-v8a ]] || fail 'Shim requires a regular file and ARM64 guest'
    readelf -h "$NDK_AUXV_SHIM" | grep -F 'Advanced Micro Devices X86-64' >/dev/null || fail 'Shim must be Android x86_64 ELF'
    bridge_sha="$(sha256sum "$ROOTFS/system/lib64/libndk_translation.so")"
    [[ "${bridge_sha%% *}" == a2086fbc807f697f9b91222065c9d9000ca9727748699c0d9b751319258cbb3e ]] || fail 'Compatibility shim requires the reviewed Google API 34 r14 bridge build'
fi
[[ -f "$TOOL/lepton" && -f "$TOOL/liblepton/baking.sh" ]] || fail 'Lepton launcher missing'
[[ -d "$ROOTFS" && -x "$ROOTFS/system/bin/sh" ]] || fail 'Source stage rootfs missing'
[[ -f "$TOOL/sysbake/system/packages.xml" && -f "$TOOL/sysbake.xattrs" ]] || fail 'Source sysbake missing'
if [[ "$RENDERING" == software ]]; then
    [[ -f "$ROOTFS/vendor/lib64/hw/vulkan.pastel.so" ]] || fail 'Software Vulkan driver missing'
    [[ -f "$ROOTFS/vendor/lib64/hw/gralloc.default.so" ]] || fail 'Software gralloc driver missing'
    grep -Fq 'gbm-software-vintf.xml' "$TOOL/liblepton/mounting.sh" || fail 'Stage lacks software GBM HAL masking fix; restage current launcher or use --rendering amd'
else
    [[ -f "$ROOTFS/vendor/lib64/hw/vulkan.radeon.so" ]] || fail 'AMD Vulkan driver missing'
fi
grep -qx 'ro.build.version.sdk=34' "$ROOTFS/system/build.prop" || fail 'Expected Android 14'
[[ -x "$STAGE/tools/bin/inotifywait" ]] || fail 'Staged inotifywait missing'
for tool in rsync podman python3 unzip grep flock realpath mktemp getfattr setfattr fuse-overlayfs systemctl timeout; do
    command -v "$tool" >/dev/null || fail "Missing host tool: $tool"
done
if [[ "$DISPLAY_MODE" == headless ]]; then
    command -v weston >/dev/null || fail 'Missing headless compositor: weston'
fi
cleanup_apk_preflight() {
    if [[ -n "$APK_PREFLIGHT_DIR" ]]; then
        rm -rf -- "$APK_PREFLIGHT_DIR"
        APK_PREFLIGHT_DIR=''
    fi
}
trap cleanup_apk_preflight EXIT
METADATA_APK="$APK"
NATIVE_APKS=("$APK")
if [[ -n "$APK" ]]; then
if [[ "${APK,,}" == *.apkm ]]; then
    [[ "$APP_MODE" == true ]] || fail 'APKM bundles require --app'
    APKM=true
    APK_PREFLIGHT_DIR="$(mktemp -d /tmp/lepton-apkm-preflight.XXXXXXXX)"
    python3 "$SCRIPT_DIR/unpack-apkm.py" "$APK" --abi "$EXPECT_ABI" \
        --output "$APK_PREFLIGHT_DIR/apks" --metadata-only
    METADATA_APK="$APK_PREFLIGHT_DIR/apks/base.apk"
    NATIVE_APKS=("$APK_PREFLIGHT_DIR/apks/"*.apk)
fi
unzip -Z1 "$METADATA_APK" | grep -Fx 'classes.dex' >/dev/null || fail 'Test APK missing classes.dex'
if [[ "$APP_MODE" == true ]]; then
    [[ -x "$RUNTIME_SOURCE/liblepton/apk_extractor/bin/apk-info-extractor" ]] || fail 'APK metadata extractor missing'
    native_found=false
    for native_apk in "${NATIVE_APKS[@]}"; do
        if unzip -Z1 "$native_apk" | grep -E "^lib/$EXPECT_ABI/[^/]+[.]so$" >/dev/null; then native_found=true; fi
    done
    [[ "$native_found" == true ]] || fail "APK set has no native libraries for $EXPECT_ABI (APKM preflight supports conventional split_config ABI names)"
    PACKAGE="$("$RUNTIME_SOURCE/liblepton/apk_extractor/bin/apk-info-extractor" --print-app-id "$METADATA_APK")"
    ACTIVITY="$("$RUNTIME_SOURCE/liblepton/apk_extractor/bin/apk-info-extractor" --print-activity-name "$METADATA_APK")"
    [[ "$PACKAGE" =~ ^[a-zA-Z0-9_.]+$ && "$ACTIVITY" =~ ^[a-zA-Z0-9_.$]+$ ]] || fail 'Invalid package or launch activity metadata'
else
    unzip -Z1 "$APK" | grep -Fx "lib/$EXPECT_ABI/libleptonjni.so" >/dev/null || fail "APK missing lib/$EXPECT_ABI/libleptonjni.so"
fi
fi
if [[ "$EXPECT_ABI" == x86_64 && "$APP_MODE" == false && "$SETUP_ONLY" == false && "$GPU_CHECK" == false ]]; then
    [[ ! -e "$ROOTFS/system/lib64/libndk_translation.so" ]] || fail 'Baseline stage unexpectedly contains NDK translator'
elif [[ "$EXPECT_ABI" == arm64-v8a ]]; then
    [[ -f "$ROOTFS/system/lib64/libndk_translation.so" ]] || fail 'NDK stage missing translator'
fi
RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
[[ "$RUNTIME" == "/run/user/$(id -u)" && -d "$RUNTIME" && -O "$RUNTIME" && -w "$RUNTIME" ]] || fail 'Safe per-user runtime directory unavailable'
info "Mode: $MODE"
info "Source stage: $STAGE"
info "APK: $APK"
info "Expected ABI: $EXPECT_ABI"
info 'Rootfs: read-only source; sysbake: private copied data'
info 'Podman: private graphroot/runroot; no default user store'
if [[ "$DISPLAY_MODE" == desktop ]]; then
    DESKTOP_SOCKET="${GAMESCOPE_WAYLAND_DISPLAY:-${WAYLAND_DISPLAY:-wayland-0}}"
    [[ "$DESKTOP_SOCKET" != */* && -S "$RUNTIME/$DESKTOP_SOCKET" ]] || fail 'Desktop Wayland socket unavailable'
fi
if [[ -n "$PROFILE" ]]; then
    WORK="$STAGE/.runtime-profile.$PROFILE"
    PROFILE_FINGERPRINT="$(
        { printf '%s\n' "$STAGE"; sha256sum "$ROOTFS/system/build.prop" "$ROOTFS/system/framework/services.jar";
          if [[ -n "$SERVICES_JAR" ]]; then
              printf 'services-override %s\n' "$(sha256sum "$SERVICES_JAR" | cut -d' ' -f1)"
          fi
          for marker in "$STAGE/google-services.sha256" "$STAGE/services-experiment.sha256"; do
              [[ ! -f "$marker" ]] || cat "$marker"
          done; } | sha256sum | cut -d' ' -f1
    )"
    if [[ -e "$WORK" || -L "$WORK" ]]; then
        [[ -d "$WORK" && ! -L "$WORK" && -O "$WORK" ]] || fail 'Unsafe profile directory'
        [[ -f "$WORK/profile-fingerprint" ]] || fail 'Profile metadata missing'
        if [[ "$(cat "$WORK/profile-fingerprint")" != "$PROFILE_FINGERPRINT" && "$ACCEPT_RUNTIME_UPDATE" != true ]]; then
            fail 'Runtime changed; use --accept-runtime-update to retain this profile after review'
        fi
        FRESH_PROFILE=false
        if [[ "$SETUP_ONLY" == false && -f "$WORK/profile-package" ]]; then
            [[ "$(cat "$WORK/profile-package")" == "$PACKAGE" ]] || fail 'Profile already belongs to another game'
        fi
    fi
fi
if [[ "$MODE" == --check ]]; then
    pass 'JNI smoke test preflight passed; no test state modified'
    exit 0
fi

if [[ -n "$PROFILE" ]]; then
    if [[ "$FRESH_PROFILE" == true ]]; then
        mkdir -m 700 -- "$WORK"
        printf '%s\n' "$PROFILE_FINGERPRINT" > "$WORK/profile-fingerprint"
    fi
    exec {PROFILE_LOCK}>"$WORK/.lock"
    flock -n "$PROFILE_LOCK" || fail 'Profile already in use'
    if [[ "$(cat "$WORK/profile-fingerprint")" != "$PROFILE_FINGERPRINT" ]]; then
        cp "$WORK/profile-fingerprint" "$WORK/profile-fingerprint.previous"
        printf '%s\n' "$PROFILE_FINGERPRINT" > "$WORK/profile-fingerprint"
    fi
    info "Persistent profile: $PROFILE (Android data retained)"
else
    WORK="$(mktemp -d "$STAGE/.jni-smoke-work.XXXXXXXX")"
fi
# Stages on shared disks may inherit a setgid group outside Podman's mapping.
# Overlay upper/work directories must belong to the mapped primary group.
chgrp "$(id -gn)" "$WORK"
chmod g-s "$WORK"
if [[ -n "$PROFILE" ]]; then
    # Podman records the runroot path in its database; keep that path stable too.
    profile_key="$(printf '%s' "$WORK" | sha256sum | cut -c1-16)"
    RUNROOT="$RUNTIME/lepton-profile-$profile_key"
    [[ ! -L "$RUNROOT" ]] || fail 'Unsafe profile runroot'
    mkdir -p -- "$RUNROOT"
    chmod 700 -- "$RUNROOT"
    [[ -O "$RUNROOT" ]] || fail 'Profile runroot is not owned by current user'
else
    RUNROOT="$(mktemp -d "$RUNTIME/lepton-jni-smoke-run.XXXXXXXX")"
fi
GRAPHROOT="$WORK/podman-storage"
SOCKET="lepton-jni-smoke-$$"
CONTEXT="jnismoke-$$"
[[ -z "$PROFILE" ]] || CONTEXT="profile-$PROFILE"
WESTON_PID=''
LAUNCH_PID=''
LOGCAT_PID=''
cleanup() {
    rc=$?
    trap - EXIT INT TERM
    set +e
    cleanup_apk_preflight
    if [[ -n "$LOGCAT_PID" ]]; then
        kill "$LOGCAT_PID" 2>/dev/null
        wait "$LOGCAT_PID" 2>/dev/null
    fi
    if [[ -n "$LAUNCH_PID" ]]; then
        kill -TERM "$LAUNCH_PID" 2>/dev/null
    fi
    if [[ -x "$WORK/bin/podman" ]]; then
        "$WORK/bin/podman" rm -fi "lepton-$CONTEXT" >/dev/null 2>&1
    fi
    if [[ -n "$LAUNCH_PID" ]]; then
        for ((i=0;i<30;i++)); do
            kill -0 "$LAUNCH_PID" 2>/dev/null || break
            sleep 0.2
        done
        kill -KILL "$LAUNCH_PID" 2>/dev/null || true
        wait "$LAUNCH_PID" 2>/dev/null || true
    fi
    systemctl --user stop "lepton-$CONTEXT.slice" >/dev/null 2>&1 || true
    if [[ -n "$WESTON_PID" ]]; then
        kill "$WESTON_PID" 2>/dev/null
        wait "$WESTON_PID" 2>/dev/null
    fi
    if [[ ( "$RUNROOT" == "$RUNTIME"/lepton-jni-smoke-run.* || "$RUNROOT" == "$RUNTIME"/lepton-profile-* ) && -d "$RUNROOT" ]]; then
        rm -rf -- "$RUNROOT" 2>/dev/null || true
    fi
    if ((rc)); then
        printf '[FAIL] Test failed (%s); logs retained at %s\n' "$rc" "$WORK" >&2
    else
        printf '[INFO] Test logs retained at %s\n' "$WORK"
    fi
    if [[ -n "${PROFILE_LOCK:-}" ]]; then
        flock -u "$PROFILE_LOCK" || true
        exec {PROFILE_LOCK}>&-
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'if [[ "$SETUP_ONLY" == true ]]; then exit 0; else exit 130; fi' INT
trap 'if [[ "$SETUP_ONLY" == true ]]; then exit 0; else exit 143; fi' TERM

if [[ "$APKM" == true && ( ! -f "$WORK/apks-source.sha256" || "$(cat "$WORK/apks-source.sha256")" != "$(sha256sum "$APK" | cut -d' ' -f1)" ) ]]; then
    info 'Extracting base, selected ABI and feature/asset APK splits'
    if [[ -d "$WORK/apks" ]]; then mv "$WORK/apks" "$WORK/apks.previous.$(date +%s)"; fi
    python3 "$SCRIPT_DIR/unpack-apkm.py" "$APK" --abi "$EXPECT_ABI" --output "$WORK/apks"
    sha256sum "$APK" | cut -d' ' -f1 > "$WORK/apks-source.sha256"
fi
cleanup_apk_preflight

mkdir -p "$WORK/bin" "$WORK/tmp" "$WORK/home/.steam" \
         "$WORK/home/.config" "$WORK/home/.local/share/Steam/steamapps" \
         "$WORK/compat_tool/images" "$GRAPHROOT"
touch "$WORK/home/.steam/steam.pipe"
# Never copy/alter the original sysbake or compiled rootfs.
rsync -a --no-owner --no-group --exclude '/images/rootfs' \
      --exclude '/sysbake' --exclude '/sysbake.xattrs' \
      "$RUNTIME_SOURCE/" "$WORK/compat_tool/"
if [[ "$FRESH_PROFILE" == true ]]; then
    ln -s -- "$ROOTFS" "$WORK/compat_tool/images/rootfs"
    cp -a --no-preserve=ownership -- "$TOOL/sysbake" "$WORK/compat_tool/sysbake"
    cp -a -- "$TOOL/sysbake.xattrs" "$WORK/compat_tool/sysbake.xattrs"
fi
if [[ -n "$SERVICES_JAR" ]]; then
    mkdir -p "$WORK/compat_tool/images/rootfs_overlay/system/framework"
    cp -- "$SERVICES_JAR" "$WORK/compat_tool/images/rootfs_overlay/system/framework/services.jar"
    sha256sum "$SERVICES_JAR" > "$WORK/services-override.sha256"
elif [[ -f "$WORK/services-override.sha256" ]]; then
    rm -f -- "$WORK/compat_tool/images/rootfs_overlay/system/framework/services.jar" "$WORK/services-override.sha256"
fi
if [[ -n "$NDK_AUXV_SHIM" ]]; then
    mkdir -p "$WORK/compat_tool/images/rootfs_overlay/system/lib64"
    cp -- "$NDK_AUXV_SHIM" "$WORK/compat_tool/images/rootfs_overlay/system/lib64/liblepton_ndk_auxv.so"
    export LEPTON_ENV_LD_PRELOAD=/system/lib64/liblepton_ndk_auxv.so
    # Explicit shim experiments supply their own overlay instead of auto-mounting.
    export LEPTON_NDK_COMPAT=false
    export LEPTON_ENV_NDK_TRANSLATION_FLAGS="${LEPTON_ENV_NDK_TRANSLATION_FLAGS:-accurate-sigsegv}"
    export LEPTON_ENV_NDK_TRANSLATION_MODE=light-translate-or-interpret
fi
(cd "$WORK/compat_tool" && setfattr -P -h --restore sysbake.xattrs) || fail 'Cannot restore copied sysbake xattrs'

# Same proven, disposable-only launcher adjustments as isolated sysbake.
python3 - "$WORK/compat_tool/lepton" "$WORK/compat_tool/liblepton/utils.sh" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]); s = p.read_text()
for old,new in [
    ('if systemctl --user is-system-running >/dev/null && [[ -z "${CATATONIT_PID}" ]]; then',
     'if [[ "${LEPTON_ISOLATED_SYSBAKE:-0}" != "1" ]] && systemctl --user is-system-running >/dev/null && [[ -z "${CATATONIT_PID}" ]]; then'),
]:
    if s.count(old) != 1: raise SystemExit(f'Unsafe launcher patch count: {old!r}')
    s = s.replace(old,new,1)
# Older stages still need a disposable-only lock-path migration. Current
# launchers validate the private override directly; do not patch them twice.
legacy_lock = 'exec {LEPTON_LOCKFD}>/tmp/lepton.lock'
if s.count(legacy_lock) == 1:
    s = s.replace(legacy_lock, 'exec {LEPTON_LOCKFD}>"${LEPTON_LOCK_PATH:?Isolated lock path required}"', 1)
elif s.count('function lepton_open_lock()') != 1:
    raise SystemExit('Unrecognized launcher lock implementation; refresh the stage launcher')
p.write_text(s)
p = Path(sys.argv[2]); s = p.read_text()
old='function wait_for_file()\n{\n'
new='function wait_for_file()\n{\n    if [[ "${LEPTON_ISOLATED_SYSBAKE:-0}" == "1" ]]; then\n        while [[ ! -e "${1}" ]]; do sleep 0.25; done\n        return 0\n    fi\n'
if s.count(old) != 1: raise SystemExit('Unsafe wait_for_file patch count')
p.write_text(s.replace(old,new,1))
PY
bash -n "$WORK/compat_tool/lepton"

PODMAN_BIN="$(command -v podman)"
FUSE_OVERLAY_BIN="$(command -v fuse-overlayfs)"
{
    printf '#!/bin/bash\n'
    printf 'unset CONTAINER_HOST CONTAINER_CONNECTION PODMAN_CONNECTION\n'
    printf 'export HOME=%q XDG_RUNTIME_DIR=%q\n' "$WORK/home" "$RUNTIME"
    printf 'exec %q --root=%q --runroot=%q --storage-driver=overlay --storage-opt=%q "$@"\n' \
           "$PODMAN_BIN" "$GRAPHROOT" "$RUNROOT" "overlay.mount_program=$FUSE_OVERLAY_BIN"
} > "$WORK/bin/podman"
chmod 755 "$WORK/bin/podman"

export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config" XDG_DATA_HOME="$WORK/home/.local/share"
export PATH="$WORK/bin:$STAGE/tools/bin:/usr/bin:/bin" XDG_RUNTIME_DIR="$RUNTIME"
export GAMESCOPE_WAYLAND_DISPLAY="$SOCKET" LEPTON_ISOLATED_SYSBAKE=1
export LEPTON_LOCK_PATH="$WORK/lock"
LEPTON_FORCE_SOFTWARE=false
[[ "$RENDERING" != software ]] || LEPTON_FORCE_SOFTWARE=true
export LEPTON_FORCE_SOFTWARE
export LEPTON_ALLOW_KMSG=false LEPTON_GAMEPAD_PASSTHROUGH=false
export LEPTON_NO_PORT_FORWARDING=true TERM=dumb TMPDIR="$WORK/tmp"
export LEPTON_NO_DEBUG_PORTS=true
export LEPTON_NETWORK_SYSCTLS="$NETWORK_SYSCTLS"
# Default: Lepton decides (Codec2 for audio when the DMA heap is usable).
if [[ "$CODEC2" == true ]]; then export LEPTON_CODEC2=true; else unset LEPTON_CODEC2; fi
if [[ -n "$PROFILE" ]]; then export LEPTON_NO_CLEANUP=true; fi
unset SteamAppId STEAM_COMPAT_INSTALL_PATH STEAM_COMPAT_DATA_PATH
if [[ -n "$PROFILE" ]]; then
    # Use the normal persistent external-storage layout as well as /data.
    export STEAM_COMPAT_DATA_PATH="$WORK/compatdata"
    export STEAM_COMPAT_LIBRARY_PATHS="$WORK/compatdata"
    export LEPTON_PROFILE_EXTERNAL_STORAGE=/lepton/profile-external
    mkdir -p "$STEAM_COMPAT_DATA_PATH"
    # Android leaves this host-owned upper directory at 0550 after shutdown.
    # The launcher must be able to replace its external-storage symlink again.
    if [[ -d "$WORK/compatdata/baked/data_overlay/media" ]]; then
        chmod u+rwx -- "$WORK/compatdata/baked/data_overlay/media"
    fi
    if [[ -f "$WORK/profile-code-path" ]]; then
        LEPTON_PROFILE_CODE_PATH="$(cat "$WORK/profile-code-path")"
        export LEPTON_PROFILE_CODE_PATH
    fi
fi
unset CONTAINER_HOST CONTAINER_CONNECTION PODMAN_CONNECTION

[[ "$(realpath -m "$(podman info --format '{{.Store.GraphRoot}}')")" == "$(realpath -m "$GRAPHROOT")" ]] || fail 'Podman graphroot not isolated'
[[ "$(realpath -m "$(podman info --format '{{.Store.RunRoot}}')")" == "$(realpath -m "$RUNROOT")" ]] || fail 'Podman runroot not isolated'
pass 'Podman graphroot/runroot isolation verified'

if [[ "$DISPLAY_MODE" == headless ]]; then
weston --no-config --backend=headless --renderer=pixman --socket="$SOCKET" --log="$WORK/weston.log" &
WESTON_PID=$!
ready=false
for ((i=0;i<50;i++)); do
    if [[ -S "$RUNTIME/$SOCKET" ]] && kill -0 "$WESTON_PID" 2>/dev/null; then ready=true; break; fi
    sleep .2
done
[[ "$ready" == true ]] || fail 'Headless Weston unavailable'
pass 'Headless Weston ready'
else
    export GAMESCOPE_WAYLAND_DISPLAY="$DESKTOP_SOCKET"
    pass "Using desktop Wayland socket: $DESKTOP_SOCKET"
fi

# Unique context avoids touching an existing Lepton dev container or context.
(
    cd "$WORK/compat_tool"
    ./lepton start "$CONTEXT"
) > "$WORK/lepton.log" 2>&1 &
LAUNCH_PID=$!

container="lepton-$CONTEXT"
deadline=$((SECONDS + TIMEOUT))
info "Waiting for Android boot: $container"
while ((SECONDS < deadline)); do
    if podman container exists "$container"; then
        state="$(podman inspect --format '{{.State.Status}}' "$container" 2>/dev/null || true)"
        if [[ "$state" == exited || "$state" == stopped ]]; then
            podman inspect "$container" > "$WORK/container.json" 2>/dev/null || true
            podman logs "$container" > "$WORK/container.log" 2>&1 || true
            tail -n 70 "$WORK/lepton.log" >&2
            fail "Android container exited before boot; see $WORK/boot-logcat.log"
        fi
        if [[ "$state" == running ]]; then
            podman exec "$container" /system/bin/logcat -d -b all > "$WORK/boot-logcat.tmp" 2>/dev/null || true
            [[ ! -s "$WORK/boot-logcat.tmp" ]] || mv "$WORK/boot-logcat.tmp" "$WORK/boot-logcat.log"
        fi
        status="$(podman exec "$container" /system/bin/getprop sys.boot_completed 2>/dev/null || true)"
        [[ "$status" == 1 ]] && break
    fi
    if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
        tail -n 70 "$WORK/lepton.log" >&2
        fail 'Lepton launcher exited before Android completed boot'
    fi
    sleep 1
done
[[ "${status:-}" == 1 ]] || { tail -n 70 "$WORK/lepton.log" >&2; fail "Android did not boot within ${TIMEOUT}s"; }
pass 'Android reported sys.boot_completed=1'

for name in ro.product.cpu.abilist ro.product.cpu.abilist64 ro.dalvik.vm.native.bridge; do
    value="$(podman exec "$container" /system/bin/getprop "$name" 2>/dev/null | tr -d '\r')"
    info "$name=$value"
done
abi_list="$(podman exec "$container" /system/bin/getprop ro.product.cpu.abilist 2>/dev/null | tr -d '\r')"
[[ ",$abi_list," == *",$EXPECT_ABI,"* ]] || fail "Running Android does not advertise expected ABI $EXPECT_ABI"

info 'Waiting for package manager readiness'
while ((SECONDS < deadline)); do
    if podman exec "$container" /system/bin/sh -c 'pm path android >/dev/null 2>&1 && settings get global airplane_mode_on >/dev/null 2>&1'; then break; fi
    sleep 1
done
((SECONDS < deadline)) || fail 'Android package manager not ready'

podman exec "$container" /system/bin/pm list packages > "$WORK/installed-packages-before.txt"
podman exec "$container" /system/bin/getprop > "$WORK/properties.txt"
podman exec "$container" /system/bin/service list > "$WORK/services.txt"
podman exec "$container" /system/bin/dumpsys connectivity > "$WORK/connectivity.txt"
podman exec "$container" /system/bin/ip address > "$WORK/ip-address.txt"
# Record which graphics stack Android actually selected.
podman exec "$container" /system/bin/dumpsys SurfaceFlinger > "$WORK/surfaceflinger.txt" 2>&1 || true
gles_line="$(grep -m1 '^GLES:' "$WORK/surfaceflinger.txt" || true)"
info "Graphics: ${gles_line:-<no GLES line in dumpsys SurfaceFlinger>}"
for name in ro.hardware.egl ro.hardware.vulkan ro.hardware.gralloc; do
    info "$name=$(grep -F "[$name]" "$WORK/properties.txt" | sed 's/.*: \[\(.*\)\]/\1/')"
done
if [[ "$GPU_CHECK" == true ]]; then
    if [[ "$RENDERING" == amd ]]; then
        [[ "$gles_line" == *RADV* ]] || fail "ANGLE is not running on AMD RADV; see $WORK/surfaceflinger.txt"
        pass 'Hardware acceleration: ANGLE on Vulkan/RADV'
    else
        [[ "$gles_line" == *SwiftShader* ]] || fail "Expected SwiftShader software rendering; see $WORK/surfaceflinger.txt"
        pass 'Software rendering: ANGLE on SwiftShader'
    fi
    exit 0
fi
if [[ "$SETUP_ONLY" == true ]]; then
    info "Setup profile ready for ${OBSERVE_SECONDS}s; no game installed"
    podman exec "$container" /system/bin/logcat -b all > "$WORK/setup-logcat.log" 2>&1 &
    LOGCAT_PID=$!
    if podman exec "$container" /system/bin/pm path com.android.vending | grep '^package:' >/dev/null; then
        podman exec "$container" /system/bin/am start -a android.intent.action.MAIN \
            -c android.intent.category.LAUNCHER -p com.android.vending > "$WORK/setup-activity.log" 2>&1 || true
    else
        podman exec "$container" /system/bin/am start -a android.settings.SETTINGS > "$WORK/setup-activity.log" 2>&1 || true
    fi
    for ((i=0;i<OBSERVE_SECONDS;i++)); do
        if [[ ! -s "$WORK/gsf-android-id.txt" ]] && ((i % 5 == 0)); then
            podman unshare python3 "$SCRIPT_DIR/read-gsf-id.py" \
                "$WORK/compatdata/baked/data_overlay/data/com.google.android.gsf/databases/gservices.db" \
                > "$WORK/gsf-android-id.txt" 2> "$WORK/gsf-id-error.log" || true
            if [[ "$(cat "$WORK/gsf-android-id.txt")" == 0 ]]; then : > "$WORK/gsf-android-id.txt"; fi
            if [[ -s "$WORK/gsf-android-id.txt" ]]; then
                info "GSF Android ID: $(cat "$WORK/gsf-android-id.txt")"
                info 'For uncertified-device registration: https://www.google.com/android/uncertified/'
            fi
        fi
        sleep 1
    done
    pass "Setup finished; Android identity and account data retained in $WORK"
    exit 0
fi
APK_SIGNATURE="$(sha256sum "$APK" | cut -d' ' -f1):$EXPECT_ABI"
if [[ "$APP_MODE" == true ]]; then
    # Match the normal installer: tell Lepton exactly which package its hook is
    # handling instead of inferring it from install timestamps or UID listings.
    podman exec "$container" /system/bin/setprop lepton.active_app_id "$PACKAGE"
fi
REUSE_INSTALL=false
if [[ -n "$PROFILE" && -f "$WORK/installed-apk.signature" && "$(cat "$WORK/installed-apk.signature")" == "$APK_SIGNATURE" ]]; then
    if podman exec "$container" /system/bin/pm path "$PACKAGE" | grep '^package:' >/dev/null; then
        REUSE_INSTALL=true
    fi
fi
podman exec "$container" /system/bin/mkdir -p /data/local/tmp
if [[ "$REUSE_INSTALL" == true ]]; then
    info 'Reusing installed APK set; package installation skipped'
    echo 'Success' > "$WORK/install.log"
else
info 'Installing APK'
if [[ "$APKM" == true ]]; then
    podman cp "$WORK/apks" "$container:/data/local/tmp/lepton-apks"
    timeout --foreground "${TIMEOUT}s" podman exec "$container" /system/bin/pm install-create -r -g --abi "$EXPECT_ABI" > "$WORK/install-session.log"
    session_result="$(cat "$WORK/install-session.log")"
    [[ "$session_result" =~ \[([0-9]+)\] ]] || fail "Cannot create install session: $session_result"
    session_id="${BASH_REMATCH[1]}"
    for split_apk in "$WORK/apks/"*.apk; do
        split_name="${split_apk##*/}"
        timeout --foreground "${TIMEOUT}s" podman exec "$container" /system/bin/pm install-write \
            "$session_id" "$split_name" "/data/local/tmp/lepton-apks/$split_name" >> "$WORK/install-session.log"
    done
    timeout --foreground "${TIMEOUT}s" podman exec "$container" /system/bin/pm install-commit "$session_id" | tee "$WORK/install.log"
else
    podman cp "$APK" "$container:/data/local/tmp/lepton-smoke.apk"
    timeout --foreground "${TIMEOUT}s" podman exec "$container" /system/bin/pm install -r -g --abi "$EXPECT_ABI" /data/local/tmp/lepton-smoke.apk | tee "$WORK/install.log"
fi
grep -qx 'Success' "$WORK/install.log" || fail 'Android package installation failed'
if [[ -n "$PROFILE" ]]; then
    printf '%s\n' "$APK_SIGNATURE" > "$WORK/installed-apk.signature"
    printf '%s\n' "$PACKAGE" > "$WORK/profile-package"
fi
fi
if [[ "$APP_MODE" == true ]]; then
    # Android's runtime-permission prompts open in a separate screen that the
    # game window does not show. Grant what the app requests (also for apps
    # installed earlier without -g); failures are harmless and ignored.
    podman exec "$container" /system/bin/dumpsys package "$PACKAGE" > "$WORK/permissions-before.txt" 2>&1 || true
    while read -r permission; do
        podman exec "$container" /system/bin/pm grant "$PACKAGE" "$permission" > /dev/null 2>&1 || true
    done < <(sed -n 's/^ *\([A-Za-z0-9_.]*\): granted=false.*/\1/p' "$WORK/permissions-before.txt" | sort -u)
    podman exec "$container" /system/bin/pm path "$PACKAGE" > "$WORK/apk-paths.txt"
    if [[ -n "$PROFILE" ]]; then
        sed -n 's|^package:\(.*\)/base\.apk$|\1|p' "$WORK/apk-paths.txt" > "$WORK/profile-code-path"
    fi
    duration="for ${OBSERVE_SECONDS}s"
    [[ "$UNTIL_EXIT" == false ]] || duration='until exit or stop'
    info "Launching $PACKAGE/$ACTIVITY $duration"
    podman exec "$container" /system/bin/logcat -c
    podman exec "$container" /system/bin/logcat -b all > "$WORK/app-logcat.log" 2>&1 &
    LOGCAT_PID=$!
    launch_ok=true
    timeout --foreground 30s podman exec "$container" /system/bin/am start -W \
        -a android.intent.action.MAIN -c android.intent.category.LAUNCHER \
        -n "$PACKAGE/$ACTIVITY" > "$WORK/activity.log" 2>&1 || launch_ok=false
    # Keep mapped-library evidence alongside the requested/installed ABI.
    # The bridge itself can be inherited from zygote even by native apps.
    # shellcheck disable=SC2016
    timeout --foreground 10s podman exec "$container" /system/bin/sh -c \
        'for pid in $(pidof "$1"); do cat /proc/"$pid"/maps; done' sh "$PACKAGE" \
        > "$WORK/app-maps.txt" 2> "$WORK/app-maps-error.log" || true
    app_alive=true
    app_crashed=false
    i=0
    while [[ "$UNTIL_EXIT" == true ]] || ((i<OBSERVE_SECONDS)); do
        if ! timeout --foreground 10s podman exec "$container" /system/bin/pidof "$PACKAGE" > "$WORK/app-pid.txt" 2>/dev/null; then app_alive=false; break; fi
        if grep -Fq ">>> $PACKAGE <<<" "$WORK/app-logcat.log"; then app_alive=false; app_crashed=true; break; fi
        if grep -Fq "Process: $PACKAGE, PID:" "$WORK/app-logcat.log"; then app_alive=false; app_crashed=true; break; fi
        sleep 1
        i=$((i+1))
    done
    if grep -Fq ">>> $PACKAGE <<<" "$WORK/app-logcat.log" || grep -Fq "Process: $PACKAGE, PID:" "$WORK/app-logcat.log"; then
        app_crashed=true
    fi
    timeout --foreground 10s podman exec "$container" /system/bin/dumpsys package "$PACKAGE" > "$WORK/package.txt" 2>&1 || true
    timeout --foreground 10s podman exec "$container" /system/bin/dumpsys activity activities > "$WORK/activities.txt" 2>&1 || true
    # Expansion is intentionally performed inside the Android shell.
    # shellcheck disable=SC2016
    timeout --foreground 10s podman exec "$container" /system/bin/sh -c \
        'pid=$(pidof "$1"); [ -n "$pid" ] && debuggerd -b "$pid"' sh "$PACKAGE" > "$WORK/native-stacks.txt" 2>&1 || true
    timeout --foreground 10s podman exec "$container" /system/bin/screencap -p /data/local/tmp/screen.png 2> "$WORK/screenshot-error.log" &&
        podman cp "$container:/data/local/tmp/screen.png" "$WORK/screen.png" || true
    cat "$WORK/activity.log"
    [[ "$launch_ok" == true ]] || fail "Activity launch command timed out/failed; see $WORK/native-stacks.txt"
    [[ "$app_crashed" == false && ( "$app_alive" == true || "$UNTIL_EXIT" == true ) ]] || fail "App process exited; see $WORK/app-logcat.log"
    grep -Fq "primaryCpuAbi=$EXPECT_ABI" "$WORK/package.txt" || fail 'Installed package ABI differs from requested ABI; inspect package.txt'
    grep -q '^Status: ok' "$WORK/activity.log" || fail "Activity did not finish launching; see $WORK/activity.log and app-logcat.log"
    if [[ "$MEDIA_SMOKE" == true ]]; then
        grep -Fq 'LEPTON_MEDIA_SMOKE_PASS ' "$WORK/app-logcat.log" || fail 'Offline media decode failed; inspect app-logcat.log'
        grep -Fq 'LEPTON_MEDIA_VIDEO_RENDERING_START' "$WORK/app-logcat.log" || fail 'Video surface did not start rendering'
        pass 'Offline AVC/Vorbis decode and video surface rendering verified'
    fi
    if [[ "$UNTIL_EXIT" == true ]]; then
        pass 'App session ended; logs retained for review'
    else
        pass "App process survived ${OBSERVE_SECONDS}s; inspect screen.png and app-logcat.log for rendering/gameplay"
    fi
    exit 0
fi
info 'Launching JNI smoke activity'
timeout --foreground 30s podman exec "$container" /system/bin/am start -W -n org.lepton.smoke/.MainActivity > "$WORK/activity.log" 2>&1 || { cat "$WORK/activity.log" >&2; fail 'Activity launch failed'; }

found=false
for ((i=0;i<45;i++)); do
    podman exec "$container" /system/bin/logcat -d -v brief -s LeptonJniSmoke:V AndroidRuntime:E > "$WORK/jni-logcat.log" 2>&1 || true
    if grep -Fq 'LEPTON_JNI_SMOKE_PASS value=42' "$WORK/jni-logcat.log"; then found=true; break; fi
    if grep -Fq 'LEPTON_JNI_SMOKE_FAIL' "$WORK/jni-logcat.log"; then break; fi
    sleep 1
done
if [[ "$found" == true ]]; then
    grep -F 'LEPTON_JNI_SMOKE_PASS value=42' "$WORK/jni-logcat.log" | tail -n 5
    pass "$EXPECT_ABI native JNI executed on Lepton: value=42"
else
    cat "$WORK/activity.log" >&2
    tail -n 80 "$WORK/jni-logcat.log" >&2
    fail "$EXPECT_ABI JNI result not observed"
fi
