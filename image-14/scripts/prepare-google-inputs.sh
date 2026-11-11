#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Turn a locally downloaded Android 14 (API 34) x86_64 Google Play emulator
# system image zip into the optional bundle inputs:
#   OUTPUT/logical-partitions/      for --with-gapps and --with-widevine
#   OUTPUT/ndk-translation/payload  for --with-ndk
# Nothing is downloaded; the zip and its contents stay on this computer.
set -Eeuo pipefail
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
EXPECTED_TRANSLATOR=a2086fbc807f697f9b91222065c9d9000ca9727748699c0d9b751319258cbb3e

usage() {
    cat <<'HELP'
Usage: bash prepare-google-inputs.sh --zip FILE [--output DIR] [--check] [--with-ndk] [--with-gapps] [--with-widevine]

FILE is the Android SDK system image "Google Play Intel x86_64 Atom System
Image", API 34, revision 14 (x86_64-34_r14.zip from the google_apis_playstore
channel), downloaded by you, e.g. with Android Studio's SDK Manager.

DIR defaults to the workspace's google-inputs/, where make-deck-bundle finds
it automatically; it must not exist yet. For another DIR, add to .build-env:
  LEPTON_GOOGLE_IMAGES="DIR/logical-partitions"
  LEPTON_NDK_PAYLOAD="DIR/ndk-translation/payload"
With no component flags, prepare all inputs (existing build behaviour).
NDK extraction is skipped when only GApps/Widevine is selected.
Needs about 10 GiB free while running (about 3 GiB afterwards). Keep the zip
itself outside the workspace.
HELP
}
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }

ZIP=''
OUT=''
WITH_NDK=false
WITH_GAPPS=false
WITH_WIDEVINE=false
SELECTED=false
CHECK=false
while (($#)); do
    case "$1" in
        --check) CHECK=true; shift ;;
        --with-ndk) WITH_NDK=true; SELECTED=true; shift ;;
        --with-gapps) WITH_GAPPS=true; SELECTED=true; shift ;;
        --with-widevine) WITH_WIDEVINE=true; SELECTED=true; shift ;;
        --zip) ZIP="${2:?--zip requires a file}"; shift 2 ;;
        --output) OUT="${2:?--output requires a directory}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "Unknown argument: $1" ;;
    esac
done
[[ -n "$ZIP" ]] || { usage >&2; fail '--zip is required'; }
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
DEFAULT_OUT=false
if [[ -z "$OUT" ]]; then
    # shellcheck source=/dev/null
    [[ -f "$ROOT/.build-env" ]] && source "$ROOT/.build-env"
    [[ -n "${LEPTON_OUTPUT_DIR:-}" ]] || fail 'Set LEPTON_OUTPUT_DIR in .build-env, or pass --output DIR'
    source "$SCRIPT_DIR/lib/workspace.sh"
    lepton_workspace
    OUT="$LEPTON_GOOGLE_INPUTS_DIR"
    DEFAULT_OUT=true
    [[ "$CHECK" == true || -d "$LEPTON_WORKSPACE" ]] || lepton_create_workspace "$LEPTON_WORKSPACE" || fail "Cannot create workspace $LEPTON_WORKSPACE"
fi
# Without component flags retain the existing build workflow (all inputs).
if [[ "$SELECTED" == false ]]; then WITH_NDK=true; WITH_GAPPS=true; WITH_WIDEVINE=true; fi
for tool in unzip sfdisk dd lpunpack debugfs sha256sum python3 realpath mktemp; do
    command -v "$tool" >/dev/null 2>&1 || fail "Missing host tool: $tool (see the README host requirements)"
done
ZIP="$(realpath -e -- "$ZIP")" || fail 'Zip not found'
OUT="$(realpath -m -- "$OUT")"
[[ ! -e "$OUT" && ! -L "$OUT" ]] || fail "Output already exists: $OUT"
[[ -d "$(dirname -- "$OUT")" ]] || fail "Output parent does not exist: $(dirname -- "$OUT")"

for member in x86_64/system.img x86_64/build.prop; do
    # One member per call: unzip -l succeeds if any listed name matches.
    unzip -l "$ZIP" "$member" >/dev/null 2>&1 ||
        fail "Not an x86_64 emulator system image zip ($member missing)"
done
# Check bounded SDK metadata and unique selected entries before extracting.
# Revision is package metadata, not a filename guess.
python3 - "$ZIP" <<'PYIDENTITY'
import sys, zipfile

def properties(data):
    result = {}
    for line in data.decode().splitlines():
        if '=' not in line or line.lstrip().startswith('#'):
            continue
        key, value = line.split('=', 1)
        if key in result:
            raise SystemExit('Duplicate Google package property: ' + key)
        result[key] = value
    return result

with zipfile.ZipFile(sys.argv[1]) as archive:
    for name in ('x86_64/build.prop', 'x86_64/system.img'):
        if archive.namelist().count(name) != 1:
            raise SystemExit('Missing or duplicate ZIP member: ' + name)
    if archive.getinfo('x86_64/build.prop').file_size > 1048576:
        raise SystemExit('Google build.prop is too large')
    build = properties(archive.read('x86_64/build.prop'))
    if build.get('ro.build.version.sdk') != '34':
        raise SystemExit('The image is not Android 14 (API 34)')
    if build.get('ro.build.flavor') != 'sdk_gphone64_x86_64-user':
        raise SystemExit('Not an x86_64 Google emulator image')
    name = 'x86_64/source.properties'
    if archive.namelist().count(name) != 1 or archive.getinfo(name).file_size > 65536:
        raise SystemExit('Missing or invalid x86_64/source.properties')
    props = properties(archive.read(name))
    for key, value in {'Pkg.Revision': '14', 'AndroidVersion.ApiLevel': '34',
                       'SystemImage.Abi': 'x86_64', 'SystemImage.TagId': 'google_apis_playstore'}.items():
        if props.get(key) != value:
            raise SystemExit('Unsupported Google image: expected ' + key + '=' + value)
PYIDENTITY

if [[ "$CHECK" == true ]]; then
    printf '[PASS] Google ZIP identity and preparation prerequisites verified; no files changed\n'
    exit 0
fi
mkdir -- "$OUT"
unzip -p "$ZIP" x86_64/source.properties > "$OUT/SOURCE.properties"
unzip -p "$ZIP" x86_64/build.prop > "$OUT/BUILD.prop"
work="$(mktemp -d "$OUT/.work.XXXXXXXX")"
trap 'rm -rf -- "$work"' EXIT

info 'Extracting system.img from the zip'
unzip -q -p "$ZIP" x86_64/system.img > "$work/disk.img"

info 'Locating the "super" partition'
read -r start size < <(sfdisk --json "$work/disk.img" | python3 -c '
import json, sys
for p in json.load(sys.stdin)["partitiontable"]["partitions"]:
    if p.get("name") == "super":
        print(p["start"], p["size"]); break
')
[[ -n "${start:-}" && -n "${size:-}" ]] || fail 'No "super" partition in system.img'
dd if="$work/disk.img" of="$work/super.img" bs=512 skip="$start" count="$size" status=none
rm -- "$work/disk.img"

info 'Unpacking logical partitions (system, system_ext, product, vendor, ...)'
mkdir -- "$work/logical-partitions"
lpunpack "$work/super.img" "$work/logical-partitions/" >/dev/null
rm -- "$work/super.img"
parts=(system)
[[ "$WITH_GAPPS" == false ]] || parts+=(system_ext product)
[[ "$WITH_WIDEVINE" == false ]] || parts+=(vendor)
for part in "${parts[@]}"; do
    [[ -s "$work/logical-partitions/$part.img" ]] || fail "Missing logical partition: $part.img"
done
if [[ "$WITH_GAPPS" == true ]]; then
    debugfs -R 'ls /priv-app/Phonesky' "$work/logical-partitions/product.img" 2>/dev/null | grep -q 'Phonesky.apk' ||
        fail 'No Play Store in this image: use the Google Play (google_apis_playstore) image, not Google APIs'
fi
mv -- "$work/logical-partitions" "$OUT/logical-partitions"

actual=not-extracted
if [[ "$WITH_NDK" == true ]]; then
    info 'Extracting the ARM64 translator (libndk_translation)'
    bash "$SCRIPT_DIR/internal/extract-ndk-translation.sh" --source-img "$OUT/logical-partitions/system.img" \
        --output "$OUT/ndk-translation" >/dev/null
    actual="$(sha256sum "$OUT/ndk-translation/payload/system/lib64/libndk_translation.so" | cut -d' ' -f1)"
    [[ "$actual" == "$EXPECTED_TRANSLATOR" ]] ||
        info "WARNING: translator differs from the tested build (r14); --with-ndk will refuse it"
fi
(cd "$OUT/logical-partitions" && sha256sum -- *.img) > "$OUT/SOURCE-IMAGES.sha256"

cat > "$OUT/SOURCE.txt" <<EOF
Source zip: $(basename -- "$ZIP")
Source SHA256: $(sha256sum "$ZIP" | cut -d' ' -f1)
Translator SHA256: $actual
EOF
printf '[PASS] Google inputs ready in %s\n' "$OUT"
if [[ "$DEFAULT_OUT" == true ]]; then
    printf 'make-deck-bundle-x86_64.sh finds them there; nothing to add to .build-env.\n'
elif [[ "$SELECTED" == true ]]; then
    printf 'Reuse with lepton-customize inject --google-inputs %q (select the same or fewer components).\n' "$OUT"
else
    printf 'Add to .build-env:\n  LEPTON_GOOGLE_IMAGES="%s/logical-partitions"\n  LEPTON_NDK_PAYLOAD="%s/ndk-translation/payload"\n' "$OUT" "$OUT"
fi
