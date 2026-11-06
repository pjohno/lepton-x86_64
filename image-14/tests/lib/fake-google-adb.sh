# shellcheck shell=bash
# SPDX-License-Identifier: MIT
# Test doubles for the Deck installer's Google ADB download (no network).
# Source this file; it defines functions only.

# fake_adb_zip DIR [VERSION]: write DIR/platform-tools.zip holding a fake adb
# (reporting VERSION, default the pinned one) and NOTICE.txt. Prints the
# fake adb's SHA256.
fake_adb_zip() {
    local dir="$1" version="${2:-37.0.1-15733141}"
    mkdir -p "$dir/src/platform-tools"
    cat > "$dir/src/platform-tools/adb" <<ADB
#!/bin/sh
[ "\$1" = version ] || exit 1
echo 'Android Debug Bridge version 1.0.41'
echo 'Version $version'
echo "Installed as \$0"
ADB
    chmod 755 "$dir/src/platform-tools/adb"
    printf 'Fixture NOTICE for the fake platform-tools\n' > "$dir/src/platform-tools/NOTICE.txt"
    printf 'not extracted\n' > "$dir/src/platform-tools/fastboot"
    python3 -I - "$dir/src" "$dir/platform-tools.zip" <<'PYZIP'
import os, sys, zipfile
src, out = sys.argv[1:]
with zipfile.ZipFile(out, 'w') as z:
    for name in ('adb', 'NOTICE.txt', 'fastboot'):
        z.write(os.path.join(src, 'platform-tools', name), 'platform-tools/' + name)
PYZIP
    sha256sum "$dir/src/platform-tools/adb" | awk '{print $1}'
}

# pin_installer SOURCE DEST SHA256: copy an installer, pinned to a fixture adb
# hash. URL and version are left as shipped, so the test exercises them.
pin_installer() {
    local source="$1" dest="$2" sha="$3"
    sed "s|^ADB_SHA256='[0-9a-f]*'\$|ADB_SHA256='$sha'|" "$source" > "$dest"
    chmod 755 "$dest"
    grep -qx "ADB_SHA256='$sha'" "$dest"
}

# install_fake_curl BINDIR: a curl that "downloads" $FAKE_ADB_ZIP, logs its
# arguments to $FAKE_CURL_LOG, and fails like a network error when
# FAKE_CURL_FAIL is set.
install_fake_curl() {
    cat > "$1/curl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${FAKE_CURL_LOG:-/dev/null}"
out=''
while (($#)); do
    case "$1" in --output|-o) out="$2"; shift 2 ;; *) shift ;; esac
done
if [[ -n "${FAKE_CURL_FAIL:-}" ]]; then
    echo 'curl: (6) Could not resolve host: dl.google.com' >&2
    exit 6
fi
[[ -n "$out" ]] || exit 2
cp -- "$FAKE_ADB_ZIP" "$out"
SH
    chmod 755 "$1/curl"
}
