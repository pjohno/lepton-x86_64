# Lepton x86_64 {{VERSION}}

**Experimental.** Lepton x86_64 is a community Steam compatibility tool that runs
Android 14 games (APK and APKM) from Steam on x86_64 Linux. It is not made or
supported by Valve.

- Version: `{{VERSION}}`
- Source commit: `{{COMMIT}}`
- Released: {{DATE}}
- Release files: {{AUTHENTICATION}}

## Supported hardware

**Steam Deck only.** Desktop PCs with an AMD GPU can install this release, but
desktop use is experimental: games start and draw, but mouse and keyboard do
not reach them yet ([#9](https://github.com/pjohno/lepton-x86_64/issues/9)).
The Android image contains AMD graphics drivers only; other GPUs (for example
Intel) are not supported.

## Install

**First time** (Steam Deck, Desktop Mode):

1. Download these three files into the same folder (for example `Downloads`):
   - `lepton-x86_64-steamdeck-{{VERSION}}.tar.gz`
   - `lepton-x86_64-steamdeck-{{VERSION}}.tar.gz.sha256`
   - `lepton-x86_64-steamdeck-{{VERSION}}.install.sh`
2. Run the installer. In Dolphin, right-click an empty part of that folder,
   choose **Open Terminal Here**, and enter:

   ```
   bash lepton-x86_64-steamdeck-{{VERSION}}.install.sh
   ```

The installer needs an internet connection; it doesn't need root or a password.

**Later versions:** open **Lepton: Install / Update / Repair** from the desktop or
the application menu.

See [INSTALL-STEAM-DECK.md](https://github.com/pjohno/lepton-x86_64/blob/{{COMMIT}}/INSTALL-STEAM-DECK.md)
for details, including installing by double-click.

## What's included

- **Included:** the Android 14 (x86_64) image, the Lepton compatibility tool,
  and the Steam integration.
- **Downloaded during installation:** Google's Android Debug Bridge (adb). The
  installer downloads the official Platform-Tools from Google and checks the
  pinned version and SHA256. adb is not redistributed here.
- **Not included in the base release:** Google apps (GApps), ARM64 NDK
  translation and Widevine DRM. These need Google files that each user prepares
  locally (see GAPPS.md).

## Known limitations

- **Game compatibility varies:** many games work, some don't, and some need
  Google services.
- **Android profile compatibility:** launcher-only releases can reuse data when
  the Android runtime and sysbake are unchanged. Different or unknown runtime
  fingerprints preserve the profile and stop launch; they never reset it
  automatically. Independently generated sysbakes may be incompatible even
  with identical Android sources. Older tools can still contain reset bugs.
- **Steam's Stop button** gives the game a few seconds to save before Android
  shuts down, so Stop takes a few seconds. A game that only saves at certain
  points (for example at checkpoints) can still lose progress since its last
  save; to be safe, close the game from inside the game.
- **Desktop PCs** are experimental: no mouse or keyboard input in games yet (#9),
  and the picture may only update after switching windows (#8).

<!-- Maintainer: replace this comment with the changes since the previous release. -->
