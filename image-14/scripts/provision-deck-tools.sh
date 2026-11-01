#!/usr/bin/env bash
# Produce tested Steam Deck host tools without committing third-party binaries.
# Run only after constructing a fresh, isolated stage. No Steam installation is changed.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
ADB_URL='https://dl.google.com/android/repository/platform-tools_r37.0.1-linux.zip'
ADB_SHA256='a902be8f45c6c62e76c9efaf6947a0fa747c9cabd89a2ac8e0d16ecb30b3ed01'
ADB_VERSION='37.0.1-15733141'
INOTIFY_VERSION='4.23.9.0'
INOTIFY_COMMIT_PREFIX='5c2ab77'
INOTIFY_REPO='https://github.com/inotify-tools/inotify-tools.git'
MODE='--check'
STAGE=''
ADB_ZIP=''

usage() {
    cat <<'HELP'
Usage: bash image-14/scripts/provision-deck-tools.sh --stage-dir DIR [--check|--execute] [--adb-zip PATH]
  --check: verify the four tools already staged; no changes or downloads.
  --execute: download verified Google ADB, compile inotify-tools 4.23.9.0 in a
             Debian 12 Podman builder, then install into an otherwise tool-free stage.
  --adb-zip: use a cached official Google platform-tools Linux ZIP (offline ADB).

The versioned Google download is accepted ONLY if its adb matches the pinned
SHA256 and version. An updated version requires an explicit reviewed pin.
The inotify-tools Git tag must resolve to the recorded upstream commit prefix.
No existing staged tool is overwritten. Does not generate sysbake or touch Steam.
HELP
}
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
while (($#)); do
    case "$1" in
        --check|--execute) MODE="$1"; shift ;;
        --stage-dir) (($# >= 2)) || fail '--stage-dir needs a path'; STAGE="$2"; shift 2 ;;
        --adb-zip) (($# >= 2)) || fail '--adb-zip needs a path'; ADB_ZIP="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done
[[ -n "$STAGE" ]] || { usage >&2; fail 'Specify --stage-dir'; }
[[ -d "$STAGE" && ! -L "$STAGE" ]] || fail "Stage must exist as a real directory: $STAGE"
STAGE="$(realpath -e -- "$STAGE")"
[[ "$STAGE" != / && "$STAGE" != "$ROOT" ]] || fail 'Refusing root/repository stage'
[[ -f "$STAGE/compat_tool/images/rootfs/system/build.prop" ]] || fail 'Stage is missing Android rootfs'
[[ -f "$STAGE/compat_tool/images/rootfs/vendor/lib64/hw/vulkan.radeon.so" ]] || fail 'Stage is missing AMD Vulkan driver'
[[ -x "$STAGE/compat_tool/lepton" ]] || fail 'Stage is missing Lepton launcher'
[[ $(uname -m) == x86_64 ]] || fail 'Only x86_64 stages supported'

paths=(tools/platform-tools/adb tools/bin/inotifywait tools/native/inotifywait tools/lib/libinotifytools.so.0)
check_tools() {
    local path
    for path in "${paths[@]}"; do
        [[ -f "$STAGE/$path" && ! -L "$STAGE/$path" ]] || fail "Missing ordinary file: $STAGE/$path"
    done
    printf '%s  %s\n' "$ADB_SHA256" "$STAGE/tools/platform-tools/adb" | sha256sum -c - >/dev/null || fail 'ADB SHA256 mismatch'
    "$STAGE/tools/platform-tools/adb" version | grep -F "Version $ADB_VERSION" >/dev/null || fail 'ADB version mismatch'
    local inotify_help
    inotify_help="$("$STAGE/tools/bin/inotifywait" --help 2>&1 || true)"
    [[ "$inotify_help" == *"inotifywait $INOTIFY_VERSION"* ]] || fail 'inotifywait version mismatch'
    LD_LIBRARY_PATH="$STAGE/tools/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        ldd "$STAGE/tools/native/inotifywait" | grep -F "$STAGE/tools/lib/libinotifytools.so.0" >/dev/null || fail 'Bundled inotify library was not resolved'
    printf '[PASS] ADB %s and inotify-tools %s are staged and linked\n' "$ADB_VERSION" "$INOTIFY_VERSION"
}
if [[ "$MODE" == --check ]]; then
    for program in sha256sum ldd grep; do command -v "$program" >/dev/null || fail "Missing $program"; done
    check_tools
    exit 0
fi

for program in curl unzip git podman install realpath sha256sum ldd; do
    command -v "$program" >/dev/null 2>&1 || fail "Missing dependency: $program"
done
if [[ -n "$ADB_ZIP" ]]; then
    [[ -f "$ADB_ZIP" ]] || fail "ADB zip not found: $ADB_ZIP"
    ADB_ZIP="$(realpath -e -- "$ADB_ZIP")"
fi
for path in "${paths[@]}"; do
    [[ ! -e "$STAGE/$path" && ! -L "$STAGE/$path" ]] || fail "Refusing to overwrite: $STAGE/$path"
done

# Keep transient downloads and compiler outputs outside the destination stage.
TEMP="$(mktemp -d "${STAGE%/*}/.lepton-tools.XXXXXXXX")"
cleanup() { rm -rf -- "$TEMP"; }
trap cleanup EXIT
if [[ -z "$ADB_ZIP" ]]; then
    echo '[INFO] Downloading official versioned Google Platform-Tools ZIP (verified by pinned adb hash)'
    curl -fL --retry 3 --connect-timeout 20 "$ADB_URL" -o "$TEMP/platform-tools.zip"
    ADB_ZIP="$TEMP/platform-tools.zip"
fi
unzip -q "$ADB_ZIP" 'platform-tools/adb' -d "$TEMP" || fail 'Could not extract ADB'
if unzip -Z1 "$ADB_ZIP" | grep -Fx 'platform-tools/NOTICE.txt' >/dev/null; then
    unzip -q "$ADB_ZIP" 'platform-tools/NOTICE.txt' -d "$TEMP"
fi
[[ -f "$TEMP/platform-tools/adb" ]] || fail 'Google archive lacks platform-tools/adb'
printf '%s  %s\n' "$ADB_SHA256" "$TEMP/platform-tools/adb" | sha256sum -c - || \
    fail 'Google archive no longer matches tested ADB; use a reviewed pinned archive with --adb-zip'
chmod +x "$TEMP/platform-tools/adb"
"$TEMP/platform-tools/adb" version | grep -F "Version $ADB_VERSION" >/dev/null || fail 'Unexpected ADB version'

# Fetch an immutable Git tag and verify the upstream release commit prefix.
# This deliberately DOES NOT copy the Fedora host's dynamically linked binary.
echo '[INFO] Fetching inotify-tools 4.23.9.0 source'
git clone -q --depth 1 --branch "$INOTIFY_VERSION" "$INOTIFY_REPO" "$TEMP/inotify-tools"
commit="$(git -C "$TEMP/inotify-tools" rev-parse HEAD)"
[[ "$commit" == "$INOTIFY_COMMIT_PREFIX"* ]] || fail "Unrecognized inotify-tools source commit: $commit"

echo '[INFO] Building inotify-tools with Debian 12 toolchain (Podman)'
podman build -q -f "$ROOT/image-14/.buildscripts_x86_64/Containerfile.deck-tools" \
    -t lepton-deck-tools-debian12:local "$ROOT/image-14/.buildscripts_x86_64" >/dev/null
podman run --rm --userns=keep-id --security-opt=label=disable \
    -v "$TEMP:/work" -w /work/inotify-tools \
    lepton-deck-tools-debian12:local /bin/bash -euc '
        export HOME=/tmp
        ./autogen.sh
        ./configure --prefix=/usr
        make -j2
        make DESTDIR=/work/inotify-installed install
    '

bin="$TEMP/inotify-installed/usr/bin/inotifywait"
lib="$(find -L "$TEMP/inotify-installed" -name libinotifytools.so.0 -type f -print -quit)"
[[ -x "$bin" && -n "$lib" && -f "$lib" ]] || fail 'inotify-tools installation is missing binary/library'
mkdir -p "$TEMP/output/tools"/{platform-tools,bin,native,lib,licenses}
install -m 755 "$TEMP/platform-tools/adb" "$TEMP/output/tools/platform-tools/adb"
install -m 755 "$bin" "$TEMP/output/tools/native/inotifywait"
install -m 755 "$lib" "$TEMP/output/tools/lib/libinotifytools.so.0"
install -m 755 "$ROOT/image-14/scripts/inotifywait-wrapper" "$TEMP/output/tools/bin/inotifywait"
# Ship upstream license notices with the compiled distribution.
find "$TEMP/inotify-tools" -maxdepth 1 -type f \
    \( -iname 'COPYING*' -o -iname 'LICENSE*' \) -exec cp -a -- {} "$TEMP/output/tools/licenses/" \;
if [[ -f "$TEMP/platform-tools/NOTICE.txt" ]]; then
    install -m 644 "$TEMP/platform-tools/NOTICE.txt" "$TEMP/output/tools/licenses/google-platform-tools-NOTICE.txt"
fi
[[ -n "$(find "$TEMP/output/tools/licenses" -type f -print -quit)" ]] || fail 'No upstream license files collected'

mkdir -p "$STAGE/tools"/{platform-tools,bin,native,lib,licenses}
for path in "${paths[@]}"; do
    [[ ! -e "$STAGE/$path" && ! -L "$STAGE/$path" ]] || fail "Destination appeared: $STAGE/$path"
done
for path in "${paths[@]}"; do
    install -m 755 "$TEMP/output/$path" "$STAGE/$path"
done
cp -n -- "$TEMP/output/tools/licenses/"* "$STAGE/tools/licenses/"
cat > "$STAGE/tools/PROVENANCE.txt" <<META
Google Android Platform-Tools: $ADB_VERSION
Google download URL (mutable): $ADB_URL
ADB binary SHA256: $ADB_SHA256
Inotify-tools: $INOTIFY_VERSION
Inotify source: $INOTIFY_REPO
Inotify source Git commit: $commit
Inotify build environment: Debian 12 (Containerfile.deck-tools)
META
check_tools
echo '[PASS] Steam Deck host utilities provisioned without modifying an existing installation'
