# Steam Deck Google-services test

> **Historical test record (2 November 2026).** Bundles now ship with a one-command
> installer; see [INSTALL-STEAM-DECK.md](../../INSTALL-STEAM-DECK.md) and [GAPPS.md](../../GAPPS.md).

Start in Desktop Mode on a Wayland session, as user `deck`. This test uses a
separate installation directory and private Podman store; it does not register
or replace the existing Steam compatibility tool. Keep NDK installed: selecting
`--expect-abi x86_64` makes this Play Games test native.

Transfer the generated archive, its `.sha256` file, and
`apks/com.google.android.play.games.apkm` to `~/Downloads` on the Deck. Verify
and extract the archive, refusing to overwrite an earlier test installation:

```bash
cd "$HOME/Downloads"
sha256sum -c lepton-x86_64-gapps-view-20261102.tar.gz.sha256 &&
  mkdir "$HOME/.local/share/lepton-gapps-test-20261102" &&
  tar -xzf lepton-x86_64-gapps-view-20261102.tar.gz \
    -C "$HOME/.local/share/lepton-gapps-test-20261102" --no-same-owner
```

Run the read-only preflight before starting Android. It reports missing host
tools; do not change SteamOS's read-only filesystem just to satisfy this test.
Desktop mode does not require Weston. The Deck needs Podman, fuse-overlayfs,
rsync, Python 3, unzip, attr tools, systemctl and the usual core utilities.

```bash
stage="$HOME/.local/share/lepton-gapps-test-20261102"
bash "$stage/tests/runtime/run-apk.sh" --stage-dir "$stage" \
  --apk "$HOME/Downloads/com.google.android.play.games.apkm" \
  --expect-abi x86_64 --app --profile playgames-native \
  --rendering amd --display desktop --network-sysctls --check
```

First run: setup and sign-in, without installing the game. The Store opens as a
background dependency. Enter credentials in Android only. If it reports an
uncertified device, register the GSF ID printed by the runner; the Fedora ID and
login have not been copied. Once sign-in finishes, use Ctrl+C in Konsole and
wait for cleanup to finish before starting the next command.

```bash
bash "$stage/tests/runtime/run-apk.sh" --stage-dir "$stage" \
  --expect-abi x86_64 --profile playgames-native --setup-only \
  --rendering amd --display desktop --network-sysctls --seconds 1800 --execute
```

Install and play, using the same stage and profile:

```bash
bash "$stage/tests/runtime/run-apk.sh" --stage-dir "$stage" \
  --apk "$HOME/Downloads/com.google.android.play.games.apkm" \
  --expect-abi x86_64 --app --profile playgames-native \
  --rendering amd --display desktop --network-sysctls --seconds 1800 --execute
```

Repeat this last command for later sessions. Unchanged installed APKs are reused;
Android account and game data are retained. Try Snake with arrows, then the Deck
screen. Desktop touch results do not establish Gaming Mode touch behavior. The
previously tested Gaming Mode path also requires Gamescope's touch-mode setting
and Steam Input's **Touchscreen Native Support**; use the saved-profile shortcut below for Gaming Mode.

Logs remain in `$stage/.runtime-profile.playgames-native/`, including
`lepton.log`, `app-logcat.log`, `activities.txt`, `package.txt` and `screen.png`.
The profile contains personal account data; do not transfer it back or publish
its contents wholesale. If the launch fails, report Konsole's first failure and
we can select the relevant diagnostics.

## Gaming Mode shortcut for the saved profile

Stop the running test first. From another Deck Konsole, use:

```bash
pkill -INT -f '[/]tests/runtime/run-apk.sh.*--profile playgames-native'
```

Wait for cleanup, then fully exit Steam from Desktop Mode. With the updated
shortcut helper and runner installed, create the shortcut:

```bash
python3 "$HOME/.local/share/lepton-gapps-test-20261102/compat_tool/tools/lepton-add-game" \
  "$HOME/Downloads/com.google.android.play.games.apkm" \
  --install-dir "$HOME/.local/share/lepton-gapps-test-20261102" \
  --runtime-profile playgames-native --expect-abi x86_64 \
  --name "Google Play Games (Lepton GApps)"
```

Use `--dry-run` to check before writing. The helper retains all existing shortcuts. It refuses an existing shortcut for this profile
and writes Steam's shortcuts only; it leaves compatibility-tool mappings
unchanged. No new compatibility-tool registration is needed: the shortcut runs
the saved-profile launcher through the installation's Gamescope bridge. Leave
**Force the use of a specific Steam Play compatibility tool** unchecked.

Restart Steam, find the entry under **Non-Steam**, enable **Touchscreen Native
Support** in its controller layout, then switch to Gaming Mode. The runner's
controller passthrough remains disabled for this test; map D-pad directions to
keyboard arrow keys for Snake. Touch and the bridge still need testing here.
`--until-exit` keeps the session running until the app exits or the runner is
stopped. Use Steam's Stop button first; if it fails to stop cleanly, use the
Konsole stop command above. The saved account/profile remains in place.
