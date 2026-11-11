# Environment variables

* `LEPTON_NDK_COMPAT=auto` (default) automatically enables the CPU/timer shim for the reviewed Google API 34 r14 NDK bridge. Other rootfs versions are left unchanged. Use `false` for comparisons; `true` requires a supported bridge. New NDK deployments and bundles include the compiled shim. See [NDK compatibility](liblepton/ndk_auxv/README.md).

* `LEPTON_DESKTOP_TOUCH_MODE` selects nested Desktop Mode's Gamescope touch mode: `0` hover (pointer-only compatibility), `1` touch as left mouse click (default: mouse and single-touch emulation, no native multitouch), or `4` native touch passthrough (known mouse-motion issue). Only `0`, `1` and `4` are accepted; invalid or empty values stop launch. Gaming Mode ignores this setting. The selected mode is logged. See [Desktop Mode](../INSTALL-STEAM-DECK.md#desktop-mode-and-gaming-mode).
* `LEPTON_GAMING_TOUCH_MODE` selects Gaming Mode's Gamescope touch mode: `0`, `1` or `4`, with native multitouch passthrough (`4`) remaining the default on the existing Gaming Mode path on all hardware. Invalid or empty values stop launch. Desktop Mode (including direct Wayland) ignores this setting. The selected mode is logged. Set either override per game through Steam Launch Options, e.g. `LEPTON_GAMING_TOUCH_MODE=1 %command%`. See [touch-mode test results](../INSTALL-STEAM-DECK.md#gaming-mode-touch-experiments).
* `LEPTON_LOCAL_FULLSCREEN=0` requests the original maximized/windowed direct path for a local-desktop installation. The default is `1` (native fullscreen); only `0` and `1` are accepted. This requires the Phase 2 hwcomposer component and does not change normal Deck geometry.
* `LEPTON_LOCAL_USE_GAMESCOPE=1` selects the windowed Gamescope fallback for an installed `local-desktop` tool. Local installs otherwise use direct Wayland by default. The profile is installation-specific data in `compat_tool/install-profile`, not a global environment setting. See [local desktop routing](LOCAL-DESKTOP.md).
* `LEPTON_DESKTOP_DIRECT=1` remains an experimental opt-in to bypass nested Gamescope on the desktop. The desktop touch-mode setting is ignored on this path.

* ```LEPTON_KEEP_CONTEXT=true``` to keep a context after the container has exited, debug option.
* ```LEPTON_STRACE=true``` to strace the application launched by the container.
* ```LEPTON_DEBUG_LAUNCH=true``` to wait e.g. for gdb before continuing execution after forking, but before launching the app.
* ```LEPTON_GDB_PORT``` to configure the port used by gdb/lldb.
* ```WAYLAND_DISPLAY``` wayland display socket, used only in 2D app mode.
* ```XDG_RUNTIME_DIR``` used to determine the pulseaudio socket.
* ```ENABLE_VULKAN_VALIDATION_LAYER```, ```ENABLE_VULKAN_FDM_INJECTION_LAYER```, ```ENABLE_VULKAN_GFXRECONSTRUCT_LAYER```, ```ENABLE_VULKAN_RPO_LAYER```, ```ENABLE_VULKAN_RENDERDOC_CAPTURE``` can be used to enable the corresponding vulkan layers.  ```ENABLE_VULKAN_VALIDATION_LAYER_LATE``` will perform validation on the application and any other enabled layers, as opposed to only the output from the application itself.
* ```LEPTON_GFXRECON_*``` envvars are translated to their corresponding ```debug.gfxrecon.*``` Android system properties when the gfxreconstruct layer is enabled. Unprefixed ```GFXRECON_*``` envvars are not considered.
* ```VK_INSTANCE_LAYERS``` can be a colon separated list containing vulkan layer names which should be enabled.
* ```LEPTON_FORCE_SOFTWARE``` mostly for gitlab since gpu rendering is not available there.
* ```LEPTON_NO_CONTEXT``` avoid clearing "baked" app data even if it would otherwise be required or recommended. Use with caution and only during development.
* ```LEPTON_LOCK_TIMEOUT``` maximum time to wait for the lepton.lock. This is mostly a debugging/test option.
* ```LEPTON_APP_LAUNCH_TIMEOUT``` maximum time to wait until an app is considered as failed to start.
* ```LEPTON_APP_INSTALL_TIMEOUT``` maximum time in seconds to wait for app installation. Defaults to 600.
* ```LEPTON_NO_PORT_FORWARDING``` disable automatic port forwarding. This is mostly a debugging/test option.

* Various other environment variables like ```SteamAppId```, ```STEAM_COMPAT_DATA_PATH```, etc. are used to configure the launch of a game via steam.
* Even more environment variables like, ```EnableFrameEndMarkers```, ```DisableTimelineSemaphoreWait```, ```HTTP_PROXY``` etc. are passed through to the container/app.

# Marker files:
* ```lepton-show-flatscreen``` inside the application depot can be used to configure an application for 2D launch mode.

Enviroment variables of the form:
```LEPTON_ENV_VARNAME=vale``` are passed through to the app as ```VARNAME=value```.
