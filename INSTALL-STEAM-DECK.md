# Install Lepton on a Steam Deck

This guide takes a finished bundle to an Android game running from Steam on a
Steam Deck with AMD hardware graphics. Make the bundles first with
**[BUILDING.md](BUILDING.md)**.

Nothing here downloads Android images, Google apps or games for you. You provide
your own APK files.

**Installing needs an internet connection.** Google's Android Debug Bridge
(`adb`), which Lepton uses to install games into Android, is not part of the
bundle. The installer downloads Google's official Android Platform-Tools
37.0.1 directly from `dl.google.com` on the Deck and keeps only `adb` and
Google's `NOTICE.txt` (see [Google ADB](#google-adb)).

## What you need

**Steam Deck**: SteamOS in Desktop Mode, signed in to Steam at least once, and
about 3 GiB free in your home directory per install. Any other x86_64 Linux
machine with an **AMD GPU** also works; other GPUs are not supported (the
image only contains AMD RADV/radeonsi drivers).

## 1. The bundle

A bundle is three files in the workspace's `bundles/` folder on the build computer, for
example for the bundle ID `base-20261104`:

| File | Purpose |
| --- | --- |
| `lepton-x86_64-steamdeck-base-20261104.tar.gz` | The bundle |
| `lepton-x86_64-steamdeck-base-20261104.tar.gz.sha256` | Checksums |
| `lepton-x86_64-steamdeck-base-20261104.install.sh` | One-command installer |

## 2. Copy it to the Deck

**Over the network (SSH).** On the Deck, once: open Konsole in Desktop Mode, set
a password with `passwd`, and run `sudo systemctl enable --now sshd`. Find the
Deck's IP address in Settings > Internet. Then on the build computer:

```bash
bash image-14/scripts/transfer-deck-bundle.sh --bundle-id base-20261104 --deck-ip 192.168.1.50
```

This copies all three files to `~/Downloads/lepton-deck-bundles/` on the Deck,
verifies the checksum there, and puts an **Install Lepton base-20261104** icon
on the Deck's desktop.

**Updating an existing install over SSH.** Add `--replace TOOL_ID` to install
straight away, overwriting that install (its games keep working; no game from
it may be running). The Deck needs internet access for this, because the
installer downloads Google's `adb`. Tool IDs are shown by `lepton-manage-installs --list` on
the Deck.

**By USB drive.** Copy the three files into one folder on the Deck.

## 3. Install (Steam Deck, Desktop Mode)

Double-tap **Install Lepton base-20261104** on the desktop. (After a USB copy,
double-tap the `.install.sh` file in Dolphin instead.) A Konsole window shows
progress. From a terminal, the same is:

```bash
bash ~/Downloads/lepton-deck-bundles/lepton-x86_64-steamdeck-base-20261104.install.sh
```

The installer:

1. verifies the checksum and that an AMD GPU is present;
2. downloads Google's `adb` and checks its SHA256 and version (see below);
3. moves everything to `~/.local/share/<install directory>` (it refuses to
   overwrite unless asked to replace);
4. registers the Steam compatibility tool **Lepton x86_64 (community) - base-20261104**;
5. writes `~/.config/lepton-x86_64/<tool id>.env` and makes it the default;
6. links `lepton-add-game`, `lepton-add-game-gui` and `lepton-run-apk` into `~/.local/bin`;
7. adds **Lepton: Add Android game**, **Lepton: Check graphics** and **Lepton:
   Remove installs** to the desktop and the application menu (Games); GApps
   bundles also add **Lepton: Add Google game** and **Lepton: Google sign-in**
   (see [GAPPS.md](GAPPS.md)).

When started from the desktop icon and other Lepton installs exist, the
installer first asks whether to **install as a new tool** or **replace** one of
them, and afterwards offers a tick-list of older installs to remove. If this
bundle is already installed, the first choice is **reinstall** it over the
existing copy instead (to undo local changes; its Steam shortcuts and game data
are kept). Steam does
not need to be closed for installing, replacing or removing (only for adding
games); restart Steam afterwards so it shows the new tool.

### Google ADB

The installer downloads
`https://dl.google.com/android/repository/platform-tools_r37.0.1-linux.zip`
over HTTPS, extracts only `platform-tools/adb` and `platform-tools/NOTICE.txt`,
and accepts `adb` only if its SHA256 is
`a902be8f45c6c62e76c9efaf6947a0fa747c9cabd89a2ac8e0d16ecb30b3ed01` and
`adb version` reports `37.0.1-15733141`. It is installed as
`tools/platform-tools/adb` in the install directory, with Google's notice in
`tools/licenses/google-platform-tools-NOTICE.txt` and the download details in
`tools/platform-tools/SOURCE.txt`. This all happens before the new copy is
moved into place: if the download or a check fails, the installer stops and
nothing (including an install you are replacing) is changed. Run it again
once the Deck is online. No `sudo` is needed.

**Without internet on the Deck**, download that same ZIP elsewhere, copy it to
the Deck and pass it in; it is checked in exactly the same way:

```bash
bash ~/Downloads/lepton-deck-bundles/lepton-x86_64-steamdeck-base-20261104.install.sh \
    --adb-zip ~/Downloads/platform-tools_r37.0.1-linux.zip
```

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

1. Double-tap **Lepton: Add Android game**, pick the `.apk` or split-APK
   bundle (`.apkm`) and confirm the name (this is checked while Steam is still
   running). On a base bundle an `.apkm` must include x86_64 code (no ARM64
   translation) and must not need Google services.
2. When asked, **exit Steam yourself**: Steam menu (top left) > Exit, or
   right-click the Steam taskbar icon > Exit. Wait until both have gone, then
   tap **Steam is closed**.
3. When it reports success, it is **safe to start Steam again**. The game appears
   under Non-Steam games with the Lepton tool selected.

Lepton never closes or starts Steam itself. If Steam is still running at step 2,
nothing is changed; close Steam and try again.

**Adding back a game whose shortcut you deleted.** Steam can take a while to
save a deleted shortcut; until it does, adding the same file again reports
"A shortcut for this APK/profile already exists". If that happens, restart
the Steam Deck (exiting Steam is not always enough) and add it again, or copy
the file to another folder first. A re-added game uses the current Lepton
tool automatically, and, if you keep the same name, continues with its saved
game data; choose a different name to start fresh.

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
Saved app profiles (for example a Google sign-in) are moved into the new copy,
so nothing is lost; the removal list shows profile counts.

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

ARM64-only games (with an NDK bundle) are prepared for the translator's faster
mode from their second launch, which removes most stutter; if one misbehaves,
`LEPTON_NDK_TRANSLATION_MODE=light-translate-or-interpret %command%` forces the
slower, most compatible mode (see `compat_tool/liblepton/ndk_auxv/README.md`).

## Game data between launches

A game's Android data (the installed app and everything it saves internally) is
kept between launches, so the APK is not reinstalled each time and progress
stays. It lives in Steam's compatdata folder for that shortcut, not in the
Lepton install, so it survives updating or replacing an install. It is reset
automatically (with a message in the Lepton log) when the game would start on a
different Android image, for example after switching the game to another Lepton
tool or installing a bundle with a new Android build; data a game keeps in
shared storage (`/sdcard`) is never reset. To reset one game by hand, launch it
once with the launch option `LEPTON_RESET_APP_DATA=true %command%`, then remove
the option. `LEPTON_KEEP_APP_DATA=false %command%` restores the old behaviour
(fresh install on every launch).

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
