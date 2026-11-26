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
* `LEPTON_SHARED_FOLDERS` chooses which host folders appear in the game's Android shared storage: the default Documents, Downloads and Videos, any other folders you name, or none. See [Shared folders](#shared-folders).
* `LEPTON_DMA_HEAP_DEVICE` overrides `/dev/dma_heap/system` for diagnostics/tests. Automatic heap selection requires a readable/writable character device; leave unset normally.
* `LEPTON_PREFIX` supplies an external scratch directory. The launcher never owns or deletes a supplied prefix, including `/tmp/lepton-context.*`. Internally created prefixes always use `/tmp` regardless of `TMPDIR`; containers using the prefix or uncertain inspection/mount state prevent deletion. Persistent Android profiles are separate and retained by ordinary cleanup.
* ```LEPTON_LOCK_TIMEOUT``` maximum time in seconds to wait for the per-user `lepton.lock` (default 10). Initial acquisition and later re-acquisitions stop the command on failure; a timeout of 0 makes acquisition nonblocking. See [lock paths and launcher-only deployment](../FEDORA-DEBUGGING.md#per-user-launcher-lock).
* ```LEPTON_APP_LAUNCH_TIMEOUT``` maximum time to wait until an app is considered as failed to start.
* ```LEPTON_APP_INSTALL_TIMEOUT``` maximum time in seconds to wait for app installation. Defaults to 600.
* ```LEPTON_NO_PORT_FORWARDING``` disable automatic port forwarding. This is mostly a debugging/test option.

* Various other environment variables like ```SteamAppId```, ```STEAM_COMPAT_DATA_PATH```, etc. are used to configure the launch of a game via steam.
* Even more environment variables like, ```EnableFrameEndMarkers```, ```DisableTimelineSemaphoreWait```, ```HTTP_PROXY``` etc. are passed through to the container/app.

# Shared folders

Android apps see shared storage as `/storage/emulated/0` (the "internal
storage" a file manager shows). `LEPTON_SHARED_FOLDERS` chooses which host
folders appear there. Put it in the shortcut's Properties > Launch Options,
before `%command%`, or before the command for `lepton-play`.

| Value | What Android sees |
| --- | --- |
| *(unset)* | The default: host `~/Documents`, `~/Downloads` and `~/Videos` as `Documents`, `Download` and `Movies`, read-write |
| `none`, or empty | No host folders. Android keeps private `Documents`, `Download` and `Movies` folders in the profile |
| `Downloads` | Only `~/Downloads`, as `Download`. Any of `Documents`, `Downloads`, `Videos` (or the Android names `Download`, `Movies`), in any case |
| `"~/Books"` | `~/Books` as `Books`. Any folder path starting with `/` or `~/` is shown under its last name |
| `"Library=/run/media/deck/SD/Books"` | That folder, shown as `Library` |
| `"Downloads,~/Books,/mnt/media/Films"` | `Download`, `Books` and `Films` |
| `"~/Books:ro"`, `Downloads:ro` | Read-only: Android can open the files but not change, add or delete them |

Examples, as Steam launch options:

```bash
LEPTON_SHARED_FOLDERS=none %command%
LEPTON_SHARED_FOLDERS="Downloads,~/Books" %command%
LEPTON_SHARED_FOLDERS="~/My Comics:ro,Films=/run/media/deck/SD/Films" %command%
```

and with `lepton-play`:

```bash
LEPTON_SHARED_FOLDERS="Documents,~/Books" lepton-play game.apk
```

Rules:

* Separate items with commas. Use quotes when a path has spaces; the spaces
  are part of the path. The default folder names may also be separated by
  spaces (`"Documents Videos"`), but paths always need commas. Paths cannot
  contain commas or `"`.
* `~/` means your home folder. Lepton expands it itself, so it works inside
  quotes.
* Any folder you can open works: inside or outside your home folder, on an
  internal drive, a USB drive or an SD card (`/run/media/<user>/<drive>/...`),
  or under `/mnt`. A path that is a symlink is followed, and the folder is
  named after the link.
* Android's folder name must be a plain name: at most 64 characters, not
  starting with `.` or `-`, without `/ \ : * ? " < > |`. If a folder's own
  name doesn't fit, or two folders end in the same name, give one a name with
  `Name=/path`. Names are compared without regard to case, as Android does.
* `Android`, `Documents`, `Download` and `Movies` can't be used for your own
  folders: `Android` holds app data and OBB files, and the others belong to
  the default folders. Other standard names such as `Music` or `Pictures` can
  be used.
* These can't be shared: `/`, your whole home folder, system folders (`/etc`,
  `/usr`, `/proc`, `/sys`, `/dev`, `/boot`, other `/run` folders), any folder
  holding the game's own Android data (for example a Steam library folder
  that contains its `compatdata`), and the same folder twice.
* Lepton never changes the shared folder or its files' permissions, owners,
  ACLs or SELinux labels. Android uses your own user's access: if you can
  read and write a folder, so can the game.

When the setting is checked and what happens:

* The whole value is checked before anything changes. A mistake (an unknown
  name, a file instead of a folder, a folder you can't open, a clash of
  names, a folder that can't be shared) stops the launch with every problem
  listed. On the Deck this shows as a popup. Nothing is changed.
* A folder path that doesn't exist at launch, such as one on a drive that
  isn't plugged in, doesn't stop the game. The log says it is not shared
  this launch, and nothing is changed: Android shows the folder again once
  the drive is back. A missing default folder (`~/Videos`, say) is skipped
  quietly, as before.
* Removing a folder from the setting, or renaming it, removes Lepton's link
  for it at the next launch. The host folder and its files are not touched.
  Links and folders that Lepton didn't make are left alone.
* If Android already has a real folder of that name with files in it (for
  example, `Music` holds files a game saved), the host folder isn't linked:
  the launch continues, the log says so, and Android's files are kept. Move
  them out to share the host folder instead. An empty folder is replaced.
* Repeated launches with the same setting change nothing.

How it works: a default folder is mounted into the container at its host
path, and a folder path at `/lepton/shared/<Name>`; Android's shared storage
holds a link to it. A link that points at exactly `/lepton/shared/<its own
name>` is Lepton's, which is how a removed folder is recognised. The
`/lepton` location also avoids Android's own `/mnt`, which hides host paths
under `/mnt`. Android's storage service serves these folders to apps like any
other shared-storage folder.

Shared Android profiles: the setting belongs to the shortcut that starts
Android, and applies to everything installed in that profile. For the
**Google Play (Lepton)** shortcut, every game installed through Play sees the
same folders. Launching the same profile with a different setting changes
the folders for every app in it.

What this setting does not control: Lepton also mounts the Steam install and
Steam library folders, and the folder of a shortcut's APK and OBB files, so
games can be installed and load their data. Those mounts are not part of
shared storage, are not shown in Android's file manager, and are not changed
by `LEPTON_SHARED_FOLDERS`. A file in a Steam library is therefore still
reachable inside the container with sharing set to `none`.

# Marker files:
* ```lepton-show-flatscreen``` inside the application depot can be used to configure an application for 2D launch mode.

Environment variables of the form:
```LEPTON_ENV_VARNAME=value``` are passed through to the app as ```VARNAME=value```.
