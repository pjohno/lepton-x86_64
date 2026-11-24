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
* ```XDG_RUNTIME_DIR``` used to determine the pulseaudio socket and the per-user launcher lock.
* ```ENABLE_VULKAN_VALIDATION_LAYER```, ```ENABLE_VULKAN_FDM_INJECTION_LAYER```, ```ENABLE_VULKAN_GFXRECONSTRUCT_LAYER```, ```ENABLE_VULKAN_RPO_LAYER```, ```ENABLE_VULKAN_RENDERDOC_CAPTURE``` can be used to enable the corresponding vulkan layers.  ```ENABLE_VULKAN_VALIDATION_LAYER_LATE``` will perform validation on the application and any other enabled layers, as opposed to only the output from the application itself.
* ```LEPTON_GFXRECON_*``` envvars are translated to their corresponding ```debug.gfxrecon.*``` Android system properties when the gfxreconstruct layer is enabled. Unprefixed ```GFXRECON_*``` envvars are not considered.
* ```VK_INSTANCE_LAYERS``` can be a colon separated list containing vulkan layer names which should be enabled.
* `LEPTON_FORCE_SOFTWARE=true` selects slow software rendering (SwiftShader), including on unsupported GPUs; the default uses hardware graphics.
* `LEPTON_VULKAN_DRIVER=radeon|intel` overrides AMD-first, then Intel selection. The matching render node and image Vulkan HAL must exist. Intel Gen9+ ANV/Iris is experimental; older bundles may contain only AMD.
* `LEPTON_SKIP_GPU_CHECK=true` bypasses host GPU validation for diagnostics; it does not add a driver or make unsupported hardware compatible. Leave unset for safe validation.
* `LEPTON_CODEC2` defaults to automatic selection on Android 14 x86_64: `blob` for software rendering, AMD images with patch 0013 or Intel images with patches 0013 and 0014, otherwise `heap` when the host DMA-BUF system heap is readable/writable, otherwise `off`. `false` disables Codec2; `true` forces experimental BLOB allocation and can crash older AMD allocators or fail on Intel images without patch 0014. Mode names are outputs, not values for this variable. Ordinary PCM game audio is independent; AVC/video output remains unresolved. See [media decoder selection](../GAPPS.md#media-decoder-selection).
* `LEPTON_VIDEO_HWACCEL=true` enables experimental hardware video decoding (VA-API) on Android 14 x86_64 images that contain the Codec2 FFmpeg service: FFmpeg's video decoders are ranked ahead of Android's software ones, and decode on the GPU gralloc uses. Off by default; refused under software rendering or with Codec2 off. Audio keeps Android's decoders. See [video-vaapi.md](../image-14/docs/video-vaapi.md).
* `LEPTON_VIDEO_HWACCEL_OUTPUT=direct|copyback` (with `LEPTON_VIDEO_HWACCEL=true`) chooses how hardware-decoded frames reach Android: `direct` (default) has the GPU convert each frame straight into Android's buffer, which played 4K60 10-bit at full rate on the tested Intel, AMD and Steam Deck GPUs; `copyback` downloads and converts each frame on the CPU. Images without direct output use `copyback`, and the service switches a session to `copyback` by itself if direct output fails.
* `LEPTON_DMA_HEAP_DEVICE` overrides `/dev/dma_heap/system` for diagnostics/tests. Automatic heap selection requires a readable/writable character device; leave unset normally.
* `LEPTON_PREFIX` supplies an external scratch directory. The launcher never owns or deletes a supplied prefix, including `/tmp/lepton-context.*`. Internally created prefixes always use `/tmp` regardless of `TMPDIR`; containers using the prefix or uncertain inspection/mount state prevent deletion. Persistent Android profiles are separate and retained by ordinary cleanup.
* ```LEPTON_LOCK_TIMEOUT``` maximum time in seconds to wait for the per-user `lepton.lock` (default 10). Initial acquisition and later re-acquisitions stop the command on failure; a timeout of 0 makes acquisition nonblocking. See [lock paths and launcher-only deployment](../FEDORA-DEBUGGING.md#per-user-launcher-lock).
* ```LEPTON_APP_LAUNCH_TIMEOUT``` maximum time to wait until an app is considered as failed to start.
* ```LEPTON_APP_INSTALL_TIMEOUT``` maximum time in seconds to wait for app installation. Defaults to 600.
* ```LEPTON_NO_PORT_FORWARDING``` disable automatic port forwarding. This is mostly a debugging/test option.

* Various other environment variables like ```SteamAppId```, ```STEAM_COMPAT_DATA_PATH```, etc. are used to configure the launch of a game via steam.
* Even more environment variables like, ```EnableFrameEndMarkers```, ```DisableTimelineSemaphoreWait```, ```HTTP_PROXY``` etc. are passed through to the container/app.

# Marker files:
* ```lepton-show-flatscreen``` inside the application depot can be used to configure an application for 2D launch mode.

Environment variables of the form:
```LEPTON_ENV_VARNAME=value``` are passed through to the app as ```VARNAME=value```.
