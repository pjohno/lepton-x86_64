#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Shared-storage host folders (issue #37) and profile shared storage outside
# Steam's folders (lepton-play). Disposable host fixtures; runs the real
# setup_mounts with stubs and checks Podman's mount arguments. No Android boot.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

for fn in podman_cmdline podman_mount_entry podman_mount_entry_optional safe_storage_link \
          lepton_shared_folders remove_empty_android_folder share_host_folder setup_mounts; do
    eval "$(sed -n "/^function $fn()/,/^}/p" "$repo/compat_tool/liblepton/mounting.sh")"
done
eval "$(sed -n '/^LEPTON_SHARED_FOLDER_PAIRS=/p' "$repo/compat_tool/liblepton/mounting.sh")"
eval "$(sed -n '/^function host_path_in_container()/,/^}/p' "$repo/compat_tool/liblepton/liblepton.sh")"

print() { printf '%s' "$*"; }
println() { printf '%s\n' "$*" >> "$work/messages"; }
die() { printf 'DIE: %s\n' "$*" >> "$work/messages"; exit 3; }
is_app() { return 1; }
is_app_baked() { return 1; }
is_sysbake() { return 1; }
steamos_devmode_enabled() { return 1; }
get_app_id() { :; }
get_baked_app_data_dir() { print "$STEAM_COMPAT_DATA_PATH/baked"; }
data_mount_path() { print "$(get_baked_app_data_dir)/data_overlay"; }
data_workdir() { print "$(get_baked_app_data_dir)/data_workdir"; }
app_workdir() { print "$(get_baked_app_data_dir)/app_workdir"; }
app_datadir() { print "$(get_baked_app_data_dir)/app_overlay"; }
lepton_basename() { basename -- "$1"; }

export HOME="$work/home"
mkdir -p "$HOME/Documents" "$HOME/Downloads" "$HOME/Videos" "$HOME/.steam" "$work/tool/liblepton"
# Globals setup_mounts reads. No rootfs_overlay next to LEPTON_DIR.
export LEPTON_DIR="$work/tool/liblepton" BAKED_SYSTEM_DATA_DIR="$work/sysbake" LEPTON_DATA_DIR="$work/contexts"
steam="$work/steam"
mkdir -p "$steam"

fail() { echo "FAIL: $*"; [[ ! -f "$work/messages" ]] || cat "$work/messages"; exit 1; }

# Run setup_mounts in a subshell; leave the mount arguments in $work/mounts.
run_mounts() {
    : > "$work/messages"
    ( PODMAN_CMDLINE=(); setup_mounts; printf '%s\n' "${PODMAN_CMDLINE[@]}" > "$work/mounts" )
}
mounted() { grep -qxF -- "type=bind,source=$1,destination=$1,rw" "$work/mounts"; }
link_is() { [[ -L "$2" && "$(readlink -- "$2")" == "$1" ]]; }

# --- Steam-style profile (compatdata inside a mounted Steam library) ----------
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$steam"
export STEAM_COMPAT_LIBRARY_PATHS="$steam"
export STEAM_COMPAT_DATA_PATH="$steam/steamapps/compatdata/123"
mkdir -p "$STEAM_COMPAT_DATA_PATH"
ext="$STEAM_COMPAT_DATA_PATH/external"

# Default (option unset): the original three folders, linked and mounted.
unset LEPTON_SHARED_FOLDERS
run_mounts || fail "default launch stopped"
link_is "$HOME/Documents" "$ext/Documents" || fail "Documents not linked by default"
link_is "$HOME/Downloads" "$ext/Download" || fail "Download not linked by default"
link_is "$HOME/Videos" "$ext/Movies" || fail "Movies not linked by default"
for d in Documents Downloads Videos; do mounted "$HOME/$d" || fail "$d not mounted by default"; done
link_is "$ext" "$STEAM_COMPAT_DATA_PATH/baked/data_overlay/media/0" || fail "media/0 link"
# Inside a mounted library: no extra mount for external.
! mounted "$ext" || fail "external mounted twice for a Steam profile"
# Idempotent.
run_mounts || fail "second default launch stopped"

# Turning one folder off removes only Lepton's link and its mount.
LEPTON_SHARED_FOLDERS="Documents, videos" run_mounts || fail "partial sharing stopped"
[[ ! -e "$ext/Download" && ! -L "$ext/Download" ]] || fail "Download link kept when off"
! mounted "$HOME/Downloads" || fail "Downloads still mounted when off"
mounted "$HOME/Documents" && mounted "$HOME/Videos" || fail "kept folders not mounted"
grep -q 'Shared folder off: Download' "$work/messages" || fail "no message for folder turned off"
[[ -d "$HOME/Downloads" ]] || fail "host Downloads touched"

# none / empty: nothing shared, nothing mounted, host folders untouched.
for value in none ""; do
    LEPTON_SHARED_FOLDERS="$value" run_mounts || fail "'$value' stopped the launch"
    for n in Documents Download Movies; do [[ ! -L "$ext/$n" ]] || fail "$n linked with '$value'"; done
    for d in Documents Downloads Videos; do
        ! mounted "$HOME/$d" || fail "$d mounted with '$value'"
        [[ -d "$HOME/$d" ]] || fail "host $d touched"
    done
done

# Android made a real Download folder while sharing was off.
# Empty: replaced by the link when sharing is turned back on.
mkdir "$ext/Download"
LEPTON_SHARED_FOLDERS=Downloads run_mounts || fail "re-enable over empty folder stopped"
link_is "$HOME/Downloads" "$ext/Download" || fail "empty Android folder not replaced by link"
# With files: kept, not linked, launch continues.
LEPTON_SHARED_FOLDERS=none run_mounts
mkdir "$ext/Download"; echo irreplaceable > "$ext/Download/book.pdf"
LEPTON_SHARED_FOLDERS=Download run_mounts || fail "real folder with files stopped the launch"
[[ -d "$ext/Download" && ! -L "$ext/Download" && "$(cat "$ext/Download/book.pdf")" == irreplaceable ]] ||
    fail "Android folder with files changed"
! mounted "$HOME/Downloads" || fail "Downloads mounted though not linked"
grep -q 'not linked' "$work/messages" || fail "no message for kept folder"
rm -rf -- "$ext/Download"

# MediaProvider's marker alone (seen in Movies and Pictures) counts as empty.
LEPTON_SHARED_FOLDERS=none run_mounts
mkdir -p "$ext/Movies/.thumbnails"; echo uuid > "$ext/Movies/.thumbnails/.database_uuid"
LEPTON_SHARED_FOLDERS=Videos run_mounts || fail "re-enable over marker-only folder stopped"
link_is "$HOME/Videos" "$ext/Movies" || fail "marker-only Android folder not replaced"
# Real thumbnails next to the marker are kept.
LEPTON_SHARED_FOLDERS=none run_mounts
mkdir -p "$ext/Movies/.thumbnails"; echo uuid > "$ext/Movies/.thumbnails/.database_uuid"
echo thumb > "$ext/Movies/.thumbnails/1.jpg"
LEPTON_SHARED_FOLDERS=Videos run_mounts || fail "folder with thumbnails stopped the launch"
[[ -f "$ext/Movies/.thumbnails/1.jpg" && -f "$ext/Movies/.thumbnails/.database_uuid" && ! -L "$ext/Movies" ]] ||
    fail "folder with thumbnails changed"
rm -rf -- "$ext/Movies"

# A link Lepton did not make is left alone when the folder is off.
ln -s /elsewhere "$ext/Movies.tmp" && rm -f "$ext/Movies" && mv "$ext/Movies.tmp" "$ext/Movies"
LEPTON_SHARED_FOLDERS=none run_mounts || fail "unknown link stopped an off folder"
link_is /elsewhere "$ext/Movies" || fail "unknown link changed"
grep -q 'left unchanged' "$work/messages" || fail "no warning for unknown link"
# ...and still stops the launch when the folder is on (unchanged behaviour).
if LEPTON_SHARED_FOLDERS=Movies run_mounts; then fail "unknown link replaced"; fi
link_is /elsewhere "$ext/Movies" || fail "unknown link changed when on"
rm -f "$ext/Movies"

# Unknown names stop the launch before anything changes.
run_mounts
if LEPTON_SHARED_FOLDERS="Downloads,Pictures" run_mounts; then fail "unknown folder name accepted"; fi
grep -q "unknown folder 'Pictures'" "$work/messages" || fail "no message for unknown name"
link_is "$HOME/Downloads" "$ext/Download" || fail "links changed by invalid option"

# A missing host folder is skipped, as before.
rmdir "$HOME/Videos"
run_mounts || fail "missing host folder stopped the launch"
! mounted "$HOME/Videos" || fail "missing Videos mounted"
mkdir "$HOME/Videos"

# --- lepton-play profile: data root outside every mounted path ----------------
unset STEAM_COMPAT_LIBRARY_PATHS
export STEAM_COMPAT_DATA_PATH="$work/lepton-compat-data/org.example.game"
mkdir -p "$STEAM_COMPAT_DATA_PATH"
ext="$STEAM_COMPAT_DATA_PATH/external"
run_mounts || fail "lepton-play profile stopped"
mounted "$ext" || fail "lepton-play external not mounted (dangling /data/media/0)"
link_is "$ext" "$STEAM_COMPAT_DATA_PATH/baked/data_overlay/media/0" || fail "lepton-play media/0 link"
link_is "$HOME/Downloads" "$ext/Download" || fail "lepton-play Download link"

# The experimental /lepton alias (run-apk.sh) keeps its own mount only.
export STEAM_COMPAT_DATA_PATH="$work/lepton-compat-data/org.example.alias"
mkdir -p "$STEAM_COMPAT_DATA_PATH"
ext="$STEAM_COMPAT_DATA_PATH/external"
LEPTON_PROFILE_EXTERNAL_STORAGE=/lepton/profile-external run_mounts || fail "alias profile stopped"
grep -qxF -- "type=bind,source=$ext,destination=/lepton/profile-external,rw" "$work/mounts" || fail "alias mount"
! mounted "$ext" || fail "alias profile also mounted at host path"
link_is /lepton/profile-external "$STEAM_COMPAT_DATA_PATH/baked/data_overlay/media/0" || fail "alias media/0 link"

echo "PASS: shared folders and profile shared storage"
