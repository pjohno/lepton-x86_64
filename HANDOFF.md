# Handoff: base-bundle Roblox login not kept (2026-11-08)

Branch: `fix/base-login-persistence`, from `main` at `6f0feeb`. Delete this file before merging.

## The problem

On the **base** bundle (`base-r0`), Roblox asks for a sign-in at every launch.
On the **GApps** bundle (`gapps-ndk-wv-r0`), the sign-in is kept.

The Deck log from 2026-11-08 shows kept data being cleared only once: at 09:43,
"Android runtime changed", after a new Lepton install at 09:30. The launches at
09:48 and 09:51 kept the data, yet Roblox still asked for a sign-in. So Lepton
isn't clearing the data; the sign-in just isn't saved or isn't accepted.

## What was checked

- **Storage is the same for both bundles.** Both use
  `compatdata/<AppID>/baked/data_overlay`, the same fingerprint check and the
  same shutdown. The GApps sign-in flow (`lepton-google-game-gui`) also
  launches through the normal Steam compatdata path. The only GApps-only file
  is the marker `compatdata/<appid>/lepton-google-game`.
- **Valve's new commits don't affect it.** `main..valve/main` has 4 commits:
  `74e070a` (RLIMIT_NICE binder messages), `1b1a0be` (drop gdbpatch, fix
  patch ordering) and 2 merges. None of them touch app data or shutdown.
- **Likely cause.** The base-bundle Roblox log shows
  `BlockStoreManager: ... Blockstore.API is not available on this device`.
  With GApps, Roblox keeps its sign-in token in Google Play services' Block
  Store, which writes it straight away. On base, Roblox has to rely on its own
  files, and the instant shutdown in `kill_container`
  ([liblepton.sh:756-757](compat_tool/liblepton/liblepton.sh#L756-L757),
  Valve's code) may stop Android before they are saved:

  ```bash
  STOP_OUTPUT="$(podman exec -i "lepton-${CONTEXT}" /system/bin/reboot -p 2>&1 || true)"
  STOP_OUTPUT+="$(podman stop -t 0 "lepton-${CONTEXT}" 2>&1 || true)"
  ```

This hasn't been proven yet.

## Next step: test on the Deck (base bundle)

1. Launch Roblox and sign in.
2. Wait about 2 minutes in the game.
3. Stop it from Steam, then relaunch it.

- **Still signed in:** the instant shutdown is the cause. Implement the
  graceful shutdown below.
- **Signed out again:** Roblox needs Play services to keep a sign-in. Don't
  change Lepton; add "Roblox needs the GApps bundle to keep its sign-in" to the
  known limitations (`.github/RELEASE_TEMPLATE.md`, `INSTALL-STEAM-DECK.md`).

## Proposed fix (only if the test says so; needs the user's approval)

In `kill_container`, before `reboot -p`:

1. Send HOME (`input keyevent KEYCODE_HOME`) so the app goes to the background
   and saves its state.
2. Wait about 3 seconds.
3. Then run `reboot -p` and `podman stop` as now.

Comment it clearly as an x86_64 change to Valve's code, so it shows up when
merging Valve's updates. Add a test to the existing liblepton tests and run
`image-14/tests/run-workflow-tests.sh`.

## Still open for the alpha (`v0.1.0-alpha`)

- **Local `main` isn't pushed.** It is 5 commits ahead of `github/main`: the
  release framework merge, the signing key and image provenance. Push `main`
  before working on the other computer.
- **Valve merge (optional).** `1b1a0be` changes patch ordering, and patches are
  an image input. Merging it before the alpha means running `prepare --reset`
  and rebuilding the images. Either merge first and rebuild, or wait until
  after the alpha.
- **Fix 3 (GPL source pointer)**, recommended before going public: include the
  resolved AOSP manifest in the bundle and the release, and add a "Source code"
  section to the release notes.
- **Release steps** (the user runs them, from the main checkout with a clean tree):
  1. `image-14/scripts/build-images-x86_64.sh --execute` (writes `BUILD-INFO.txt`).
  2. `image-14/scripts/make-deck-bundle-x86_64.sh --execute --bundle-id v0.1.0-alpha`.
  3. `image-14/scripts/publish-release.sh --check --version v0.1.0-alpha --signing-key ~/.config/lepton-release/signing-key`.
  4. Install it by hand on the Deck and test.
  5. Run `publish-release.sh ... --execute`, which creates a draft release.
  6. Make the repo public, run `--publish`, then test Lepton: Install / Update / Repair on the Deck.
  7. Delete `PENDING-TESTS.md`, then announce.
- **The signing key** is only at `~/.config/lepton-release/signing-key` on the
  original computer. Copy it securely if you'll publish from the new one.
- **Clean-up.** The `feature/release-framework` branch and its worktree
  `../lepton86-public-releasefw` are merged and can be deleted.
- **Later:** desktop input (#9) and redraw (#8); mouse clicks not registering
  on the Deck (a Bluetooth mouse shows the pointer but clicks don't arrive);
  the "Logcat read failure" when dumping the log; `test-tool-entry` may be
  flaky.

## Standing rules

- No commit, push, tag, merge or publish without approval. The user runs the
  pushes.
- Never close or start Steam; ask the user.
- The release is Deck-only; desktop is experimental.
- Images and bundles must be built from the main checkout, not a worktree
  (worktrees don't share submodule checkouts).
