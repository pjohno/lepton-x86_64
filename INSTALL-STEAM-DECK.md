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

Use `--check` to verify without installing. To update the same tool later, run
the new bundle's installer with `--replace`; the old copy is kept as
`<directory>.previous-<date>`.

## 4. Check graphics

Double-tap **Lepton: Check graphics**, or run
`~/.local/bin/lepton-run-apk --gpu-check --execute`. This boots Android once
without any app (about a minute) and must end with
`[PASS] Hardware acceleration: ANGLE on Vulkan/RADV`. On a Steam Deck the
graphics line names `RADV VANGOGH`.

## 5. Add a game

Double-tap **Lepton: Add Android game**, pick the APK, confirm the name. Steam
closes, the shortcut is added, and Steam starts again by itself, so no typing is
needed after Steam exits (the on-screen keyboard is part of Steam). The game
appears under Non-Steam games with the Lepton tool selected.

From a terminal: `~/.local/bin/lepton-add-game --restart-steam ~/Downloads/my-game.apk`
(add `--dry-run` to check first, `--name "Title"` to change the Steam name).

**Touch input**: in the game's controller layout enable
Controller Settings > Edit Layout > Default Action Set > Always-On Command >
System > **Touchscreen Native Support**. Without it, the Deck's touchscreen
does not reach Android.

Controllers present at launch are passed to Android. Live controller hotplug is
experimental (`--hotplug`) and exposes all host input devices to the container.

## Several installs side by side

Each bundle ID installs as its own Steam tool (`lepton_x86_64_<bundle-id>`, or
`lepton_gapps_<bundle-id>` with Google apps), so an older install such as
`~/.local/share/lepton-x86_64-dev` is left alone. `lepton-add-game` uses the most
recently installed one; pick another with `--tool-id <tool id>` (tool IDs are
listed in `~/.config/lepton-x86_64/`).

## Removing an install

With Steam exited (replace `DIR` and `TOOL` with the names the installer printed):

```bash
chmod -R u+rwX ~/.local/share/DIR && rm -rf ~/.local/share/DIR
rm ~/.local/share/Steam/compatibilitytools.d/TOOL.vdf ~/.config/lepton-x86_64/TOOL.env
```

Shortcuts for that tool remain in Steam until you delete them there.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Installer: `No AMD GPU found` | Only AMD GPUs are supported. |
| GPU check reports SwiftShader | `LEPTON_FORCE_SOFTWARE` is set, or `/dev/dri` is not accessible to your user. |
| Game shows no touch input | Touchscreen Native Support (step 5). |
| Lepton missing in Steam's compatibility list | Restart Steam after installing. |
| Logs | `~/.steam/steam/logs/lepton-*.log`; GPU-check logs are listed at the end of its output. |
