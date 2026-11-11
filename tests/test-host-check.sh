#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# lepton-host-check against fake hosts: an isolated PATH of stand-in tools and
# fake /proc/filesystems, /sys/class/drm, os-release and home directory.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
check="$repo/compat_tool/tools/lepton-host-check"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
fail() { echo "FAIL: $*" >&2; cat "$work/out" >&2; exit 1; }

# Basic tools the check itself uses come from the real system.
mkdir -p "$work/base"
for tool in bash uname id grep dirname; do ln -s "$(command -v "$tool")" "$work/base/$tool"; done
stub() { mkdir -p "$work/$1"; for tool in "${@:2}"; do printf '#!/bin/sh\n' > "$work/$1/$tool"; chmod +x "$work/$1/$tool"; done; }
stub all podman gamescope setfattr python3 zenity xdpyinfo xprop
printf 'nodev\tproc\nnodev\tbinder\n' > "$work/binder"
printf 'nodev\tproc\n' > "$work/no-binder"
mkdir -p "$work/drm-amd/renderD128/device" "$work/drm-intel/renderD128/device"
echo 0x1002 > "$work/drm-amd/renderD128/device/vendor"
echo 0x8086 > "$work/drm-intel/renderD128/device/vendor"
printf 'NAME="SteamOS"\nID=steamos\n' > "$work/steamos"
printf 'NAME="Fedora Linux"\nID=fedora\n' > "$work/fedora"
mkdir -p "$work/home/.local/share/Steam" "$work/flatpak-home/.var/app/com.valvesoftware.Steam" "$work/empty-home"

# host [VAR=VALUE...]: run the check on a fake SteamOS Deck with every tool,
# then apply the overrides. Output in $work/out; returns the check's status.
host() {
    env -i PATH="$work/all:$work/base" HOME="$work/home" LEPTON_HOST_FILESYSTEMS="$work/binder" \
        LEPTON_SYSFS_DRM="$work/drm-amd" LEPTON_HOST_OS_RELEASE="$work/steamos" "$@" \
        bash "$check" > "$work/out" 2>&1
}
ok() { host "$@" || fail "rejected: $*"; }
refused() { if host "${@:2}"; then fail "accepted: ${*:2}"; fi; grep -Fq -- "$1" "$work/out" || fail "missing: $1"; }

ok
grep -q '^\[PASS\] This computer meets the requirements' "$work/out"
! grep -q '^\[WARN\]' "$work/out" || fail 'warnings on a complete Deck'
grep -q '^\[PASS\] SteamOS/Gamescope profile$' "$work/out"

refused 'Android Binder (BinderFS) kernel support is not available' LEPTON_HOST_FILESYSTEMS="$work/no-binder"
refused '1 requirement(s) missing; nothing was changed' LEPTON_HOST_FILESYSTEMS="$work/no-binder"
for tool in podman gamescope setfattr python3; do
    rm -rf "$work/without"; cp -a "$work/all" "$work/without"; rm "$work/without/$tool"
    refused "$tool" PATH="$work/without:$work/base"
    grep -q "^\[FAIL\] .*$( [[ $tool == setfattr ]] && echo 'package "attr"' || echo "$tool")" "$work/out" || fail "no FAIL line for $tool"
done
stub nodialog podman gamescope setfattr python3
refused 'Neither zenity nor kdialog' PATH="$work/nodialog:$work/base"
stub kdialog-only podman gamescope setfattr python3 kdialog
ok PATH="$work/kdialog-only:$work/base"
refused 'Only Flatpak Steam was found' HOME="$work/flatpak-home"
refused 'Steam not found' HOME="$work/empty-home"

# Intel graphics: a warning, not a failure.
ok LEPTON_SYSFS_DRM="$work/drm-intel"
grep -q '^\[WARN\] No AMD GPU' "$work/out"

stub direct podman setfattr python3 kdialog
# Both desktops use direct Wayland and need no Gamescope or X11 utilities.
python3 - "$work/wayland-0" <<'SOCKET'
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
SOCKET
for desktop in KDE GNOME; do
    ok LEPTON_HOST_OS_RELEASE="$work/fedora" XDG_CURRENT_DESKTOP="$desktop" XDG_SESSION_TYPE=wayland \
        WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR="$work" PATH="$work/direct:$work/base"
    grep -q "^\[PASS\] Desktop: $desktop (Wayland)" "$work/out"
    ! grep -q 'Gamescope\|xdpyinfo\|xprop' "$work/out" || fail 'direct profile requires bridge tools'
done
refused 'X11 sessions are unsupported' LEPTON_HOST_OS_RELEASE="$work/fedora" XDG_SESSION_TYPE=x11
ok LEPTON_HOST_OS_RELEASE="$work/fedora"
grep -q '^\[WARN\] No usable Wayland socket' "$work/out"
ok LEPTON_HOST_OS_RELEASE="$work/fedora" XDG_SESSION_TYPE=wayland WAYLAND_DISPLAY=absent XDG_RUNTIME_DIR="$work"
grep -q '^\[WARN\] No usable Wayland socket' "$work/out"
# Direct routing still requires Podman, Binder, attr, Python and native Steam.
for tool in podman setfattr python3; do
    rm -rf "$work/without"; cp -a "$work/direct" "$work/without"; rm "$work/without/$tool"
    refused "$tool" LEPTON_HOST_OS_RELEASE="$work/fedora" PATH="$work/without:$work/base"
done
refused 'Android Binder' LEPTON_HOST_OS_RELEASE="$work/fedora" LEPTON_HOST_FILESYSTEMS="$work/no-binder"
refused 'Only Flatpak Steam' LEPTON_HOST_OS_RELEASE="$work/fedora" HOME="$work/flatpak-home"
# Explicit steamos on Fedora restores its Gamescope requirement.
if env -i HOME="$work/home" PATH="$work/direct:$work/base" LEPTON_HOST_OS_RELEASE="$work/fedora" \
    LEPTON_HOST_FILESYSTEMS="$work/binder" LEPTON_SYSFS_DRM="$work/drm-amd" \
    bash "$check" --install-profile steamos > "$work/out" 2>&1; then
    fail 'forced Gamescope profile accepted without Gamescope'
fi
grep -q 'Gamescope is not installed' "$work/out"
# SteamOS over SSH (no desktop variables) is fine.
ok XDG_CURRENT_DESKTOP=
# Several problems are all reported, not just the first.
refused '2 requirement(s) missing' LEPTON_HOST_FILESYSTEMS="$work/no-binder" HOME="$work/empty-home"
echo 'PASS: host check: complete Deck, each missing requirement, dialogs, Flatpak/missing Steam, non-AMD warning, desktops'
