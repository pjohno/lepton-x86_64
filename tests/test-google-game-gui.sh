#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Drive lepton-google-game-gui with a scripted zenity, a fake run-apk.sh that
# behaves like Android (ready line, GSF ID, waits until stopped) and a fake
# lepton-add-game. Steam must never be invoked.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
root="$work/home/.local/share/lepton_gapps_x"
mkdir -p "$root/compat_tool/tools" "$root/tests/runtime" "$work/bin" "$work/home/Downloads" \
         "$root/compat_tool/images/rootfs/system/product/priv-app/PrebuiltGmsCore"
touch "$root/compat_tool/images/rootfs/system/product/priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk"
echo '{"tool_id": "lepton_gapps_x"}' > "$root/BUNDLE.json"
cp "$repo/compat_tool/tools/lepton-google-game-gui" "$root/compat_tool/tools/"
gui="$root/compat_tool/tools/lepton-google-game-gui"

# Fake runner: records arguments; setup/app sessions run until SIGTERM.
cat > "$root/tests/runtime/run-apk.sh" <<'SH'
#!/bin/bash
echo "run-apk $*" >> "$LOG"
profile=''; mode=app
while (($#)); do case "$1" in --profile) profile="$2"; shift ;; --setup-only) mode=setup ;; esac; shift; done
root="$(cd "$(dirname "$0")/../.." && pwd)"
trap 'echo "stopped-by-TERM $mode" >> "$LOG"; exit 0' TERM
if [[ "$mode" == setup ]]; then
    [[ -z "${FAKE_SETUP_FAIL:-}" ]] || { echo '[FAIL] boot failed'; exit 1; }
    mkdir -p "$root/.runtime-profile.$profile"
    echo "[INFO] Setup profile ready for 3600s; no game installed"
    echo "[INFO] GSF Android ID: 3912345678901234567"
else
    [[ -z "${FAKE_APP_FAIL:-}" ]] || { echo '[FAIL] Android package installation failed'; exit 1; }
    echo 'com.example.game' > "$root/.runtime-profile.$profile/profile-package"
    echo "[INFO] Launching com.example.game/.Main until exit or stop"
fi
while :; do sleep 0.2; done
SH
cat > "$root/compat_tool/tools/lepton-add-game" <<'PY'
import os, sys
open(os.environ['LOG'], 'a').write('add-game ' + ' '.join(sys.argv[1:]) + '\n')
if os.environ.get('FAKE_ADD_FAIL') and '--dry-run' not in sys.argv:
    print('ERROR: Steam is still running. Nothing was changed.'); sys.exit(1)
print('Added Steam shortcut')
PY
chmod +x "$root/tests/runtime/run-apk.sh"
# Scripted zenity. Progress dialogs: "Done" (exit 1) once a line matches DONE_ON.
cat > "$work/bin/zenity" <<'SH'
#!/bin/bash
echo "zenity $1" >> "$UI_LOG"
case "$1" in
  --file-selection) printf '%s\n' "$PICK" ;;
  --entry) printf '%s\n' "$NAME_ANSWER" ;;
  --list) printf '%s\n' "$PROFILE_PICK" ;;
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
chmod +x "$work/bin/zenity" "$work/bin/steam"
mkapk() { python3 -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr(sys.argv[2],b"x"); z.close()' "$1" "$2"; }
mkapk "$work/home/Downloads/Game.apk" lib/x86_64/libgame.so
mkapk "$work/home/Downloads/ArmGame.apkm" split_config.arm64_v8a.apk
run() { env HOME="$work/home" PATH="$work/bin:/usr/bin:/bin" LEPTON_DIALOG=zenity LOG="$work/log" UI_LOG="$work/ui" "$@" bash "$gui"; }
args() { env HOME="$work/home" PATH="$work/bin:/usr/bin:/bin" LEPTON_DIALOG=zenity LOG="$work/log" UI_LOG="$work/ui" "$@" bash "$gui" --sign-in; }
reset() { rm -f "$work/log" "$work/ui"*; }

# Full flow: sign in (TERM on Done), install/check (TERM on Done), shortcut.
# (Done is tapped once the device-registration ID is shown.)
reset; DONE_ON='register ID|is open' run PICK="$work/home/Downloads/Game.apk" NAME_ANSWER='My Game!'
grep -qx 'run-apk --profile my-game --setup-only --network-sysctls --seconds 3600 --execute' "$work/log"
grep -qx "run-apk --profile my-game --app --expect-abi x86_64 --apk $work/home/Downloads/Game.apk --network-sysctls --until-exit --execute" "$work/log"
grep -qx 'stopped-by-TERM setup' "$work/log" && grep -qx 'stopped-by-TERM app' "$work/log"
grep -qx "add-game $work/home/Downloads/Game.apk --runtime-profile my-game --expect-abi x86_64 --name My Game! --dry-run" "$work/log"
grep -qx "add-game $work/home/Downloads/Game.apk --runtime-profile my-game --expect-abi x86_64 --name My Game!" "$work/log"
grep -q 'register ID 3912345678901234567' "$work/ui"
grep -q 'Q: Step 3 of 3' "$work/ui" && grep -q 'It is now safe to start Steam again' "$work/ui.--info"

# Existing profile: "Skip sign-in" goes straight to installing.
reset; NO_ON='already exists' run PICK="$work/home/Downloads/Game.apk" NAME_ANSWER='My Game!'
! grep -q -- '--setup-only' "$work/log"
grep -q -- '--app' "$work/log"

# ARM64-only game uses the ARM64 ABI.
reset; run PICK="$work/home/Downloads/ArmGame.apkm" NAME_ANSWER='Arm Game'
grep -q -- '--profile arm-game --app --expect-abi arm64-v8a' "$work/log"

# Failures stop before Steam: sign-in ends by itself, game fails, Steam still open.
reset
if run PICK="$work/home/Downloads/Game.apk" NAME_ANSWER='New One' FAKE_SETUP_FAIL=1; then echo 'FAIL: setup failure accepted'; exit 1; fi
grep -q 'stopped unexpectedly during sign-in' "$work/ui.--error"; ! grep -q add-game "$work/log"
reset
if run PICK="$work/home/Downloads/Game.apk" NAME_ANSWER='My Game!' NO_ON='already exists' FAKE_APP_FAIL=1; then echo 'FAIL: app failure accepted'; exit 1; fi
grep -q 'could not be installed or started' "$work/ui.--error"; ! grep -q add-game "$work/log"
reset
if run PICK="$work/home/Downloads/Game.apk" NAME_ANSWER='My Game!' NO_ON='already exists' FAKE_ADD_FAIL=1; then echo 'FAIL: add failure accepted'; exit 1; fi
grep -q 'Steam is still running. Nothing was changed.' "$work/ui.--error"
# Cancel at "Steam is closed": no real add.
reset; NO_ON='Step 3 of 3' run PICK="$work/home/Downloads/Game.apk" NAME_ANSWER='My Game!' 2>/dev/null || true
! grep -qx "add-game $work/home/Downloads/Game.apk --runtime-profile my-game --expect-abi x86_64 --name My Game!" "$work/log"

# Sign in again for an existing profile.
reset; args PROFILE_PICK=my-game
grep -qx 'run-apk --profile my-game --setup-only --network-sysctls --seconds 3600 --execute' "$work/log"
grep -q 'Sign-in finished' "$work/ui.--info"

# Never Steam; no Google services -> clear error.
[[ ! -e "$work/ui.steam" ]]
command rm "$root/compat_tool/images/rootfs/system/product/priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk"
reset
if run PICK=x NAME_ANSWER=x; then echo 'FAIL: non-GApps install accepted'; exit 1; fi
grep -q 'no Google services' "$work/ui.--error"
echo 'PASS: Google game window: sign-in/install/shortcut flow, TERM stop, GSF ID, ABI choice, failures, sign-in again'
