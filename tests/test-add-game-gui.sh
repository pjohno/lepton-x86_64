#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Drive lepton-add-game-gui with scripted zenity/kdialog stand-ins and a fake
# lepton-add-game; no real dialogs, Steam or user files are touched.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/tools" "$work/bin" "$work/home/Downloads"
cp "$repo/compat_tool/tools/lepton-add-game-gui" "$work/tools/"
apk="$work/home/Downloads/My Game.apk"
touch "$apk"
# Fake lepton-add-game: record arguments; fail when FAKE_ADD_FAIL matches the mode.
cat > "$work/tools/lepton-add-game" <<'PY'
import os, sys
open(os.environ['LOG'], 'a').write(repr(sys.argv[1:]) + '\n')
mode = 'dry' if '--dry-run' in sys.argv else 'add'
if os.environ.get('FAKE_ADD_FAIL') == mode:
    print('ERROR: simulated ' + mode + ' failure'); sys.exit(1)
print('Added Steam shortcut: ' + sys.argv[sys.argv.index('--name') + 1])
PY
# Scripted zenity: answers come from environment variables.
cat > "$work/bin/zenity" <<'SH'
#!/bin/bash
echo "zenity $1" >> "$UI_LOG"
case "$1" in
  --file-selection) [[ -n "${PICK:-}" ]] && printf '%s\n' "$PICK" || exit 1 ;;
  --entry) printf '%s\n' "$NAME_ANSWER" ;;
  --question) exit "${CONFIRM_RC:-0}" ;;
  --progress) cat > /dev/null ;;
  --info|--error) for a in "$@"; do [[ "$a" == --text=* ]] && printf '%s\n' "${a#--text=}" > "$UI_LOG.$1"; done ;;
esac
SH
chmod +x "$work/bin/zenity"
gui() { env LEPTON_DIALOG=zenity HOME="$work/home" PATH="$work/bin:/usr/bin:/bin" LOG="$work/add.log" UI_LOG="$work/ui.log" "$@" bash "$work/tools/lepton-add-game-gui"; }
reset() { rm -f "$work/add.log" "$work/ui.log"*; }

# Success: dry run first, then --restart-steam with the chosen name.
reset
gui PICK="$apk" NAME_ANSWER='Nice Name'
grep -Fqx "['$apk', '--name', 'Nice Name', '--dry-run']" "$work/add.log"
grep -Fqx "['$apk', '--name', 'Nice Name', '--restart-steam']" "$work/add.log"
grep -Fq 'Touchscreen Native Support' "$work/ui.log.--info"

# Cancel at file picker or confirmation: nothing is added.
reset; gui PICK='' NAME_ANSWER=x
[[ ! -e "$work/add.log" ]]
reset; gui PICK="$apk" NAME_ANSWER=x CONFIRM_RC=1
! grep -q -- '--restart-steam' "$work/add.log"

# Validation error stops before Steam is touched; add failure is reported.
reset
if gui PICK="$apk" NAME_ANSWER=x FAKE_ADD_FAIL=dry; then echo 'FAIL: dry-run error accepted'; exit 1; fi
! grep -q -- '--restart-steam' "$work/add.log"
grep -Fq 'simulated dry failure' "$work/ui.log.--error"
reset
if gui PICK="$apk" NAME_ANSWER=x FAKE_ADD_FAIL=add; then echo 'FAIL: add error accepted'; exit 1; fi
grep -Fq 'simulated add failure' "$work/ui.log.--error"

# Empty name falls back to the APK file name.
reset; gui PICK="$apk" NAME_ANSWER=''
grep -Fq "'--name', 'My Game', '--restart-steam'" "$work/add.log"

# kdialog fallback when zenity is absent.
rm "$work/bin/zenity"
cat > "$work/bin/kdialog" <<'SH'
#!/bin/bash
echo "kdialog $*" >> "$UI_LOG"
case "$3" in
  --getopenfilename) printf '%s\n' "$PICK" ;;
  --inputbox) printf '%s\n' "$NAME_ANSWER" ;;
esac
SH
chmod +x "$work/bin/kdialog"
reset; gui LEPTON_DIALOG=kdialog PICK="$apk" NAME_ANSWER='KDE Name'
grep -Fqx "['$apk', '--name', 'KDE Name', '--restart-steam']" "$work/add.log"
grep -q 'kdialog --title .* --msgbox' "$work/ui.log"
# lepton-in-terminal: keeps the command's status and always ends with the prompt.
wrap="$repo/compat_tool/tools/lepton-in-terminal"
bash "$wrap" true < /dev/null > "$work/wrap-ok.log"
grep -q 'closes by itself in 60 seconds' "$work/wrap-ok.log"
if bash "$wrap" sh -c 'exit 3' < /dev/null > "$work/wrap-fail.log"; then echo 'FAIL: status lost'; exit 1; fi
grep -q 'exit status 3' "$work/wrap-fail.log"
grep -q 'closes by itself in 600 seconds' "$work/wrap-fail.log"
echo 'PASS: add-game GUI success, cancel, validation/add errors, default name and kdialog fallback; terminal close prompt'
