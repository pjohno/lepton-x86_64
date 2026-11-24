# Hardware video decoding (VA-API)

Android 14 in Lepton decodes video with Android's software Codec2 decoders
(`c2.android.*`). This adds a vendor Codec2 service that decodes with FFmpeg and,
when enabled, uses the GPU's video engine through VA-API. It is built into the
image and **off by default** (`LEPTON_VIDEO_HWACCEL=true` turns it on).

When it is on, decoded frames reach Android in one of two ways
(`LEPTON_VIDEO_HWACCEL_OUTPUT`, see "Enabling"):

- **direct** (default, patch 0030): the GPU converts each frame straight into
  Android's buffer; no readback and no CPU conversion. It played a 4K59.94 HEVC
  Main10 clip at full rate on an Intel UHD 630, an AMD RX 6700 XT and a Steam
  Deck, where copy-back could not;
- **copy-back**: the CPU downloads each frame and converts it. Used when asked
  for, on images without direct output, and automatically for the rest of a
  session whenever direct output fails.

HDR output is not included: 10-bit video is shown as 8-bit SDR.

## How it works

```
app (MediaCodec) → Codec2 → c2.ffmpeg.* (FFmpeg service) → FFmpeg hwaccel → VA-API driver → GPU video engine
                                   │                                               (decodes into FFmpeg's own VA surfaces)
                                   ├─ direct:    VA surface → GPU video processor → Android buffer (YV12, imported as a VA surface)
                                   └─ copy-back: VA surface → CPU (map) → swscale → Android buffer (YV12)
```

| Term | Meaning | In this release |
| --- | --- | --- |
| Hardware decoding | The GPU's video engine decodes the bitstream into VA surfaces in GPU memory | yes |
| Copy-back | Each decoded surface is mapped for the CPU and copied, converted to 8-bit YV12, into an ordinary Android buffer (ByteBuffer or Surface) | yes |
| GPU VPP | The GPU converts formats through VA's video processing (`VAEntrypointVideoProc`) | yes, for direct output |
| Direct output | The GPU writes the converted frame into Android's own (gralloc) buffer, which SurfaceFlinger then shows | yes, the default |
| Zero-copy | The GPU *decodes* straight into Android's buffers | no: removed; see "Direct output" for why direct output differs |

Each frame, with copy-back, the service:
1. sends the packet to FFmpeg (`avcodec_send_packet`), which submits the
   decode to VA;
2. receives the decoded VA surface (`avcodec_receive_frame`);
3. waits for the GPU (`vaSyncSurface`);
4. maps the surface for reading (see "Copy-back modes");
5. gets an Android output buffer (`fetchGraphicBlock`) and maps it;
6. converts NV12 or P010 to YV12 with swscale. Luma is copied unchanged for
   8-bit; 10-bit is reduced to 8-bit.

### Copy-back modes (patch 0029)

| Mode | How it reads the surface | Default for |
| --- | --- | --- |
| `derive` | `av_hwframe_map(READ \| DIRECT)`: Mesa maps the surface through a cached staging copy, and swscale reads it directly | Mesa drivers (AMD radeonsi; `vaQueryVendorString` starts with "Mesa Gallium driver") |
| `map` | FFmpeg's default read map: `vaCreateImage` + `vaGetImage` + `vaMapBuffer`, a new image buffer for every frame | every other driver (Intel iHD and i965) |

`map` is the default on Intel because a direct map of an iHD surface can be
uncached memory, which is slow to read. That is why FFmpeg avoids it for reads.
If the derived map fails, the service logs it and uses `map` for the rest of the
session.

The 10-bit to 8-bit conversion runs on 2 swscale slice threads at 1080p and
above (`sws_scale_frame`), and on 1 thread otherwise. 8-bit NV12 to YV12 stays
on one thread: it is a plain copy, and more threads did not help.

### Direct output (patch 0030)

The service's DRM PRIME "VPP mode" from upstream, made to work. FFmpeg still
decodes into its own VA surfaces, laid out as each driver wants. Per frame, the
service:
1. waits for the decode (`vaSyncSurface`);
2. fetches an Android output buffer: the same CPU-mappable YV12 buffer copy-back
   uses (minigbm refuses YV12 for decoder-only usage). It is imported as a VA
   surface once per BufferQueue slot (ByteBuffer outputs get a new buffer each
   frame; their imports are dropped when the frame is released);
3. has the GPU convert the decoded surface into it (`VAProfileNone` /
   `VAEntrypointVideoProc`), covering the picture only: the buffer is aligned to
   64 and the output is cropped to the decoded size;
4. waits for the GPU (`vaSyncSurface`) before the buffer goes to the framework,
   keeping the decoded surface until then.

The conversion changes layout and bit depth only: same matrix in and out, both
sides declared full range so no driver remaps values. Android's YV12 (planes Y,
V, U) is described to VA as I420 with the U plane first, because Mesa writes a
YV12 import's chroma in I420 order. 10-bit frames are rounded to 8-bit.

Any failure (no video processor, import refused, a GPU error) and interlaced
frames switch the session to copy-back (`LEPTON_VA_DIRECT fallback=`). Nothing
outside the service changes: SurfaceFlinger, gralloc and minigbm get the
buffers they already get with copy-back.

This is not the old zero-copy experiment. Zero-copy had the GPU *decode* into
linear gralloc buffers: iHD produced wrong pictures, i965 refused the imports and
AMD needed NV12 buffers SurfaceFlinger could not display. Direct output decodes
into the driver's own surfaces and only *writes* the final YV12 into Android's
buffer, a linear format both drivers render to and SurfaceFlinger displays.

**Cost by GPU.** On Intel Gen 9 the conversion to a planar format runs on the
render engine (shaders), about 4 ms per 4K frame on the host and 9 ms in Android
under SurfaceFlinger's load. On the RX 6700 XT it takes about 1 ms.

## What has been tested

Machines (results are from these two only):
- Intel UHD 630 (Gen 9.5): iHD 24.3.4, with i965 also installed;
- AMD RX 6700 XT (navi22): Mesa 26.0.8 radeonsi; host CPU i7-8700.

Bundles:
- `video-vaapi-test-16` (`f15ed14`): both machines;
- `-19`, `-20`, `-21` (`a9ea4d7`, before the copy-back work): AMD;
- `-23` (`53b4370`, patches 0028/0029): AMD; Intel (copy-back, 4K60 below);
- `-25` (`94fdcbb`, patch 0030): both machines and the Steam Deck (direct
  output, below). `-24` was the first direct-output build; it is superseded
  (washed-out colour on Mesa, fixed in `-25`);
- `-26` (`f6e768f`, the release state: direct output by default, `vpp` removed,
  safe handle checks): both machines (regression, below).

### Correctness (media probe, headless)

| Clip (probe) | Intel UHD 630 (test-16) | AMD RX 6700 XT (test-23) |
| --- | --- | --- |
| H.264 High 720p and 1080p | VA-API; identical to Android's decoder | same |
| Repeat ×3, flush and seek | identical | identical |
| HEVC Main | VA-API; identical | VA-API; identical |
| HEVC Main10 720p, 1080p, 4K | VA-API (P010); not compared | VA-API (P010); identical to host FFmpeg (see below) |
| VP9 Profile 0 720p | VA-API; identical | VA-API; identical |
| VP9 Profile 0 4K | not tested | VA-API; identical to host FFmpeg |
| H.264, HEVC Main, AV1 4K | not tested | VA-API; identical to Android's decoder |
| AV1 | not offered (iHD reports no AV1 on Gen 9.5); Android's `c2.android.av1.decoder` used | VA-API; identical |
| H.264, 640×360 → 1280×720 mid-stream | VA-API; **one frame lost at the switch**, all others identical | same |
| H.264 High 4:4:4 | FFmpeg software inside the service (no VA driver decodes 4:4:4), logged as such | same |
| Surface output (ImageReader) | every frame delivered | same |
| Hardware decoding off | Android's decoders, unchanged | same |

"Identical" means the CRC of the visible luma of every frame equals Android's
software decoder's. H.264, HEVC, VP9 and AV1 decoding is bit-exact.

The 10-bit and VP9 4K clips have no Android reference:
- Android has no HEVC Main10 software decoder;
- Android's VP9 decoder does not take 4K.

For these, the luma CRCs from test-23 were compared by hand with host FFmpeg
decoding the same files and converting to 8-bit with swscale. All 60 frames of
every clip were identical. The same CRCs were produced before and after patch
0029 (test-21 and test-23), so the faster path changed no pixels.

**Evidence of GPU decoding.** Only the FFmpeg service had DRM video-engine time:
- test-16: 0.5 s on Intel and 14.7 s on AMD during a probe run;
- test-23: 45.9 s on AMD.

With hardware decoding off, no process used the video engine. In test-23:
- 46 sessions used `derive` (`LEPTON_VA_COPYBACK`), with 0 transfer failures;
- the 4:4:4 clip fell back to software;
- with hardware decoding off, there were no VA lines, no service CPU time, and
  audio was unchanged.

### Performance: before and after (AMD, test-21 → test-23)

The probe's throughput run decodes each clip (2 s, 60 frames) as fast as
possible, with no CRCs (`LEPTON_MEDIA_THROUGHPUT`, frames/s):

| Clip | ByteBuffer before | ByteBuffer after | Surface before | Surface after |
| --- | --- | --- | --- | --- |
| H.264 1080p | 110 | 198 | 107 | 230 |
| HEVC Main10 1080p | 59 | 152 | 78 | 113 |
| H.264 4K | 39 | 65 | 41 | 76 |
| HEVC Main 4K | 39 | 64 | 40 | 77 |
| HEVC Main10 4K | 22 | 47 | 22 | 54 |
| VP9 4K | 36 | 59 | 36 | 62 |
| AV1 4K | 32 | 50 | 34 | 56 |

The service's time per frame (`LEPTON_VA_TIMING`, ms; `sync` is part of
`download` before 0029):

| Clip | Step | send | receive | sync | download | map | convert | whole frame |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| HEVC Main 4K | before | 4.6 | 0.8 | – | 15.2 | 1.2 | 2.0 | 24.3 |
| | after | 4.7 | 0.2 | 1.8 | 2.2 | 1.2 | 2.4 | 13.0 |
| HEVC Main10 4K | before | 4.5 | 1.6 | – | 27.7 | 1.3 | 8.9 | 44.4 |
| | after | 4.7 | 0.4 | 1.8 | 3.9 | 1.2 | 5.9 | 18.5 |
| H.264 1080p | before | 1.7 | 0.2 | – | 2.7 | 0.5 | 0.5 | 6.1 |
| | after | 1.6 | 0.1 | 0.2 | 0.8 | 0.4 | 0.6 | 4.2 |

**Bottleneck before:** the CPU read-back, not the GPU. FFmpeg's read map makes
Mesa allocate a new image (12–25 MB at 4K) for every frame and copy the surface
into it on one thread. The wait for the GPU (`sync`) was only 1–2 ms (5–8 ms for
VP9 and AV1 at 4K).

**After:** at 4K the largest costs are:
- submitting the decode (`send`, 2–6 ms; FFmpeg's bitstream parsing and VA
  submission);
- the 10-bit conversion (about 6 ms on 2 threads).

Experiments (test-22, not shipped):

| Change | Result |
| --- | --- |
| Persistent VA image + `vaGetImage` | 10–20% faster than `map` |
| 3 conversion threads | about the same as 2 |
| 4 or more conversion threads | slower than 2 |
| Threads for 8-bit conversion | no gain |

### Direct output and 4K60 (VLC, test-23 to -26)

The same clip throughout: `meridian_2160p5994_main10_sdr709.mkv`, HEVC Main10,
3840×2160, 59.94 fps (16.68 ms per frame), limited-range BT.709 SDR, 60 s,
3,597 frames, no audio. VLC 3.x (`org.videolan.vlc` 13070208), native
resolution, played through to the end.

| Machine | Output | Delivered | VLC late pictures | Service work per frame |
| --- | --- | --- | --- | --- |
| Intel UHD 630 (desktop) | copy-back | 20.4 fps | 2,248 | 49 ms: map 30.6, gralloc map 8.0, convert 4.5, decode wait 3.6 |
| Intel UHD 630 | GPU conversion + copy-back (removed) | 25.2 fps | 2,880 | 40 ms: NV12 map 21.6, gralloc map 7.2 |
| Intel UHD 630 | **direct** | **60.1 fps** | **0** | decode wait 3.4, GPU conversion 9.0, submit 0.3 |
| RX 6700 XT (headless) | copy-back | 42.0 fps | 3,588 | 23.7 ms |
| RX 6700 XT | GPU conversion + copy-back (removed) | 59.7 fps | 469 (start-up) | about 14 ms of work |
| RX 6700 XT | **direct** | **60.1 fps** | **0** | decode wait 5.5, GPU conversion 1.1, submit 0.2 |
| Steam Deck | copy-back / GPU conversion + copy-back (earlier) | – | falls behind | about 24 / 19 ms per frame |
| Steam Deck (test-25, two runs) | **direct** | 56.4 and **60.1 fps** | not captured | decode wait 7.6, GPU conversion 3.4, submit 1.4 |

With direct output, every one of the 3,597 frames was converted on the GPU
(`LEPTON_VA_DIRECT_END frames=3597 copyback_frames=0 fallback=0`), with no
readback, map or CPU conversion (`download=0 map=0 convert=0`). SurfaceFlinger
recorded the video layer at its 60 Hz cadence with 0 dropped frames. The
service's CPU time on Intel fell from 93 s (copy-back) to 7 s for the clip.
The rest of each 16.7 ms is spent waiting for VLC's output queue, which is the
headroom left.

On the Intel host, outside Android, the UHD 630 decodes this clip at about 340
fps, so the decoder itself was never the limit; the CPU round trip was.

**Steam Deck.** Both runs converted all 3,597 frames directly
(`copyback_frames=0 fallback=0`, no transfer failures), and the second
delivered 60.1 fps; the first run's 56.4 fps includes player start-up in its
time window. Playback on the Deck's screen was smooth. About 12.5 ms of each
16.68 ms frame is work (mostly waiting for the Deck's video decoder); the rest
is waiting for VLC's queue, which is the headroom. `LEPTON_VA_DEADLINE` counted
about 1,200 `process` calls over 16.68 ms per run: those calls include waits
for the app's output queue and are not dropped frames. VLC's late-picture count
and SurfaceFlinger's displayed-frame totals were not captured on the Deck, so
displayed frames there are not independently verified.

The service's `fps` is the rate at which it delivered frames to the app. On
Intel and AMD, VLC's own count of late pictures and SurfaceFlinger's frame
statistics were also recorded (the table); on the Deck only the service's
numbers and the visual check are available.

Also with direct output on Intel:
- 1080p H.264, HEVC Main, VP9 (30 fps) and HEVC Main10 (60 fps) at full rate
  with 0 late pictures;
- seeking (arrow keys, 5–8 seeks) flushed and recovered with 0 late pictures and
  no fallback;
- through the launcher option alone (test-25, `LEPTON_VIDEO_HWACCEL_OUTPUT=direct`),
  all 3,597 frames direct.

**Pixels.** With `direct-validation=pixels` the service reads two output buffers
of each session back on the CPU and compares them with the decoded surface
(`LEPTON_VA_DIRECT_PIXELS`):
- **Intel iHD 24.3.4:** identical, every plane, for 8-bit and 10-bit sessions at
  720p, 1080p and 4K (10-bit compared with nearest rounding). The media probe's
  CRCs also match Android's decoders for H.264, HEVC Main and VP9 at 1080p and
  4K, and for repeat and seek.
- **AMD, Mesa 26.0.8 (the image's Mesa):** not bit-exact. About a third of luma
  samples are one code high (mean +0.5), with peaks of 16–17 codes next to sharp
  chroma edges; V is about one code high. Mesa 26.0 converts YUV to YUV through
  RGB, so chroma interpolation leaks into luma at edges. Natural video looks
  the same as copy-back. Mesa 26.2.7 on the host converts exactly, so a newer Mesa in the
  image should make it bit-exact (not done: it is a shared graphics change).

The probe's occasional HEVC "mismatches" on Intel (one to four frames) were
traced to Android's reference decoder: the differing reference frames all
carried one identical CRC, while the direct output's CRCs were the same in
every run.

**Lifecycle (direct).** Six VLC sessions and repeated probe runs (each about 25
decoder sessions): the service stayed at 13 open files with Surface output; with
ByteBuffer output, after the import fix, it levels at about 145 DMA-BUF handles
(Codec2's buffer cache) whatever the number of runs, at about 55 MB resident.

### Release regression (test-26)

test-26 is the release state (`f6e768f`). Launch options only, no properties
set by hand:

| Check | Intel UHD 630 | RX 6700 XT |
| --- | --- | --- |
| Hardware decoding off: probe, audio, rendering | Android's `c2.android.*` decoders, no service activity, audio and video smoke pass; ANGLE on Vulkan/ANV | – |
| `LEPTON_VIDEO_HWACCEL=true` only | `output direct`; 39 probe sessions direct, 0 copy-back frames, 0 fallbacks | `output direct`; 45 sessions, 0 copy-back frames, 0 fallbacks |
| Probe CRCs, direct | H.264 1080p/4K, VP9, repeat, seek: identical; HEVC: single-frame reference glitches only | within about one code (Mesa 26.0.8, see "Pixels") |
| `..._OUTPUT=copyback` | `output copy-back`; CRCs as before | `output copy-back`; identical to Android's decoders |
| H.264 High 4:4:4 | FFmpeg software inside the service, logged | same |
| VLC 4K59.94 Main10, default | 60.1 fps, 3,597 frames, 0 late, 0 SurfaceFlinger drops | – |
| VLC seeks (8), flushes (6) | 0 late, no fallback | – |
| VLC 1080p H.264, VP9 | 30 fps, 0 late | – |
| Forced fallback (`direct-validation=fallback`) | 3 frames direct, then 2,281 by copy-back, 0 transfer failures, session ended normally | – |
| Service after the sessions | same process, 13 open files, 0 DMA-BUF handles, about 48 MB | – |

One of two hardware-off probe runs on Intel ended with the probe app itself
crashing (in `MediaExtractor.readSampleData`, after Android's own HEVC decoder
rejected a 4K clip); the rerun passed. The service is not involved when
hardware decoding is off.

### Real app: VLC

VLC 3.x (`org.videolan.vlc` 13070208) was used on the desktop with
`run-apk.sh --app --display desktop --video-hwaccel`. Clips were opened by
intent from `/data/local/tmp`.

| Bundle | Clip | VLC decoder | Service | Picture (user) |
| --- | --- | --- | --- | --- |
| Intel test-17 | H.264, HEVC 8-bit, VP9 | `c2.ffmpeg.*` | VA-API | played |
| Intel test-17 | HEVC 10-bit | VLC software (before patch 0025) | – | – |
| AMD test-19 | H.264 High 1080p | `c2.ffmpeg.h264.decoder` | vaapi, 1446 hw / 0 sw frames | good |
| AMD test-19 | HEVC Main 1080p | `c2.ffmpeg.hevc.decoder` | vaapi, 1235 hw / 0 sw | good |
| AMD test-19 | VP9 Profile 0 1080p | `c2.ffmpeg.vp9.decoder` | vaapi, 720 hw / 0 sw | fine |
| AMD test-19 | AV1 10-bit 1080p | VLC's dav1d | not used | not judged |
| AMD test-23 | HEVC Main10 1080p 60 fps | `c2.ffmpeg.hevc.decoder` | vaapi, `derive`, 1797 hw / 0 sw | good |
| AMD test-23 | HEVC Main10 4K 59.94 fps HDR10, clean MP4 | `c2.ffmpeg.hevc.decoder` | vaapi, `derive`, 2860 hw / 0 sw, 46.7 fps (20.5 ms per frame) | **black**: every frame late, so VLC drops it |
| AMD test-23 | HEVC Main10 4K 59.94 fps HDR10, damaged MPEG-TS | `c2.ffmpeg.hevc.decoder` | vaapi, 2866 hw / 0 sw | one still frame (VLC's clock; see "Known issues") |
| AMD test-20 | HEVC Main10 8K 24 fps HLG | `c2.ffmpeg.hevc.decoder` | vaapi, about 6 fps (before 0029) | froze |

In every session above, all frames came from the GPU with 0 transfer failures.
Only the FFmpeg service had video-engine time.

VLC never uses MediaCodec for AV1, in 3.0.x or master: its `mediacodec.c` has no
AV1 entry. GPU AV1 has only been tested with the probe.

### Lifecycle (AMD, test-23)

The probe was run 10 times in one instance, about 140 decoder sessions,
alternating `derive` and `map`. After each pass the service's resident memory
was 41.6 MB (±60 kB), with 19 threads and 18–22 open files. No leak was seen:
- VA surfaces are released;
- conversion threads exit;
- buffers are freed when sessions end.

Seek, flush and repeat sessions matched the reference.

### Not verified

- newer Intel GPUs (Ice Lake and later; Xe GPUs on the `xe` kernel driver), and
  i965 with direct output;
- on the Steam Deck: VLC's late-picture count and SurfaceFlinger's displayed
  frames with direct output (only the service's numbers and the on-screen
  check were collected), and clips other than the 4K59.94 Main10 one;
- other AMD generations;
- VP8, MPEG-2 and VC-1 content; VP9 Profile 2 and AV1 10-bit content;
- real apps other than VLC (ExoPlayer-based players, games), and AV1 in a real
  app;
- full-rate 4K60 with copy-back (not reached on any tested machine; see "Known
  issues"); direct output under heavy GPU load (a game running alongside);
- HDR output (not supported);
- long playback (beyond about 2 minutes).

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
- the output path, from `LEPTON_VIDEO_HWACCEL_OUTPUT`:

| `LEPTON_VIDEO_HWACCEL_OUTPUT` | `hwaccel.drm` | `pixel_format` |
| --- | --- | --- |
| `direct` (default) | `true` | `YUV_420_PLANER` |
| `copyback` | `false` | `YUV_420` |

`direct` is used only when the image's service has it (patch 0030); older
images get `copyback`, with a log line. Any other value also gives `copyback`,
with a log line. The launcher's line ends with the path in use, for example
`... using /dev/dri/renderD128; output direct`. Even with `direct`, the service
switches a session to copy-back by itself if direct output fails (see "Direct
output").

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

**Tuning properties (patch 0029)** are for diagnosis. They are read when a
decoder opens, so set them before starting playback:

| Property | Values | Default |
| --- | --- | --- |
| `debug.ffmpeg-codec2.copyback` | `auto`, `map`, `derive` | `auto`: `derive` on Mesa, `map` otherwise |
| `debug.ffmpeg-codec2.convert-threads` | `0` (auto) to `8` | `0`: 2 threads for 10-bit at 1080p and above, otherwise 1 |

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

**Size limits (patches 0026/0027).** When hardware decoding is on and VA decodes
the codec, the service queries each VA profile's largest surface
(`VASurfaceAttribMaxWidth`/`MaxHeight`) and uses it as the picture-size range.
Otherwise it uses 4080×4080, as before. When that size is beyond level 5.x,
level 6 is also listed. Levels 6.1 and 6.2 are not listed, because VA reports no
frame rate.

On AMD (test-20), `LEPTON_VA_CAPS max=` reported:
- 8192×4352 for HEVC, HEVC 10-bit, VP9 and AV1;
- 4096×4096 for H.264;
- 1920×1088 for MPEG-2.

For a 7680×4320 24 fps stream, `findDecoderForFormat` picks `c2.ffmpeg.hevc`,
`.vp9` and `.av1.decoder`. Being listed for 8K does not mean 8K plays at full
rate.

Android takes codec limits from the static `media_codecs` XML only. Patch 0027
(`frameworks/av`, `Codec2InfoBuilder`) replaces the XML `size-range` of
`c2.ffmpeg.*` video decoders with the component's range. It scales
`block-count-range` and `blocks-per-second-range` by the same factor, keeping
the XML's frame rate at the largest size. Logged as `LEPTON_CODEC_LIMITS`.
Other codecs keep their XML limits.

## Diagnostics

The service logs to logcat:

| Line | Meaning |
| --- | --- |
| `LEPTON_VA_CAPS` | once per service start: VA driver, render node, decodable codecs and profiles, largest sizes |
| `LEPTON_VA_SESSION codec= profile= size= decode=vaapi\|software [reason=] sw_format= zero_copy= output=` | once per decoder session, at its first frame; `output=direct\|copy-back\|software` |
| `LEPTON_VA_DIRECT input= output= picture= buffer=` | direct output: first converted frame of a session |
| `LEPTON_VA_DIRECT fallback=` | direct output failed; the rest of the session uses copy-back |
| `LEPTON_VA_DIRECT_END frames= copyback_frames= fallback= submit_us= gpu_wait_us=` | direct output, when the session ends. `copyback_frames` must be 0 for a fully direct session |
| `LEPTON_VA_SLOW`, `LEPTON_VA_PERCENTILES`, `LEPTON_VA_DEADLINE` | when the session ends: slowest `process` call, p95/p99 per step (0.5 ms bins), calls over 16.68 ms. `process` includes waits for the app's output queue, so long calls are not dropped frames |
| `LEPTON_VA_DIRECT_PIXELS` / `LEPTON_VA_DIRECT_TEST` | only with `setprop debug.ffmpeg-codec2.direct-validation pixels` (compare two output buffers per session with the decoded surface) or `fallback` (fail the fourth frame to exercise the fallback), set before playback |
| `LEPTON_VA_COPYBACK mode= setting= vendor=` | once per hardware session: the copy-back mode chosen (patch 0029); `derive failed` if it fell back |
| `LEPTON_VA_SESSION_END codec= hw_frames= sw_frames= transfer_failures=` | when the session ends |
| `LEPTON_VA_TIMING codec= size= frames= fps= copyback= convert_threads= us_per_frame: send= receive= sync= download= fetch= map= convert= process=` | when the session ends: average microseconds per frame for each step (patch 0028). `fps` is the output rate, which includes time the app paused |

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

For a full-rate target, `process` must stay below the frame interval: 16.7 ms for
60 fps, 33 ms for 30 fps.

## Testing on your machines

### With the test tools (a development host)

```bash
# Media probe APK (on a host with the AOSP checkout and ffmpeg)
bash tests/runtime/build-jni-smoke.sh --aosp <aosp> --abi x86_64 --media-smoke --output probe.apk

# Probe with hardware decoding, with the GPU video-engine sampler alongside
bash tests/runtime/sample-video-engine.sh /tmp/video.log & s=$!
bash tests/runtime/run-apk.sh --stage-dir <stage> --apk probe.apk --expect-abi x86_64 \
    --media-smoke --rendering intel|amd --display headless --seconds 300 --video-hwaccel --execute
kill $s; bash tests/runtime/sample-video-engine.sh --summary /tmp/video.log

# Results (the run prints the retained log directory)
grep -ah 'LEPTON_VA_CAPS' <dir>/boot-logcat.log
grep -aoE 'LEPTON_MEDIA_(CODEC|REPEAT|SEEK|THROUGHPUT) .*|LEPTON_VA_(SESSION|COPYBACK|TIMING).*' <dir>/app-logcat.log
```

Run the probe again without `--video-hwaccel` for the software baseline: every
decoder is `c2.android.*`, and there is no video-engine time.

Expected with hardware decoding:
- `LEPTON_MEDIA_CODEC ... result=PASS` for the 8-bit clips the GPU decodes,
  and `NOT_COMPARED` or `NO_REFERENCE` for 10-bit and VP9 4K;
- `LEPTON_VA_SESSION ... decode=vaapi` for them;
- `LEPTON_VA_COPYBACK mode=derive` on AMD and `mode=map` on Intel;
- video-engine time only for `android.hardware.media.c2-ffmpeg-service`.

`LEPTON_MEDIA_CODEC` results:
- `PASS`: every frame identical to Android's decoder, and Surface output works;
- `MISMATCH`: lists the differing frame numbers, plus `LEPTON_MEDIA_CODEC_CRCS`
  with both CRC lists;
- `INCOMPLETE`: no output for 10 s;
- `UNSUPPORTED`: no decoder;
- `NO_REFERENCE`: Android cannot decode the clip. The CRCs are still listed,
  for comparison with host FFmpeg;
- `NOT_COMPARED`: 10-bit output;
- `SURFACE_FAIL`.

Throughput only: start the probe with the intent extra `lepton.throughput`. It
skips the other tests and ends with `LEPTON_MEDIA_THROUGHPUT_DONE`:

```bash
am start --activity-clear-task -n org.lepton.smoke/.MainActivity --ez lepton.throughput true
```

**Intel, comparing copy-back modes.** Intel defaults to `map`. To measure
`derive` (which may be slower on iHD, or faster), set the property in the
instance, rerun the throughput test, and compare the `LEPTON_VA_TIMING`
`download` values and the CRCs with a `map` run:

```bash
setprop debug.ffmpeg-codec2.copyback derive    # then map, then auto
```

### On a Steam Deck or another desktop

1. Add `LEPTON_VIDEO_HWACCEL=true %command%` to the app's Steam launch options
   (direct output). To compare with copy-back, use
   `LEPTON_VIDEO_HWACCEL=true LEPTON_VIDEO_HWACCEL_OUTPUT=copyback %command%`.
2. Play a 1080p H.264 or HEVC video in the app, then a 4K one, to the end.
3. Collect the service and player lines from another terminal. The `lepton`
   command is inside the install, for example
   `~/.local/share/lepton_x86_64_<id>/compat_tool/lepton`; `lepton ps` lists
   instances:
   ```bash
   lepton logcat <instance_or_application_name> --full -d | grep -aE 'LEPTON_VA_|too late to be displayed'
   ```
   A clip can be copied into the instance and opened in the app with:
   ```bash
   lepton exec <instance> sh -c 'cat > /data/local/tmp/v.mkv && chmod 644 /data/local/tmp/v.mkv' < video.mkv
   lepton exec <instance> am start -a android.intent.action.VIEW -d file:///data/local/tmp/v.mkv -t 'video/*' -p <package>
   ```
4. Check for:
   - `decode=vaapi` and `output=direct` in `LEPTON_VA_SESSION`;
   - `LEPTON_VA_DIRECT_END ... copyback_frames=0 fallback=0`;
   - `LEPTON_VA_TIMING ... fps=` close to the video's rate, and few or no
     "too late" lines from VLC;
   - natural colour, no stripes or green/pink cast, smooth motion.
5. Remove the launch options and play the same video: the `LEPTON_VA` lines
   should be absent (Android's decoders).

## Zero-copy (removed)

`LEPTON_VIDEO_HWACCEL_ZEROCOPY` is gone. It had the GPU decode straight into
Android's buffers (the service's DRM PRIME mode with NV12): i965 refused every
import, iHD decoded wrong pictures into linear buffers, and on AMD
SurfaceFlinger aborted on the NV12 buffers (which also needed a minigbm layout
change, the former `experimental/0022`). Direct output keeps decoding in the
driver's own surfaces and gets the same benefit for display. Patch 0021 (buffer
identity without a BufferQueue) is now used by direct output's ByteBuffer path.

## Future work

GPU conversion into Android buffers, which this section used to propose, is
now direct output (patch 0030). What remains:

- **Bit-exact direct output on AMD:** Mesa 26.2 converts YUV to YUV exactly;
  the image's Mesa 26.0.8 goes through RGB (see "Pixels"). Updating Mesa is a
  shared graphics change, to be weighed on its own.
- **Hardware decoding on by default**, once more GPUs, apps and longer sessions
  have been tried.

**HDR output.** HEVC Main10 has no software decoder in this image. With hardware
decoding it is converted to 8-bit (YV12) and shown as SDR, with no tone mapping
(on every output path).
HDR10 (PQ) content therefore looks too bright and washed out, and HLG looks
flat. HDR10 and HDR10+ are not listed. HDR end to end is a separate project,
needing all of:
- P010 or another 10-bit output format SurfaceFlinger can display;
- HDR profiles and metadata in Codec2;
- an HDR dataspace through SurfaceFlinger;
- 10-bit PQ through Lepton's display bridge.

## Patches

| Patch | Project | Purpose |
| --- | --- | --- |
| 0017 | `external/ffmpeg` | x86_64 build without Vulkan: Android 14's Vulkan headers are too old |
| 0018 | `external/stagefright-plugins` | drop the "raw codec data" parameter, which only exists in WayDroid's `frameworks/av` |
| 0019 | `external/mesa` | VA-API in Mesa's Android build; accept libva-android's display |
| 0020 | `external/intel-media-driver` | build iHD with Android 14's clang |
| 0021 | `external/stagefright-plugins` | buffer identity without a BufferQueue (direct output to ByteBuffers), with a size and magic check before minigbm handle fields are read; import logging |
| 0023 | `external/stagefright-plugins` | copy-back in the surface's own format (bit-exact on Mesa) |
| 0024 | `external/stagefright-plugins` | VA capability query and gating; session diagnostics |
| 0025 | `external/stagefright-plugins` | list HEVC Main10 when VA decodes `HEVC10` |
| 0026 | `external/stagefright-plugins` | picture-size range (and level 6) from VA's largest surface |
| 0027 | `frameworks/av` | `c2.ffmpeg.*` video decoders' listed size limits from the component, not the XML |
| 0028 | `external/stagefright-plugins` | time each copy-back step (`LEPTON_VA_TIMING`) |
| 0029 | `external/stagefright-plugins` | faster copy-back: derived VA mapping on Mesa, threaded 10-bit conversion (`LEPTON_VA_COPYBACK`) |
| 0030 | `external/stagefright-plugins` | direct output (GPU converts into Android's buffer) with copy-back fallback; deadline diagnostics; `direct-validation` test switch |

**Why 0023:** asking Mesa's `vaGetImage` for a format other than the surface's
(YUV420P from NV12) converts through its video compositor and changes every
pixel. The service now downloads in the surface's software format (NV12, or
P010 for 10-bit), and its swscale step converts to YV12 without changing luma.

**Review notes (0017–0027).** None of these block the release:
- **0021:** fixed: minigbm handle fields are read only after checking that the
  handle has an fd and is large enough for `cros_gralloc_handle`, and that the
  magic number matches. Other handles are refused by the import, and direct
  output falls back to copy-back.
- **0024–0026:** the HEVC profile list is gated on VA, but VP9 Profile 2 and AV1
  Profile 1 are listed as upstream had them, whatever VA reports. A stream the
  GPU cannot decode (AV1 4:4:4, or VP9 10-bit without `VP92`) is decoded by
  FFmpeg in software and logged as `decode=software`.
- **0026:** includes `<map>` only through other headers.

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
630 (test-16, before patch 0029), iHD copy-back was slower than i965: about
126/183 frames/s against 165/328 at 720p (buffers/Surface).

## Known issues

- **4K60 needs direct output.** With copy-back, 4K59.94 10-bit runs below full
  rate on every tested machine (UHD 630 about 20 fps, RX 6700 XT about 42 fps,
  Steam Deck about 24 ms per frame), and VLC drops the late pictures. Direct
  output reached full rate on all three, but 4K60 is not guaranteed on other
  hardware, with other apps, or while a game loads the GPU: on the Steam Deck
  about 4 ms of each 16.7 ms frame is spare. 8K is listed but far below full
  rate.
- **Direct output on AMD is not bit-exact** (Mesa 26.0.8; see "Pixels"): within
  about one code on average, more next to sharp chroma edges.
- **Direct output on Intel Gen 9 uses the render engine** for the conversion
  (about 9 ms per 4K frame in Android). It shares the GPU with the game or app
  being drawn; under heavy rendering load 4K60 may fall behind.
- **Resolution change:** one frame is lost where an H.264 stream changes
  resolution mid-stream (both GPUs). All other frames are identical. FFmpeg
  decodes every frame. The last frame before the switch is lost where the
  service pairs output frames with Android's work items (`unknown frame index`
  in the log). This predates the copy-back work, which does not change it. Not
  fixed for this release.
- **HDR shown as SDR:** see "Future work". PQ content looks too bright.
- **Android's own software decoders:** comparing a `c2.android.*` decoder with
  itself sometimes gives one or a few differing frames, under heavy host load or
  on Intel. This is in Android's software path, not VA-API; not investigated.
- **VLC and damaged files:** an MPEG-TS file named `.mkv`, whose audio track
  has no timestamps, broke VLC's clock. VLC showed one still frame ("picture way
  too early"), and stopping it deadlocked VLC's own threads (`input_Close` and
  `vlc_join`, with the MediaCodec thread waiting on a VLC mutex). The service
  had decoded all 2866 frames and was idle. The same video remuxed into a clean
  MP4 had no clock problem. This matches the earlier "VLC hang after a 4K
  clip". It is in VLC, not the decoder.
- **VLC does not release the decoder on Back:** VLC keeps the session open in
  the background. With `run-apk.sh --app --until-exit`, closing VLC's window
  does not end the session either. To end it, run `am force-stop
  org.videolan.vlc` in the instance.
- **Headless test instances:** an Ethernet `IpClient` retry loop keeps `logd`
  busy (about 70% of a CPU) and adds noise to timings. It is unrelated to media.
  Use several runs and take medians.
