# Build Lepton x86_64 from source

This guide goes from a fresh clone to Steam Deck bundles: a **base** bundle
and, optionally, a **GApps + NDK** bundle (Google Play services and ARM64 app
translation). Installing a bundle on the Deck is covered in
[INSTALL-STEAM-DECK.md](INSTALL-STEAM-DECK.md).

Nothing here downloads Google software or games: you supply those files.

## The words used here

| Term               | Meaning                                                                                                                                            |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Checkout** | The Android 14 (AOSP) source tree and build output in `LEPTON_OUTPUT_DIR`.                                                                       |
| **Images**   | `system.img` and `vendor.img`, compiled from the checkout.                                                                                     |
| **Rootfs**   | The images unpacked into one folder (`repro-rootfs-auto/rootfs`), ready for bundling.                                                            |
| **Stage**    | A working folder in which one bundle is assembled. Made and used by `make-deck-bundle`; you never edit it.                                       |
| **Bundle**   | The finished `.tar.gz` plus its `.sha256` checksum and `.install.sh` installer, in `~/lepton-deck-bundles`. This is what goes to the Deck. |

You only run the scripts in `image-14/scripts/` itself. The ones in
`image-14/scripts/internal/` are building blocks those scripts call; you only
need them when debugging a failed step.

## Requirements

- x86_64 Linux (tested on Fedora 44) with rootless Podman, and an AMD GPU if
  you also want to test locally.
- About **350 GB** free for the checkout (sources about 265 GB, build output
  about 70 GB) and a few GB for each bundle. `LEPTON_MIN_FREE_GIB` (default 200)
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

In `.build-env`, set at least:

- `LEPTON_OUTPUT_DIR`: where the Android checkout goes (a large, fast disk);
- `LEPTON_LOG_DIR`: build logs (outside the checkout);
- `LEPTON_BUILD_JOBS`: parallel compile jobs (6 suits 24 GB of RAM).

**Optional Google inputs (for the GApps + NDK bundle).** Download the Android
SDK system image *Google Play Intel x86_64 Atom System Image, API 34,
revision 14* (`x86_64-34_r14.zip`), for example with Android Studio's SDK
Manager. Then:

```bash
bash image-14/scripts/prepare-google-inputs.sh --zip /path/to/x86_64-34_r14.zip \
    --output /path/to/lepton-inputs/google-play-api34-r14
```

It prints two lines (`LEPTON_GOOGLE_IMAGES=...` and `LEPTON_NDK_PAYLOAD=...`).
Add them to `.build-env`. See [GAPPS.md](GAPPS.md) for what this adds.

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
   container. It then unpacks them to `repro-rootfs-auto/rootfs`, replacing the
   rootfs from any earlier build.
4. **and 5. Make bundle** each create a stage, add the Deck tools (ADB,
   inotify-tools), boot Android once to bake its first-boot data (private
   Podman storage, no GPU needed), then write the bundle to
   `~/lepton-deck-bundles`. Bundle IDs must be new each time (a date works
   well). Each one becomes its own Steam compatibility tool, named
   **Lepton x86_64 (community) - *bundle ID***.

Add `--check` instead of `--execute` to steps 2 to 5 to see what would happen
without changing anything.

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

## Rebuilding later

After pulling new commits or changing patches:

```bash
bash image-14/scripts/preflight-x86_64.sh existing
bash image-14/scripts/prepare-x86_64.sh --reset
bash image-14/scripts/build-images-x86_64.sh --execute
bash image-14/scripts/make-deck-bundle-x86_64.sh --execute --bundle-id base-YYYYMMDD
```

## When something fails

- Every step prints the path of its log. Logs live in `LEPTON_LOG_DIR` and stay
  after failures.
- A failed **build** can simply be run again; it continues where it stopped.
- A failed **prepare** during patching refuses to continue automatically, so
  that a half-patched tree is never built. Run `prepare-x86_64.sh --reset` to
  start the patching from clean sources.
- A failed **make-deck-bundle** leaves its stage behind. Delete the stage and
  bundle it names, or simply use a new bundle ID. Stage folders contain files
  owned by Podman's user namespace, so remove them with
  `podman unshare rm -rf "$LEPTON_OUTPUT_DIR/deck-stage-ID"` (no sudo needed).

## Advanced

- `image-14/do_build_x86_64.sh` runs steps 1 to 4 in one go for a brand-new
  checkout (see [image-14/docs/BUILD-x86_64.md](image-14/docs/BUILD-x86_64.md)).
- How a stage is assembled: [image-14/docs/DECK-STAGING.md](image-14/docs/DECK-STAGING.md);
  first-boot baking: [image-14/docs/isolated-sysbake.md](image-14/docs/isolated-sysbake.md).
- Testing APKs locally on the build computer: [FEDORA-DEBUGGING.md](FEDORA-DEBUGGING.md).
