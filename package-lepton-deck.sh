#!/usr/bin/env bash
# Build a Steam Deck transferable bundle from an already-prepared Fedora stage.
# Local directories are configured in .build-env; command-line options override.
# Usage: ./package-lepton-deck.sh [STAGE_DIR] [OUT_DIR] [--bundle-id ID] [--deck-ip IPv4]
#        ./package-lepton-deck.sh [STAGE_DIR] [OUT_DIR] [--bundle-id ID] --deck-ip IPv4 --transfer-only
set -Eeuo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# This is a trusted, developer-maintained shell config already used by builds.
[[ ! -f "$repo/.build-env" ]] || source "$repo/.build-env"
stage="${LEPTON_DECK_STAGE_DIR:-}"
outdir="${LEPTON_DECK_BUNDLE_DIR:-${HOME}/lepton-deck-bundles}"
deck_ip=""
bundle_id="${LEPTON_DECK_BUNDLE_ID:-dev-$(date -u +%Y%m%d-%H%M%S)}"
transfer_only=false
positionals=()

usage() {
    cat <<'HELP'
Usage:
  ./package-lepton-deck.sh [STAGE_DIR] [OUT_DIR] [--bundle-id ID] [--deck-ip IPv4]
  ./package-lepton-deck.sh [STAGE_DIR] [OUT_DIR] [--bundle-id ID] --deck-ip IPv4 --transfer-only

Without --deck-ip, package locally only. With --deck-ip, copy the resulting
archive + checksum to deck@IP:~/Downloads/lepton-deck-bundles/ and verify it.
--transfer-only sends an already-built archive without repackaging.
Reads .build-env from the repository root. Configure LEPTON_DECK_STAGE_DIR,
LEPTON_DECK_BUNDLE_DIR there (see .build-env.example).
Positional directory arguments override the configured paths.
--bundle-id names a distinct archive; default: timestamped dev bundle.
--transfer-only requires the same bundle ID previously used to package.
Neither mode modifies the Deck's existing Lepton installation.
HELP
}

while (( $# )); do
    case "$1" in
        --deck-ip)
            (( $# >= 2 )) || { echo 'ERROR: --deck-ip needs an IPv4 address' >&2; exit 2; }
            deck_ip="$2"
            shift 2
            ;;
        --bundle-id)
            (( $# >= 2 )) || { echo 'ERROR: --bundle-id needs a value' >&2; exit 2; }
            bundle_id="$2"
            shift 2
            ;;
        --transfer-only)
            transfer_only=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            echo "ERROR: unknown option $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            positionals+=("$1")
            shift
            ;;
    esac
done

(( ${#positionals[@]} <= 2 )) || { usage >&2; exit 2; }
if (( ${#positionals[@]} >= 1 )); then stage="${positionals[0]}"; fi
if (( ${#positionals[@]} >= 2 )); then outdir="${positionals[1]}"; fi

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

[[ "$bundle_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && ${#bundle_id} -le 64 ]] || {
    echo 'ERROR: bundle ID must contain 1-64 letters, digits, dots, dashes or underscores' >&2
    exit 2
}

mkdir -p -- "$outdir"
outdir="$(realpath -e -- "$outdir")"
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
    transfer_bundle
    exit 0
fi

[[ -n "$stage" ]] || {
    echo 'ERROR: set LEPTON_DECK_STAGE_DIR in .build-env or supply STAGE_DIR' >&2
    exit 2
}
stage="$(realpath -e -- "$stage")"
for program in rsync tar gzip sha256sum awk grep mktemp install; do
    command -v "$program" >/dev/null || { echo "ERROR: missing $program" >&2; exit 1; }
done

for script in liblepton.sh app_metadata.sh mounting.sh baking.sh; do
    [[ -f "$repo/compat_tool/liblepton/$script" ]] || {
        echo "ERROR: missing Fedora source compat_tool/liblepton/$script" >&2
        exit 1
    }
done
for script in compat_tool/lepton compat_tool/tools/lepton-gamescope-bridge compat_tool/tools/lepton-controller-hotplug-experiment; do
    [[ -f "$repo/$script" ]] || { echo "ERROR: missing Fedora source $script" >&2; exit 1; }
    bash -n "$repo/$script"
done
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
for script in liblepton.sh app_metadata.sh mounting.sh baking.sh; do
    bash -n "$repo/compat_tool/liblepton/$script"
done
grep -Fq 'no-force-stop' "$repo/compat_tool/liblepton/app_metadata.sh" || {
    echo 'ERROR: Fedora source missing tested no-force-stop option' >&2; exit 1;
}
grep -Fq 'no-force-stop' "$repo/compat_tool/liblepton/mounting.sh" || {
    echo 'ERROR: Fedora source missing tested automatic launch call' >&2; exit 1;
}

[[ ! -e "$archive" && ! -e "$checksum" ]] || {
    echo "ERROR: output already exists; refusing overwrite: $archive" >&2
    exit 1
}
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
rsync -a --no-owner --no-group -- "$stage/" "$tmp/payload/"

# Refresh all tested shell fixes without touching the staged materialized
# Android rootfs (the Fedora checkout holds only an external rootfs symlink).
for script in liblepton.sh app_metadata.sh mounting.sh baking.sh; do
    install -m 755 "$repo/compat_tool/liblepton/$script" \
        "$tmp/payload/compat_tool/liblepton/$script"
done
# These launch helpers must track the checked-out Fedora source, not an
# older stage snapshot. Do not touch the staged Android rootfs.
install -m 755 "$repo/compat_tool/lepton" "$tmp/payload/compat_tool/lepton"
install -m 755 "$repo/compat_tool/tools/lepton-gamescope-bridge" \
    "$tmp/payload/compat_tool/tools/lepton-gamescope-bridge"
install -m 755 "$repo/compat_tool/tools/lepton-controller-hotplug-experiment" \
    "$tmp/payload/compat_tool/tools/lepton-controller-hotplug-experiment"
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

# Ship the registration template for a future fresh install. Existing Steam
# configurations are not modified by this packaging operation.
cat > "$tmp/payload/lepton_x86_64_dev.vdf" <<'VDF'
"compatibilitytools"
{
    "compat_tools"
    {
        "lepton_x86_64_dev"
        {
            "install_path" "/home/deck/.local/share/lepton-x86_64-dev/compat_tool"
            "display_name" "Lepton x86_64 (development)"
            "from_oslist" "windows"
            "to_oslist" "linux"
        }
    }
}
VDF
cat > "$tmp/payload/STEAM-DECK-INSTALL.txt" <<'DOC'
Lepton x86_64 development bundle — Steam Deck (user: deck)

Extract from the Steam Deck user account (Desktop Mode):
  mkdir -p "$HOME/.local/share/lepton-x86_64-dev"
  tar -xzf lepton-x86_64-steamdeck-v308.tar.gz -C "$HOME/.local/share/lepton-x86_64-dev" --no-same-owner

Fresh registration, only if not already registered:
  mkdir -p "$HOME/.local/share/Steam/compatibilitytools.d"
  cp "$HOME/.local/share/lepton-x86_64-dev/lepton_x86_64_dev.vdf" "$HOME/.local/share/Steam/compatibilitytools.d/"
  Restart Steam after initial registration.

Add an APK as a non-Steam shortcut and choose "Lepton x86_64 (development)"
under Properties > Compatibility. Use these Steam launch options:
  SteamAppId=0 APP_WANTS_FLATSCREEN=true GAMESCOPE_WAYLAND_DISPLAY=wayland-0 LEPTON_ADB=/home/deck/.local/share/lepton-x86_64-dev/tools/platform-tools/adb PATH=/home/deck/.local/share/lepton-x86_64-dev/tools/bin:$PATH %command%

The steamlaunch-0 app-install path uses Podman and waits for Android package
services before installing. The automatic game launch does not force-stop a
already-running app if init triggers it again.
Do not overwrite a running compatibility tool.
DOC

# Keep the embedded install instructions in sync with the requested archive ID.
sed -i "s/lepton-x86_64-steamdeck-v308.tar.gz/$(basename -- "$archive")/g" \
    "$tmp/payload/STEAM-DECK-INSTALL.txt"

[[ -f "$tmp/payload/compat_tool/images/rootfs/system/etc/init/hw/init.rc" ]]
[[ -x "$tmp/payload/compat_tool/images/rootfs_overlay/system/bin/binderfs-ensure" ]]
[[ -s "$tmp/payload/compat_tool/liblepton/Vendor_28de_Product_11ff.kl" ]]
for script in liblepton.sh app_metadata.sh mounting.sh baking.sh; do
    bash -n "$tmp/payload/compat_tool/liblepton/$script"
done
grep -Fq 'no-force-stop' "$tmp/payload/compat_tool/liblepton/mounting.sh"
for script in compat_tool/lepton compat_tool/tools/lepton-gamescope-bridge compat_tool/tools/lepton-controller-hotplug-experiment; do
    bash -n "$tmp/payload/$script"
done

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
