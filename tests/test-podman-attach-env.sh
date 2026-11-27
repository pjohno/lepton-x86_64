#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# podman_attach runs Podman with its own settings only. The game's
# environment (Steam's LD_PRELOAD, runtime library paths) is not passed to
# Podman, Android's PATH goes into the container with --env, and a Podman
# wrapper found through the host PATH (#!/usr/bin/env) still works.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/podman" <<'SH'
#!/usr/bin/env bash
{ printf 'ARGS'; printf ' %q' "$@"; printf '\n'; env | sort; } > "$PODMAN_TEST_RECORD"
SH
chmod +x "$work/bin/podman"
for fn in lepton_podman_environment podman_attach_no_context_check; do
    eval "$(sed -n "/^function $fn()/,/^}/p" "$repo/compat_tool/liblepton/liblepton.sh")"
    declare -F "$fn" > /dev/null || { echo "FAIL: $fn not found"; exit 1; }
done
println() { printf '%s\n' "$*"; }
fail() { echo "FAIL: $*"; exit 1; }
export PATH="$work/bin:$PATH" PODMAN_TEST_RECORD="$work/record" LEPTON_CONTEXT=game
export LD_PRELOAD=libc.so.6 LD_LIBRARY_PATH=/steam/runtime SteamAppId=123
export CONTAINERS_STORAGE_CONF="$work/storage.conf" XDG_RUNTIME_DIR="$work/run"
podman_attach_no_context_check --no-term getprop ro.build.version.sdk
record="$(cat "$work/record")"
grep -q '^ARGS exec -i --env PATH=/product/bin:.*:/system/bin:.*:/vendor/xbin lepton-game getprop ro.build.version.sdk$' <<< "$record" ||
    fail "unexpected podman arguments: $(head -1 <<< "$record")"
for kept in "CONTAINERS_STORAGE_CONF=$work/storage.conf" "XDG_RUNTIME_DIR=$work/run" "HOME=$HOME" "PATH=$PATH"; do
    grep -qxF "$kept" <<< "$record" || fail "Podman setting not passed: $kept"
done
for dropped in LD_PRELOAD LD_LIBRARY_PATH SteamAppId SteamAppId; do
    ! grep -q "^$dropped=" <<< "$record" || fail "game environment passed to Podman: $dropped"
done
echo "PASS: podman_attach passes Podman's own settings and Android's PATH, not the game's environment"
