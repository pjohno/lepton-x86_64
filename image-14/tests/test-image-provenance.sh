#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# lib/image-provenance.sh: what the Android images were built from.
# A throwaway repository and Android checkout; no Android build.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$repo/image-14/scripts/lib/image-provenance.sh"
field() { sed -n "s/^$1: //p" "$work/info"; }

# The lists agree with what prepare-x86_64.sh and copy_vendored_projects.sh do.
expected="$(sed -n 's|^apply_custom /workspace/output/\([^ ]*\) /workspace/patches/\([^ ]*\) .*|\1\|\2|p' \
    "$repo/image-14/scripts/prepare-x86_64.sh")"
[[ "$expected" == "$(printf '%s\n' "${LEPTON_CUSTOM_PATCHES[@]}")" ]] ||
    fail "LEPTON_CUSTOM_PATCHES differs from prepare-x86_64.sh apply_custom: $expected"
for entry in "${LEPTON_COPIED_TREES[@]}"; do
    src="${entry%%|*}" dst="${entry#*|}"
    grep -Eq "rsync .*\"\\\$\{ROOT_DIR\}/${src#image-14/}/\" \"\\\$\{ANDROID_ROOT\}/$dst\"" \
        "$repo/image-14/.buildscripts/copy_vendored_projects.sh" || fail "copy_vendored_projects.sh does not copy $src to $dst"
done
for path in "${LEPTON_IMAGE_INPUTS[@]}"; do
    git -C "$repo" ls-files --error-unmatch -- "$path" >/dev/null 2>&1 || [[ -e "$repo/$path" ]] ||
        fail "image input does not exist: $path"
done

# A fake repository with the image inputs, and a matching Android checkout.
fake="$work/repo" aosp="$work/aosp" rootfs="$work/rootfs"
mkdir -p "$fake/image-14/patches" "$rootfs/system"
printf 'ro.build.version.sdk=34\n' > "$rootfs/system/build.prop"
printf '<manifest/>\n' > "$work/manifest"
for entry in "${LEPTON_COPIED_TREES[@]}"; do
    mkdir -p "$fake/${entry%%|*}/sub" "$aosp/${entry#*|}/sub"
    printf 'device file\n' > "$fake/${entry%%|*}/sub/file"
    cp "$fake/${entry%%|*}/sub/file" "$aosp/${entry#*|}/sub/file"
    ln -s ../../elsewhere "$fake/${entry%%|*}/link"; ln -s ../../elsewhere "$aosp/${entry#*|}/link"
done
cp "$work/manifest" "$aosp/.lepton-resolved-manifest.xml"
for entry in "${LEPTON_CUSTOM_PATCHES[@]}"; do
    project="$aosp/${entry%%|*}" patch="$fake/image-14/patches/${entry#*|}"
    if [[ ! -d "$project/.git" ]]; then
        mkdir -p "$project" && git -C "$project" init -q
        git -C "$project" config user.email t@example.invalid; git -C "$project" config user.name T
        printf 'base\n' > "$project/source.c"
        for copied in "${LEPTON_COPIED_TREES[@]}"; do
            [[ "${copied#*|}" != "${entry%%|*}" ]] || cp "$project/source.c" "$fake/${copied%%|*}/source.c"
        done
        git -C "$project" add -A; git -C "$project" commit -qm base
    fi
    # Each patch adds its own file to the project.
    name="${entry#*|}"
    printf 'diff --git a/%s.txt b/%s.txt\nnew file mode 100644\n--- /dev/null\n+++ b/%s.txt\n@@ -0,0 +1 @@\n+%s\n' \
        "$name" "$name" "$name" "$name" > "$patch"
    git -C "$project" apply "$patch"
done
git -C "$fake" init -q -b main
git -C "$fake" config user.email t@example.invalid; git -C "$fake" config user.name T
printf 'readme\n' > "$fake/README.md"
git -C "$fake" add -A && git -C "$fake" commit -qm initial
prop="$(sha256sum "$rootfs/system/build.prop" | cut -d' ' -f1)"

# A clean build: everything recorded as matching.
image_provenance_write "$fake" "$aosp" "$rootfs" "$work/info"
[[ "$(field 'Image source commit')" == "$(git -C "$fake" rev-parse HEAD)" ]] || fail 'commit'
[[ "$(field 'Image inputs')" == clean && "$(field 'Copied folders')" == match && "$(field 'Lepton patches')" == applied ]] ||
    { cat "$work/info"; fail 'a clean build is not recorded as clean'; }
[[ "$(field 'Rootfs build.prop SHA256')" == "$prop" ]] || fail 'build.prop hash'
[[ "$(field 'AOSP manifest SHA256')" == "$(sha256sum "$work/manifest" | cut -d' ' -f1)" ]] || fail 'manifest hash'
image_provenance_check "$work/info" "$fake" HEAD "$prop" || fail 'a clean record does not pass the check'
cp "$work/info" "$work/clean-info"

# Uncommitted changes to an image input.
echo change >> "$fake/image-14/android_device_valve_lepton/sub/file"
image_provenance_write "$fake" "$aosp" "$rootfs" "$work/info"
[[ "$(field 'Image inputs')" == modified ]] || fail 'modified inputs not recorded'
# ...which also makes the copied folder differ from the checkout.
[[ "$(field 'Copied folders')" == "differ (device/waydroid/waydroid)" ]] || { cat "$work/info"; fail 'differing folder'; }
if image_provenance_check "$work/info" "$fake" HEAD "$prop" > "$work/problems"; then fail 'modified inputs accepted'; fi
grep -q 'uncommitted changes' "$work/problems" && grep -q 'differ from the repository' "$work/problems"
git -C "$fake" checkout -q -- .

# A file only in the Android checkout's copy also counts as a difference.
touch "$aosp/vendor/extra/stray"
image_provenance_write "$fake" "$aosp" "$rootfs" "$work/info"
[[ "$(field 'Copied folders')" == "differ (vendor/extra)" ]] || fail 'stray file not detected'
rm "$aosp/vendor/extra/stray"

# An empty repository folder (uninitialised submodule) is never "match".
mv "$fake/image-14/android_hardware_waydroid" "$work/held" && mkdir "$fake/image-14/android_hardware_waydroid"
image_provenance_write "$fake" "$aosp" "$rootfs" "$work/info"
[[ "$(field 'Copied folders')" == "differ (image-14/android_hardware_waydroid not checked out)" ]] ||
    { cat "$work/info"; fail 'empty submodule'; }
rmdir "$fake/image-14/android_hardware_waydroid" && mv "$work/held" "$fake/image-14/android_hardware_waydroid"

# A Lepton patch that is not applied.
first="${LEPTON_CUSTOM_PATCHES[0]}"
git -C "$aosp/${first%%|*}" apply --reverse "$fake/image-14/patches/${first#*|}"
image_provenance_write "$fake" "$aosp" "$rootfs" "$work/info"
[[ "$(field 'Lepton patches')" == "missing (${first#*|})" ]] || { cat "$work/info"; fail 'unapplied patch'; }
if image_provenance_check "$work/info" "$fake" HEAD "$prop" >/dev/null; then fail 'missing patch accepted'; fi
git -C "$aosp/${first%%|*}" apply "$fake/image-14/patches/${first#*|}"

# The check: a different build, and later commits.
if image_provenance_check "$work/clean-info" "$fake" HEAD "$(printf '0%.0s' {1..64})" > "$work/problems"; then fail 'other build accepted'; fi
grep -q 'different image build' "$work/problems"
echo docs >> "$fake/README.md"; git -C "$fake" commit -qam docs
image_provenance_check "$work/clean-info" "$fake" HEAD "$prop" || fail 'a docs-only change should not matter'
echo '# x' >> "$fake/image-14/patches/${first#*|}"; git -C "$fake" commit -qam patch
if image_provenance_check "$work/clean-info" "$fake" HEAD "$prop" > "$work/problems"; then fail 'changed patch accepted'; fi
grep -q 'image inputs changed between' "$work/problems"
# Images from a commit newer than the release commit.
sed "s/^Image source commit: .*/Image source commit: $(git -C "$fake" rev-parse HEAD)/" "$work/clean-info" > "$work/newer-info"
if image_provenance_check "$work/newer-info" "$fake" HEAD~2 "$prop" > "$work/problems"; then fail 'later image commit accepted'; fi
grep -q 'not an ancestor' "$work/problems"

echo 'PASS: image provenance: lists match prepare, clean build recorded, modified inputs, differing or missing folders, unapplied patches, other builds and changed inputs refused'
