#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verify optional inputs and fresh-output guards without building Android.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/repo/image-14/scripts/lib" "$work/existing/aosp" "$work/payload/system/lib64"
cp "$repo/image-14/do_build_x86_64.sh" "$work/repo/image-14/"
cp "$repo/image-14/scripts/lib/workspace.sh" "$work/repo/image-14/scripts/lib/"
{
    printf 'LEPTON_OUTPUT_DIR=%q\n' "$work/existing"
    printf 'LEPTON_BUILD_TARGET=aosp_lepton_x86_64-ap2a-userdebug\n'
} > "$work/repo/.build-env"
printf 'fixture bridge' > "$work/payload/system/lib64/libndk_translation.so"
(cd "$work/payload" && sha256sum system/lib64/libndk_translation.so) > "$work/SHA256SUMS"
run() { bash "$work/repo/image-14/do_build_x86_64.sh" "$@"; }
reject() {
    local message="$1"; shift
    if run "$@" > "$work/result" 2>&1; then echo 'FAIL: unsafe build accepted'; exit 1; fi
    grep -Fq -- "$message" "$work/result"
}
run --help > "$work/help"
grep -q -- '--with-gapps' "$work/help"
grep -q -- '--with-ndk' "$work/help"
grep -q -- '--sysbake-rendering' "$work/help"
reject '--google-images requires --with-gapps' --check --bundle-id fixture --google-images "$work/existing"
reject 'Invalid tool ID' --check --bundle-id fixture --tool-id '../bad'
reject 'Invalid sysbake rendering' --check --bundle-id fixture --sysbake-rendering bogus
reject '--ndk-payload requires --with-ndk' --check --bundle-id fixture --ndk-payload "$work/payload"
reject 'existing local NDK payload is required' --check --bundle-id fixture --with-ndk
reject 'Refusing to reuse an existing Android checkout' --check --bundle-id fixture
reject 'Refusing to reuse an existing Android checkout' --execute --bundle-id fixture --with-ndk --ndk-payload "$work/payload" --sysbake-rendering amd
printf 'corrupted' >> "$work/payload/system/lib64/libndk_translation.so"
reject 'NDK payload hash verification failed' --check --bundle-id fixture --with-ndk --ndk-payload "$work/payload"
echo 'PASS: full-pipeline CLI defaults, optional NDK/hash validation, rendering selection and fresh-output guards'
