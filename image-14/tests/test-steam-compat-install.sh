#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# The bundle installer with both layouts, end to end: real packaged bundles
# and their real installers in a throwaway home with ~/.steam/root ->
# ~/.local/share/Steam and an unrelated GE-Proton. Covers --check, traditional
# and --steam-compat installs and updates, explicit migration (tool ID, saved
# profiles and game mappings kept), rollback, duplicate tool IDs, names,
# add-game, the graphical layout choice and removal. ADB is a fake download;
# no real Steam, Podman or Android is used.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
work="$(mktemp -d)"
trap 'chmod -R u+rwX -- "$work" 2>/dev/null; rm -rf -- "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
not() { if "$@"; then fail "unexpectedly succeeded: $*"; fi; }
source "$repo/image-14/tests/lib/fake-google-adb.sh"

# A minimal complete stage (as in test-release-install.sh).
stage="$work/stage"; out="$work/bundles"
mkdir -p "$stage/compat_tool/liblepton" "$stage/compat_tool/sysbake/system" \
    "$stage/compat_tool/images/rootfs/system/etc/init/hw" "$stage/compat_tool/images/rootfs/vendor/lib64/hw" \
    "$stage/compat_tool/images/rootfs_overlay/system/bin" "$stage/tools/bin"
for file in lepton toolmanifest.vdf liblepton/liblepton.sh liblepton/app_metadata.sh liblepton/mounting.sh liblepton/baking.sh; do
    printf '#!/bin/sh\n' > "$stage/compat_tool/$file"
done
printf 'binderfs-ensure\n' > "$stage/compat_tool/images/rootfs/system/etc/init/hw/init.rc"
printf 'ro.build.version.sdk=34\nro.dalvik.vm.native.bridge=0\n' > "$stage/compat_tool/images/rootfs/system/build.prop"
printf 'test-radv\n' > "$stage/compat_tool/images/rootfs/vendor/lib64/hw/vulkan.radeon.so"
printf '#!/bin/sh\n' > "$stage/compat_tool/images/rootfs_overlay/system/bin/binderfs-ensure"
chmod +x "$stage/compat_tool/images/rootfs_overlay/system/bin/binderfs-ensure"
printf '<packages/>\n' > "$stage/compat_tool/sysbake/system/packages.xml"
printf '# file: sysbake/system/packages.xml\nuser.fake=0x31\n' > "$stage/compat_tool/sysbake.xattrs"
printf '#!/bin/sh\n' > "$stage/tools/bin/inotifywait"
mkdir -p "$stage/compat_tool/liblepton/ndk_auxv/bin"
printf 'void fixture(void) {}\n' | cc -x c -shared -nostdlib -fPIC \
    -Wl,-soname,liblepton_ndk_auxv.so -o "$stage/compat_tool/liblepton/ndk_auxv/bin/liblepton_ndk_auxv.so" -

fake_sha="$(fake_adb_zip "$work/fake-adb")"
package() {   # package BUNDLE_ID [--tool-name NAME]
    bash "$repo/image-14/scripts/internal/deploy-compat-x86_64.sh" --package-only --execute \
        --stage-dir "$stage" --bundle-dir "$out" --bundle-id "$@" > "$work/package-$1.log" 2>&1 ||
        { cat "$work/package-$1.log"; fail "packaging $1"; }
    local name="lepton-x86_64-$1"
    pin_installer "$out/$name.install.sh" "$work/pinned.sh" "$fake_sha"
    mv -- "$work/pinned.sh" "$out/$name.install.sh"
    (cd "$out" && sha256sum "$name.tar.gz" "$name.install.sh" > "$name.tar.gz.sha256")
}
package v0.1.0-alpha
package v0.2.0-alpha
package oldname --tool-name 'Lepton x86_64 (community) - oldname'   # a bundle named the old way
package custom --tool-name 'My Lepton'                               # an explicit name

home="$work/home"
steam="$home/.local/share/Steam"; tools="$steam/compatibilitytools.d"; config="$home/.config/lepton-x86_64"
mkdir -p "$steam/userdata/1/config" "$steam/config" "$tools/GE-Proton9-20" "$home/.steam" "$home/Desktop"
ln -s ../.local/share/Steam "$home/.steam/root"
cat > "$tools/GE-Proton9-20/compatibilitytool.vdf" <<'VDF'
"compatibilitytools"
{
  "compat_tools"
  {
    "GE-Proton9-20"
    {
      "install_path" "."
      "display_name" "GE-Proton9-20"
      "from_oslist" "windows"
      "to_oslist" "linux"
    }
  }
}
VDF
printf '#!/bin/sh\n' > "$tools/GE-Proton9-20/proton"
proton_sum="$(cd "$tools/GE-Proton9-20" && sha256sum compatibilitytool.vdf proton)"
# A game shortcut already mapped to the first tool, and its Android data.
cat > "$steam/config/config.vdf" <<'VDF'
"InstallConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"CompatToolMapping"
				{
					"2000000000"
					{
						"name"		"lepton_x86_64_v0_1_0_alpha"
						"config"		""
						"priority"		"250"
					}
				}
			}
		}
	}
}
VDF
mapping_sum="$(sha256sum < "$steam/config/config.vdf")"
mkdir -p "$steam/steamapps/compatdata/2000000000/baked"
echo 'level 7' > "$steam/steamapps/compatdata/2000000000/baked/save"
printf 'ID=steamos\nNAME="SteamOS"\n' > "$work/steamos"

inst() {   # inst BUNDLE_ID [installer options...]
    local bundle="$1"; shift
    env -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u DISPLAY -u WAYLAND_DISPLAY HOME="$home" \
        PATH="${EXTRA_PATH:+$EXTRA_PATH:}$PATH" LEPTON_SKIP_HOST_CHECK=1 LEPTON_INSTALL_IN_TERMINAL=1 \
        LEPTON_NO_DIALOGS=1 LEPTON_HOST_OS_RELEASE="$work/steamos" \
        bash "$out/lepton-x86_64-$bundle.install.sh" --allow-non-amd --adb-zip "$work/fake-adb/platform-tools.zip" \
        "$@" < /dev/null > "$work/out" 2>&1
}
manage() { env -u XDG_DATA_HOME -u XDG_CONFIG_HOME HOME="$home" python3 "$repo/compat_tool/tools/lepton-manage-installs" "$@"; }
# Every path, type, mode, size, file time and link target. Directory times are
# left out: --check extracts into a temporary folder inside ~/.local/share.
snapshot() { (cd "$home" && find . \( -type d -printf '%p d %m\n' \) -o -printf '%p %y %m %s %T@ %l\n' | LC_ALL=C sort); }
# shellcheck source=/dev/null
envval() { (source "$config/$1.env"; printf '%s' "${!2}"); }
registered_name() { sed -n 's/.*"display_name" "\(.*\)"/\1/p' "$1"; }
legacy_dir="$home/.local/share/lepton_x86_64_v0_1_0_alpha"
steam_dir="$tools/lepton_x86_64_v0_1_0_alpha"

# 1. --check changes nothing, in either layout.
before="$(snapshot)"
inst v0.1.0-alpha --check --steam-compat || { cat "$work/out"; fail 'steam-compat check'; }
grep -q 'Layout: self-contained Steam compatibility tool' "$work/out"
grep -q "Install directory: $(realpath "$tools")/lepton_x86_64_v0_1_0_alpha" "$work/out"
inst v0.1.0-alpha --check || { cat "$work/out"; fail 'legacy check'; }
[[ "$(snapshot)" == "$before" ]] || fail '--check changed files'

# 2. Traditional install: Lepton's folder plus a standalone registration.
inst v0.1.0-alpha || { cat "$work/out"; fail 'legacy install'; }
[[ -x "$legacy_dir/compat_tool/lepton" && -f "$tools/lepton_x86_64_v0_1_0_alpha.vdf" && ! -e "$steam_dir" ]]
[[ "$(registered_name "$tools/lepton_x86_64_v0_1_0_alpha.vdf")" == 'lepton v0.1.0-alpha x86_64 (community)' ]] ||
    fail 'version-first name (legacy)'
[[ "$(envval lepton_x86_64_v0_1_0_alpha LEPTON_X86_LAYOUT)" == legacy ]]

# 3. A second install with the same tool ID is refused, in either layout.
not inst v0.1.0-alpha --steam-compat
grep -q 'already installed at' "$work/out"
not inst v0.1.0-alpha --new

# 4. Updating keeps the layout; the name shows the new version.
inst v0.2.0-alpha --into lepton_x86_64_v0_1_0_alpha || { cat "$work/out"; fail 'legacy update'; }
[[ -f "$tools/lepton_x86_64_v0_1_0_alpha.vdf" && ! -e "$steam_dir" ]] || fail 'update changed the layout'
[[ "$(registered_name "$tools/lepton_x86_64_v0_1_0_alpha.vdf")" == 'lepton v0.2.0-alpha x86_64 (community)' ]] ||
    fail 'name after replacing an older release'
python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert (m["bundle_id"], m["tool_id"]) == ("v0.2.0-alpha", "lepton_x86_64_v0_1_0_alpha")' \
    "$legacy_dir/BUNDLE.json"

# 5. Rollback: a failed registration restores the previous copy.
mkdir -p "$work/failpy"
cat > "$work/failpy/python3" <<'SH'
#!/bin/bash
# Simulated failure of the Steam registration step only.
case "$1" in */lepton-register-tool) echo 'simulated registration failure' >&2; exit 1 ;; esac
exec /usr/bin/env -u EXTRA_PATH PATH="${PATH#*:}" python3 "$@"
SH
chmod +x "$work/failpy/python3"
echo keep > "$legacy_dir/marker"
before="$(snapshot)"
EXTRA_PATH="$work/failpy" not inst v0.1.0-alpha --into lepton_x86_64_v0_1_0_alpha --steam-compat
grep -q 'simulated registration failure' "$work/out" && grep -q 'were restored' "$work/out" ||
    { cat "$work/out"; fail 'rollback not exercised'; }
[[ "$(snapshot)" == "$before" ]] || { diff <(echo "$before") <(snapshot) | head; fail 'failed migration was not rolled back'; }
rm "$legacy_dir/marker"

# 6. Explicit migration into Steam's folder: same tool ID, shortcuts, saved
#    profiles and game data; exactly one registration afterwards.
mkdir -p "$legacy_dir/.runtime-profile.game/data"
echo signed-in > "$legacy_dir/.runtime-profile.game/data/account"
inst v0.2.0-alpha --into lepton_x86_64_v0_1_0_alpha --steam-compat || { cat "$work/out"; fail 'migration'; }
[[ -f "$steam_dir/compatibilitytool.vdf" && ! -e "$tools/lepton_x86_64_v0_1_0_alpha.vdf" && ! -e "$legacy_dir" ]] ||
    fail 'migration left two registrations or the old copy'
[[ "$(cat "$steam_dir/.runtime-profile.game/data/account")" == signed-in ]] || fail 'saved profile lost'
not compgen -G "$home/.local/share/lepton_x86_64_v0_1_0_alpha.previous-*" > /dev/null
[[ "$(envval lepton_x86_64_v0_1_0_alpha LEPTON_X86_LAYOUT)" == steam-compat ]]
[[ "$(envval lepton_x86_64_v0_1_0_alpha LEPTON_X86_INSTALL_DIR)" == "$(realpath "$steam_dir")" ]]
[[ "$(readlink -f "$home/.local/bin/lepton-add-game")" == "$(realpath "$steam_dir")/compat_tool/tools/lepton-add-game" ]]
[[ "$(sha256sum < "$steam/config/config.vdf")" == "$mapping_sum" ]] || fail 'game shortcut mapping changed'
[[ "$(cat "$steam/steamapps/compatdata/2000000000/baked/save")" == 'level 7' ]] || fail 'game data changed'
[[ "$(manage --list --json | python3 -c 'import json,sys; print(sum(e["id"] == "lepton_x86_64_v0_1_0_alpha" for e in json.load(sys.stdin)))')" == 1 ]]
[[ "$(manage --print-layout lepton_x86_64_v0_1_0_alpha)" == steam-compat ]]
grep -Fq '"commandline" "/lepton-x86_64-entry %verb% --"' "$steam_dir/toolmanifest.vdf"
[[ -x "$steam_dir/lepton-x86_64-entry" && -x "$steam_dir/tools/platform-tools/adb" ]]
# add-game finds the self-contained registration (dry run: Steam may be running here).
HOME="$home" python3 "$steam_dir/compat_tool/tools/lepton-add-game" --dry-run --userdata "$steam/userdata/1" \
    "$repo/README.md" > "$work/add-game.out" 2>&1 && fail 'add-game accepted a non-APK'
cp "$out/lepton-x86_64-v0.1.0-alpha.tar.gz" "$work/game.apk"
HOME="$home" python3 "$steam_dir/compat_tool/tools/lepton-add-game" --dry-run --userdata "$steam/userdata/1" \
    "$work/game.apk" > "$work/add-game.out" 2>&1 || { cat "$work/add-game.out"; fail 'add-game with a steam-compat tool'; }
grep -q 'PASS: shortcut and compatibility mapping are valid' "$work/add-game.out"

# 7. Updates of a self-contained install stay there; a kept backup is not
#    registered, so Steam still sees the tool once.
inst v0.2.0-alpha --into lepton_x86_64_v0_1_0_alpha --keep-previous || { cat "$work/out"; fail 'steam-compat update'; }
backups=("$tools"/lepton_x86_64_v0_1_0_alpha.previous-*)
[[ ${#backups[@]} == 1 && -d "${backups[0]}" && ! -e "${backups[0]}/compatibilitytool.vdf" ]] || fail 'backup registered'
[[ -f "$steam_dir/compatibilitytool.vdf" && ! -e "$legacy_dir" && ! -e "$tools/lepton_x86_64_v0_1_0_alpha.vdf" ]]
[[ "$(cat "$steam_dir/.runtime-profile.game/data/account")" == signed-in ]] || fail 'profile lost on update'
manage --list --json | python3 -c '
import json, sys
kinds = sorted(e["kind"] for e in json.load(sys.stdin) if e["id"].startswith("lepton_x86_64_v0_1_0_alpha"))
assert kinds == ["backup", "install"], kinds'
manage --remove "$(basename -- "${backups[0]}")" --execute > /dev/null
[[ ! -e "${backups[0]}" && -f "$steam_dir/compatibilitytool.vdf" ]]

# 8. A failed update of a self-contained install restores it.
echo keep > "$steam_dir/marker"
before="$(snapshot)"
EXTRA_PATH="$work/failpy" not inst v0.2.0-alpha --into lepton_x86_64_v0_1_0_alpha
grep -q 'simulated registration failure' "$work/out" && grep -q 'were restored' "$work/out" ||
    { cat "$work/out"; fail 'rollback not exercised'; }
[[ "$(snapshot)" == "$before" ]] || { diff <(echo "$before") <(snapshot) | head; fail 'failed update was not rolled back'; }
rm "$steam_dir/marker"

# 9. Names: an older-style packaged name is rewritten version first; an
#    explicit name is kept. New installs go where asked.
inst oldname --steam-compat || { cat "$work/out"; fail 'old-name bundle'; }
[[ "$(registered_name "$tools/lepton_x86_64_oldname/compatibilitytool.vdf")" == 'lepton oldname x86_64 (community)' ]] ||
    fail 'old-style name not rewritten'
inst custom || { cat "$work/out"; fail 'custom-name bundle'; }
[[ "$(registered_name "$tools/lepton_x86_64_custom.vdf")" == 'My Lepton' ]] || fail 'explicit name not kept'

# 10. Two installs with one tool ID: listed as a conflict, never replaced.
cp -a "$tools/lepton_x86_64_oldname" "$home/.local/share/lepton_x86_64_oldname"
rm -f "$home/.local/share/lepton_x86_64_oldname/compatibilitytool.vdf"
printf '"compatibilitytools"\n{\n "compat_tools"\n {\n  "lepton_x86_64_oldname"\n  {\n   "install_path" "%s/compat_tool"\n  }\n }\n}\n' \
    "$home/.local/share/lepton_x86_64_oldname" > "$tools/lepton_x86_64_oldname.vdf"
[[ "$(manage --list --json | python3 -c 'import json,sys; print(sum(e["conflict"] for e in json.load(sys.stdin)))')" == 2 ]]
before="$(snapshot)"
not inst oldname --replace
grep -q 'registered by 2 installs' "$work/out" || { cat "$work/out"; fail 'duplicate tool ID not explained'; }
[[ "$(snapshot)" == "$before" ]] || fail 'refused replacement changed files'
manage --remove "$home/.local/share/lepton_x86_64_oldname" --execute > /dev/null
[[ ! -e "$tools/lepton_x86_64_oldname.vdf" && -f "$tools/lepton_x86_64_oldname/compatibilitytool.vdf" ]]

# 11. Double-clicked installer: the layout is chosen in a window.
mkdir -p "$work/gui-bin"
cat > "$work/gui-bin/zenity" <<'SH'
#!/bin/bash
echo "zenity $*" >> "$UI_LOG"
case "$*" in
  *"Where should"*) echo steam-compat ;;
  *"How should"*) echo new ;;
esac
SH
chmod +x "$work/gui-bin/zenity"
package gui
env -u XDG_DATA_HOME -u XDG_CONFIG_HOME HOME="$home" PATH="$work/gui-bin:$PATH" WAYLAND_DISPLAY=test \
    LEPTON_DIALOG=zenity UI_LOG="$work/gui.log" LEPTON_SKIP_HOST_CHECK=1 LEPTON_INSTALL_IN_TERMINAL=1 \
    LEPTON_HOST_OS_RELEASE="$work/steamos" bash "$out/lepton-x86_64-gui.install.sh" --allow-non-amd --pause \
    --adb-zip "$work/fake-adb/platform-tools.zip" < /dev/null > "$work/gui.out" 2>&1 ||
    { cat "$work/gui.out"; fail 'graphical install'; }
grep -q "Where should lepton gui x86_64 (community) be installed" "$work/gui.log"
[[ -f "$tools/lepton_x86_64_gui/compatibilitytool.vdf" ]] || fail 'layout choice ignored'

# 12. Removal of both layouts; other tools and game data stay.
manage --remove lepton_x86_64_v0_1_0_alpha lepton_x86_64_oldname lepton_x86_64_custom lepton_x86_64_gui --execute > /dev/null
[[ "$(cd "$tools" && ls -A)" == GE-Proton9-20 ]] || { ls -A "$tools"; fail 'removal left Lepton files in Steam'; }
[[ "$(cd "$tools/GE-Proton9-20" && sha256sum compatibilitytool.vdf proton)" == "$proton_sum" ]] || fail 'GE-Proton changed'
[[ "$(cat "$steam/steamapps/compatdata/2000000000/baked/save")" == 'level 7' ]] || fail 'game data removed'
not compgen -G "$home/.local/share/lepton_x86_64_*" > /dev/null
not compgen -G "$tools/.lepton-install.*" > /dev/null
echo 'PASS: steam-compat install: --check changes nothing, both layouts, updates keep layout and refresh the version-first name, migration keeps tool ID/profiles/mappings/data with one registration, rollback, duplicate tool IDs refused, names, add-game, layout window, removal leaves GE-Proton'
