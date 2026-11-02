#!/usr/bin/env bash
# Exercise the real deployment packaging entrypoint with a tiny synthetic stage.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
deploy="$repo/image-14/scripts/deploy-compat-x86_64.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
stage="$work/stage"; out="$work/bundles"
mkdir -p "$stage/compat_tool/liblepton" "$stage/compat_tool/tools" \
    "$stage/compat_tool/sysbake/system" "$stage/compat_tool/images/rootfs/system/etc/init/hw" \
    "$stage/compat_tool/images/rootfs/vendor/lib64/hw" \
    "$stage/compat_tool/images/rootfs_overlay/system/bin" "$stage/tools/platform-tools" "$stage/tools/bin"
for file in lepton toolmanifest.vdf liblepton/liblepton.sh liblepton/app_metadata.sh liblepton/mounting.sh liblepton/baking.sh; do
    printf '#!/bin/sh\n' > "$stage/compat_tool/$file"
done
printf 'binderfs-ensure\n' > "$stage/compat_tool/images/rootfs/system/etc/init/hw/init.rc"
printf 'ro.build.version.sdk=34\nro.dalvik.vm.native.bridge=0\n' > "$stage/compat_tool/images/rootfs/system/build.prop"
printf 'test-radv\n' > "$stage/compat_tool/images/rootfs/vendor/lib64/hw/vulkan.radeon.so"
printf '#!/bin/sh\n' > "$stage/compat_tool/images/rootfs_overlay/system/bin/binderfs-ensure"
chmod +x "$stage/compat_tool/images/rootfs_overlay/system/bin/binderfs-ensure"
printf '<packages/>\n' > "$stage/compat_tool/sysbake/system/packages.xml"
printf '# file: sysbake/system/packages.xml\nuser.fake=0x31\nsecurity.selinux=0x32\n' > "$stage/compat_tool/sysbake.xattrs"
mkdir -p "$stage/compat_tool/liblepton/apk_extractor/target" "$stage/compat_tool/images/rootfs/system/target"
printf 'host build cache' > "$stage/compat_tool/liblepton/apk_extractor/target/host-cache"
printf 'required Android asset' > "$stage/compat_tool/images/rootfs/system/target/required"
printf '#!/bin/sh\n' > "$stage/tools/platform-tools/adb"
printf '#!/bin/sh\n' > "$stage/tools/bin/inotifywait"
cp "$stage/compat_tool/sysbake.xattrs" "$work/original-xattrs"
run() { bash "$deploy" "$@"; }
reject() { if run "$@" > "$work/rejected.log" 2>&1; then echo "FAIL: unexpectedly accepted $*"; exit 1; fi; }
export TRACE="$work/remote.log"
mkdir "$work/bin"
for command in ssh rsync; do
    if [[ "$command" == rsync ]]; then
        # Allow local staging, but mock any remote transfer.
        real_rsync="$(command -v rsync)"
        printf '#!/bin/bash\nfor arg in "$@"; do if [[ "$arg" == deck@* ]]; then echo rsync >> "$TRACE"; exit 0; fi; done\nexec %q "$@"\n' "$real_rsync" > "$work/bin/rsync"
    else
        printf '#!/bin/sh\necho ssh >> "$TRACE"\n' > "$work/bin/ssh"
    fi
    chmod +x "$work/bin/$command"
done
export PATH="$work/bin:$PATH"
run --package-only --check --stage-dir "$stage" --bundle-dir "$out" --bundle-id fixture --deck-ip 192.0.2.1 > "$work/check.log"
[[ ! -e "$out" && ! -e "$TRACE" ]]
reject --package-only --check --stage-dir "$stage" --bundle-dir "$stage/recursive" --bundle-id fixture
reject --package-only --check --stage-dir "$stage" --bundle-dir "$out" --bundle-id '../wrong'
reject --package-only --check --stage-dir "$stage" --bundle-dir "$out" --bundle-id fixture --with-ndk
reject --bundle-id fixture
reject --package-only --check --stage-dir "$stage" --bundle-dir "$out" --bundle-id fixture --deck-ip 999.0.0.1
run --package-only --execute --stage-dir "$stage" --bundle-dir "$out" --bundle-id fixture > "$work/package.log"
archive="$out/lepton-x86_64-steamdeck-fixture.tar.gz"
(cd "$out" && sha256sum -c "$(basename "$archive").sha256")
tar -xOf "$archive" ./compat_tool/sysbake.xattrs > "$work/packaged-xattrs"
! grep -q '^security.selinux=' "$work/packaged-xattrs"
grep -qx 'user.fake=0x31' "$work/packaged-xattrs"
cmp "$work/original-xattrs" "$stage/compat_tool/sysbake.xattrs"
tar -tzf "$archive" > "$work/contents"
grep -qx './compat_tool/liblepton/ndk_auxv/runtime.sh' "$work/contents"
grep -qx './compat_tool/images/rootfs/system/target/required' "$work/contents"
! grep -q 'apk_extractor/target/' "$work/contents"
for file in compat_tool/liblepton/properties.sh compat_tool/images/rootfs_overlay/system/bin/cmd tests/runtime/run-apk.sh tests/runtime/unpack-apkm.py tests/runtime/read-gsf-id.py; do
    tar -xOf "$archive" "./$file" > "$work/packaged-source"
    cmp "$repo/$file" "$work/packaged-source"
done
! rg -q 'runtime-profile|podman-storage|apks/' "$work/contents"
tar -xOf "$archive" ./BUNDLE.json > "$work/BUNDLE.json"
python3 - "$work/BUNDLE.json" <<'PYMETA'
import json, sys
assert json.load(open(sys.argv[1]))['tool_id'] == 'lepton_x86_64_dev'
PYMETA
mkdir -p "$stage/compat_tool/images/rootfs/system/product/priv-app/PrebuiltGmsCore"
printf 'synthetic' > "$stage/compat_tool/images/rootfs/system/product/priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk"
mkdir -p "$stage/compat_tool/images/rootfs/system/framework"
python3 - "$stage/compat_tool/images/rootfs/system/framework/services.jar" <<'PYJAR'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as jar:
    jar.writestr('classes.dex', b'StartLocaleManagerService StartCrossProfileAppsService persist.lepton.forward_web_intents')
PYJAR
run --package-only --execute --stage-dir "$stage" --bundle-dir "$out" --bundle-id gapps-fixture > "$work/gapps-package.log"
tar -xOf "$out/lepton-x86_64-steamdeck-gapps-fixture.tar.gz" ./BUNDLE.json > "$work/gapps.json"
python3 - "$work/gapps.json" <<'PYMETA'
import json, sys
metadata = json.load(open(sys.argv[1]))
assert metadata['tool_id'] == 'lepton_gapps_gapps_fixture'
assert metadata['install_directory'] == metadata['tool_id']
PYMETA
reject --package-only --check --stage-dir "$stage" --bundle-dir "$out" --bundle-id invalid-tool --tool-id ../bad
[[ ! -e "$TRACE" ]]
reject --package-only --execute --stage-dir "$stage" --bundle-dir "$out" --bundle-id fixture
run --transfer-only --check --bundle-dir "$out" --bundle-id fixture --deck-ip 192.0.2.1 > "$work/transfer-check.log"
[[ ! -e "$TRACE" ]]
run --transfer-only --execute --bundle-dir "$out" --bundle-id fixture --deck-ip 192.0.2.1 > "$work/transfer.log"
[[ $(wc -l < "$TRACE") == 3 ]]
printf 'broken' >> "$archive"
reject --transfer-only --check --bundle-dir "$out" --bundle-id fixture --deck-ip 192.0.2.1
echo 'PASS: read-only packaging/transfer checks, real archive, xattr preservation, overwrite guards and mocked transfer'
