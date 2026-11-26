#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Shared-storage host folders (issue #37) and profile shared storage outside
# Steam's folders (lepton-play). Disposable host fixtures; runs the real
# setup_mounts with stubs and checks Podman's mount arguments. No Android boot.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
work="$(realpath -e -- "$work")"
trap 'chmod -R u+rwx -- "$work" 2>/dev/null; rm -rf -- "$work"' EXIT

for fn in podman_cmdline podman_mount_entry podman_mount_entry_optional safe_storage_link \
          lepton_xdg_user_dir lepton_shared_folder_entries lepton_trim lepton_array_has \
          lepton_shared_protected_paths lepton_shared_check_defaults lepton_shared_check_custom \
          lepton_shared_name_ok lepton_shared_folder_ok lepton_shared_host_ok \
          remove_empty_android_folder share_host_folder lepton_shared_link_is_ours \
          setup_shared_folders setup_mounts; do
    eval "$(sed -n "/^function $fn()/,/^}/p" "$repo/compat_tool/liblepton/mounting.sh")"
    declare -F "$fn" > /dev/null || { echo "FAIL: $fn not found"; exit 1; }
done
# Array assignments may continue on the next line.
eval "$(awk '/^LEPTON_SHARED_[A-Z_]*=/ {p=1; arr=/=\(/} p {print} p && (!arr || /\)[[:space:]]*$/) {p=0}' \
          "$repo/compat_tool/liblepton/mounting.sh")"
[[ ${#LEPTON_SHARED_FOLDER_DEFAULTS[@]} == 5 ]] || { echo "FAIL: default folders not loaded"; exit 1; }
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
unset XDG_CONFIG_HOME XDG_DATA_HOME
mkdir -p "$HOME/Documents" "$HOME/Downloads" "$HOME/Videos" "$HOME/Music" "$HOME/Pictures" \
         "$HOME/.steam" "$work/tool/liblepton"
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
mounted_at() { grep -qxF -- "type=bind,source=$1,destination=$2,${3:-rw}" "$work/mounts"; }
link_is() { [[ -L "$2" && "$(readlink -- "$2")" == "$1" ]]; }
# shared NAME HOST [MODE]: HOST mounted at /lepton/shared/NAME, linked as NAME.
shared() { mounted_at "$2" "/lepton/shared/$1" "${3:-rw}" && link_is "/lepton/shared/$1" "$ext/$1"; }
not_shared() { [[ ! -L "$ext/$1" ]] && ! grep -qF -- "destination=/lepton/shared/$1," "$work/mounts"; }
count_mounts() { grep -c -- "destination=/lepton/shared/" "$work/mounts" || true; }
snapshot() { find "$ext" -maxdepth 1 -printf '%f %l\n' | sort; }
use_profile() {
    export STEAM_COMPAT_DATA_PATH="$steam/steamapps/compatdata/$1"
    mkdir -p "$STEAM_COMPAT_DATA_PATH"
    ext="$STEAM_COMPAT_DATA_PATH/external"
}
# The five default folders: Android name and host folder.
defaults=(Documents:Documents Download:Downloads Movies:Videos Music:Music Pictures:Pictures)
all_defaults_shared() {
    local d
    for d in "${defaults[@]}"; do shared "${d%%:*}" "$HOME/${d#*:}" || return 1; done
}

# --- Steam-style profile (compatdata inside a mounted Steam library) ----------
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$steam"
export STEAM_COMPAT_LIBRARY_PATHS="$steam"
use_profile 123

# Default (option unset): five folders, mounted under /lepton/shared, quietly.
unset LEPTON_SHARED_FOLDERS
run_mounts || fail "default launch stopped"
all_defaults_shared || fail "default folders not all shared"
[[ "$(count_mounts)" == 5 ]] || fail "expected 5 default mounts, got $(count_mounts)"
for d in Documents Downloads Videos Music Pictures; do ! mounted "$HOME/$d" || fail "$d also mounted at its host path"; done
! grep -q 'Shared folder' "$work/messages" || fail "default launch not quiet"
link_is "$ext" "$STEAM_COMPAT_DATA_PATH/baked/data_overlay/media/0" || fail "media/0 link"
# Inside a mounted library: no extra mount for external.
! mounted "$ext" || fail "external mounted twice for a Steam profile"
# Idempotent.
cp "$work/mounts" "$work/mounts.before"; snapshot > "$work/links.before"
run_mounts || fail "second default launch stopped"
cmp -s "$work/mounts" "$work/mounts.before" && diff <(snapshot) "$work/links.before" > /dev/null ||
    fail "second default launch changed something"
! grep -q 'Shared folder' "$work/messages" || fail "second default launch not quiet"

# Turning folders off removes only Lepton's link and its mount.
LEPTON_SHARED_FOLDERS="Documents, videos, MUSIC" run_mounts || fail "partial sharing stopped"
not_shared Download && not_shared Pictures || fail "Download/Pictures kept when off"
# Android does not remake Documents or Download: Lepton leaves an empty
# folder of Android's own in place of the link.
android_folder() { [[ -d "$ext/$1" && ! -L "$ext/$1" && -z "$(ls -A -- "$ext/$1")" ]]; }
android_folder Download && android_folder Pictures || fail "no empty Android folder for Download/Pictures when off"
shared Documents "$HOME/Documents" && shared Movies "$HOME/Videos" && shared Music "$HOME/Music" ||
    fail "kept folders not shared"
grep -q 'Shared folder off: Download' "$work/messages" && grep -q 'Shared folder off: Pictures' "$work/messages" ||
    fail "no message for folders turned off"
[[ -d "$HOME/Downloads" && -d "$HOME/Pictures" ]] || fail "host folders touched"
LEPTON_SHARED_FOLDERS="music pictures" run_mounts || fail "space-separated Music Pictures stopped"
shared Music "$HOME/Music" && shared Pictures "$HOME/Pictures" && not_shared Documents || fail "Music Pictures selection"

# none / empty: nothing shared, nothing mounted, host folders untouched.
for value in none ""; do
    LEPTON_SHARED_FOLDERS="$value" run_mounts || fail "'$value' stopped the launch"
    for d in "${defaults[@]}"; do
        not_shared "${d%%:*}" || fail "${d%%:*} shared with '$value'"
        [[ -d "$HOME/${d#*:}" ]] || fail "host ${d#*:} touched"
        android_folder "${d%%:*}" || fail "no Android ${d%%:*} folder with '$value'"
    done
done

# Android made a real Download folder while sharing was off.
# Empty: replaced by the link when sharing is turned back on.
android_folder Download || fail "no Android Download folder"
LEPTON_SHARED_FOLDERS=Downloads run_mounts || fail "re-enable over empty folder stopped"
shared Download "$HOME/Downloads" || fail "empty Android folder not replaced by link"
# With files: kept, not linked, launch continues.
LEPTON_SHARED_FOLDERS=none run_mounts
echo irreplaceable > "$ext/Download/book.pdf"
LEPTON_SHARED_FOLDERS=Download run_mounts || fail "real folder with files stopped the launch"
[[ -d "$ext/Download" && ! -L "$ext/Download" && "$(cat "$ext/Download/book.pdf")" == irreplaceable ]] ||
    fail "Android folder with files changed"
! grep -q 'destination=/lepton/shared/Download,' "$work/mounts" || fail "Downloads mounted though not linked"
grep -q 'not linked' "$work/messages" || fail "no message for kept folder"
rm -rf -- "$ext/Download"

# MediaProvider's marker alone (seen in Movies, Music, Pictures) counts as empty.
LEPTON_SHARED_FOLDERS=none run_mounts
mkdir -p "$ext/Movies/.thumbnails"; echo uuid > "$ext/Movies/.thumbnails/.database_uuid"
LEPTON_SHARED_FOLDERS=Videos run_mounts || fail "re-enable over marker-only folder stopped"
shared Movies "$HOME/Videos" || fail "marker-only Android folder not replaced"
# Real thumbnails next to the marker are kept.
LEPTON_SHARED_FOLDERS=none run_mounts
mkdir -p "$ext/Movies/.thumbnails"; echo uuid > "$ext/Movies/.thumbnails/.database_uuid"
echo thumb > "$ext/Movies/.thumbnails/1.jpg"
LEPTON_SHARED_FOLDERS=Videos run_mounts || fail "folder with thumbnails stopped the launch"
[[ -f "$ext/Movies/.thumbnails/1.jpg" && -f "$ext/Movies/.thumbnails/.database_uuid" && ! -L "$ext/Movies" ]] ||
    fail "folder with thumbnails changed"
rm -rf -- "$ext/Movies"

# A link Lepton did not make is left alone when the folder is off...
ln -s /elsewhere "$ext/Movies"
LEPTON_SHARED_FOLDERS=none run_mounts || fail "unknown link stopped an off folder"
link_is /elsewhere "$ext/Movies" || fail "unknown link changed"
grep -q 'left unchanged' "$work/messages" || fail "no warning for unknown link"
# ...and stops the launch, before anything changes, when the folder is on.
if LEPTON_SHARED_FOLDERS=Movies run_mounts; then fail "unknown link replaced"; fi
link_is /elsewhere "$ext/Movies" || fail "unknown link changed when on"
rm -f "$ext/Movies"

# Unknown names stop the launch before anything changes.
run_mounts
if LEPTON_SHARED_FOLDERS="Downloads,Photos" run_mounts; then fail "unknown folder name accepted"; fi
grep -q "unknown folder 'Photos'" "$work/messages" || fail "no message for unknown name"
shared Download "$HOME/Downloads" || fail "links changed by invalid option"

# A missing default folder is skipped quietly; its link is kept, and the
# folder is not created on the host.
rmdir "$HOME/Videos"
run_mounts || fail "missing host folder stopped the launch"
! grep -q 'destination=/lepton/shared/Movies,' "$work/mounts" || fail "missing Videos mounted"
link_is /lepton/shared/Movies "$ext/Movies" || fail "missing Videos' link removed"
[[ ! -e "$HOME/Videos" ]] || fail "missing Videos created"
! grep -q 'Movies' "$work/messages" || fail "missing default folder not quiet"
# Asked for by name, it is reported.
LEPTON_SHARED_FOLDERS=Videos run_mounts || fail "missing named default stopped the launch"
grep -q 'WARNING: shared folder Movies: .* is not there' "$work/messages" || fail "missing named default not reported"
mkdir "$HOME/Videos"

# --- Profiles from before /lepton/shared: links to host paths -----------------
use_profile 789
mkdir -p "$ext"
ln -s "$HOME/Documents" "$ext/Documents"; ln -s "$HOME/Downloads" "$ext/Download"; ln -s "$HOME/Videos" "$ext/Movies"
mkdir -p "$ext/Music"; echo song > "$ext/Music/saved-by-game.ogg"     # Android's own, with a file
mkdir -p "$ext/Pictures/.thumbnails"; echo uuid > "$ext/Pictures/.thumbnails/.database_uuid"  # Android's, empty
unset LEPTON_SHARED_FOLDERS
run_mounts || fail "old profile stopped with the new defaults"
shared Documents "$HOME/Documents" && shared Download "$HOME/Downloads" && shared Movies "$HOME/Videos" ||
    fail "old links not updated to /lepton/shared"
[[ "$(grep -c 'link updated to /lepton/shared' "$work/messages")" == 3 ]] || fail "no message for updated links"
shared Pictures "$HOME/Pictures" || fail "empty Android Pictures not replaced in old profile"
[[ -d "$ext/Music" && ! -L "$ext/Music" && "$(cat "$ext/Music/saved-by-game.ogg")" == song ]] ||
    fail "Android Music with files changed"
grep -q 'Shared folder Music not linked' "$work/messages" || fail "no message for kept Android Music"
for d in Documents Downloads Videos; do [[ -d "$HOME/$d" ]] || fail "host $d touched by update"; done
run_mounts || fail "second launch of updated profile stopped"
! grep -q 'link updated' "$work/messages" || fail "links updated twice"
# Old links for folders turned off are removed like current ones.
use_profile 790
mkdir -p "$ext"
ln -s "$HOME/Documents" "$ext/Documents"; ln -s "$HOME/Downloads" "$ext/Download"; ln -s "$HOME/Videos" "$ext/Movies"
LEPTON_SHARED_FOLDERS=Documents run_mounts || fail "old profile with one folder stopped"
shared Documents "$HOME/Documents" || fail "old Documents link not updated"
android_folder Download && android_folder Movies || fail "old links of folders off kept"
grep -q 'Shared folder off: Download' "$work/messages" && grep -q 'Shared folder off: Movies' "$work/messages" ||
    fail "no message for old links removed"
# An old-style link to some other folder is not Lepton's.
use_profile 791
mkdir -p "$ext"; ln -s "$HOME/Music" "$ext/Download"
if run_mounts; then fail "foreign Download link replaced"; fi
link_is "$HOME/Music" "$ext/Download" || fail "foreign Download link changed"

# --- XDG user directories: localised, relocated, turned off, protected --------
use_profile 800
mkdir -p "$HOME/.config" "$HOME/Musik" "$HOME/Téléchargements" "$work/media/Photo Drive/Bilder"
cat > "$HOME/.config/user-dirs.dirs" <<EOF
# This file is written by xdg-user-dirs-update
XDG_DESKTOP_DIR="\$HOME/Desktop"
XDG_DOWNLOAD_DIR="\$HOME/Téléchargements"
XDG_MUSIC_DIR="\$HOME/Musik"
XDG_PICTURES_DIR="$work/media/Photo Drive/Bilder"
XDG_VIDEOS_DIR="\$HOME/"
XDG_DOCUMENTS_DIR="\$(touch $work/pwned)"
XDG_PUBLICSHARE_DIR="\$HOME/Public"
EOF
unset LEPTON_SHARED_FOLDERS
run_mounts || fail "XDG launch stopped"
shared Download "$HOME/Téléchargements" || fail "localised Downloads not used"
shared Music "$HOME/Musik" || fail "localised Music not used"
shared Pictures "$work/media/Photo Drive/Bilder" || fail "relocated Pictures not used"
shared Documents "$HOME/Documents" || fail "invalid XDG line did not fall back to ~/Documents"
[[ ! -e "$work/pwned" ]] || fail "user-dirs.dirs was executed"
not_shared Movies || fail "Videos set to HOME was shared"
! grep -qF "source=$HOME," "$work/mounts" || fail "HOME mounted"
grep -q 'WARNING: shared folder Movies: your Movies folder is set to your home folder' "$work/messages" ||
    fail "no warning for XDG folder set to HOME"
! grep -qE 'Desktop|Public' "$work/mounts" || fail "Desktop or Public shared"
# Named explicitly, a folder set to HOME is an error, and nothing changes.
snapshot > "$work/links.good"
if LEPTON_SHARED_FOLDERS="Music,Videos" run_mounts; then fail "Videos set to HOME accepted by name"; fi
grep -q 'your Movies folder is set to your home folder' "$work/messages" || fail "no error for named HOME folder"
diff <(snapshot) "$work/links.good" > /dev/null || fail "links changed by HOME folder error"
# A relocated folder that isn't there (drive unplugged): not created, link kept.
mv "$work/media" "$work/media.unplugged"
run_mounts || fail "unplugged XDG Pictures stopped the launch"
link_is /lepton/shared/Pictures "$ext/Pictures" || fail "unplugged XDG Pictures link removed"
[[ ! -e "$work/media" ]] || fail "unplugged XDG folder created"
mv "$work/media.unplugged" "$work/media"
# XDG pointing at protected or system folders: warned and skipped by default.
mkdir -p "$HOME/.ssh"
cat > "$HOME/.config/user-dirs.dirs" <<EOF
XDG_DOCUMENTS_DIR="/etc"
XDG_DOWNLOAD_DIR="\$HOME/.ssh"
XDG_MUSIC_DIR="/"
XDG_PICTURES_DIR="$STEAM_COMPAT_DATA_PATH"
XDG_VIDEOS_DIR="\$HOME/Videos"
EOF
run_mounts || fail "protected XDG folders stopped a default launch"
for n in Documents Download Music Pictures; do not_shared "$n" || fail "protected XDG $n shared"; done
shared Movies "$HOME/Videos" || fail "Videos not shared next to protected folders"
[[ "$(grep -c '^WARNING: shared folder' "$work/messages")" == 4 ]] || fail "not every protected XDG folder reported"
if LEPTON_SHARED_FOLDERS=Documents run_mounts; then fail "XDG /etc accepted by name"; fi
grep -q 'Documents: /etc is a system folder' "$work/messages" || fail "no error for named XDG /etc"
# XDG_CONFIG_HOME is used when set.
mkdir -p "$work/xdgconf"; printf 'XDG_MUSIC_DIR="%s"\n' "$HOME/Musik" > "$work/xdgconf/user-dirs.dirs"
XDG_CONFIG_HOME="$work/xdgconf" LEPTON_SHARED_FOLDERS=Music run_mounts || fail "XDG_CONFIG_HOME launch stopped"
shared Music "$HOME/Musik" || fail "XDG_CONFIG_HOME not used"
rm -f "$HOME/.config/user-dirs.dirs"

# --- Music and Pictures used as custom names (round 2 profiles) ---------------
use_profile 810
mkdir -p "$work/other/Music"
LEPTON_SHARED_FOLDERS="~/Music,~/Pictures" run_mounts || fail "custom ~/Music,~/Pictures stopped"
shared Music "$HOME/Music" && shared Pictures "$HOME/Pictures" || fail "custom Music/Pictures"
# The same profile with the new default: same links, nothing to change.
run_mounts || fail "custom Music profile with default stopped"
shared Music "$HOME/Music" && ! grep -q 'Music' "$work/messages" || fail "custom Music to default changed it"
# A path in place of a default folder.
LEPTON_SHARED_FOLDERS="Documents,Music=$work/other/Music" run_mounts || fail "Music=path stopped"
shared Music "$work/other/Music" && [[ "$(grep -c 'destination=/lepton/shared/Music,' "$work/mounts")" == 1 ]] ||
    fail "Music=path did not replace the default"

# --- Custom host folders (any path, mounted under /lepton/shared) -------------
use_profile 456
books="$HOME/Books"; films="$work/media/USB Drive/Films"; outside="$work/srv/Comics"
mkdir -p "$books" "$films" "$outside"

# A single path: shown under its final name.
LEPTON_SHARED_FOLDERS="$books" run_mounts || fail "single custom path stopped"
shared Books "$books" || fail "Books not shared at /lepton/shared/Books"
for d in "${defaults[@]}"; do not_shared "${d%%:*}" || fail "${d%%:*} linked when only a path is listed"; done
grep -qF "Shared folder Books: $books (read-write)" "$work/messages" || fail "no message for custom folder"
# ~/ is expanded by Lepton (Steam passes it quoted), trailing / ignored.
LEPTON_SHARED_FOLDERS="~/Books/" run_mounts || fail "~/ path stopped"
shared Books "$books" || fail "~/Books not shared"

# Mixture of default names and paths, with spaces and outside HOME.
LEPTON_SHARED_FOLDERS="Downloads, $books ,$films,Strips = $outside" run_mounts || fail "mixed list stopped"
shared Download "$HOME/Downloads" || fail "Download not shared in mixed list"
shared Books "$books" && shared Films "$films" && shared Strips "$outside" || fail "custom folders in mixed list"
[[ "$(count_mounts)" == 4 ]] || fail "expected 4 shared mounts, got $(count_mounts)"
for n in Documents Movies Music Pictures; do not_shared "$n" || fail "$n linked though not listed"; done
# The future APK library's layout: only its storage folder is shared, under
# the package name; the APK and obb/ next to it are not.
lib="$HOME/Android_Library/com.example.game"
mkdir -p "$lib/Container Storage" "$lib/obb"; touch "$lib/com.example.game.12334.apk"
LEPTON_SHARED_FOLDERS="Downloads,Container Storage=~/Android_Library/com.example.game/Container Storage" run_mounts ||
    fail "library Container Storage stopped"
shared "Container Storage" "$lib/Container Storage" || fail "library Container Storage not shared"
! grep -qE "source=$lib(/obb)?," "$work/mounts" || fail "library folder or obb shared"

# Old space-separated default names still work next to comma-separated paths.
LEPTON_SHARED_FOLDERS="Documents Videos,$books" run_mounts || fail "spaces + path stopped"
shared Documents "$HOME/Documents" && shared Movies "$HOME/Videos" && shared Books "$books" ||
    fail "spaces + path mapping"
not_shared Download || fail "Download linked in spaces + path"

# Repeated launch: same links, same mounts, no stray messages.
cp "$work/mounts" "$work/mounts.before"; snapshot > "$work/links.before"
LEPTON_SHARED_FOLDERS="Documents Videos,$books" run_mounts || fail "repeat launch stopped"
cmp -s "$work/mounts" "$work/mounts.before" || fail "repeat launch changed the mounts"
diff <(snapshot) "$work/links.before" > /dev/null || fail "repeat launch changed links"
! grep -q 'off\|WARNING\|ERROR\|updated' "$work/messages" || fail "repeat launch reported changes"

# Read-only, for a path and a default folder.
LEPTON_SHARED_FOLDERS="$films:ro,Downloads:RO" run_mounts || fail ":ro stopped"
shared Films "$films" ro || fail "Films not read-only"
shared Download "$HOME/Downloads" ro || fail "Downloads not read-only"
grep -qF "Shared folder Films: $films (read-only)" "$work/messages" || fail "no read-only message"
grep -qF "Shared folder Download: $HOME/Downloads (read-only)" "$work/messages" || fail "no read-only default message"

# Changing a mapping: same name, other folder. One link, one mount, new source.
other="$work/other/Books"; mkdir -p "$other"
LEPTON_SHARED_FOLDERS="$books" run_mounts
LEPTON_SHARED_FOLDERS="$other" run_mounts || fail "changing Books stopped"
shared Books "$other" && [[ "$(count_mounts)" == 1 ]] || fail "changed Books mapping"
! grep -qF "source=$books," "$work/mounts" || fail "old Books source still mounted"
# Renaming: the old link goes, the new one appears.
LEPTON_SHARED_FOLDERS="Novels=$books" run_mounts || fail "renaming stopped"
shared Novels "$books" || fail "Novels not shared"
[[ ! -e "$ext/Books" && ! -L "$ext/Books" ]] || fail "stale Books link after rename"
grep -q 'Shared folder off: Books' "$work/messages" || fail "no message for removed Books"
# Removing every custom folder (back to the default) removes their links only.
echo keep > "$ext/notes.txt"; mkdir -p "$ext/DCIM"; echo photo > "$ext/DCIM/p.jpg"
ln -s /somewhere/else "$ext/MyLink"; ln -s /lepton/shared/Other "$ext/Odd"
unset LEPTON_SHARED_FOLDERS
run_mounts || fail "back to default stopped"
[[ ! -L "$ext/Novels" ]] || fail "Novels link kept after removal"
all_defaults_shared || fail "defaults not restored"
[[ "$(count_mounts)" == 5 ]] || fail "custom mounts left after removal"
[[ "$(cat "$ext/notes.txt")" == keep && "$(cat "$ext/DCIM/p.jpg")" == photo ]] || fail "Android files changed"
link_is /somewhere/else "$ext/MyLink" && link_is /lepton/shared/Other "$ext/Odd" || fail "unrelated links changed"
[[ -d "$books" && -d "$films" && -d "$outside" && -d "$other" ]] || fail "host folders touched"

# A custom name over Android's own folder: empty -> linked; with files -> kept.
mkdir -p "$HOME/DCIM"
LEPTON_SHARED_FOLDERS="$HOME/DCIM" run_mounts || fail "DCIM with files stopped the launch"
[[ -d "$ext/DCIM" && ! -L "$ext/DCIM" && "$(cat "$ext/DCIM/p.jpg")" == photo ]] || fail "Android DCIM changed"
not_shared DCIM || fail "DCIM mounted though not linked"
grep -q 'Shared folder DCIM not linked' "$work/messages" || fail "no message for kept DCIM"
rm -rf -- "$ext/DCIM"; mkdir "$ext/DCIM"
LEPTON_SHARED_FOLDERS="$HOME/DCIM" run_mounts || fail "DCIM over empty folder stopped"
shared DCIM "$HOME/DCIM" || fail "empty Android DCIM not replaced"
LEPTON_SHARED_FOLDERS=none run_mounts; rm -f "$ext/MyLink" "$ext/Odd" "$ext/notes.txt"

# Missing folder (drive not connected): launch continues, its link is kept,
# nothing else changes; it comes back when the folder does.
LEPTON_SHARED_FOLDERS="$films,$books" run_mounts
mv "$work/media" "$work/media.unplugged"
LEPTON_SHARED_FOLDERS="$films,$books" run_mounts || fail "missing drive stopped the launch"
link_is /lepton/shared/Films "$ext/Films" || fail "missing drive's link removed"
! grep -q 'Films' "$work/mounts" || fail "missing folder mounted"
shared Books "$books" || fail "other folder affected by missing drive"
grep -q "WARNING: shared folder Films: $films is not there" "$work/messages" || fail "no warning for missing folder"
# A link to an unplugged drive counts as missing too.
ln -s "$work/media/USB Drive/Films" "$HOME/FilmsLink"
LEPTON_SHARED_FOLDERS="$HOME/FilmsLink" run_mounts || fail "dangling host link stopped the launch"
grep -q 'shared folder FilmsLink: .* is not there' "$work/messages" || fail "dangling host link not reported missing"
mv "$work/media.unplugged" "$work/media"
LEPTON_SHARED_FOLDERS="$films,$books" run_mounts || fail "reconnected drive stopped"
shared Films "$films" || fail "reconnected drive not shared"
# A host symlink to a folder: mounted from the real folder, named after the link.
LEPTON_SHARED_FOLDERS="$HOME/FilmsLink" run_mounts || fail "host symlink stopped"
shared FilmsLink "$films" || fail "host symlink not resolved to its folder"
# Links inside a shared folder are not followed or mounted.
ln -s /etc "$films/etc-link"; ln -s "$outside" "$films/comics-link"
LEPTON_SHARED_FOLDERS="$films" run_mounts || fail "folder with inner links stopped"
shared Films "$films" && ! grep -qE "source=(/etc|$outside)," "$work/mounts" ||
    fail "link inside a shared folder was mounted"
rm -f "$films/etc-link" "$films/comics-link"
# A host symlink that leads somewhere protected is refused.
ln -s "$HOME/.ssh" "$HOME/Keys"
if LEPTON_SHARED_FOLDERS="$HOME/Keys" run_mounts; then fail "link to ~/.ssh accepted"; fi
grep -q 'hidden folder of your home' "$work/messages" || fail "no error for link to ~/.ssh"
rm -f "$HOME/FilmsLink" "$HOME/Keys"

# Folders on /mnt drives are mounted under /lepton/shared, not at their /mnt
# path (Android hides /mnt). Needs a writable folder under /mnt on this host.
mntdir=""
for d in /mnt/*/; do [[ -w "$d" ]] && mntdir="$(mktemp -d "${d}lepton-shared-test.XXXXXX")" && break; done
if [[ -n "$mntdir" ]]; then
    mkdir "$mntdir/Games Media"
    LEPTON_SHARED_FOLDERS="$mntdir/Games Media" run_mounts || { rm -rf -- "$mntdir"; fail "/mnt folder stopped"; }
    shared "Games Media" "$mntdir/Games Media" || { rm -rf -- "$mntdir"; fail "/mnt folder not under /lepton/shared"; }
    rm -rf -- "$mntdir"
else
    echo "SKIP: no writable folder under /mnt for the /mnt mount check"
fi

# --- Which real folders may be shared -----------------------------------------
ERRORS=() PROTECTED=()
HOME_REAL="$(realpath -m -- "$HOME")"
lepton_shared_protected_paths
for p in /run/media/deck/SDCARD /run/media/deck/SDCARD/Films /var/home/deck/Books /var/mnt/data/Films \
         /srv/media /opt/games/saves /tmp/share "$HOME/Books" "$HOME/Music/Lepton"; do
    lepton_shared_host_ok "$p" x || fail "$p refused"
done
for p in / "$HOME" "$work" /home /var/home /mnt /media /var/mnt /run/media /run/media/deck \
         /run/user/1000 /etc/ssh /usr/share /proc/1 /dev/shm /boot /root /var /var/lib/flatpak /var/log \
         "$HOME/.ssh" "$HOME/.local/share/Steam" "$HOME/.config" \
         "$work/tool" "$work/tool/images" "$LEPTON_DATA_DIR" "$HOME/.local/share/lepton-compat-data/x" \
         "$STEAM_COMPAT_DATA_PATH" "$STEAM_COMPAT_DATA_PATH/external" "$steam/steamapps"; do
    if lepton_shared_host_ok "$p" x; then fail "$p accepted"; fi
done

# --- Invalid options: launch stops, nothing at all is changed -----------------
LEPTON_SHARED_FOLDERS="Documents,$books,$films:ro" run_mounts || fail "baseline for invalid tests"
snapshot > "$work/links.good"
mkdir -p "$work/a/Books" "$work/b/Books"; echo x > "$work/file.txt"; mkdir -p "$work/locked"; chmod 000 "$work/locked"
invalid() {
    local value="$1" expect="$2"
    if LEPTON_SHARED_FOLDERS="$value" run_mounts; then fail "invalid option accepted: $value"; fi
    grep -qF -- "$expect" "$work/messages" || fail "no '$expect' for: $value"
    grep -q 'Shared folders unchanged' "$work/messages" || fail "no unchanged message for: $value"
    diff <(snapshot) "$work/links.good" > /dev/null || fail "links changed by invalid option: $value"
}
invalid "Downloads,Photos" "unknown folder 'Photos'"
invalid "$work/a/Books,$work/b/Books" "Books is already used by another item"
invalid "Downloads,$work/a/Books,books=$work/b/Books" "books is already used"
invalid "Downloads,Downloads" "Download is listed twice"
invalid "Music,~/Music" "Music is already used by another item"
invalid "Pictures,pictures=$books" "pictures is already used"
invalid "$books,Library=$books" "is already shared by another item"
invalid "Documents,Stuff=$HOME/Documents" "is already shared by another item"
invalid "Android=$books" "Android is kept for Android"
invalid "$work/Android" "is kept for Android"
invalid ".hidden=$books" "can't be a shared-storage folder name"
invalid "a:b=$books" "can't be a shared-storage folder name"
invalid "Books=relative/path" "give a folder path starting with / or ~/"
invalid "relative/path" "separate folder paths"
invalid "Downloads $books" "separate folder paths from other items with commas"
invalid "$HOME/../x" "without . or .. parts"
invalid "~otheruser/Books" "write ~/ for your home folder"
invalid "$work/file.txt" "is not a folder"
invalid "/" "not the whole of it"
invalid "$HOME" "holds your whole home folder"
invalid "~" "holds your whole home folder"
invalid "$work" "holds your whole home folder"
invalid "/etc" "is a system folder"
invalid "/var/log" "is a system folder"
invalid "Keys=~/.ssh" "hidden folder of your home"
invalid "$STEAM_COMPAT_DATA_PATH/baked" "holds Lepton's own data"
invalid "$STEAM_COMPAT_DATA_PATH/.." "without . or .. parts"
invalid "$steam/steamapps" "holds Lepton's own data"
invalid "Downloads"$'\n'"$books" "control character"
if [[ $(id -u) != 0 ]]; then invalid "$work/locked" "don't have permission"; fi
chmod 755 "$work/locked"
# Every problem is reported, not just the first.
LEPTON_SHARED_FOLDERS="Photos,Android=$books,$work/file.txt" run_mounts || true
[[ "$(grep -c 'ERROR: LEPTON_SHARED_FOLDERS' "$work/messages")" == 3 ]] || fail "not every problem reported"
# A foreign link where a custom folder goes is found before anything changes.
LEPTON_SHARED_FOLDERS="Documents,$books" run_mounts
ln -s /elsewhere "$ext/Films"
if LEPTON_SHARED_FOLDERS="$films" run_mounts; then fail "foreign Films link replaced"; fi
link_is /elsewhere "$ext/Films" || fail "foreign Films link changed"
shared Documents "$HOME/Documents" && link_is /lepton/shared/Books "$ext/Books" ||
    fail "other links changed before the foreign-link stop"
rm -f "$ext/Films"

# --- lepton-play profile: data root outside every mounted path ----------------
unset STEAM_COMPAT_LIBRARY_PATHS LEPTON_SHARED_FOLDERS
export STEAM_COMPAT_DATA_PATH="$work/lepton-compat-data/org.example.game"
mkdir -p "$STEAM_COMPAT_DATA_PATH"
ext="$STEAM_COMPAT_DATA_PATH/external"
run_mounts || fail "lepton-play profile stopped"
mounted "$ext" || fail "lepton-play external not mounted (dangling /data/media/0)"
link_is "$ext" "$STEAM_COMPAT_DATA_PATH/baked/data_overlay/media/0" || fail "lepton-play media/0 link"
all_defaults_shared || fail "lepton-play default folders"
LEPTON_SHARED_FOLDERS="Music,$books" run_mounts || fail "lepton-play custom stopped"
shared Music "$HOME/Music" && shared Books "$books" || fail "lepton-play custom folders"

# The experimental /lepton alias (run-apk.sh) keeps its own mount only.
export STEAM_COMPAT_DATA_PATH="$work/lepton-compat-data/org.example.alias"
mkdir -p "$STEAM_COMPAT_DATA_PATH"
ext="$STEAM_COMPAT_DATA_PATH/external"
LEPTON_PROFILE_EXTERNAL_STORAGE=/lepton/profile-external run_mounts || fail "alias profile stopped"
grep -qxF -- "type=bind,source=$ext,destination=/lepton/profile-external,rw" "$work/mounts" || fail "alias mount"
! mounted "$ext" || fail "alias profile also mounted at host path"
link_is /lepton/profile-external "$STEAM_COMPAT_DATA_PATH/baked/data_overlay/media/0" || fail "alias media/0 link"

echo "PASS: shared folders and profile shared storage"
