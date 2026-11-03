# Lepton x86_64 — experimental community port

> **Unofficial developer preview.** This repository contains an experimental x86_64 Linux port of [Valve's Lepton](https://gitlab.steamos.cloud/frame-public/lepton), intended to explore running Android applications through Steam on Linux desktops and Steam Deck. **It is not affiliated with, supported by, or endorsed by Valve.**
>
> **Source code and build recipes only.** No Android system or vendor images, extracted Android root filesystems, Steam depot binaries, proprietary applications, or APKs are supplied.

## Status

**Experimental — October 2026.** The port has booted Android 14 on an x86_64 AMD/Fedora development system and on a Steam Deck, and has launched local Android applications through Steam. These results are development observations, not a general compatibility guarantee.

Verified on the development setup:

- Android 14 boots through Lepton's rootless Podman integration.
- An ANGLE → Vulkan → Mesa RADV graphics path provides interactive output on the tested AMD hardware.
- A local Android 2048 APK was launched through Steam with persistent saves.
- Steam Deck gamepad axes are recognised by Android after correcting inherited EventHub handling of native evdev axis ranges.
- Native Steam Deck touchscreen input works in the tested Android applications when the launcher and Steam Input are configured appropriately.

Known limitations:

- The clean Android 14 x86_64 source preparation, image build, and rootfs packaging workflows have succeeded on the development Fedora host. Boot validation of the **newly reproduced** rootfs is still in progress; earlier boot results do not establish that this new build boots.
- USB mouse interaction is incomplete; connecting/disconnecting a mouse may affect application touch handling.
- Multiple controllers connected at startup were verified on the Steam Deck; live hotplug remains experimental and must be explicitly enabled.
- Steam shortcuts, input configuration, Binder support, host graphics, and Android application compatibility vary by system.
- ARM translation is experimental: an NDK-enabled test stage passed ARM64 JNI on Fedora. The [version-specific compatibility shim](compat_tool/liblepton/ndk_auxv/README.md) now enables automatically for its matching translator. AAAAXY ARM64 and SuperTuxKart 1.4 in both x86_64 and forced ARM64 modes launched, rendered and were played on Fedora. Broader ARM game compatibility and this fix on Deck remain unverified. See [local debugging findings](FEDORA-DEBUGGING.md).
- Native Android depots, broad game compatibility, clean sysbake generation, and other GPUs/platforms remain unverified.

## Repository layout

| Path | Purpose |
| --- | --- |
| `compat_tool/` | Lepton runtime, local test scripts, and x86_64 adaptations |
| `compat_tool/tools/lepton-gamescope-bridge` | Experimental nested Gamescope launcher used on Steam Deck |
| `image-14/` | Android 14 image build configuration, vendor projects, and scripts |
| `image-14/patches/` | Reviewed source patches, including native evdev input-axis handling |
| `image-14/scripts/preflight-x86_64.sh` | Checks host and workflow prerequisites (`fresh`, `existing`, or `full`) |
| `image-14/scripts/prepare-x86_64.sh` | Prepares an isolated Android 14 source checkout |
| `image-14/scripts/build-images-x86_64.sh` | Builds Android system/vendor images with the configured builder |
| `image-14/scripts/package-repro-rootfs.sh` | Packages a separate test rootfs from locally built images |
| `image-14/scripts/deploy-compat-x86_64.sh` | Stages a runtime; packages or transfers complete stages with `--package-only` / `--transfer-only` |
| `image-14/scripts/make-deck-bundle-x86_64.sh` | One command from built images to an installable Steam Deck bundle |
| `compat_tool/tools/lepton-install-bundle` | Deck-side installer, shipped next to each bundle |
| `tests/runtime/` | Isolated local APK tests and JNI fixture builder |

Some build components are Git submodules. Confirm that the URLs in `.gitmodules` are publicly accessible before attempting a fresh clone or reporting a reproducible clean build.

## Building and deploying Android 14 x86_64

The experimental developer workflow uses Fedora Linux, rootless Podman, an Ubuntu-based builder container, and a separately configured Android source/output directory. This is not a turnkey Android image downloader or consumer installer.

Copy `.build-env.example` to `.build-env` and configure its local paths. The `.build-env` file is machine-specific and excluded from Git. Prepare the builder images described by the build scripts before invoking source preparation or image compilation.

The x86_64-specific Ubuntu 26.04 and Steam Deck tool builder definitions are
under `image-14/.buildscripts_x86_64/`. The original Valve-derived scripts remain
under `image-14/.buildscripts/`.

From the repository root:

```bash
# Check prerequisites and prepare a fresh, isolated AOSP checkout.
bash image-14/scripts/preflight-x86_64.sh fresh
bash image-14/scripts/prepare-x86_64.sh --execute

# Check the prepared checkout and builder environment.
bash image-14/scripts/preflight-x86_64.sh existing

# Compile the Android 14 system and vendor images.
bash image-14/scripts/build-images-x86_64.sh --check
bash image-14/scripts/build-images-x86_64.sh --execute

# Package the images as a standalone test rootfs.
source .build-env
bash image-14/scripts/package-repro-rootfs.sh "$LEPTON_OUTPUT_DIR"

# Stage the rootfs and native x86_64 APK extractor under compat_tool.
bash image-14/scripts/deploy-compat-x86_64.sh --check
bash image-14/scripts/deploy-compat-x86_64.sh --execute
```

The image build uses the Android target `aosp_lepton_x86_64-ap2a-userdebug` and produces `system.img` and `vendor.img`. The packaging step converts the Android sparse images, extracts their filesystems, flattens APEX packages, and writes to `$LEPTON_OUTPUT_DIR/repro-rootfs-auto/rootfs`. It refuses to overwrite an existing packaged rootfs.

The local deploy step copies the packaged rootfs into `compat_tool/images/rootfs` and builds the native x86_64 APK metadata extractor. It refuses to overwrite an existing destination and **does not install or replace Lepton in Steam**. Generated rootfs contents and the extractor executable are Git-ignored, but they can be included in a separate rsync transfer of the repository directory; ensure the rsync options do not exclude ignored/generated files. There is no need to transfer the full AOSP checkout to another test computer.

The native controller range correction is held in `image-14/patches/0007-eventhub-preserve-evdev-axes.patch` and is applied during the source preparation workflow to the AOSP `frameworks/native` checkout. It preserves synthetic Wayland input ranges while restoring the evdev axis information of real controllers.

ARM64 NDK translation is **opt-in**. To assemble a separate stage from a native
rootfs and an already extracted local payload, use:

```bash
bash image-14/scripts/deploy-compat-x86_64.sh --check \
  --stage-dir /path/to/new-ndk-stage --with-ndk --ndk-payload /path/to/payload
# Replace --check with --execute after reviewing preflight output.
```

This builds the compatibility shim and injects the verified payload into a new
rootfs copy. It does not download Google binaries. Provision utilities and create
a fresh sysbake afterward. See [Fedora debugging and validation](FEDORA-DEBUGGING.md)
for the complete workflow, local `apks/` directory, and test results.

### Making a Steam Deck bundle and installing it

Once the images are built, one command creates an installable bundle and a
one-command installer for the Deck:

```bash
bash image-14/scripts/make-deck-bundle-x86_64.sh --execute --bundle-id my-deck-01
```

Follow **[INSTALL-STEAM-DECK.md](INSTALL-STEAM-DECK.md)** for transfer, installation,
the graphics check, and adding games to Steam. Only AMD GPUs are supported: the
image contains AMD RADV/radeonsi drivers, and Lepton stops with an explicit message
on other hosts unless `LEPTON_FORCE_SOFTWARE=true` (slow software rendering) is set.

**Do not point packaging or deployment scripts at an existing Steam Deck runtime, and do not distribute generated Android binaries without a separate license and security review.**

## Runtime testing prerequisites

For fast local APK installation, ARM64 JNI checks, and captured game crash logs
on Fedora, see [Local Fedora APK debugging](FEDORA-DEBUGGING.md).

When testing Lepton on Fedora, SteamOS, or a second x86_64 Linux computer:

- Install the Steam client for the Linux user who will run Lepton.
- Launch Steam and complete account sign-in at least once using **that same Linux user**.
- Steam does **not necessarily need to remain running** for the shell-based runtime tests. Launching Android applications through Steam may require an active Steam session.
- Install rootless Podman and the other host dependencies required by the runtime.
- Ensure the required Wayland, audio, BinderFS, and graphics resources are accessible to the test user. On a Fedora Wayland desktop, `GAMESCOPE_WAYLAND_DISPLAY=wayland-0` may be necessary. Lepton maps this variable to its expected Wayland socket during setup.
- When running tests over SSH, use the account with the existing Steam setup and desktop runtime resources. An SSH login alone does not create a Wayland or audio session.

The experimental x86_64 tests are ordered from filesystem setup to Android initialization and graphics checks. Tests `0100` through `0600` read `compat_tool/images/rootfs`. Tests `0700` and `0800` are designed for a **separate** rootfs provided through `LEPTON_TEST_ROOTFS` and refuse to use the default rootfs path. Test failures at Podman container creation are not proof that Android itself failed to boot.

Start with the least invasive test from the repository root:

```bash
GAMESCOPE_WAYLAND_DISPLAY=wayland-0 bash compat_tool/test-0100.sh
```

Once host prerequisites and configuration are satisfied, continue in test-number order. `test-0200.sh` verifies container lifecycle without starting Android `/init`, while later tests exercise Android initialization and the graphics stack. Do not run `.ci_scripts/run-tests.sh` directly on a normal Fedora desktop: the CI harness includes system-wide changes and a forced Podman reset.

## Optional Google services

See [GApps build, installation and fixes](GAPPS.md) for the opt-in pipeline,
side-by-side Deck bundles, persistent sign-in and APKM Gaming Mode shortcuts.

## Steam Deck shortcut and display-mode helper

The Deck bundle includes `compat_tool/tools/lepton-add-game`, a standard-library
Python script to register a non-Steam APK shortcut, its Lepton compatibility
tool mapping, and its Gamescope launch options. The installer links it into
`~/.local/bin`, and it finds its own installation. After **fully exiting Steam**
from Desktop Mode:

```bash
~/.local/bin/lepton-add-game "$HOME/Android_Games/RetroArch.apk"
```

Restart Steam to see the new shortcut. Add `--hotplug` to opt in to the
experimental broad `/dev/input` mount and live gamepad hotplug. Without it,
the default only passes identified controllers present at startup. The helper
does not set Steam Input layouts: enable **Touchscreen Native Support** in the
shortcut's controller layout manually.

The helper refuses to modify Steam's binary shortcuts or text compatibility
mapping if it cannot recognise their format, if the APK is already registered,
or if Steam is running. When more than one Steam user directory exists, pass
`--userdata ~/.local/share/Steam/userdata/USER_ID`.

**Verified on Steam Deck, 29 October 2026:** A dry run validated Steam's
existing shortcuts and compatibility mapping without writing files; a new
2048 shortcut was then created, selected Lepton automatically, and launched
in both Desktop Mode and Gaming Mode. This is a functional test of the
current Deck configuration, not broad coverage of other Steam versions.

The `lepton-gamescope-bridge` keeps its known Gaming Mode SDL/X11 fullscreen
path. On KDE Plasma Wayland Desktop Mode it selects a **windowed Wayland
Gamescope** at 1280×800 (configurable with `LEPTON_RESOLUTION=WIDTHxHEIGHT`).
Override detection using `LEPTON_DISPLAY_MODE=gaming` or `desktop`.
The Desktop Wayland Gamescope window was verified on the Steam Deck, and
the new 2048 shortcut launched successfully in Desktop and Gaming modes.

## Steam Deck input notes (experimental)

The checked-in `compat_tool/tools/lepton-gamescope-bridge` reflects a tested nested Gamescope configuration with `--default-touch-mode 4`. **That switch alone is not enough** for native touch on the Steam Deck. The Lepton Steam shortcut's Steam Input configuration must also enable:

**Controller Settings → Edit Layout → Default Action Set → Always-On Command → System → Touchscreen Native Support**

With this combination, touch worked in the tested 2048 application and RetroArch's menu (with RetroArch's Mouse Support disabled). Results are specific to the development configuration. A USB mouse is not a substitute for native touch and may behave inconsistently.

**Verified on Steam Deck, 28 October 2026:** RetroArch recognises the built-in Steam Input virtual Xbox controller and its buttons, D-pad, and analogue axes with `Vendor_28de_Product_11ff.kl` and the patched Android InputReader. Controller passthrough defaults to **enabled** for all recognised Steam Input virtual controllers present when Lepton starts; set `LEPTON_GAMEPAD_PASSTHROUGH=false` to opt out.

**Experimental clean-install test, 29 October 2026:** On a freshly cleared Steam Deck, RetroArch launched in Gaming Mode through `lepton-gamescope-bridge`. The built-in Deck controller operated on Port 1, and two Bluetooth controllers were recognised independently on Ports 2 and 3. Both Bluetooth controllers connected and disconnected during the same session, and native touch remained usable after the display correction.

The original experimental hotplug test enabled two development switches. The user-facing switch is now **`LEPTON_GAMEPAD_HOTPLUG=true`**, which enables both the experimental input mount and automatic watcher; the unified switch has passed a Deck smoke test. Touch initially failed on controller connect because the watcher inherited nested Gamescope `DISPLAY=:2`, while the native-touch property was on host `DISPLAY=:0`. Setting `LEPTON_TOUCH_DISPLAY=:0` fixed the behaviour. The watcher's default was subsequently corrected to `:0`; the new default was exercised in the transferred host scripts during the single-switch smoke test.

**Security limitation:** `LEPTON_GAMEPAD_HOTPLUG=true` bind-mounts the host's *entire* `/dev/input` directory read-only into the Android container for experimental hotplug. Read-only access does **not** prevent reading events from unrelated host input devices. This feature is opt-in and is **not suitable as a general/default deployment** until exposure is narrowed.

**Default multi-controller startup test, 29 October 2026:** With hotplug disabled, two Bluetooth controllers and the built-in Deck controller worked simultaneously. The container mounted only `/dev/input/event10`, `/dev/input/event11`, and `/dev/input/event24` as individual input nodes; it did **not** mount the full host input directory. Later Bluetooth/keyboard hotplug is not supported in this mode.

**Build and bundle provenance:** The working controller test used an existing previously validated Android rootfs with an updated InputReader library compiled from the prepared Android source tree containing patches `0007-eventhub-preserve-evdev-axes.patch` and `0008-inputreader-separate-steam-input-pads.patch`. The test bundle was `lepton-x86_64-steamdeck-clean-install-controller-test-20261029.tar.gz`. This was a functional test of the assembled installation, **not** verification of a freshly rebuilt, complete Android rootfs. `deploy-compat-x86_64.sh --package-only` packages an existing stage and refreshes selected host-side scripts; it does not rebuild Android or substitute individual libraries. A full-from-source image/rootfs rebuild and whole-output verification are separate follow-up work.

RetroArch's controller assignment and per-core bindings may differ from other Android applications.

## Upstream, attribution and licenses

This is a community modification of [Valve's public Lepton project](https://gitlab.steamos.cloud/frame-public/lepton). Retain Valve's copyright notices, third-party attribution, and the license headers in files taken from upstream. Valve's public GitLab is the authoritative upstream project; this repository is an independent experimental port.

**The repository is not covered by one universal license.** Read:

- [`LICENSE.md`](LICENSE.md) — Valve's top-level license index.
- [`LICENSES/compat_tool.md`](LICENSES/compat_tool.md) — MIT terms for the top level and compatibility tool, retaining Valve's notice.
- [`LICENSES/image.md`](LICENSES/image.md) — Android-image license information; the combined image has a GPL-3.0 declaration and its component projects retain their own licenses.
- [`LICENSES/x86_64-contributions.md`](LICENSES/x86_64-contributions.md) — terms for original standalone material written for this port; this does **not** relicense Valve, Android, Waydroid, Mesa, or other third-party code.

Source patches against upstream components retain the copyright and license requirements applicable to the code they modify. Building or distributing Android binaries would require a separate corresponding-source, third-party notice and license-compliance review. No Android binaries are included here.

## Contributing

Issues and patches reproducing problems on x86_64 Linux are welcome. Please include host hardware and OS, a precise launch configuration, relevant command output, and whether the problem reproduces without local modifications. Do not upload proprietary game files, Android images, Steam depot binaries, credentials, or personal logs.

The primary goal of this repository is reproducible technical investigation, not a claim of supported consumer compatibility.
