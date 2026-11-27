#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Launch-time Android Library decisions (android_library.sh with the real
# runtime helper): only a managed APK requires the library. Unmanaged APKs,
# Steam games and Google Play start without Container Storage when the
# library's drive is missing, and nothing is created at its location.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
work="$(realpath -e -- "$work")"
trap 'rm -rf -- "$work"' EXIT
export HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config"
mkdir -p "$HOME"
LEPTON_DIR="$repo/compat_tool/liblepton"
fail() { echo "FAIL: $*"; exit 1; }
print() { printf '%s' "$*"; }
println() { printf '%s\n' "$*"; }
lepton_tell_player() { printf '%s\n' "$@" > "$work/popup"; }
die() { printf 'DIE: %s\n' "$*"; lepton_tell_player "$@"; exit 3; }
is_sysbake() { return 1; }
get_app_id() { print org.example.game; }

library="$work/SD Card/Android_Library"
mkdir -p "${library%/*}"
python3 -B - "$repo/compat_tool/tools" "$library" <<'PY'
import sys, uuid
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import lepton_library as lib
root = lib.initialize(Path(sys.argv[2]))
app = root / "org.example.game"
(app / "obb").mkdir(parents=True)
apk = app / "org.example.game.apk"
apk.write_bytes(b"PK test")
digest = lib.sha256(apk)
lib.atomic_json(app / "config.json", dict(
    schema_version=1, package="org.example.game", format=".apk", name="Game", version_name="1",
    version_code=1, sha256=digest, revision=uuid.uuid4().hex, signers=None, apks={"base.apk": digest},
    launchable_activity=".Play", shared_folders={"defaults": [], "custom": []}))
PY
managed="$library/org.example.game/org.example.game.apk"
download="$HOME/Downloads/other.apk"

# Run one launch decision in a subshell; print the outcome.
resolve() {
    (
        source "$LEPTON_DIR/android_library.sh"
        unset LEPTON_SHARED_FOLDERS
        lepton_library_resolve "$1"
        printf 'root=%s\nmanaged=%s\nactivity=%s\nsharing=%s\n' "$LEPTON_LIBRARY_ROOT" "$LEPTON_MANAGED_APP" \
            "${APP_ACTIVITY:-}" "${LEPTON_SHARED_FOLDERS-unset}"
    )
}

# Not configured: Lepton's existing behaviour.
mv "$XDG_CONFIG_HOME/lepton-x86_64/android-library.json" "$work/settings.json"
out="$(resolve "$managed")"
grep -qx 'root=' <<< "$out" && grep -qx 'managed=' <<< "$out" || fail "unconfigured library was used"
mv "$work/settings.json" "$XDG_CONFIG_HOME/lepton-x86_64/android-library.json"

# Available: managed launches use the library; others get Container Storage.
out="$(resolve "$managed")"
grep -qx "root=$library" <<< "$out" || fail "managed launch without library"
grep -qx "managed=$library/org.example.game" <<< "$out" || fail "managed APK not recognised"
grep -qx 'activity=.Play' <<< "$out" || fail "managed activity not used"
grep -qx 'sharing=none' <<< "$out" || fail "saved shared folders not applied"
out="$(resolve "$download")"
grep -qx "root=$library" <<< "$out" && grep -qx 'managed=' <<< "$out" || fail "unmanaged launch lost Container Storage"
out="$(resolve "")"
grep -qx "root=$library" <<< "$out" || fail "Google Play launch lost Container Storage"

# The drive is disconnected.
mv "$work/SD Card" "$work/elsewhere"
for target in "$download" "" "$HOME/.local/share/Steam/steamapps/common/G/game.apk"; do
    out="$(resolve "$target")" || fail "unrelated launch stopped: ${target:-Google Play}"
    grep -qx 'root=' <<< "$out" || fail "unavailable Container Storage used"
    grep -q 'Container Storage not shared this launch: Android Library unavailable' <<< "$out" ||
        fail "unavailable Container Storage not logged"
done
if out="$(resolve "$managed")"; then fail "managed launch continued without its library"; fi
grep -q 'DIE: This game is in the Android Library, which is not available' <<< "$out" || fail "unclear managed error: $out"
grep -q 'Reconnect its drive' "$work/popup" || fail "no actionable popup"
[[ ! -e "$work/SD Card" ]] || fail "a replacement library location was created"

# A mount point left behind by the drive is not the library either.
mkdir -p "$library"
out="$(resolve "$download")" && grep -qx 'root=' <<< "$out" || fail "empty mount point used as library"
if resolve "$managed" > /dev/null; then fail "empty mount point accepted for a managed launch"; fi
[[ -z "$(ls -A "$library")" ]] || fail "files created at the empty mount point"
rm -rf "$work/SD Card"

# Reconnected: normal operation resumes.
mv "$work/elsewhere" "$work/SD Card"
out="$(resolve "$managed")" && grep -qx "managed=$library/org.example.game" <<< "$out" || fail "reconnected library unused"

# A damaged configuration does not stop unrelated launches.
cp "$XDG_CONFIG_HOME/lepton-x86_64/android-library.json" "$work/settings.json"
echo '{' > "$XDG_CONFIG_HOME/lepton-x86_64/android-library.json"
out="$(resolve "$download" 2>&1)" || fail "damaged configuration stopped an unrelated launch"
grep -q 'WARNING: cannot read the Android Library configuration' <<< "$out" || fail "damaged configuration not reported"
cp "$work/settings.json" "$XDG_CONFIG_HOME/lepton-x86_64/android-library.json"

# An unmanaged launch must not reuse a managed profile, and vice versa a
# profile without a receipt stays legacy.
profile="$work/profile/baked"
mkdir -p "$profile"
(source "$LEPTON_DIR/android_library.sh"; lepton_managed_profile "$profile" existing) || fail "legacy profile refused"
printf '{"schema_version": 1, "package": "org.example.game", "installed": null, "pending": null}\n' \
    > "$profile/lepton-managed.json"
if out="$(source "$LEPTON_DIR/android_library.sh"; lepton_managed_profile "$profile" existing)"; then
    fail "managed profile reused by an unmanaged launch"
fi
grep -q 'belongs to an Android Library app' <<< "$out" || fail "unclear managed-profile error"

echo "PASS: managed launches need the library; unmanaged, Steam and Google Play launches continue without Container Storage; nothing created on a missing drive; reconnection; damaged settings; managed profile reuse"
