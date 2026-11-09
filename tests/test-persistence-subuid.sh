#!/usr/bin/env bash
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work=$(mktemp -d /tmp/lepton-subuid.XXXXXXXX)
trap 'podman unshare rm -rf -- "$work"' EXIT
for fn in profile_has_no_mounts clear_baked_app_data remove_baked_workdirs remove_prefix; do
 eval "$(sed -n "/^function $fn()/,/^}/p" "$repo/compat_tool/liblepton/liblepton.sh")"
done
print() { printf '%s' "$*"; }
println() { printf '%s\n' "$*"; }
get_baked_app_data_dir() { print "$STEAM_COMPAT_DATA_PATH/baked"; }
export STEAM_COMPAT_DATA_PATH="$work/compatdata/123" LEPTON_CONTEXT="steamlaunch-$(basename "$work")"
mkdir -p "$STEAM_COMPAT_DATA_PATH/baked/data_overlay/user/0/game" "$STEAM_COMPAT_DATA_PATH/baked/data_workdir/work"
podman unshare sh -c 'echo synthetic-save > "$1/save"; chown -R 10000:10000 "$1"; chmod 700 "$1"; chmod 600 "$1/save"' sh "$STEAM_COMPAT_DATA_PATH/baked/data_overlay/user/0/game"
before=$(podman unshare sha256sum "$STEAM_COMPAT_DATA_PATH/baked/data_overlay/user/0/game/save")
# Reproduce the old failure mechanism on this disposable fixture only. This
# establishes permission behaviour, not the cause of any historical Deck save.
if rm -rf -- "$STEAM_COMPAT_DATA_PATH/baked/data_overlay/user/0/game" 2> "$work/legacy-removal.log"; then
    echo 'FAIL: expected host deletion to be blocked by subordinate-UID ownership' >&2
    exit 1
fi
[[ "$(podman unshare sha256sum "$STEAM_COMPAT_DATA_PATH/baked/data_overlay/user/0/game/save")" == "$before" ]]
LEPTON_PREFIX=$(mktemp -d /tmp/lepton-context.XXXXXXXX)
remove_prefix
[[ "$(podman unshare sha256sum "$STEAM_COMPAT_DATA_PATH/baked/data_overlay/user/0/game/save")" == "$before" ]]
[[ "$(podman unshare stat -c %u:%g "$STEAM_COMPAT_DATA_PATH/baked/data_overlay/user/0/game/save")" == 10000:10000 ]]
LEPTON_RESET_APP_DATA=true clear_baked_app_data disposable-fixture-reset
[[ ! -e "$STEAM_COMPAT_DATA_PATH/baked" ]]
echo 'PASS: historical deletion failure mechanism reproduced; subordinate-UID save bytes and ownership survive cleanup; explicit disposable reset succeeds'
