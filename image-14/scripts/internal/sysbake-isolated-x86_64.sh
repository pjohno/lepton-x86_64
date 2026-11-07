#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Create Android 14 sysbake with private Podman storage and a headless compositor.
# This script never invokes the destructive upstream CI sysbake wrapper.
set -Eeuo pipefail

MODE=--check
STAGE=
TIMEOUT=600
RENDERING=software
usage() {
    echo "Usage: $0 [--check|--execute] --stage-dir ABSOLUTE_PATH [--timeout SECONDS] [--rendering software|amd]"
}
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }
pass() { printf '[PASS] %s\n' "$*"; }
while (( $# )); do
    case "$1" in
        --check|--execute) MODE="$1"; shift ;;
        --stage-dir) (( $# >= 2 )) || fail '--stage-dir requires a value'; STAGE="$2"; shift 2 ;;
        --timeout) (( $# >= 2 )) || fail '--timeout requires a value'; TIMEOUT="$2"; shift 2 ;;
        --rendering) (( $# >= 2 )) || fail '--rendering requires a value'; RENDERING="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "Unknown argument: $1" ;;
    esac
done
[[ "$RENDERING" == software || "$RENDERING" == amd ]] || fail "Unknown rendering mode: $RENDERING"
[[ -n "$STAGE" && "$STAGE" = /* ]] || fail 'Supply an absolute --stage-dir path'
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || fail '--timeout must be a positive integer'
[[ "$(id -u)" != 0 ]] || fail 'Run as an unprivileged user (no sudo)'
[[ "$(uname -m)" == x86_64 ]] || fail 'x86_64 host required'
STAGE="$(realpath -e -- "$STAGE")" || fail 'Stage does not exist'
[[ -d "$STAGE" && ! -L "$STAGE" ]] || fail 'Stage must be a normal directory'
TOOL="$STAGE/compat_tool"
ROOTFS="$TOOL/images/rootfs"
[[ -f "$TOOL/lepton" && -f "$TOOL/liblepton/baking.sh" ]] || fail 'Lepton stage missing'
[[ -d "$ROOTFS" && ! -L "$ROOTFS" && -x "$ROOTFS/system/bin/sh" ]] || fail 'Android rootfs missing'
grep -qx 'ro.build.version.sdk=34' "$ROOTFS/system/build.prop" || fail 'Expected Android 14 API 34'
if [[ "$RENDERING" == software ]]; then
    [[ -f "$ROOTFS/vendor/lib64/hw/vulkan.pastel.so" ]] || fail 'SwiftShader Vulkan missing'
    [[ -f "$ROOTFS/vendor/lib64/hw/gralloc.default.so" ]] || fail 'Software gralloc missing'
    grep -Fq 'gbm-software-vintf.xml' "$TOOL/liblepton/mounting.sh" ||
        fail 'Software GBM HAL masking fix missing from staged Lepton'
else
    [[ -f "$ROOTFS/vendor/lib64/hw/vulkan.radeon.so" ]] || fail 'AMD Vulkan rootfs missing'
fi
[[ -f "$TOOL/images/rootfs_overlay/system/etc/init/hw/init.rc" || -d "$TOOL/images/rootfs_overlay" ]] || fail 'Rootfs overlay missing'
[[ ! -e "$TOOL/sysbake" && ! -L "$TOOL/sysbake" && ! -e "$TOOL/sysbake.xattrs" && ! -L "$TOOL/sysbake.xattrs" ]] || fail 'Existing sysbake present: refusing overwrite'
grep -Fq 'never bake the build host address' "$TOOL/liblepton/baking.sh" || fail 'Missing baked Ethernet cleanup fix'
grep -Fq 'ETHERNET_APEX_CONFIG=' "$TOOL/liblepton/mounting.sh" || fail 'Missing Android 14 runtime Ethernet override'
for bin in podman weston systemctl rsync getfattr setfattr timeout python3 flock realpath mktemp fuse-overlayfs; do
    command -v "$bin" >/dev/null 2>&1 || fail "Missing host command: $bin"
done
[[ -x "$STAGE/tools/bin/inotifywait" ]] || fail 'Staged inotifywait missing'
RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
[[ -d "$RUNTIME" && -O "$RUNTIME" && -w "$RUNTIME" ]] || fail "Unavailable user runtime directory: $RUNTIME"
[[ "$RUNTIME" = /run/user/* ]] || fail 'Unexpected XDG_RUNTIME_DIR; refusing to run'
if systemctl --user is-active --quiet lepton-sysbake.slice; then
    fail 'lepton-sysbake.slice is already active; will not interfere'
fi
info "Mode: $MODE"
info "Rendering: $RENDERING"
info "Stage: $STAGE"
info "Podman storage: fresh directory inside $STAGE/.sysbake-work.* (not user's default store)"
info "Runroot: private directory under $RUNTIME"
info 'Headless Weston: temporary dedicated socket'
if [[ "$MODE" == --check ]]; then
    pass 'Isolated sysbake preflight passed; no files or services changed'
    exit 0
fi

# Serialize isolated runs and protect lepton-sysbake.slice against concurrent runs.
exec {RUN_LOCK}>"$RUNTIME/lepton-isolated-sysbake.lock"
flock -n "$RUN_LOCK" || fail 'Another isolated sysbake run is active'
if systemctl --user is-active --quiet lepton-sysbake.slice; then
    fail 'lepton-sysbake.slice became active; refusing to interfere'
fi
WORK="$(mktemp -d "$STAGE/.sysbake-work.XXXXXXXX")"
RUNROOT="$(mktemp -d "$RUNTIME/lepton-sysbake-run.XXXXXXXX")"
GRAPHROOT="$WORK/podman-storage"
SOCKET="lepton-sysbake-$$"
WESTON_PID=
PARTIAL=
PARTIAL_XATTR=
# Lepton runs Android commands with `podman exec -it`. When its input is this
# terminal, Podman switches the terminal to raw mode, and a container stopped
# mid-command never switches it back (the terminal then needs `reset`).
# Sysbake gets no terminal at all (as in upstream CI); restore the settings
# on exit anyway.
TTY_STATE=
if [[ -t 0 ]]; then TTY_STATE="$(stty -g 2>/dev/null || true)"; fi
cleanup() {
    rc=$?
    trap - EXIT INT TERM
    if [[ -n "$TTY_STATE" ]]; then stty "$TTY_STATE" 2>/dev/null || true; fi
    # Only the private Podman graph/runroot is addressable through this wrapper.
    if [[ -x "$WORK/bin/podman" ]]; then
        "$WORK/bin/podman" rm -fi lepton-sysbake >/dev/null 2>&1 || true
    fi
    # Lepton's launcher waits for its container with a background
    # `podman events`; if the container already existed, that watcher never
    # exits and keeps this run's lock open, blocking every later sysbake.
    # Stop whatever still uses this run's private runroot (a unique path).
    if [[ -n "$RUNROOT" ]]; then
        pkill -f -- "--runroot=$RUNROOT( |$)" >/dev/null 2>&1 || true
    fi
    # The runner preflights this slice as inactive, then only sysbake creates it.
    systemctl --user stop lepton-sysbake.slice >/dev/null 2>&1 || true
    if [[ -n "$WESTON_PID" ]]; then
        kill "$WESTON_PID" >/dev/null 2>&1 || true
        wait "$WESTON_PID" 2>/dev/null || true
    fi
    if [[ -n "$PARTIAL" && -d "$PARTIAL" ]]; then
        # Only remove the disposable publication directory this run created.
        rm -rf -- "$PARTIAL"
    fi
    if [[ -n "$PARTIAL_XATTR" && -f "$PARTIAL_XATTR" ]]; then
        rm -f -- "$PARTIAL_XATTR"
    fi
    if [[ -n "$RUNROOT" && -d "$RUNROOT" ]]; then
        rmdir "$RUNROOT" 2>/dev/null || true
    fi
    if (( rc != 0 )); then
        printf '[FAIL] Sysbake exited %s; diagnostic files preserved in %s\n' "$rc" "$WORK" >&2
        printf '[INFO] Runtime directory (may contain diagnostic state): %s\n' "$RUNROOT" >&2
    else
        printf '[INFO] Private sysbake work retained for inspection: %s\n' "$WORK"
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$WORK/bin" "$WORK/home/.steam" "$WORK/home/.config" "$WORK/home/.local/share" "$WORK/tmp" "$GRAPHROOT"
touch "$WORK/home/.steam/steam.pipe"
mkdir -p "$WORK/compat_tool"
rsync -a --no-owner --no-group --exclude '/images/rootfs' --exclude '/sysbake' --exclude '/sysbake.xattrs' \
    "$TOOL/" "$WORK/compat_tool/"
mkdir -p "$WORK/compat_tool/images"
ln -s -- "$ROOTFS" "$WORK/compat_tool/images/rootfs"

# Isolated sysbake: poll for Android-created files rather than relying
# on inotify propagation through container overlay mounts.
# Only the disposable compat_tool copy is modified.
python3 - "$WORK/compat_tool/liblepton/utils.sh" <<'PYPOLL'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

old = "function wait_for_file()" + chr(10) + "{" + chr(10)
new = """function wait_for_file()
{
    if [[ "${LEPTON_ISOLATED_SYSBAKE:-0}" == "1" ]]; then
        echo "[sysbake-wait] target=${1} context=${LEPTON_CONTEXT:-unset} home=${HOME} steamdata=${STEAM_COMPAT_DATA_PATH:-unset}" >&2
        while [[ ! -e "${1}" ]]; do sleep 0.25; done
        echo "[sysbake-wait] observed=${1}" >&2
        return 0
    fi
"""

assert s.count(old) == 1, "Expected wait_for_file definition not found"
p.write_text(s.replace(old, new, 1))
PYPOLL

# Patch only the disposable launcher copy: it must not manage the host's
# podman.service, nor contend on the live Lepton /tmp/lepton.lock.
python3 - "$WORK/compat_tool/lepton" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
replacements = [
    ('if systemctl --user is-system-running >/dev/null && [[ -z "${CATATONIT_PID}" ]]; then',
     'if [[ "${LEPTON_ISOLATED_SYSBAKE:-0}" != "1" ]] && systemctl --user is-system-running >/dev/null && [[ -z "${CATATONIT_PID}" ]]; then'),
    ('exec {LEPTON_LOCKFD}>/tmp/lepton.lock',
     'exec {LEPTON_LOCKFD}>"${LEPTON_LOCK_PATH:-/tmp/lepton.lock}"'),
]
for old, new in replacements:
    if s.count(old) != 1:
        raise SystemExit(f'Refusing unsafe launcher modification: expected exactly one {old!r}')
    s = s.replace(old, new, 1)
p.write_text(s)
PY
bash -n "$WORK/compat_tool/lepton"

# Hard-coded wrapper paths also work when Lepton's `podman_attach` uses env -i.
# Always use CLI storage flags; never inherit or migrate the normal Podman store.
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
export PATH="$WORK/bin:$STAGE/tools/bin:/usr/bin:/bin"
export XDG_RUNTIME_DIR="$RUNTIME" GAMESCOPE_WAYLAND_DISPLAY="$SOCKET"
export LEPTON_ISOLATED_SYSBAKE=1 LEPTON_LOCK_PATH="$WORK/lock"
if [[ "$RENDERING" == software ]]; then
    export LEPTON_FORCE_SOFTWARE=true
else
    export LEPTON_FORCE_SOFTWARE=false
fi
export LEPTON_ALLOW_LOCAL_SYSBAKE=1
export LEPTON_ALLOW_KMSG=false LEPTON_GAMEPAD_PASSTHROUGH=false
export TERM=dumb TMPDIR="$WORK/tmp"
unset SteamAppId STEAM_COMPAT_INSTALL_PATH STEAM_COMPAT_DATA_PATH
unset CONTAINER_HOST CONTAINER_CONNECTION PODMAN_CONNECTION

# Fail closed if a changed Podman default or wrapper reaches the host store.
ROOT_ACTUAL="$(podman info --format '{{.Store.GraphRoot}}')" || fail 'Isolated Podman cannot initialize'
RUN_ACTUAL="$(podman info --format '{{.Store.RunRoot}}')" || fail 'Isolated Podman runroot failed'
[[ "$(realpath -m "$ROOT_ACTUAL")" == "$(realpath -m "$GRAPHROOT")" ]] || fail "Podman graphroot escaped isolation: $ROOT_ACTUAL"
[[ "$(realpath -m "$RUN_ACTUAL")" == "$(realpath -m "$RUNROOT")" ]] || fail "Podman runroot escaped isolation: $RUN_ACTUAL"
pass 'Podman graphroot and runroot are isolated'

weston --no-config --backend=headless --renderer=pixman --socket="$SOCKET" --log="$WORK/weston.log" &
WESTON_PID=$!
READY=false
for (( i=0; i<50; i++ )); do
    if [[ -S "$RUNTIME/$SOCKET" ]] && kill -0 "$WESTON_PID" 2>/dev/null; then
        READY=true
        break
    fi
    sleep .2
done
if [[ "$READY" != true ]]; then
    tail -n 40 "$WORK/weston.log" >&2 || true
    fail 'Headless Weston failed to start'
fi
pass "Headless Wayland compositor ready: $SOCKET"

info "Booting fresh Android 14 for sysbake (timeout ${TIMEOUT}s)"
(
    cd "$WORK/compat_tool"
    timeout --foreground --signal=TERM --kill-after=20s "${TIMEOUT}s" ./lepton sysbake
) < /dev/null > "$WORK/sysbake.log" 2>&1 || {
    tail -n 65 "$WORK/sysbake.log" >&2 || true
    fail "Android sysbake failed; see $WORK/sysbake.log"
}

BAKED="$WORK/compat_tool/sysbake"
[[ -s "$BAKED/system/packages.xml" ]] || fail 'Missing baked Android packages.xml'
[[ ! -e "$BAKED/misc/ethernet/ipconfig.txt" ]] || fail 'Baked legacy Ethernet host configuration detected'
[[ ! -e "$BAKED/misc/apexdata/com.android.tethering/misc/ethernet/ipconfig.txt" ]] || fail 'Baked APEX Ethernet host configuration detected'
rm -f -- "$BAKED/lepton-onboot" "$BAKED/lepton-on-app-exit"
# As in upstream CI, remove SSH overlay data that fuse-overlayfs cannot handle.
if [[ -d "$BAKED/ssh" && ! -L "$BAKED/ssh" ]]; then
    rm -rf -- "$BAKED/ssh"
fi
(
    cd "$WORK/compat_tool"
    getfattr -R -P -h -d -m '-' sysbake 2> "$WORK/getfattr.log" |
        sed '/^security\.selinux=/d' > "$WORK/sysbake.xattrs"
)
if grep -q '^security\.selinux=' "$WORK/sysbake.xattrs"; then
    fail 'SELinux host labels remained in sysbake.xattrs'
fi
# Verify that the recorded xattrs can be restored as an ordinary user.
(
    cd "$WORK/compat_tool"
    setfattr -P -h --restore "$WORK/sysbake.xattrs"
) || fail 'sysbake.xattrs cannot be restored without elevated privileges'

# Publish after all checks. Existing stage assets are never overwritten.
[[ ! -e "$TOOL/sysbake" && ! -L "$TOOL/sysbake" && ! -e "$TOOL/sysbake.xattrs" && ! -L "$TOOL/sysbake.xattrs" ]] || fail 'sysbake destination appeared during run'
PARTIAL="$(mktemp -d "$TOOL/.sysbake-partial.XXXXXXXX")"
cp -a -- "$BAKED/." "$PARTIAL/"
PARTIAL_XATTR="$TOOL/.sysbake.xattrs.tmp.$$"
cp -- "$WORK/sysbake.xattrs" "$PARTIAL_XATTR"
[[ ! -e "$TOOL/sysbake" && ! -e "$TOOL/sysbake.xattrs" ]] || fail 'sysbake destination appeared during publish'
mv -T -- "$PARTIAL" "$TOOL/sysbake"
PARTIAL=
mv -T -- "$PARTIAL_XATTR" "$TOOL/sysbake.xattrs"
PARTIAL_XATTR=
pass "Fresh sysbake: $TOOL/sysbake"
pass "Portable xattrs: $TOOL/sysbake.xattrs"
pass 'No Fedora Ethernet ipconfig files baked into Android data'
