#!/usr/bin/env bash
# Capture current Lepton x86_64 source changes without staging/committing to the real index.
# Install under image-14/scripts/ and run: bash scripts/snapshot-worktree-patches.sh
set -Eeuo pipefail

IMAGE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
COMPAT_DIR="$(cd -- "$IMAGE_DIR/../compat_tool" && pwd -P)"
AOSP_DIR="$(readlink -f -- "$IMAGE_DIR/aosp-output")"

if [[ ! -d "$AOSP_DIR/external/minigbm/.git" && ! -f "$AOSP_DIR/external/minigbm/.git" ]]; then
    echo "ERROR: expected a Git checkout at $AOSP_DIR/external/minigbm" >&2
    exit 1
fi

# The Android input fix lives in frameworks/native, which is a separate
# AOSP Git project. Check it explicitly before starting a capture.
for repo in \
    "$IMAGE_DIR" \
    "$COMPAT_DIR" \
    "$AOSP_DIR/external/mesa" \
    "$AOSP_DIR/frameworks/native"; do
    if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "ERROR: not a Git working tree: $repo" >&2
        exit 1
    fi
done

mkdir -p -- "$IMAGE_DIR/patches/snapshots"
OUT="$(mktemp -d "$IMAGE_DIR/patches/snapshots/run-XXXXXXXX")"
printf 'Generated: %s\n' "$(date -Is)" > "$OUT/BASE_COMMITS.txt"
printf 'Snapshots are raw, unreviewed, current working-tree changes.\n' >> "$OUT/BASE_COMMITS.txt"
printf 'They may contain obsolete AMD/DRI code or duplicate the Mesa zstd patch.\n\n' >> "$OUT/BASE_COMMITS.txt"

ALT_INDEX=''
cleanup_index() {
    if [[ -n "$ALT_INDEX" ]]; then
        rm -f -- "$ALT_INDEX" "$ALT_INDEX.lock"
    fi
}
trap cleanup_index EXIT

capture() {
    local label="$1" repo="$2"; shift 2
    local outfile="$OUT/${label}.DRAFT.patch"

    printf '\n[%s]\n' "$label" >> "$OUT/BASE_COMMITS.txt"
    printf 'requested_directory=%s\n' "$repo" >> "$OUT/BASE_COMMITS.txt"
    printf 'git_root=%s\n' "$(git -C "$repo" rev-parse --show-toplevel)" >> "$OUT/BASE_COMMITS.txt"
    printf 'base_commit=%s\n' "$(git -C "$repo" rev-parse HEAD)" >> "$OUT/BASE_COMMITS.txt"
    git -C "$repo" status --short --untracked-files=normal > "$OUT/${label}.status.txt"

    # Build a temporary index starting at HEAD: includes new/untracked files while
    # avoiding writes to the user's real staging area (.git/index).
    ALT_INDEX="$(mktemp "$OUT/.alt-index-XXXXXXXX")"
    rm -f -- "$ALT_INDEX"
    GIT_INDEX_FILE="$ALT_INDEX" git -C "$repo" read-tree HEAD
    GIT_INDEX_FILE="$ALT_INDEX" git -C "$repo" add -A -- "$@"
    GIT_INDEX_FILE="$ALT_INDEX" git -C "$repo" diff --cached --binary --full-index HEAD > "$outfile"
    cleanup_index
    ALT_INDEX=''
    if [[ -s "$outfile" ]]; then
        echo "Captured: $(basename "$outfile") ($(wc -c < "$outfile") bytes)"
    else
        echo "No selected changes for: $label"
    fi
}

# These snapshots intentionally include experimental work. Review before use.
capture minigbm "$AOSP_DIR/external/minigbm" .
capture mesa-android "$AOSP_DIR/external/mesa" android

# Preserve the verified Android 14 EventHub joystick-axis fix. This is an AOSP
# frameworks/native change, not a change in the main Lepton Git checkout.
capture inputflinger "$AOSP_DIR/frameworks/native" \
    services/inputflinger/reader/EventHub.cpp

# Scope the main repository to source/build changes, avoiding generated output,
# symlinks, binary images and draft snapshots.
image_paths=(android_device_valve_lepton .buildscripts/container.sh)
[[ -f "$IMAGE_DIR/.buildscripts/package_rootfs.sh" ]] && image_paths+=(.buildscripts/package_rootfs.sh)
[[ -d "$IMAGE_DIR/scripts" ]] && image_paths+=(scripts)

# Include reviewed, numbered top-level patch files, but NOT patches/snapshots/
# or patches/archive/. This captures a future promoted EventHub patch too.
shopt -s nullglob
for patch_file in "$IMAGE_DIR"/patches/[0-9][0-9][0-9][0-9]-*.patch; do
    image_paths+=("patches/$(basename "$patch_file")")
done
shopt -u nullglob
capture lepton-image "$IMAGE_DIR" "${image_paths[@]}"

compat_paths=(lepton liblepton)
[[ -d "$COMPAT_DIR/images/rootfs_overlay" ]] && compat_paths+=(images/rootfs_overlay)

# The working Steam Deck Gamescope bridge is a standalone launcher script,
# stored in the repo at compat_tool/tools/lepton-gamescope-bridge.
if [[ -f "$COMPAT_DIR/tools/lepton-gamescope-bridge" ]]; then
    compat_paths+=(tools/lepton-gamescope-bridge)
else
    echo "NOTE: Gamescope bridge not yet in compat_tool/tools/; copy it from the Deck to capture it."
fi

shopt -s nullglob
for test_script in "$COMPAT_DIR"/test-[0-9][0-9][0-9][0-9].sh; do
    compat_paths+=("$(basename "$test_script")")
done
shopt -u nullglob
capture lepton-runtime "$COMPAT_DIR" "${compat_paths[@]}"

cat > "$OUT/README.txt" <<'INFO'
PATCH CAPTURE — REVIEW REQUIRED
================================
Each *.DRAFT.patch is a snapshot against the base commit recorded in
BASE_COMMITS.txt. Apply patches from the corresponding git_root directory,
not blindly from image-14. No source/index changes were made to capture them.

minigbm: may include obsolete AMD/legacy DRI experimental code alongside the
          working Waydroid GBM/Mesa backend. Clean/split before finalization.
mesa-android: may overlap the existing 0001 SDK34 zstd patch; do NOT apply both
              without inspecting the diff.
inputflinger: Android frameworks/native EventHub source changes, including
              the real-evdev axis-range fix; promote to a reviewed permanent
              patch and add it to the image build workflow.
lepton-image: device config, build helpers, scripts, and numbered top-level
              reviewed patch files (excluding snapshots/archive).
lepton-runtime: launcher, runtime libraries, numbered tests, and the Gamescope
                bridge when present under compat_tool/tools/.

Next: review Git diffs and draft patches, remove experiments, promote the
EventHub change to an ordered patch, update build-images-x86_64.sh to apply it,
then verify clean patch application and rebuilt images before deployment.
INFO
printf '\nPatch snapshots saved to: %s\n' "$OUT"
printf 'Source checkouts and their actual Git index were not modified.\n'
