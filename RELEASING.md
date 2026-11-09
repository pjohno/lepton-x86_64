# Releasing Lepton x86_64

This guide publishes a tested base bundle as a GitHub Release at
<https://github.com/pjohno/lepton-x86_64/releases>. Users install a release
as described in
[INSTALL-STEAM-DECK.md](INSTALL-STEAM-DECK.md#install-from-github-releases).

The publisher, `image-14/scripts/publish-release.sh`, never builds Android or
bundles; it only uploads files you've already built and tested. No GitHub
Actions job builds Android.

## Release files and versions

A release of version `VERSION` contains exactly:

| File | Made by |
| --- | --- |
| `lepton-x86_64-steamdeck-VERSION.tar.gz` | `make-deck-bundle-x86_64.sh --bundle-id VERSION` |
| `lepton-x86_64-steamdeck-VERSION.tar.gz.sha256` | the same; SHA256 of the archive **and** the installer |
| `lepton-x86_64-steamdeck-VERSION.install.sh` | the same (`compat_tool/tools/lepton-install-bundle`) |
| `lepton-x86_64-steamdeck-VERSION.tar.gz.sha256.sig` | `publish-release.sh --execute`, when signing |

**Versions** are [Semantic Versioning 2.0](https://semver.org) with a leading
`v` and no build metadata: `v0.1.0-alpha`, `v0.1.0-alpha.2`, `v0.2.0-beta.1`,
`v1.0.0`.
- The version is also the bundle ID and the Git tag.
- The installed Steam tool ID is `lepton_x86_64_` plus the version, with `.`
  and `-` replaced by `_` (for example `lepton_x86_64_v0_1_0_alpha`).
- A version with a `-` part (alpha, beta, rc) is published as a GitHub
  **prerelease**.

The release manager orders versions by SemVer precedence, never alphabetically:
- numbers compare as numbers;
- a prerelease comes before its release: `v0.2.0-alpha` < `v0.2.0`;
- prerelease parts compare one by one: numeric parts before words, numbers as
  numbers, and more parts after fewer.

So `v0.1.0-alpha` < `v0.1.0-alpha.2` < `v0.1.0-alpha.10` < `v0.1.0-beta` <
`v0.1.0` < `v0.10.0`.

**Release contents.** A release contains the base bundle only:
- **No Google files in the archive:**
  - no Google host `adb` (the installer downloads it);
  - no GApps;
  - no NDK translation;
  - no Widevine.
- **No local data:** no saved profiles, build workspaces or keys.

The publisher refuses an archive containing any of these. It also checks that
the bundle's `BUNDLE.json` says `gapps: false` and `ndk: false`.

## Launcher-only releases using a validated stage

Launcher fixes can reuse the tested Android system and sysbake. Do not run the
full bundle pipeline for these updates: it creates a new sysbake. Record full
rootfs/sysbake manifests and compatibility-input hashes before packaging, then
use the existing stage read-only:

```bash
bash image-14/scripts/internal/deploy-compat-x86_64.sh --package-only --execute \
  --stage-dir "$VALIDATED_STAGE" --bundle-dir "$RELEASE_BUNDLE_DIR" \
  --bundle-id v0.1.1-alpha
```

This refreshes host runtime scripts and injected launcher hooks in a temporary
payload. It does not prepare Android or regenerate sysbake. Compare the archive's
complete Android contents against the baseline, recheck the source stage, and
verify the packaged scripts against the reviewed checkout. Stop on unexplained
Android differences. Release/tool identity changes alone must not reset game
profiles. See [PERSISTENCE-SAFETY.md](PERSISTENCE-SAFETY.md) for the validation
report and outstanding Deck gates. The existing checksum/signing and approval
requirements still apply.

## Release workflow

Run everything from a clean checkout of the repository on the build machine,
with the GitHub CLI (`gh`) signed in (`gh auth login`).

### 1. Merge into `main` and push it

The release commit is the commit the bundle is made from. It must be on the
`github` remote's `main` branch:
```bash
git switch main && git pull && git push github main
```

### 2. Build the Android images

Build them from the release commit's checkout (with its submodules checked
out), so they record what they were built from in `images/BUILD-INFO.txt`:
the commit, whether the image inputs (device files, Waydroid and Valve
projects, patches) had uncommitted changes, whether the folders copied into
the Android checkout still match the repository, and whether every Lepton
patch is applied. After changes to the image or patches, run
`prepare-x86_64.sh --reset` first; see [BUILDING.md](BUILDING.md). Without
changes the build is quick (nothing is recompiled).
```bash
bash image-14/scripts/build-images-x86_64.sh --execute
```

The bundle carries this record as `tools/IMAGE-PROVENANCE.txt`. The publisher
refuses a release whose images were built with modified inputs, without every
patch applied, or from a commit whose image inputs differ from the release
commit's. Images built at an earlier commit are accepted when only other files
(scripts, docs) changed since.

### 3. Make the versioned base bundle

Make it from that exact commit, with no uncommitted changes. The bundle records
its commit and "clean" in `tools/BUNDLE-PROVENANCE.txt`, and the publisher
checks both.
```bash
git status --short          # must print nothing
bash image-14/scripts/make-deck-bundle-x86_64.sh --execute --bundle-id v0.1.0-alpha
```

### 4. Run the automated checks
```bash
bash image-14/tests/run-workflow-tests.sh
```

### 5. Test the bundle on a Steam Deck

Install it the way users will: copy the three files to the Deck's `Downloads`
and run `bash lepton-x86_64-steamdeck-v0.1.0-alpha.install.sh`. Then check:
- "Lepton: Check graphics" (RADV);
- a few APK and APKM games;
- **Lepton: Install / Update / Repair** opens.

### 6. Check provenance and licences

Read the archive's `tools/PROVENANCE.txt` and `tools/BUNDLE-PROVENANCE.txt`.
Make sure the licences in `LICENSES/` and the bundle's `tools/licenses/` cover
what is shipped. Make sure no file came from a source you can't redistribute.

### 7. Check, sign, draft and upload

```bash
bash image-14/scripts/publish-release.sh --check   --version v0.1.0-alpha --signing-key ~/.config/lepton-release/signing-key
bash image-14/scripts/publish-release.sh --execute --version v0.1.0-alpha --signing-key ~/.config/lepton-release/signing-key
```

**`--check` changes nothing.** It verifies:
- the repository and the `gh` sign-in;
- a clean checkout;
- that the bundle's commit is on `github/main`, and that any existing tag
  points at it;
- that exactly the three files are present, and their checksums;
- that the installer is byte-identical to the one in the commit;
- the contents rules above;
- that each file is under GitHub's 2 GiB limit;
- the signature setup;
- that no **published** release with this version exists.

**`--execute`:**
1. signs the `.sha256` file (with `--signing-key`);
2. creates a **draft** release targeting the bundle's commit, with notes filled
   in from [.github/RELEASE_TEMPLATE.md](.github/RELEASE_TEMPLATE.md);
3. uploads the files;
4. verifies each uploaded file's name and size, and its SHA256 when GitHub
   reports one;
5. prints the draft's address.

Drafts are invisible to users and to the release manager. If the upload is
interrupted, run `--execute` again:
- files already uploaded and identical are skipped;
- a file that differs (for example a partial upload) is only replaced with
  `--replace-draft-assets`, and only on a draft.

Until a release key exists (see below), use `--unsigned` instead of
`--signing-key`.

### 8. Review the release notes

Open the draft on GitHub:
- **Edit the notes:** replace the closing comment with the changes since the
  previous release, and check the known limitations.
- **Check the files:** the draft must list the expected files.

### 9. Publish
```bash
bash image-14/scripts/publish-release.sh --publish --version v0.1.0-alpha
```

This checks everything again, including that the draft's files match the local
ones, and then publishes the draft:
- **Alpha, beta and rc versions:** published as prereleases, and never marked
  "latest".
- **Stable versions:** marked "latest".

GitHub creates the tag `v0.1.0-alpha` at the release commit when the release is
published.

**Once published, a release is never changed by the script.** `--check`,
`--execute` and `--publish` all refuse that version. To fix a published
release, publish a new version.

**What is never uploaded:** only the release files listed above are uploaded.
Workspaces, stages, Google inputs, signing keys and credentials never are.

## First stable release

The release manager preselects the newest alpha while `ALPHA_PERIOD = True`
in `compat_tool/tools/lepton-release-manager`. Set it to `False` (and raise
`MANAGER_VERSION`) in the commit for the first stable release, so stable
releases become the default choice.

## Release signing

**Mechanism:**
- Releases are signed with an OpenSSH key (`ssh-keygen -Y sign`, namespace
  `lepton-release`). This works on SteamOS without extra software.
- The signature covers the `.sha256` file, which lists the SHA256 of the archive
  and the installer, so it authenticates both.
- The public keys the release manager trusts are in
  [compat_tool/release-keys/allowed_signers](compat_tool/release-keys/allowed_signers),
  and every bundle installs them with the manager.

**Never commit a private key.** Keep it outside the repository (for example in
`~/.config/lepton-release/`), with a passphrase, and keep a backup offline.

**Create the first key** (once):
```bash
mkdir -p ~/.config/lepton-release && chmod 700 ~/.config/lepton-release
ssh-keygen -t ed25519 -C "lepton-release-$(date +%Y)" -f ~/.config/lepton-release/signing-key
printf 'lepton-release namespaces="lepton-release" %s\n' \
    "$(cut -d' ' -f1-3 ~/.config/lepton-release/signing-key.pub)" >> compat_tool/release-keys/allowed_signers
git commit -m "release: add release signing key" compat_tool/release-keys/allowed_signers
```

**The order matters.** The key must be in `allowed_signers` in the release
commit, because that's the file the release's own manager will use. The
publisher checks this. It also refuses to publish **unsigned** releases from
then on, because the release manager rejects them.

**Verify a release by hand:**
```bash
ssh-keygen -Y verify -f allowed_signers -I lepton-release -n lepton-release \
    -s lepton-x86_64-steamdeck-VERSION.tar.gz.sha256.sig < lepton-x86_64-steamdeck-VERSION.tar.gz.sha256
sha256sum --check lepton-x86_64-steamdeck-VERSION.tar.gz.sha256
```

**Key rotation:**
1. Create the new key, and add its line to `allowed_signers` next to the old
   one. You can add `valid-after="YYYYMMDD"` to the new key.
2. Publish a release signed with the **old** key. Installing it gives users a
   manager that trusts both keys.
3. Sign the following releases with the new key.
4. Later, remove the old key, or limit it with `valid-before="YYYYMMDD"`.

**If a key is lost or stolen:**
1. Remove it from `allowed_signers`, add a new key, and publish a release signed
   with the new key.
2. Tell users. Their installed manager doesn't trust the new key yet, so the new
   release must be installed by hand once, as a **first installation**, from
   the GitHub page.
3. If the key was stolen, also review recent releases, and delete any that you
   didn't publish.

No trust is ever added silently: the manager never learns a key from a
download.

## Trust model

| Step | What protects it | What it does not cover |
| --- | --- | --- |
| First installation | HTTPS download from the GitHub project page; the installer checks the archive against its `.sha256` | A compromised GitHub account could replace all three files together |
| Release manager, signed release | Signature by a key in the installed `allowed_signers`; then SHA256 of each file; no redirects outside GitHub's hosts | A stolen signing key (see above) |
| Release manager, unsigned release | SHA256 of each file (detects damaged downloads) | Authenticity: the user is told so and must confirm before the installer runs |
| Google ADB | Pinned SHA256 and version in the installer | — |

The manager makes sure nothing downloaded runs before it is verified:
- files keep temporary names until they're verified;
- the installer's checksum is checked again just before it runs;
- the installer runs as the user, never as root.

## Updating the release manager

`compat_tool/tools/lepton-release-manager` has a `MANAGER_VERSION` number.
**Increase it whenever the file (or the `lepton-manage-installs` copy it uses)
changes.**

**How installers update it:**
- Every bundle installer copies the manager into
  `~/.local/share/lepton-release-manager/`, together with `allowed_signers`,
  but only if its copy is the same version or newer. An older release never
  downgrades it.
- Files are replaced by renaming, so a copy that's running is unaffected.
- Users therefore get a new manager by installing (or repairing) any newer
  release.
- The manager doesn't download or update itself in any other way.

**When it's removed:** `deck-clean-slate.sh` removes the manager with
everything else. **Lepton: Remove installs** never removes it.

## Troubleshooting the publisher

| Message | Fix |
| --- | --- |
| `is not on github/main` | Push the commit (and `git fetch github`), or make the bundle from a pushed commit |
| `made from a checkout with uncommitted changes` | Commit, then make the bundle again |
| `installer differs` | The bundle was made with a different installer; make it again from the release commit |
| `The existing draft targets …` | Delete the draft on GitHub (or fix its target) and run `--execute` again |
| `differs … --replace-draft-assets` | A file of the draft is incomplete or different; run `--execute --replace-draft-assets` |
| `already published` | Published releases are final; release a new version |
