# Phase 4 end-to-end tests (pending)

Branch `feat/bundle-ndk-compat-shim`. Roles:

- **Build machine:** has the AOSP checkout and makes the new base bundle.
- **Linux PC:** Fedora, no AOSP. Runs Tests A and B.
- **Steam Deck:** install and gameplay only.

Nothing below builds Android, downloads AOSP or reads `.build-env`.

**Status (2026-11-12):**

- **Test A passed** on the Linux PC with `base-20261112` (from `5a2f31c`) and the
  tools at `eddeaef`.
  - Identical: rootfs (4059 entries), sysbake (1168 entries), xattrs (1171
    paths), 52 registered packages, and the runtime fingerprint (`585ab06c…`).
  - No sysbake ran, and compare exited 0.
  - The only file removed is `compat_tool/images/.gitignore` (development only).
- **The first Test A run found two packaging bugs, fixed in `eddeaef`:**
  - `tests/runtime` helpers were dropped.
  - Packaging a fresh sysbake that contains sockets crashed.
- **Test B, first run (PC):**
  - Injection worked.
  - Sysbake first hung: SELinux denied the container Binder. After the one-time
    policy module install, sysbake succeeded in about 2 minutes and registered
    57 packages.
  - Packaging and comparison worked, and showed all the expected Android
    changes. The comparison also exposed a mode bug in the shared NDK
    injector: base directories became `2755`, inheriting setgid from the
    inputs' folder. Fixed in `a6ca691`.
  - Don't install that first `full-base-20261112` bundle.
- **PC tests passed on `base-20261112-r2`** (package-only repackage at
  `3ba5f8f`), using the bundle's own tools:
  - **r1 vs r2:** identical Android rootfs, sysbake, xattrs and fingerprint;
    only tooling and docs differ.
  - **Test A:** passed again, with the same identical results as above.
  - **Test B:**
    - Injection kept every base directory mode (`system/bin` stays `0751`, no
      setgid), and the real sysbake passed (57 packages).
    - The comparison shows only the intended differences: 158 rootfs entries
      added, three `build.prop` files changed, no permission, type or link
      changes, nothing removed from the rootfs, and a new sysbake registering
      Chrome, Play Store, Play services, GSF and Trichrome. `BUNDLE.json`
      `gapps`/`ndk`/`widevine` are true, matching the rootfs.
    - Installer `--check` passed (separate tool `lepton_custom_full_20261112_r2`).
  - **Output for the Deck:** `~/lepton-work/r2/bundles/lepton-x86_64-full-20261112-r2.*`.
- **Still needed:** the Steam Deck install and gameplay checks below.

## 0. Linux PC preparation (can be done now)

```bash
sudo dnf install python3 binutils bash rsync e2fsprogs unzip util-linux diffutils gawk \
                 podman fuse-overlayfs weston attr procps-ng shadow-utils openssh android-tools
grep -w binder /proc/filesystems              # BinderFS kernel support
systemctl --user is-system-running            # running (or degraded)
getsubids "$USER" && getsubids -g "$USER"     # rootless Podman ranges
# SELinux: allow Android's Binder in the container (once; SELinux stays enforcing)
sudo dnf install checkpolicy semodule-utils
checkmodule -M -m -o /tmp/lepton_binder.mod fedora/lepton_binder.te
semodule_package -o /tmp/lepton_binder.pp -m /tmp/lepton_binder.mod
sudo semodule -i /tmp/lepton_binder.pp
```

Without the module, sysbake boots into a loop of `servicemanager` aborts:
`binder { set_context_mgr }` is denied for `spc_t` (see `journalctl | grep avc`).
`sysbake --check` reports this, with these commands, when the tools include the SELinux check.

Optional, also possible now: prepare the Google inputs from the repository
checkout. They must be made with this branch, because inputs from `5588b21`
lack `libc++.so`.

```bash
bash image-14/scripts/prepare-google-inputs.sh --zip ~/Downloads/x86_64-34_r14.zip \
  --output ~/lepton-work/google-inputs --with-ndk --with-gapps --with-widevine
```

## Common setup (needs the incoming base bundle)

Copy `lepton-x86_64-<ID>.tar.gz`, `.tar.gz.sha256` and `.install.sh` from the
build machine into `IN`.

```bash
IN=/mnt/e46048ea-fde7-4f4d-acc9-49f1e7d6348e/lepton-workspace/bundles
BASE_ID=base-20261112                          # the incoming bundle's ID
B=$IN/lepton-x86_64-$BASE_ID.tar.gz
W=~/lepton-work
mkdir -p "$W/bootstrap"
(cd "$IN" && sha256sum -c "lepton-x86_64-$BASE_ID.tar.gz.sha256")
tar -xzf "$B" -C "$W/bootstrap" ./compat_tool/tools ./compat_tool/release-keys
C=$W/bootstrap/compat_tool/tools
```

The `base-20261112` bundle was packaged at `5a2f31c`, before the packaging
fixes in `eddeaef`. Until a base bundle is packaged from `eddeaef` or later, use
an up-to-date checkout's tools:
`C=~/WORK/UniStore/Codes/lepton86-public/compat_tool/tools`. The stage helpers
(sysbake, inject) from the bundle are unaffected.

The build machine does not sign bundles, but the bundle carries the release
keys. Every command that reads `$B` therefore needs `--allow-unsigned`, which
checks integrity only. Alternatively, sign the `.sha256` with your own key and
pass `--trusted-signers FILE`.

## Test A: restore and repackage (needs the incoming base bundle)

No sysbake may run in this test.

```bash
$C/lepton-customize restore --check   --allow-unsigned --bundle "$B" --checksum "$B.sha256" --stage-dir "$W/restored"
$C/lepton-customize restore --execute --allow-unsigned --bundle "$B" --checksum "$B.sha256" --stage-dir "$W/restored"
python3 -m json.tool "$W/restored/STAGE.json"  # state restored-complete, sysbake_required false
$C/lepton-customize sysbake --check --stage-dir "$W/restored"   # must REFUSE: keeps its original sysbake
$C/lepton-customize package --check   --stage-dir "$W/restored" --output-dir "$W/bundles" --bundle-id "$BASE_ID-repack"
$C/lepton-customize package --execute --stage-dir "$W/restored" --output-dir "$W/bundles" --bundle-id "$BASE_ID-repack"
$C/lepton-compare-bundles "$B" "$W/bundles/lepton-x86_64-$BASE_ID-repack.tar.gz" --json "$W/test-a.json"; echo "exit=$?"
```

Pass when all of the following hold:

- [ ] Compare exits 0 and reports `Android rootfs: IDENTICAL`, `Sysbake: IDENTICAL`,
      `sysbake.xattrs: IDENTICAL`, `Runtime fingerprint inputs: IDENTICAL`, and
      `registered Android packages: N -> N (same set)`.
- [ ] `RESULT: ... differences are confined to launcher/tooling/metadata`.
- [ ] The metadata changes are only the bundle/tool identity, `origin` and
      `source_bundle_id`, and the files that list are `BUNDLE.json`,
      `STEAM-DECK-INSTALL.txt`, provenance files and the added
      `compat_tool/provenance/sources/<ID>/`.
- [ ] `restore` printed nothing about generating a sysbake.

The automated equivalent, which uses a temporary directory and cleans up:

```bash
LEPTON_TEST_COMPLETE_BUNDLE="$B" LEPTON_TEST_ALLOW_UNSIGNED=1 \
  python3 -B tests/test-customize-package.py LocalBundleIntegration
```

## Test B: customise and rebuild (needs the incoming base bundle)

```bash
# 1. New prepared stage from the same base bundle (sysbake discarded)
$C/lepton-customize --execute --allow-unsigned --bundle "$B" --checksum "$B.sha256" --stage-dir "$W/base-stage"

# 2. Google inputs: reuse step 0, or prepare from the ZIP with the bundled helper
#    (skip if "$W/google-inputs" exists)
bash "$W/base-stage/tools/customize/prepare-google-inputs.sh" --zip ~/Downloads/x86_64-34_r14.zip \
  --output "$W/google-inputs" --with-ndk --with-gapps --with-widevine

# 3. Inject all three components
$C/lepton-customize inject --check   --stage-dir "$W/base-stage" --output-stage "$W/full-stage" \
  --google-inputs "$W/google-inputs" --with-ndk --with-gapps --with-widevine
$C/lepton-customize inject --execute --stage-dir "$W/base-stage" --output-stage "$W/full-stage" \
  --google-inputs "$W/google-inputs" --with-ndk --with-gapps --with-widevine

# 4. Optional: pinned Google adb in the stage (only to test APKs on this PC; never packaged)
$C/lepton-customize adb --execute --stage-dir "$W/full-stage"

# 5. Fresh isolated sysbake (software rendering; add --timeout 1200 if the boot times out)
$C/lepton-customize sysbake --check   --stage-dir "$W/full-stage"
$C/lepton-customize sysbake --execute --stage-dir "$W/full-stage"
python3 -m json.tool "$W/full-stage/STAGE.json"  # state baked, baked_from customized

# 6. Package and compare against the base bundle
FULL_ID=full-$BASE_ID
$C/lepton-customize package --execute --stage-dir "$W/full-stage" --output-dir "$W/bundles" --bundle-id "$FULL_ID"
$C/lepton-compare-bundles "$B" "$W/bundles/lepton-x86_64-$FULL_ID.tar.gz" --json "$W/test-b.json"; echo "exit=$?"
bash "$W/bundles/lepton-x86_64-$FULL_ID.install.sh" --check --allow-non-amd   # verifies only; changes nothing
```

Pass on the PC when all of the following hold:

- [ ] Sysbake passes host checks, boots, and prints `fresh sysbake validated`
      together with the `registers N packages` count.
- [ ] Compare exits 1 (Android differs as intended):
  - Android rootfs DIFFERENT, with added `libndk_translation*`, `system/*/arm64`,
    `PrebuiltGmsCore`, `Phonesky`, `GoogleServicesFramework`, Chrome/Trichrome
    and `vendor/apex/com.google.android.widevine/*`;
  - `system/build.prop`, `vendor/build.prop` and `vendor/odm/etc/build.prop` changed;
  - no `permissions changed` entries in the rootfs: injection keeps every base
    directory mode (`a6ca691`);
  - Sysbake DIFFERENT;
  - registered packages gained `com.google.android.gms`, `com.android.vending`,
    `com.google.android.gsf`, `com.android.chrome` and `com.google.android.trichromelibrary_*`;
  - `Installed in new rootfs: gapps true, ndk true, widevine true`, matching `BUNDLE.json`.
- [ ] The installer `--check` passes.

The automated equivalent (keeps its output):

```bash
LEPTON_TEST_BASE_BUNDLE="$B" LEPTON_TEST_GOOGLE_INPUTS="$W/google-inputs" LEPTON_TEST_ALLOW_UNSIGNED=1 \
  python3 -B tests/test-customize-package.py LocalSysbakeIntegration
```

### Steam Deck: install as a separate tool

From the PC (needs SSH on the Deck):

```bash
DECK=deck@192.168.1.50
ssh "$DECK" 'mkdir -p ~/Downloads/lepton-deck-bundles'
rsync -tv --progress "$W/bundles/lepton-x86_64-$FULL_ID."{tar.gz,tar.gz.sha256,install.sh} \
  "$DECK:Downloads/lepton-deck-bundles/"
```

On the Deck (Desktop Mode, Konsole):

```bash
cd ~/Downloads/lepton-deck-bundles
sha256sum -c lepton-x86_64-full-*.tar.gz.sha256
python3 ~/.local/bin/lepton-manage-installs --list > ~/lepton-installs-before.txt   # if installed
bash lepton-x86_64-full-*.install.sh --check
bash lepton-x86_64-full-*.install.sh --new     # new tool lepton_custom_full_...; never replaces
python3 ~/.local/bin/lepton-manage-installs --list   # earlier installs unchanged
```

Do not use `--replace`, `--into` or `--remove` here. The installer downloads
the pinned adb from Google, so it needs internet; offline, use `--adb-zip FILE`.
Restart Steam.

The new install becomes the default for the Lepton menu entries and
`~/.local/bin` tools: `~/.config/lepton-x86_64/default.env` and the `~/.local/bin`
links are updated. Earlier tools, their files and their Steam games are
unchanged. When adding a game, check which tool is selected.

**Protect saves:** add test games with "Lepton: Add Android game" and pick the
new tool. Do not switch an existing game's compatibility tool. A game's saved
Android data belongs to the bundle it was made with; another bundle refuses that
profile (it is kept, not mounted).

Gameplay checks:

- [ ] The new tool appears in Steam, separate from earlier tools, and earlier
      installs and their games still work.
- [ ] An x86_64 game installs and plays (sysbake/runtime sanity).
- [ ] An ARM64-only game installs and plays (NDK).
- [ ] Google sign-in works ("Lepton: Google sign-in (<ID>)"), then Play services
      and an APKM/Play game (GApps).
- [ ] A Widevine-reporting app shows L3 (Widevine; software DRM only).
- [ ] Steam Stop and relaunch keep the game's own saved progress.

When done: `python3 ~/.local/bin/lepton-manage-installs --remove lepton_custom_full_<…> --execute`.

## Clean-up on the PC

```bash
podman unshare rm -rf "$W/restored" "$W/base-stage" "$W/full-stage"   # stages hold Android-owned files
```

Keep `$W/bundles` and `$W/google-inputs` as needed.
