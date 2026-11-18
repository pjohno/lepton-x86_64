#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Drive lepton-google-play-gui with scripted zenity/kdialog stand-ins and a
# fake lepton-add-game that records its arguments. Steam is never invoked.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$work/tools" "$work/bin" "$work/home/Downloads"
cp "$repo/compat_tool/tools/lepton-google-play-gui" "$work/tools/"
gui="$work/tools/lepton-google-play-gui"
U1="$work/Steam/userdata/123" U2="$work/Steam/userdata/456"

# Fake lepton-add-game: list users, status from a file, validation, changes.
cat > "$work/tools/lepton-add-game" <<'PY'
import os, sys
args = sys.argv[1:]
open(os.environ['LOG'], 'a').write(' '.join(args) + '\n')
status = os.environ['STATUS']
if '--list-users' in args:
    print(os.environ['USERS'], end=''); sys.exit(0)
if '--status' in args:
    print(open(status).read() if os.path.exists(status) else '', end=''); sys.exit(0)
user = args[args.index('--userdata') + 1] if '--userdata' in args else os.environ['U1']
art = [a.split('=', 1) for i, a in enumerate(args) if i and args[i - 1] == '--artwork']
for kind, path in art:
    if 'bad' in path:
        print('ERROR: %s is not a valid PNG, JPEG or ICO image' % path); sys.exit(1)
if '--dry-run' in args:
    print('PASS: valid'); sys.exit(0)
if os.environ.get('FAKE_ADD_FAIL'):
    print('ERROR: Steam is still running. Exit Steam completely. Nothing was changed.'); sys.exit(1)
open(os.environ['UI_LOG'], 'a').write('CHANGE ' + ' '.join(args) + '\n')
if '--artwork-only' not in args:
    open(status, 'a').write('%s\t3000000001\tGoogle Play (Lepton)\t\n' % user)
print('Steam AppID: 3000000001')
for kind, _ in art:
    print('Imported ' + kind)
PY
cat > "$work/bin/zenity" <<'SH'
#!/bin/bash
text=''; for a in "$@"; do [[ "$a" == --text=* ]] && text="${a#--text=}"; done
echo "zenity $1 ${text%%$'\n'*}" >> "$UI_LOG"
case "$1" in
  --question) echo "Q: $text" >> "$UI_LOG.full"
              [[ -n "${NO_ON:-}" && "$text" =~ $NO_ON ]] && exit 1; exit 0 ;;
  --file-selection) answer="$(head -n 1 "$PICKS")"; sed -i 1d "$PICKS"
              [[ "$answer" != CANCEL && -n "$answer" ]] || exit 1; printf '%s\n' "$answer" ;;
  --list) printf '%s\n' "$LIST_PICK" ;;
  --info|--error) printf '%s\n---\n' "$text" >> "$UI_LOG.$1" ;;
esac
SH
cat > "$work/bin/kdialog" <<'SH'
#!/bin/bash
echo "kdialog $*" >> "$UI_LOG"
case " $* " in
  *' --yesno '*) [[ -n "${NO_ON:-}" && "$*" =~ $NO_ON ]] && exit 1; exit 0 ;;
  *' --getopenfilename '*) answer="$(head -n 1 "$PICKS")"; sed -i 1d "$PICKS"
              [[ "$answer" != CANCEL && -n "$answer" ]] || exit 1; printf '%s\n' "$answer" ;;
  *' --radiolist '*) printf '%s\n' "$LIST_PICK" ;;
esac
SH
printf '#!/bin/sh\necho steam >> "$UI_LOG.steam"\n' > "$work/bin/steam"
chmod +x "$work/bin/"*
reset() { rm -f "$work/log" "$work/ui"* "$work/status"; : > "$work/picks"; }
picks() { printf '%s\n' "$@" > "$work/picks"; }
run() { env HOME="$work/home" PATH="$work/bin:/usr/bin:/bin" LEPTON_DIALOG="${UI:-zenity}" LOG="$work/log" \
            UI_LOG="$work/ui" STATUS="$work/status" PICKS="$work/picks" U1="$U1" \
            USERS="${USERS:-$U1	Player One
}" "$@" bash "$gui" ${GUI_ARGS:-}; }
calls() { grep -c -- "$1" "$work/log" || true; }

# Installer offer declined: nothing read beyond the question, nothing changed.
reset; NO_ON='Would you like to add Google Play' GUI_ARGS=--offer run
[[ ! -e "$work/log" ]] || fail 'declined offer ran lepton-add-game'
grep -q 'Would you like to add Google Play to your Steam library' "$work/ui.full"

# Accepted; artwork skipped: validate, ask for Steam to be closed, then add.
reset; NO_ON='Optional: Steam library artwork' GUI_ARGS=--offer run
grep -qx -- '--google-play --dry-run' "$work/log"
grep -qx -- '--google-play' "$work/log"
[[ "$(calls '--userdata')" == 0 ]]
grep -q 'Steam must be fully closed before Lepton changes its library' "$work/ui.full"
# The user confirms Steam is closed before Steam's files are changed.
[[ "$(grep -n 'Ready to add' "$work/ui" | cut -d: -f1)" -lt "$(grep -n '^CHANGE --google-play$' "$work/ui" | cut -d: -f1)" ]]
grep -q 'Google Play (Lepton) was added to Steam' "$work/ui.--info"
grep -q 'safe to start Steam again' "$work/ui.--info"
not_order=$(awk '/--google-play --dry-run/{d=NR} /^--google-play$/{a=NR} END{print (d<a)?"ok":"bad"}' "$work/log")
[[ "$not_order" == ok ]]

# Several Steam accounts: the user picks one, and every call names it.
reset; USERS="$U1	Player One
$U2	Player Two
" LIST_PICK="$U2" NO_ON='Optional: Steam library artwork' run
grep -qx -- "--google-play --userdata $U2 --dry-run" "$work/log"
grep -qx -- "--google-play --userdata $U2" "$work/log"
[[ "$(grep -c -- '--userdata' "$work/log")" == 2 ]]
reset; USERS="$U1	Player One
$U2	Player Two
" LIST_PICK='' run
[[ "$(calls '--google-play --dry-run')" == 0 ]] || fail 'no account chosen but continued'

# Artwork: portrait chosen, horizontal skipped, a bad hero then skipped,
# logo chosen, icon skipped. One import call with only the valid files.
reset; picks "$work/home/Downloads/cover.png" CANCEL "$work/home/Downloads/bad.png" \
             "$work/home/Downloads/logo.png" CANCEL
NO_ON='cannot be used as the Hero' run
grep -qx -- "--google-play --artwork-only --artwork portrait=$work/home/Downloads/cover.png --artwork logo=$work/home/Downloads/logo.png" "$work/log"
grep -q 'steamgriddb.com/game/5451976' "$work/ui.full"
grep -q 'Lepton does not download or include artwork' "$work/ui.full"
grep -q 'Artwork imported. It is now safe to start Steam again' "$work/ui.--info"
# Only once the last change is made is Steam declared safe to start.
[[ "$(grep -c 'safe to start Steam again' "$work/ui.--info")" == 1 ]]

# Already in Steam: left unchanged (never re-added); existing artwork is
# only replaced after confirmation.
reset; printf '%s\t3000000001\tMy Store\tportrait,hero\n' "$U1" > "$work/status"
picks CANCEL "$work/home/Downloads/new-hero.png" CANCEL CANCEL   # horizontal, hero, logo, icon
NO_ON='already has a Portrait' run
[[ "$(calls '^--google-play$')" == 0 ]] && [[ "$(calls '--dry-run$')" == 0 ]]
grep -q 'already in your Steam library ("My Store")' "$work/ui.--info"
grep -q 'already has a Hero' "$work/ui.full"
grep -qx -- "--google-play --artwork-only --artwork hero=$work/home/Downloads/new-hero.png --replace-artwork hero" "$work/log"
reset; printf '%s\t3000000001\tGoogle Play (Lepton)\t\n' "$U1" > "$work/status"
NO_ON='Import Steam library artwork for it now' run
[[ "$(wc -l < "$work/log")" == 2 ]]   # list users + status only

# Artwork later (menu entry): needs the shortcut and a closed Steam.
reset; GUI_ARGS=--artwork run && fail 'artwork without shortcut accepted' || true
grep -q 'Google Play is not in Steam yet' "$work/ui.--error"
reset; printf '%s\t3000000001\tGoogle Play (Lepton)\t\n' "$U1" > "$work/status"
picks CANCEL CANCEL CANCEL CANCEL "$work/home/Downloads/icon.png"
GUI_ARGS=--artwork run
grep -q 'Steam must be fully closed' "$work/ui.full"
grep -qx -- "--google-play --artwork-only --artwork icon=$work/home/Downloads/icon.png" "$work/log"
reset; printf '%s\t3000000001\tGoogle Play (Lepton)\t\n' "$U1" > "$work/status"
NO_ON='Steam must be fully closed' GUI_ARGS=--artwork run
[[ "$(calls '--artwork-only')" == 0 ]]

# Failures: the add is refused (e.g. Steam still running); cancel at the
# Steam step changes nothing.
reset; if FAKE_ADD_FAIL=1 run; then fail 'add failure reported success'; fi
grep -q "Steam's shortcuts were not changed" "$work/ui.--error"
reset; NO_ON='Ready to add' run
[[ "$(calls '^--google-play$')" == 0 ]]
grep -q 'Google Play was not added' "$work/ui.--info"

# kdialog works too.
reset; UI=kdialog NO_ON='Optional: Steam library artwork' run
grep -qx -- '--google-play' "$work/log"

[[ ! -e "$work/ui.steam" ]] || fail 'GUI started Steam'
grep -Eq '^[^#]*\bsteam\b +-' "$gui" && fail 'GUI invokes steam'
echo 'PASS: Google Play GUI: offer, add after Steam is closed, accounts, optional/invalid/existing artwork, later import, failures, kdialog; never runs Steam'
