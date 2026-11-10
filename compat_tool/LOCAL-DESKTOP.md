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

## Fullscreen and scaling

This phase leaves direct Wayland geometry unchanged. The client requests
maximization in its Wayland hwcomposer, but provides no launcher-controlled
`xdg_toplevel.set_fullscreen` request. Wayland does not provide a portable way
for an unrelated launcher to set another client's fullscreen state. Compositor
rules are host-specific and could affect unrelated Android windows, so none
are installed. There is no forced resize or change to framebuffer dimensions,
fractional scaling or pointer coordinates.

The smallest client-side follow-up is an opt-in fullscreen request in the
Wayland client, with configure/state handling. Physical monitor resolution and
scale negotiation need separate validation before promising physical-resolution
fullscreen. Those changes require hwcomposer work and are outside this phase.
Fedora testing must check rendering/redraw, pointer alignment, focus, exit and
relaunch; earlier direct tests do not establish that every scaling setup works.

## Launcher-only Fedora deployment

For the existing test installation, verify the 2048 shortcut's selected tool
against `~/.local/share/Steam/config/config.vdf` and its matching registration
in `~/.local/share/Steam/compatibilitytools.d/`. The selected test tool is
currently `lepton_x86_64_v0_1_1_alpha`, not the separately registered tool named
“development”. Stop the game normally before the next test launch.

Back up each existing file, recording absent files as well, then replace only:

- `compat_tool/lepton-x86_64-entry`
- `compat_tool/tools/lepton-gamescope-bridge`
- `compat_tool/tools/lepton-direct-wayland` (new)
- `compat_tool/tools/lepton-display-common.sh` (new)
- `compat_tool/install-profile` (write `local-desktop` last)

Preserve executable permissions on replacements; install the new direct helper
as mode 755 and the common helper/profile as mode 644. Replace by rename in the
same directory, and write the profile last so partial deployment cannot enable
an incomplete direct path. Do not replace the rootfs, APK, sysbake or prefixes.
Do not change Steam configuration or shortcuts. Use `%command%`, then compare
the explicit fallback above. Save the backup directory printed by deployment;
its `rollback.py` restores original files/modes and removes newly added files:

```bash
python3 '/exact/backup/directory/rollback.py'
```

Steam's `logs/console-linux.txt` should show `Lepton display: desktop Wayland
(...), no Gamescope; geometry unchanged`. The normal per-AppID runtime log
confirms which tool/profile launched and the Android window dimensions. It
starts after display routing, so bridge/direct selection messages are in
Steam's console log. Confirm absence of a new nested Gamescope rather than
relying only on the Android window appearing. Rollback and relaunch should
restore the previous nested Desktop Mode path.
