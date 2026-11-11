# Optional Google services on Android 14

The x86_64 pipeline can assemble Google Play services, Google Services Framework,
Play Store (a dependency of the tested Play Games SDK), and matching
Chrome/Trichrome from locally extracted Android 14 Google Play emulator images.
`--with-gapps` enables this payload; the default image stays Google-free.
`--with-ndk` independently enables ARM64 translation. Native x86_64 apps still run
natively when NDK is installed.

No Google binaries, games, credentials or signed-in profiles are stored in Git.
The scripts do not download Google components. Both GApps and the NDK
translator come from one file you download yourself: the Android SDK system
image *Google Play Intel x86_64 Atom System Image, API 34, revision 14*
(`x86_64-34_r14.zip`). Chrome from that image is version 113 and should be
updated before general browsing. Extraction preserves privileged partition
placement and permission XML, unpacks Chrome/Trichrome, and extracts x86_64
native libraries. Payload and input image SHA256 hashes are recorded under
`compat_tool/provenance/gapps/`.

## Building a GApps + NDK bundle

1. Turn the zip into the two inputs and add the printed lines to `.build-env`:

   ```bash
   bash image-14/scripts/prepare-google-inputs.sh --zip /path/to/x86_64-34_r14.zip \
       --output /path/to/lepton-inputs/google-play-api34-r14
   ```

2. Build Android as in [BUILDING.md](BUILDING.md), then make the bundle:

   ```bash
   bash image-14/scripts/make-deck-bundle-x86_64.sh --execute --bundle-id gapps-ndk-20261104 \
       --with-gapps --with-ndk
   ```

Omit `--with-ndk` for an x86_64-only GApps bundle, or `--with-gapps` for ARM64
translation without Google services. The patch series restores the
LocaleManager and CrossProfileApps services and uses Android-first VIEW
routing, so a freshly built rootfs needs no hand-patched services.jar. The GApps
preflight refuses an older rootfs that lacks these fixes (rebuild it, or, for
testing only, supply a tested `--services-jar FILE`).

## Optional Widevine (protected video)

Add `--with-widevine` to the bundle command to include Widevine, Android's DRM
system for protected video. It comes from the same Google Play image
(`vendor.img`, the `com.google.android.widevine` APEX), nothing is
downloaded, and it is **L3 only**: software decryption, so services that offer
HD only to hardware-backed (L1) devices limit playback to SD.

Tested: Android reports Widevine L3 (CDM 18), and the Widevine test streams on
the Shaka Player demo play in a browser (Firefox or Edge from the Play Store)
on a Steam Deck, so provisioning, licences and decryption work. Individual
services may still refuse Lepton for their own reasons, for example a root or
device-integrity check, since Lepton is a debuggable build that cannot pass
Google Play Integrity. Lepton does not work around such checks.

## Install alongside another Deck bundle

Transfer the archive, `.sha256` and `.install.sh` files together (for example
with `transfer-deck-bundle.sh`, see [BUILDING.md](BUILDING.md#6-send-the-bundles-to-the-deck)), then in Desktop Mode:

```bash
bash ~/Downloads/lepton-deck-bundles/lepton-x86_64-gapps-v1.install.sh
```

The installer verifies the checksum, extracts to a new directory named after the
tool ID, registers the tool and makes it the default for `~/.local/bin/lepton-*`.
Restart Steam afterwards. Each bundle needs its own `--tool-id`; conflicting
registrations and existing destination directories are refused unless you choose
to replace an install (`--replace`, `--into TOOL_ID`, or the choice offered by the
desktop icon); a replaced install holding saved Google profiles is kept as a
`.previous-*` copy. GApps packaging defaults to `lepton_gapps_<bundle-id>`
(dots and hyphens become underscores) and a normal package to
`lepton_x86_64_<bundle-id>`, so neither reuses the legacy `lepton_x86_64_dev`. See
[INSTALL-STEAM-DECK.md](INSTALL-STEAM-DECK.md) for the full flow.

## Registration, install/play, then Gaming Mode

**Tap-only (recommended).** GApps installs put two icons on the desktop:

- **Lepton: Add Google game (<bundle>)**: pick the game (`.apk` or `.apkm`) and
  confirm its name. Step 1 opens Android in a window, installs the game and
  shows the Play Store: sign in to Google and tap **Done**. Step 2 opens the
  game: check it and tap **Done**. Step 3 asks you to exit Steam, then adds a
  normal Steam shortcut. If Google says the device is not certified, the dialog
  shows the GSF ID to register at google.com/android/uncertified.
- **Lepton: Google sign-in (<bundle>)**: sign in again for a Google game.

Google games use the **normal Steam launch path**, like every other game. Their
installed app, saved data and Google sign-in live in the shortcut's Steam
compatdata, so in **Properties > Compatibility** they can be switched to another
GApps install and keep the sign-in (a different Android build may make Lepton
reinstall the app; see INSTALL-STEAM-DECK.md, "Game data between launches").
Lepton refuses to start them on a tool without Google services and says so.
Split bundles (`.apkm`) are unpacked once into compatdata; ARM64-only games
need an install with ARM translation (NDK). During sign-in the Play Store may
update Google Play services and restart; the session continues until **Done**.

Nothing closes or starts Steam; start Steam again when told it is safe.

**Saved-profile runner (test tool).** `tests/runtime/run-apk.sh` with
`--profile` runs a separate, isolated Android with its own profile inside the
install. It is kept for diagnostics only: it is not the path Steam uses, and
its audio output does not reach the host. Start from the Deck's Wayland Desktop
Mode, without sudo, for the steps below. Place the
game/APKM outside the installation directory. For the tested native Play Games APKM:

The runner uses the default (most recently installed) bundle, with AMD rendering
on the desktop; pass `--stage-dir DIR` to select another installation.

```bash
~/.local/bin/lepton-run-apk --profile playgames-native --setup-only \
  --network-sysctls --seconds 1800 --execute
```

Sign in within Android. Only if Google requests uncertified-device registration,
register the displayed GSF Android ID in your own browser; this is not Play
Integrity or manufacturer certification. Stop setup with Ctrl+C and wait for
cleanup. If the Deck virtual keyboard cannot send Ctrl+C, use another Konsole:

```bash
pkill -INT -f '[/]tests/runtime/run-apk.sh.*--profile playgames-native'
```

Install/play with the same profile; subsequent runs reuse unchanged packages:

```bash
~/.local/bin/lepton-run-apk --profile playgames-native --app --expect-abi x86_64 \
  --apk "$HOME/Downloads/com.google.android.play.games.apkm" \
  --network-sysctls --until-exit --execute
```

Stop the running session, fully exit Steam, and add the saved-profile shortcut:

```bash
~/.local/bin/lepton-add-game "$HOME/Downloads/com.google.android.play.games.apkm" \
  --runtime-profile playgames-native --expect-abi x86_64 \
  --name "Google Play Games (Lepton GApps)"
```

Restart Steam, then launch from Non-Steam in Gaming Mode. Keep compatibility-tool
forcing unchecked on this shortcut: it starts the saved-profile runner through
this bundle's Gamescope bridge. Enable **Touchscreen Native Support** in Steam
Input; for Snake, map D-pad directions to arrow keys. The test runner disables
native controller passthrough. The saved-profile shortcut has no observation
timeout. Steam Stop should end the session; the Konsole stop command is a
fallback. Gaming Mode shortcut behavior remains to be confirmed on the Deck.

Profiles live under `$stage/.runtime-profile.NAME/`. They retain Google identity,
account data, game state and installed splits, and are never packaged. One game
package is pinned to each profile. Runtime fingerprint changes require explicit
`--accept-runtime-update`; ordinary launches need no registration or reinstall.
Profiles are separate from the kept game data of normal APK shortcuts (see
INSTALL-STEAM-DECK.md, "Game data between launches"). Replacing an install moves
its profiles into the new copy, so sign-ins are kept; after an Android image
change the runner asks for `--accept-runtime-update` before reusing them.

## Fixes and evidence

| Change | Why it was needed |
| --- | --- |
| Restore LocaleManagerService | Modern apps call Android's locale API; Valve disabled its startup. |
| Restore CrossProfileAppsService | Its absence caused a repeated GMS crash loop during sign-in. |
| Android-first ACTION_VIEW | Valve returned success while swallowing embedded games, links and callbacks. Android now resolves these normally; `LEPTON_FORWARD_WEB_INTENTS=true` opts into forwarding only implicit HTTP(S) links to Steam. |
| Launcher activity aliases | Play Games launches through an activity-alias; extract the alias and skip disabled aliases. |
| Correct package-manager wrapper | Fix the active-app property typo and avoid treating UID tokens as package names. |
| Persistent test profiles | Preserve registration and sign-in; install unchanged APK/APKM only once. |
| Host-side GSF ID reader | Guest sqlite3 crashes during ICU initialization; use Python SQLite in Podman's user namespace. |
| Fedora SELinux handling | Keep the existing container-only `label=disable` configuration; packaging strips host `security.selinux` xattrs while preserving `user.*`. Host SELinux stays enabled. |
| Private network sysctl opt-in | Fedora netd needed writes under the container's private `/proc/sys` for IPv4; no host-network sysctls are changed. |
| NDK event hints | SEV/SEVL/WFE are handled as nonblocking hints for the reviewed bridge; unsupported instructions still fail. |

User-confirmed: AAAAXY and SuperTuxKart gameplay in earlier native/translated tests;
Google sign-in, Play Games home and Snake keyboard gameplay on Fedora; native
Play Games installed and ran on the Deck using the persistent desktop runner.
The Deck Gaming Mode shortcut was prepared but has not been confirmed working.

Kingdom and Crossy Road are still unresolved ARM64 cases. Google login alone is
not evidence those games work. Codec2 experiments remain opt-in (`--codec2`):
decoders enumerate, but AVC output hits a gralloc YCbCr layout failure; YouTube
media playback is not fixed. The default codec setting has not been changed.

Validate without Android boot or network:

```bash
bash image-14/tests/run-workflow-tests.sh
cargo test --offline --release --locked \
  --manifest-path compat_tool/liblepton/apk_extractor/Cargo.toml
```

## Milestone artifact, 2 November 2026

The integrated deployer assembled `deck-stage-gapps-milestone-20261102` under the
configured build output using the standard compiled rootfs, the local API 34 r14
Google Play partitions, the reviewed NDK v2 payload and the tested framework
SHA256 `d82f1d0afa895cd849ad035fb7f07aaea1b961d02e46715844b09b87fa49b28e`.
Fresh offline sysbake was generated; no signed-in test profile was reused.

The local bundle is
`$LEPTON_OUTPUT_DIR/deck-bundles/lepton-x86_64-gapps-milestone-20261102.tar.gz`,
with its `.sha256` companion. It uses tool ID and suggested installation directory
`lepton_gapps_milestone_20261102`, displayed as **Lepton Android 14 GApps (milestone)**.
The archive includes `GAPPS.md`, `BUNDLE.json`, exact installation instructions,
updated profile/shortcut tools and payload provenance. Games must be transferred
separately. The existing Deck test installation remains usable alongside it.
