#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build only our compatibility shim, using the existing AOSP compiler.
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
usage() {
    echo "Usage: bash $0 --aosp /path/to/prepared/android14 [--output FILE]" >&2
    echo "Default output: $HERE/bin/liblepton_ndk_auxv.so (developer runtime from a checkout)" >&2
    exit 2
}
AOSP='' TARGET="$HERE/bin/liblepton_ndk_auxv.so"
while (($#)); do
    case "$1" in
        --aosp) [[ $# -ge 2 ]] || usage; AOSP="$2"; shift 2 ;;
        --output) [[ $# -ge 2 ]] || usage; TARGET="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[[ -n "$AOSP" ]] || usage
AOSP="$(realpath -e -- "$AOSP")"
CLANG="$AOSP/prebuilts/clang/host/linux-x86/clang-r510928/bin/clang"
[[ -x "$CLANG" ]] || { echo "AOSP Clang missing: $CLANG" >&2; exit 1; }
mkdir -p -- "$(dirname -- "$TARGET")"
# Compile beside the target, then rename: the target is complete or absent.
output="$(mktemp "$(dirname -- "$TARGET")/.ndk-compat.XXXXXXXX.so")"
trap 'rm -f -- "$output"' EXIT
"$CLANG" --target=x86_64-linux-android34 -O2 -fPIC -shared -nostdlib \
    -fvisibility=hidden -Wall -Wextra -Werror -Wl,-soname,liblepton_ndk_auxv.so \
    -o "$output" "$HERE/ndk_auxv.c"
bash "$HERE/validate.sh" "$output"
chmod 755 "$output"
mv -f -- "$output" "$TARGET"
echo "Built $TARGET"
