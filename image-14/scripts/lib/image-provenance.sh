#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Image provenance: what the Android images were built from.
#
# build-images-x86_64.sh writes images/BUILD-INFO.txt after each build;
# make-deck-bundle copies it into the bundle as tools/IMAGE-PROVENANCE.txt
# (only when the bundle's rootfs is the one that build produced); the release
# publisher refuses a release whose images were not built from the release
# commit's image inputs.

# Repository paths that determine the Android images. A change to any of them
# needs prepare-x86_64.sh --reset and a new image build.
LEPTON_IMAGE_INPUTS=(
    image-14/android_device_valve_lepton
    image-14/android_hardware_waydroid
    image-14/android_vendor_valve
    image-14/patches
    image-14/.buildscripts
    image-14/scripts/prepare-x86_64.sh
)

# Folders prepare-x86_64.sh copies into the Android checkout once
# (.buildscripts/copy_vendored_projects.sh): "repository folder|checkout folder".
LEPTON_COPIED_TREES=(
    "image-14/android_device_valve_lepton|device/waydroid/waydroid"
    "image-14/android_hardware_waydroid|hardware/waydroid"
    "image-14/android_vendor_valve|vendor/extra"
)

# Lepton's own patches, applied as uncommitted changes by prepare-x86_64.sh
# (apply_custom): "checkout project|patch file". Keep in step with prepare;
# test-image-provenance.sh checks that both lists agree.
LEPTON_CUSTOM_PATCHES=(
    "external/mesa|0001-mesa-android-sdk34-link-libzstd.patch"
    "external/mesa|0002-radv-android-yv12-hardware-buffers.patch"
    "external/minigbm|0004-minigbm-gbm-mesa-driver.patch"
    "frameworks/native|0007-eventhub-preserve-evdev-axes.patch"
    "frameworks/native|0008-inputreader-separate-steam-input-pads.patch"
    "hardware/waydroid|0009-hwc-local-wayland-fullscreen.patch"
    "frameworks/native|0010-egl-hide-untranslatable-gl-extensions.patch"
)

# image_source_status REPO AOSP: verify copied source content and every patch.
# The copied project's Git HEAD can differ: vendoring copies pinned source files
# over the manifest project. Content plus applied patches is authoritative.
image_source_status() (
    set -Eeuo pipefail
    local repo="$1" aosp="$2" entry src dst project patch expected custom matching
    local inputs=clean trees=match patches=applied
    local -a tree_problems=() patch_problems=()
    [[ -z "$(git -C "$repo" status --porcelain -- "${LEPTON_IMAGE_INPUTS[@]}")" ]] || inputs=modified
    for entry in "${LEPTON_COPIED_TREES[@]}"; do
        src="$repo/${entry%%|*}" dst="$aosp/${entry#*|}"
        if [[ -z "$(ls -A -- "$src" 2>/dev/null)" ]]; then
            # An uninitialised submodule (e.g. in a git worktree): cannot compare.
            trees=differ; tree_problems+=("${entry%%|*} not checked out")
        else
            # A copied project can also receive a reviewed custom patch. Compare
            # its expected patched tree, never treat those changes as unexplained.
            matching=()
            for custom in "${LEPTON_CUSTOM_PATCHES[@]}"; do
                [[ "${custom%%|*}" != "${entry#*|}" ]] || matching+=("${custom#*|}")
            done
            expected="$src"
            if ((${#matching[@]})); then
                expected="$(mktemp -d)"
                cp -a -- "$src/." "$expected/"
                rm -rf -- "$expected/.git"
                for patch in "${matching[@]}"; do
                    git -C "$expected" apply --no-index "$repo/image-14/patches/$patch" >/dev/null 2>&1 ||
                        { trees=differ; tree_problems+=("${entry#*|} expected patch failed"); }
                done
            fi
            if ! diff -rq --no-dereference --exclude=.git -- "$expected" "$dst" >/dev/null 2>&1; then
                trees=differ; tree_problems+=("${entry#*|}")
            fi
            [[ "$expected" == "$src" ]] || rm -rf -- "$expected"
        fi
    done
    for entry in "${LEPTON_CUSTOM_PATCHES[@]}"; do
        project="$aosp/${entry%%|*}" patch="$repo/image-14/patches/${entry#*|}"
        if ! git -C "$project" apply --reverse --check "$patch" >/dev/null 2>&1; then
            patches=missing; patch_problems+=("${entry#*|}")
        fi
    done
    printf 'Image inputs: %s\n' "$inputs"
    printf 'Copied folders: %s%s\n' "$trees" "${tree_problems[*]:+ (${tree_problems[*]})}"
    printf 'Lepton patches: %s%s\n' "$patches" "${patch_problems[*]:+ (${patch_problems[*]})}"
    [[ "$trees" == match && "$patches" == applied ]]
)

# image_provenance_write REPO AOSP ROOTFS OUTPUT
# Records the repository commit, whether the image inputs had uncommitted
# changes, whether the copied folders still match the repository, whether
# each Lepton patch is applied, the resolved AOSP manifest and the rootfs.
image_provenance_write() (
    set -Eeuo pipefail
    local repo="$1" aosp="$2" rootfs="$3" output="$4" status
    status="$(image_source_status "$repo" "$aosp" || true)"
    {
        printf 'Image source commit: %s\n' "$(git -C "$repo" rev-parse HEAD)"
        printf '%s\n' "$status"
        printf 'AOSP manifest SHA256: %s\n' \
            "$(sha256sum "$aosp/.lepton-resolved-manifest.xml" 2>/dev/null | cut -d' ' -f1 || echo unknown)"
        printf 'Rootfs build.prop SHA256: %s\n' "$(sha256sum "$rootfs/system/build.prop" | cut -d' ' -f1)"
        if [[ -f "$rootfs/vendor/lib64/hw/hwcomposer.waydroid.so" ]]; then
            printf 'Rootfs hwcomposer SHA256: %s\n' "$(sha256sum "$rootfs/vendor/lib64/hw/hwcomposer.waydroid.so" | cut -d' ' -f1)"
        fi
        printf 'Built: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$output"
)

# image_provenance_check FILE REPO RELEASE_COMMIT BUILD_PROP_SHA256
# Prints problems, one per line; succeeds only if there are none.
image_provenance_check() (
    set -Eeuo pipefail
    local file="$1" repo="$2" release="$3" prop="$4" commit
    local -a problems=()
    field() { sed -n "s/^$1: //p" "$file" | head -1; }
    commit="$(field 'Image source commit')"
    [[ "$(field 'Image inputs')" == clean ]] || problems+=('the images were built with uncommitted changes to their inputs')
    [[ "$(field 'Copied folders')" == match ]] ||
        problems+=("folders copied into the Android checkout differ from the repository: $(field 'Copied folders')")
    [[ "$(field 'Lepton patches')" == applied ]] ||
        problems+=("Lepton patches were not applied: $(field 'Lepton patches')")
    [[ "$(field 'Rootfs build.prop SHA256')" == "$prop" ]] ||
        problems+=('the record belongs to a different image build than the bundle')
    if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]] || ! git -C "$repo" cat-file -e "$commit^{commit}" 2>/dev/null; then
        problems+=("unknown image source commit: ${commit:-none}")
    elif ! git -C "$repo" merge-base --is-ancestor "$commit" "$release"; then
        problems+=("image commit $commit is not an ancestor of the release commit")
    elif ! git -C "$repo" diff --quiet "$commit" "$release" -- "${LEPTON_IMAGE_INPUTS[@]}"; then
        problems+=("image inputs changed between $commit and the release commit (prepare --reset and rebuild)")
    fi
    ((${#problems[@]} == 0)) || { printf '%s\n' "${problems[@]}"; return 1; }
)
