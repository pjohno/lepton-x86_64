#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Offline tests for the workspace layout, transfer-deck-bundle --check,
# prepare-google-inputs argument checks and the Widevine injector.
# Uses synthetic files only: no Google image, Deck, network or real workspace.
set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
step=''
trap 'printf "FAIL: %s (line %s)\n" "${step:-test setup}" "$LINENO" >&2' ERR
expect_fail() { # expect_fail PATTERN command...
    local pattern="$1"; shift
    if "$@" > "$TMP/out.log" 2>&1; then fail "unexpectedly succeeded: $*"; fi
    grep -Fq -- "$pattern" "$TMP/out.log" || { cat "$TMP/out.log" >&2; fail "expected '$pattern' from: $*"; }
}

# A disposable copy of the user-facing scripts, so the real .build-env and
# workspace are never read.
FAKE="$TMP/repo"
mkdir -p "$FAKE/image-14/scripts/lib" "$FAKE/image-14/scripts/internal"
cp "$REPO/image-14/scripts/lib/workspace.sh" "$REPO/image-14/scripts/lib/google-services.sh" "$FAKE/image-14/scripts/lib/"
cp "$REPO/image-14/scripts/transfer-deck-bundle.sh" "$REPO/image-14/scripts/prepare-google-inputs.sh" "$FAKE/image-14/scripts/"
WS="$TMP/disk/workspace"
printf 'LEPTON_OUTPUT_DIR=%q\n' "$WS" > "$FAKE/.build-env"

## Workspace layout
step='lepton_workspace accepted a missing LEPTON_OUTPUT_DIR'
(
    unset LEPTON_OUTPUT_DIR
    source "$REPO/image-14/scripts/lib/workspace.sh"
    if (lepton_workspace) 2>/dev/null; then exit 1; fi
)
step='workspace default and override paths'
(
    LEPTON_OUTPUT_DIR="$TMP/disk/./workspace/"
    LEPTON_AOSP_DIR="$TMP/elsewhere/aosp"
    source "$REPO/image-14/scripts/lib/workspace.sh"
    lepton_workspace
    [[ "$LEPTON_WORKSPACE" == "$WS" ]]
    [[ "$LEPTON_AOSP_DIR" == "$TMP/elsewhere/aosp" ]]           # override kept
    [[ "$LEPTON_LOG_DIR" == "$WS/logs" && "$LEPTON_IMAGES_DIR" == "$WS/images" ]]
    [[ "$LEPTON_ROOTFS_DIR" == "$WS/rootfs" && "$LEPTON_STAGES_DIR" == "$WS/stages" ]]
    [[ "$LEPTON_DECK_BUNDLE_DIR" == "$WS/bundles" && "$LEPTON_GOOGLE_INPUTS_DIR" == "$WS/google-inputs" ]]
    [[ -z "${LEPTON_GOOGLE_IMAGES:-}" && -z "${LEPTON_NDK_PAYLOAD:-}" ]] # absent inputs not guessed
)
mkdir -p "$TMP/gi/logical-partitions" "$TMP/gi/ndk-translation/payload"
step='Google inputs auto-detection'
(
    LEPTON_OUTPUT_DIR="$WS" LEPTON_GOOGLE_INPUTS_DIR="$TMP/gi" LEPTON_NDK_PAYLOAD=/explicit
    source "$REPO/image-14/scripts/lib/workspace.sh"
    lepton_workspace
    [[ "$LEPTON_GOOGLE_IMAGES" == "$TMP/gi/logical-partitions" ]]  # found automatically
    [[ "$LEPTON_NDK_PAYLOAD" == /explicit ]]                       # explicit setting wins
)

# New workspace folders get the user's own group and no setgid bit, even under
# a setgid parent owned by another of the user's groups (the rootless Podman
# "value too large for defined data type" fix).
parent="$TMP/shared"
mkdir "$parent"
other_group="$(id -G | tr ' ' '\n' | grep -vx "$(id -g)" | head -1 || true)"
[[ -z "$other_group" ]] || chgrp "$other_group" "$parent"
chmod g+s "$parent"
step='lepton_create_workspace group/setgid handling'
(
    source "$REPO/image-14/scripts/lib/workspace.sh"
    lepton_create_workspace "$parent/ws/nested"
    for dir in "$parent/ws/nested"; do
        [[ "$(stat -c %g "$dir")" == "$(id -g)" ]]
        [[ "$(stat -c %A "$dir")" != *s* && "$(stat -c %A "$dir")" != *S* ]]
    done
    lepton_create_workspace "$parent/ws/nested"   # idempotent on an existing folder
)

## transfer-deck-bundle.sh --check (local verification only)
transfer() { bash "$FAKE/image-14/scripts/transfer-deck-bundle.sh" "$@"; }
mkdir -p "$WS/bundles"
step='transfer-deck-bundle --check'
(
    cd "$WS/bundles"
    printf 'archive\n' > lepton-x86_64-t1.tar.gz
    sha256sum lepton-x86_64-t1.tar.gz > lepton-x86_64-t1.tar.gz.sha256
    printf '#!/bin/sh\n' > lepton-x86_64-t1.install.sh
)
transfer --check --bundle-id t1 | grep -Fq '[PASS] Bundle t1 is complete and verified'
expect_fail '--bundle-id is required' transfer --check
expect_fail '--deck-ip is required' transfer --bundle-id t1
expect_fail 'Unknown argument' transfer --check --bundle-id t1 --bogus
expect_fail 'Bundle t2 not found' transfer --check --bundle-id t2
mkdir "$TMP/other-bundles"
cp "$WS"/bundles/lepton-x86_64-t1.* "$TMP/other-bundles/"
transfer --check --bundle-id t1 --bundle-dir "$TMP/other-bundles" >/dev/null
printf 'tampered\n' >> "$WS/bundles/lepton-x86_64-t1.tar.gz"
expect_fail 'Checksum mismatch' transfer --check --bundle-id t1

## prepare-google-inputs.sh refuses bad input before extracting anything
step='prepare-google-inputs input checks'
prep() { bash "$FAKE/image-14/scripts/prepare-google-inputs.sh" "$@"; }
make_zip() { # make_zip ZIP SDK [with-system-img]
    python3 -I - "$@" <<'PY'
import sys, zipfile
path, sdk = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(path, 'w') as z:
    z.writestr('x86_64/build.prop', f'ro.build.version.sdk={sdk}\nro.build.flavor=sdk_gphone64_x86_64-user\n')
    if len(sys.argv) > 3:
        z.writestr('x86_64/system.img', b'not a disk')
PY
}
expect_fail '--zip is required' prep
expect_fail 'Zip not found' prep --zip "$TMP/missing.zip" --output "$TMP/gi-out"
make_zip "$TMP/no-system.zip" 34
expect_fail 'Not an x86_64 emulator system image zip' prep --zip "$TMP/no-system.zip" --output "$TMP/gi-out"
make_zip "$TMP/api33.zip" 33 with-system-img
expect_fail 'not Android 14' prep --zip "$TMP/api33.zip" --output "$TMP/gi-out"
[[ ! -e "$TMP/gi-out" ]] || fail 'prepare-google-inputs wrote output for a rejected zip'
mkdir "$TMP/gi-exists"
expect_fail 'Output already exists' prep --zip "$TMP/api33.zip" --output "$TMP/gi-exists"
# The default output is the workspace's google-inputs/.
mkdir -p "$WS/google-inputs"
expect_fail "Output already exists: $WS/google-inputs" prep --zip "$TMP/api33.zip"

## Widevine: check and inject from a synthetic vendor.img
apex_name=com.google.android.widevine
payload="$TMP/wv/payload"
mkdir -p "$payload/bin/hw" "$payload/etc/vintf" "$payload/lib64"
printf '\n\x1c%s' "$apex_name" > "$payload/apex_manifest.pb"
printf 'service\n' > "$payload/bin/hw/android.hardware.drm-service.widevine"
printf 'rc\n' > "$payload/etc/$apex_name.rc"
printf 'xml\n' > "$payload/etc/vintf/$apex_name.xml"
printf 'lib\n' > "$payload/lib64/libcrypto.so"
make_vendor() { # make_vendor PAYLOAD_DIR OUT_DIR
    local out="$2"
    mkdir -p "$out/tree/apex"
    mke2fs -q -t ext4 -d "$1" "$out/apex_payload.img" 4M
    python3 -I - "$out/apex_payload.img" "$out/tree/apex/$apex_name.nonupdatable.apex" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[2], 'w') as z:
    z.write(sys.argv[1], 'apex_payload.img')
PY
    mke2fs -q -t ext4 -d "$out/tree" "$out/vendor.img" 8M
}
make_vendor "$payload" "$TMP/wv/good"
mkdir -p "$TMP/wv/empty-tree"
mke2fs -q -t ext4 -d "$TMP/wv/empty-tree" "$TMP/wv/no-widevine.img" 4M
mkdir "$TMP/wv/none" && mv "$TMP/wv/no-widevine.img" "$TMP/wv/none/vendor.img"
step='Widevine check/inject'
(
    source "$FAKE/image-14/scripts/lib/google-services.sh"
    widevine_check "$TMP/wv/good"
    if widevine_check "$TMP/wv/none" 2>/dev/null; then exit 1; fi
    if widevine_check "$TMP/wv" 2>/dev/null; then exit 1; fi   # no vendor.img
    rootfs="$TMP/wv/rootfs"
    mkdir -p "$rootfs/vendor"
    widevine_inject "$rootfs" "$TMP/wv/good" "$TMP/wv/prov"
    dest="$rootfs/vendor/apex/$apex_name"
    [[ "$(stat -c %a "$dest/bin/hw/android.hardware.drm-service.widevine")" == 755 ]]
    [[ "$(stat -c %a "$dest/lib64/libcrypto.so")" == 644 && "$(stat -c %a "$dest/etc/vintf")" == 755 ]]
    [[ ! -e "$dest/lost+found" ]]
    (cd "$rootfs" && sha256sum --quiet -c "$TMP/wv/prov/SHA256SUMS")
    grep -q 'L3' "$TMP/wv/prov/COMPONENTS.txt"
    grep -q 'vendor.img' "$TMP/wv/prov/SOURCE-IMAGES.sha256"
    if widevine_inject "$rootfs" "$TMP/wv/good" "$TMP/wv/prov2" 2>/dev/null; then exit 1; fi  # no overwrite
)
rm -- "$payload/lib64/libcrypto.so"
make_vendor "$payload" "$TMP/wv/incomplete"
step='Widevine inject accepted an incomplete APEX'
(
    source "$FAKE/image-14/scripts/lib/google-services.sh"
    mkdir -p "$TMP/wv/rootfs2/vendor"
    if widevine_inject "$TMP/wv/rootfs2" "$TMP/wv/incomplete" "$TMP/wv/prov3" 2>"$TMP/wv/err"; then exit 1; fi
    grep -Fq 'Widevine APEX lacks lib64/libcrypto.so' "$TMP/wv/err"
    [[ ! -e "$TMP/wv/rootfs2/vendor/apex" ]]
)

echo 'PASS: workspace layout, bundle check, Google input validation and Widevine injection'
