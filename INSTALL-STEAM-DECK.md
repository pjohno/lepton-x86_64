# Install Lepton on a Steam Deck

This guide gets Android games running from Steam on a Steam Deck with AMD
hardware graphics. There are two ways to install:

- **[From GitHub Releases](#install-from-github-releases)**: for most people. No
  SSH, Git or developer tools are needed.
- **[Your own bundle](#developer-install-your-own-bundle)**: for developers who
  build bundles with **[BUILDING.md](BUILDING.md)** and copy them to the Deck
  over SSH or USB.

Nothing here downloads Android images, Google apps or games for you. You provide
your own APK files.

**Installing needs an internet connection.** Google's Android Debug Bridge
(`adb`), which Lepton uses to install games into Android, is not part of the
bundle. The installer downloads Google's official Android Platform-Tools
37.0.1 directly from `dl.google.com` on the Deck and keeps only `adb` and
Google's `NOTICE.txt` (see [Google ADB](#google-adb)).

## What you need

**Steam Deck**: SteamOS in Desktop Mode, signed in to Steam at least once, and
about 3 GiB free in your home directory per install.

**Lepton supports the Steam Deck only.** Desktop PCs with an AMD GPU can
install it, but that is experimental: games start and draw, but mouse and
keyboard do not reach them yet
([issue #9](https://github.com/pjohno/lepton-x86_64/issues/9)). Other GPUs are
not supported (the image only contains AMD RADV/radeonsi drivers).

## Install from GitHub Releases

Releases are published at <https://github.com/pjohno/lepton-x86_64/releases>.
Each release of version `VERSION` (for example `v0.1.0-alpha`) has these files:

| File | Purpose |
| --- | --- |
| `lepton-x86_64-steamdeck-VERSION.tar.gz` | The bundle |
| `lepton-x86_64-steamdeck-VERSION.tar.gz.sha256` | Checksums of the bundle and the installer |
| `lepton-x86_64-steamdeck-VERSION.install.sh` | The installer |
| `lepton-x86_64-steamdeck-VERSION.tar.gz.sha256.sig` | Signature (signed releases only) |

### First installation

1. **Download the files.** In Desktop Mode, open the release page in a web
   browser and download the `.tar.gz`, `.tar.gz.sha256` and `.install.sh` files
   of the **same version** into one folder. The browser's `Downloads` folder is
   fine. Keep the file names exactly as they are: the installer finds the bundle
   by name next to itself. If your browser added ` (1)` to a name, delete the
   copies and download again.
2. **Run the installer.** Browsers don't keep the "executable" permission on
   downloaded files, so a plain double-click on the `.install.sh` file opens it
   in a text editor instead of running it. Use one of these methods:
   - **Terminal (dependable):** in Dolphin, open the folder with the three files,
     right-click an empty area, choose **Open Terminal Here**, and run (Tab
     completes the file name):

     ```bash
     bash lepton-x86_64-steamdeck-VERSION.install.sh
     ```
   - **Double-click:** in Dolphin, right-click the `.install.sh` file and choose
     **Properties > Permissions**. Tick **Is executable** (called **Allow
     executing file as program** on some versions), then **OK**. Double-click the
     file. When Dolphin asks whether to **Launch this program as an executable**,
     choose **Launch** (or **Yes**). A Konsole window opens and shows the
     progress.

The installer:
- needs an internet connection, but no password and no `sudo`;
- checks the bundle against the `.sha256` file before unpacking anything;
- checks that the Deck can run Lepton games;
- downloads Google's `adb` and checks it (see [Google ADB](#google-adb));
- installs into `~/.local/share` and registers the Steam compatibility tool.

If anything fails, nothing is installed and existing installs are unchanged.
Restart Steam afterwards. Then continue with
[Check graphics](#4-check-graphics) and [Add a game](#5-add-a-game).

The installer also adds these entries to the application menu and the desktop:

| Entry | Use |
| --- | --- |
| **Lepton: Install / Update / Repair** | Later versions, updates and repair (below) |
| **Lepton: Add Android game** | Add an APK or APKM to Steam |
| **Lepton: Check graphics** | Check the AMD hardware graphics |
| **Lepton: Remove installs** | Remove old installs |

### Later versions, updates and repair

Open **Lepton: Install / Update / Repair**. It lists the releases published on
GitHub and offers:

- **Update** an installed version when a newer release exists. During the alpha
  period, alpha releases count as updates.
- **Install the latest alpha** (preselected during the alpha period), or **the
  latest stable release**. If none of that kind has been published yet, it says
  so.
- **Choose from all published versions.** Each version shows its date, whether
  it's an alpha, its size, and whether it is signed.
- **Repair an existing installation:** reinstall the same version over it.
- **Remove installs:** opens **Lepton: Remove installs**.

When you install a version, you choose to install it **alongside** the existing
ones (a new Steam tool) or to **replace** one of them. Replacing keeps that
tool's Steam ID, so games set to it keep using it. The manager warns before a
**downgrade**. Nothing is installed or replaced until you confirm.

How downloads work:
- Files go to `~/Downloads/lepton-deck-bundles/`. They're downloaded under
  temporary names and only take their real names once their checksums are
  verified.
- Files that are already there and verify are reused. Damaged or incomplete
  files are downloaded again.
- The release's own installer then does the installing, exactly as for a first
  installation.
- GApps, NDK and Widevine add-ons are never downloaded.

After an install, you can remove older installs. You tick which ones in **Lepton:
Remove installs**, which shows how many Steam shortcuts use each. Nothing is
removed without your confirmation, and game data in Steam's `compatdata` folder
is never deleted.

**Repair** reinstalls the version an install came from, with the same Steam tool
ID, shortcuts and game data. It can't repair:
- damaged Android app data inside a game;
- installs of bundles that were never published (your own builds);
- GApps or NDK installs, because releases only contain the base bundle.

In those cases it explains why and changes nothing.

**Lepton: Install / Update / Repair** lives in
`~/.local/share/lepton-release-manager/`, outside the versioned installs, so it
keeps working after every install is removed. Installing a newer release also
updates it; an older release never replaces a newer copy of it.

**Authenticity:**
- **Signed releases:** when the release manager has a Lepton release key (it
  comes with the manager), it checks the release's signature and refuses
  unsigned or wrongly signed releases.
- **Unsigned releases:** the checksums only show that the files were not
  damaged. The manager says so and asks before running the downloaded
  installer.
- **First installation:** you trust the files because you downloaded them over
  HTTPS from the project's GitHub page.

See [RELEASING.md](RELEASING.md#trust-model).

### Game data when you change versions

Launcher-only updates can reuse the same validated Android image and sysbake.
Changing the Lepton release version or tool name does not reset game data.
Existing profiles remain under the same Steam AppID's compatdata directory.

Independently built Android images or sysbakes can have incompatible system
and credential state, even when built from the same source. If the recorded
runtime fingerprint differs or is unknown, the fixed launcher preserves the
profile and stops with a diagnostic. Select its original runtime to reuse it;
do not force a different image to boot against it. Invalid installations and
changed APK contents also preserve data and stop for diagnosis.

Older Lepton tools may still reset profiles automatically. Use a fixed tool
when testing reuse, and see [Game data between launches](#game-data-between-launches)
for explicit reset scope and compatibility checks.

Separately, Steam's **Stop** button gives the game a few seconds to save before
Android shuts down (see [Game data between launches](#game-data-between-launches)). A game that only
saves at certain points, such as checkpoints, can still lose progress since its
last save; to be safe, close the game from inside the game.

## Developer install: your own bundle

### 1. The bundle

A bundle is three files in the workspace's `bundles/` folder on the build computer, for
example for the bundle ID `base-20261104`:

| File | Purpose |
| --- | --- |
| `lepton-x86_64-steamdeck-base-20261104.tar.gz` | The bundle |
| `lepton-x86_64-steamdeck-base-20261104.tar.gz.sha256` | Checksums |
| `lepton-x86_64-steamdeck-base-20261104.install.sh` | One-command installer |

### 2. Copy it to the Deck

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

### 3. Install (Steam Deck, Desktop Mode)

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

#### Google ADB

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

### 4. Check graphics

Double-tap **Lepton: Check graphics**, or run
`~/.local/bin/lepton-run-apk --gpu-check --execute`. This boots Android once
without any app (about a minute) and must end with
`[PASS] Hardware acceleration: ANGLE on Vulkan/RADV`. On a Steam Deck the
graphics line names `RADV VANGOGH`.

### 5. Add a game

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

### Desktop Mode and Gaming Mode

Both modes run the game inside a nested Gamescope.

- **Gaming Mode:** the game fills the screen, as before.
- **Desktop Mode:** the game opens in a normal window with Plasma's title bar,
  so you can move, minimise and close it, and the desktop and panel stay
  reachable. The Steam button doesn't work as an escape in Desktop Mode, so a
  fullscreen game could leave the Deck looking stuck. The window is 80% of the
  desktop at 16:10: 1024×640 on a Steam Deck.

Launch options for Desktop Mode:

| Option | Effect |
| --- | --- |
| `LEPTON_DESKTOP_FULLSCREEN=1` | Fill the main screen instead. Close the game with Alt+F4 or from Steam. |
| `LEPTON_RESOLUTION=WIDTHxHEIGHT` | Android's screen size: the window's size, or the size scaled to fill the screen with `LEPTON_DESKTOP_FULLSCREEN=1`. In Gaming Mode it sets Android's size and the game still fills the screen. |
| `LEPTON_DISPLAY_MODE=desktop` or `gaming` | Override detection (see below). |

Lepton treats a session as Gaming Mode only when Steam's Gamescope session is
detected. If it can't tell which mode it's in and a Wayland desktop is
available, it opens a window and logs a warning. `LEPTON_DESKTOP_WINDOWED=1`
is accepted but no longer needed.

ARM64-only games (with an NDK bundle) are prepared for the translator's faster
mode from their second launch, which removes most stutter; if one misbehaves,
`LEPTON_NDK_TRANSLATION_MODE=light-translate-or-interpret %command%` forces the
slower, most compatible mode (see `compat_tool/liblepton/ndk_auxv/README.md`).

## Game data between launches

A game's Android data (the installed app and everything it saves internally) is
kept between launches, so the APK is not reinstalled each time and progress
stays. It lives in Steam's compatdata folder for that shortcut, not in the
Lepton install, so it survives updating or replacing an install when Android
and sysbake are identical. Launcher version changes and APK timestamps do not
invalidate it. Short exits, crashes and failed installations never reset it.

A missing or different runtime fingerprint stops launch and preserves the
profile. Use the original Android image and sysbake. An incomplete installation
or changed APK also stops launch with a diagnostic; automatic in-place repair
is pending validation of Lepton's APK overlay. Back up the profile before
investigating metadata or installing an update. Do not reset to resolve an error
unless you intend to discard the Android profile.

To explicitly discard **only the selected game's `baked/` Android profile**,
stop the game, back it up, then launch once with
`LEPTON_RESET_APP_DATA=true %command%` and remove that option immediately.
This removes installed code, Android-private saves and Android system state in
`baked/`. It retains `external/` shared storage and legacy `internal/` files;
legacy data retained outside `baked/` is not a promise of automatic recovery.
Reset refuses active profiles and reports deletion failures.
`LEPTON_KEEP_APP_DATA=false` is now ignored with a warning: inherited launch
options cannot authorise deletion. `cleanup_all` stops/removes containers and
retains profiles. The separate Deck clean-slate utility remains an explicitly
confirmed destructive administrative action; do not use it for persistence tests.

When you press Stop in Steam, Lepton first sends the game to the background
(as if you pressed Home) and waits 3 seconds so it can save, then lets Android
shut down for up to 5 seconds before stopping it. Stop therefore takes a few
seconds. This gives games a chance to save; it cannot make a game write
progress. **Save through the game before using Steam Stop.** In 2048, use the
game's own Exit function to save the latest board. Going back through previous
moves also triggers a save. Deck testing found that Steam Stop retained the
previous saved board but did not save the latest moves by itself.
The waits can be changed with
`LEPTON_STOP_SAVE_WAIT=<seconds>` and `LEPTON_STOP_SHUTDOWN_WAIT=<seconds>`;
setting both to `0` gives the old instant stop.

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
| Desktop Mode: game too large, or fullscreen when it shouldn't be | Remove `LEPTON_DESKTOP_FULLSCREEN` / `LEPTON_RESOLUTION` from the launch options. Alt+F4 closes a fullscreen game. |
| Lepton missing in Steam's compatibility list | Restart Steam after installing. |
| Logs | `~/.steam/steam/logs/lepton-*.log`; GPU-check logs are listed at the end of its output. |
