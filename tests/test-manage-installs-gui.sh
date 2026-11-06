#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Drive lepton-manage-installs' windows with scripted zenity/kdialog stand-ins
# against synthetic installs in a throwaway home.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tool="$repo/compat_tool/tools/lepton-manage-installs"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
home="$work/home"
mkdir -p "$work/bin" "$home/.local/share/Steam/compatibilitytools.d" "$home/.config/lepton-x86_64"

make_install() {  # make_install TOOL_ID DISPLAY_NAME
    local dir="$home/.local/share/$1"
    mkdir -p "$dir/compat_tool/liblepton" "$dir/compat_tool/tools"
    printf '#!/bin/sh\n' > "$dir/compat_tool/lepton"
    printf '#!/bin/sh\n' > "$dir/compat_tool/tools/lepton-add-game"
    printf '"compatibilitytools"\n{\n "compat_tools"\n {\n  "%s"\n  {\n   "install_path" "%s/compat_tool"\n   "display_name" "%s"\n  }\n }\n}\n' \
        "$1" "$dir" "$2" > "$home/.local/share/Steam/compatibilitytools.d/$1.vdf"
    printf 'LEPTON_X86_TOOL_ID=%s\nLEPTON_X86_INSTALL_DIR=%s\n' "$1" "$dir" > "$home/.config/lepton-x86_64/$1.env"
}

cat > "$work/bin/zenity" <<'SH'
#!/bin/bash
echo "zenity $*" >> "$UI_LOG"
case "$1" in
  --list) printf '%s\n' "$@" > "$UI_LOG.list"; [[ "$PICK" == __cancel__ ]] && exit 1; printf '%s\n' "$PICK" ;;
  --question) exit "${CONFIRM_RC:-0}" ;;
  --info|--error) for a in "$@"; do [[ "$a" == --text=* ]] && printf '%s\n' "${a#--text=}" > "$UI_LOG.$1"; done ;;
esac
SH
cat > "$work/bin/kdialog" <<'SH'
#!/bin/bash
echo "kdialog $*" >> "$UI_LOG"
case "$3" in
  --checklist) printf '"%s"\n' "$PICK" ;;
  --yesno) exit 0 ;;
  --msgbox) printf '%s\n' "$4" > "$UI_LOG.--info" ;;
esac
SH
chmod +x "$work/bin/zenity" "$work/bin/kdialog"
run() { env -u XDG_DATA_HOME -u XDG_CONFIG_HOME HOME="$home" PATH="$work/bin:/usr/bin:/bin" \
        LEPTON_DIALOG="${DIALOG:-zenity}" UI_LOG="$work/ui.log" "$@"; }
manage() { run python3 "$tool" "$@"; }
reset() { rm -f "$work/ui.log"*; }

make_install lepton_a 'Lepton A'
make_install lepton_b 'Lepton B'
ln -s lepton_a.env "$home/.config/lepton-x86_64/default.env"

# Choose-target: "new" is preselected; picking an install returns its ID.
reset
[[ "$(PICK=lepton_b manage --gui-choose-target --new-id lepton_c --new-name 'Lepton C')" == lepton_b ]]
grep -qx -- '--radiolist' "$work/ui.log.list"
grep -Fqx 'Install as a new tool: Lepton C (keep the others)' "$work/ui.log.list"
grep -Fq 'Replace Lepton B' "$work/ui.log.list"
if PICK=__cancel__ manage --gui-choose-target --new-id lepton_c --new-name C > /dev/null; then echo 'FAIL: cancel accepted'; exit 1; fi

# Removal list: cancel, or "no" at confirmation, changes nothing.
reset; PICK=__cancel__ manage --gui
reset; PICK=lepton_b CONFIRM_RC=1 manage --gui
[[ -d "$home/.local/share/lepton_b" ]]
# --exclude hides the given install.
reset; PICK=__cancel__ manage --gui --exclude lepton_a
! grep -Fq 'Lepton A' "$work/ui.log.list"
grep -qx -- '--checklist' "$work/ui.log.list"

# A running install cannot be removed; the error is shown.
(cd "$home/.local/share/lepton_b" && exec sleep 30) &
busy=$!
reset
if PICK=lepton_b manage --gui; then echo 'FAIL: running install removed'; exit 1; fi
grep -q 'is running' "$work/ui.log.--error"
kill "$busy"; wait "$busy" 2>/dev/null || true
[[ -d "$home/.local/share/lepton_b" ]]

# Remove B; default A is untouched.
reset; PICK=lepton_b manage --gui
[[ ! -e "$home/.local/share/lepton_b" && ! -e "$home/.local/share/Steam/compatibilitytools.d/lepton_b.vdf" ]]
[[ ! -e "$home/.config/lepton-x86_64/lepton_b.env" ]]
grep -q 'Removed: Lepton B' "$work/ui.log.--info"
[[ "$(readlink "$home/.config/lepton-x86_64/default.env")" == lepton_a.env ]]

# Nothing else left: --quiet-if-empty shows no dialog at all.
reset; PICK=x manage --gui --exclude lepton_a --quiet-if-empty
[[ ! -e "$work/ui.log" ]]
# The bundle being installed is already installed (double-clicked again):
# "Reinstall" is offered and preselected, never "new"; cancel changes nothing.
reset
[[ "$(PICK=lepton_a manage --gui-choose-target --new-id lepton_a --new-name A)" == lepton_a ]]
grep -Fqx 'Reinstall A over the existing copy (its Steam shortcuts and game data are kept)' "$work/ui.log.list"
grep -A1 -x -- '--hide-column=2' "$work/ui.log.list" | grep -qx TRUE
not() { if "$@"; then echo "FAIL: unexpectedly succeeded: $*" >&2; exit 1; fi; }
not grep -Fq 'Install as a new tool' "$work/ui.log.list"
if PICK=__cancel__ manage --gui-choose-target --new-id lepton_a --new-name A > /dev/null; then echo 'FAIL: cancel accepted'; exit 1; fi
# No installs at all: "new" without any dialog.
mv "$home/.config/lepton-x86_64" "$work/config-aside"; mv "$home/.local/share/Steam/compatibilitytools.d" "$work/vdf-aside"
mkdir -p "$home/.local/share/Steam/compatibilitytools.d"; reset
[[ "$(PICK=x manage --gui-choose-target --new-id lepton_z --new-name Z)" == new ]]
[[ ! -e "$work/ui.log" ]]
rm -rf "$home/.local/share/Steam/compatibilitytools.d"
mv "$work/config-aside" "$home/.config/lepton-x86_64"; mv "$work/vdf-aside" "$home/.local/share/Steam/compatibilitytools.d"

# kdialog: quoted checklist output; removing the last install clears links.
make_install lepton_b 'Lepton B'
mkdir -p "$home/.local/bin" "$home/.local/share/applications"
ln -s "$home/.local/share/lepton_a/compat_tool/tools/lepton-add-game" "$home/.local/bin/lepton-add-game"
touch "$home/.local/share/applications/lepton-x86_64-add-game.desktop"
reset; DIALOG=kdialog PICK=lepton_b manage --gui
[[ ! -e "$home/.local/share/lepton_b" ]]
manage --remove lepton_a --execute > "$work/last.log"
grep -q 'Default install: none' "$work/last.log"
[[ ! -e "$home/.config/lepton-x86_64/default.env" && ! -L "$home/.local/bin/lepton-add-game" ]]
[[ ! -e "$home/.local/share/applications/lepton-x86_64-add-game.desktop" ]]
echo 'PASS: manage-installs windows: choose target, cancel/confirm, exclude, running-install guard, default handling, kdialog'
