# Handoff: where Lepton x86_64 is up to (2026-11-06)

Read this first when picking the work up on another computer or in a new AI
session. Delete it, together with `PENDING-TESTS.md`, when this branch is
merged into `main`.

## Branches

| Branch | Where | State |
| --- | --- | --- |
| `main` | GitHub | Unchanged since `b44f29c`. Nothing below is merged yet. |
| `release/adb-and-local-install` (this branch) | GitHub | Committed and pushed. Waiting for the tests in `PENDING-TESTS.md`, then merge into `main`. |
| `feature/release-framework` | **Only on the original computer** (worktree `../lepton86-public-releasefw`) | Built on this branch, **not committed or pushed** yet; waiting for review (see "Release framework" below). |
| `feature/software-launch` | GitHub | Automatic software rendering on non-AMD GPUs. **Not for release:** games crash with it on Intel. Kept for later. Do not merge. |

The user's rule: **no commit, push, tag, merge or publish without their
explicit approval.**

## What this branch contains

Each item is its own commit:
- **Steam Deck installer downloads Google ADB.** It's pinned to r37.0.1, and its
  SHA256 and version are checked. Bundles no longer contain it. `--adb-zip`
  installs offline.
- **Add-game:**
  - picks `.apkm`;
  - re-adds games whose shortcut was deleted, with a restart hint;
  - works on a desktop Steam that has no `CompatToolMapping` section.
- **Build recovery after a power cut:** `build-images-x86_64.sh --repair`, an
  "unfinished build" marker, and a hint when the build fails.
- **Local install:** `image-14/scripts/install-local.sh`, plus the
  `lepton-host-check` requirements check, which the installer also runs.
- **Double-click reinstall:** double-clicking an already-installed bundle's
  installer offers "Reinstall".
- **Neutral device brand:** `PRODUCT_BRAND := Linux-PC` instead of Steam-Frame.
  This needs an image rebuild; see `PENDING-TESTS.md`, build machine item 0.
- **Sysbake no longer breaks the terminal:** making a bundle no longer needs
  `reset` afterwards.
- **Test fixes:** "must not" checks that can now fail, and no real dialogs
  during tests.

## What is next

1. **Work through `PENDING-TESTS.md`** (Deck, build machine, AMD desktop):
   - rebuild the images with the brand change: copy the `.mk` file into the
     Android checkout first, and reuse `out/`;
   - make a fresh `combined-test` bundle;
   - test Reinstall, the ADB download, re-adding a deleted shortcut, GApps and
     NDK bundles, and `--repair` on a real build.
2. **Merge this branch into `main`** once the user approves, deleting
   `HANDOFF.md` and `PENDING-TESTS.md`.
3. **Review the release framework,** then commit, push and merge it, all with
   approval. After that, prepare the first public alpha (`v0.1.0-alpha`)
   following `RELEASING.md` on that branch.

## Release framework (`feature/release-framework`, not pushed)

This is the work for the first public alpha:
- **Lepton: Install / Update / Repair** (`compat_tool/tools/lepton-release-manager`):
  - lists GitHub releases;
  - downloads and verifies a release;
  - installs it alongside, replaces, updates or repairs an install by running
    the bundle's own installer;
  - is installed into `~/.local/share/lepton-release-manager/`.
- **The publisher** (`image-14/scripts/publish-release.sh`):
  - `--check`, `--execute` (creates a draft), `--publish`;
  - uses `gh`, and supports OpenSSH signatures.
- **Docs and tests:**
  - `RELEASING.md` and `.github/RELEASE_TEMPLATE.md`;
  - updated install documentation;
  - three new test files.

All tests pass on that branch. It isn't on GitHub, so on another computer ask
the user to commit and push it first, from the computer that has the worktree.

**Open points for the release:**
- **The repository isn't public:** the GitHub API answers 404 for
  `pjohno/lepton-x86_64`. Users and the release manager need it to be public.
- **No signing key exists yet.** Create one with `RELEASING.md` › "Release
  signing" and commit its public key before the first signed release.
  Otherwise publish with `--unsigned`; users then confirm a warning before
  installing.
- **Check on a real Deck:** Dolphin's handling of a downloaded `.install.sh`,
  and the manager's windows. These are listed in that branch's
  `PENDING-TESTS.md`.

## Facts learned in testing (do not re-investigate)

- **Kept game data only works with the exact bundle it was made on.**
  - Each bundle's sysbake creates its own Android user 0 and storage keys.
  - Data from another bundle hangs on "Phone is starting…", with
    `Failed to unwrap synthetic password` in logcat.
  - So clearing the data when a game's tool changes is correct; relaxing that
    was tried and withdrawn.
- **Steam's Stop does not save progress.** Android is stopped immediately, and
  games that save on pause (such as 2048) lose unsaved moves. Closing from
  inside the game saves. The user chose to keep this behaviour.
- **Files owned by Android's users** under `compatdata/<AppID>/baked` and in
  stages can't be deleted by a plain `rm`. Use `podman unshare rm -rf`.
- **Software rendering on Intel crashes.** Lepton is Steam Deck / AMD only for
  now.
- **The device files are copied once.** `prepare-x86_64.sh` copies
  `image-14/android_device_valve_lepton/` into the Android checkout
  (`aosp/device/waydroid/waydroid/`) only once. Later edits must be copied in
  by hand before rebuilding.

## Working notes

**Workspaces.** The `.build-env` workspace path differs per machine:
- build machine: `/mnt/025a620c-1a4d-4e70-acf1-c342593547f8/lepton-workspace`;
- Intel laptop: `/mnt/e46048ea-fde7-4f4d-acc9-49f1e7d6348e/lepton-workspace`.

The release worktree's `.build-env` uses
`LEPTON_OUTPUT_DIR="${LEPTON_OUTPUT_DIR:-…build machine path…}"`, so on the
laptop override it for each command.

**Running the tests.** `bash image-14/tests/run-workflow-tests.sh` runs them.
On a computer without `lpunpack`, put a stub `lpunpack` on `PATH` (only
`test-workspace-and-inputs` needs it). When testing, put stand-ins for
`zenity`, `kdialog`, `konsole` and `curl` first on `PATH`, so that no real
window opens and nothing is downloaded.

**On the Deck:**
- `lepton-manage-installs --remove` takes the **tool ID** (for example
  `lepton_x86_64_base_20261104`), not the bundle name.
- **Lepton: Check graphics** and **Lepton: Add Android game** use the
  **default** install, which is normally the one installed last; see
  `readlink -f ~/.local/bin/lepton-run-apk`.
- An experimental keep-data hot-fix was put on the Deck earlier and then
  withdrawn. Its backups end in `.before-keep-data-fix`. Reinstalling the
  bundles with `--replace` removes any trace of it.
