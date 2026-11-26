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
          lepton_shared_folder_entries lepton_trim lepton_array_has lepton_shared_check_custom \
          lepton_shared_name_ok lepton_shared_host_ok remove_empty_android_folder share_host_folder \
          setup_shared_folders setup_mounts; do
    eval "$(sed -n "/^function $fn()/,/^}/p" "$repo/compat_tool/liblepton/mounting.sh")"
    declare -F "$fn" > /dev/null || { echo "FAIL: $fn not found"; exit 1; }
done
eval "$(grep -E '^LEPTON_SHARED_(FOLDER_PAIRS|GUEST_ROOT|RESERVED_NAMES)=' "$repo/compat_tool/liblepton/mounting.sh")"
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

# --- Custom host folders (any path, mounted under /lepton/shared) -------------
export STEAM_COMPAT_DATA_PATH="$steam/steamapps/compatdata/456"
mkdir -p "$STEAM_COMPAT_DATA_PATH"
ext="$STEAM_COMPAT_DATA_PATH/external"
mounted_at() { grep -qxF -- "type=bind,source=$1,destination=$2,${3:-rw}" "$work/mounts"; }
shared() { mounted_at "$2" "/lepton/shared/$1" "${3:-rw}" && link_is "/lepton/shared/$1" "$ext/$1"; }
count_mounts() { grep -c -- "destination=/lepton/shared/" "$work/mounts" || true; }
books="$HOME/Books"; films="$work/media/USB Drive/Films"; outside="$work/srv/Comics"
mkdir -p "$books" "$films" "$outside"

# A single path: shown under its final name.
LEPTON_SHARED_FOLDERS="$books" run_mounts || fail "single custom path stopped"
shared Books "$books" || fail "Books not shared at /lepton/shared/Books"
for n in Documents Download Movies; do [[ ! -L "$ext/$n" ]] || fail "$n linked when only a path is listed"; done
grep -qF "Shared folder Books: $books (read-write)" "$work/messages" || fail "no message for custom folder"
# ~/ is expanded by Lepton (Steam passes it quoted), trailing / ignored.
LEPTON_SHARED_FOLDERS="~/Books/" run_mounts || fail "~/ path stopped"
shared Books "$books" || fail "~/Books not shared"

# Mixture of default names and paths, with spaces and outside HOME.
LEPTON_SHARED_FOLDERS="Downloads, $books ,$films,Strips=$outside" run_mounts || fail "mixed list stopped"
link_is "$HOME/Downloads" "$ext/Download" && mounted "$HOME/Downloads" || fail "Download not shared in mixed list"
shared Books "$books" && shared Films "$films" && shared Strips "$outside" || fail "custom folders in mixed list"
[[ "$(count_mounts)" == 3 ]] || fail "expected 3 custom mounts, got $(count_mounts)"
for n in Documents Movies; do [[ ! -L "$ext/$n" ]] || fail "$n linked though not listed"; done
# The future APK library's layout: only user_storage is shared, under the
# package name; the APK and obb/ next to it are not.
lib="$HOME/Android_library/com.example.game"; mkdir -p "$lib/user_storage" "$lib/obb"; touch "$lib/com.example.game.12334.apk"
LEPTON_SHARED_FOLDERS="Downloads,com.example.game=~/Android_library/com.example.game/user_storage" run_mounts ||
    fail "library user_storage stopped"
shared com.example.game "$lib/user_storage" || fail "library user_storage not shared"
! grep -qE "source=$lib(/obb)?," "$work/mounts" || fail "library folder or obb shared"

# Old space-separated default names still work next to comma-separated paths.
LEPTON_SHARED_FOLDERS="Documents Videos,$books" run_mounts || fail "spaces + path stopped"
link_is "$HOME/Documents" "$ext/Documents" && link_is "$HOME/Videos" "$ext/Movies" && shared Books "$books" ||
    fail "spaces + path mapping"
[[ ! -L "$ext/Download" ]] || fail "Download linked in spaces + path"

# Repeated launch: same links, same mounts, no stray messages.
cp "$work/mounts" "$work/mounts.before"; find "$ext" -maxdepth 1 -printf '%f %l\n' | sort > "$work/links.before"
LEPTON_SHARED_FOLDERS="Documents Videos,$books" run_mounts || fail "repeat launch stopped"
cmp -s "$work/mounts" "$work/mounts.before" || fail "repeat launch changed the mounts"
diff <(find "$ext" -maxdepth 1 -printf '%f %l\n' | sort) "$work/links.before" > /dev/null || fail "repeat launch changed links"
! grep -q 'off\|WARNING\|ERROR' "$work/messages" || fail "repeat launch reported changes"

# Read-only, for a path and a default folder.
LEPTON_SHARED_FOLDERS="$films:ro,Downloads:RO" run_mounts || fail ":ro stopped"
shared Films "$films" ro || fail "Films not read-only"
mounted_at "$HOME/Downloads" "$HOME/Downloads" ro && link_is "$HOME/Downloads" "$ext/Download" || fail "Downloads not read-only"
grep -qF "Shared folder Films: $films (read-only)" "$work/messages" || fail "no read-only message"

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
echo keep > "$ext/notes.txt"; mkdir -p "$ext/Pictures"; echo photo > "$ext/Pictures/p.jpg"
ln -s /somewhere/else "$ext/MyLink"; ln -s /lepton/shared/Other "$ext/Odd"
unset LEPTON_SHARED_FOLDERS
run_mounts || fail "back to default stopped"
[[ ! -L "$ext/Novels" ]] || fail "Novels link kept after removal"
link_is "$HOME/Downloads" "$ext/Download" || fail "default not restored"
[[ "$(count_mounts)" == 0 ]] || fail "custom mounts left after removal"
[[ "$(cat "$ext/notes.txt")" == keep && "$(cat "$ext/Pictures/p.jpg")" == photo ]] || fail "Android files changed"
link_is /somewhere/else "$ext/MyLink" && link_is /lepton/shared/Other "$ext/Odd" || fail "unrelated links changed"
[[ -d "$books" && -d "$films" && -d "$outside" && -d "$other" ]] || fail "host folders touched"

# A custom name over Android's own folder: empty -> linked; with files -> kept.
pics="$HOME/Pictures"; mkdir -p "$pics"
LEPTON_SHARED_FOLDERS="$pics" run_mounts || fail "Pictures with files stopped the launch"
[[ -d "$ext/Pictures" && ! -L "$ext/Pictures" && "$(cat "$ext/Pictures/p.jpg")" == photo ]] || fail "Android Pictures changed"
! mounted_at "$pics" /lepton/shared/Pictures || fail "Pictures mounted though not linked"
grep -q 'Shared folder Pictures not linked' "$work/messages" || fail "no message for kept Pictures"
rm -rf -- "$ext/Pictures"; mkdir "$ext/Pictures"
LEPTON_SHARED_FOLDERS="$pics" run_mounts || fail "Pictures over empty folder stopped"
shared Pictures "$pics" || fail "empty Android Pictures not replaced"
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
rm -f "$HOME/FilmsLink"

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
# /run/media drives are allowed; other /run folders are system folders.
ERRORS=()
lepton_shared_host_ok /run/media/deck/SDCARD/Films x "" || fail "/run/media drive folder refused"
lepton_shared_host_ok /run/media/deck/SDCARD x "" || fail "/run/media drive root refused"
for p in /run/user/1000 /run/media/deck /etc/ssh /usr/share /proc/1 /dev/shm; do
    if lepton_shared_host_ok "$p" x ""; then fail "system folder $p accepted"; fi
done

# --- Invalid options: launch stops, nothing at all is changed -----------------
LEPTON_SHARED_FOLDERS="Documents,$books,$films:ro" run_mounts || fail "baseline for invalid tests"
snapshot() { find "$ext" -maxdepth 1 -printf '%f %l\n' | sort; }
snapshot > "$work/links.good"
mkdir -p "$work/a/Books" "$work/b/Books"; echo x > "$work/file.txt"; mkdir -p "$work/locked"; chmod 000 "$work/locked"
invalid() {
    local value="$1" expect="$2"
    if LEPTON_SHARED_FOLDERS="$value" run_mounts; then fail "invalid option accepted: $value"; fi
    grep -qF -- "$expect" "$work/messages" || fail "no '$expect' for: $value"
    grep -q 'Shared folders unchanged' "$work/messages" || fail "no unchanged message for: $value"
    diff <(snapshot) "$work/links.good" > /dev/null || fail "links changed by invalid option: $value"
}
invalid "Downloads,Pictures" "unknown folder 'Pictures'"
invalid "$work/a/Books,$work/b/Books" "Books is already used by another item"
invalid "Downloads,$work/a/Books,books=$work/b/Books" "books is already used"
invalid "Downloads,Downloads" "Download is listed twice"
invalid "$books,Library=$books" "is already shared by another item"
invalid "Documents,Stuff=$HOME/Documents" "is already shared by another item"
invalid "Android=$books" "Android is kept for Android"
invalid "download=$books" "download is kept"
invalid "$work/Movies" "Movies is kept"
invalid ".hidden=$books" "can't be a shared-storage folder name"
invalid "a:b=$books" "can't be a shared-storage folder name"
invalid "Books=relative/path" "give a folder path starting with / or ~/"
invalid "relative/path" "separate folder paths"
invalid "Downloads $books" "separate folder paths from other items with commas"
invalid "$HOME/../x" "without . or .. parts"
invalid "~otheruser/Books" "write ~/ for your home folder"
invalid "$work/file.txt" "is not a folder"
invalid "/" "not the whole of it"
invalid "$HOME" "not the whole of it"
invalid "~" "not the whole of it"
invalid "/etc" "is a system folder"
invalid "$STEAM_COMPAT_DATA_PATH/baked" "holds this game's Android data"
invalid "$STEAM_COMPAT_DATA_PATH/.." "without . or .. parts"
invalid "$steam/steamapps" "holds this game's Android data"
invalid "Downloads"$'\n'"$books" "control character"
if [[ $(id -u) != 0 ]]; then invalid "$work/locked" "don't have permission"; fi
chmod 755 "$work/locked"
# Every problem is reported, not just the first.
LEPTON_SHARED_FOLDERS="Pictures,Android=$books,$work/file.txt" run_mounts || true
[[ "$(grep -c 'ERROR: LEPTON_SHARED_FOLDERS' "$work/messages")" == 3 ]] || fail "not every problem reported"
# A foreign link where a custom folder goes is found before anything changes.
LEPTON_SHARED_FOLDERS="Documents,$books" run_mounts
ln -s /elsewhere "$ext/Films"
if LEPTON_SHARED_FOLDERS="$films" run_mounts; then fail "foreign Films link replaced"; fi
link_is /elsewhere "$ext/Films" || fail "foreign Films link changed"
link_is "$HOME/Documents" "$ext/Documents" && link_is /lepton/shared/Books "$ext/Books" ||
    fail "other links changed before the foreign-link stop"
rm -f "$ext/Films"

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
