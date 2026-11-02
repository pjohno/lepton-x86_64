#!/usr/bin/env bash
# Local, opt-in Google-services experiment. Play Store requires an explicit flag.
# Source stages are unchanged; Google binaries remain in external build output.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SOURCE=''
STAGE=''
IMAGES=''
MODE=--check
WITH_STORE=false
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
while (($#)); do
    case "$1" in
        --source-stage) SOURCE="${2:?}"; shift 2 ;;
        --stage-dir) STAGE="${2:?}"; shift 2 ;;
        --google-images) IMAGES="${2:?}"; shift 2 ;;
        --check|--execute) MODE="$1"; shift ;;
        --with-play-store) WITH_STORE=true; shift ;;
        -h|--help)
            echo 'Usage: bash tests/runtime/stage-google-services.sh --source-stage DIR --stage-dir NEW_DIR --google-images LOGICAL_PARTITIONS_DIR [--with-play-store] [--check|--execute]'
            exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done
[[ -n "$SOURCE" && -n "$STAGE" && -n "$IMAGES" ]] || fail 'Supply source stage, new stage and Google logical images'
SOURCE="$(realpath -e -- "$SOURCE")"
STAGE="$(realpath -m -- "$STAGE")"
IMAGES="$(realpath -e -- "$IMAGES")"
[[ ! -e "$STAGE" && ! -L "$STAGE" && "$STAGE" != "$SOURCE/"* ]] || fail 'Stage must be new and outside the source stage'
[[ "$IMAGES" != "$STAGE/"* ]] || fail 'Google source images cannot be inside destination'
[[ -d "$SOURCE/tools" ]] || fail 'Source stage host tools missing'
for tool in debugfs python3 sha256sum; do command -v "$tool" >/dev/null || fail "Missing $tool"; done
for part in system product system_ext; do [[ -f "$IMAGES/$part.img" ]] || fail "Missing $part.img"; done
debugfs -R 'cat /system/build.prop' "$IMAGES/system.img" 2>/dev/null |
    grep -x 'ro.build.version.sdk=34' >/dev/null || fail 'Google image must be Android API 34'
bash "$ROOT/image-14/scripts/deploy-compat-x86_64.sh" "$MODE" \
    --stage-dir "$STAGE" --rootfs-source "$SOURCE/compat_tool/images/rootfs"
if [[ "$MODE" == --check ]]; then
    echo '[PASS] Services-only staging preflight; no Google files extracted or installed'
    exit 0
fi
ROOTFS="$STAGE/compat_tool/images/rootfs"
LOG="$STAGE/google-extraction.log"
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
for relative in ['PrebuiltGmsCore/PrebuiltGmsCore.apk', 'Phonesky/Phonesky.apk']:
    apk = root / 'system/product/priv-app' / relative
    if not apk.exists():
        continue
    with zipfile.ZipFile(apk) as bundle:
        libs = [entry for entry in bundle.infolist()
                if re.fullmatch(r'lib/x86_64/[A-Za-z0-9_.-]+\.so', entry.filename)]
        if not libs and relative.startswith('PrebuiltGmsCore/'):
            raise SystemExit('Google services APK has no x86_64 native libraries')
        if libs:
            dest = apk.parent / 'lib/x86_64'
            dest.mkdir(parents=True)
            for entry in libs:
                with bundle.open(entry) as source, (dest / Path(entry.filename).name).open('xb') as target:
                    shutil.copyfileobj(source, target)
                (dest / Path(entry.filename).name).chmod(0o644)
PY
cp -a --no-preserve=ownership -- "$SOURCE/tools" "$STAGE/tools"
(
    cd "$ROOTFS"
    find system/product/priv-app/PrebuiltGmsCore system/system_ext/priv-app/GoogleServicesFramework \
        -type f -print0 | sort -z | xargs -0 sha256sum
    find system -type f -name 'lepton-google*.xml' -print0 | sort -z | xargs -0 sha256sum
) > "$STAGE/google-services.sha256"
if [[ "$WITH_STORE" == true ]]; then
    (cd "$ROOTFS" && find system/product/priv-app/Phonesky -type f -print0 | sort -z | xargs -0 sha256sum) >> "$STAGE/google-services.sha256"
fi
printf 'Google images: %s\nSource stage: %s\nPlay Store included: %s\n' \
    "$IMAGES" "$SOURCE" "$WITH_STORE" > "$STAGE/google-services-source.txt"
echo "[PASS] Google-services experiment staged at $STAGE; generate fresh sysbake"
