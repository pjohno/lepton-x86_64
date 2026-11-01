# Steam Deck development staging (Ubuntu 26.04 AMD-only build)

**Status:** experimental. This covers a fresh Android rootfs and transferable *host utilities*, not full Steam Deck installation or fresh system-data baking. The existing Steam Deck Lepton installation remains the known-good reference until a complete new build has passed runtime tests.

## Outputs and separation

- AOSP checkout: `$LEPTON_OUTPUT_DIR` (configured in ignored `.build-env`).
- Packaged Android rootfs: `$LEPTON_OUTPUT_DIR/repro-rootfs-auto/rootfs`.
- New, isolated Steam Deck stage: `$LEPTON_OUTPUT_DIR/deck-stage-CLEAN` (choose a fresh, nonexistent path).
- Bundle archive: choose an output directory outside both the repository and existing installed compatibility tool.

From the repository root after image compilation and rootfs packaging:

```bash
source .build-env
stage="$LEPTON_OUTPUT_DIR/deck-stage-CLEAN"
bash image-14/scripts/deploy-compat-x86_64.sh --check --stage-dir "$stage"
bash image-14/scripts/deploy-compat-x86_64.sh --execute --stage-dir "$stage"
bash image-14/scripts/provision-deck-tools.sh --execute --stage-dir "$stage"
bash image-14/scripts/provision-deck-tools.sh --check --stage-dir "$stage"
```

These commands do not overwrite an existing stage. `--check` may be run on a stage that already contains matching Android files. If an earlier stage has already been assembled, do **not** rerun `--execute` against it; check it instead.

`deploy-compat-x86_64.sh` with no `--stage-dir` retains its legacy repository-rootfs target and refuses overwrites. The new isolated mode stages host scripts, rootfs and the locally built native APK extractor, but deliberately excludes any old `sysbake` data. No SSH transfer or Steam configuration changes are performed.

## Reproducing the two Deck utilities

`provision-deck-tools.sh` downloads Google's official Linux Platform-Tools from `https://dl.google.com/android/repository/platform-tools_r37.0.1-linux.zip`, unpacks only the `adb` executable and verifies its SHA256 exactly matches the previously tested 37.0.1-15733141 binary:

```
a902be8f45c6c62e76c9efaf6947a0fa747c9cabd89a2ac8e0d16ecb30b3ed01
```

The script uses a versioned URL rather than Google's mutable `latest` URL. If verification fails, **do not disable it**; supply the known-good official ZIP with `--adb-zip PATH`, or review and test a version upgrade. Record the archive SHA256, tool version and licensing before refreshing the pin. The Fedora distribution ADB had nonportable dependencies in earlier Deck tests; the Google binary worked.

The script also clones the official `inotify-tools` Git tag `4.23.9.0`, checks its release-commit prefix `5c2ab77`, and builds in Debian 12 with rootless Podman to target an older glibc. It stages:

```
tools/bin/inotifywait              # in-repository shell wrapper
tools/native/inotifywait           # compiled program
tools/lib/libinotifytools.so.0     # compiled matching shared library
```

The wrapper sets `LD_LIBRARY_PATH` to the adjacent `tools/lib` folder before running the executable. Version and `ldd` checks verify the arrangement on the build machine. The earlier handoff documented an actual CREATE event test on the Deck for this layout; **newly rebuilt** binaries must still be tested on Deck. Upstream licenses should accompany the bundle. The builder's Debian 12 image tag is not yet digest-pinned; record the actual image ID/digest for release-grade reproducibility. Generated binaries and licenses are staged, not committed to Git. Source scripts and the Containerfile should be committed after review.

## Sysbake is not automated by this change

Do **not** copy an older `sysbake` from October's test stage into a new Android rootfs. The package manager generates `sysbake/system/packages.xml` when Android first boots, and `getfattr -R -d -m '-' sysbake` produces the corresponding `sysbake.xattrs` after baking. The recipe under `.ci_scripts/build-sysbake-14.sh` is for a disposable CI machine and runs destructive host operations, including `podman system reset --force`; never run it directly on Fedora or Steam Deck.

A future isolated sysbake runner must prevent global Lepton context cleanup, avoid resetting the user's Podman state, stage both the generated data and restored user xattrs, verify API 34 and successful initialization, and handle mode-000 directories safely. This is a separate acceptance gate before `package-lepton-deck.sh` will accept the stage and before any deployment to a working installation.

## Distribution and licensing

Source files should be the only additions to Git. The produced Deck archive may include redistributable binaries only after checking their upstream notices/license requirements, retaining the corresponding inotify-tools source and attribution, and reviewing Google's SDK distribution terms. Don't include proprietary APKs or private device data.
