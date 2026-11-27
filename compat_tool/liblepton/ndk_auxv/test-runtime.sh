#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=compat_tool/liblepton/ndk_auxv/runtime.sh
source "$HERE/runtime.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
LEPTON_DIR="$work/tool/liblepton"
LEPTON_TEST_ROOTFS="$work/rootfs"
rc="$work/zygote.rc"
mkdir -p "$LEPTON_DIR/ndk_auxv/bin" "$LEPTON_TEST_ROOTFS/system/lib64"
mounts=()
podman_mount_entry() { mounts+=("$*"); }
print() { printf '%s' "$*"; }
println() { printf '%s\n' "$*"; }
get_baked_app_data_dir() { print "$work/baked"; }
app_datadir() { print "$work/baked/app_overlay"; }
data_mount_path() { print "$work/baked/data_overlay"; }
managed=false pending=false
lepton_managed_app() { [[ "$managed" == true ]]; }
lepton_managed_install_pending() { [[ "$pending" == true ]]; }
mkdir -p "$work/baked"
cp "$HERE/arm64_hints.py" "$LEPTON_DIR/ndk_auxv/"
sha256sum() { printf '%s  %s\n' "$test_sha" "$1"; }
test_sha=a2086fbc807f697f9b91222065c9d9000ca9727748699c0d9b751319258cbb3e
unset LEPTON_NDK_COMPAT LEPTON_ENV_LD_PRELOAD LEPTON_ENV_NDK_TRANSLATION_MODE LEPTON_ENV_NDK_TRANSLATION_FLAGS
: > "$LEPTON_DIR/ndk_auxv/bin/liblepton_ndk_auxv.so"
: > "$rc"
configure_ndk_compat "$rc"
[[ ! -s "$rc" && ${#mounts[@]} == 0 ]] # Native runtime stays untouched.
# An incomplete translator installation must remain inactive with a shim present.
printf 'ro.dalvik.vm.native.bridge=0\nro.product.cpu.abilist=x86_64\n' > "$LEPTON_TEST_ROOTFS/system/build.prop"
: > "$LEPTON_TEST_ROOTFS/system/lib64/libndk_translation.so"
cp "$LEPTON_TEST_ROOTFS/system/build.prop" "$work/base.prop"
configure_ndk_compat "$rc"
[[ ! -s "$rc" && ${#mounts[@]} == 0 ]]
cmp "$work/base.prop" "$LEPTON_TEST_ROOTFS/system/build.prop"
rm "$LEPTON_TEST_ROOTFS/system/lib64/libndk_translation.so"
printf 'ro.dalvik.vm.native.bridge=libndk_translation.so\n' > "$LEPTON_TEST_ROOTFS/system/build.prop"
configure_ndk_compat "$rc"
[[ ! -s "$rc" && ${#mounts[@]} == 0 ]]
rm "$LEPTON_DIR/ndk_auxv/bin/liblepton_ndk_auxv.so"
printf 'ro.dalvik.vm.native.bridge=libndk_translation.so\n' > "$LEPTON_TEST_ROOTFS/system/build.prop"
: > "$LEPTON_TEST_ROOTFS/system/lib64/libndk_translation.so"
if configure_ndk_compat "$rc" 2> "$work/missing.log"; then echo 'FAIL: missing shim accepted'; exit 1; fi
grep -q 'Bundled NDK compatibility shim missing' "$work/missing.log"
: > "$LEPTON_DIR/ndk_auxv/bin/liblepton_ndk_auxv.so"
configure_ndk_compat "$rc" > "$work/enabled.log"
[[ ${#mounts[@]} == 1 ]]
grep -qx '    setenv LD_PRELOAD /system/lib64/liblepton_ndk_auxv.so' "$rc"
grep -qx '    setenv NDK_TRANSLATION_MODE light-translate-or-interpret' "$rc"
grep -qx '    setenv NDK_TRANSLATION_FLAGS accurate-sigsegv' "$rc"
: > "$rc"; mounts=()
LEPTON_NDK_COMPAT=false configure_ndk_compat "$rc"
[[ ! -s "$rc" && ${#mounts[@]} == 0 ]]
test_sha=unknown
configure_ndk_compat "$rc"
[[ ! -s "$rc" && ${#mounts[@]} == 0 ]]
if LEPTON_NDK_COMPAT=true configure_ndk_compat "$rc" 2> "$work/version.log"; then echo 'FAIL: unsupported bridge forced'; exit 1; fi
test_sha=a2086fbc807f697f9b91222065c9d9000ca9727748699c0d9b751319258cbb3e
if LEPTON_ENV_LD_PRELOAD=/other.so configure_ndk_compat "$rc" 2> "$work/preload.log"; then echo 'FAIL: conflicting preload accepted'; exit 1; fi
if LEPTON_ENV_NDK_TRANSLATION_MODE=heavy-optimize configure_ndk_compat "$rc" 2> "$work/mode.log"; then echo 'FAIL: incompatible mode accepted'; exit 1; fi
[[ ! -s "$rc" && ${#mounts[@]} == 0 ]]

# Translator mode: default light; the game's recorded choice; explicit setting wins.
mode_line() { grep 'NDK_TRANSLATION_MODE' "$rc" || echo '(tiered: no mode line)'; }
: > "$rc"; configure_ndk_compat "$rc" > /dev/null
[[ "$(mode_line)" == '    setenv NDK_TRANSLATION_MODE light-translate-or-interpret' && "$LEPTON_NDK_MODE_SOURCE" == default ]]
echo tiered > "$work/baked/lepton-ndk-mode"
: > "$rc"; configure_ndk_compat "$rc" > /dev/null
[[ "$(mode_line)" == '(tiered: no mode line)' && "$LEPTON_NDK_MODE_SOURCE" == game && "$LEPTON_NDK_ACTIVE_MODE" == tiered ]]
: > "$rc"; LEPTON_NDK_TRANSLATION_MODE=light-translate-or-interpret configure_ndk_compat "$rc" > /dev/null
[[ "$(mode_line)" == '    setenv NDK_TRANSLATION_MODE light-translate-or-interpret' && "$LEPTON_NDK_MODE_SOURCE" == setting ]]
: > "$rc"; LEPTON_ENV_NDK_TRANSLATION_FLAGS=none configure_ndk_compat "$rc" > /dev/null
! grep -q NDK_TRANSLATION_FLAGS "$rc"
echo bogus > "$work/baked/lepton-ndk-mode"
: > "$rc"; configure_ndk_compat "$rc" > /dev/null
[[ "$LEPTON_NDK_MODE_SOURCE" == default ]]
if LEPTON_NDK_TRANSLATION_MODE=fast configure_ndk_compat "$rc" 2> /dev/null; then echo 'FAIL: invalid mode accepted'; exit 1; fi

# Synthetic ARM64 libraries: an executable segment with the given words, plus a
# non-executable segment holding a SEVL word that must never be patched.
make_lib() {  # make_lib PATH WORD...
    python3 - "$@" <<'PY'
import struct, sys
path, words = sys.argv[1], [int(w, 16) for w in sys.argv[2:]]
code = b"".join(struct.pack("<I", w) for w in words); data = struct.pack("<I", 0xD50320BF)
ehdr = bytearray(64); ehdr[:6] = b"\x7fELF\x02\x01"
struct.pack_into("<HHIQQQIHHHHHH", ehdr, 16, 3, 183, 1, 0, 64, 0, 0, 64, 56, 2, 0, 0, 0)
code_off = 64 + 2 * 56; data_off = code_off + len(code)
ph = struct.pack("<IIQQQQQQ", 1, 5, code_off, 0, 0, len(code), len(code), 4)
ph += struct.pack("<IIQQQQQQ", 1, 6, data_off, 0, 0, 4, 4, 4)
open(path, "wb").write(bytes(ehdr) + ph + code + data)
PY
}
words() { python3 -c 'import struct,sys; d=open(sys.argv[1],"rb").read(); print(" ".join("%08x" % struct.unpack_from("<I", d, o)[0] for o in range(176, len(d), 4)))' "$1"; }
lib="$work/baked/app_overlay/lib/arm64"; mkdir -p "$lib"
make_lib "$lib/libunity.so" d50320bf d503205f d503209f d503201f
cp "$lib/libunity.so" "$work/unity-before.so"
ndk_prepare_installed_app > "$work/prepare.log"
[[ "$(cat "$work/baked/lepton-ndk-mode")" == tiered ]]
[[ "$(words "$lib/libunity.so")" == 'd503201f d503201f d503201f d503201f d50320bf' ]]  # data segment unchanged
grep -q 'translator mode from next launch: tiered' "$work/prepare.log"
make_lib "$lib/libgo.so" d53be041 d50320bf      # MRS X1, CNTVCT_EL0 needs the shim
ndk_prepare_installed_app > /dev/null
[[ "$(cat "$work/baked/lepton-ndk-mode")" == light-translate-or-interpret ]]
python3 "$HERE/arm64_hints.py" scan "$lib" 2> "$work/scan.log" | grep -qx light-translate-or-interpret
grep -q "libgo.so: found hints none; shim-only reads {'CNTVCT_EL0': 1}" "$work/scan.log"
rm -f "$lib"/*.so; ndk_prepare_installed_app > /dev/null # libraries loaded from the APK (AAAAXY):
[[ "$(cat "$work/baked/lepton-ndk-mode")" == light-translate-or-interpret ]]  # cannot be checked, never tiered
rm -r "$lib"; ndk_prepare_installed_app > /dev/null      # x86_64 game: no choice recorded
[[ ! -e "$work/baked/lepton-ndk-mode" ]]
mkdir -p "$lib"; cp "$work/unity-before.so" "$lib/libunity.so"
LEPTON_NDK_COMPAT=false ndk_prepare_installed_app
cmp "$work/unity-before.so" "$lib/libunity.so"            # opted out: untouched

# An already installed game without a recorded choice is prepared at launch,
# before Android starts, and uses the result immediately.
rm -f "$work/baked/lepton-ndk-mode"; rm -f "$lib"/*.so
make_lib "$lib/libunity.so" d50320bf d503205f
: > "$rc"; configure_ndk_compat "$rc" > "$work/late.log"
[[ "$(cat "$work/baked/lepton-ndk-mode")" == tiered && "$LEPTON_NDK_ACTIVE_MODE" == tiered && "$LEPTON_NDK_MODE_SOURCE" == game ]]
[[ "$(words "$lib/libunity.so")" == 'd503201f d503201f d50320bf' ]]
grep -q 'translator mode: tiered' "$work/late.log"

# Early exit in the automatically chosen tiered mode reverts the game to light.
echo tiered > "$work/baked/lepton-ndk-mode"
LEPTON_NDK_MODE_SOURCE=game LEPTON_NDK_ACTIVE_MODE=tiered ndk_note_early_exit > /dev/null
[[ "$(cat "$work/baked/lepton-ndk-mode")" == light-translate-or-interpret ]]
echo tiered > "$work/baked/lepton-ndk-mode"
LEPTON_NDK_MODE_SOURCE=setting LEPTON_NDK_ACTIVE_MODE=tiered ndk_note_early_exit > /dev/null
[[ "$(cat "$work/baked/lepton-ndk-mode")" == tiered ]]   # an explicit setting is respected
# Android Library apps: Android's native code directory is prepared after
# each installation that changed the code, and only then.
managed=true
code=/data/app/~~AbC==/org.example.game-XyZ==
managed_lib="$work/baked/data_overlay/app/~~AbC==/org.example.game-XyZ==/lib/arm64"
mkdir -p "$managed_lib"; rm -f "$work/baked/lepton-ndk-mode" "$work/baked/lepton-ndk-code"
make_lib "$managed_lib/libunity.so" d50320bf d503205f
printf 'PK-apk' > "$work/base.apk"; cp "$work/base.apk" "$work/base-before.apk"
id1=1111111111111111111111111111111111111111111111111111111111111111
ndk_prepare_managed_app "$code" "$id1" > "$work/managed.log"
[[ "$(cat "$work/baked/lepton-ndk-mode")" == tiered && "$(cat "$work/baked/lepton-ndk-code")" == "$id1" ]]
[[ "$(words "$managed_lib/libunity.so")" == 'd503201f d503201f d50320bf' ]]
cmp "$work/base.apk" "$work/base-before.apk"                 # APKs are never touched
# An early exit chose light; the same code keeps that choice...
echo light-translate-or-interpret > "$work/baked/lepton-ndk-mode"
ndk_prepare_managed_app "$code" "$id1" > /dev/null
[[ "$(cat "$work/baked/lepton-ndk-mode")" == light-translate-or-interpret ]]
# ...and an update (new code directory and identity) is evaluated afresh.
code2=/data/app/~~DeF==/org.example.game-UvW==
lib2="$work/baked/data_overlay/app/~~DeF==/org.example.game-UvW==/lib/arm64"; mkdir -p "$lib2"
make_lib "$lib2/libunity.so" d503205f
ndk_prepare_managed_app "$code2" 2222222222222222222222222222222222222222222222222222222222222222 > /dev/null
[[ "$(cat "$work/baked/lepton-ndk-mode")" == tiered && "$(words "$lib2/libunity.so")" == 'd503201f d50320bf' ]]
# An update to a build that loads its libraries from the APK records no choice.
ndk_prepare_managed_app /data/app/~~G==/org.example.game-H== 3333333333333333333333333333333333333333333333333333333333333333 > /dev/null
[[ ! -e "$work/baked/lepton-ndk-mode" ]]
ndk_prepare_managed_app '/data/app/../../etc' "$id1" | grep -q 'unexpected Android code path'
# Without the reviewed translator nothing is recorded, so a later NDK bundle
# still prepares the installed code.
rm -f "$work/baked/lepton-ndk-code"
LEPTON_NDK_COMPAT=false ndk_prepare_managed_app "$code" "$id1"
[[ ! -e "$work/baked/lepton-ndk-code" ]]
# While Android replaces the code during a launch, the old choice is ignored.
echo tiered > "$work/baked/lepton-ndk-mode"
pending=true; : > "$rc"; configure_ndk_compat "$rc" > "$work/pending.log"
[[ "$LEPTON_NDK_ACTIVE_MODE" == light-translate-or-interpret && "$LEPTON_NDK_MODE_SOURCE" == default ]]
pending=false; : > "$rc"; configure_ndk_compat "$rc" > /dev/null
[[ "$LEPTON_NDK_ACTIVE_MODE" == tiered && "$LEPTON_NDK_MODE_SOURCE" == game ]]
managed=false
echo 'PASS: Android Library NDK preparation per installed code, update re-evaluation, pending-update light mode'
echo 'PASS: default matching-bridge activation, native/unknown skip, opt-out, missing binary, conflicting settings; per-game translator mode, ARM64 hint patching (executable code only), shim-only read detection, early-exit fallback'
