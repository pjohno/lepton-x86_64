#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
reject() {
    if bash "$HERE/validate.sh" "$1" > "$work/error" 2>&1; then
        echo "FAIL: accepted invalid shim $1" >&2; exit 1
    fi
}
reject "$work/missing.so"
printf invalid > "$work/text.so"
reject "$work/text.so"
printf 'void fixture(void) {}\n' > "$work/shim.c"
"${CC:-cc}" -shared -nostdlib -fPIC -Wl,-soname,liblepton_ndk_auxv.so -o "$work/good.so" "$work/shim.c"
bash "$HERE/validate.sh" "$work/good.so"
"${CC:-cc}" -shared -nostdlib -fPIC -o "$work/no-soname.so" "$work/shim.c"
reject "$work/no-soname.so"
# Reject wrong machine/type even when the rest of the shared object is valid.
python3 - "$work" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
data = bytearray((root / 'good.so').read_bytes())
data[18:20] = (183).to_bytes(2, 'little')
(root / 'arm64.so').write_bytes(data)
data[18:20] = (62).to_bytes(2, 'little')
data[16:18] = (2).to_bytes(2, 'little')
(root / 'executable.so').write_bytes(data)
(root / 'truncated.so').write_bytes(data[:32])
PY
reject "$work/arm64.so"
reject "$work/executable.so"
reject "$work/truncated.so"
printf '#include <stdio.h>\nvoid fixture(void) { puts("host libc"); }\n' > "$work/host.c"
"${CC:-cc}" -shared -fPIC -Wl,-soname,liblepton_ndk_auxv.so -o "$work/host.so" "$work/host.c"
reject "$work/host.so"
echo 'PASS: shim ELF validation rejects missing, malformed, wrong architecture/type/SONAME and host libc binaries'
