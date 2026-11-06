# Pending tests for `release/adb-and-local-install`

Delete this file when the branch is merged into `main`.

## What the branch adds

Each item is one commit:

- **Steam Deck installer downloads Google ADB.** Bundles no longer contain it.
- **Add-game changes:**
  - the picker accepts `.apkm` files;
  - games whose shortcut was deleted can be added again;
  - desktop Steam with no `CompatToolMapping` section works.
- **Build recovery after a power cut:** `build-images-x86_64.sh --repair`, and an
  "unfinished build" marker.
- **Local install and host check:** `install-local.sh` and `lepton-host-check`.
- **Double-click reinstall:** double-clicking an installed bundle offers "Reinstall".
- **Stronger tests:** "must not" checks that can now fail, and no real dialogs
  during tests.

The local suite passes:

```
bash image-14/tests/run-workflow-tests.sh
```

On a computer without `lpunpack`, put a stub `lpunpack` on `PATH`. Only
`test-workspace-and-inputs` needs it.

## Already confirmed on the Steam Deck

These were tested with a bundle from this code (before the last two commits):

- **Roblox (`.apkm`)** installs and runs on the base bundle.
- **A game's data is kept between launches on the same tool**, when the game is
  closed from inside the game (see Facts below).

## Still to test

Make a fresh bundle from this branch first. Keep the bundle ID `combined-test`,
so that installing it also tests item 1.

### On the Deck

1. **Double-click reinstall.** Double-click the new `combined-test` installer.
   - The first choice is "Reinstall … over the existing copy" and is preselected.
   - The install is replaced.
   - Game data is kept.
2. **ADB download.** Run:
   ```
   cat ~/.local/share/lepton_x86_64_combined_test/tools/platform-tools/SOURCE.txt
   ```
   It should say "downloaded by the Lepton installer", with the verified SHA256.
3. **Re-adding a deleted shortcut.**
   1. Delete a game's shortcut in Steam.
   2. Restart the Deck.
   3. Add the same game again with the same name using "Lepton: Add Android game".
   - Expected: the game is added, with the note "Reusing the saved game data".
   - Without the restart: a "restart the Steam Deck" hint.
4. **GApps and NDK bundles with the ADB change.** These have never been tested
   on hardware. Make both bundles from this branch, install them, and check:
   - Google sign-in;
   - an ARM64 game.
5. *(Optional)* **Offline install.** Run the installer with
   `--adb-zip platform-tools_r37.0.1-linux.zip`.

### On the build machine

6. **Build recovery on a real build.** On a finished build, run:
   ```
   bash image-14/scripts/build-images-x86_64.sh --repair
   ```
   - It must report **0** damaged files.
   - `--check` must then not warn about an unfinished build.

### On the desktop with an AMD GPU (Intel CPU)

7. **Local install.**
   1. Run `install-local.sh --check --bundle-id <id>`.
   2. Run `install-local.sh --execute --bundle-id <id>`, without
      `--allow-non-amd`.
   3. Run "Check graphics".
   4. Add a game and play it. This also tests the `CompatToolMapping` fix,
      because desktop Steam often lacks that section.
   - If the machine also has an Intel iGPU: confirm games use the AMD GPU.

The workspace path differs per machine. Set `LEPTON_OUTPUT_DIR` in `.build-env`,
or override it for one command, for example:

```
LEPTON_OUTPUT_DIR=/mnt/…/lepton-workspace bash image-14/scripts/install-local.sh …
```

## Facts learned in testing (do not re-investigate)

- **Kept game data only works with the exact bundle it was made on.**
  - Each bundle's sysbake creates its own user 0 and storage keys.
  - Starting one bundle's data on another hangs on "Phone is starting…", with
    `LockSettingsService: Failed to unwrap synthetic password` in logcat.
  - So clearing the data on a tool switch (`check_kept_app_data`) is correct.
  - Relaxing that check was tried and withdrawn.
  - Possible later improvements: move the data aside instead of deleting it,
    restore it on switching back, or warn at launch.
- **Steam's Stop does not save game progress.**
  - Lepton stops Android immediately (`reboot -p`, then `podman stop -t 0`,
    which is Valve's code).
  - So games that save when paused, such as 2048, lose unsaved moves.
  - Closing the game from inside the game saves.
  - This was kept on purpose: on Steam you save manually.
- **Lepton's host-side `rm -rf` cannot delete files that belong to Android's
  users** (subuids under rootless Podman).
  - A failed or partial clear leaves a half-deleted `compatdata/<AppID>/baked`.
  - Remove it with `podman unshare rm -rf`.
- **Software rendering (non-AMD GPUs) crashes on Intel.**
  - It is on its own branch, `feature/software-launch`, and is not merged.
  - Lepton is Steam Deck / AMD only for now.
