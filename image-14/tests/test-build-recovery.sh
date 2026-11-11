#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# build-images-x86_64.sh after a power cut: an unfinished build is detected and
# the files it left damaged are deleted before resuming; failures caused by
# damaged files point to --repair. Fake checkout and fake podman: no Android
# build, container or network.
set -Eeuo pipefail
not() { if "$@"; then echo "FAIL: unexpectedly succeeded: $*" >&2; exit 1; fi; }
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
work="$(mktemp -d)"
cleanup() { [[ -z "${build_pid:-}" ]] || kill -9 "$build_pid" 2>/dev/null || true; rm -rf -- "$work"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; [[ ! -f "$work/out.log" ]] || cat "$work/out.log" >&2; exit 1; }

fake="$work/repo"
mkdir -p "$fake/image-14/scripts/lib" "$fake/image-14/scripts/internal"
cp "$repo/image-14/scripts/build-images-x86_64.sh" "$fake/image-14/scripts/"
cp "$repo/image-14/scripts/lib/"{workspace.sh,packaging-fuse.sh,package-images.sh} "$fake/image-14/scripts/lib/"
cp "$repo/image-14/scripts/internal/"{check-build-outputs.py,check-active-compilation.py} "$fake/image-14/scripts/internal/"
ws="$work/ws"; aosp="$ws/aosp"; state="$aosp/.lepton-clean14-state"; out="$aosp/out"
cat > "$fake/.build-env" <<ENV
LEPTON_OUTPUT_DIR=$ws
LEPTON_BUILD_TARGET=aosp_lepton_x86_64-ap2a-userdebug
LEPTON_BUILD_JOBS=1
LEPTON_MIN_FREE_GIB=0
LEPTON_BUILD_CONTAINER=lepton-builder-ubuntu26:latest
ENV
mkdir -p "$state" "$aosp/build" "$aosp/device/waydroid/waydroid" "$aosp/vendor/extra"
touch "$aosp/.lepton-clean14-owner" "$aosp/build/envsetup.sh" "$state/"{sync,vendor,patches}.done

# Fake podman: "run" plays the compiler according to FAKE_BUILD.
mkdir -p "$work/bin"
cat > "$work/bin/podman" <<'SH'
#!/bin/bash
case "$1" in
  image) exit 0 ;;
  stop|kill) exit 0 ;;
  run)
    cid=''; while (($#)); do [[ "$1" == --cidfile ]] && cid="$2"; shift; done
    echo fake-container > "$cid"
    cat > /dev/null
    [[ -f "$STATE_DIR/build.running" ]] && echo 'marker present during build' >> "$TRACE"
    case "$FAKE_BUILD" in
      damaged) echo "ld.lld: error: libbluetooth_gd.a: archive member 'inquiry.o' is neither ET_REL nor LLVM bitcode"; exit 1 ;;
      broken) echo 'error: undefined symbol: foo'; exit 1 ;;
      hang) exec sleep 60 ;;
    esac ;;
esac
SH
chmod +x "$work/bin/podman"
build() {
    env PATH="$work/bin:$PATH" STATE_DIR="$state" TRACE="$work/trace" FAKE_BUILD="${FAKE_BUILD:-broken}" \
        bash "$fake/image-14/scripts/build-images-x86_64.sh" "$@" > "$work/out.log" 2>&1
}

# Build output: valid files, files damaged by a power cut, and look-alikes.
obj="$out/soong/.intermediates/packages/modules/Bluetooth/system/gd/libbluetooth_gd"
mkdir -p "$obj" "$out/target/product/lepton_x86_64/obj/lib" "$out/host/glslang14" "$out/soong/ndk"
elf() { printf '\177ELF\002\001\001' > "$1"; }
elf "$obj/good.o"; printf 'BC\300\336rest' > "$obj/lto.o"; printf '!<arch>\nx' > "$obj/libgood.a"
printf 'PK\003\004rest' > "$obj/good.jar"
printf '/* GNU ld script */\nGROUP ( libc.so.6 )\n' > "$out/target/product/lepton_x86_64/obj/lib/libc.so"
: > "$obj/inquiry.o"                                   # empty: lost before reaching the disk
head -c 4096 /dev/zero > "$obj/name_db.o"              # zero-filled
head -c 512 /dev/zero > "$obj/libbluetooth_gd.a"
head -c 512 /dev/zero > "$out/target/product/lepton_x86_64/obj/lib/libbroken.so"
head -c 64 /dev/zero > "$obj/broken.jar"
head -c 64 /dev/zero > "$obj/old-damage.o"; touch -d '3 hours ago' "$obj/old-damage.o"
head -c 64 /dev/zero > "$out/host/glslang14/not-a-ninja-output.o"   # bootstrap output: never touched
head -c 64 /dev/zero > "$out/soong/ndk/outside-scan.o"               # outside the scanned folders

# The checker alone: reports without --delete, honours --since-file.
python3 -B "$fake/image-14/scripts/internal/check-build-outputs.py" "$out" > "$work/scan.log"
grep -q 'Damaged build files: 6 found' "$work/scan.log" || { cat "$work/scan.log"; fail 'scan count'; }
[[ -f "$obj/inquiry.o" ]]
if python3 -B "$fake/image-14/scripts/internal/check-build-outputs.py" "$aosp" > /dev/null 2>&1; then fail 'accepted a non-out folder'; fi

# A reset interrupted with old successful stage markers must never build.
touch "$state/reset.started"
if build --check; then fail 'accepted an interrupted source reset'; fi
grep -q 'Interrupted source reset' "$work/out.log"
rm "$state/reset.started"

# A build cut off an hour ago (marker left behind) wrote the damaged files.
echo 'Started earlier' > "$state/build.running"; touch -d '1 hour ago' "$state/build.running"
build --check || fail 'check failed'
grep -q 'The previous image build did not finish' "$work/out.log"
grep -q -- '--execute will first find and rebuild' "$work/out.log"
[[ -f "$obj/inquiry.o" ]] || fail '--check deleted files'

FAKE_BUILD=broken build --execute && fail 'fake build should fail'
grep -q 'Checking files written by the unfinished build for damage' "$work/out.log"
grep -q 'Damaged build files: 5 deleted' "$work/out.log"
for gone in inquiry.o name_db.o libbluetooth_gd.a broken.jar; do [[ ! -e "$obj/$gone" ]] || fail "$gone kept"; done
[[ ! -e "$out/target/product/lepton_x86_64/obj/lib/libbroken.so" ]]
for kept in good.o lto.o libgood.a good.jar old-damage.o; do [[ -e "$obj/$kept" ]] || fail "$kept deleted"; done
[[ -f "$out/target/product/lepton_x86_64/obj/lib/libc.so" && -f "$out/host/glslang14/not-a-ninja-output.o" ]]
grep -q 'marker present during build' "$work/trace"
[[ ! -e "$state/build.running" ]] || fail 'marker kept after the build ended by itself'
report="$(compgen -G "$ws/logs/images-*-damaged-files.txt")"
[[ $(wc -l < "$report") == 5 ]] && grep -q '/inquiry.o$' "$report"
not grep -q '\[HINT\]' "$work/out.log" || fail 'hint for an unrelated failure'

# A failure that looks like damaged files suggests --repair.
FAKE_BUILD=damaged build --execute && fail 'fake build should fail'
grep -q 'HINT.*build-images-x86_64.sh --repair' "$work/out.log"
not grep -q 'Checking files written by the unfinished build' "$work/out.log"  # no marker this time

# --repair checks the whole output, including damage older than any marker.
build --repair || fail 'repair failed'
grep -q 'Damaged build files: 1 deleted' "$work/out.log"
[[ ! -e "$obj/old-damage.o" && -e "$obj/good.o" && -f "$out/host/glslang14/not-a-ninja-output.o" && -f "$out/soong/ndk/outside-scan.o" ]]
grep -q 'Repair finished' "$work/out.log"
compgen -G "$ws/logs/damaged-build-files-*.txt" > /dev/null

# A build stopped with SIGTERM (or Ctrl-C) keeps the marker: next time is checked.
env PATH="$work/bin:$PATH" STATE_DIR="$state" TRACE="$work/trace" FAKE_BUILD=hang \
    bash "$fake/image-14/scripts/build-images-x86_64.sh" --execute > "$work/out.log" 2>&1 &
build_pid=$!
for _ in $(seq 100); do [[ -f "$state/build.running" ]] && break; sleep 0.1; done
[[ -f "$state/build.running" ]] || fail 'marker not written'
sleep 0.5
kill -TERM "$build_pid"
wait "$build_pid" && fail 'interrupted build reported success' || true
build_pid=''
grep -q 'INTERRUPTED' "$work/out.log"
[[ -f "$state/build.running" ]] || fail 'marker removed after an interrupted build'
echo 'PASS: build recovery: unfinished build detected, its damaged files deleted (only those), failure hint, --repair, marker lifecycle'
