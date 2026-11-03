#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Exercise the real deployment packaging entrypoint with a tiny synthetic stage.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
deploy="$repo/image-14/scripts/deploy-compat-x86_64.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
stage="$work/stage"; out="$work/bundles"
mkdir -p "$stage/compat_tool/liblepton" "$stage/compat_tool/tools" \
    "$stage/compat_tool/sysbake/system" "$stage/compat_tool/images/rootfs/system/etc/init/hw" \
    "$stage/compat_tool/images/rootfs/vendor/lib64/hw" \
    "$stage/compat_tool/images/rootfs_overlay/system/bin" "$stage/tools/platform-tools" "$stage/tools/bin"
for file in lepton toolmanifest.vdf liblepton/liblepton.sh liblepton/app_metadata.sh liblepton/mounting.sh liblepton/baking.sh; do
    printf '#!/bin/sh\n' > "$stage/compat_tool/$file"
done
printf 'binderfs-ensure\n' > "$stage/compat_tool/images/rootfs/system/etc/init/hw/init.rc"
printf 'ro.build.version.sdk=34\nro.dalvik.vm.native.bridge=0\n' > "$stage/compat_tool/images/rootfs/system/build.prop"
printf 'test-radv\n' > "$stage/compat_tool/images/rootfs/vendor/lib64/hw/vulkan.radeon.so"
printf '#!/bin/sh\n' > "$stage/compat_tool/images/rootfs_overlay/system/bin/binderfs-ensure"
chmod +x "$stage/compat_tool/images/rootfs_overlay/system/bin/binderfs-ensure"
printf '# stale networking from an older stage\n' > "$stage/compat_tool/liblepton/networking.sh"
printf '<packages/>\n' > "$stage/compat_tool/sysbake/system/packages.xml"
printf '# file: sysbake/system/packages.xml\nuser.fake=0x31\nsecurity.selinux=0x32\n' > "$stage/compat_tool/sysbake.xattrs"
mkdir -p "$stage/compat_tool/liblepton/apk_extractor/target" "$stage/compat_tool/images/rootfs/system/target"
printf 'host build cache' > "$stage/compat_tool/liblepton/apk_extractor/target/host-cache"
printf 'required Android asset' > "$stage/compat_tool/images/rootfs/system/target/required"
printf '#!/bin/sh\n' > "$stage/tools/platform-tools/adb"
printf '#!/bin/sh\n' > "$stage/tools/bin/inotifywait"
cp "$stage/compat_tool/sysbake.xattrs" "$work/original-xattrs"
run() { bash "$deploy" "$@"; }
reject() { if run "$@" > "$work/rejected.log" 2>&1; then echo "FAIL: unexpectedly accepted $*"; exit 1; fi; }
export TRACE="$work/remote.log"
mkdir "$work/bin"
for command in ssh rsync; do
    if [[ "$command" == rsync ]]; then
        # Allow local staging, but mock any remote transfer.
        real_rsync="$(command -v rsync)"
        printf '#!/bin/bash\nfor arg in "$@"; do if [[ "$arg" == deck@* ]]; then echo rsync >> "$TRACE"; exit 0; fi; done\nexec %q "$@"\n' "$real_rsync" > "$work/bin/rsync"
    else
        # Keep the desktop entry the transfer writes on the Deck for validation.
        printf '#!/bin/sh\necho ssh >> "$TRACE"\ncase "$*" in *Desktop*) cat > "$TRACE.desktop";; esac\n' > "$work/bin/ssh"
    fi
    chmod +x "$work/bin/$command"
done
export PATH="$work/bin:$PATH"
run --package-only --check --stage-dir "$stage" --bundle-dir "$out" --bundle-id fixture --deck-ip 192.0.2.1 > "$work/check.log"
[[ ! -e "$out" && ! -e "$TRACE" ]]
reject --package-only --check --stage-dir "$stage" --bundle-dir "$stage/recursive" --bundle-id fixture
reject --package-only --check --stage-dir "$stage" --bundle-dir "$out" --bundle-id '../wrong'
reject --package-only --check --stage-dir "$stage" --bundle-dir "$out" --bundle-id fixture --with-ndk
reject --bundle-id fixture
reject --package-only --check --stage-dir "$stage" --bundle-dir "$out" --bundle-id fixture --deck-ip 999.0.0.1
run --package-only --execute --stage-dir "$stage" --bundle-dir "$out" --bundle-id fixture > "$work/package.log"
archive="$out/lepton-x86_64-steamdeck-fixture.tar.gz"
(cd "$out" && sha256sum -c "$(basename "$archive").sha256")
tar -xOf "$archive" ./compat_tool/sysbake.xattrs > "$work/packaged-xattrs"
! grep -q '^security.selinux=' "$work/packaged-xattrs"
grep -qx 'user.fake=0x31' "$work/packaged-xattrs"
cmp "$work/original-xattrs" "$stage/compat_tool/sysbake.xattrs"
tar -tzf "$archive" > "$work/contents"
grep -qx './compat_tool/liblepton/ndk_auxv/runtime.sh' "$work/contents"
grep -qx './compat_tool/images/rootfs/system/target/required' "$work/contents"
! grep -q 'apk_extractor/target/' "$work/contents"
tar -xOf "$archive" ./compat_tool/toolmanifest.vdf | grep -Fq '"commandline" "/lepton-x86_64-entry %verb% --"'
grep -qx './compat_tool/lepton-x86_64-entry' "$work/contents"
for file in compat_tool/liblepton/properties.sh compat_tool/liblepton/networking.sh compat_tool/images/rootfs_overlay/system/bin/cmd tests/runtime/run-apk.sh tests/runtime/unpack-apkm.py tests/runtime/read-gsf-id.py; do
    tar -xOf "$archive" "./$file" > "$work/packaged-source"
    cmp "$repo/$file" "$work/packaged-source"
done
! rg -q 'runtime-profile|podman-storage|apks/' "$work/contents"
tar -xOf "$archive" ./BUNDLE.json > "$work/BUNDLE.json"
python3 - "$work/BUNDLE.json" <<'PYMETA'
import json, sys
metadata = json.load(open(sys.argv[1]))
assert metadata['tool_id'] == 'lepton_x86_64_fixture'
assert metadata['install_directory'] == 'lepton_x86_64_fixture'
PYMETA
# Deck installer, run against a throwaway home (no real Steam/user files).
installer="$out/lepton-x86_64-steamdeck-fixture.install.sh"
[[ -x "$installer" ]]
grep -Fq ' lepton-x86_64-steamdeck-fixture.install.sh' "$archive.sha256"
deck_home="$work/deck-home"
mkdir -p "$deck_home"
# LEPTON_INSTALL_IN_TERMINAL stops the installer reopening itself in Konsole.
deck() { env -u XDG_DATA_HOME -u XDG_CONFIG_HOME LEPTON_INSTALL_IN_TERMINAL=1 LEPTON_NO_DIALOGS=1 HOME="$deck_home" bash "$installer" --allow-non-amd "$@"; }
manage() { env -u XDG_DATA_HOME -u XDG_CONFIG_HOME HOME="$deck_home" python3 "$deck_home/.local/bin/lepton-manage-installs" "$@"; }
mkdir -p "$deck_home/Desktop"
deck --check > "$work/install-check.log"
! grep -q 'Press Enter' "$work/install-check.log"
# --pause ends with the close prompt, on success and on failure (stdin at EOF
# makes the prompt return at once).
deck --check --pause < /dev/null > "$work/install-pause.log"
grep -q '^\[DONE\] Finished successfully' "$work/install-pause.log"
grep -q 'Press Enter to close this window (it closes by itself in 60 seconds)' "$work/install-pause.log"
if deck --pause --bogus < /dev/null > "$work/install-fail.log" 2>&1; then echo 'FAIL: bad option accepted'; exit 1; fi
grep -q 'closes by itself in 600 seconds' "$work/install-fail.log"
dest="$deck_home/.local/share/lepton_x86_64_fixture"
[[ ! -e "$dest" && ! -e "$deck_home/.config" ]]
deck > "$work/install.log"
[[ -x "$dest/compat_tool/lepton" && -f "$dest/BUNDLE.json" ]]
vdf="$deck_home/.local/share/Steam/compatibilitytools.d/lepton_x86_64_fixture.vdf"
grep -Fq "\"$dest/compat_tool\"" "$vdf"
grep -Fq '"Lepton x86_64 (community) - fixture"' "$vdf"
[[ "$(readlink "$deck_home/.config/lepton-x86_64/default.env")" == lepton_x86_64_fixture.env ]]
( source "$deck_home/.config/lepton-x86_64/lepton_x86_64_fixture.env"; [[ "$LEPTON_X86_INSTALL_DIR" == "$dest" ]] )
[[ "$(readlink -f "$deck_home/.local/bin/lepton-add-game")" == "$dest/compat_tool/tools/lepton-add-game" ]]
[[ "$(readlink -f "$deck_home/.local/bin/lepton-run-apk")" == "$dest/tests/runtime/run-apk.sh" ]]
[[ "$(readlink -f "$deck_home/.local/bin/lepton-add-game-gui")" == "$dest/compat_tool/tools/lepton-add-game-gui" ]]
grep -Fqx "Exec=\"$deck_home/.local/bin/lepton-add-game-gui\"" "$deck_home/.local/share/applications/lepton-x86_64-add-game.desktop"
grep -Fq -- '--gpu-check --execute' "$deck_home/.local/share/applications/lepton-x86_64-gpu-check.desktop"
grep -Fq "lepton-in-terminal\" \"$deck_home/.local/bin/lepton-run-apk\"" "$deck_home/.local/share/applications/lepton-x86_64-gpu-check.desktop"
! grep -q -- '--hold' "$deck_home/.local/share/applications/lepton-x86_64-gpu-check.desktop"
[[ "$(readlink -f "$deck_home/.local/bin/lepton-in-terminal")" == "$dest/compat_tool/tools/lepton-in-terminal" ]]
[[ -x "$deck_home/Desktop/lepton-x86_64-add-game.desktop" && -x "$deck_home/Desktop/lepton-x86_64-gpu-check.desktop" ]]
if command -v desktop-file-validate >/dev/null; then
    desktop-file-validate "$deck_home/.local/share/applications/"lepton-x86_64-*.desktop
fi
# The linked helper resolves its own install without flags.
HOME="$deck_home" python3 - "$deck_home/.local/bin/lepton-add-game" "$dest" <<'PYADD'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader('add_game', sys.argv[1])
module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(module)
assert (module.TOOL, str(module.INSTALL)) == ('lepton_x86_64_fixture', sys.argv[2]), (module.TOOL, module.INSTALL)
PYADD
if deck > "$work/reinstall.log" 2>&1; then echo 'FAIL: installer overwrote an existing install'; exit 1; fi
grep -q -- '--replace' "$work/reinstall.log"
# --replace overwrites in place and removes the old copy unless --keep-previous.
deck --replace > "$work/replace.log"
! compgen -G "$dest.previous-*" > /dev/null
# ...but an old copy holding saved app profiles is always kept.
mkdir -p "$dest/.runtime-profile.playgames"
manage --list | grep -q '1 saved app profile(s)'
deck --replace > "$work/replace-profile.log"
grep -q 'contains saved app profiles' "$work/replace-profile.log"
kept="$(compgen -G "$dest.previous-*")"
[[ -d "$kept/.runtime-profile.playgames" ]]
manage --remove "$(basename "$kept")" | grep -q 'deletes 1 saved app profile(s)'
manage --remove "$(basename "$kept")" --execute > /dev/null
! compgen -G "$dest.previous-*" > /dev/null
[[ -x "$dest/compat_tool/lepton" ]]
deck --replace --keep-previous > "$work/replace-keep.log"
compgen -G "$dest.previous-*" > /dev/null
manage --list > "$work/list.log"
grep -q '^\* lepton_x86_64_fixture$' "$work/list.log"
grep -q 'Backup of lepton_x86_64_fixture' "$work/list.log"
backup="$(basename "$(compgen -G "$dest.previous-*")")"
manage --remove "$backup" > "$work/remove-check.log"
grep -q 'Nothing was changed' "$work/remove-check.log"
compgen -G "$dest.previous-*" > /dev/null
manage --remove "$backup" --execute > "$work/remove.log"
! compgen -G "$dest.previous-*" > /dev/null
[[ -x "$dest/compat_tool/lepton" ]]

# A Steam shortcut mapped to the fixture tool (as lepton-add-game writes it).
mkdir -p "$deck_home/.local/share/Steam/config"
printf '"CompatToolMapping"\n{\n"1"\n{\n"name"\t\t"lepton_x86_64_fixture"\n}\n}\n' > "$deck_home/.local/share/Steam/config/config.vdf"
manage --list | grep -q '1 Steam shortcut(s)'

# A legacy, manually installed lepton-x86_64-dev registered with Steam.
legacy="$deck_home/.local/share/lepton-x86_64-dev"
mkdir -p "$legacy/compat_tool/liblepton"
printf '#!/bin/sh\n' > "$legacy/compat_tool/lepton"
printf '"compatibilitytools"\n{\n  "compat_tools"\n  {\n    "lepton_x86_64_dev"\n    {\n      "install_path" "%s/compat_tool"\n      "display_name" "Lepton x86_64 dev"\n    }\n  }\n}\n' "$legacy" \
    > "$deck_home/.local/share/Steam/compatibilitytools.d/lepton_x86_64_dev.vdf"
manage --list | grep -q '^  lepton_x86_64_dev$'
# A running process inside an install blocks overwriting/removing it.
(cd "$legacy" && exec sleep 30) &
busy=$!
if deck --into lepton_x86_64_dev > "$work/into-busy.log" 2>&1; then echo 'FAIL: overwrote a running install'; exit 1; fi
grep -q 'is running' "$work/into-busy.log"
if manage --remove lepton_x86_64_dev --execute > "$work/remove-busy.log" 2>&1; then echo 'FAIL: removed a running install'; exit 1; fi
kill "$busy"; wait "$busy" 2>/dev/null || true
# Overwrite the legacy install: same tool ID and directory, new contents and name.
deck --into lepton_x86_64_dev > "$work/into.log"
[[ -f "$legacy/BUNDLE.json" && ! -e "$deck_home/.local/share/lepton_x86_64_dev" ]]
python3 - "$legacy/BUNDLE.json" <<'PYINTO'
import json, sys
m = json.load(open(sys.argv[1]))
assert (m['tool_id'], m['install_directory'], m['packaged_tool_id']) == ('lepton_x86_64_dev', 'lepton-x86_64-dev', 'lepton_x86_64_fixture'), m
PYINTO
grep -Fq "\"$legacy/compat_tool\"" "$deck_home/.local/share/Steam/compatibilitytools.d/lepton_x86_64_dev.vdf"
grep -Fq '"Lepton x86_64 (community) - fixture"' "$deck_home/.local/share/Steam/compatibilitytools.d/lepton_x86_64_dev.vdf"
! compgen -G "$legacy.previous-*" > /dev/null
[[ "$(readlink "$deck_home/.config/lepton-x86_64/default.env")" == lepton_x86_64_dev.env ]]
[[ "$(readlink -f "$deck_home/.local/bin/lepton-add-game")" == "$legacy/compat_tool/tools/lepton-add-game" ]]
# --into requires an existing install.
if deck --into lepton_missing > "$work/into-missing.log" 2>&1; then echo 'FAIL: --into missing accepted'; exit 1; fi
# Remove the default install: default moves to the remaining install.
manage --remove lepton_x86_64_dev --execute > "$work/remove-default.log"
[[ ! -e "$legacy" && ! -e "$deck_home/.local/share/Steam/compatibilitytools.d/lepton_x86_64_dev.vdf" ]]
[[ "$(readlink "$deck_home/.config/lepton-x86_64/default.env")" == lepton_x86_64_fixture.env ]]
[[ "$(readlink -f "$deck_home/.local/bin/lepton-add-game")" == "$dest/compat_tool/tools/lepton-add-game" ]]
grep -q 'Default install: Lepton x86_64 (community) - fixture' "$work/remove-default.log"
# Installer --remove: validated before any change, applied after success.
mkdir -p "$legacy/compat_tool/liblepton" && printf '#!/bin/sh\n' > "$legacy/compat_tool/lepton"
manage --list | grep -q 'Unregistered lepton-x86_64-dev'
if deck --replace --remove lepton_unknown > "$work/remove-unknown.log" 2>&1; then echo 'FAIL: unknown --remove accepted'; exit 1; fi
if deck --replace --remove lepton_x86_64_fixture > "$work/remove-self.log" 2>&1; then echo 'FAIL: removed itself'; exit 1; fi
grep -q 'would remove the install being created' "$work/remove-self.log"
deck --replace --remove "$(basename "$legacy")" > "$work/replace-remove.log"
[[ ! -e "$legacy" && -x "$dest/compat_tool/lepton" ]]
# Desktop-icon install (--pause + display): scripted zenity chooses to replace
# a registered legacy install, then ticks the fixture install for removal.
mkdir -p "$legacy/compat_tool/liblepton" && printf '#!/bin/sh\n' > "$legacy/compat_tool/lepton"
printf '"compatibilitytools"\n{\n "compat_tools"\n {\n  "lepton_x86_64_dev"\n  {\n   "install_path" "%s/compat_tool"\n   "display_name" "Lepton dev"\n  }\n }\n}\n' "$legacy" \
    > "$deck_home/.local/share/Steam/compatibilitytools.d/lepton_x86_64_dev.vdf"
mkdir -p "$work/gui-bin"
cat > "$work/gui-bin/zenity" <<'SH'
#!/bin/bash
echo "zenity $*" >> "$UI_LOG"
case "$1" in
  --list) if [[ " $* " == *" --radiolist "* ]]; then echo lepton_x86_64_dev; else echo lepton_x86_64_fixture; fi ;;
  --question) exit 0 ;;
esac
SH
chmod +x "$work/gui-bin/zenity"
env -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u LEPTON_NO_DIALOGS LEPTON_INSTALL_IN_TERMINAL=1 LEPTON_DIALOG=zenity \
    WAYLAND_DISPLAY=test-display UI_LOG="$work/gui-install.log" PATH="$work/gui-bin:$PATH" HOME="$deck_home" \
    bash "$installer" --allow-non-amd --pause < /dev/null > "$work/gui-install.out"
grep -q 'zenity --list --radiolist' "$work/gui-install.log"
grep -q 'zenity --list --checklist' "$work/gui-install.log"
[[ -f "$legacy/BUNDLE.json" && ! -e "$dest" ]]
[[ ! -e "$deck_home/.local/share/Steam/compatibilitytools.d/lepton_x86_64_fixture.vdf" ]]
[[ "$(readlink "$deck_home/.config/lepton-x86_64/default.env")" == lepton_x86_64_dev.env ]]
grep -q 'Press Enter to close' "$work/gui-install.out"
mkdir -p "$stage/compat_tool/images/rootfs/system/product/priv-app/PrebuiltGmsCore"
printf 'synthetic' > "$stage/compat_tool/images/rootfs/system/product/priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk"
mkdir -p "$stage/compat_tool/images/rootfs/system/framework"
python3 - "$stage/compat_tool/images/rootfs/system/framework/services.jar" <<'PYJAR'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as jar:
    jar.writestr('classes.dex', b'StartLocaleManagerService StartCrossProfileAppsService persist.lepton.forward_web_intents')
PYJAR
run --package-only --execute --stage-dir "$stage" --bundle-dir "$out" --bundle-id gapps-fixture > "$work/gapps-package.log"
tar -xOf "$out/lepton-x86_64-steamdeck-gapps-fixture.tar.gz" ./BUNDLE.json > "$work/gapps.json"
python3 - "$work/gapps.json" <<'PYMETA'
import json, sys
metadata = json.load(open(sys.argv[1]))
assert metadata['tool_id'] == 'lepton_gapps_gapps_fixture'
assert metadata['install_directory'] == metadata['tool_id']
assert metadata['gapps'] is True and metadata['ndk'] is False
PYMETA
reject --package-only --check --stage-dir "$stage" --bundle-dir "$out" --bundle-id invalid-tool --tool-id ../bad
[[ ! -e "$TRACE" ]]
reject --package-only --execute --stage-dir "$stage" --bundle-dir "$out" --bundle-id fixture
run --transfer-only --check --bundle-dir "$out" --bundle-id fixture --deck-ip 192.0.2.1 > "$work/transfer-check.log"
[[ ! -e "$TRACE" ]]
run --transfer-only --execute --bundle-dir "$out" --bundle-id fixture --deck-ip 192.0.2.1 > "$work/transfer.log"
[[ $(wc -l < "$TRACE") == 4 ]]  # ssh mkdir, rsync, ssh verify, ssh desktop icon
sed "s|@HOME@|/home/deck|g" "$TRACE.desktop" > "$work/lepton-install-fixture.desktop"
grep -Fqx 'Exec=konsole -e bash "/home/deck/Downloads/lepton-deck-bundles/lepton-x86_64-steamdeck-fixture.install.sh" --pause' "$work/lepton-install-fixture.desktop"
if command -v desktop-file-validate >/dev/null; then desktop-file-validate "$work/lepton-install-fixture.desktop"; fi
printf 'broken' >> "$archive"
reject --transfer-only --check --bundle-dir "$out" --bundle-id fixture --deck-ip 192.0.2.1
echo 'PASS: read-only packaging/transfer checks, real archive, xattr preservation, overwrite guards and mocked transfer'
