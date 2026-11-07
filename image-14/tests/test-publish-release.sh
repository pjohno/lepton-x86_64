#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# publish-release.sh against a throwaway git repository and a fake GitHub CLI:
# read-only --check, every refusal, draft creation and upload, resume,
# interrupted uploads, publishing, signing. Nothing reaches GitHub.
set -Eeuo pipefail
not() { if "$@"; then echo "FAIL: unexpectedly succeeded: $*" >&2; exit 1; fi; }
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

# A repository whose "github" remote is a local bare repository.
fake="$work/repo"
for file in image-14/scripts/publish-release.sh image-14/scripts/lib/workspace.sh image-14/scripts/lib/image-provenance.sh \
            image-14/patches/0001-mesa-android-sdk34-link-libzstd.patch .github/RELEASE_TEMPLATE.md \
            compat_tool/tools/lepton-install-bundle compat_tool/release-keys/allowed_signers; do
    install -D "$repo/$file" "$fake/$file"
done
# Start without a release key, whatever the real repository lists.
sed -i '/^[[:space:]]*[^#[:space:]]/d' "$fake/compat_tool/release-keys/allowed_signers"
git -C "$fake" init -q -b main
git -C "$fake" config user.email test@example.invalid
git -C "$fake" config user.name Test
git -C "$fake" add -A && git -C "$fake" commit -qm initial
git init -q --bare "$work/remote.git"
git -C "$fake" remote add github https://github.com/pjohno/lepton-x86_64.git
git -C "$fake" config url."$work/remote.git".insteadOf https://github.com/pjohno/lepton-x86_64.git
git -C "$fake" push -q github main && git -C "$fake" fetch -q github

mkdir -p "$work/bin"
install -m 755 "$repo/image-14/tests/lib/fake-gh" "$work/bin/gh"
export FAKE_GH_STATE="$work/gh-state.json" FAKE_GH_LOG="$work/gh.log"
out="$work/bundles"
mkdir -p "$out"

# make_bundle VERSION [COMMIT] [extra payload path] — writes the three files.
make_bundle() {
    local version="$1" commit="${2:-$(git -C "$fake" rev-parse HEAD)}" extra="${3:-}"
    local name="lepton-x86_64-steamdeck-$version" payload="$work/payload-$version"
    rm -rf -- "$payload" "$out/$name".*
    mkdir -p "$payload/compat_tool" "$payload/tools"
    printf '#!/bin/sh\n' > "$payload/compat_tool/lepton"
    printf '{"bundle_id": "%s", "tool_id": "lepton_x86_64_%s", "gapps": %s, "ndk": false}\n' \
        "${BUNDLE_ID:-$version}" "$(tr '.-' '__' <<< "$version")" "${GAPPS:-false}" > "$payload/BUNDLE.json"
    local prop=9297b881810c2b0e12c92f6e2b46265813eb26ba6f46446dfd998c6ed6499810
    printf 'Launcher source commit: %s\nLauncher working tree: %s\n%s  system/build.prop\n' \
        "$commit" "${TREE:-clean}" "$prop" > "$payload/tools/BUNDLE-PROVENANCE.txt"
    if [[ "${NO_IMAGE_INFO:-}" != 1 ]]; then
        printf 'Image source commit: %s\nImage inputs: %s\nCopied folders: match\nLepton patches: %s\nRootfs build.prop SHA256: %s\n' \
            "${IMAGE_COMMIT:-$commit}" "${IMAGE_INPUTS:-clean}" "${IMAGE_PATCHES:-applied}" "${IMAGE_PROP:-$prop}" \
            > "$payload/tools/IMAGE-PROVENANCE.txt"
    fi
    if [[ -n "$extra" ]]; then mkdir -p "$payload/$(dirname "$extra")"; printf 'x' > "$payload/$extra"; fi
    tar -C "$payload" -czf "$out/$name.tar.gz" .
    git -C "$fake" show "$commit:compat_tool/tools/lepton-install-bundle" |
        sed "s|^DEFAULT_ARCHIVE=''\$|DEFAULT_ARCHIVE='$name.tar.gz'|" > "$out/$name.install.sh"
    (cd "$out" && sha256sum "$name.tar.gz" "$name.install.sh" > "$name.tar.gz.sha256")
}
publish() {
    env -u LEPTON_RELEASE_SIGNING_KEY PATH="$work/bin:$PATH" \
        bash "$fake/image-14/scripts/publish-release.sh" --bundle-dir "$out" "$@" > "$work/out.log" 2>&1
}
expect_fail() {  # expect_fail MESSAGE ARGS...
    local message="$1"; shift
    if publish "$@"; then cat "$work/out.log"; echo "FAIL: accepted: $*"; exit 1; fi
    grep -Fq -- "$message" "$work/out.log" || { cat "$work/out.log"; echo "FAIL: expected '$message'"; exit 1; }
}
release_field() {  # release_field TAG PYTHON-EXPRESSION-ON-r
    python3 -c 'import json,sys; r=next(r for r in json.load(open(sys.argv[1]))["releases"] if r["tag_name"]==sys.argv[2]); print(eval(sys.argv[3]))' \
        "$FAKE_GH_STATE" "$1" "$2"
}
mutations() { grep -cE '^release (create|upload|edit)' "$FAKE_GH_LOG" || true; }

V=v0.1.0-alpha
make_bundle "$V"
# Option and input checks.
expect_fail 'explicit --version' --check
expect_fail 'Version must look like' --check --version 0.1.0
expect_fail 'Version must look like' --check --version v0.1.0+build
expect_fail 'No signature' --check --version "$V"
FAKE_GH_AUTH=1 expect_fail 'not signed in' --check --version "$V" --unsigned

# --check is read-only.
before="$(ls -l --time-style=full-iso "$out")"
publish --check --version "$V" --unsigned || { cat "$work/out.log"; exit 1; }
grep -q "Release $V is ready (prerelease); nothing was changed" "$work/out.log"
grep -q 'Installer matches the source commit' "$work/out.log"
[[ "$(mutations)" == 0 && ! -e "$FAKE_GH_STATE" && "$(ls -l --time-style=full-iso "$out")" == "$before" ]]

# Refusals: dirty checkout, missing or altered files, contents, provenance, size.
touch "$fake/untracked"; expect_fail 'uncommitted changes' --check --version "$V" --unsigned; rm "$fake/untracked"
mv "$out/lepton-x86_64-steamdeck-$V.install.sh" "$work/held"
expect_fail 'Missing release file' --check --version "$V" --unsigned
mv "$work/held" "$out/lepton-x86_64-steamdeck-$V.install.sh"
echo '# extra' >> "$out/lepton-x86_64-steamdeck-$V.install.sh"
expect_fail 'Checksum verification failed' --check --version "$V" --unsigned
(cd "$out" && sha256sum "lepton-x86_64-steamdeck-$V.tar.gz" "lepton-x86_64-steamdeck-$V.install.sh" > "lepton-x86_64-steamdeck-$V.tar.gz.sha256")
expect_fail 'installer differs' --check --version "$V" --unsigned
make_bundle "$V"
echo "$(printf '0%.0s' {1..64})  other.sh" >> "$out/lepton-x86_64-steamdeck-$V.tar.gz.sha256"
expect_fail 'exactly the archive and the installer' --check --version "$V" --unsigned
for extra in tools/platform-tools/adb compat_tool/images/rootfs/vendor/apex/com.google.android.widevine.apex \
             compat_tool/images/rootfs/system/lib64/libndk_translation.so \
             compat_tool/images/rootfs/system/product/priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk \
             tools/signing-key; do
    make_bundle "$V" "" "$extra"
    expect_fail 'must not include' --check --version "$V" --unsigned
done
GAPPS=true make_bundle "$V"; expect_fail 'not describe a base bundle' --check --version "$V" --unsigned
BUNDLE_ID=v0.0.9 make_bundle "$V"; expect_fail 'not describe a base bundle' --check --version "$V" --unsigned
TREE=dirty make_bundle "$V"; expect_fail 'uncommitted changes; rebuild' --check --version "$V" --unsigned
# Image provenance: present, clean, patches applied, same build, same inputs.
NO_IMAGE_INFO=1 make_bundle "$V"; expect_fail 'no tools/IMAGE-PROVENANCE.txt' --check --version "$V" --unsigned
IMAGE_INPUTS=modified make_bundle "$V"; expect_fail 'uncommitted changes to their inputs' --check --version "$V" --unsigned
IMAGE_PATCHES='missing (0001-mesa-android-sdk34-link-libzstd.patch)' make_bundle "$V"
expect_fail 'Lepton patches were not applied' --check --version "$V" --unsigned
IMAGE_PROP="$(printf '0%.0s' {1..64})" make_bundle "$V"; expect_fail 'different image build' --check --version "$V" --unsigned
IMAGE_COMMIT="$(printf 'a%.0s' {1..40})" make_bundle "$V"; expect_fail 'unknown image source commit' --check --version "$V" --unsigned
# Images from an earlier commit are fine if only non-image files changed since...
image_commit="$(git -C "$fake" rev-parse HEAD)"
echo '# docs' >> "$fake/.github/RELEASE_TEMPLATE.md"; git -C "$fake" commit -qam docs
git -C "$fake" push -q github main && git -C "$fake" fetch -q github
IMAGE_COMMIT="$image_commit" make_bundle "$V"
publish --check --version "$V" --unsigned || { cat "$work/out.log"; exit 1; }
grep -q "Android images built from $image_commit" "$work/out.log"
# ...but not if an image input (here a patch) changed.
echo '# changed' >> "$fake/image-14/patches/0001-mesa-android-sdk34-link-libzstd.patch"
git -C "$fake" commit -qam patch && git -C "$fake" push -q github main && git -C "$fake" fetch -q github
IMAGE_COMMIT="$image_commit" make_bundle "$V"; expect_fail 'image inputs changed between' --check --version "$V" --unsigned
make_bundle "$V"
LEPTON_TEST_MAX_ASSET_BYTES=10 expect_fail 'under 2 GiB' --check --version "$V" --unsigned
expect_fail 'is not the bundle' --check --version "$V" --unsigned --commit 'HEAD^{tree}'
echo change >> "$fake/.github/RELEASE_TEMPLATE.md"; git -C "$fake" commit -qam unpushed
make_bundle "$V"
expect_fail 'is not on github/main' --check --version "$V" --unsigned
git -C "$fake" push -q github main && git -C "$fake" fetch -q github
git -C "$fake" tag "$V" HEAD~1
expect_fail "Local tag $V points at" --check --version "$V" --unsigned
git -C "$fake" tag -d "$V" > /dev/null
[[ "$(mutations)" == 0 ]]

# --execute: a draft prerelease with exactly the three files, verified.
make_bundle "$V"
commit="$(git -C "$fake" rev-parse HEAD)"
publish --execute --version "$V" --unsigned || { cat "$work/out.log"; exit 1; }
grep -q "Draft release $V is ready for review" "$work/out.log"
[[ "$(release_field "$V" 'r["draft"], r["prerelease"], r["target_commitish"]')" == "(True, True, '$commit')" ]]
[[ "$(release_field "$V" 'sorted(a["name"] for a in r["assets"])')" == \
   "['lepton-x86_64-steamdeck-$V.install.sh', 'lepton-x86_64-steamdeck-$V.tar.gz', 'lepton-x86_64-steamdeck-$V.tar.gz.sha256']" ]]
release_field "$V" 'r["body"]' | grep -q "Source commit: \`$commit\`"
release_field "$V" 'r["body"]' | grep -q 'NOT signed'
# Running it again resumes: nothing is uploaded twice.
uploads="$(grep -c '^release upload' "$FAKE_GH_LOG")"
publish --execute --version "$V" --unsigned || { cat "$work/out.log"; exit 1; }
grep -q 'Already uploaded' "$work/out.log"
[[ "$(grep -c '^release upload' "$FAKE_GH_LOG")" == "$uploads" && "$(grep -c '^release create' "$FAKE_GH_LOG")" == 1 ]]

# An interrupted upload is detected and only replaced on request.
W=v0.1.1-alpha
make_bundle "$W"
FAKE_GH_TRUNCATE="lepton-x86_64-steamdeck-$W.tar.gz" expect_fail 'do not match the local files' --execute --version "$W" --unsigned
expect_fail 'rerun with --replace-draft-assets' --execute --version "$W" --unsigned
publish --execute --version "$W" --unsigned --replace-draft-assets || { cat "$work/out.log"; exit 1; }
grep -q -- '--clobber' "$FAKE_GH_LOG"
[[ "$(release_field "$W" 'all(a["state"] == "uploaded" for a in r["assets"])')" == True ]]

# --publish: prerelease, not "latest"; a published release is never changed again.
make_bundle v0.2.0
expect_fail 'No draft release v0.2.0 to publish' --publish --version v0.2.0 --unsigned
publish --publish --version "$V" --unsigned || { cat "$work/out.log"; exit 1; }
grep -q "Published $V (prerelease)" "$work/out.log"
[[ "$(release_field "$V" 'r["draft"], r["prerelease"], r["latest"]')" == "(False, True, False)" ]]
for mode in --check --execute --publish; do
    expect_fail 'already published' "$mode" --version "$V" --unsigned
done
# A stable release becomes "latest".
publish --execute --version v0.2.0 --unsigned && publish --publish --version v0.2.0 --unsigned ||
    { cat "$work/out.log"; exit 1; }
[[ "$(release_field v0.2.0 'r["draft"], r["prerelease"], r["latest"]')" == "(False, False, True)" ]]

# Signing: once allowed_signers lists a key, releases must be signed by it.
ssh-keygen -q -t ed25519 -N '' -C test -f "$work/key"
ssh-keygen -q -t ed25519 -N '' -C other -f "$work/other-key"
printf 'lepton-release namespaces="lepton-release" %s\n' "$(cut -d' ' -f1,2 "$work/key.pub")" \
    >> "$fake/compat_tool/release-keys/allowed_signers"
git -C "$fake" commit -qam 'add release key' && git -C "$fake" push -q github main && git -C "$fake" fetch -q github
S=v0.3.0-alpha
make_bundle "$S"
expect_fail 'sign this release' --check --version "$S" --unsigned
expect_fail 'not listed in allowed_signers' --check --version "$S" --signing-key "$work/other-key"
publish --check --version "$S" --signing-key "$work/key" || { cat "$work/out.log"; exit 1; }
[[ ! -e "$out/lepton-x86_64-steamdeck-$S.tar.gz.sha256.sig" ]]   # --check does not sign
publish --execute --version "$S" --signing-key "$work/key" || { cat "$work/out.log"; exit 1; }
sig="$out/lepton-x86_64-steamdeck-$S.tar.gz.sha256.sig"
ssh-keygen -Y verify -f "$fake/compat_tool/release-keys/allowed_signers" -I lepton-release -n lepton-release \
    -s "$sig" < "$out/lepton-x86_64-steamdeck-$S.tar.gz.sha256" > /dev/null
[[ "$(release_field "$S" 'len(r["assets"])')" == 4 ]]
release_field "$S" 'r["body"]' | grep -q 'Signed:'
publish --publish --version "$S" || { cat "$work/out.log"; exit 1; }   # existing signature is checked
# A signature by an untrusted key is refused.
T=v0.3.1-alpha
make_bundle "$T"
cp "$out/lepton-x86_64-steamdeck-$T.tar.gz.sha256" "$work/m"
ssh-keygen -q -Y sign -f "$work/other-key" -n lepton-release "$work/m"
mv "$work/m.sig" "$out/lepton-x86_64-steamdeck-$T.tar.gz.sha256.sig"
expect_fail 'is not a valid signature' --check --version "$T"
echo 'PASS: publish-release: read-only --check, refusals (dirty tree, files, checksums, contents, provenance, branch, tag, size, signing), draft creation and verified upload, resume, interrupted upload, publish (prerelease/latest), no changes to published releases, signed releases'
