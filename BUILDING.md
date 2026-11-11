# Build Lepton x86_64 from source

This guide goes from a fresh clone to Steam Deck bundles: a **base** bundle
and, optionally, a **GApps + NDK** bundle (Google Play services and ARM64 app
translation). Installing a bundle on the Deck is covered in
[INSTALL-STEAM-DECK.md](INSTALL-STEAM-DECK.md).

Nothing here downloads Google apps or games: you supply those files. The one
exception is Google's Android Debug Bridge (`adb`), see
[Google ADB](#google-adb-is-not-in-the-bundle) below.

## The workspace

Everything the build makes goes into one folder, the **workspace**, set by
`LEPTON_OUTPUT_DIR` in `.build-env`. Deleting that folder removes it all; the
build never writes elsewhere in your home folder (except Podman's builder
image).

| Folder             | What it holds                                                                                                                                               |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `aosp/`          | The **checkout**: the Android 14 (AOSP) sources and their build output (`aosp/out/`).                                                               |
| `images/`        | `system.img` and `vendor.img` from the latest build, with checksums and `BUILD-INFO.txt` (what they were built from).                                 |
| `rootfs/`        | The **rootfs**: those images unpacked into one folder, ready for bundling.                                                                            |
| `stages/<ID>/`   | One **stage** per bundle: the working folder in which `make-deck-bundle` assembles it. You never edit it, and can delete it once the bundle exists. |
| `bundles/`       | Finished **bundles**: `.tar.gz`, `.sha256` checksum and `.install.sh` installer. This is what goes to the Deck.                                 |
| `logs/`          | Logs of every step.                                                                                                                                         |
| `google-inputs/` | Optional GApps, NDK and Widevine inputs, made from your Google zip.                                                                                         |

You only run the scripts in `image-14/scripts/` itself. The ones in
`image-14/scripts/internal/` are building blocks those scripts call; you only
need them when debugging a failed step or
[repackaging an existing stage](#repackage-an-existing-stage-without-rebuilding-android).

## Requirements

- x86_64 Linux (tested on Fedora 44) with rootless Podman, and an AMD GPU if you also want to test locally.
- About **350 GB** free for the workspace (sources about 265 GB, build output
  about 70 GB) plus a few GB for each bundle. `LEPTON_MIN_FREE_GIB` (default 200)
  is checked before each step.
- 24 GB RAM works with `LEPTON_BUILD_JOBS=6`. The first build takes many hours;
  later builds are incremental.
- Host commands, all checked by the preflight in step 2: `git podman rsync python3 simg2img sqfs2tar fuse2fs fusermount3 unzip`, plus `lpunpack sfdisk debugfs` for the Google inputs. On Fedora they come from the `android-tools`,
  `squashfs-tools-ng`, `e2fsprogs`/`fuse2fs`, `fuse3`, `util-linux` and `unzip`
  packages.

## 0. One-time setup

```bash
git clone --recurse-submodules https://github.com/pjohno/lepton-x86_64
cd lepton-x86_64
cp .build-env.example .build-env    # then edit it, see below
podman build -t lepton-builder-ubuntu26:latest \
    -f image-14/.buildscripts_x86_64/Containerfile.ubuntu26 image-14/.buildscripts_x86_64
```

In `.build-env`, set:

- `LEPTON_OUTPUT_DIR`: the workspace folder, on a large, fast disk. It is
  created by step 2 and must not be inside this repository;
- `LEPTON_BUILD_JOBS`: parallel compile jobs (6 suits 24 GB of RAM).

**Optional Google inputs (for the GApps + NDK bundle).** Download the Android
SDK system image *Google Play Intel x86_64 Atom System Image, API 34,
revision 14* (`x86_64-34_r14.zip`), for example with Android Studio's SDK
Manager. Then:

```bash
bash image-14/scripts/prepare-google-inputs.sh --zip /path/to/x86_64-34_r14.zip
```

This writes `google-inputs/` in the workspace, where the bundle step finds it.
Keep the zip itself outside the workspace. See [GAPPS.md](GAPPS.md) for what
this adds.

## The build: five commands

**Tip for long steps.** Steps 2 and 3 can take hours. To keep them running after
you log out (Fedora otherwise stops your processes and Podman containers),
start a terminal session that survives logout, and run the commands in it:

```bash
loginctl enable-linger                      # once per user
systemd-run --user --scope tmux new-session -s lepton
```

Detach with `Ctrl-b` then `d`; reattach later with `tmux attach -t lepton`.

Run these from the repository root. Each stops with `[FAIL]` and a log path if
something is wrong; nothing is ever copied to the Deck by these steps.

```bash
# 1. Check the computer and configuration
bash image-14/scripts/preflight-x86_64.sh fresh        # 'existing' if the checkout already exists

# 2. Download and prepare the Android sources (patched for Lepton)
bash image-14/scripts/prepare-x86_64.sh --execute      # '--reset' if the checkout already exists

# 3. Compile Android and package its rootfs
bash image-14/scripts/build-images-x86_64.sh --execute

# 4. Base bundle
bash image-14/scripts/make-deck-bundle-x86_64.sh --execute --bundle-id base-20261104

# 5. GApps + NDK bundle (needs the optional Google inputs)
bash image-14/scripts/make-deck-bundle-x86_64.sh --execute --bundle-id gapps-ndk-20261104 \
    --with-gapps --with-ndk
```

Step 5 also accepts `--with-widevine` (software Widevine L3 from the same
Google image; see [GAPPS.md](GAPPS.md)).

What each step does:

1. **Preflight** checks host tools, disk space, the builder image and the
   repository's submodules. It changes nothing.
2. **Prepare** downloads AOSP (Android 14, about 150 GB, several hours the
   first time) and applies Lepton's changes: Valve's projects and patches, then
   the x86_64 patches in `image-14/patches/`.
   - If the download is interrupted, rerun with `--resume`.
   - `--reset` puts an existing checkout back to exactly the downloaded sources
     and then patches it again, with no new download. It also removes
     previously installed build outputs. Use it when the checkout needs to be
     re-prepared for changed Android sources or patches, or when you want a
     build that is known to come only from this repository. For an already
     prepared checkout, use the [incremental workflow](#incremental-test-bundle-without-replacing-packaged-outputs)
     below instead.
3. **Build images** compiles `system.img` and `vendor.img` inside the builder
   container, copies them to `images/` and unpacks them to `rootfs/`,
   replacing those from any earlier build.
4. **and 5. Make bundle** each create a stage, add the Deck tools
   (inotify-tools, plus ADB for local testing only), boot Android once to bake its first-boot data (private
   Podman storage, no GPU needed) in `stages/<ID>/`, then write the bundle to
   `bundles/`. Bundle IDs must be new each time (a date works well). Each one becomes its own Steam compatibility tool, named
   **Lepton x86_64 (community) - *bundle ID***.

Add `--check` instead of `--execute` to steps 2 to 5 to see what would happen
without changing anything.

### Google ADB is not in the bundle

Lepton uses Google's `adb` from Android Platform-Tools 37.0.1
(`37.0.1-15733141`) to install games into Android. The bundles do **not**
contain it, and this project does not redistribute it:

- On the build computer, making a stage downloads the official
  [`platform-tools_r37.0.1-linux.zip`](https://dl.google.com/android/repository/platform-tools_r37.0.1-linux.zip)
  (or uses `--adb-zip FILE`) and puts the verified `adb` in
  `stages/<ID>/tools/platform-tools/` for local testing only.
- Packaging leaves `tools/platform-tools/` and Google's notice out of the
  archive, and refuses to write an archive that contains a host `adb`.
- On the Deck, the installer downloads the same ZIP directly from Google,
  extracts only `adb` and `NOTICE.txt`, and accepts `adb` only if its SHA256 is
  `a902be8f45c6c62e76c9efaf6947a0fa747c9cabd89a2ac8e0d16ecb30b3ed01` and it
  reports version `37.0.1-15733141`. The pin is in
  `compat_tool/tools/lepton-install-bundle` and must match
  `image-14/scripts/internal/provision-deck-tools.sh` (a test checks this).

## 6. Send the bundles to the Deck

Enable SSH on the Deck once (see [INSTALL-STEAM-DECK.md](INSTALL-STEAM-DECK.md#2-copy-it-to-the-deck)), then:

```bash
bash image-14/scripts/transfer-deck-bundle.sh --bundle-id base-20261104 --deck-ip 192.168.1.50
bash image-14/scripts/transfer-deck-bundle.sh --bundle-id gapps-ndk-20261104 --deck-ip 192.168.1.50
```

Each puts an **Install Lepton *ID*** icon on the Deck's desktop; continue with
[INSTALL-STEAM-DECK.md, step 3](INSTALL-STEAM-DECK.md#3-install-steam-deck-desktop-mode).
To update an existing install in place instead (its games keep working), add
`--replace TOOL_ID`; `lepton-manage-installs --list` on the Deck shows the IDs.

## Or install on this computer (experimental)

A bundle can also be installed on the build computer itself. The local wrapper
uses the Deck installer with a persistent `local-desktop` installation profile: it registers the Steam compatibility tool and adds
**Lepton: Add Android game** to the application menu.

Local installs now launch directly through host Wayland by default, without
nested Gamescope. Phase 2 requests native fullscreen and negotiates physical buffer dimensions
through the local hwcomposer patch; runtime verification is required. Use `LEPTON_LOCAL_USE_GAMESCOPE=1 %command%`
for the existing windowed Gamescope fallback. Normal Deck installs keep their
existing paths. See [local desktop routing](compat_tool/LOCAL-DESKTOP.md) for
profile persistence, upgrades, limitations and launcher-only deployment.

**Lepton targets the Steam Deck.** Desktop PCs remain experimental. Fedora KDE
Wayland testing confirmed mouse and keyboard input with the desktop touch-mode
fix; older bundles may still have the nested Gamescope mouse failure. Physical
Fedora mode-1 testing confirmed mouse, keyboard, focus and game interaction; Steam Deck tests confirm mouse
and single-touch compatibility in mode 1, with native multitouch requiring mode 4. See
[testing a bridge change](FEDORA-DEBUGGING.md#testing-the-steam-gamescope-bridge)
to use updated launcher code without rebuilding Android.

```bash
bash image-14/scripts/install-local.sh --check --bundle-id base-20261104
bash image-14/scripts/install-local.sh --execute --bundle-id base-20261104
```

It first checks this computer (`compat_tool/tools/lepton-host-check`, which
only reads and never installs anything) and stops if something is missing:

- **Podman** (rootless), **Gamescope**, **setfattr** (package `attr`),
  **Python 3**, and **zenity** or **kdialog**;
- **Android Binder (BinderFS)** support in the kernel. Lepton never loads
  kernel modules; check with `grep binder /proc/filesystems`;
- the **native Steam** package, started once. Flatpak Steam cannot start
  Lepton's containers and is not supported.

Graphics: an **AMD GPU** is required; the Android image only contains AMD
drivers. Software rendering on other GPUs (for example Intel) does not work
yet: `--allow-non-amd` installs anyway, for testing only. Desktops: KDE Plasma on Wayland is tested (it is what the
Deck's Desktop Mode uses). Other desktops, such as GNOME, are **untested**:
the check warns but allows them.

If the bundle does not exist yet but its stage does, the stage is packaged
first. Installing again needs `--replace` (or `--into TOOL_ID`), as on the
Deck. Restart Steam afterwards to see the new tool.

## Publishing a release (maintainers)

A public release is a base bundle made with the release version as its bundle
ID, then checked and uploaded by `publish-release.sh`:

```bash
bash image-14/scripts/make-deck-bundle-x86_64.sh --execute --bundle-id v0.1.0-alpha
bash image-14/scripts/publish-release.sh --check --version v0.1.0-alpha
```

Make the bundle from a clean commit on `main`. **[RELEASING.md](RELEASING.md)**
has the whole workflow, from testing and signing to drafting, reviewing and
publishing. The publisher never builds anything; it only uploads bundles that
have already been made and tested.

## Rebuilding later

Choose the workflow according to what changed. Run commands from the repository
root, keeping `.build-env` pointed at the existing workspace and AOSP checkout.

| Change | Workflow |
| --- | --- |
| Android source changes already applied to a prepared checkout | [Incremental build](#incremental-test-bundle-without-replacing-packaged-outputs): reuse `aosp/` and `aosp/out/`, create new images, rootfs, stage and bundle |
| Installer, launcher or host script changes; existing Android runtime is suitable | [Repackage the existing stage](#repackage-an-existing-stage-without-rebuilding-android): no compilation or sysbake regeneration |
| Android patches or vendored sources changed and the checkout needs re-preparation | [Reset and re-prepare](#reset-and-re-prepare-the-existing-checkout) before building |

Pulling host-only changes does not require an Android reset or rebuild.
`image-14/do_build_x86_64.sh` is for a fresh checkout and refuses an existing
one; use the incremental wrapper below to reuse the checkout.

### Reset and re-prepare the existing checkout

Use this when the prepared Android sources no longer match the required
patches/vendor content. `--reset` discards checkout edits and runs
`m installclean`; it keeps the downloaded checkout and compiled intermediates,
but removes installed build outputs. It is not the ordinary incremental path.

```bash
bash image-14/scripts/preflight-x86_64.sh existing
bash image-14/scripts/prepare-x86_64.sh --reset
bash image-14/scripts/build-images-x86_64.sh --execute
bash image-14/scripts/make-deck-bundle-x86_64.sh --execute --bundle-id base-YYYYMMDD
```

### Repackage an existing stage without rebuilding Android

For installer or host-script changes, reuse a complete stage, including its
existing rootfs and sysbake. For example, refresh the fullscreen test bundle:

```bash
source .build-env

bash image-14/scripts/internal/deploy-compat-x86_64.sh \
  --package-only --check \
  --stage-dir "$LEPTON_OUTPUT_DIR/fullscreen-test/stage" \
  --bundle-dir "$LEPTON_OUTPUT_DIR/fullscreen-test/bundles" \
  --bundle-id fullscreen-test-r2

bash image-14/scripts/internal/deploy-compat-x86_64.sh \
  --package-only --execute \
  --stage-dir "$LEPTON_OUTPUT_DIR/fullscreen-test/stage" \
  --bundle-dir "$LEPTON_OUTPUT_DIR/fullscreen-test/bundles" \
  --bundle-id fullscreen-test-r2
```

Replace the stage path with your existing complete stage. Choose a new bundle
ID each time: packaging refuses to overwrite existing archives, checksums or
installers. It copies the stage and refreshes the bundled host scripts from
this repository, leaving the source stage unchanged. It neither compiles
Android nor regenerates sysbake, and it does not transfer or install anything.
Android changes must already be present in the stage to appear in this bundle.

## Incremental test bundle without replacing packaged outputs

When the checkout is already prepared for this branch, use a new output folder
instead of the fresh-checkout `do_build_x86_64.sh` workflow. The wrapper reuses
the checkout at `LEPTON_AOSP_DIR` (default `$LEPTON_OUTPUT_DIR/aosp`) and its
existing `out/` intermediates; Android rebuilds the affected targets. It does
not download another checkout. Do not run `prepare --reset`, `installclean`,
or a clean build for this case. If `fullscreen-test` already exists, choose a
new output folder and bundle ID, such as `fullscreen-test-r2`, in both commands.

```bash
source .build-env
TEST_OUT="$LEPTON_OUTPUT_DIR/fullscreen-test"
bash image-14/scripts/build-incremental-bundle-x86_64.sh \
  --check --bundle-id fullscreen-test --output-dir "$TEST_OUT"
bash image-14/scripts/build-incremental-bundle-x86_64.sh \
  --execute --bundle-id fullscreen-test --output-dir "$TEST_OUT" \
  --from-stage "$LEPTON_OUTPUT_DIR/stages/v0.1.0-alpha"
```

`--from-stage` is optional and reuses only verified ADB/inotify tools from an
existing stage; it never reuses that stage's sysbake. Omit it to provision tools
normally. ADB is not redistributed in the archive. Forward `--with-gapps`,
`--with-ndk`, `--with-widevine`, their input options, tool identity and sysbake
options as needed; these features remain opt-in. No files are transferred or
installed by this wrapper.

The new folder must not exist. It will contain:

| Path | Contents |
| --- | --- |
| `images/` | New system/vendor images, `SHA256SUMS`, `BUILD-INFO.txt` |
| `rootfs/` | New flattened rootfs, including its own image-provenance record |
| `stage/` | New compatibility tool and fresh sysbake for those images |
| `bundles/` | `lepton-x86_64-steamdeck-fullscreen-test.tar.gz`, its `.sha256` and `.install.sh` |

The original workspace `images/`, `rootfs/`, `stages/` and `bundles/` are
preserved. **The existing checkout's `aosp/out/` is shared and updated by
incremental compilation.** Source files are not reset. Logs and the build lock
are also updated. An interrupted earlier build is refused in isolated mode;
inspect or repair it separately, rather than silently deleting intermediates.
Partial new outputs are kept for inspection and are never silently overwritten.

The same operations can be run separately:

```bash
bash image-14/scripts/build-images-x86_64.sh --execute \
  --images-dir "$TEST_OUT/images" --rootfs-dir "$TEST_OUT/rootfs"
bash image-14/scripts/make-deck-bundle-x86_64.sh --execute \
  --bundle-id fullscreen-test --rootfs-source "$TEST_OUT/rootfs" \
  --stage-dir "$TEST_OUT/stage" --bundle-dir "$TEST_OUT/bundles" \
  --from-stage "$LEPTON_OUTPUT_DIR/stages/v0.1.0-alpha"
```

Both explicit image/rootfs destinations must be new, outside the original
artifact directories, disjoint from sources/each other, and contain no symlink
ancestors. Supply both overrides to preserve both defaults. `.build-env` is
never edited. Omitting overrides retains the original replacement behavior.

Before compilation, the local hwcomposer patch must already be applied and
vendored source contents must match this branch's pinned trees plus its reviewed
patches. The copied tree's underlying Git HEAD need not equal the vendored
submodule HEAD: vendoring overlays source files. Content checks are authoritative.
A missing patch is reported with a safe apply command; it is not applied twice
or reset automatically. Conflicting/stale source content stops the build.

The compiler explicitly builds `hwcomposer.waydroid` before generating images.
The extracted vendor library must match that artifact byte-for-byte and contain
the new local-display code before the output is marked ready. New rootfs builds
carry `.lepton-image-provenance`, which packaging prefers over the workspace's
old `BUILD-INFO.txt`. Both build.prop and hwcomposer hashes must match, avoiding
false provenance when only the native library changed.

After reviewing the resulting bundle, transfer it (replace `DECK_IP`):

```bash
bash image-14/scripts/transfer-deck-bundle.sh --check \
  --bundle-id fullscreen-test --bundle-dir "$TEST_OUT/bundles"
bash image-14/scripts/transfer-deck-bundle.sh \
  --bundle-id fullscreen-test --bundle-dir "$TEST_OUT/bundles" --deck-ip DECK_IP
```

On the Deck, install alongside existing tools:

```bash
bash ~/Downloads/lepton-deck-bundles/lepton-x86_64-steamdeck-fullscreen-test.install.sh --new
```

Restart Steam and manually select `Lepton x86_64 (community) - fullscreen-test`
for a test shortcut. The tool ID is `lepton_x86_64_fullscreen_test`; do not use
`--replace`, `--into` or a transfer `--replace` option. The bundle carries no
local-desktop profile, so Deck Desktop Mode stays windowed with touch mode 1,
and Gaming Mode retains fullscreen SDL/X11 Gamescope with touch mode 4.

Existing saves/prefixes are not reset. A different Android runtime may be refused
for an existing game profile by fingerprint protection; keep the original tool
for that game or add a separately named test shortcut with its own prefix.
Never bypass that refusal by resetting valuable data. These commands do not
publish a release, merge the branch or change GitHub issue state.

## When something fails

- Every step prints the path of its log. Logs live in the workspace's `logs/`
  and stay after failures.
- A failed or stopped **build** can simply be run again; it continues where
  it stopped.
- **Power cut, crash or forced shutdown during a build.** Avoid these if you
  can: the build is long and writes a great many files, and files written in
  the last seconds before the power went may be empty or garbage even though
  the build had recorded them as finished. Just run the build again: it
  notices that the previous run did not finish ("The previous image build did
  not finish"), deletes the damaged files it finds and rebuilds only those.
  If a build still fails with errors such as `neither ET_REL nor LLVM bitcode`, `file format not recognized` or `file truncated` (the build then
  prints a hint), check the whole output and continue:

  ```bash
  bash image-14/scripts/build-images-x86_64.sh --repair
  bash image-14/scripts/build-images-x86_64.sh --execute
  ```

  Use `--repair` only when `--execute` will not complete. It deletes every
  compiled file (objects, libraries, jars, APKs) that does not look like a
  valid one, and lists them in `logs/`. It errs on the side of caution: on a
  healthy build it also deletes a few dozen good files that Android writes in
  another format (text or JSON with a `.o` or `.a` name). Those are simply
  rebuilt by the next `--execute`, which takes minutes, not hours. If the
  build still fails the same way afterwards, delete `aosp/out/` for a full
  rebuild (no new download; several hours).
- A failed **prepare** during patching refuses to continue automatically, so
  that a half-patched tree is never built. Run `prepare-x86_64.sh --reset` to
  start the patching from clean sources. An interrupted **reset** must also
  be retried with `--reset`; resume and build refuse its `reset.started`
  checkpoint. Existing vendor/patch checkpoints remain as evidence until
  project reset and `m installclean` both succeed. Reset then vendors and
  patches again. It keeps the pinned manifest and compiled intermediates;
  it neither downloads sources nor recreates the Android checkout.
- **Git index locks after an interrupted prepare.** `--reset` inventories
  managed projects using `.repo/project.list` and resolves their actual
  `index.lock` locations through Git, including gitfiles and repo worktrees.
  It also checks the manifest/repo Git checkouts when present. Host Python 3
  inspects Linux `/proc` before the builder starts, so host and rootless
  container processes are visible. Only regular, user-owned index locks
  with one hard link, at least 60 seconds old, with no detected operation or
  open file holder, qualify for automatic removal. Every candidate is
  validated before any removal; process activity and file identity are
  checked again immediately before removing each exact file.

  Recovery deliberately refuses **any** visible Git/repo operation, even in
  another checkout: working directories alone cannot identify operations
  using `git -C`, `GIT_DIR`, shared stores or child editors. It also refuses
  fresh, changing, symlinked or externally located locks and inaccessible
  process information. No Git/repo process is killed and no other lock type
  is removed. Keep all Git/repo work stopped throughout reset: inspection
  cannot prevent an independently started command from racing it. Concurrent
  preparation through this workflow is serialized with `flock`.

  If recovery stops, the log identifies the project, revision, operation and
  lock path. Inspect `ps -ef` on the host and `podman top CONTAINER` for any
  remaining builder; let verified operations finish, or stop only the exact
  operation yourself. For a fresh lock, wait at least 60 seconds and retry.
  Restore host `/proc` visibility if restricted; do not run recovery from
  inside a PID-isolated container. Git directories outside the managed tree
  require manual inspection. To inspect the reported project manually:

  ```bash
  source .build-env
  PROJECT="${LEPTON_AOSP_DIR:-$LEPTON_OUTPUT_DIR/aosp}/prebuilts/clang/host/linux-x86"
  git -C "$PROJECT" rev-parse --path-format=absolute --git-path index.lock
  # Only after confirming all operations have stopped and this exact lock is stale:
  rm -- /exact/verified/path/to/index.lock
  bash image-14/scripts/prepare-x86_64.sh --reset
  ```

  Never delete `*.lock` or use `pkill`/`killall`. Do not delete preparation
  checkpoints to bypass recovery. A Git error during reset now retains Git's
  stderr and prints the precise failing operation, project, manifest revision
  and index lock path. Other lock types or repository corruption need manual
  repair; this recovery does not diagnose Soong module errors.
- A failed **make-deck-bundle** leaves its stage behind. Delete it, or simply
  use a new bundle ID.

## Cleaning up

Stages contain files owned by Podman's user namespace, so delete them (or the
whole workspace) with `podman unshare`, not `sudo`:

```bash
source .build-env
podman unshare rm -rf "$LEPTON_OUTPUT_DIR/stages/base-20261104"   # one stage
podman unshare rm -rf "$LEPTON_OUTPUT_DIR"                         # everything
```

## Advanced

- `image-14/do_build_x86_64.sh` runs steps 1 to 4 in one go for a brand-new
  checkout (see [image-14/docs/BUILD-x86_64.md](image-14/docs/BUILD-x86_64.md)).
- How a stage is assembled: [image-14/docs/DECK-STAGING.md](image-14/docs/DECK-STAGING.md);
  first-boot baking: [image-14/docs/isolated-sysbake.md](image-14/docs/isolated-sysbake.md).
- Testing APKs locally on the build computer: [FEDORA-DEBUGGING.md](FEDORA-DEBUGGING.md).
