# Lepton x86_64

Run Android games from Steam on a Steam Deck.

Lepton x86_64 is a community port of [Valve's Lepton](https://gitlab.steamos.cloud/frame-public/lepton)
to x86_64 Linux. Each Android game becomes a normal Steam shortcut: you press
Play, and Lepton starts Android 14 in a container, shows the game full screen
with the Deck's controls and touchscreen, and keeps its saves between launches.

> **Unofficial and experimental.** This project is not affiliated with,
> supported by, or endorsed by Valve. It targets the Steam Deck; other
> computers are experimental.
>
> **AI Assistance Disclosure.** AI tools have been used to aid development
> in this repo. I (as author) maintain responsibility for the code, and
> have reviewed as much as possible. 
>
> **You provide the games.** This repository contains source code and build
> recipes only: no Android images, Steam binaries, apps or APKs. Releases
> contain a ready-built base bundle (see [Install](#install-on-a-steam-deck)).

## What you need

- A **Steam Deck** running SteamOS, signed in to Steam at least once.
- About **3 GiB free** in your home directory.
- An **internet connection** while installing. The installer downloads Google's
  `adb` tool directly from Google; it is not shipped in the bundle.
- The **Android games** you want to play, as `.apk` files or split-APK bundles
  (`.apkm`).

Desktop PCs with an **AMD GPU** can install Lepton, but this is experimental:
games start and draw, but mouse and keyboard don't reach them yet
([issue #9](https://github.com/pjohno/lepton-x86_64/issues/9)). Other GPUs are
not supported, because the Android image only contains AMD graphics drivers.

## Install on a Steam Deck

The full guide, with every step and troubleshooting, is **[INSTALL-STEAM-DECK.md](INSTALL-STEAM-DECK.md)**. In short:

1. **Switch to Desktop Mode** and open
   [GitHub Releases](https://github.com/pjohno/lepton-x86_64/releases).
2. **Download the three files** of the newest release into `Downloads`, keeping
   their names: the `.tar.gz`, the `.tar.gz.sha256` and the `.install.sh`.
3. **Run the installer** from a terminal (Konsole):
   ```bash
   cd ~/Downloads && bash lepton-x86_64-steamdeck-VERSION.install.sh
   ```
   It checks the download and the Deck, installs into `~/.local/share` and
   registers Lepton as a Steam compatibility tool. If anything fails, nothing
   is changed.
4. **Check graphics:** double-tap **Lepton: Check graphics** on the desktop. It
   should report the AMD (RADV) driver.

Later versions, updates and repairs: double-tap
**Lepton: Install / Update / Repair**
([details](INSTALL-STEAM-DECK.md#later-versions-updates-and-repair)).

## Add and play a game

1. Double-tap **Lepton: Add Android game** and pick the game's `.apk` or
   `.apkm`.
2. When asked, **exit Steam** (Steam menu > Exit) and tap **Steam is closed**.
   Lepton never closes or starts Steam itself.
3. Start Steam again. The game is under **Non-Steam games**, with Lepton already
   selected as its compatibility tool.
4. **Turn on touch:** in the game's controller layout, enable
   Controller Settings > Edit Layout > Default Action Set > Always-On Command >
   System > **Touchscreen Native Support**.

Then play it from Gaming Mode like any other game. The first launch installs
the game into Android and takes longer.

**Saves.** A game's Android data is kept between launches, in Steam's
compatdata folder for that shortcut. When you press **Stop** in Steam, Lepton
sends the game to the background and gives it a few seconds to save before
shutting Android down, so Stop takes a few seconds. Save inside the game
before pressing Stop: Lepton gives the game time to save, but can't make it
save. Switching a game to a different Lepton version keeps its Android data
when that version uses the same Android image. If the image differs, or the
installed APK no longer matches the game's file, Lepton stops with a message
and keeps the data. It never resets data on its own
([details](INSTALL-STEAM-DECK.md#game-data-between-launches)).

## Launch options

Games need no launch options. These optional ones go in the shortcut's
Properties > Launch Options, followed by `%command%`:

| Option | Effect |
| --- | --- |
| `LEPTON_RESET_APP_DATA=true` | Permanently delete this game's Android profile (installed app, saves, logins) on the next launch. Back it up first and remove the option afterwards; shared storage is kept ([scope](INSTALL-STEAM-DECK.md#game-data-between-launches)) |
| `LEPTON_GAMEPAD_HOTPLUG=true` | Experimental: connect and disconnect controllers while the game runs (see [limitations](#known-limitations)) |
| `LEPTON_GAMEPAD_PASSTHROUGH=false` | Don't pass controllers to Android |
| `LEPTON_STOP_SAVE_WAIT=<s>`, `LEPTON_STOP_SHUTDOWN_WAIT=<s>` | Time given to the game to save at Stop (default 3 s) and to Android to shut down (default 5 s); `0` and `0` stop instantly |
| `LEPTON_NDK_TRANSLATION_MODE=light-translate-or-interpret` | ARM64 games on an NDK bundle: slower, most compatible translation |
| `LEPTON_DESKTOP_WINDOWED=1`, `LEPTON_RESOLUTION=WIDTHxHEIGHT` | Desktop Mode: a 1280×800 window, or a window of any size, instead of full screen |

## What works

- Android 14 games launched from Steam in Gaming Mode and Desktop Mode on the
  Steam Deck, with AMD hardware graphics (ANGLE on Vulkan, Mesa RADV).
- The Deck's touchscreen, its built-in controls, and Bluetooth controllers
  connected before the game starts, each as a separate Android controller.
- Saves kept between launches.
- Audio and video playback (for example YouTube up to 1080p).
- Optional, in bundles you build yourself: Google Play services, ARM64
  translation for ARM-only games, and Widevine protected video
  ([GAPPS.md](GAPPS.md)).

Compatibility varies from game to game.

## Known limitations

- **Release bundles are base bundles:** no Google Play services and no ARM64
  translation. Games that need either must be built with
  [GApps and NDK](GAPPS.md) yourself.
- **Mouse and keyboard** don't reach games on desktop PCs yet, and a USB mouse
  on the Deck may interfere with touch.
- **Controller hotplug** (`LEPTON_GAMEPAD_HOTPLUG=true`) gives Android read
  access to *all* the computer's input devices, not just controllers. Leave it
  off unless you need it.
- **Desktops other than KDE Plasma** are untested. With several monitors or
  fractional scaling, Android may get the wrong screen size; set
  `LEPTON_RESOLUTION`.

## Documentation

| Guide | For |
| --- | --- |
| [INSTALL-STEAM-DECK.md](INSTALL-STEAM-DECK.md) | Installing, updating, several installs side by side, game data, troubleshooting |
| [BUILDING.md](BUILDING.md) | Building Android and the Deck bundles from source |
| [GAPPS.md](GAPPS.md) | Optional Google Play services, ARM64 translation and Widevine bundles |
| [RELEASING.md](RELEASING.md) | Maintainers: publishing a GitHub release |
| [FEDORA-DEBUGGING.md](FEDORA-DEBUGGING.md) | Testing APKs and debugging crashes on a Fedora build computer |
| [compat_tool/README.md](compat_tool/README.md) | Valve's Lepton runtime documentation |

## For developers

**Building.** [BUILDING.md](BUILDING.md) takes you from the Android sources to an
installable bundle in five commands, on an x86_64 Linux computer with about
350 GB of free space. Some build components are Git submodules.

**Tests.** The offline regression suite needs no Android build, Deck or network:

```bash
bash image-14/tests/run-workflow-tests.sh
```

To check a built image, boot it and run an APK with `tests/runtime/run-apk.sh`
([tests/runtime/README.md](tests/runtime/README.md)). Don't run
`.ci_scripts/run-tests.sh` on a normal desktop: it makes system-wide changes
and resets Podman.

**Android patches.** Source preparation applies Valve's patches, then these:

| Patch (`image-14/patches/`) | Purpose |
| --- | --- |
| `0001-mesa-android-sdk34-link-libzstd.patch` | Links Mesa with `libzstd` on Android 14 |
| `0002-radv-android-yv12-hardware-buffers.patch` | RADV imports YV12 video buffers, so video can be displayed |
| `0004-minigbm-gbm-mesa-driver.patch` | Real three-plane layout for YV12 buffers, so decoders can write frames |
| `0007-eventhub-preserve-evdev-axes.patch` | Keeps real controllers' axis ranges |
| `0008-inputreader-separate-steam-input-pads.patch` | Steam Input controllers appear as separate Android controllers |

**Where things are:**

| Path | Contents |
| --- | --- |
| `compat_tool/` | The Lepton runtime that Steam runs, with the x86_64 changes |
| `compat_tool/tools/` | Deck tools: installer, add-game, release manager, Gamescope bridge, host check |
| `image-14/` | Android 14 build configuration, device files and patches |
| `image-14/scripts/` | The build, bundle, install and release commands from [BUILDING.md](BUILDING.md) |
| `tests/`, `image-14/tests/` | Regression and runtime tests |

Changes to Valve's code are marked with `x86_64 port:` comments, so they can be
found when merging Valve's updates.

## Upstream, attribution and licences

This is a community modification of
[Valve's public Lepton project](https://gitlab.steamos.cloud/frame-public/lepton),
which remains the authoritative upstream. Keep Valve's copyright notices,
third-party attribution and licence headers in files taken from upstream.

**The repository is not covered by one licence.** See:

- [`LICENSE.md`](LICENSE.md): Valve's licence index.
- [`LICENSES/compat_tool.md`](LICENSES/compat_tool.md): MIT terms for the top
  level and the compatibility tool, with Valve's notice.
- [`LICENSES/image.md`](LICENSES/image.md): the Android image. The combined
  image has a GPL-3.0 declaration; its component projects keep their own
  licences.
- [`LICENSES/x86_64-contributions.md`](LICENSES/x86_64-contributions.md):
  original material written for this port. It does not relicense Valve,
  Android, Waydroid, Mesa or other third-party code.

Patches keep the licence of the code they modify. Google's `adb` is not in this
repository or in the bundles; the installer downloads the official
Platform-Tools from Google and checks it against a pinned checksum
([details](INSTALL-STEAM-DECK.md#google-adb)).

## Contributing

Bug reports and patches are welcome. Please include your hardware and OS, the
Lepton version, the game, how you launched it, and the relevant part of
`~/.steam/steam/logs/lepton-*.log`. Don't upload game files, Android images,
Steam binaries, credentials or personal data.
