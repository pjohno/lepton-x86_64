#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# deck-clean-slate.sh --local against a throwaway home with Lepton items and
# unrelated look-alikes. podman/pgrep are faked so real containers are safe.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
script="$repo/image-14/scripts/deck-clean-slate.sh"
work="$(mktemp -d)"
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf -- "$work"' EXIT
home="$work/home"; share="$home/.local/share"; steam="$share/Steam"
mkdir -p "$work/bin"
cat > "$work/bin/podman" <<'SH'
#!/bin/bash
case "$1" in
  ps) [[ -z "${FAKE_EAT_STDIN:-}" ]] || cat > /dev/null  # a command that reads stdin
      [[ -n "${FAKE_CONTAINERS:-}" ]] && printf '%s\n' "$FAKE_CONTAINERS"; exit 0 ;;
  rm) echo "rm $*" >> "$PODMAN_LOG"; exit 0 ;;
  *) exit 1 ;;  # unshare unavailable: the script falls back to chmod + rm
esac
SH
printf '#!/bin/sh\n[ -n "$FAKE_BUSY" ]\n' > "$work/bin/pgrep"
chmod +x "$work/bin/podman" "$work/bin/pgrep"
clean() { env HOME="$home" PATH="$work/bin:/usr/bin:/bin" PODMAN_LOG="$work/podman.log" bash "$script" --local "$@"; }

mk_install() { mkdir -p "$1/compat_tool/tools"; printf '#!/bin/sh\n' > "$1/compat_tool/lepton"; }
mk_install "$share/lepton_x86_64_a"
mk_install "$share/lepton-x86_64-dev"
mk_install "$share/lepton_gapps_b.previous-20261103-120000"
mkdir -p "$share/lepton_x86_64_a/compat_tool/sysbake/locked" && chmod 000 "$share/lepton_x86_64_a/compat_tool/sysbake/locked"
mk_install "$share/.lepton-install.AbCd1234"
mkdir -p "$share/lepton/logs" "$share/leptonic-other" "$share/other-app"
mkdir -p "$steam/compatibilitytools.d" "$home/.config/lepton-x86_64" "$home/.local/bin" \
         "$share/applications" "$home/Desktop" "$home/Downloads/lepton-deck-bundles" \
         "$steam/steamapps/compatdata/123/baked" "$steam/steamapps/compatdata/456/pfx"
touch "$steam/compatibilitytools.d/lepton_x86_64_a.vdf" "$steam/compatibilitytools.d/proton_custom.vdf" \
      "$home/.config/lepton-x86_64/default.env" "$share/applications/lepton-x86_64-add-game.desktop" \
      "$share/applications/other.desktop" "$home/Desktop/lepton-install-a.desktop" "$home/Desktop/steam.desktop" \
      "$home/Downloads/lepton-x86_64-steamdeck-a.tar.gz" "$home/Downloads/holiday.jpg" "$home/.local/bin/other-tool"
ln -s "$share/lepton_x86_64_a/compat_tool/tools/lepton-add-game" "$home/.local/bin/lepton-add-game"
# Lepton: Install / Update / Repair (outside the versioned installs).
mkdir -p "$share/lepton-release-manager"; touch "$share/lepton-release-manager/lepton-release-manager" \
    "$share/applications/lepton-release-manager.desktop" "$home/Desktop/lepton-release-manager.desktop"
ln -s "$share/lepton-release-manager/lepton-release-manager" "$home/.local/bin/lepton-release-manager"

lepton_items=("$share/lepton_x86_64_a" "$share/lepton-x86_64-dev" "$share/lepton_gapps_b.previous-20261103-120000"
    "$share/.lepton-install.AbCd1234" "$share/lepton" "$steam/compatibilitytools.d/lepton_x86_64_a.vdf"
    "$home/.config/lepton-x86_64" "$home/.local/bin/lepton-add-game" "$share/applications/lepton-x86_64-add-game.desktop"
    "$home/Desktop/lepton-install-a.desktop" "$home/Downloads/lepton-x86_64-steamdeck-a.tar.gz" "$home/Downloads/lepton-deck-bundles"
    "$share/lepton-release-manager" "$share/applications/lepton-release-manager.desktop"
    "$home/Desktop/lepton-release-manager.desktop" "$home/.local/bin/lepton-release-manager")
unrelated=("$share/leptonic-other" "$share/other-app" "$steam/compatibilitytools.d/proton_custom.vdf"
    "$share/applications/other.desktop" "$home/Desktop/steam.desktop" "$home/Downloads/holiday.jpg"
    "$home/.local/bin/other-tool" "$steam/steamapps/compatdata/456")

# --check lists everything Lepton and changes nothing.
FAKE_CONTAINERS='lepton-steamlaunch-1 exited' clean --check > "$work/check.log"
for path in "${lepton_items[@]}"; do grep -Fqx "  $path" "$work/check.log"; [[ -e "$path" || -L "$path" ]]; done
for path in "${unrelated[@]}"; do ! grep -Fq "  $path" "$work/check.log"; done
grep -Fq 'podman container lepton-steamlaunch-1' "$work/check.log"
grep -Fq 'add --game-data to remove it' "$work/check.log"
grep -Fqx "  $steam/steamapps/compatdata/123" "$work/check.log"

# A running game or container blocks removal entirely.
if FAKE_BUSY=1 clean --execute > /dev/null 2>&1; then echo 'FAIL: removed while a game runs'; exit 1; fi
if FAKE_CONTAINERS='lepton-steamlaunch-1 running' clean --execute > /dev/null 2>&1; then echo 'FAIL: removed with a running container'; exit 1; fi
[[ -d "$share/lepton_x86_64_a" ]]

# --execute removes Lepton items (incl. mode-000 dirs) but keeps game data by default.
FAKE_CONTAINERS='lepton-steamlaunch-1 exited' clean --execute > "$work/execute.log"
for path in "${lepton_items[@]}"; do [[ ! -e "$path" && ! -L "$path" ]]; done
for path in "${unrelated[@]}"; do [[ -e "$path" ]]; done
[[ -d "$steam/steamapps/compatdata/123" ]]
grep -q 'rm -f lepton-steamlaunch-1' "$work/podman.log"

# --game-data also removes Lepton app data, never Proton prefixes.
clean --execute --game-data > "$work/game-data.log"
[[ ! -e "$steam/steamapps/compatdata/123" && -d "$steam/steamapps/compatdata/456/pfx" ]]
for path in "${unrelated[@]}"; do [[ -e "$path" ]]; done
# Remote mode sends this same script over SSH (fake ssh runs it locally).
printf '#!/bin/bash\necho "ssh $1" >> "$PODMAN_LOG"\nshift\nexec "$@"\n' > "$work/bin/ssh"
chmod +x "$work/bin/ssh"
mk_install "$share/lepton_x86_64_c"
# Over SSH the script is bash's stdin; a command reading stdin must not cut it short.
env HOME="$home" PATH="$work/bin:/usr/bin:/bin" PODMAN_LOG="$work/podman.log" FAKE_EAT_STDIN=1 \
    bash "$script" --deck-ip 192.0.2.7 --check > "$work/remote.log"
grep -q '^\[PASS\] Nothing was changed' "$work/remote.log"
grep -qx 'ssh deck@192.0.2.7' "$work/podman.log"
grep -Fqx "  $share/lepton_x86_64_c" "$work/remote.log"
[[ -d "$share/lepton_x86_64_c" ]]
if bash "$script" --deck-ip not-an-ip --check > /dev/null 2>&1; then echo 'FAIL: bad IP accepted'; exit 1; fi
# No dependency on the hostname command (absent on SteamOS).
! grep -Eq '\$\(hostname|`hostname' "$script"
echo 'PASS: deck clean slate: lists, removes only Lepton items, guards running games, opt-in game data, SSH mode'
