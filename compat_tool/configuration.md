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
* `LEPTON_SHARED_FOLDERS` chooses which host folders appear in the game's Android shared storage: by default your Documents, Downloads, Videos, Music and Pictures folders; folders you give are added to them, and naming default folders (or `none`) chooses which of those are kept. See [Shared folders](#shared-folders).
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

By default, Android sees five of your folders, read-write:

| Your folder | In Android |
| --- | --- |
| Documents | `Documents` |
| Downloads | `Download` |
| Videos | `Movies` |
| Music | `Music` |
| Pictures | `Pictures` |

"Your folder" is the one your desktop uses, from `~/.config/user-dirs.dirs`
(the XDG user directories), so translated names such as `~/Musik` and
folders moved to another drive are used. Without that file, or a line in it,
Lepton uses `~/Documents`, `~/Downloads`, `~/Videos`, `~/Music` and
`~/Pictures`. Lepton never creates these folders: one that doesn't exist is
skipped. A folder set to your home folder itself (which is how XDG turns a
folder off) is never shared; the log says so. Desktop, Public and Templates
are not shared.

Two rules decide what is shared:

* **Folders you give are added.** A folder path, or the name of a folder in
  your home, is shared next to the default folders.
* **Default folder names choose the defaults.** Name one or more of
  `Documents`, `Downloads`, `Videos`, `Music`, `Pictures` (or the Android
  names `Download`, `Movies`, in any case) and only those are shared; name
  none of them and all five are; `none` shares none of them.

| Value | What Android sees |
| --- | --- |
| *(unset)* | The five default folders |
| `Books` or `"~/Books"` | The five default folders, and `~/Books` as `Books` |
| `"/run/media/deck/SD/Films"` | The five default folders, and that folder as `Films` |
| `"Library=/run/media/deck/SD/Books"` | The five default folders, and that folder as `Library` |
| `Music,Pictures` | Only those two default folders |
| `"Downloads,Books,/mnt/media/Films"` | `Download`, `Books` and `Films` |
| `"none,Books"` | Only `Books` |
| `none`, or empty | None of your folders. Android keeps private `Documents`, `Download`, `Movies`, `Music` and `Pictures` folders in the profile |
| `"Music=/mnt/Media/Music"` | The default folders, with that folder as `Music` in place of your Music folder |
| `"Books:ro"`, `Downloads:ro` | Read-only: Android can open the files but not change, add or delete them |

Examples, as Steam launch options:

```bash
LEPTON_SHARED_FOLDERS=Books %command%
LEPTON_SHARED_FOLDERS="/run/media/deck/SD/Films" %command%
LEPTON_SHARED_FOLDERS="Music,Pictures,Books" %command%
LEPTON_SHARED_FOLDERS=none %command%
```

and with `lepton-play`:

```bash
LEPTON_SHARED_FOLDERS="Documents,Books" ~/.local/share/lepton-commands/lepton-play game.apk
```

Writing the value:

* Separate items with commas; spaces around them are ignored. Use quotes when
  a path has spaces; the spaces are part of the path. The default folder
  names may also be separated by spaces (`"Documents Videos"`), but paths
  always need commas. Paths cannot contain commas or `"`.
* A name alone that isn't a default folder (`Books`, `My Comics`) is that
  folder in your home. It must exist: if it doesn't, perhaps a misspelt
  default folder name, the launch stops and says so. For a folder anywhere
  else, give its path.
* `~/` means your home folder. Lepton expands it itself, so it works inside
  quotes.
* Any folder you can open works: inside or outside your home folder, on an
  internal drive, a USB drive or an SD card (`/run/media/<user>/<drive>/...`),
  or under `/mnt`.
* Android's folder name must be a plain name: at most 64 characters, not
  starting with `.` or `-`, without `/ \ : * ? " < > |`. If a folder's own
  name doesn't fit, or two folders end in the same name, give one a name with
  `Name=/path`. Names are compared without regard to case, as Android does.
* `Android` can't be used: it holds app data and OBB files. A default
  folder's name can be given to a path, which then replaces that default
  folder; listing both (`Music,Music=/x`) is a mistake. Giving a default
  folder by its path (`~/Downloads`) shares it under that folder's own name
  (`Downloads`) in place of the default one.
* When a launch is stopped because of the setting, the popup lists each
  problem and the value that was used; nothing has been changed.

## What can't be shared

Lepton refuses, for default and named folders alike, and checks again at
every launch, after following the path if it is a link:

* `/`, your whole home folder, and folders that hold it (`/home`,
  `/var/home`);
* folders that list whole drives (`/mnt`, `/media`, `/run/media`,
  `/run/media/<user>`); share a folder on the drive, or the drive itself
  (`/run/media/<user>/<drive>`);
* system folders: `/etc`, `/usr`, `/bin`, `/sbin`, `/lib*`, `/boot`, `/efi`,
  `/root`, `/proc`, `/sys`, `/dev`, `/run` (other than drives) and `/var`
  (other than `/var/home` and `/var/mnt`, used by Fedora Atomic and SteamOS-like
  systems);
* hidden folders in your home (`~/.ssh`, `~/.config`, `~/.local`, ...), which
  hold settings and keys, and through them Steam's own folders and Lepton's
  installation;
* folders that hold, or are inside, Lepton's own data: this game's Android
  profile (and so a Steam library folder holding its `compatdata`), the
  `lepton-play` profiles, and the Lepton tool itself;
* the same folder twice.

A path you give that is a symlink is followed to the real folder, which is
what is checked and mounted; it is named after the link. Links inside a
shared folder are not followed or mounted: inside Android they lead to the
container's own files, not your host's. Lepton never changes a shared
folder's permissions, owners, ACLs or SELinux labels. Android uses your own
user's access: if you can read and write a folder, so can the game.

Not a security boundary: this setting decides what appears in Android's
shared storage, nothing more. Lepton also mounts the Steam install and Steam
library folders, and the folder of a shortcut's APK and OBB files, so games
can be installed and load their data. Those mounts are not part of shared
storage, are not shown in Android's file manager, and are not changed by
`LEPTON_SHARED_FOLDERS`. So a file in a Steam library is still reachable
inside the container with sharing set to `none`, and a folder shared
read-only can still be written through such a mount if it is also inside
one.

## When the setting is checked and what happens

* The whole value is checked before anything changes. A mistake (an unknown
  name, a file instead of a folder, a folder you can't open, a clash of
  names, a folder that can't be shared) stops the launch with every problem
  listed. On the Deck this shows as a popup. Nothing is changed.
* With no setting, a default folder that can't be shared (set to your home
  folder, or to a folder above) is skipped with a warning in the log, and
  the game starts. Asked for by name, it is a mistake as above.
* A folder that doesn't exist at launch, such as one on a drive that isn't
  plugged in, doesn't stop the game. Its link is kept and nothing is
  changed: Android shows the folder again once the drive is back. The log
  says so for a folder you named; a missing default folder is skipped
  quietly.
* Removing a folder from the setting, or renaming it, removes Lepton's link
  for it at the next launch. The host folder and its files are not touched.
  Links and folders that Lepton didn't make are left alone.
* If Android already has a real folder of that name with files in it (for
  example `Music` or `Pictures` holding files a game saved), the host folder
  isn't linked: the launch continues, the log says so, and Android's files
  are kept. Move them out to share the host folder instead. An empty folder,
  or one holding only Android's `.thumbnails` marker, is replaced.
* Repeated launches with the same setting change nothing.

## How it works

Each shared folder is mounted into the container at `/lepton/shared/<Name>`,
and Android's shared storage holds a link `<Name>` to it. The `/lepton`
location avoids Android's own `/mnt`, which hides host paths under `/mnt`.
Android's storage service serves these folders to apps like any other
shared-storage folder.

A link that points at exactly `/lepton/shared/<its own name>` is Lepton's:
that is how a folder no longer shared is recognised, with no separate list
to keep in step. Android's storage service doesn't let apps make links, and
a link naming a Lepton mount point is not something people or apps make by
accident; Lepton only ever removes such a link, never the folder behind it.
(Lepton runs Android apps as your user, so an app working on the profile's
files directly, rather than through shared storage, could make one; the
worst it could cause is that link being removed.) Profiles from before this used links to `~/Documents`, `~/Downloads`
and `~/Videos` themselves; those are recognised too, and replaced by the new
kind at the next launch that shares the folder (the log says "link
updated"). Nothing else in the profile changes.

## Shared Android profiles

The setting belongs to the shortcut that starts Android, and applies to
everything installed in that profile: all apps in one Android share its
mounts. For the **Google Play (Lepton)** shortcut, every game installed
through Play sees the same folders. Launching the same profile with a
different setting changes the folders for every app in it.

## Media apps and file pickers

Two different things decide what an Android app finds:

* **Opening files by path**, as file managers with all-files access and many
  games and readers do: works for every shared folder, read and write.
* **Android's media index (MediaStore)**, used by gallery, music and video
  apps, and by the "Images", "Audio", "Videos" and "Recent" views of
  Android's file picker: on Lepton's current Android 14 image it lists no
  files from shared storage at all. This is not caused by shared folders or
  their links. In local testing, a photo in Android's own `DCIM` folder,
  files in linked folders, and files in a folder mounted straight into
  shared storage (no link) were all missing from the index, and Android's
  storage service could see all of them. Android never runs its first scan
  of shared storage at boot, and the scan requests available from a shell
  either do nothing on Android 14 or don't run in this image.
* **Android's file picker, browsing folders** (the Storage Access
  Framework): lists folders from the file system, not the media index, so it
  is expected to show shared folders. Not yet confirmed on a device.

Making the media index work is separate work: it needs a scan of shared
storage once Android has started, requested from inside Android.

# Marker files:
* ```lepton-show-flatscreen``` inside the application depot can be used to configure an application for 2D launch mode.

Environment variables of the form:
```LEPTON_ENV_VARNAME=value``` are passed through to the app as ```VARNAME=value```.
