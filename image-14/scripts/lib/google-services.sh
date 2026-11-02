#!/usr/bin/env bash
# Shared offline extraction for the production deployer and experimental tests.
google_services_check() (
    set -Eeuo pipefail
    local images="$1" store="$2" browser="$3"
    for tool in debugfs python3 sha256sum; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }; done
    for part in system product system_ext; do [[ -f "$images/$part.img" ]] || { echo "Missing $part.img" >&2; exit 1; }; done
    debugfs -R 'cat /system/build.prop' "$images/system.img" 2>/dev/null |
        grep -x 'ro.build.version.sdk=34' >/dev/null || { echo 'Google image must be Android API 34' >&2; exit 1; }
    local part remote
    while read -r part remote; do
        debugfs -R "stat $remote" "$images/$part.img" 2>/dev/null |
            grep -q 'Type: regular' || { echo "Missing Google component: $part:$remote" >&2; exit 1; }
    done < <(google_services_files "$store" "$browser")
)
google_services_files() {
    cat <<'FILES'
product /priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk
system_ext /priv-app/GoogleServicesFramework/GoogleServicesFramework.apk
system /system/etc/permissions/privapp-permissions-google.xml
product /etc/permissions/privapp-permissions-google-p.xml
system_ext /etc/permissions/privapp-permissions-google-se.xml
product /etc/sysconfig/google.xml
product /etc/sysconfig/google-hiddenapi-package-whitelist.xml
product /etc/default-permissions/default-permissions-sdk-google.xml
FILES
    if [[ "$1" == true ]]; then echo 'product /priv-app/Phonesky/Phonesky.apk'; fi
    if [[ "$2" == true ]]; then
        echo 'product /app/Chrome/Chrome.apk.gz'
        echo 'product /app/TrichromeLibrary/TrichromeLibrary.apk.gz'
    fi
}
google_services_framework_check() {
    python3 - "$1" <<'PYFRAMEWORK'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as jar:
    dex = b"".join(jar.read(name) for name in jar.namelist() if name.endswith('.dex'))
for marker in (b'StartLocaleManagerService', b'StartCrossProfileAppsService', b'persist.lepton.forward_web_intents'):
    if marker not in dex:
        raise SystemExit('Framework lacks required GApps/VIEW fix: ' + marker.decode() + '; rebuild Android or supply --services-jar')
PYFRAMEWORK
}
google_services_inject() (
set -Eeuo pipefail
local ROOTFS="$1" IMAGES="$2" WITH_STORE="$3" WITH_BROWSER="$4" provenance="$5"
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
mkdir -p "$provenance"
local LOG="$provenance/extraction.log"
dump_file() {
    local partition="$1" remote="$2" relative="$3" dest="$ROOTFS/$3"
    [[ ! -e "$dest" && ! -L "$dest" ]] || fail "Refusing to overwrite $relative"
    mkdir -p "$(dirname "$dest")"
    debugfs -R "dump $remote $dest" "$IMAGES/$partition.img" >> "$LOG" 2>&1
    [[ -s "$dest" ]] || fail "Cannot extract $partition:$remote; inspect $LOG"
    chmod 0644 "$dest"
}
dump_file product /priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk system/product/priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk
dump_file system_ext /priv-app/GoogleServicesFramework/GoogleServicesFramework.apk system/system_ext/priv-app/GoogleServicesFramework/GoogleServicesFramework.apk
if [[ "$WITH_STORE" == true ]]; then
    dump_file product /priv-app/Phonesky/Phonesky.apk system/product/priv-app/Phonesky/Phonesky.apk
fi
if [[ "$WITH_BROWSER" == true ]]; then
    for name in Chrome TrichromeLibrary; do
        dump_file product "/app/$name/$name.apk.gz" "system/product/app/$name/$name.apk.gz"
    done
    python3 - "$ROOTFS" <<'PYBROWSER'
import gzip
from pathlib import Path
import shutil
import sys
for name in ('Chrome', 'TrichromeLibrary'):
    packed = Path(sys.argv[1]) / f'system/product/app/{name}/{name}.apk.gz'
    with gzip.open(packed, 'rb') as source, packed.with_suffix('').open('xb') as target:
        shutil.copyfileobj(source, target)
    packed.with_suffix('').chmod(0o644)
    packed.unlink()
PYBROWSER
fi
# Preserve partition placement for privileged permission enforcement. Keep these
# files under distinct names so no Lepton permission configuration is replaced.
dump_file system /system/etc/permissions/privapp-permissions-google.xml system/etc/permissions/lepton-google.xml
dump_file product /etc/permissions/privapp-permissions-google-p.xml system/product/etc/permissions/lepton-google.xml
dump_file system_ext /etc/permissions/privapp-permissions-google-se.xml system/system_ext/etc/permissions/lepton-google.xml
dump_file product /etc/sysconfig/google.xml system/product/etc/sysconfig/lepton-google.xml
dump_file product /etc/sysconfig/google-hiddenapi-package-whitelist.xml system/product/etc/sysconfig/lepton-google-hiddenapi.xml
dump_file product /etc/default-permissions/default-permissions-sdk-google.xml system/product/etc/default-permissions/lepton-google.xml
python3 - "$ROOTFS" <<'PY'
from pathlib import Path
import re
import shutil
import sys
import zipfile
root = Path(sys.argv[1])
for relative in ['priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk', 'priv-app/Phonesky/Phonesky.apk',
                 'app/Chrome/Chrome.apk', 'app/TrichromeLibrary/TrichromeLibrary.apk']:
    apk = root / 'system/product' / relative
    if not apk.exists():
        continue
    with zipfile.ZipFile(apk) as bundle:
        libs = [entry for entry in bundle.infolist()
                if re.fullmatch(r'lib/x86_64/[A-Za-z0-9_.-]+\.so', entry.filename)]
        if not libs and relative.startswith('priv-app/PrebuiltGmsCore/'):
            raise SystemExit('Google services APK has no x86_64 native libraries')
        if libs:
            dest = apk.parent / 'lib/x86_64'
            dest.mkdir(parents=True)
            for entry in libs:
                with bundle.open(entry) as source, (dest / Path(entry.filename).name).open('xb') as target:
                    shutil.copyfileobj(source, target)
                (dest / Path(entry.filename).name).chmod(0o644)
PY
(
    cd "$ROOTFS"
    find system/product/priv-app/PrebuiltGmsCore system/system_ext/priv-app/GoogleServicesFramework \
        -type f -print0 | sort -z | xargs -0 sha256sum
    find system -type f -name 'lepton-google*.xml' -print0 | sort -z | xargs -0 sha256sum
) > "$provenance/SHA256SUMS"
if [[ "$WITH_STORE" == true ]]; then
    (cd "$ROOTFS" && find system/product/priv-app/Phonesky -type f -print0 | sort -z | xargs -0 sha256sum) >> "$provenance/SHA256SUMS"
fi
if [[ "$WITH_BROWSER" == true ]]; then
    (cd "$ROOTFS" && find system/product/app/Chrome system/product/app/TrichromeLibrary -type f -print0 | sort -z | xargs -0 sha256sum) >> "$provenance/SHA256SUMS"
fi

(cd "$IMAGES" && sha256sum system.img product.img system_ext.img) > "$provenance/SOURCE-IMAGES.sha256"
printf 'Android API: 34\nPlay Store included: %s\nBrowser included: %s\n' "$WITH_STORE" "$WITH_BROWSER" > "$provenance/COMPONENTS.txt"
)
