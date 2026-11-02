#!/usr/bin/env bash
# Regression tests for default and alternate rootfs staging.
# Uses a disposable synthetic checkout; never touches an actual Lepton build.
set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
DEPLOY="$REPO/image-14/scripts/deploy-compat-x86_64.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

FAKE="$TMP/fake-repo"
OUTPUT="$TMP/output"
BIN="$TMP/bin"
mkdir -p "$FAKE/image-14/scripts" "$FAKE/compat_tool/liblepton/apk_extractor" \
    "$OUTPUT/repro-rootfs-auto/rootfs" "$OUTPUT/native-bridge-research/test-rootfs" "$BIN"
cp "$DEPLOY" "$FAKE/image-14/scripts/"
mkdir -p "$FAKE/compat_tool/liblepton/ndk_auxv"
cp "$REPO/compat_tool/liblepton/ndk_auxv/runtime.sh" "$FAKE/compat_tool/liblepton/ndk_auxv/"
: > "$FAKE/compat_tool/lepton"
: > "$FAKE/compat_tool/liblepton/apk_extractor/Makefile"
printf 'LEPTON_OUTPUT_DIR=%q\n' "$OUTPUT" > "$FAKE/.build-env"

NORMAL="$OUTPUT/repro-rootfs-auto/rootfs"
BRIDGE="$OUTPUT/native-bridge-research/test-rootfs"
for src in "$NORMAL" "$BRIDGE"; do
    mkdir -p "$src/system/bin" "$src/vendor/lib64/hw"
    printf '#!/system/bin/sh\n' > "$src/system/bin/sh"
    chmod +x "$src/system/bin/sh"
    printf 'radeon-test-fixture\n' > "$src/vendor/lib64/hw/vulkan.radeon.so"
    printf 'ro.build.version.sdk=34\n' > "$src/system/build.prop"
done
printf 'ro.dalvik.vm.native.bridge=0\n' >> "$NORMAL/system/build.prop"
printf 'ro.dalvik.vm.native.bridge=libndk_translation.so\n' >> "$BRIDGE/system/build.prop"

# Check and execution dependencies are all local. Avoid compiling Rust in the test.
cat > "$BIN/cargo" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "$BIN/make" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == -C && "$3" == install-native ]]
mkdir -p "$2/bin"
printf '#!/bin/sh\nexit 0\n' > "$2/bin/apk-info-extractor"
chmod +x "$2/bin/apk-info-extractor"
STUB
chmod +x "$BIN/cargo" "$BIN/make"
export PATH="$BIN:$PATH"

run() { bash "$FAKE/image-14/scripts/deploy-compat-x86_64.sh" "$@"; }
expect_fail() {
    if run "$@" > "$TMP/failure.log" 2>&1; then
        echo "FAIL: unexpectedly succeeded: $*" >&2
        exit 1
    fi
}

# The original default remains selected when --rootfs-source is omitted.
run --check --stage-dir "$OUTPUT/standard-stage" > "$TMP/default.log"
grep -Fq "Source: $NORMAL" "$TMP/default.log"

# Alternate source can be checked without producing any files.
run --check --rootfs-source "$BRIDGE" --stage-dir "$OUTPUT/bridge-stage" > "$TMP/bridge.log"
grep -Fq "Source: $BRIDGE" "$TMP/bridge.log"
[[ ! -e "$OUTPUT/bridge-stage" ]]

# Safety: no alternate source in legacy mode, no symlink rootfs, no nesting.
expect_fail --check --rootfs-source "$BRIDGE"
ln -s "$BRIDGE" "$OUTPUT/bridge-symlink"
expect_fail --check --rootfs-source "$OUTPUT/bridge-symlink" --stage-dir "$OUTPUT/bridge-stage"
expect_fail --check --rootfs-source "$BRIDGE" --stage-dir "$BRIDGE/nested-stage"

# Stage a real copy of the alternate source and confirm no source mutation.
run --execute --rootfs-source "$BRIDGE" --stage-dir "$OUTPUT/bridge-stage" > "$TMP/executed.log"
STAGED="$OUTPUT/bridge-stage/compat_tool/images/rootfs"
[[ -d "$STAGED" && ! -L "$STAGED" ]]
cmp "$BRIDGE/system/build.prop" "$STAGED/system/build.prop"
[[ -x "$OUTPUT/bridge-stage/compat_tool/liblepton/apk_extractor/bin/apk-info-extractor" ]]
[[ ! -e "$BRIDGE/nested-stage" ]]

# Existing stages are inspectable in check mode but cannot be overwritten.
run --check --rootfs-source "$BRIDGE" --stage-dir "$OUTPUT/bridge-stage" > /dev/null
expect_fail --execute --rootfs-source "$BRIDGE" --stage-dir "$OUTPUT/bridge-stage"
expect_fail --check --stage-dir "$OUTPUT/bridge-stage" # Default differs.
expect_fail --check --rootfs-source "$STAGED" --stage-dir "$OUTPUT/bridge-stage"

# Default execution still uses the standard rootfs and fresh separate stage.
run --execute --stage-dir "$OUTPUT/standard-stage" > /dev/null
cmp "$NORMAL/system/build.prop" "$OUTPUT/standard-stage/compat_tool/images/rootfs/system/build.prop"
[[ -f "$NORMAL/system/build.prop" && -f "$BRIDGE/system/build.prop" ]]

# Opt-in NDK deployment invokes the real injector, never downloads a payload,
# and leaves the original native source untouched. Only the compiler is stubbed.
cp "$REPO/image-14/scripts/inject-ndk-translation.sh" "$FAKE/image-14/scripts/"
mkdir -p "$OUTPUT/prebuilts/clang/host/linux-x86/clang-r510928/bin"
printf '#!/bin/sh\nexit 0\n' > "$OUTPUT/prebuilts/clang/host/linux-x86/clang-r510928/bin/clang"
chmod +x "$OUTPUT/prebuilts/clang/host/linux-x86/clang-r510928/bin/clang"
cat > "$FAKE/compat_tool/liblepton/ndk_auxv/build.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == --aosp && -d "$2" ]]
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$here/bin"
printf 'test-compiled-shim\n' > "$here/bin/liblepton_ndk_auxv.so"
STUB
cat > "$NORMAL/system/build.prop" <<'PROPS'
ro.build.version.sdk=34
ro.product.cpu.abi=x86_64
ro.dalvik.vm.native.bridge=0
ro.system.product.cpu.abilist=x86_64
ro.system.product.cpu.abilist64=x86_64
ro.system.product.cpu.abilist32=
PROPS
mkdir -p "$NORMAL/vendor"
cat > "$NORMAL/vendor/build.prop" <<'PROPS'
ro.vendor.product.cpu.abilist=x86_64
ro.vendor.product.cpu.abilist64=x86_64
ro.vendor.product.cpu.abilist32=
PROPS
payload="$TMP/translator/payload"
mkdir -p "$payload/system/lib64/arm64" "$payload/system/bin/arm64" "$payload/system/etc"
for name in libndk_translation.so libndk_translation_exec_region.so libndk_translation_proxy_libEGL.so libndk_translation_proxy_libvulkan.so; do
    printf 'test-%s\n' "$name" > "$payload/system/lib64/$name"
done
for name in libc.so libnative_bridge_vdso.so; do printf 'test\n' > "$payload/system/lib64/arm64/$name"; done
for name in linker64 app_process64; do printf 'test\n' > "$payload/system/bin/arm64/$name"; done
printf 'test\n' > "$payload/system/etc/ld.config.arm64.txt"
for number in $(seq 1 50); do printf 'test\n' > "$payload/system/lib64/arm64/test-$number.so"; done
(cd "$payload" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$TMP/translator/SHA256SUMS"
expect_fail --check --with-ndk --ndk-payload "$payload" # New stage required.
expect_fail --check --with-ndk --stage-dir "$OUTPUT/ndk-stage" # Payload required.
expect_fail --check --ndk-payload "$payload" --stage-dir "$OUTPUT/ndk-stage"
run --check --with-ndk --ndk-payload "$payload" --stage-dir "$OUTPUT/ndk-stage" > "$TMP/ndk-check.log"
[[ ! -e "$OUTPUT/ndk-stage" && ! -e "$FAKE/compat_tool/liblepton/ndk_auxv/bin/liblepton_ndk_auxv.so" ]]
run --execute --with-ndk --ndk-payload "$payload" --stage-dir "$OUTPUT/ndk-stage" > "$TMP/ndk-execute.log"
ndk_root="$OUTPUT/ndk-stage/compat_tool/images/rootfs"
grep -qx 'ro.dalvik.vm.native.bridge=libndk_translation.so' "$ndk_root/system/build.prop"
grep -qx 'ro.ndk_translation.flags=accurate-sigsegv' "$ndk_root/system/build.prop"
grep -qx 'ro.dalvik.vm.native.bridge=0' "$NORMAL/system/build.prop"
[[ ! -e "$NORMAL/system/lib64/libndk_translation.so" ]]
[[ -s "$OUTPUT/ndk-stage/compat_tool/liblepton/ndk_auxv/bin/liblepton_ndk_auxv.so" ]]
[[ -s "$OUTPUT/ndk-stage/compat_tool/ndk-provenance/NDK-INJECTION-REPORT.txt" ]]
expect_fail --execute --with-ndk --ndk-payload "$payload" --stage-dir "$OUTPUT/ndk-stage"
echo 'PASS: Default/alternate/opt-in NDK staging, preflight, isolation and overwrite guards'
