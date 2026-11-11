#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build only our compatibility shim, using the existing AOSP compiler.
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ $# != 2 || "$1" != --aosp ]]; then
    echo "Usage: bash $0 --aosp /path/to/prepared/android14" >&2
    exit 2
fi
AOSP="$(realpath -e -- "$2")"
CLANG="$AOSP/prebuilts/clang/host/linux-x86/clang-r510928/bin/clang"
[[ -x "$CLANG" ]] || { echo "AOSP Clang missing: $CLANG" >&2; exit 1; }
mkdir -p "$HERE/bin"
output="$(mktemp "$HERE/bin/.ndk-compat.XXXXXXXX.so")"
trap 'rm -f -- "$output"' EXIT
"$CLANG" --target=x86_64-linux-android34 -O2 -fPIC -shared -nostdlib \
    -fvisibility=hidden -Wall -Wextra -Werror -Wl,-soname,liblepton_ndk_auxv.so \
    -o "$output" "$HERE/ndk_auxv.c"
bash "$HERE/validate.sh" "$output"
chmod 755 "$output"
mv -f -- "$output" "$HERE/bin/liblepton_ndk_auxv.so"
echo "Built $HERE/bin/liblepton_ndk_auxv.so"
