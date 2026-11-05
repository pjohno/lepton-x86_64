#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

[[ $# -eq 1 ]] || {
    echo "Usage: $0 /path/to/extracted/rootfs" >&2
    exit 2
}

init_rc="$1/system/etc/init/hw/init.rc"
[[ -f "$init_rc" ]] || {
    echo "Missing Android init.rc: $init_rc" >&2
    exit 1
}

python3 - "$init_rc" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

mount = "    mount binder binder /dev/binderfs stats=global\n"
hook = "    exec - root root -- /system/bin/binderfs-ensure\n"

if text.count(mount) != 1:
    raise SystemExit("Unexpected BinderFS mount layout; refusing to patch")

if text.count(hook) == 1:
    if mount + hook not in text:
        raise SystemExit("BinderFS helper exists at an unexpected location")
    print("BinderFS init hook already present")
elif hook in text:
    raise SystemExit("Duplicate or malformed BinderFS helper hook")
else:
    path.write_text(text.replace(mount, mount + hook, 1))
    print("Added BinderFS init hook:", path)
PY
