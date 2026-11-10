#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Launch failures reach the player: die() and the other launch exits leave a
# message for the Gamescope bridge's popup (LEPTON_MESSAGE_FILE). The first,
# most specific message wins; nothing is written without the bridge's file.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
for fn in lepton_tell_player die; do
    eval "$(sed -n "/^function $fn()/,/^}/p" "$repo/compat_tool/liblepton/utils.sh")"
done
msg="$work/message"
# die: logged on stderr and shown to the player, then exits 1.
: > "$msg"
if (LEPTON_MESSAGE_FILE="$msg" die "This game only contains ARM64 code." "Select an NDK tool.") 2> "$work/err"; then fail 'die returned'; fi
[[ "$(cat "$msg")" == $'This game only contains ARM64 code.\nSelect an NDK tool.' ]] || fail 'die message not passed on'
grep -qx 'This game only contains ARM64 code.' "$work/err"
# A specific message is kept; the generic die that follows does not replace it.
(LEPTON_MESSAGE_FILE="$msg" die "Profile safety check failed; existing data preserved") 2>/dev/null || true
[[ "$(head -1 "$msg")" == 'This game only contains ARM64 code.' ]] || fail 'specific message overwritten'
# No bridge file, a missing file or a symlink: log only.
(die "outside a game launch") 2>/dev/null || true
(LEPTON_MESSAGE_FILE="$work/missing" die x) 2>/dev/null || true; [[ ! -e "$work/missing" ]]
ln -s "$work/target" "$work/link"
(LEPTON_MESSAGE_FILE="$work/link" die x) 2>/dev/null || true; [[ ! -e "$work/target" ]]
# The launch exits that used to be silent now go through die / the player.
lepton="$repo/compat_tool/lepton"
grep -q 'die "This file doesn.t look like an Android app' "$lepton" || fail 'no-package exit is silent'
grep -q 'die "Android can.t start ${APP_PACKAGE_ID:-this game}: its APK names no app to launch' "$lepton" || fail 'malformed-APK exit is silent'
grep -q "die \"This Lepton tool's files are incomplete" "$repo/compat_tool/liblepton/baking.sh" || fail 'unbaked exit is silent'
# A failed install ends the launch with a message instead of leaving Android
# waiting for the app (a black screen until Stop); the profile is kept.
branch="$(sed -n '/elif app_install_needed; then/,/^        fi$/p' "$lepton")"
grep -q 'lepton_tell_player "Android couldn.t install' <<< "$branch" || fail 'install failure is silent'
grep -q 'Nothing has been deleted' <<< "$branch"
after="$(grep -A4 'lepton_tell_player "Android couldn' <<< "$branch")"
grep -qx ' *teardown' <<< "$after" && grep -qx ' *exit 1' <<< "$after" || fail 'install failure does not end the launch'
! grep -qE 'clear_baked_app_data|rm -rf' <<< "$branch" || fail 'install failure path deletes data'
echo 'PASS: player messages: die and silent launch exits reach the popup; specific message kept; log only without the bridge; failed install ends the launch, data kept'
