# Local desktop launch routing

Installations made with `image-14/scripts/install-local.sh` use direct host
Wayland for Steam game launches. No Steam Launch Options are required:

```text
%command%
```

The local wrapper passes `--install-profile local-desktop` to the bundled
installer. The installer writes the single line `local-desktop` to
`compat_tool/install-profile` in the installed copy, before making it active.
The Steam entry point reads this as data, not shell code. It never infers a
local installation from KDE or Wayland session variables or from a global
`LEPTON_INSTALL_PROFILE` environment variable.

The profile survives Steam restarts and reboots. `--replace` and `--into`
preserve an existing local profile; the local installer explicitly recreates
it. Packaging and installation discard profiles embedded in transferable
archives. Older bundles lacking the new launcher support are refused for a
local install: repackage an existing stage with current launch scripts, without
rebuilding Android. Ordinary unmarked Deck installs and existing shortcuts
keep their Gamescope path. On SteamOS, even a copied local profile is ignored
so normal Deck launch routing still applies. Compatibility IDs and prefixes
are unchanged.

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
