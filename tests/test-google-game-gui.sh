#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Drive lepton-google-game-gui with scripted dialogs, a fake tool entry (runs
# until SIGTERM, like a Lepton launch) and a fake lepton-add-game. The game's
# data must land in Steam's compatdata for its AppID; Steam is never invoked.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
home="$work/home"
root="$home/.local/share/lepton_gapps_x"
compat="$home/.local/share/Steam/steamapps/compatdata"
mkdir -p "$root/compat_tool/tools" "$root/tests/runtime" "$work/bin" "$home/Downloads" \
         "$root/compat_tool/images/rootfs/system/product/priv-app/PrebuiltGmsCore"
touch "$root/compat_tool/images/rootfs/system/product/priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk"
cp "$repo/compat_tool/tools/lepton-google-game-gui" "$root/compat_tool/tools/"
gui="$root/compat_tool/tools/lepton-google-game-gui"

# Fake tool entry: records the Steam-style environment, then "runs" until TERM.
cat > "$root/compat_tool/lepton-x86_64-entry" <<'SH'
#!/bin/bash
echo "entry $* signin=$LEPTON_GOOGLE_SIGNIN appid=$SteamAppId data=$STEAM_COMPAT_DATA_PATH nobridge=$LEPTON_NO_BRIDGE" >> "$LOG"
trap 'echo "stopped-by-TERM signin=$LEPTON_GOOGLE_SIGNIN" >> "$LOG"; exit 0' TERM
[[ -z "${FAKE_FAIL:-}" || "$LEPTON_GOOGLE_SIGNIN" != "$FAKE_FAIL" ]] || { echo 'ERROR: boot failed'; exit 1; }
mkdir -p "$STEAM_COMPAT_DATA_PATH/baked/data_overlay"
echo "Waiting for app com.example.game to exit..."
while :; do sleep 0.2; done
SH
cat > "$root/compat_tool/tools/lepton-add-game" <<'PY'
import os, sys
if '--print-appid' in sys.argv:
    print(os.environ.get('FAKE_APPID', '3999999999')); sys.exit(0)
open(os.environ['LOG'], 'a').write('add-game ' + ' '.join(sys.argv[1:]) + '\n')
if os.environ.get('FAKE_ADD_FAIL') and '--dry-run' not in sys.argv:
    print('ERROR: Steam is still running. Nothing was changed.'); sys.exit(1)
print('Added Steam shortcut')
PY
printf 'print(3912345678901234567)\n' > "$root/tests/runtime/read-gsf-id.py"
chmod +x "$root/compat_tool/lepton-x86_64-entry"
# podman unshare python3 READER DB -> run the reader directly.
printf '#!/bin/sh\n[ "$1" = unshare ] && shift && exec "$@"\n' > "$work/bin/podman"
cat > "$work/bin/zenity" <<'SH'
#!/bin/bash
echo "zenity $1" >> "$UI_LOG"
case "$1" in
  --file-selection) printf '%s\n' "$PICK" ;;
  --entry) printf '%s\n' "$NAME_ANSWER" ;;
  --list) printf '%s\n' "$LIST_PICK" ;;
  --question) text=''; for a in "$@"; do [[ "$a" == --text=* ]] && text="${a#--text=}"; done
              echo "Q: $text" >> "$UI_LOG"
              [[ -n "${NO_ON:-}" && "$text" == *"$NO_ON"* ]] && exit 1; exit 0 ;;
  --progress) while IFS= read -r line; do echo "P: $line" >> "$UI_LOG"
                  [[ "$line" == 100 ]] && exit 0
                  [[ "$line" =~ ${DONE_ON:-tap Done} ]] && exit 1; done; exit 0 ;;
  --info|--error) for a in "$@"; do [[ "$a" == --text=* ]] && printf '%s\n' "${a#--text=}" >> "$UI_LOG.$1"; done ;;
esac
SH
printf '#!/bin/sh\necho steam >> "$UI_LOG.steam"\n' > "$work/bin/steam"
chmod +x "$work/bin/"*
touch "$home/Downloads/Game.apkm"
run() { env HOME="$home" PATH="$work/bin:/usr/bin:/bin" LEPTON_DIALOG=zenity LOG="$work/log" UI_LOG="$work/ui" \
            WAYLAND_DISPLAY=wayland-test "$@" bash "$gui"; }
reset() { rm -f "$work/log" "$work/ui"*; }
data="$compat/3999999999"

# Full flow: sign-in launch, check launch (both stopped with TERM), normal shortcut.
reset; DONE_ON='register ID|is open' run PICK="$home/Downloads/Game.apkm" NAME_ANSWER='My Game'
grep -qx "entry waitforexitandrun -- $home/Downloads/Game.apkm signin=true appid=3999999999 data=$data nobridge=true" "$work/log"
grep -qx "entry waitforexitandrun -- $home/Downloads/Game.apkm signin=false appid=3999999999 data=$data nobridge=true" "$work/log"
grep -qx 'stopped-by-TERM signin=true' "$work/log" && grep -qx 'stopped-by-TERM signin=false' "$work/log"
[[ "$(cat "$data/lepton-google-game")" == "$home/Downloads/Game.apkm"$'\n''My Game' ]]
grep -qx "add-game $home/Downloads/Game.apkm --name My Game --dry-run" "$work/log"
grep -qx "add-game $home/Downloads/Game.apkm --name My Game" "$work/log"
! grep -q -- '--runtime-profile' "$work/log"
grep -q 'register ID 3912345678901234567' "$work/ui"
grep -q 'It is now safe to start Steam again' "$work/ui.--info"

# Existing data: "Skip sign-in" goes straight to checking.
reset; NO_ON='already has saved Android data' run PICK="$home/Downloads/Game.apkm" NAME_ANSWER='My Game'
! grep -q 'signin=true' "$work/log"; grep -q 'signin=false' "$work/log"

# Failures stop before Steam.
reset; command rm -rf "$compat"
if FAKE_FAIL=true run PICK="$home/Downloads/Game.apkm" NAME_ANSWER='My Game'; then echo 'FAIL: sign-in failure accepted'; exit 1; fi
grep -q 'Android stopped before sign-in finished' "$work/ui.--error"; ! grep -q add-game "$work/log"
reset
if NO_ON='already has saved' FAKE_FAIL=false run PICK="$home/Downloads/Game.apkm" NAME_ANSWER='My Game'; then echo 'FAIL: game failure accepted'; exit 1; fi
grep -q 'could not be started' "$work/ui.--error"; ! grep -q add-game "$work/log"
reset
if NO_ON='already has saved' FAKE_ADD_FAIL=1 run PICK="$home/Downloads/Game.apkm" NAME_ANSWER='My Game'; then echo 'FAIL: add failure accepted'; exit 1; fi
grep -q 'Steam is still running. Nothing was changed.' "$work/ui.--error"
reset; NO_ON='Step 3 of 3' run PICK="$home/Downloads/Game.apkm" NAME_ANSWER='My Game' || true
! grep -qx "add-game $home/Downloads/Game.apkm --name My Game" "$work/log"

# Sign in again: lists Google games by their marker.
reset; env HOME="$home" PATH="$work/bin:/usr/bin:/bin" LEPTON_DIALOG=zenity LOG="$work/log" UI_LOG="$work/ui" \
    WAYLAND_DISPLAY=wayland-test LIST_PICK=3999999999 bash "$gui" --sign-in
grep -q "signin=true appid=3999999999 data=$data" "$work/log"
grep -q 'Sign-in finished for "My Game"' "$work/ui.--info"

# Never Steam; no Google services -> clear error.
[[ ! -e "$work/ui.steam" ]]
command rm "$root/compat_tool/images/rootfs/system/product/priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk"
reset
if run PICK=x NAME_ANSWER=x; then echo 'FAIL: non-GApps install accepted'; exit 1; fi
grep -q 'no Google services' "$work/ui.--error"
echo 'PASS: Google game window (normal path): sign-in and check launches in the shortcut compatdata, TERM stop, GSF ID, normal shortcut, failures, sign-in again'
