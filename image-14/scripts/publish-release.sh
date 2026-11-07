#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Publish a previously built and tested Lepton base bundle as a GitHub Release.
# Never builds Android or bundles; uploads only the release files.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
REPO='pjohno/lepton-x86_64'
REMOTE=''
BRANCH='main'
MODE=''
VERSION=''
BUNDLE_DIR=''
COMMIT_ARG=''
SIGNING_KEY="${LEPTON_RELEASE_SIGNING_KEY:-}"
UNSIGNED=false
ALLOW_DIRTY=false
REPLACE_DRAFT_ASSETS=false
NOTES_FILE=''
# GitHub: each release asset must be under 2 GiB (test hook: a smaller limit).
MAX_ASSET_BYTES="${LEPTON_TEST_MAX_ASSET_BYTES:-$((2 * 1024 * 1024 * 1024 - 1))}"
NAMESPACE='lepton-release'

usage() {
    cat <<'HELP'
Usage: bash image-14/scripts/publish-release.sh --check|--execute|--publish --version vX.Y.Z[-PRE] [options]

  --check     Validate everything (repository, sign-in, source commit, bundle
              files, checksums, contents, signature, release state); changes nothing
  --execute   Run the checks, create a DRAFT GitHub Release (or resume one) and
              upload and verify the release files
  --publish   Run the checks again and publish a reviewed draft (alpha/beta/rc
              versions are published as prereleases)

Options:
  --version V          Release version and bundle ID, e.g. v0.1.0-alpha (required)
  --bundle-dir DIR     Where the bundle files are (default: workspace bundles/)
  --commit SHA         Expected source commit (default: the bundle's own
                       recorded commit; both must agree)
  --branch NAME        Branch that must contain the commit (default: main)
  --remote NAME        Git remote of the GitHub repository (default: found by URL)
  --signing-key FILE   OpenSSH private key for the release signature (or
                       LEPTON_RELEASE_SIGNING_KEY); its public key must be in
                       compat_tool/release-keys/allowed_signers at the release commit
  --unsigned           Allow an unsigned release (only while allowed_signers lists
                       no key; users are then asked to confirm before installing)
  --notes-file FILE    Release notes (default: .github/RELEASE_TEMPLATE.md, filled in)
  --replace-draft-assets  Replace files of an existing DRAFT that differ from the
                       local ones (never touches a published release)
  --allow-dirty        Allow uncommitted changes in this checkout (not recommended)

Release files (exactly these, from make-deck-bundle-x86_64.sh --bundle-id VERSION):
  lepton-x86_64-steamdeck-VERSION.tar.gz
  lepton-x86_64-steamdeck-VERSION.tar.gz.sha256
  lepton-x86_64-steamdeck-VERSION.install.sh
  lepton-x86_64-steamdeck-VERSION.tar.gz.sha256.sig   (the signature, if signed)
See RELEASING.md for the whole workflow.
HELP
}
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }
pass() { printf '[PASS] %s\n' "$*"; }
step() { printf '\n=== %s ===\n' "$*"; }

while (($#)); do
    case "$1" in
        --check|--execute|--publish) [[ -z "$MODE" ]] || fail 'Choose one of --check, --execute, --publish'; MODE="${1#--}"; shift ;;
        --version) VERSION="${2:?--version requires a value}"; shift 2 ;;
        --bundle-dir) BUNDLE_DIR="${2:?--bundle-dir requires DIR}"; shift 2 ;;
        --commit) COMMIT_ARG="${2:?--commit requires SHA}"; shift 2 ;;
        --branch) BRANCH="${2:?--branch requires NAME}"; shift 2 ;;
        --remote) REMOTE="${2:?--remote requires NAME}"; shift 2 ;;
        --signing-key) SIGNING_KEY="${2:?--signing-key requires FILE}"; shift 2 ;;
        --unsigned) UNSIGNED=true; shift ;;
        --notes-file) NOTES_FILE="${2:?--notes-file requires FILE}"; shift 2 ;;
        --replace-draft-assets) REPLACE_DRAFT_ASSETS=true; shift ;;
        --allow-dirty) ALLOW_DIRTY=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "Unknown argument: $1" ;;
    esac
done
[[ -n "$MODE" && -n "$VERSION" ]] || { usage >&2; fail 'A mode and an explicit --version are required'; }
# SemVer 2.0 with a leading v and no build metadata; must also be a bundle ID.
python3 -c '
import re, sys
ident = r"(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
pattern = r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-%s(?:\.%s)*)?" % (ident, ident)
sys.exit(0 if re.fullmatch(pattern, sys.argv[1]) and len(sys.argv[1]) <= 64 else 1)' "$VERSION" ||
    fail "Version must look like v0.1.0, v0.1.0-alpha or v0.2.0-beta.2 (got: $VERSION)"
PRERELEASE=false
[[ "$VERSION" != *-* ]] || PRERELEASE=true
for program in git gh python3 tar gzip sha256sum ssh-keygen; do
    command -v "$program" >/dev/null || fail "Missing required program: $program"
done
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

step 'Repository and GitHub sign-in'
cd -- "$ROOT"
if [[ -z "$REMOTE" ]]; then
    for name in $(git remote); do
        url="$(git config --get "remote.$name.url" || true)"
        if [[ "$url" =~ github\.com[:/]${REPO}(\.git)?/?$ ]]; then REMOTE="$name"; break; fi
    done
fi
[[ -n "$REMOTE" ]] || fail "No git remote points at github.com/$REPO (use --remote NAME)"
[[ "$(git config --get "remote.$REMOTE.url")" =~ github\.com[:/]${REPO}(\.git)?/?$ ]] ||
    fail "Remote $REMOTE does not point at github.com/$REPO"
gh auth status --hostname github.com >/dev/null 2>&1 || fail 'GitHub CLI is not signed in: run gh auth login'
[[ "$(gh api "repos/$REPO" --jq .full_name)" == "$REPO" ]] || fail "GitHub does not report repository $REPO"
pass "GitHub repository $REPO (git remote $REMOTE), signed in"
if [[ "$ALLOW_DIRTY" == false && -n "$(git status --porcelain)" ]]; then
    fail 'This checkout has uncommitted changes; commit or stash them (or --allow-dirty)'
fi

step 'Release files'
if [[ -z "$BUNDLE_DIR" ]]; then
    [[ -f "$ROOT/.build-env" ]] || fail "Missing $ROOT/.build-env; pass --bundle-dir"
    # shellcheck source=/dev/null
    source "$ROOT/.build-env"
    source "$ROOT/image-14/scripts/lib/workspace.sh"
    lepton_workspace
    BUNDLE_DIR="$LEPTON_DECK_BUNDLE_DIR"
fi
BUNDLE_DIR="$(realpath -e -- "$BUNDLE_DIR")" || fail "Bundle directory not found: $BUNDLE_DIR"
NAME="lepton-x86_64-steamdeck-$VERSION"
ARCHIVE="$BUNDLE_DIR/$NAME.tar.gz"
MANIFEST="$ARCHIVE.sha256"
INSTALLER="$BUNDLE_DIR/$NAME.install.sh"
SIGNATURE="$MANIFEST.sig"
for file in "$ARCHIVE" "$MANIFEST" "$INSTALLER"; do
    [[ -f "$file" && ! -L "$file" ]] || fail "Missing release file: $file (make it with make-deck-bundle-x86_64.sh --bundle-id $VERSION)"
done
for file in "$ARCHIVE" "$MANIFEST" "$INSTALLER"; do
    size="$(stat -c %s "$file")"
    (( size > 0 && size <= MAX_ASSET_BYTES )) || fail "$(basename -- "$file") is $size bytes; GitHub release files must be under 2 GiB"
done
python3 - "$MANIFEST" "$NAME" <<'PY' || fail 'The .sha256 file must list exactly the archive and the installer'
import re, sys
names = set()
for line in open(sys.argv[1], encoding="utf-8"):
    if line.strip():
        m = re.fullmatch(r"[0-9a-f]{64} [ *](\S+)", line.strip())
        if not m: sys.exit(1)
        names.add(m.group(1))
sys.exit(0 if names == {sys.argv[2] + ".tar.gz", sys.argv[2] + ".install.sh"} else 1)
PY
info "Verifying checksums (reads the whole archive)"
( cd "$BUNDLE_DIR" && sha256sum --check --quiet "$NAME.tar.gz.sha256" ) || fail 'Checksum verification failed'
pass "$NAME: archive and installer match the .sha256 file"

step 'Bundle contents and provenance'
tar -xzOf "$ARCHIVE" ./BUNDLE.json > "$WORK/BUNDLE.json" 2>/dev/null || fail 'Archive has no BUNDLE.json'
tar -xzOf "$ARCHIVE" ./tools/BUNDLE-PROVENANCE.txt > "$WORK/provenance" 2>/dev/null ||
    fail 'Archive has no tools/BUNDLE-PROVENANCE.txt (bundle made before provenance was recorded)'
tar -tzf "$ARCHIVE" > "$WORK/contents"
python3 - "$WORK/BUNDLE.json" "$VERSION" <<'PY' || fail 'BUNDLE.json does not describe a base bundle of this version'
import json, re, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
version = sys.argv[2]
problems = []
if m.get("bundle_id") != version: problems.append("bundle_id is %r" % m.get("bundle_id"))
if m.get("tool_id") != "lepton_x86_64_" + re.sub(r"[.-]", "_", version): problems.append("tool_id is %r" % m.get("tool_id"))
if m.get("gapps") or m.get("ndk"): problems.append("it contains GApps or NDK translation")
for p in problems: print("  " + p, file=sys.stderr)
sys.exit(1 if problems else 0)
PY
# Base releases never contain Google's host adb, Google apps, NDK translation,
# Widevine, saved profiles, build workspaces or keys.
python3 - "$WORK/contents" > "$WORK/forbidden" <<'PY' || true
import re, sys
rules = [
    (r"(^|/)adb$|^\./tools/platform-tools(/|$)|google-platform-tools-NOTICE", "Google host adb"),
    (r"PrebuiltGmsCore|Phonesky|GoogleServicesFramework|GmsCore", "Google apps (GApps)"),
    (r"ndk_translation|ndk-provenance", "NDK translation"),
    (r"(?i)widevine", "Widevine"),
    (r"\.runtime-profile|podman-storage|lepton-apkm/|apk_extractor/target/", "local workspace data"),
    (r"(^|/)(id_(rsa|ecdsa|ed25519)(\.pub)?|signing-key[^/]*)$", "key material"),
]
for line in open(sys.argv[1], encoding="utf-8"):
    path = line.rstrip("\n")
    for pattern, what in rules:
        if re.search(pattern, path):
            print("%s: %s" % (what, path))
            break
PY
if [[ -s "$WORK/forbidden" ]]; then
    head -n 20 "$WORK/forbidden" >&2
    fail 'The archive contains files a base release must not include (listed above)'
fi
pass 'Base bundle: no Google adb, GApps, NDK translation, Widevine, profiles or keys'
BUNDLE_COMMIT="$(sed -n 's/^Launcher source commit: \([0-9a-f]\{40\}\)$/\1/p' "$WORK/provenance")"
[[ -n "$BUNDLE_COMMIT" ]] || fail 'The bundle does not record its source commit'
grep -qx 'Launcher working tree: clean' "$WORK/provenance" ||
    fail "The bundle was made from a checkout with uncommitted changes; rebuild it from a clean commit"
COMMIT="$BUNDLE_COMMIT"
if [[ -n "$COMMIT_ARG" ]]; then
    [[ "$(git rev-parse --verify --quiet "$COMMIT_ARG^{commit}")" == "$BUNDLE_COMMIT" ]] ||
        fail "--commit $COMMIT_ARG is not the bundle's source commit $BUNDLE_COMMIT"
fi
git cat-file -e "$COMMIT^{commit}" 2>/dev/null || fail "Bundle source commit $COMMIT is not in this repository (git fetch)"
git merge-base --is-ancestor "$COMMIT" "$REMOTE/$BRANCH" 2>/dev/null ||
    fail "Commit $COMMIT is not on $REMOTE/$BRANCH (merge and push it, then git fetch $REMOTE)"
pass "Source commit $COMMIT (clean, on $REMOTE/$BRANCH)"
# The installer must be exactly the one in that commit (with the archive name).
git show "$COMMIT:compat_tool/tools/lepton-install-bundle" |
    sed "s|^DEFAULT_ARCHIVE=''\$|DEFAULT_ARCHIVE='$NAME.tar.gz'|" > "$WORK/expected-installer"
cmp -s "$WORK/expected-installer" "$INSTALLER" ||
    fail "The installer differs from compat_tool/tools/lepton-install-bundle at $COMMIT"
pass 'Installer matches the source commit'
local_tag="$(git rev-parse --verify --quiet "refs/tags/$VERSION^{commit}" || true)"
[[ -z "$local_tag" || "$local_tag" == "$COMMIT" ]] || fail "Local tag $VERSION points at $local_tag, not $COMMIT"
remote_tag="$(git ls-remote --tags "$REMOTE" "refs/tags/$VERSION^{}" "refs/tags/$VERSION" | awk 'NR==1{print $1}')"
if [[ -n "$remote_tag" ]]; then
    peeled="$(git ls-remote --tags "$REMOTE" "refs/tags/$VERSION^{}" | awk '{print $1}')"
    [[ "${peeled:-$remote_tag}" == "$COMMIT" ]] || fail "Tag $VERSION on GitHub points at ${peeled:-$remote_tag}, not $COMMIT"
    pass "Tag $VERSION on GitHub points at the source commit"
else
    info "Tag $VERSION does not exist on GitHub yet; GitHub creates it at $COMMIT when the release is published"
fi

step 'Signature'
git show "$COMMIT:compat_tool/release-keys/allowed_signers" > "$WORK/allowed_signers" 2>/dev/null || : > "$WORK/allowed_signers"
KEYS_LISTED=false
grep -qvE '^[[:space:]]*(#|$)' "$WORK/allowed_signers" && KEYS_LISTED=true
verify_signature() {
    ssh-keygen -Y verify -f "$WORK/allowed_signers" -I "$NAMESPACE" -n "$NAMESPACE" -s "$1" < "$MANIFEST" >/dev/null 2>&1
}
SIGNED=false
if [[ -f "$SIGNATURE" ]]; then
    [[ "$KEYS_LISTED" == true ]] || fail "$(basename -- "$SIGNATURE") exists, but allowed_signers at $COMMIT lists no key to check it"
    verify_signature "$SIGNATURE" || fail "$(basename -- "$SIGNATURE") is not a valid signature by a key in allowed_signers"
    SIGNED=true
    pass 'Existing signature verified against allowed_signers at the source commit'
elif [[ -n "$SIGNING_KEY" ]]; then
    [[ -f "$SIGNING_KEY" ]] || fail "Signing key not found: $SIGNING_KEY"
    [[ "$KEYS_LISTED" == true ]] || fail 'allowed_signers at the source commit lists no key; users could not verify this signature'
    public="$(ssh-keygen -y -f "$SIGNING_KEY" 2>/dev/null | awk '{print $1, $2}')" ||
        fail 'Cannot read the public key of the signing key'
    grep -Fq "$public" "$WORK/allowed_signers" || fail 'The signing key is not listed in allowed_signers at the source commit'
    pass 'Signing key is trusted by the release manager at the source commit'
    SIGNED=pending
elif [[ "$KEYS_LISTED" == true ]]; then
    fail 'allowed_signers lists a release key: sign this release (--signing-key FILE); the release manager refuses unsigned releases'
elif [[ "$UNSIGNED" == true ]]; then
    info 'UNSIGNED release (--unsigned): users verify checksums only and must confirm before installing'
else
    fail 'No signature: pass --signing-key FILE, or --unsigned while no release key exists (see RELEASING.md)'
fi

step "GitHub release $VERSION"
gh api --paginate "repos/$REPO/releases?per_page=100" --jq '.[]' > "$WORK/releases.jsonl"
python3 - "$WORK/releases.jsonl" "$VERSION" > "$WORK/release.json" <<'PY'
import json, sys
found = None
for line in open(sys.argv[1], encoding="utf-8"):
    if line.strip():
        item = json.loads(line)
        if item.get("tag_name") == sys.argv[2]:
            found = item
print(json.dumps(found))
PY
STATE="$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print("none" if r is None else ("draft" if r["draft"] else "published"))' "$WORK/release.json")"
[[ "$STATE" != published ]] || fail "Release $VERSION is already published; it is never changed by this script"
if [[ "$STATE" == draft ]]; then
    target="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("target_commitish",""))' "$WORK/release.json")"
    [[ "$target" == "$COMMIT" ]] || fail "The existing draft targets $target, not $COMMIT; delete or fix the draft on GitHub"
    info "A draft release $VERSION exists (resuming)"
else
    info "No release $VERSION on GitHub yet"
fi

# Compare the draft's files with the local ones: prints one line per file:
# same / missing / differs / unexpected.
compare_assets() {
    python3 - "$1" "$ARCHIVE" "$MANIFEST" "$INSTALLER" "$SIGNATURE" <<'PY'
import hashlib, json, os, sys
release = json.load(open(sys.argv[1]))
local = {os.path.basename(p): p for p in sys.argv[2:] if os.path.isfile(p)}
assets = {a["name"]: a for a in (release or {}).get("assets", [])}
for name in sorted(set(local) | set(assets)):
    if name not in local:
        print("unexpected", name); continue
    asset = assets.get(name)
    if asset is None:
        print("missing", name); continue
    ok = asset.get("state", "uploaded") == "uploaded" and asset.get("size") == os.path.getsize(local[name])
    digest = asset.get("digest") or ""
    if ok and digest.startswith("sha256:"):
        h = hashlib.sha256()
        with open(local[name], "rb") as f:
            for block in iter(lambda: f.read(1 << 20), b""):
                h.update(block)
        ok = digest == "sha256:" + h.hexdigest()
    print("same" if ok else "differs", name)
PY
}

if [[ "$MODE" == check ]]; then
    [[ "$STATE" == none ]] || compare_assets "$WORK/release.json" | sed 's/^/[INFO]   draft file: /'
    printf '\n[PASS] Release %s is ready (%s); nothing was changed.\n' "$VERSION" \
        "$([[ "$PRERELEASE" == true ]] && echo prerelease || echo stable)"
    exit 0
fi

if [[ "$MODE" == publish ]]; then
    [[ "$STATE" == draft ]] || fail "No draft release $VERSION to publish; run --execute first"
    compare_assets "$WORK/release.json" > "$WORK/compare"
    if grep -qv '^same ' "$WORK/compare"; then
        sed 's/^/  /' "$WORK/compare" >&2
        fail 'The draft files do not match the local release files; run --execute again'
    fi
    [[ "$SIGNED" != pending ]] || fail 'The draft has no signature yet; run --execute first'
    latest=true; [[ "$PRERELEASE" == false ]] || latest=false
    gh release edit "$VERSION" --repo "$REPO" --draft=false --prerelease="$PRERELEASE" --latest="$latest" >/dev/null
    url="$(gh release view "$VERSION" --repo "$REPO" --json url --jq .url)"
    printf '\n[PASS] Published %s (%s) at %s\n' "$VERSION" \
        "$([[ "$PRERELEASE" == true ]] && echo prerelease || echo stable)" "$url"
    exit 0
fi

# --execute: sign, create the draft, upload, verify.
if [[ "$SIGNED" == pending ]]; then
    cp -- "$MANIFEST" "$WORK/$NAME.tar.gz.sha256"
    ssh-keygen -Y sign -f "$SIGNING_KEY" -n "$NAMESPACE" "$WORK/$NAME.tar.gz.sha256" >/dev/null ||
        fail 'Signing failed'
    verify_signature "$WORK/$NAME.tar.gz.sha256.sig" || fail 'The new signature does not verify'
    install -m 644 "$WORK/$NAME.tar.gz.sha256.sig" "$SIGNATURE"
    SIGNED=true
    pass "Signed: $(basename -- "$SIGNATURE")"
fi
if [[ "$STATE" == none ]]; then
    if [[ -z "$NOTES_FILE" ]]; then
        NOTES_FILE="$WORK/notes.md"
        auth='Signed: the release manager checks the signature before installing.'
        [[ "$SIGNED" == true ]] || auth='NOT signed: checksums only; the release manager asks for confirmation before installing.'
        python3 - "$ROOT/.github/RELEASE_TEMPLATE.md" "$VERSION" "$COMMIT" "$auth" > "$NOTES_FILE" <<'PY'
import sys, time
text = open(sys.argv[1], encoding="utf-8").read()
for key, value in (("VERSION", sys.argv[2]), ("COMMIT", sys.argv[3]), ("AUTHENTICATION", sys.argv[4]),
                   ("DATE", time.strftime("%Y-%m-%d"))):
    text = text.replace("{{%s}}" % key, value)
print(text, end="")
PY
    fi
    prerelease_flag=()
    [[ "$PRERELEASE" == false ]] || prerelease_flag=(--prerelease)
    gh release create "$VERSION" --repo "$REPO" --draft --target "$COMMIT" \
        --title "Lepton x86_64 $VERSION" --notes-file "$NOTES_FILE" "${prerelease_flag[@]}" >/dev/null
    pass "Created draft release $VERSION (target $COMMIT)"
    gh api --paginate "repos/$REPO/releases?per_page=100" --jq '.[]' > "$WORK/releases.jsonl"
    python3 - "$WORK/releases.jsonl" "$VERSION" > "$WORK/release.json" <<'PY'
import json, sys
print(json.dumps(next((json.loads(l) for l in open(sys.argv[1]) if l.strip()
                       and json.loads(l).get("tag_name") == sys.argv[2]), None)))
PY
fi
compare_assets "$WORK/release.json" > "$WORK/compare"
if grep -q '^unexpected ' "$WORK/compare"; then
    sed -n 's/^unexpected /  /p' "$WORK/compare" >&2
    fail 'The draft has files that are not release files (listed above); delete them on GitHub'
fi
upload=()
clobber=()
while read -r status name; do
    case "$status" in
        missing) upload+=("$BUNDLE_DIR/$name") ;;
        differs)
            [[ "$REPLACE_DRAFT_ASSETS" == true ]] ||
                fail "The draft's $name differs from the local file (interrupted upload?); rerun with --replace-draft-assets"
            upload+=("$BUNDLE_DIR/$name"); clobber=(--clobber) ;;
        same) info "Already uploaded: $name" ;;
    esac
done < "$WORK/compare"
if ((${#upload[@]})); then
    info "Uploading ${#upload[@]} file(s)"
    gh release upload "$VERSION" --repo "$REPO" "${clobber[@]}" "${upload[@]}"
fi
gh api --paginate "repos/$REPO/releases?per_page=100" --jq '.[]' > "$WORK/releases.jsonl"
python3 - "$WORK/releases.jsonl" "$VERSION" > "$WORK/release.json" <<'PY'
import json, sys
print(json.dumps(next((json.loads(l) for l in open(sys.argv[1]) if l.strip()
                       and json.loads(l).get("tag_name") == sys.argv[2]), None)))
PY
compare_assets "$WORK/release.json" > "$WORK/compare"
if grep -qv '^same ' "$WORK/compare"; then
    sed 's/^/  /' "$WORK/compare" >&2
    fail 'Uploaded files do not match the local files (see above); rerun --execute'
fi
pass 'Uploaded files verified (names, sizes and SHA256 where GitHub reports it)'
url="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("html_url",""))' "$WORK/release.json")"
cat <<EOF

[DONE] Draft release $VERSION is ready for review: $url
  Source commit: $COMMIT
  Files: $(sed 's/^same //' "$WORK/compare" | paste -sd' ')
  Signature: $([[ "$SIGNED" == true ]] && echo signed || echo 'NOT signed (--unsigned)')
Review the notes on GitHub, then publish:
  bash image-14/scripts/publish-release.sh --publish --version $VERSION
EOF
