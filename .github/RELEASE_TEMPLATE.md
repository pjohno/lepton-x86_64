# Lepton x86_64 {{VERSION}}

**Experimental.** Lepton x86_64 is a community Steam compatibility tool that runs
Android 14 games (APK and APKM) from Steam on x86_64 Linux. It is not made or
supported by Valve.

- Version: `{{VERSION}}`
- Source commit: `{{COMMIT}}`
- Released: {{DATE}}
- Release files: {{AUTHENTICATION}}

## Supported hardware

**Steam Deck (and other AMD GPUs).** The Android image contains AMD graphics
drivers only. Software rendering for other GPUs (for example Intel) is
experimental and is not part of this release.

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
- **Each release has its own Android image.** Android app data (installed apps,
  sign-ins, saves stored only on the device) does not move between releases or
  other independently built bundles. When a game switches to a different Lepton
  tool, or its tool is updated or downgraded, the game starts with fresh Android
  data. Shared storage (`/sdcard`) and online or cloud saves are kept.
  **Repairing** the same version keeps the data.
- **Steam's Stop button** stops Android immediately, so a game may lose progress
  it has not saved yet. To keep progress, close the game from inside the game.
- **Intel software rendering** is experimental and is not part of this release.

<!-- Maintainer: replace this comment with the changes since the previous release. -->
