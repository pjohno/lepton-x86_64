# Build a bundle and install it on a Steam Deck

This guide goes from a built Android 14 x86_64 image to an Android game running
from Steam on a Steam Deck with AMD hardware graphics. It assumes you have
already compiled the Android images (see [README](README.md#building-and-deploying-android-14-x86_64)
or run `image-14/do_build_x86_64.sh` to do everything from source).

Nothing here downloads Android images, Google apps or games for you. You provide
your own APK files.

## What you need

**Build computer**: x86_64 Linux (tested on Fedora), rootless Podman, and the
compiled Android output configured in `.build-env`. The bundle step needs about
5 GiB of free space in addition to the Android output (more with Google apps).
Missing host commands are reported by `--check`.

**Steam Deck**: SteamOS in Desktop Mode, signed in to Steam at least once, and
about 3 GiB free in your home directory per install. Any
other x86_64 Linux machine with an **AMD GPU** also works; other GPUs are not
supported (the image only contains AMD RADV/radeonsi drivers).

## 1. Make the bundle (build computer)

From the repository root, choose a new bundle ID (letters, digits, `.`, `-`, `_`):

```bash
bash image-14/scripts/make-deck-bundle-x86_64.sh --check   --bundle-id my-deck-01
bash image-14/scripts/make-deck-bundle-x86_64.sh --execute --bundle-id my-deck-01
```

This stages the Android rootfs, provisions the Deck helper tools, bakes Android's
first-boot data in a private Podman store, and writes three files to
`LEPTON_DECK_BUNDLE_DIR` (default `~/lepton-deck-bundles`):

| File | Purpose |
| --- | --- |
| `lepton-x86_64-steamdeck-my-deck-01.tar.gz` | The bundle |
| `lepton-x86_64-steamdeck-my-deck-01.tar.gz.sha256` | Checksums |
| `lepton-x86_64-steamdeck-my-deck-01.install.sh` | One-command installer |

Optional extras: `--with-gapps --google-images DIR` (Google Play services, see
[GAPPS.md](GAPPS.md)) and `--with-ndk --ndk-payload DIR` (ARM64 app translation).
Existing stages and bundles are never overwritten; use a new bundle ID instead.

## 2. Copy it to the Deck

**Over the network (SSH).** On the Deck, once: open Konsole in Desktop Mode, set
a password with `passwd`, and run `sudo systemctl enable --now sshd`. Find the
Deck's IP address in Settings > Internet. Then on the build computer:

```bash
bash image-14/scripts/deploy-compat-x86_64.sh --transfer-only --execute \
    --bundle-id my-deck-01 --deck-ip 192.168.1.50
```

This copies all three files to `~/Downloads/lepton-deck-bundles/` on the Deck,
verifies the checksum there, and puts an **Install Lepton my-deck-01** icon on the
Deck's desktop. You can also add `--deck-ip` to step 1.

**By USB drive.** Copy the three files into one folder on the Deck.

## 3. Install (Steam Deck, Desktop Mode)

Double-tap **Install Lepton my-deck-01** on the desktop. (After a USB copy,
double-tap the `.install.sh` file in Dolphin instead.) A Konsole window shows
progress. From a terminal, the same is:

```bash
bash ~/Downloads/lepton-deck-bundles/lepton-x86_64-steamdeck-my-deck-01.install.sh
```

The installer:

1. verifies the checksum and that an AMD GPU is present;
2. extracts to `~/.local/share/<install directory>` (it refuses to overwrite);
3. registers the Steam compatibility tool **Lepton x86_64 (community) - my-deck-01**;
4. writes `~/.config/lepton-x86_64/<tool id>.env` and makes it the default;
5. links `lepton-add-game`, `lepton-add-game-gui` and `lepton-run-apk` into `~/.local/bin`;
6. adds **Lepton: Add Android game** and **Lepton: Check graphics** to the desktop
   and to the application menu (Games).

When started from the desktop icon and other Lepton installs exist, the
installer first asks whether to **install as a new tool** or **replace** one of
them, and afterwards offers a tick-list of older installs to remove. Steam does
not need to be closed for installing, replacing or removing (only for adding
games); restart Steam afterwards so it shows the new tool.

Terminal options: `--check` verifies without installing; `--into TOOL_ID`
replaces an existing install; `--replace` replaces this bundle's own earlier
install; `--remove TOOL_ID` (repeatable) removes others after installing;
`--keep-previous` keeps the replaced copy as `<directory>.previous-<date>`.

## 4. Check graphics

Double-tap **Lepton: Check graphics**, or run
`~/.local/bin/lepton-run-apk --gpu-check --execute`. This boots Android once
without any app (about a minute) and must end with
`[PASS] Hardware acceleration: ANGLE on Vulkan/RADV`. On a Steam Deck the
graphics line names `RADV VANGOGH`.

## 5. Add a game

Steam must be closed while a shortcut is added, and its on-screen keyboard
closes with it, so the add-game window needs only taps:

1. Double-tap **Lepton: Add Android game**, pick the APK and confirm the name
   (this is checked while Steam is still running).
2. When asked, **exit Steam yourself**: Steam menu (top left) > Exit, or
   right-click the Steam taskbar icon > Exit. Wait until both have gone, then
   tap **Steam is closed**.
3. When it reports success, it is **safe to start Steam again**. The game appears
   under Non-Steam games with the Lepton tool selected.

Lepton never closes or starts Steam itself. If Steam is still running at step 2,
nothing is changed; close Steam and try again.

From a terminal, with Steam exited: `~/.local/bin/lepton-add-game ~/Downloads/my-game.apk`
(add `--dry-run` to check first, which also works while Steam runs, and
`--name "Title"` to change the Steam name).

**Touch input**: in the game's controller layout enable
Controller Settings > Edit Layout > Default Action Set > Always-On Command >
System > **Touchscreen Native Support**. Without it, the Deck's touchscreen
does not reach Android.

Controllers present at launch are passed to Android. Live controller hotplug is
experimental (`--hotplug`) and exposes all host input devices to the container.

## Several installs side by side, replacing and removing

Each bundle ID installs as its own Steam tool (`lepton_x86_64_<bundle-id>`, or
`lepton_gapps_<bundle-id>` with Google apps), so an older install such as
`~/.local/share/lepton-x86_64-dev` is left alone unless you choose to replace it.
`lepton-add-game` uses the most recently installed one; pick another with
`--tool-id <tool id>`.

**Replacing** an install keeps its tool ID and directory, so the games already
added for it keep working; Steam shows the new bundle's name after a restart.
If the replaced install holds saved app profiles (for example a Google
sign-in), its old copy is kept as `<directory>.previous-<date>` so nothing is
lost; the removal list shows profile counts.

**Removing**: double-tap **Lepton: Remove installs** and tick what to delete.
It lists every Lepton install (including older manual ones registered with
Steam), leftover `.previous-*` backups and unregistered Lepton folders, with the
number of Steam shortcuts using each. In a terminal:

```bash
~/.local/bin/lepton-manage-installs --list
~/.local/bin/lepton-manage-installs --remove TOOL_ID            # shows what would happen
~/.local/bin/lepton-manage-installs --remove TOOL_ID --execute
```

An install that is running a game or test is never replaced or removed. If the
default install is removed, the newest remaining one becomes the default. Steam
shortcuts that used a removed tool stay in Steam; delete them there or select
another compatibility tool for them. The downloaded archives in
`~/Downloads/lepton-deck-bundles/` are not touched; delete them in Dolphin when
no longer needed.

## How games are started

Each installed tool is self-contained: Steam starts the tool's own
`lepton-x86_64-entry`, which uses that install's Gamescope bridge and ADB. Game
shortcuts therefore have **empty launch options**, and changing a game's
compatibility tool in Steam (Properties > Compatibility) switches everything at
once. Optional per-game settings still go in the launch options, for example
`LEPTON_GAMEPAD_HOTPLUG=true %command%`. `LEPTON_NO_BRIDGE=true %command%`
starts without the nested Gamescope (for debugging).

## Starting again from a clean slate

To remove every Lepton install and trace from a Deck, run from the build
computer (SSH as in step 2; Steam may stay open, no game may be running):

```bash
bash image-14/scripts/deck-clean-slate.sh --deck-ip 192.168.1.50 --check     # list
bash image-14/scripts/deck-clean-slate.sh --deck-ip 192.168.1.50 --execute   # remove
```

It removes installs, backups, Steam tool registrations, settings, command links,
menu/desktop icons, downloaded bundles and stopped Lepton containers. Android app
data (game saves) is kept unless you add `--game-data`. Delete the game shortcuts
in Steam yourself and restart Steam afterwards. On the Deck itself, use `--local`
instead of `--deck-ip`.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Installer: `No AMD GPU found` | Only AMD GPUs are supported. |
| GPU check reports SwiftShader | `LEPTON_FORCE_SOFTWARE` is set, or `/dev/dri` is not accessible to your user. |
| Game shows no touch input | Touchscreen Native Support (step 5). |
| Lepton missing in Steam's compatibility list | Restart Steam after installing. |
| Logs | `~/.steam/steam/logs/lepton-*.log`; GPU-check logs are listed at the end of its output. |
