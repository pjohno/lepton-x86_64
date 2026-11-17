#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Real CLI/source/path/provenance checks; fake compiler and image extractor.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
fail() { cat "$work/log" >&2; echo "FAIL: $*" >&2; exit 1; }
fake="$work/repo"; ws="$work/ws"; aosp="$ws/aosp"; product="$aosp/out/target/product/lepton_x86_64"
mkdir -p "$fake/image-14/scripts/"{lib,internal} "$fake/image-14/patches" "$fake/image-14/hardware" "$work/bin" \
    "$aosp/.lepton-clean14-state" "$aosp/build" "$aosp/device/waydroid/waydroid" "$aosp/vendor/extra" "$aosp/hardware/waydroid" "$ws/images" "$ws/rootfs"
cp "$repo/image-14/scripts/"{build-images-x86_64.sh,build-incremental-bundle-x86_64.sh} "$fake/image-14/scripts/"
cp "$repo/image-14/scripts/lib/"{workspace.sh,image-provenance.sh,packaging-fuse.sh,package-images.sh} "$fake/image-14/scripts/lib/"
cp "$repo/image-14/scripts/internal/"{check-active-compilation.py,validate-android-images.py} "$fake/image-14/scripts/internal/"
printf '#!/bin/bash\n# Fixture: Mesa host tools need the real builder.\nexit 0\n' > "$fake/image-14/scripts/internal/bootstrap-mesa-clc.sh"
cat >> "$fake/image-14/scripts/lib/image-provenance.sh" <<'CONFIG'
LEPTON_COPIED_TREES=('image-14/hardware|hardware/waydroid')
LEPTON_CUSTOM_PATCHES=('hardware/waydroid|0009-hwc-local-wayland-fullscreen.patch')
CONFIG
printf 'base\n' > "$fake/image-14/hardware/source.c"
printf 'patched\n' > "$aosp/hardware/waydroid/source.c"
cat > "$fake/image-14/patches/0009-hwc-local-wayland-fullscreen.patch" <<'PATCH'
diff --git a/source.c b/source.c
--- a/source.c
+++ b/source.c
@@ -1 +1 @@
-base
+patched
PATCH
printf 'LEPTON_OUTPUT_DIR=%q\nLEPTON_BUILD_TARGET=aosp_lepton_x86_64-ap2a-userdebug\nLEPTON_BUILD_JOBS=1\nLEPTON_MIN_FREE_GIB=0\nLEPTON_BUILD_CONTAINER=lepton-builder-ubuntu26:latest\n' "$ws" > "$fake/.build-env"
touch "$aosp/.lepton-clean14-owner" "$aosp/build/envsetup.sh" "$aosp/.lepton-clean14-state/"{sync,vendor,patches}.done
printf old-images > "$ws/images/system.img"; printf old-rootfs > "$ws/rootfs/saved"
# Default replacement only overwrites outputs recognised as earlier packaging.
printf old-vendor > "$ws/images/vendor.img"; (cd "$ws/images" && sha256sum system.img vendor.img > SHA256SUMS)
mkdir -p "$ws/rootfs/system" "$ws/rootfs/vendor/lib64/hw"
printf 'sdk=34\n' > "$ws/rootfs/system/build.prop"; printf old-HAL > "$ws/rootfs/vendor/lib64/hw/vulkan.radeon.so"
cat > "$work/bin/podman" <<'PODMAN'
#!/bin/bash
case "$1" in
image) exit 0 ;;
unshare) shift; exec "$@" ;;
run)
    printf 'compile\n' >> "$TRACE"
    while (($#)); do [[ "$1" != --cidfile ]] || printf cid > "$2"; shift; done
    cat > "$TRACE.input"
    mkdir -p "$PRODUCT/vendor/lib64/hw"
    # Smallest complete sparse image (one DONT_CARE chunk) that packaging validates.
    for part in system vendor; do
        printf '\x3a\xff\x26\xed\x01\x00\x00\x00\x1c\x00\x0c\x00\x00\x10\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\xc3\xca\x00\x00\x01\x00\x00\x00\x0c\x00\x00\x00' > "$PRODUCT/$part.img"
    done
    case "${FAKE_HWC:-fresh}" in
        missing) rm -f "$PRODUCT/vendor/lib64/hw/hwcomposer.waydroid.so" ;;
        stale) printf old-HAL > "$PRODUCT/vendor/lib64/hw/hwcomposer.waydroid.so" ;;
        *) printf 'ELF fixture Lepton local configure:' > "$PRODUCT/vendor/lib64/hw/hwcomposer.waydroid.so" ;;
    esac
    if [[ -n "${SWAP_IMAGES:-}" ]]; then
        # Destinations are no longer reserved before compiling; a symlink
        # planted there meanwhile must still be refused at packaging time.
        mkdir -p "$(dirname "$SWAP_IMAGES")"
        ln -s "$OLD_IMAGES" "$SWAP_IMAGES"
    fi ;;
esac
PODMAN
cat > "$fake/image-14/scripts/internal/package-repro-rootfs.sh" <<'PACKAGE'
#!/bin/bash
set -e
[[ ! -e "$2" ]] || exit 1
mkdir -p "$2/system" "$2/vendor/lib64/hw"
printf 'sdk=34\n' > "$2/system/build.prop"
cp "$1/out/target/product/lepton_x86_64/vendor/lib64/hw/hwcomposer.waydroid.so" "$2/vendor/lib64/hw/"
[[ "${FAKE_HWC:-}" != mismatch ]] || printf wrong-HAL > "$2/vendor/lib64/hw/hwcomposer.waydroid.so"
printf 'rootfs %s\n' "$2" >> "$TRACE"
PACKAGE
cat > "$fake/image-14/scripts/make-deck-bundle-x86_64.sh" <<'BUNDLE'
#!/bin/bash
printf '%s\n' "$@" > "$TRACE.bundle"
while (($#)); do
    case "$1" in --rootfs-source) rootfs="$2"; shift 2 ;; --stage-dir) stage="$2"; shift 2 ;; --bundle-dir) bundles="$2"; shift 2 ;; *) shift ;; esac
done
[[ -f "$rootfs/.lepton-image-provenance" && ! -e "$stage" ]] || exit 1
mkdir -p "$stage/compat_tool/sysbake" "$bundles"
printf fresh-sysbake > "$stage/compat_tool/sysbake/new"
BUNDLE
# Real host probes are covered by tests/test-build-preflight.py; here only the
# wrapper's hand-off to the capability check is recorded.
cat > "$fake/image-14/scripts/internal/check-host-capabilities.py" <<'CAPS'
import os, sys
with open(os.environ['TRACE'] + '.capabilities', 'w') as out:
    out.write('\n'.join(sys.argv[1:]) + '\n')
CAPS
chmod +x "$work/bin/podman" "$fake/image-14/scripts/internal/package-repro-rootfs.sh"
git -C "$fake" init -q
git -C "$fake" -c user.name=Test -c user.email=t@example.invalid add -A
git -C "$fake" -c user.name=Test -c user.email=t@example.invalid commit -qm fixture
run() { env PATH="$work/bin:$PATH" TRACE="$work/trace" PRODUCT="$product" FAKE_HWC="${FAKE_HWC:-fresh}" SWAP_IMAGES="${SWAP_IMAGES:-}" OLD_IMAGES="$ws/images" bash "$fake/image-14/scripts/build-images-x86_64.sh" "$@" > "$work/log" 2>&1; }
reject() { local expected="$1"; shift; if run "$@"; then fail 'accepted invalid build'; fi; grep -Fq -- "$expected" "$work/log" || fail "$expected"; }
args=(--images-dir "$ws/new/images" --rootfs-dir "$ws/new/rootfs")
run --check "${args[@]}" || fail check
[[ ! -e "$ws/new" && ! -e "$work/trace" ]]
for path in / /tmp /mnt "$HOME" "$fake/inside" "$aosp/output" "$ws/images/inside"; do
    if run --check --images-dir "$path" --rootfs-dir "$ws/new/rootfs"; then fail "accepted $path"; fi
    grep -Eqi 'unsafe|overlap' "$work/log" || fail 'missing path diagnostic'
done
mkdir "$ws/existing"
reject 'existing destination' --check --images-dir "$ws/existing" --rootfs-dir "$ws/new/rootfs"
ln -s "$ws" "$work/alias"
reject 'symlink' --check --images-dir "$work/alias/new/images" --rootfs-dir "$ws/new/rootfs"
reject 'Unsafe image destination' --check --images-dir "$ws/new/images" --rootfs-dir "$ws/new/images/rootfs"
reject 'outside the original artifact' --check --images-dir "$ws/images/test" --rootfs-dir "$ws/new/rootfs"
reject '--repair cannot be combined' --repair "${args[@]}"
printf base > "$aosp/hardware/waydroid/source.c"
# Ensure newline matches the old-side patch exactly.
printf 'base\n' > "$aosp/hardware/waydroid/source.c"
reject 'can be applied safely' --execute "${args[@]}"
[[ "$(cat "$aosp/hardware/waydroid/source.c")" == base && ! -e "$work/trace" ]]
printf 'conflict\n' > "$aosp/hardware/waydroid/source.c"
reject 'inconsistent with patch' --execute "${args[@]}"
printf 'patched\n' > "$aosp/hardware/waydroid/source.c"
printf extra > "$aosp/hardware/waydroid/unreviewed"
reject 'Prepared source content differs' --check "${args[@]}"
rm "$aosp/hardware/waydroid/unreviewed"
touch "$aosp/.lepton-clean14-state/build.running"
reject 'no cleanup performed' --execute "${args[@]}"
rm "$aosp/.lepton-clean14-state/build.running"
mkdir -p "$aosp/out/keep"
printf keep > "$aosp/out/keep/intermediate"
run --execute "${args[@]}" || fail execute
[[ "$(cat "$ws/images/system.img")" == old-images && "$(cat "$ws/rootfs/saved")" == old-rootfs ]]
[[ "$(cat "$aosp/out/keep/intermediate")" == keep ]]
[[ -s "$ws/new/images/SHA256SUMS" && -s "$ws/new/images/BUILD-INFO.txt" ]]
(cd "$ws/new/images" && sha256sum -c SHA256SUMS)
cmp "$ws/new/images/BUILD-INFO.txt" "$ws/new/rootfs/.lepton-image-provenance"
grep -q '^Rootfs hwcomposer SHA256:' "$ws/new/images/BUILD-INFO.txt"
grep -q 'm -j.*hwcomposer.waydroid' "$work/trace.input"
if grep -Eq 'installclean|m .*clean|prepare.*reset' "$work/trace.input"; then fail 'clean invoked'; fi
reject 'existing destination' --execute "${args[@]}"
for kind in missing stale mismatch; do
    FAKE_HWC="$kind" reject 'hwcomposer' --execute --images-dir "$ws/$kind/images" --rootfs-dir "$ws/$kind/rootfs"
    [[ ! -e "$ws/$kind/rootfs/.lepton-image-provenance" ]]
done
SWAP_IMAGES="$ws/race/images" reject 'Output path contains a symlink' --execute --images-dir "$ws/race/images" --rootfs-dir "$ws/race/rootfs"
[[ "$(cat "$ws/images/system.img")" == old-images ]]
# Wrapper passes the NEW rootfs and every optional flavor argument unchanged.
env PATH="$work/bin:$PATH" TRACE="$work/trace" PRODUCT="$product" \
    bash "$fake/image-14/scripts/build-incremental-bundle-x86_64.sh" --execute \
    --bundle-id fullscreen-test --output-dir "$ws/fullscreen-test" \
    --with-gapps --with-ndk --with-widevine --google-images /fixtures/google --ndk-payload /fixtures/ndk \
    > "$work/log" 2>&1 || fail wrapper
[[ -f "$ws/fullscreen-test/stage/compat_tool/sysbake/new" ]]
grep -Fxq "$ws/fullscreen-test/rootfs" "$work/trace.bundle"
for flag in --with-gapps --with-ndk --with-widevine; do grep -Fxq -- "$flag" "$work/trace.bundle"; done
for flag in complete --with-gapps --with-ndk --with-widevine; do grep -Fxq -- "$flag" "$work/trace.capabilities"; done
[[ "$(cat "$ws/images/system.img")" == old-images && "$(cat "$ws/rootfs/saved")" == old-rootfs ]]
# Omitting overrides preserves default replacement behavior.
run --execute || fail default
cmp "$ws/images/system.img" "$product/system.img" && [[ ! -e "$ws/rootfs/saved" ]]
[[ -s "$ws/rootfs/.lepton-image-provenance" ]]
echo 'PASS: isolated incremental outputs, source/patch guards, stale/missing HAL refusal, checksums/provenance, new-rootfs bundle handoff, optional flavors and default replacement'
