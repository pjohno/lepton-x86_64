#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# The Deck installer downloads Google's adb itself (bundles never contain it).
# Uses a fake curl and a fixture Platform-Tools ZIP: no network access.
# Optional: LEPTON_REAL_ADB_ZIP=/path/platform-tools_r37.0.1-linux.zip also
# installs the real Google ZIP against the shipped (unmodified) pin.
set -Eeuo pipefail
not() { if "$@"; then echo "FAIL: unexpectedly succeeded: $*" >&2; exit 1; fi; }
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
template="$repo/compat_tool/tools/lepton-install-bundle"
source "$repo/image-14/tests/lib/fake-google-adb.sh"
work="$(mktemp -d)"
trap 'chmod -R u+rwX -- "$work" 2>/dev/null; rm -rf -- "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# One pin, two copies: the stage provisioning and the Deck installer.
pin() { grep -E "^$1='[^']+'\$" "$2" || fail "$1 missing in $2"; }
for name in ADB_URL ADB_SHA256 ADB_VERSION; do
    [[ "$(pin "$name" "$template")" == "$(pin "$name" "$repo/image-14/scripts/internal/provision-deck-tools.sh")" ]] ||
        fail "$name differs between the installer and provision-deck-tools.sh"
done
grep -qx "ADB_URL='https://dl.google.com/android/repository/platform-tools_r37.0.1-linux.zip'" "$template"
grep -qx "ADB_SHA256='a902be8f45c6c62e76c9efaf6947a0fa747c9cabd89a2ac8e0d16ecb30b3ed01'" "$template"
grep -qx "ADB_VERSION='37.0.1-15733141'" "$template"

# A minimal bundle, laid out as packaging writes it (no tools/platform-tools).
make_bundle() {
    local id="$1" payload="$work/payload-$1" out="$work/bundles" prefix="${3:-lepton-x86_64-}"
    mkdir -p "$payload/compat_tool/tools" "$payload/compat_tool/liblepton" "$payload/compat_tool/sysbake/system" \
        "$payload/tools/bin" "$out"
    printf '#!/bin/sh\n' > "$payload/compat_tool/lepton"; chmod 755 "$payload/compat_tool/lepton"
    printf '<packages/>\n' > "$payload/compat_tool/sysbake/system/packages.xml"
    printf '#!/bin/sh\n' > "$payload/tools/bin/inotifywait"
    cp "$repo/compat_tool/tools/lepton-manage-installs" "$repo/compat_tool/tools/lepton-register-tool" \
        "$payload/compat_tool/tools/"
    printf '{"format_version": 2, "bundle_id": "%s", "tool_id": "lepton_x86_64_%s", "display_name": "Lepton %s",
 "install_directory": "lepton_x86_64_%s", "gapps": false, "ndk": false}\n' "$id" "$id" "$id" "$id" > "$payload/BUNDLE.json"
    if [[ -n "${2:-}" ]]; then install -D -m 755 "$2" "$payload/tools/platform-tools/adb"; fi
    (cd "$payload" && tar -czf "$out/${prefix}$id.tar.gz" .)
    sed "s|^DEFAULT_ARCHIVE=''\$|DEFAULT_ARCHIVE='${prefix}$id.tar.gz'|" "$template" \
        > "$out/${prefix}$id.install.sh"
    (cd "$out" && sha256sum "${prefix}$id.tar.gz" "${prefix}$id.install.sh") \
        > "$out/${prefix}$id.tar.gz.sha256"
}
make_bundle base
[[ -z "$(tar -tzf "$work/bundles/lepton-x86_64-base.tar.gz" | grep -E '(^|/)adb$' || true)" ]]
shipped="$work/bundles/lepton-x86_64-base.install.sh"

good_sha="$(fake_adb_zip "$work/good")"
other_sha="$(fake_adb_zip "$work/other-version" 36.0.0-1)"
pinned="$work/bundles/base-pinned.install.sh"
pin_installer "$shipped" "$pinned" "$good_sha"
pin_installer "$shipped" "$work/bundles/base-other.install.sh" "$other_sha"
printf '<html>Service unavailable</html>\n' > "$work/not-a-zip.zip"

mkdir -p "$work/bin"; install_fake_curl "$work/bin"
home="$work/home"; mkdir -p "$home/.local/share/Steam"   # native Steam
data="$home/.local/share"; dest="$data/lepton_x86_64_base"
vdf="$data/Steam/compatibilitytools.d/lepton_x86_64_base.vdf"
export FAKE_CURL_LOG="$work/curl.log" FAKE_ADB_ZIP="$work/good/platform-tools.zip"
deck() {
    local installer="$1"; shift
    env -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u FAKE_CURL_FAIL LEPTON_INSTALL_IN_TERMINAL=1 LEPTON_NO_DIALOGS=1 \
        HOME="$home" PATH="$work/bin:$PATH" ${FAKE_FAIL:+FAKE_CURL_FAIL=1} bash "$installer" --install-profile steamos --allow-non-amd "$@"
}
# Fails, says why, and leaves no install, registration, settings or temp files.
expect_clean_failure() {
    local message="$1"; shift
    if deck "$@" > "$work/out.log" 2>&1; then cat "$work/out.log"; fail "accepted: $*"; fi
    grep -Fq -- "$message" "$work/out.log" || { cat "$work/out.log"; fail "missing message: $message"; }
    [[ ! -e "$dest" && ! -e "$vdf" && ! -e "$home/.config/lepton-x86_64" ]] || fail "partial install after: $message"
    ! compgen -G "$data/.lepton-*" > /dev/null || fail "temporary files left after: $message"
}

# --check is offline and needs no download.
FAKE_FAIL=1 deck "$pinned" --check > "$work/check.log"
[[ ! -e "$work/curl.log" && ! -e "$dest" ]]

FAKE_FAIL=1 expect_clean_failure 'Could not download ADB from Google. Nothing was installed or changed' "$pinned"
FAKE_ADB_ZIP="$work/not-a-zip.zip" expect_clean_failure 'does not contain adb and NOTICE.txt' "$pinned"
expect_clean_failure 'does not match the pinned SHA256' "$shipped"
FAKE_ADB_ZIP="$work/other-version/platform-tools.zip" expect_clean_failure 'is not version 37.0.1-15733141' \
    "$work/bundles/base-other.install.sh"
expect_clean_failure 'ADB ZIP not found' "$pinned" --adb-zip "$work/missing.zip"

# Success: HTTPS-only download of the pinned URL; only adb + notice installed.
rm -f "$work/curl.log"
deck "$pinned" > "$work/install.log"
grep -q 'ADB 37.0.1-15733141 verified (SHA256 and version)' "$work/install.log"
[[ $(wc -l < "$work/curl.log") == 1 ]]
grep -Fq -- "--proto =https --proto-redir =https --tlsv1.2" "$work/curl.log"
grep -Fq -- "-- https://dl.google.com/android/repository/platform-tools_r37.0.1-linux.zip" "$work/curl.log"
[[ ! -e "$dest/compat_tool/install-profile" ]] || fail 'ordinary Deck install acquired a local profile'
adb="$dest/tools/platform-tools/adb"
[[ -f "$adb" && -x "$adb" && ! -L "$adb" ]]
[[ "$(sha256sum "$adb" | awk '{print $1}')" == "$good_sha" ]]
"$adb" version | grep -x 'Version 37.0.1-15733141' >/dev/null
cmp "$work/good/src/platform-tools/NOTICE.txt" "$dest/tools/licenses/google-platform-tools-NOTICE.txt"
grep -qx 'Source: https://dl.google.com/android/repository/platform-tools_r37.0.1-linux.zip' "$dest/tools/platform-tools/SOURCE.txt"
grep -qx 'Version: 37.0.1-15733141' "$dest/tools/platform-tools/SOURCE.txt"
[[ "$(LC_ALL=C ls "$dest/tools/platform-tools")" == $'SOURCE.txt\nadb' ]]
[[ -z "$(find "$dest" -name '*.zip' -o -name fastboot)" ]]
[[ -f "$vdf" && -x "$dest/compat_tool/lepton" ]]
not compgen -G "$data/.lepton-*" > /dev/null

# A failed download while replacing leaves the existing install untouched.
echo keep > "$dest/marker"
FAKE_FAIL=1 deck "$pinned" --replace > "$work/replace-fail.log" 2>&1 && fail 'replace with failed download accepted'
grep -q 'Nothing was installed or changed' "$work/replace-fail.log" || { cat "$work/replace-fail.log"; fail 'replace failure message'; }
[[ "$(cat "$dest/marker")" == keep && -x "$adb" && -f "$vdf" ]]
not compgen -G "$dest.previous-*" > /dev/null
not compgen -G "$data/.lepton-*" > /dev/null
# A good download replaces it as before.
deck "$pinned" --replace > "$work/replace.log"
[[ ! -e "$dest/marker" && -x "$adb" ]]
not compgen -G "$dest.previous-*" > /dev/null

# Offline: a local copy of the ZIP, same checks, no download attempted.
rm -f "$work/curl.log"
FAKE_FAIL=1 deck "$pinned" --replace --adb-zip "$work/good/platform-tools.zip" > "$work/local.log"
[[ ! -e "$work/curl.log" ]]
grep -q 'Using local Google Platform-Tools ZIP' "$work/local.log"
grep -q '^Source: local copy of https://dl.google.com/' "$dest/tools/platform-tools/SOURCE.txt"
"$adb" version | grep -x 'Version 37.0.1-15733141' >/dev/null
expect_local_reject() {
    if FAKE_FAIL=1 deck "$1" --replace --adb-zip "$2" > "$work/out.log" 2>&1; then fail "accepted $2"; fi
    grep -Fq -- "$3" "$work/out.log"
    [[ -f "$adb" ]]  # previous install still in place
}
expect_local_reject "$shipped" "$work/good/platform-tools.zip" 'does not match the pinned SHA256'
expect_local_reject "$pinned" "$work/not-a-zip.zip" 'does not contain adb'

# Older bundles that still carry the pinned adb install offline, unchanged.
make_bundle legacy "$work/good/src/platform-tools/adb" lepton-x86_64-steamdeck-
pin_installer "$work/bundles/lepton-x86_64-steamdeck-legacy.install.sh" "$work/bundles/legacy-pinned.install.sh" "$good_sha"
rm -f "$work/curl.log"
FAKE_FAIL=1 deck "$work/bundles/legacy-pinned.install.sh" > "$work/legacy.log"
[[ ! -e "$work/curl.log" ]]
grep -q 'ADB 37.0.1-15733141 from the bundle verified' "$work/legacy.log"
[[ -x "$data/lepton_x86_64_legacy/tools/platform-tools/adb" ]]
# ...but a bundled adb that is not the pinned one is replaced by a download.
make_bundle tampered "$work/other-version/src/platform-tools/adb"
pin_installer "$work/bundles/lepton-x86_64-tampered.install.sh" "$work/bundles/tampered-pinned.install.sh" "$good_sha"
rm -f "$work/curl.log"
deck "$work/bundles/tampered-pinned.install.sh" > "$work/tampered.log"
[[ $(wc -l < "$work/curl.log") == 1 ]]
[[ "$(sha256sum "$data/lepton_x86_64_tampered/tools/platform-tools/adb" | awk '{print $1}')" == "$good_sha" ]]

if [[ -n "${LEPTON_REAL_ADB_ZIP:-}" ]]; then
    # The real Google ZIP against the unmodified, shipped pin.
    rm -rf -- "$dest" "$vdf"
    FAKE_FAIL=1 deck "$shipped" --adb-zip "$LEPTON_REAL_ADB_ZIP" > "$work/real.log"
    [[ "$(sha256sum "$adb" | awk '{print $1}')" == a902be8f45c6c62e76c9efaf6947a0fa747c9cabd89a2ac8e0d16ecb30b3ed01 ]]
    "$adb" version | grep -x 'Version 37.0.1-15733141' >/dev/null
    [[ -s "$dest/tools/licenses/google-platform-tools-NOTICE.txt" ]]
    echo 'PASS: real Google Platform-Tools ZIP installed against the shipped pin'
fi
echo 'PASS: installer ADB download, SHA256/version checks, failure without partial installs, replace rollback, local ZIP and older bundles'
