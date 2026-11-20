# Hardware video decoding (VA-API), experimental

Android 14 in Lepton decodes video with Android's software Codec2 decoders
(`c2.android.*`). This adds a vendor Codec2 service that decodes with FFmpeg and,
when enabled, uses the GPU's video engine through VA-API. It is built into the
image and **off by default**.

## Enabling

Set `LEPTON_VIDEO_HWACCEL=true` (Steam launch options, or
`tests/runtime/run-apk.sh --video-hwaccel`). The launcher then:

- ranks the service's video decoders (256) ahead of Android's software ones
  (512); its audio decoders stay disabled, so audio keeps Android's decoders;
- sets `media.sf.hwaccel=1`, which makes FFmpeg open a VA-API device.

It is refused, with a log line, under software rendering, when Android's media
decoders (Codec2) are off, and on images other than Android 14 x86_64. Off,
`debug.ffmpeg-codec2.rank` is `4294967295`: the service lists no components and
Android's codec list is unchanged.

libva opens the render node in `gralloc.gbm.device`, the GPU Lepton already
selected for graphics.

## Components (third party)

Added by `manifests-34/20-video-vaapi.xml` (installed into a prepared checkout
with `prepare-x86_64.sh --add-projects`), all from WayDroid-ATV's Android 14
branches and pinned to commits:

| Path | Project | Licence |
| --- | --- | --- |
| `external/stagefright-plugins` | Codec2 FFmpeg service (`android.hardware.media.c2-ffmpeg-service`, Michael Goffioul and the Android-x86 project) | Apache-2.0 |
| `external/ffmpeg` | FFmpeg 7.1, Android build | LGPL-2.1-or-later as configured (`CONFIG_GPL`, `CONFIG_NONFREE` and `CONFIG_VERSION3` are 0); shared libraries |
| `external/libva` | libva 2.23 (VA-API 1.23) for Android, vendor partition | MIT |
| `external/intel-vaapi-driver` | Intel i965 VA driver (Gen 4 to Gen 9.5, e.g. UHD 630) | MIT |

The manifest removes the unused Android 11 libva at `hardware/intel/common/libva`
(system partition; same module names). FFmpeg uses AOSP's `libdav1d` and
`libdrm`. Distributing an image that contains FFmpeg needs the LGPL notices
and source availability for these libraries.

Lepton patches: `0017` builds FFmpeg for x86_64 without Vulkan (Android 14's
Vulkan headers are too old for it), and `0018` removes the service's "raw codec
data" parameter, which needs WayDroid's `frameworks/av` changes; without it the
decoders take the codec from the media type.

Not yet included: Intel's iHD driver (newer Intel GPUs) and Mesa's VA driver
for AMD (`radeonsi`).

## Verifying

A working video does not show that the GPU decoded it. Check:

1. **Decoder:** the media probe's `LEPTON_MEDIA_AVC_DECODE ... decoder=` names
   `c2.ffmpeg.h264.decoder` instead of `c2.android.avc.decoder`.
2. **GPU video engine:** `drm-engine-video` in `/proc/<pid>/fdinfo/*` of the
   service process (`android.hardware.media.c2-ffmpeg-service`) increases while
   it decodes. See `tests/runtime/README.md`.
3. **Copies:** decoded frames are copied from VA surfaces into Android buffers
   unless the service's DRM PRIME mode is used; zero-copy is not claimed.
