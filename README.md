# Lepton x86_64

Run Android games from Steam on a Steam Deck.

Lepton x86_64 is a community port of [Valve's Lepton](https://gitlab.steamos.cloud/frame-public/lepton)
to x86_64 Linux. Each Android game becomes a normal Steam shortcut: you press
Play, and Lepton starts Android 14 in a container, shows the game (full screen
in Gaming Mode, in a window in Desktop Mode) with the Deck's controls and
touchscreen, and keeps its saves between launches.

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

**Desktop PCs** with a **Wayland** desktop can install Lepton too. On Fedora
GNOME and KDE Plasma, games run full screen with mouse and keyboard input.

Steam Deck / AMD RADV is the established hardware-accelerated path. Intel Gen9
(Skylake) and newer have experimental ANV/Iris support **only in bundles containing
`vendor/lib64/hw/vulkan.intel.so`**; published bundles may omit it. The launcher
selects AMD first, then Intel, with `LEPTON_VULKAN_DRIVER=radeon|intel` overrides.
Unsupported GPUs can try slow software rendering: install with `--allow-non-amd`
and launch with `LEPTON_FORCE_SOFTWARE=true %command%`. Hardware support outside
validated configurations remains experimental. **Fedora and other
SELinux-enforcing systems** need a small SELinux policy module installed once,
or Android never finishes starting: see
[desktop setup](compat_tool/LOCAL-DESKTOP.md#one-time-selinux-setup-fedora).

## Install on a Steam Deck

The full guide, with every step and troubleshooting, is **[INSTALL-STEAM-DECK.md](INSTALL-STEAM-DECK.md)**. In short:

1. **Switch to Desktop Mode** and open
   [GitHub Releases](https://github.com/pjohno/lepton-x86_64/releases).
2. **Download the three files** of the newest release into `Downloads`, keeping
   their names: the `.tar.gz`, the `.tar.gz.sha256` and the `.install.sh`.
3. **Run the installer** from a terminal (Konsole):
   ```bash
   cd ~/Downloads && bash lepton-x86_64-VERSION.install.sh
   ```
   It checks the download and the Deck, installs into `~/.local/share` and
   registers Lepton as a Steam compatibility tool, named with its version first
   (**lepton VERSION x86_64 (community)**). If anything fails, nothing is
   changed. Add `--steam-compat` to install it instead as a self-contained tool
   in Steam's own `~/.steam/root/compatibilitytools.d/`, like GE-Proton
   ([details](INSTALL-STEAM-DECK.md#installing-into-steams-compatibility-tool-folder-optional)).
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

**Google Play (GApps bundles you build yourself).** A GApps install can add
one Steam shortcut, **Google Play (Lepton)**. The installer offers it, and
**Lepton: Add Google Play to Steam** adds it later. It opens the Play Store:
install games there, play them, go back to Android's home screen with
Steam + D-pad Left (Esc), and start another game. Steam's Stop ends the
session. All games installed this way share that one shortcut's Android data,
which keeps them, the Google sign-in and their saves between launches.
Shortcuts added with **Lepton: Add Android game** keep their own separate
Android. You can import Steam artwork you have downloaded. A game being in the
Play Store doesn't mean it runs: ARM translation and Play Integrity limit many
games ([details](GAPPS.md#google-play-in-steam)).

With patch 0012 in the Android image, closing the game's direct Wayland desktop
window requests Android task removal and launcher teardown. Save in the game
first: window closing does not guarantee unsaved progress has been written.

## Launch options

Games need no launch options. These optional ones go in the shortcut's
Properties > Launch Options, followed by `%command%`:

| Option | Effect |
| --- | --- |
| `LEPTON_RESET_APP_DATA=true` | Permanently delete this game's Android profile (installed app, saves, logins) on the next launch. Back it up first and remove the option afterwards; shared storage is kept ([scope](INSTALL-STEAM-DECK.md#game-data-between-launches)) |
| `LEPTON_SHARED_FOLDERS=none` | Choose which host folders the game's Android sees in its shared storage. The default shares Documents, Downloads and Videos. `none` shares none; `Downloads` only that one; `"Downloads,~/Books,/run/media/deck/SD/Films"` adds any folders, shown as `Books` and `Films`; `:ro` makes one read-only ([details](compat_tool/configuration.md#shared-folders)) |
| `LEPTON_GAMEPAD_HOTPLUG=true` | Experimental: connect and disconnect controllers while the game runs (see [limitations](#known-limitations)) |
| `LEPTON_GAMEPAD_PASSTHROUGH=false` | Don't pass controllers to Android |
| `LEPTON_STOP_SAVE_WAIT=<s>`, `LEPTON_STOP_SHUTDOWN_WAIT=<s>` | Time given to the game to save at Stop (default 3 s) and to Android to shut down (default 5 s); `0` and `0` stop instantly |
| `LEPTON_NDK_TRANSLATION_MODE=light-translate-or-interpret` | ARM64 games on an NDK bundle: slower, most compatible translation |
| `LEPTON_DESKTOP_FULLSCREEN=1` | Desktop Mode: fill the screen instead of a movable window ([Desktop Mode](INSTALL-STEAM-DECK.md#desktop-mode-and-gaming-mode)) |
| `LEPTON_DESKTOP_TOUCH_MODE=1` | Desktop Mode: `1` mouse and single-touch emulation (default, no native multitouch), `0` pointer-only compatibility, `4` native multitouch with a known mouse-motion issue ([modes and caveats](INSTALL-STEAM-DECK.md#desktop-mode-and-gaming-mode)) |
| `LEPTON_GAMING_TOUCH_MODE=1` | Experimental Gaming Mode touch override: `0` hover, `1` touch as left-click, `4` passthrough (default); [hardware testing and caveats](INSTALL-STEAM-DECK.md#gaming-mode-touch-experiments) |
| `LEPTON_DESKTOP_DIRECT=1` | Experimental direct Wayland opt-in for unmarked tools; [local desktop installs](compat_tool/LOCAL-DESKTOP.md) use it by default |
| `LEPTON_LOCAL_FULLSCREEN=0` | Local desktop direct Wayland: disable the native fullscreen default (requires Phase 2 hwcomposer) |
| `LEPTON_LOCAL_USE_GAMESCOPE=1` | Local desktop installations: use the existing windowed Gamescope fallback |
| `LEPTON_RESOLUTION=WIDTHxHEIGHT` | Android's screen size; in Desktop Mode also the window's size |

## What works

- Android 14 games launched from Steam in Gaming Mode and Desktop Mode on the
  Steam Deck, with AMD hardware graphics (ANGLE on Vulkan, Mesa RADV).
- The Deck's touchscreen in Gaming Mode, its built-in controls, and Bluetooth
  controllers connected before the game starts, each as a separate Android
  controller.
- Saves kept between launches.
- Ordinary game audio (games that mix their own PCM). Android media-decoder
  audio through Codec2 is selected automatically: AMD images with patch 0013
  and Intel images with patches 0013 and 0014 use gralloc BLOB buffers without
  host heap access; older images require accessible host DMA-BUF heap access,
  otherwise Codec2 stays off.
  Software rendering can use BLOB buffers. AVC/video output problems remain;
  YouTube video playback is not established ([media details](GAPPS.md#media-decoder-selection)).
- Optional hardware video decoding (VA-API), off by default:
  `LEPTON_VIDEO_HWACCEL=true` in an app's launch options decodes H.264, HEVC
  (including Main10), VP9 and, on AMD, AV1 on the GPU
  ([video-vaapi.md](image-14/docs/video-vaapi.md)). HDR video is shown as SDR.
- Optional, in bundles you build yourself: Google Play services, ARM64
  translation for ARM-only games, and Widevine L3 DRM support
  ([GAPPS.md](GAPPS.md)).

Widevine provisioning and decryption support do not guarantee application playback
compatibility; decoder, video output and service restrictions still apply.

Compatibility varies from game to game: see the [tested games](GAMES.md).

## Known limitations

- **Release bundles are base bundles:** no Google Play services and no ARM64
  translation. Games that need either must be built with
  [GApps and NDK](GAPPS.md) yourself.
- **Desktop input:** Fedora KDE Wayland testing confirmed mouse and keyboard
  input with the desktop touch-mode fix; older bundles may still leave mouse
  coordinates at `(0,0)`. Desktop Mode now defaults to mode 1 for mouse and
  single-touch emulation; native multitouch requires mode 4, which has a known
  mouse-motion issue. Fedora mode-1 testing confirmed mouse, keyboard, focus and game interaction.
- **Controller hotplug** (`LEPTON_GAMEPAD_HOTPLUG=true`) gives Android read
  access to *all* the computer's input devices, not just controllers. Leave it
  off unless you need it.
- **Desktops other than GNOME and KDE Plasma on Wayland** are untested; X11
  is not supported. With several monitors or
  fractional scaling, Android may get the wrong screen size; set
  `LEPTON_RESOLUTION`.

## Documentation

| Guide | For |
| --- | --- |
| [INSTALL-STEAM-DECK.md](INSTALL-STEAM-DECK.md) | Installing, updating, several installs side by side, game data, troubleshooting |
| [GAMES.md](GAMES.md) | Games tested with Lepton, and how to report one |
| [BUILDING.md](BUILDING.md) | Building Android and the Deck bundles from source |
| [GAPPS.md](GAPPS.md) | Optional Google Play services, ARM64 translation and Widevine bundles |
| [CUSTOMIZING.md](CUSTOMIZING.md) | Customizing and repackaging bundles without an AOSP build |
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
| `0009-hwc-local-wayland-fullscreen.patch` | Native fullscreen and output selection for direct Wayland desktops |
| `0010-egl-hide-untranslatable-gl-extensions.patch` | Arm64 games under NDK translation don't see ANGLE GL extensions the translator can't forward (fixes Flutter/Skia games stuck loading) |
| `0011-hwc-present-framebuffer-after-color-layers.patch` | Desktop windows keep updating when the bottom layer is a color layer (letterboxed games such as Roblox stayed on their splash screen until Alt+Tab) |
| `0012-hwc-window-close-android14-task-codes.patch` | Closing the game's desktop window ends the game: the Waydroid task service used Android 13 binder codes, so on Android 14 the close removed nothing (also fixes per-task close/focus) |
| `0013-minigbm-gbm-mesa-no-allocator-map.patch` | Music and video apps decode audio without host DMA-BUF heap access: the AMD allocator no longer crashes on Codec2 buffers allocated through gralloc (Valve's upstream approach) |
| `0014-minigbm-gbm-mesa-blob-cpu-surface.patch` | The same on Intel: gralloc imports and maps Codec2 BLOB buffers as the 4096-wide surface they were allocated as, which iris accepts (issue #30) |
| `0016-minigbm-gbm-mesa-blob-direct-map.patch` | Media audio no longer drops out every few seconds on Intel: gralloc maps Codec2's byte buffers directly, so the decoder process always reads the bytes the app wrote (Mesa's staging maps delivered them only at unmap) |
| `0015-libopus-float-decode-x86_64.patch` | Loud music decoded by Android's Opus decoder no longer crackles: libopus is built floating-point on x86_64, so peaks above full scale are soft-clipped instead of flattened (apps such as Metrolist fall back to this decoder when their own is ARM-only) |
| `0017`–`0030` (video) | Optional hardware video decoding through VA-API (`LEPTON_VIDEO_HWACCEL=true`, off by default): FFmpeg's Codec2 service with Intel and Mesa VA drivers, HEVC Main10 for profile-checking apps, size limits from the driver, and direct GPU output into Android's buffers (4K60 10-bit on the tested Intel, AMD and Steam Deck GPUs). See [image-14/docs/video-vaapi.md](image-14/docs/video-vaapi.md) |

Patches 0012 (window close), 0013 (AMD allocator), 0014 (Intel BLOB mapping), 0015 (float Opus decoding) and 0016 (direct BLOB mapping) change Android components.
They require images containing those fixes; updating only the launcher cannot
add them to an older rootfs. Patch 0013 does not resolve AVC/video output.

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
