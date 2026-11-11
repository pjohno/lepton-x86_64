#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# lepton-x86_64-entry: built-in ADB/PATH/flatscreen defaults, bridge only for
# game launches, and never a second bridge. Uses a fake install tree.
set -Eeuo pipefail
not() { if "$@"; then echo "FAIL: unexpectedly succeeded: $*" >&2; exit 1; fi; }
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
root="$work/install"
mkdir -p "$root/compat_tool/tools" "$root/tools/platform-tools" "$root/tools/bin" "$work/old"
cp "$repo/compat_tool/lepton-x86_64-entry" "$root/compat_tool/"
printf '#!/bin/sh\n' > "$root/tools/platform-tools/adb"
# Fake Valve lepton: record arguments and the relevant environment.
cat > "$root/compat_tool/lepton" <<'SH'
#!/bin/bash
{ echo "lepton $*"; echo "ADB=${LEPTON_ADB:-}"; echo "FLAT=${APP_WANTS_FLATSCREEN:-}"
  echo "PATH0=${PATH%%:*}"; echo "BRIDGE=${LEPTON_BRIDGE_ACTIVE:-}"; echo "LOCAL=${LEPTON_LOCAL_DISPLAY_ACTIVE:-}"; } >> "$LOG"
SH
# Fake bundled bridge: like the real one, mark and run the command.
cat > "$root/compat_tool/tools/lepton-gamescope-bridge" <<'SH'
#!/bin/bash
echo "bridge" >> "$LOG"
echo "MODE=${LEPTON_DISPLAY_MODE:-} DIRECT=${LEPTON_DESKTOP_DIRECT:-}" >> "$LOG"
export LEPTON_BRIDGE_ACTIVE=1
exec "$@"
SH
# An older bridge from a previous install: no marker, does not exec.
cat > "$work/old/lepton-gamescope-bridge" <<'SH'
#!/bin/bash
echo "old-bridge" >> "$LOG"
"$@"
SH
chmod +x "$root/compat_tool/lepton" "$root/compat_tool/tools/lepton-gamescope-bridge" "$root/tools/platform-tools/adb" "$work/old/lepton-gamescope-bridge"
entry="$root/compat_tool/lepton-x86_64-entry"
# Never reach the real desktop: no display, and a fake zenity first on PATH.
mkdir -p "$work/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$DIALOG_LOG"\n' > "$work/bin/zenity"
chmod +x "$work/bin/zenity"
run() { rm -f "$work/log"; env -u LEPTON_ADB -u APP_WANTS_FLATSCREEN -u LEPTON_BRIDGE_ACTIVE -u LEPTON_NO_BRIDGE \
    -u LEPTON_LOCAL_USE_GAMESCOPE -u LEPTON_INSTALL_PROFILE -u LEPTON_DESKTOP_DIRECT -u DISPLAY -u WAYLAND_DISPLAY PATH="$work/bin:$PATH" DIALOG_LOG="$work/dialog.log" LOG="$work/log" "$@"; }

# Game launch: bridge first, then Valve's lepton with the original arguments.
run "$entry" waitforexitandrun -- /games/My\ Game.apk
[[ "$(head -1 "$work/log")" == bridge ]]
grep -qx 'lepton waitforexitandrun -- /games/My Game.apk' "$work/log"
grep -qx "ADB=$root/tools/platform-tools/adb" "$work/log"
grep -qx 'FLAT=true' "$work/log"
grep -qx "PATH0=$root/tools/bin" "$work/log"
grep -qx 'BRIDGE=1' "$work/log"

# Other verbs never start a bridge.
run "$entry" getcompatpath /x
not grep -qx bridge "$work/log"
grep -qx 'lepton getcompatpath /x' "$work/log"

# Explicit settings win over the built-in defaults.
run env LEPTON_ADB=/custom/adb APP_WANTS_FLATSCREEN=false "$entry" waitforexitandrun -- a.apk
grep -qx 'ADB=/custom/adb' "$work/log" && grep -qx 'FLAT=false' "$work/log"

# Already inside a bridge (new marker, or an old bridge as an ancestor): no second one.
run env LEPTON_BRIDGE_ACTIVE=1 "$entry" waitforexitandrun -- a.apk
[[ "$(grep -cx bridge "$work/log" || true)" == 0 ]]
run "$work/old/lepton-gamescope-bridge" "$entry" waitforexitandrun -- a.apk
[[ "$(grep -cx bridge "$work/log" || true)" == 0 ]]
grep -qx old-bridge "$work/log" && grep -qx 'lepton waitforexitandrun -- a.apk' "$work/log"
# LEPTON_NO_BRIDGE=true opts out.
run env LEPTON_NO_BRIDGE=true "$entry" waitforexitandrun -- a.apk
[[ "$(grep -cx bridge "$work/log" || true)" == 0 ]]

# Via a symlinked path the entry still finds its own install.
ln -s "$entry" "$work/entry-link"
run "$work/entry-link" waitforexitandrun -- a.apk
grep -qx "ADB=$root/tools/platform-tools/adb" "$work/log"

# A game marked as needing Google services refuses a tool without them, before
# anything starts; with Google services it launches normally.
mkdir -p "$work/compat/1"; touch "$work/compat/1/lepton-google-game"
# The player sees the reason in a dialog (the fake zenity records it).
if run env STEAM_COMPAT_DATA_PATH="$work/compat/1" LEPTON_NO_BRIDGE=true WAYLAND_DISPLAY=test-display \
        "$entry" waitforexitandrun -- a.apk 2> "$work/google.err"; then
    echo 'FAIL: Google game started without Google services'; exit 1
fi
grep -q 'needs Google services' "$work/google.err"
grep -q -- '--error --title=Lepton' "$work/dialog.log" && grep -q 'needs Google services' "$work/dialog.log"
[[ ! -e "$work/log" ]]
gms="$root/compat_tool/images/rootfs/system/product/priv-app/PrebuiltGmsCore"
mkdir -p "$gms" && touch "$gms/PrebuiltGmsCore.apk"
run env STEAM_COMPAT_DATA_PATH="$work/compat/1" LEPTON_NO_BRIDGE=true "$entry" waitforexitandrun -- a.apk
grep -qx 'lepton waitforexitandrun -- a.apk' "$work/log"

# A profile belongs to this tool, never a caller's global environment.
run env LEPTON_INSTALL_PROFILE=local-desktop "$entry" waitforexitandrun -- a.apk
grep -qx bridge "$work/log"
cat > "$root/compat_tool/tools/lepton-direct-wayland" <<'SH'
#!/bin/bash
echo direct >> "$LOG"
echo "LOCAL=${LEPTON_LOCAL_DISPLAY_ACTIVE:-}" >> "$LOG"
exec "$@"
SH
chmod +x "$root/compat_tool/tools/lepton-direct-wayland"
printf '%s\n' local-desktop > "$root/compat_tool/install-profile"
run "$entry" waitforexitandrun -- a.apk
grep -qx direct "$work/log"
grep -qx LOCAL=1 "$work/log"
not grep -qx bridge "$work/log"
grep -qx 'lepton waitforexitandrun -- a.apk' "$work/log"
# Fallback must override session hints and a legacy direct override.
run env LEPTON_LOCAL_USE_GAMESCOPE=1 LEPTON_DISPLAY_MODE=gaming LEPTON_DESKTOP_DIRECT=1 "$entry" waitforexitandrun -- a.apk
grep -qx bridge "$work/log"
not grep -qx direct "$work/log"
grep -qx 'MODE=desktop DIRECT=0' "$work/log"
grep -qx LOCAL=0 "$work/log"
# Even a copied local profile cannot change SteamOS's default path.
real_grep="$(command -v grep)"
cat > "$work/bin/grep" <<SH
#!/bin/bash
if [[ "\${!#}" == /etc/os-release ]]; then exit \${FAKE_STEAMOS:-1}; fi
exec '$real_grep' "\$@"
SH
chmod +x "$work/bin/grep"
run env FAKE_STEAMOS=0 LEPTON_LOCAL_DISPLAY_ACTIVE=1 "$entry" waitforexitandrun -- a.apk
grep -qx bridge "$work/log"
not grep -qx direct "$work/log"
grep -qx LOCAL=0 "$work/log"
run "$entry" getcompatpath /x
not grep -qx direct "$work/log"
run env LEPTON_BRIDGE_ACTIVE=1 "$entry" waitforexitandrun -- a.apk
not grep -qx direct "$work/log"
# A second, unmarked install remains independent.
rm "$root/compat_tool/install-profile"
run env LEPTON_LOCAL_USE_GAMESCOPE=1 "$entry" waitforexitandrun -- a.apk
grep -qx bridge "$work/log"

# The real bridge marks its children.
grep -qx 'export LEPTON_BRIDGE_ACTIVE=1' "$repo/compat_tool/tools/lepton-gamescope-bridge"
echo 'PASS: tool entry: built-in ADB/PATH/flatscreen, bridge only for game launches, never nested'
