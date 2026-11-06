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

| Folder | What it holds |
| --- | --- |
| `aosp/` | The **checkout**: the Android 14 (AOSP) sources and their build output (`aosp/out/`). |
| `images/` | `system.img` and `vendor.img` from the latest build, with checksums. |
| `rootfs/` | The **rootfs**: those images unpacked into one folder, ready for bundling. |
| `stages/<ID>/` | One **stage** per bundle: the working folder in which `make-deck-bundle` assembles it. You never edit it, and can delete it once the bundle exists. |
| `bundles/` | Finished **bundles**: `.tar.gz`, `.sha256` checksum and `.install.sh` installer. This is what goes to the Deck. |
| `logs/` | Logs of every step. |
| `google-inputs/` | Optional GApps, NDK and Widevine inputs, made from your Google zip. |

You only run the scripts in `image-14/scripts/` itself. The ones in
`image-14/scripts/internal/` are building blocks those scripts call; you only
need them when debugging a failed step.

## Requirements

- x86_64 Linux (tested on Fedora 44) with rootless Podman, and an AMD GPU if
  you also want to test locally.
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
git clone --recurse-submodules <this repository> lepton86-public
cd lepton86-public
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
     previously installed build outputs. Use it after `git pull`, after
     editing patches, or whenever you want a build that is known to come only
     from this repository.
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

## Or install on this computer

A bundle can also be installed on the build computer itself, with the same
installer a Deck uses: it registers the Steam compatibility tool and adds
**Lepton: Add Android game** to the application menu.

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

## Rebuilding later

After pulling new commits or changing patches:

```bash
bash image-14/scripts/preflight-x86_64.sh existing
bash image-14/scripts/prepare-x86_64.sh --reset
bash image-14/scripts/build-images-x86_64.sh --execute
bash image-14/scripts/make-deck-bundle-x86_64.sh --execute --bundle-id base-YYYYMMDD
```

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
  If a build still fails with errors such as `neither ET_REL nor LLVM
  bitcode`, `file format not recognized` or `file truncated` (the build then
  prints a hint), check the whole output and continue:

  ```bash
  bash image-14/scripts/build-images-x86_64.sh --repair
  bash image-14/scripts/build-images-x86_64.sh --execute
  ```

  `--repair` only deletes compiled files (objects, libraries, jars, APKs)
  that are not valid, and lists them in `logs/`. If the build still fails the
  same way afterwards, delete `aosp/out/` for a full rebuild (no new
  download; several hours).
- A failed **prepare** during patching refuses to continue automatically, so
  that a half-patched tree is never built. Run `prepare-x86_64.sh --reset` to
  start the patching from clean sources.
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
