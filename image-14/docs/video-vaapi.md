# Hardware video decoding (VA-API)

Android 14 in Lepton decodes video with Android's software Codec2 decoders
(`c2.android.*`). This adds a vendor Codec2 service that decodes with FFmpeg and,
when enabled, uses the GPU's video engine through VA-API. It is built into the
image and **off by default** (`LEPTON_VIDEO_HWACCEL=true` turns it on).

What ships is **hardware decoding with copy-back**. The release does not include
GPU video post-processing (VPP), zero-copy output or HDR output.

## How it works

```
app (MediaCodec) → Codec2 → c2.ffmpeg.* (FFmpeg service) → FFmpeg hwaccel → VA-API driver → GPU video engine
                                   │
                                   └─ copy-back: VA surface → CPU (map) → swscale → Android buffer (YV12)
```

| Term | Meaning | In this release |
| --- | --- | --- |
| Hardware decoding | The GPU's video engine decodes the bitstream into VA surfaces in GPU memory | yes |
| Copy-back | Each decoded surface is mapped for the CPU and copied, converted to 8-bit YV12, into an ordinary Android buffer (ByteBuffer or Surface) | yes |
| GPU VPP | The GPU converts or scales (for example P010 to NV12, or straight into the Android buffer's format) through VA's video processing | no (future work) |
| Zero-copy | The GPU decodes straight into Android's own (gralloc/DMA-BUF) buffers, with no CPU copy | no: a broken development option, see "Zero-copy" |

Each frame, the service:
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

## What has been tested

Machines (results are from these two only):
- Intel UHD 630 (Gen 9.5): iHD 24.3.4, with i965 also installed;
- AMD RX 6700 XT (navi22): Mesa 26.0.8 radeonsi; host CPU i7-8700.

Bundles:
- `video-vaapi-test-16` (`f15ed14`): both machines;
- `-19`, `-20`, `-21` (`a9ea4d7`, before the copy-back work): AMD;
- `-23` (`53b4370`, patches 0028/0029): AMD.

**Intel has not been tested with patch 0029.** It is expected to behave as
before (the `map` mode plus threaded 10-bit conversion), but that is not
measured. See "Testing on your machines".

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

- Intel with patch 0029, and newer Intel GPUs (Ice Lake and later; Xe GPUs on
  the `xe` kernel driver);
- Steam Deck (AMD Van Gogh, radeonsi): expected to use `derive` like the RX
  6700 XT, but not run;
- other AMD generations;
- VP8, MPEG-2 and VC-1 content; VP9 Profile 2 and AV1 10-bit content;
- real apps other than VLC (ExoPlayer-based players, games), and AV1 in a real
  app;
- full-rate 4K60 10-bit (about 47 fps in VLC; see "Known issues");
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
| `LEPTON_VA_SESSION codec= profile= size= decode=vaapi\|software [reason=] sw_format= zero_copy=` | once per decoder session, at its first frame |
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

1. Add `LEPTON_VIDEO_HWACCEL=true %command%` to the game's Steam launch options.
2. Play a 1080p H.264 or HEVC video in the app, then a 4K one.
3. Collect the service lines from another terminal:
   ```bash
   lepton logcat <instance_or_application_name> --full | grep -E 'LEPTON_VA_(CAPS|SESSION|COPYBACK|TIMING)'
   ```
4. Check for:
   - `decode=vaapi`;
   - `transfer_failures=0`;
   - a `process` value below the video's frame interval.
5. Remove the launch option and play the same video: the `LEPTON_VA` lines
   should be absent (Android's decoders).

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

## Future work

Copy-back costs CPU time and memory bandwidth for every frame. Two approaches
would remove part or all of it. Neither is started.

**1. GPU VPP into Android buffers.**
- *How:* the service allocates the Android output buffer as before (YV12, a
  format SurfaceFlinger already displays), imports it as a VA surface, and asks
  the driver's video processor (`vaCreateContext` on `VAProfileNone` /
  `VAEntrypointVideoProc`, or FFmpeg's `scale_vaapi`) to convert the decoded
  surface into it on the GPU.
- *What it removes:* the CPU map and the swscale conversion (at 4K 10-bit,
  about 11 ms of the 18.5 ms per frame).
- *Problems to solve:*
  - Mesa's compositor changed luma values when it converted formats (the reason
    for patch 0023), so its output must be checked against the CRCs, or accepted
    as not bit-exact;
  - the import has the same gralloc layout problems as zero-copy (pitches and
    modifiers), but on a format that already displays;
  - Intel iHD's VPP must be checked separately.

**2. DMA-BUF / gralloc zero-copy.**
- *How:* the GPU decodes straight into Android's buffers (NV12, or P010 for
  10-bit) and SurfaceFlinger displays them.
- *What it removes:* every copy.
- *Problems to solve:* everything listed under "Zero-copy":
  - NV12 import in Mesa/RADV for Android hardware buffers, like patch 0002 does
    for YV12;
  - an allocation path for video buffers that does not change every NV12
    buffer's layout;
  - iHD's broken imports;
  - buffer reuse and generation in patch 0021.

  It is also the only route to HDR.

**HDR output.** HEVC Main10 has no software decoder in this image. With hardware
decoding it is converted to 8-bit (YV12) and shown as SDR, with no tone mapping.
HDR10 (PQ) content therefore looks too bright and washed out, and HLG looks
flat. HDR10 and HDR10+ are not listed. HDR end to end is a separate project,
needing all of:
- P010 output (zero-copy or VPP);
- HDR profiles and metadata in Codec2;
- an HDR dataspace through SurfaceFlinger;
- 10-bit PQ through Lepton's display bridge.

**4K60 10-bit with copy-back.** These might close the remaining gap (about 47
against 60 fps), and are untried:
- a dedicated P010 to 8-bit loop in place of swscale's general path (estimated
  2–3 ms against 6 ms). It must be checked against the 10-bit CRCs, since its
  rounding may differ;
- overlapping the conversion of one frame with the decode of the next (a worker
  thread). This needs care with buffer ownership on flush, seek and resolution
  change.

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
| 0026 | `external/stagefright-plugins` | picture-size range (and level 6) from VA's largest surface |
| 0027 | `frameworks/av` | `c2.ffmpeg.*` video decoders' listed size limits from the component, not the XML |
| 0028 | `external/stagefright-plugins` | time each copy-back step (`LEPTON_VA_TIMING`) |
| 0029 | `external/stagefright-plugins` | faster copy-back: derived VA mapping on Mesa, threaded 10-bit conversion (`LEPTON_VA_COPYBACK`) |
| experimental/0022 | `external/minigbm` | zero-copy NV12 layout; not applied |

**Why 0023:** asking Mesa's `vaGetImage` for a format other than the surface's
(YUV420P from NV12) converts through its video compositor and changes every
pixel. The service now downloads in the surface's software format (NV12, or
P010 for 10-bit), and its swscale step converts to YV12 without changing luma.

**Review notes (0017–0027).** None of these block the release:
- **0021:** reads minigbm's handle `magic` without first checking that the
  handle is large enough. It only runs in zero-copy mode, and Lepton's gralloc is
  minigbm; check `numInts` before any wider use.
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

- **4K60 10-bit is below full rate.** On the RX 6700 XT, real 4K 59.94 fps
  HEVC Main10 content runs at about 47 fps (20.5 ms per frame), so VLC drops
  every late frame and shows black. 4K30 and 1080p60 10-bit have headroom; 8-bit
  4K reaches 64–77 fps in the probe. 8K is listed but far below full rate. See
  "Future work".
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
