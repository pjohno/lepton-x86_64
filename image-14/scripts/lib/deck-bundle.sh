#!/usr/bin/env bash
# Internal deploy-compat-x86_64.sh packaging/transfer implementation.
# Runs in a subshell so temporary-workspace traps cannot affect the caller.
package_deck_bundle() (
set -Eeuo pipefail
local repo="$1" stage="$2" outdir="$3" bundle_id="$4" deck_ip="$5" transfer_only="$6" mode="$7"
local tool_id="${8:-}" tool_name="${9:-}" install_name
[[ "$bundle_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && ${#bundle_id} -le 64 ]] || {
    echo 'ERROR: bundle ID must contain 1-64 letters, digits, dots, dashes or underscores' >&2
    exit 2
}
if [[ -n "$deck_ip" ]]; then
    [[ "$deck_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || {
        echo 'ERROR: --deck-ip must be an IPv4 address, e.g. 192.168.1.50' >&2
        exit 2
    }
    IFS=. read -r oct1 oct2 oct3 oct4 <<< "$deck_ip"
    for octet in "$oct1" "$oct2" "$oct3" "$oct4"; do
        (( 10#$octet <= 255 )) || { echo 'ERROR: invalid IPv4 octet' >&2; exit 2; }
    done
fi


outdir="$(realpath -m -- "$outdir")"
[[ "$outdir" != / && "$outdir" != "$repo" ]] || { echo "ERROR: unsafe bundle output directory" >&2; exit 1; }
archive="$outdir/lepton-x86_64-steamdeck-${bundle_id}.tar.gz"
checksum="$archive.sha256"

transfer_bundle() {
    [[ -n "$deck_ip" ]] || { echo 'ERROR: specify --deck-ip for transfer' >&2; exit 2; }
    for program in ssh rsync sha256sum; do
        command -v "$program" >/dev/null || { echo "ERROR: missing $program" >&2; exit 1; }
    done
    [[ -f "$archive" && -f "$checksum" ]] || {
        echo "ERROR: bundle or checksum does not exist at $archive" >&2
        exit 1
    }
    printf 'Verifying local archive checksum...\n'
    ( cd "$outdir" && sha256sum --check "$(basename -- "$checksum")" )
    remote="deck@$deck_ip"
    printf 'Transferring archive and checksum to %s:~/Downloads/lepton-deck-bundles/ ...\n' "$remote"
    ssh "$remote" 'mkdir -p "$HOME/Downloads/lepton-deck-bundles"'
    rsync -rtv --partial --progress -- "$archive" "$checksum" \
        "$remote:Downloads/lepton-deck-bundles/"
    printf 'Verifying checksum on Steam Deck...\n'
    ssh "$remote" "cd \"\$HOME/Downloads/lepton-deck-bundles\" && sha256sum --check '$(basename -- "$checksum")'"
    printf 'PASS: transferred and verified on Steam Deck at %s\n' "$remote"
    printf 'NOTE: existing Steam Deck Lepton installation was not changed.\n'
}

if [[ "$transfer_only" == true ]]; then
    [[ -n "$deck_ip" && -f "$archive" && -f "$checksum" ]] || { echo 'ERROR: transfer requires --deck-ip and an existing archive/checksum' >&2; exit 1; }
    if [[ "$mode" == --check ]]; then
        ( cd "$outdir" && sha256sum --check "$(basename -- "$checksum")" )
        echo 'PASS: transfer preflight; no files or remote state changed'
        exit 0
    fi
    transfer_bundle
    exit 0
fi

[[ -n "$stage" ]] || {
    echo 'ERROR: set LEPTON_DECK_STAGE_DIR in .build-env or supply STAGE_DIR' >&2
    exit 2
}
stage="$(realpath -e -- "$stage")"
[[ "$outdir" != "$stage" && "$outdir" != "$stage/"* ]] || { echo 'ERROR: bundle output must be outside the source stage' >&2; exit 1; }
if [[ -z "$tool_id" ]]; then
    if [[ -f "$stage/compat_tool/images/rootfs/system/product/priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk" ]]; then
        tool_id="lepton_gapps_${bundle_id//[.-]/_}"
    else
        tool_id=lepton_x86_64_dev
    fi
fi
[[ "$tool_id" =~ ^[A-Za-z0-9_]{1,96}$ ]] || { echo 'ERROR: invalid tool ID' >&2; exit 2; }
[[ -n "$tool_name" ]] || tool_name="Lepton x86_64 ($bundle_id)"
[[ "$tool_name" != *$'\n'* && "$tool_name" != *$'\r'* ]] || { echo 'ERROR: invalid tool name' >&2; exit 2; }
install_name="$tool_id"
[[ "$tool_id" != lepton_x86_64_dev ]] || install_name=lepton-x86_64-dev
if [[ -f "$stage/compat_tool/images/rootfs/system/product/priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk" ]]; then
    source "$repo/image-14/scripts/lib/google-services.sh"
    google_services_framework_check "$stage/compat_tool/images/rootfs/system/framework/services.jar"
    if [[ -f "$stage/compat_tool/provenance/gapps/SHA256SUMS" ]]; then
        (cd "$stage/compat_tool/images/rootfs" && sha256sum -c "$stage/compat_tool/provenance/gapps/SHA256SUMS" >/dev/null)
    fi
fi
source "$repo/compat_tool/liblepton/ndk_auxv/runtime.sh"
if ndk_compat_supported "$stage/compat_tool/images/rootfs"; then
    [[ -f "$repo/compat_tool/liblepton/ndk_auxv/bin/liblepton_ndk_auxv.so" ]] || {
        echo 'ERROR: Build the standard NDK shim before packaging: bash compat_tool/liblepton/ndk_auxv/build.sh --aosp DIR' >&2
        exit 1
    }
fi
for program in rsync tar gzip sha256sum awk grep mktemp install; do
    command -v "$program" >/dev/null || { echo "ERROR: missing $program" >&2; exit 1; }
done

for script in liblepton.sh app_metadata.sh mounting.sh baking.sh properties.sh; do
    [[ -f "$repo/compat_tool/liblepton/$script" ]] || {
        echo "ERROR: missing Fedora source compat_tool/liblepton/$script" >&2
        exit 1
    }
done
for script in compat_tool/lepton compat_tool/tools/lepton-gamescope-bridge compat_tool/tools/lepton-controller-hotplug-experiment; do
    [[ -f "$repo/$script" ]] || { echo "ERROR: missing Fedora source $script" >&2; exit 1; }
    bash -n "$repo/$script"
done
[[ -f "$repo/compat_tool/tools/lepton-add-game" ]] || { echo 'ERROR: missing shortcut installer' >&2; exit 1; }
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$repo/compat_tool/tools/lepton-add-game"
[[ -f "$repo/compat_tool/liblepton/Vendor_28de_Product_11ff.kl" ]] || {
    echo "ERROR: missing Steam Input keylayout in Fedora source" >&2
    exit 1
}

# Require a previously validated stage. Do not dereference the source checkout's
# external rootfs symlink, and do not assemble the Android rootfs here.
for path in \
    compat_tool/lepton \
    compat_tool/toolmanifest.vdf \
    compat_tool/liblepton/liblepton.sh \
    compat_tool/liblepton/app_metadata.sh \
    compat_tool/liblepton/mounting.sh \
    compat_tool/liblepton/baking.sh \
    compat_tool/sysbake.xattrs \
    compat_tool/sysbake/system/packages.xml \
    compat_tool/images/rootfs/system/etc/init/hw/init.rc \
    compat_tool/images/rootfs/vendor/lib64/hw/vulkan.radeon.so \
    compat_tool/images/rootfs_overlay/system/bin/binderfs-ensure \
    tools/platform-tools/adb \
    tools/bin/inotifywait; do
    [[ -e "$stage/$path" ]] || { echo "ERROR: missing staging asset: $path" >&2; exit 1; }
done
[[ -d "$stage/compat_tool/images/rootfs" && ! -L "$stage/compat_tool/images/rootfs" ]] || {
    echo 'ERROR: staged Android rootfs must be a real directory' >&2; exit 1;
}
grep -q 'binderfs-ensure' "$stage/compat_tool/images/rootfs/system/etc/init/hw/init.rc" || {
    echo 'ERROR: staged Android init.rc is missing the BinderFS helper hook' >&2; exit 1;
}
grep -q 'steamlaunch-0' "$repo/compat_tool/liblepton/liblepton.sh" || {
    echo 'ERROR: Fedora installer lacks the tested steamlaunch-0 installation route' >&2; exit 1;
}
for script in liblepton.sh app_metadata.sh mounting.sh baking.sh properties.sh; do
    bash -n "$repo/compat_tool/liblepton/$script"
done
grep -Fq 'no-force-stop' "$repo/compat_tool/liblepton/app_metadata.sh" || {
    echo 'ERROR: Fedora source missing tested no-force-stop option' >&2; exit 1;
}
grep -Fq 'no-force-stop' "$repo/compat_tool/liblepton/mounting.sh" || {
    echo 'ERROR: Fedora source missing tested automatic launch call' >&2; exit 1;
}

[[ ! -e "$archive" && ! -L "$archive" && ! -e "$checksum" && ! -L "$checksum" ]] || {
    echo "ERROR: output already exists; refusing overwrite: $archive" >&2
    exit 1
}
if [[ "$mode" == --check ]]; then
    echo "PASS: bundle preflight for $archive; no files changed"
    exit 0
fi
mkdir -p -- "$outdir"
tmp="$(mktemp -d "$outdir/.lepton-bundle-XXXXXXXX")"
cleanup() {
    local status=$?
    trap - EXIT
    # Android's sysbake includes mode-000 / mode-100 directories. The rsync
    # stage copy is owned by us but permissions can block recursive removal.
    # Only relax permissions on this throwaway copy, never on the source stage.
    chmod -R u+rwX -- "$tmp" 2>/dev/null || true
    if ! rm -rf -- "$tmp"; then
        echo "WARNING: could not fully remove temporary bundle staging at $tmp" >&2
    fi
    exit "$status"
}
trap cleanup EXIT

printf 'Copying staged bundle (no rootfs rebuild)...\n'
mkdir -p -- "$tmp/payload"
# Copy only distributable components, never temporary build workspaces.
[[ -d "$stage/compat_tool" && -d "$stage/tools" ]] || {
    echo "ERROR: missing stage components" >&2
    exit 1
}
rsync -a --no-owner --no-group --exclude='/liblepton/apk_extractor/target/' --exclude=__pycache__/ -- "$stage/compat_tool/" "$tmp/payload/compat_tool/"
rsync -a --no-owner --no-group -- "$stage/tools/" "$tmp/payload/tools/"

# Refresh all tested shell fixes without touching the staged materialized
# Android rootfs (the Fedora checkout holds only an external rootfs symlink).
# Earlier stages did not ship compat_tool/tools; create the destination before
# overlaying the newer launch helpers.
mkdir -p -- "$tmp/payload/compat_tool/liblepton" "$tmp/payload/compat_tool/tools"
rsync -a --no-owner --no-group -- "$repo/compat_tool/liblepton/ndk_auxv/" \
    "$tmp/payload/compat_tool/liblepton/ndk_auxv/"
for script in liblepton.sh app_metadata.sh mounting.sh baking.sh properties.sh; do
    install -m 755 "$repo/compat_tool/liblepton/$script" \
        "$tmp/payload/compat_tool/liblepton/$script"
done
# Keep Android command routing and launcher alias parsing current too.
install -m 755 "$repo/compat_tool/images/rootfs_overlay/system/bin/cmd" \
    "$tmp/payload/compat_tool/images/rootfs_overlay/system/bin/cmd"
if [[ -x "$repo/compat_tool/liblepton/apk_extractor/bin/apk-info-extractor" ]]; then
    install -D -m 755 "$repo/compat_tool/liblepton/apk_extractor/bin/apk-info-extractor" \
        "$tmp/payload/compat_tool/liblepton/apk_extractor/bin/apk-info-extractor"
fi
# The persistent test runner also handles split APKM installs. Ship only its
# source helpers; profiles, APKs and host build workspaces are never included.
mkdir -p "$tmp/payload/tests/runtime"
for helper in run-apk.sh unpack-apkm.py read-gsf-id.py; do
    install -m 755 "$repo/tests/runtime/$helper" "$tmp/payload/tests/runtime/$helper"
done
install -m 644 "$repo/tests/runtime/README.md" "$tmp/payload/tests/runtime/README.md"
install -m 644 "$repo/tests/runtime/STEAM-DECK-GAPPS.md" "$tmp/payload/tests/runtime/STEAM-DECK-GAPPS.md"
# These launch helpers must track the checked-out Fedora source, not an
# older stage snapshot. Do not touch the staged Android rootfs.
install -m 755 "$repo/compat_tool/lepton" "$tmp/payload/compat_tool/lepton"
install -m 755 "$repo/compat_tool/tools/lepton-gamescope-bridge" \
    "$tmp/payload/compat_tool/tools/lepton-gamescope-bridge"
install -m 755 "$repo/compat_tool/tools/lepton-controller-hotplug-experiment" \
    "$tmp/payload/compat_tool/tools/lepton-controller-hotplug-experiment"
install -m 755 "$repo/compat_tool/tools/lepton-add-game" \
    "$tmp/payload/compat_tool/tools/lepton-add-game"
install -m 755 "$repo/compat_tool/tools/lepton-register-tool" \
    "$tmp/payload/compat_tool/tools/lepton-register-tool"
install -m 644 "$repo/compat_tool/liblepton/Vendor_28de_Product_11ff.kl" \
    "$tmp/payload/compat_tool/liblepton/Vendor_28de_Product_11ff.kl"

# A Fedora sysbake may carry security.selinux xattrs, which cannot be restored
# by Deck users. Keep every user.* attribute and its file-path record intact.
xattrs="$tmp/payload/compat_tool/sysbake.xattrs"
original_user_count="$(awk '/^user\.[^=]*=/{n++} END{print n+0}' "$xattrs")"
original_selinux_count="$(awk '/^security\.selinux=/{n++} END{print n+0}' "$xattrs")"
awk '!/^security\.selinux=/' "$xattrs" > "$tmp/sysbake.xattrs.filtered"
cat "$tmp/sysbake.xattrs.filtered" > "$xattrs"
filtered_user_count="$(awk '/^user\.[^=]*=/{n++} END{print n+0}' "$xattrs")"
[[ "$original_user_count" -gt 0 && "$original_user_count" -eq "$filtered_user_count" ]] || {
    echo 'ERROR: sysbake user.* attributes did not survive filtering' >&2; exit 1;
}
if grep -q '^security\.selinux=' "$xattrs"; then
    echo 'ERROR: Fedora SELinux labels remain after filtering' >&2; exit 1
fi

# Metadata and registration use a distinct ID/directory for optional GApps.
# The helper resolves the actual extracted path instead of assuming /home/deck.
python3 - "$tmp/payload" "$bundle_id" "$tool_id" "$tool_name" "$install_name" "$(basename -- "$archive")" <<'PYBUNDLE'
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
bundle, tool, name, directory, archive = sys.argv[2:]
(root / 'BUNDLE.json').write_text(json.dumps(dict(
    format_version=1, bundle_id=bundle, tool_id=tool, display_name=name,
    install_directory=directory), indent=2) + '\n')
(root / 'STEAM-DECK-INSTALL.txt').write_text(f'''Lepton Steam Deck bundle: {name}

In Desktop Mode, extract into a NEW directory (existing installs are retained):
  cd "$HOME/Downloads"
  sha256sum -c {archive}.sha256 &&
  mkdir "$HOME/.local/share/{directory}" &&
  tar -xzf {archive} -C "$HOME/.local/share/{directory}" --no-same-owner

Register this compatibility tool, then restart Steam:
  python3 "$HOME/.local/share/{directory}/compat_tool/tools/lepton-register-tool" --execute
The registration refuses conflicting tool IDs. Existing registrations are kept.

For a normal APK, fully exit Steam before adding its shortcut:
  python3 "$HOME/.local/share/{directory}/compat_tool/tools/lepton-add-game" /path/to/game.apk --tool-id {tool} --install-dir "$HOME/.local/share/{directory}"

For Google registration/sign-in, then APK/APKM install/play in a persistent
profile, follow GAPPS.md. Saved profiles and credentials are never bundled.
For a saved profile shortcut, use lepton-add-game --runtime-profile NAME
--install-dir "$HOME/.local/share/{directory}"; Steam compatibility forcing
must remain unchecked for that native launcher shortcut.

Enable Steam Input Touchscreen Native Support in the shortcut controller layout.
Never overwrite a running installation. Default cleanup remains unchanged for
normal APK shortcuts; saved profiles explicitly enable persistence.
''')
PYBUNDLE
install -m 644 "$repo/GAPPS.md" "$tmp/payload/GAPPS.md"

[[ -f "$tmp/payload/compat_tool/images/rootfs/system/etc/init/hw/init.rc" ]]
[[ -x "$tmp/payload/compat_tool/images/rootfs_overlay/system/bin/binderfs-ensure" ]]
[[ -s "$tmp/payload/compat_tool/liblepton/Vendor_28de_Product_11ff.kl" ]]
for script in liblepton.sh app_metadata.sh mounting.sh baking.sh properties.sh; do
    bash -n "$tmp/payload/compat_tool/liblepton/$script"
done
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$tmp/payload/compat_tool/tools/lepton-add-game"
grep -Fq 'no-force-stop' "$tmp/payload/compat_tool/liblepton/mounting.sh"
for script in compat_tool/lepton compat_tool/tools/lepton-gamescope-bridge compat_tool/tools/lepton-controller-hotplug-experiment; do
    bash -n "$tmp/payload/$script"
done

# Record exactly which launcher checkout and framework were packaged. This does
# not claim that the reused rootfs was freshly compiled from that checkout.
{
    printf 'Launcher source commit: %s\n' "$(git -C "$repo" rev-parse HEAD)"
    if [[ -n "$(git -C "$repo" status --porcelain)" ]]; then
        printf 'Launcher working tree: dirty\n'
    else
        printf 'Launcher working tree: clean\n'
    fi
    printf 'Bundle ID: %s\nTool ID: %s\n' "$bundle_id" "$tool_id"
    printf 'Android artifacts: staged rootfs (packaging does not rebuild Android)\n'
    for path in system/build.prop system/framework/services.jar; do
        if [[ -f "$tmp/payload/compat_tool/images/rootfs/$path" ]]; then
            (cd "$tmp/payload/compat_tool/images/rootfs" && sha256sum "$path")
        fi
    done
    printf 'Payload provenance: compat_tool/provenance and compat_tool/ndk-provenance when present\n'
} > "$tmp/payload/tools/BUNDLE-PROVENANCE.txt"

printf 'Creating compressed archive...\n'
( cd "$tmp/payload" && tar --warning=no-file-ignored -cf - . ) | gzip -1 > "$tmp/bundle.tar.gz"
gzip -t "$tmp/bundle.tar.gz"
tar -tzf "$tmp/bundle.tar.gz" | grep -Fx './compat_tool/images/rootfs/system/etc/init/hw/init.rc' >/dev/null
mv -- "$tmp/bundle.tar.gz" "$archive"
( cd "$outdir" && sha256sum "$(basename -- "$archive")" ) > "$checksum"
printf 'PASS: filtered %s security.selinux entries; preserved %s user.* entries\n' \
    "$original_selinux_count" "$filtered_user_count"
printf 'PASS: %s\n' "$archive"
printf 'PASS: %s\n' "$checksum"
ls -lh "$archive" "$checksum"
if [[ -n "$deck_ip" ]]; then transfer_bundle; fi

)
