# Local desktop launch routing

Both the transferred `.install.sh` installer and
`image-14/scripts/install-local.sh` automatically select a host profile:

| Host OS | Installation profile | Launcher |
| --- | --- | --- |
| SteamOS (`ID=steamos`) | `steamos` (no marker file) | Existing Gamescope bridge |
| Other Linux, including Fedora GNOME/KDE | `local-desktop` | Direct Wayland, native fullscreen |

Detection reads `/etc/os-release` as data, falling back to `/usr/lib/os-release`
when the first file is unavailable. It never executes the file and does not
use the hostname, user, desktop environment, session mode or installed
Gamescope to select the profile. Unknown Linux systems default to
`local-desktop`. `lepton-install-bundle --detect-profile` prints the selection
without installing or checking dependencies. The standalone installer contains
this policy itself and needs no source checkout.

An explicit `--install-profile local-desktop` or `--install-profile steamos`
overrides detection in either installer. For debugging the Gamescope route on
Fedora, use `--install-profile steamos`; Gamescope must then be installed.
SteamOS retains its existing runtime safeguard: even an explicitly installed
local marker does not switch a Steam Deck away from its normal bridge.

For `local-desktop`, the installer writes the single line `local-desktop` to
`compat_tool/install-profile` before activating the installation. For `steamos`,
it removes that file. The Steam entry point reads the marker as data. The
profile survives Steam restarts and reboots; a global `LEPTON_INSTALL_PROFILE`
environment variable cannot select it.

On `--replace` and `--into TOOL_ID`, the detected host or explicit override
selects the new profile, even when the previous installation used a different
profile. The installer reports the OS, profile and launcher. Profiles embedded
in transferable archives are discarded. Old bundles without local launcher
support or profile-aware host checks must be repackaged with current host
scripts; no Android rebuild or sysbake regeneration is needed. Compatibility
IDs, game data, rootfs and container ownership are unchanged.

Host checks keep Podman, BinderFS, graphics, native Steam, Python, attr and
dialog requirements. Only the `steamos` profile requires Gamescope. Both GNOME
and KDE Plasma Wayland use the same direct route. An X11 session is rejected
for `local-desktop`. Headless/SSH installs without a usable Wayland socket get
a warning: games still require Steam to run in a Wayland desktop session,
and the existing direct launcher validates the socket at launch.

### Install and check on Fedora GNOME or KDE

Run these same commands in a terminal in either desktop's Wayland session,
as your normal user. Replace `VERSION` with your bundle ID:

```bash
# Transferred bundle: no source checkout needed.
bash lepton-x86_64-VERSION.install.sh --check
bash lepton-x86_64-VERSION.install.sh
# Upgrade an existing installation, recalculating its profile for this host.
bash lepton-x86_64-VERSION.install.sh --replace
# Force the Gamescope route for comparison (requires Gamescope).
bash lepton-x86_64-VERSION.install.sh --replace --install-profile steamos
# Restore direct Wayland.
bash lepton-x86_64-VERSION.install.sh --replace --install-profile local-desktop
```

From the source checkout, with a bundle or prepared stage already available:

```bash
bash compat_tool/tools/lepton-host-check
bash image-14/scripts/install-local.sh --check --bundle-id VERSION
bash image-14/scripts/install-local.sh --execute --bundle-id VERSION
# To overwrite a different tool while keeping its Steam shortcuts:
bash image-14/scripts/install-local.sh --execute --bundle-id VERSION --into TOOL_ID
```

Restart Steam after installation, select the installed compatibility tool, and
use `%command%` as the game's Launch Options. Confirm native fullscreen,
compositor resolution/scale, input, exit and relaunch in each desktop.
Steam Deck Gaming Mode remains fullscreen and Desktop Mode remains windowed.

Host-only regression tests (no root or downloads):

```bash
python3 tests/test-install-profiles.py -v
bash tests/test-host-check.sh
bash tests/test-tool-entry.sh
bash tests/test-gamescope-bridge.sh
bash tests/test-direct-wayland.sh
```

Tests simulate OS files through `LEPTON_HOST_OS_RELEASE` and
`LEPTON_HOST_OS_RELEASE_FALLBACK`; leave these unset for normal installation.

The local entry point runs `tools/lepton-direct-wayland`, without invoking
`lepton-gamescope-bridge`. It keeps the compatibility-tool environment and
passes the host socket through `GAMESCOPE_WAYLAND_DISPLAY` to the existing
Podman mount at `/waydroid/xdg/wayland-0`. `WAYLAND_DISPLAY` must be a socket
name under `XDG_RUNTIME_DIR`; missing variables, missing sockets and regular
files produce an error and a player dialog. Start Steam from a Wayland session.
Absolute socket paths are not supported by this launcher. Binder preflight,
startup-refusal messages, exit status and child shutdown are retained. These
checks do not guarantee compositor responsiveness; socket connection failures
remain visible in the normal runtime logs.

For a per-game fallback, use Steam Properties → Launch Options:

```ini
LEPTON_LOCAL_USE_GAMESCOPE=1 %command%
```

The fallback selects the existing Wayland Gamescope Desktop Mode path, windowed
by default with touch mode 1. Explicit desktop sizing/fullscreen overrides
remain available. Gaming Mode's SDL/X11 fullscreen path and touch mode 4 are
unchanged for normal Deck installs. Unmarked tools still support the existing
experimental `LEPTON_DESKTOP_DIRECT=1` opt-in; it uses the same direct helper.
The explicit local Gamescope fallback takes precedence over that older option.

## Native fullscreen and scaling (Phase 2)

The local profile now requests native fullscreen by default. The entry point
resets `LEPTON_LOCAL_DISPLAY_ACTIVE` for every launch and enables it only for
the installed local profile outside SteamOS. Unmarked tools, a local profile
copied to SteamOS, and the Gamescope fallback leave it disabled.

For a local game's Steam Launch Options:

```ini
%command%
```

To request the original maximized/windowed direct path instead:

```ini
LEPTON_LOCAL_FULLSCREEN=0 %command%
```

To use the existing windowed Gamescope fallback:

```ini
LEPTON_LOCAL_USE_GAMESCOPE=1 %command%
```

The fullscreen option accepts only `0` or `1`. The direct launcher obtains a
primary enabled output name from `kscreen-doctor -j` when available; it passes
only that placement hint, not forced dimensions. The existing property-file
generator writes `ro.lepton.local_display`, `ro.lepton.local_fullscreen` and
`ro.lepton.local_output` into the per-launch `lepton.prop`. Podman mounts this
file at `/vendor/waydroid.prop`, which Android imports. SurfaceFlinger reads
those properties through the modified hwcomposer. Host environment variables
are not implicitly inherited by Android.

The hwcomposer change is the reviewed patch
`image-14/patches/0009-hwc-local-wayland-fullscreen.patch`. Preparation applies
it to `hardware/waydroid`; the pinned submodule stays unchanged. Image
provenance compares that copied project against the expected patched source.
The fractional-scale XML is included with its upstream MIT notice and code is
generated with Android's existing Wayland scanner.

The client requests `xdg_toplevel.set_fullscreen` on the matching `wl_output`,
then respects the compositor's acknowledged fullscreen state and logical
configure size. The current output mode supplies exact physical buffer
extents in fullscreen, including rotated modes. For example DP-1 at 3440×1440
and 125% uses a 2752×1152 logical surface with a 3440×1440 Android display.
Fractional-scale preferred-scale events and `wp_viewporter` map physical layer
buffers to logical surface destinations. This avoids treating the integer
`wl_output.scale` value of 2 as the actual 125% scale. When the fractional
protocol is unavailable, fullscreen still uses the entered output's exact
physical mode; windowed rendering falls back to the output's integer scale.

Each axis uses the physical/logical ratio for absolute pointer, touch and
stylus coordinates, retaining Wayland fixed-point precision until conversion.
This also handles independently rounded logical dimensions at 150%. The HWC
attributes presented to SurfaceFlinger use exact physical buffer extents.
There is no host-side `wm size` change, forced window resize, or double-scaling.

Configure state is applied after `xdg_surface.ack_configure`. Focus-only
configures with unchanged dimensions do not trigger display hotplug. Resizing,
scale changes and entered-output changes invalidate the display as needed;
removed outputs are discarded and the compositor's next surface-enter/configure
chooses the replacement. A zero-size configure uses the prior size or a bounded
startup hint rather than waiting forever. The compositor can decline fullscreen.

Single-primary-monitor startup is the primary target. Multi-monitor placement
without KDE output names is compositor-selected. Runtime output switching,
rotation changes and unplug are handled in code but need hardware validation.
The code changes do not replace the existing vsync/presentation feedback
scheduler or add a continuous redraw loop. Issue #8 was not reproduced during
the fresh Phase 1 Fedora test; this does not prove it fixed for all games.

Protocol references: [xdg-shell](https://wayland.app/protocols/xdg-shell),
[fractional scale](https://wayland.app/protocols/fractional-scale-v1),
[viewporter](https://wayland.app/protocols/viewporter).

## Component-only build

Use the existing prepared Android checkout; do not reset it or clean its outputs.
After preparation has applied the patch, the component-only command is:

```bash
source .build-env
AOSP="$LEPTON_OUTPUT_DIR/aosp"
podman run --rm --network=none --userns=keep-id --group-add keep-groups \
  --security-opt=label=disable \
  -e BUILD_USERNAME=lepton -e BUILD_HOSTNAME=lepton-build \
  -v "$AOSP:/workspace/output:rw" -w /workspace/output \
  lepton-builder-ubuntu26:latest /bin/bash -c \
  'source build/envsetup.sh >/dev/null && lunch aosp_lepton_x86_64-ap2a-userdebug && m -j6 hwcomposer.waydroid'
```

For an already prepared Phase 1 checkout, first apply the isolated patch with
`git -C "$AOSP/hardware/waydroid" apply --check "$PWD/image-14/patches/0009-hwc-local-wayland-fullscreen.patch"`,
then the same command without `--check`. If the reverse check already passes,
it is already applied. Do not apply over conflicting source changes.
The artifact is
`out/target/product/lepton_x86_64/vendor/lib64/hw/hwcomposer.waydroid.so`.
No system/vendor image rebuild is required for this development test.

## Launcher-only Fedora deployment

For the existing test installation, verify the 2048 shortcut's selected tool
against `~/.local/share/Steam/config/config.vdf` and its matching registration
in `~/.local/share/Steam/compatibilitytools.d/`. The selected test tool is
currently `lepton_x86_64_v0_1_1_alpha`, not the separately registered tool named
“development”. Stop the game normally before the next test launch.

Back up each existing file, recording absent files as well, then replace only:

- `compat_tool/lepton-x86_64-entry`
- `compat_tool/tools/lepton-direct-wayland`
- `compat_tool/liblepton/properties.sh`
- `compat_tool/images/rootfs_overlay/vendor/lib64/hw/hwcomposer.waydroid.so`

Keep the existing `local-desktop` profile and Phase 1 shared helpers. The new
library is a read-only Podman bind overlay; the original rootfs library is not
replaced. The runtime fingerprint and saved compatibility profile are unchanged.

Preserve executable permissions on script replacements and install the library
overlay as mode 755. Replace by rename in the
same directory, and deploy the entry point last so partial deployment cannot enable
an incomplete local policy. Do not replace the rootfs, APK, sysbake or prefixes.
Do not change Steam configuration or shortcuts. Use `%command%`, then compare
the explicit fallback above. Save the backup directory printed by deployment;
its `rollback.py` restores original files/modes and removes newly added files:

```bash
python3 '/exact/backup/directory/rollback.py'
```

Steam's `logs/console-linux.txt` should show `Lepton display: desktop Wayland
(...), no Gamescope`. The normal per-AppID runtime log
confirms which tool/profile launched and the Android window dimensions. It
starts after display routing, so bridge/direct selection messages are in
Steam's console log. Confirm absence of a new nested Gamescope rather than
relying only on the Android window appearing. Rollback and relaunch should
restore the Phase 1 direct path. The separate Phase 1 backup restores the
older nested Desktop Mode path if needed.

## Fedora validation record

On 2026-11-11, the user rechecked Phase 1 in the installed 2048 Steam shortcut:
mouse/keyboard, pointer alignment, continuous redraw, and normal exit/relaunch
worked; issue #8 was not reproduced. KDE reported primary output DP-1 at
3440×1440, scale 1.25, logical screen 2752×1152.

The isolated Ubuntu 26 build compiled only `hwcomposer.waydroid` and generated
protocol dependencies (no clean build or system/vendor image rebuild). The
component's shared-library dependency set matches the installed original.
The full workflow regression suite passed, including profile isolation on
SteamOS, both existing Gamescope paths, property-file handoff, fractional
coordinate math, patch application and image provenance.

For runtime verification after relaunch, inspect Steam's `logs/console-linux.txt`
for the direct route and local fullscreen request. In the Android container:

```bash
podman exec lepton-steamlaunch-2826395812 /system/bin/getprop ro.lepton.local_display
podman exec lepton-steamlaunch-2826395812 /system/bin/getprop ro.lepton.local_fullscreen
podman exec lepton-steamlaunch-2826395812 /system/bin/getprop ro.lepton.local_output
podman exec lepton-steamlaunch-2826395812 /system/bin/wm size
podman exec lepton-steamlaunch-2826395812 /system/bin/logcat -b all -d -s hwcomposer:I
```

The hwcomposer log must confirm the acknowledged fullscreen state and both
logical and buffer extents. A launch request or passing unit tests alone does
not verify fullscreen, physical dimensions, input alignment or continuous
rendering. Native physical touch, additional scales/rotations and live monitor
unplug remain hardware tests.

Phase 2 Fedora test at 125%: the 2026-11-11 09:21:43 Steam launch selected
native fullscreen on DP-1 without Gamescope. Android's 2048 log recorded
`GLSurfaceView.onSurfaceChanged(3440, 1440)` at 09:21:47. The user confirmed
that the window covered the Plasma panels and that input/redraw worked. The
session subsequently logged a normal exit and retained the existing profile.
A second launch at 09:24:56 retained the authoritative hwcomposer record:
`fullscreen=1 logical=2752x1152 buffer=3440x1440 scale=1.2500`.
Live Android properties confirmed `ro.lepton.local_display=true`, fullscreen
`1`, output `DP-1`, and `waydroid.display_scale=1.250000`. `wm size` reported
`Physical size: 3440x1440`; DisplayManager/SurfaceFlinger agreed on 3440×1440
physical/logical Android frames and the current monitor mode at 120 Hz.
No nested Gamescope startup appeared for the direct launch.
No other scale, rotated output, live unplug or physical touch test is implied.
