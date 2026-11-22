# Hardware video decoding (VA-API), experimental

Android 14 in Lepton decodes video with Android's software Codec2 decoders
(`c2.android.*`). This adds a vendor Codec2 service that decodes with FFmpeg and,
when enabled, uses the GPU's video engine through VA-API. It is built into the
image and **off by default**.

The approach is: VA-API first, **copy-back** first, zero-copy later. FFmpeg
decodes into its own VA surfaces, and each frame is copied into an ordinary
Android buffer.

## What has been tested

Tested with bundle `video-vaapi-test-16` (image `f15ed14`) and media probe
`0120786`, headless:
- Intel UHD 630 (Gen 9.5): iHD 24.3.4, with i965 also installed;
- AMD RX 6700 XT: Mesa 26.0.8 radeonsi.

The results below are from these two machines only.

| Clip (probe) | Intel UHD 630 | AMD RX 6700 XT |
| --- | --- | --- |
| H.264 High 720p and 1080p | VA-API; content identical to Android's decoder | same |
| Repeat ×3, flush and seek | identical | identical |
| HEVC Main | VA-API; identical | VA-API; identical |
| HEVC Main10 | VA-API (P010); not compared, see below | same |
| VP9 Profile 0 | VA-API; identical | VA-API; identical |
| AV1 | not offered (iHD reports no AV1 on Gen 9.5); Android's `c2.android.av1.decoder` used | VA-API; identical |
| H.264, 640×360 → 1280×720 mid-stream | VA-API; **one frame lost at the switch**, all others identical | same |
| H.264 High 4:4:4 | FFmpeg software inside the service (no VA driver decodes 4:4:4), logged as such | same |
| Surface output (ImageReader) | every frame delivered | same |
| Hardware decoding off | Android's decoders, unchanged | same |

"Identical" means the CRC of the visible luma of every frame equals Android's
software decoder's. H.264, HEVC, VP9 and AV1 decoding is bit-exact.

**Evidence of GPU decoding.** The DRM video-engine time of the FFmpeg service
was 0.5 s (Intel) and 14.7 s (AMD) during a probe run; no other process used the
video engine. With hardware decoding off, no process used it.

**HEVC Main10 profile (patch 0025), AMD, `video-vaapi-test-19` (`9795c05`):**
the probe's `LEPTON_MEDIA_HEVC_PROFILES` and `LEPTON_MEDIA_HEVC_MAIN10` lines
show:
- with hardware decoding on, `c2.ffmpeg.hevc.decoder` lists Main10, and Android
  picks it for a Main10 stream. The session is `decode=vaapi
  sw_format=p010le`, with every frame from the GPU;
- with hardware decoding off, no decoder lists Main10.

The other probe results matched test-16.

**Real app: VLC 3.x** (`org.videolan.vlc` 13070208), on the desktop with
`run-apk.sh --app --display desktop --video-hwaccel`. Clips opened by intent
from `/data/local/tmp`.

Intel, test-17 (before patch 0025):
- H.264, HEVC 8-bit and VP9 played through `c2.ffmpeg.*` on VA-API;
- HEVC 10-bit went to VLC's own software decoder.

AMD, test-19:

| Clip | VLC decoder | Service | Picture (user) |
| --- | --- | --- | --- |
| HEVC Main10 1080p | `c2.ffmpeg.hevc.decoder` | `decode=vaapi sw_format=p010le` | good |
| HEVC Main 1080p | `c2.ffmpeg.hevc.decoder` | vaapi, 1235 hw / 0 sw frames | good |
| H.264 High 1080p | `c2.ffmpeg.h264.decoder` | vaapi, 1446 hw / 0 sw frames | good |
| VP9 Profile 0 1080p | `c2.ffmpeg.vp9.decoder` | vaapi, 720 hw / 0 sw frames | fine |
| AV1 10-bit 1080p | VLC's dav1d | not used | not judged |
| HEVC Main10 8K HLG | VLC's avcodec | not used | choppy, very slow |

All sessions had 0 transfer failures. Only the FFmpeg service had video-engine
time: 32.2 s over the session.

The Main10 session's end line was lost because logcat's ring buffer filled.
Keep a filtered `logcat` running into a file during app tests.

VLC never uses MediaCodec for AV1, in 3.0.x or master: its `mediacodec.c` has
no AV1 entry. GPU AV1 therefore needs another player.

The 8K clip went past the service's HEVC limit (see "Known issues").

**Not verified:**
- 10-bit output against a reference: Android has no HEVC Main10 software decoder
  to compare with, and copy-back converts to 8-bit. The user judged the picture
  in VLC only;
- newer Intel GPUs (Ice Lake and later; Xe GPUs on the `xe` kernel driver);
- other AMD generations;
- VP8, MPEG-2 and VC-1 content;
- real apps other than VLC (ExoPlayer-based players, games), and AV1 in a real
  app;
- long playback.

## Enabling

Set `LEPTON_VIDEO_HWACCEL=true` (Steam launch options, or
`tests/runtime/run-apk.sh --video-hwaccel`). The launcher
(`compat_tool/liblepton/properties.sh`) then sets:

- **`debug.ffmpeg-codec2.rank=256` and `.rank.video=256`:** the service's video
  decoders rank ahead of Android's (512).
- **`.rank.audio=4294967295`:** its audio decoders stay disabled, so audio is
  unchanged.
- **`media.sf.hwaccel=1`:** FFmpeg opens a VA-API device on the render node in
  `gralloc.gbm.device`, the GPU Lepton selected for graphics.
- **`debug.ffmpeg-codec2.hwaccel.force=true`:** the service lists only the video
  codecs the VA driver decodes (see "Codecs"). The others stay on Android's
  decoders.
- **`debug.ffmpeg-codec2.hwaccel.drm=false`:** copy-back.

It is refused, with a log line, in these cases:
- under software rendering;
- when Android's media decoders (Codec2) are off;
- when the image has no VA driver for the selected GPU (Intel: `iHD_drv_video.so`
  or `i965_drv_video.so`; AMD: Mesa's VA entry point in `libgallium_dri.so`);
- on images other than Android 14 x86_64.

**When off:**
- `debug.ffmpeg-codec2.rank` is `4294967295`, so the service lists nothing and
  Android's codec list is unchanged;
- these defaults come from `lepton_x86_64/video-defaults.prop` in the system
  `build.prop`, ahead of the launcher's `/vendor/waydroid.prop` import. Vendor
  properties load after that import and would override the launcher, so the
  defaults must not move there.

`tests/runtime/test-runtime-properties.sh` and `test-video-vaapi-config.py` cover
this.

## Codecs

The service queries the VA driver once, listing the profiles with a VLD (decode)
entry point. It logs them as `LEPTON_VA_CAPS` in the boot log:

```
LEPTON_VA_CAPS driver="Intel iHD driver ... 24.3.4" node=/dev/dri/renderD128 codecs=MPG2 H264 VP80 HEVC HEVC10 VP90 VP92 profiles=...
LEPTON_VA_CAPS driver="Mesa Gallium driver 26.0.8 for AMD Radeon Graphics (radeonsi, navi22...)" node=... codecs=MPG2 H264 HEVC HEVC10 VP90 VP92 AV10 profiles=...
```

With `hwaccel.force`, only those codecs are offered (patch 0024). This covers
the five checked codecs (H.264, HEVC, VP8, VP9, AV1) and the other FFmpeg video
decoders (MPEG-2/4, H.263, DivX, WMV...). The service marks all of them as
hardware, so FFmpeg software decoders must not replace Android's.

The list is per codec, not per profile. The one exception is HEVC Main10, which
patch 0025 lists only when the driver reports `HEVC10`. A stream whose profile
the driver cannot decode, such as 4:4:4 or HEVC Main10 on a GPU without it, is still
decoded, by FFmpeg in software inside the service. It is logged as such (see
"Diagnostics"), and it does not hang. Android's decoders cannot decode those
streams either. Mesa is built with decoders only:
`-Dvideo-codecs=h264dec,h265dec,vp9dec,av1dec,mpeg12dec,vc1dec`. H.264 and
H.265 are patent-encumbered; no hardware encoders are built.

## Diagnostics

The service logs to logcat:

| Line | Meaning |
| --- | --- |
| `LEPTON_VA_CAPS` | once per service start: VA driver, render node, decodable codecs and profiles |
| `LEPTON_VA_SESSION codec= profile= size= decode=vaapi\|software [reason=] sw_format= zero_copy=` | once per decoder session, at its first frame |
| `LEPTON_VA_SESSION_END codec= hw_frames= sw_frames= transfer_failures=` | when the session ends |

Reasons for `decode=software`:
- `hwaccel-off`;
- `no-va-device-or-codec`;
- `va-cannot-decode-stream`: FFmpeg's internal software fallback, for example an
  unsupported profile.

`transfer_failures` counts hardware frames that could not be copied back (each is
dropped). It was 0 in every tested session.

`MediaCodecInfo.isHardwareAccelerated()` is not evidence: the service reports
every component as hardware, and FFmpeg may still decode in software. Use the
`LEPTON_VA_SESSION` lines and the GPU's video engine.

## How to validate

```bash
# Media probe APK (built on a host with the AOSP checkout and ffmpeg)
bash tests/runtime/build-jni-smoke.sh --aosp <aosp> --abi x86_64 --media-smoke --output probe.apk

# GPU video-engine evidence while the probe runs (on the host)
bash tests/runtime/sample-video-engine.sh /tmp/video.log & s=$!
bash tests/runtime/run-apk.sh [--stage-dir <stage>] --apk probe.apk --expect-abi x86_64 \
    --media-smoke --rendering intel|amd --display headless --seconds 200 --video-hwaccel --execute
kill $s; bash tests/runtime/sample-video-engine.sh --summary /tmp/video.log

# Results (the run prints the retained log directory)
grep -ah 'LEPTON_VA_CAPS' <dir>/boot-logcat.log
grep -aoE 'LEPTON_MEDIA_(CODEC|REPEAT|SEEK|AVC_DECODE) .*|LEPTON_VA_SESSION.*' <dir>/app-logcat.log
```

Expected with hardware decoding:
- `LEPTON_MEDIA_CODEC ... result=PASS` for the 8-bit clips the GPU decodes;
- `LEPTON_VA_SESSION ... decode=vaapi` for them;
- video-engine time only for `android.hardware.media.c2-ffmpeg-service`.

Run again without `--video-hwaccel` for the software baseline: every decoder is
`c2.android.*`, and there is no video-engine time.

`LEPTON_MEDIA_CODEC` results:
- `PASS`: every frame identical to Android's decoder, and Surface output works;
- `MISMATCH`: lists the differing frame numbers, plus `LEPTON_MEDIA_CODEC_CRCS`
  with both CRC lists;
- `INCOMPLETE`: no output for 10 s;
- `UNSUPPORTED`: no decoder;
- `NO_REFERENCE`: Android cannot decode the clip;
- `NOT_COMPARED`: 10-bit output;
- `SURFACE_FAIL`.

## Zero-copy (development only, broken)

`LEPTON_VIDEO_HWACCEL_ZEROCOPY=true` selects the service's DRM PRIME mode:
the GPU decodes straight into Android's buffers. The launcher reports it as a
broken development option. Findings:

- **Intel i965:** every VA surface import fails; the app waits for frames.
- **Intel iHD:** imports succeed, but the decoded data is wrong (CRC mismatch,
  scrambled picture).
- **AMD radeonsi:** decoding is bit-exact once the buffers have 256-byte pitches
  and a linear modifier. That needs `patches/experimental/0022` (minigbm), which
  is not applied by default. SurfaceFlinger then aborts creating a texture from
  the NV12 buffer (`Failed to create a valid texture ... format:35`).
- **Patch 0021** (applied; only active in this mode) keys VA surfaces by
  minigbm's buffer id for buffers without a BufferQueue slot. Without it, ByteBuffer
  output loops forever. VA surfaces are kept until the decoder closes. The
  generation and lifecycle of reused buffers have not been reviewed beyond that.

Making zero-copy work needs:
- NV12 import support in Mesa/RADV for Android hardware buffers, like patch 0002
  does for YV12;
- an allocation path for video buffers that does not change every NV12 buffer;
- investigation of iHD's imports.

It is future work.

## Patches

| Patch | Project | Purpose |
| --- | --- | --- |
| 0017 | `external/ffmpeg` | x86_64 build without Vulkan: Android 14's Vulkan headers are too old |
| 0018 | `external/stagefright-plugins` | drop the "raw codec data" parameter, which only exists in WayDroid's `frameworks/av` |
| 0019 | `external/mesa` | VA-API in Mesa's Android build; accept libva-android's display |
| 0020 | `external/intel-media-driver` | build iHD with Android 14's clang |
| 0021 | `external/stagefright-plugins` | zero-copy: buffer identity without a BufferQueue; import logging |
| 0023 | `external/stagefright-plugins` | copy-back in the surface's own format (bit-exact on Mesa) |
| 0024 | `external/stagefright-plugins` | VA capability query and gating; session diagnostics |
| 0025 | `external/stagefright-plugins` | list HEVC Main10 when VA decodes `HEVC10` |
| experimental/0022 | `external/minigbm` | zero-copy NV12 layout; not applied |

**Why 0023:** asking Mesa's `vaGetImage` for a format other than the surface's
(YUV420P from NV12) converts through its video compositor and changes every
pixel. The service now downloads in the surface's software format (NV12, or
P010 for 10-bit), and its swscale step converts to YV12 without changing luma.

## Components (third party)

Added by these manifests, installed into a prepared checkout with
`prepare-x86_64.sh --add-projects` and pinned to commits:
- `manifests-34/20-video-vaapi.xml` (WayDroid-ATV's Android 14 branches);
- `21-video-intel-ihd.xml` (Intel Celadon).

| Path | Project | Licence |
| --- | --- | --- |
| `external/stagefright-plugins` | Codec2 FFmpeg service (`android.hardware.media.c2-ffmpeg-service`, Michael Goffioul and the Android-x86 project) | Apache-2.0 |
| `external/ffmpeg` | FFmpeg 7.1, Android build | LGPL-2.1-or-later as configured (`CONFIG_GPL`, `CONFIG_NONFREE` and `CONFIG_VERSION3` are 0); shared libraries |
| `external/libva` | libva 2.23 (VA-API 1.23) for Android, vendor partition | MIT |
| `external/intel-vaapi-driver` | Intel i965 VA driver (Gen 4 to Gen 9.5) | MIT |
| `external/intel-media-driver` | Intel iHD VA driver 24.3.4 (Gen 8 and newer), free kernels only | MIT |
| `external/gmmlib` | Intel graphics memory library for iHD | MIT |

The manifest removes the unused Android 11 libva at
`hardware/intel/common/libva`, which has the same module names. FFmpeg uses
AOSP's `libdav1d` and `libdrm`. Distributing an image that contains FFmpeg needs
the LGPL notices and source availability for these libraries.

On Intel GPUs supported by both drivers, libva tries iHD before i965. On the UHD
630, iHD copy-back was slower than i965 (about 126/183 against 165/328 frames/s at
720p, buffers/Surface).

## Known issues

- **Resolution change:** one frame is lost where an H.264 stream changes
  resolution mid-stream (both GPUs). All other frames are identical. Not
  investigated: the service pairs output frames with Android's work items by
  timestamp.
- **Android's own software decoders:** comparing a `c2.android.*` decoder with
  itself sometimes gives one or a few differing frames, under heavy host load or
  on Intel. This is in Android's software path, not VA-API; not investigated.
- **10-bit:** HEVC Main10 has no software decoder in this image. With hardware
  decoding it is converted to 8-bit (YV12) and shown as SDR. HDR10 and HDR10+
  are not listed. HDR end to end would need all of these, and is a separate
  project:
  - P010 output;
  - HDR profiles and metadata in Codec2;
  - an HDR dataspace through SurfaceFlinger;
  - 10-bit PQ through Lepton's display bridge.
- **Size limits:** `media_codecs_ffmpeg_c2.xml` caps HEVC at 4096×4096 and AV1
  at 2048×2048, below what the GPU decodes. Larger streams go to the app's own
  software decoder: an 8K HEVC clip was choppy in VLC. These limits could come
  from VA (`vaQuerySurfaceAttributes`); this has not been done.
