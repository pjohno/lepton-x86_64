# Lepton x86_64 {{VERSION}}

**Experimental.** Lepton x86_64 is a community Steam compatibility tool that runs
Android 14 games (APK and APKM) from Steam on x86_64 Linux. It is not made or
supported by Valve.

- Version: `{{VERSION}}`
- Source commit: `{{COMMIT}}`
- Released: {{DATE}}
- Release files: {{AUTHENTICATION}}

## Supported hardware

**Steam Deck** is the main target. Desktop PCs with a Wayland desktop can
install this release; desktop use is experimental (earlier tests on
Fedora GNOME and KDE Plasma, with mouse and keyboard input). **Fedora and other
SELinux-enforcing systems** need a one-time SELinux policy module, or Android
never finishes starting: see
[one-time SELinux setup](https://github.com/pjohno/lepton-x86_64/blob/main/compat_tool/LOCAL-DESKTOP.md#one-time-selinux-setup-fedora).
Steam Deck / AMD RADV is the established hardware-accelerated path. Intel Gen9
(Skylake) and newer have experimental ANV/Iris support **only in bundles containing
`vendor/lib64/hw/vulkan.intel.so`**; published bundles may omit it. The launcher
selects AMD first, then Intel, with `LEPTON_VULKAN_DRIVER=radeon|intel` overrides.
Unsupported GPUs can try slow software rendering: install with `--allow-non-amd`
and launch with `LEPTON_FORCE_SOFTWARE=true %command%`. Hardware support outside
validated configurations remains experimental.

Direct Wayland window-close task removal requires Android patch 0012; AMD
Codec2 BLOB allocation requires patch 0013, and Intel requires 0013 and 0014. Launcher updates alone cannot add
those image fixes. Ordinary game audio is separate from Codec2 media audio;
automatic Codec2 selection depends on the image, GPU and host heap permissions.
AVC/video output still has known problems, and Widevine L3 support does not
guarantee application playback. Consult the release's recorded hardware results.

## Install

**First time** (Steam Deck, Desktop Mode):

1. Download these three files into the same folder (for example `Downloads`):
   - `lepton-x86_64-{{VERSION}}.tar.gz`
   - `lepton-x86_64-{{VERSION}}.tar.gz.sha256`
   - `lepton-x86_64-{{VERSION}}.install.sh`
2. Run the installer. In Dolphin, right-click an empty part of that folder,
   choose **Open Terminal Here**, and enter:

   ```
   bash lepton-x86_64-{{VERSION}}.install.sh
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
- **Desktop PCs** are experimental: only Fedora GNOME and KDE Plasma on
  Wayland have been tested, and SELinux-enforcing systems need the one-time policy module (see
  Supported hardware).

<!-- Maintainer: replace this comment with the changes since the previous release. -->
