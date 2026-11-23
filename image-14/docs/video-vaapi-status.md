# Hardware video decoding (VA-API): status

Status on 2026-11-23 for branch `feature/video-vaapi` at `20d9a4b`. The branch
started from `main` at `39d77f3`. It is pushed only to the AMD handoff repo, not
GitHub, and is not merged. The full description, results and testing steps are
in [video-vaapi.md](video-vaapi.md).

## Where it stands

- **Hardware decoding with copy-back** works on both test machines. The GPU's
  video engine decodes, and each frame is copied, as 8-bit YV12, into an
  ordinary Android buffer.
  - Intel UHD 630, with iHD (or i965);
  - AMD RX 6700 XT, with Mesa radeonsi.
- **Correct output:** every clip the GPU decodes gives the same frames as
  Android's software decoder, or as host FFmpeg where Android has no reference:
  - H.264, HEVC Main and VP9 on both GPUs;
  - AV1, HEVC Main10 (720p to 4K) and 4K content on AMD.
- **Robust:**
  - repeat, flush and seek give identical output;
  - Surface output delivers every frame;
  - 10 probe passes (about 140 decoder sessions) showed no leak.
- **GPU really used:** only the FFmpeg service has video-engine time; with the
  feature off, no process does.
- **Codec gating:**
  - the service offers only the codecs, and the HEVC Main10 profile, that the
    VA driver reports;
  - it reports the picture sizes VA supports;
  - unsupported streams fall back to FFmpeg software inside the service, and
    the log says so.
- **Faster copy-back on AMD (patch 0029):** about twice the frame rate at 4K;
  4K 8-bit decodes at 64–77 fps in the probe.
- **Real app:** VLC plays H.264, HEVC 8-bit, VP9 and 1080p HEVC Main10 through
  the GPU on AMD; H.264, HEVC and VP9 also on Intel (test-17).
- **Off by default:** `LEPTON_VIDEO_HWACCEL=true` turns it on. When it's off,
  Android's decoders and the audio path are unchanged.
- **Zero-copy** is a broken development option
  (`LEPTON_VIDEO_HWACCEL_ZEROCOPY=true`), kept away from the default path.

## What was done

| Commits | Change |
| --- | --- |
| `e3ddc76`–`69478a7` | FFmpeg Codec2 service, libva, Intel i965 and iHD drivers, Mesa VA (patches 0017–0021), bit-exact copy-back on Mesa (0023), launcher option and off defaults, media probe |
| `3b13fd3`–`12c536d` | Copy-back first: VA capability gating and session logs (0024), 0023 kept, zero-copy behind a development option, decode-only Mesa, probe codec matrix, video-engine sampler, docs |
| `eaff44b`–`6b900e6` | HEVC Main10 listed when VA decodes it (0025); VLC test on AMD |
| `10483e7`–`57b7799` | Decoder size limits from VA, up to 8K (0026, 0027) |
| `387203f`–`3ab4eb2` | Copy-back step timing (0028); faster copy-back (0029: derived VA mapping on Mesa, threaded 10-bit conversion); 4K and 10-bit probe clips; throughput mode |
| `20d9a4b` | Documentation of the release state |

## Still to do

1. **4K60 10-bit is below full rate:** about 47 fps on the RX 6700 XT, so VLC
   drops the late frames and shows black. Options are in "Future work" in the
   main doc: a dedicated P010 conversion, or overlapping conversion with decode.
2. **HDR is shown as SDR:** 10-bit is reduced to 8-bit with no tone mapping, so
   PQ content looks washed out. HDR end to end needs P010 output (zero-copy or
   GPU VPP), HDR metadata in Codec2, an HDR dataspace through SurfaceFlinger,
   and 10-bit PQ through Lepton's display bridge. The AMD machine's monitor
   supports HDR10.
3. **Resolution change:** one frame is lost where an H.264 stream changes
   resolution mid-stream (the service's frame pairing).
4. **Intel with patch 0029** has not been tested, and iHD copy-back was slower
   than i965 on the UHD 630.
5. **Zero-copy and GPU VPP:** not started. Zero-copy needs NV12 import in Mesa
   for Android buffers, a video-only allocation path, and fixes for iHD imports.
6. **Not tested:**
   - newer Intel GPUs, other AMD generations, the Steam Deck;
   - VP8, MPEG-2, VC-1, VP9 Profile 2 and AV1 10-bit content;
   - real apps other than VLC;
   - AV1 in a real app (VLC never uses MediaCodec for AV1);
   - long playback.
7. **Before merging:**
   - reconcile the AMD checkout, which carries the added projects and patches;
   - add the LGPL notices for FFmpeg;
   - the existing test failures, also on `main`, remain: `test-source-reset`,
     `test-local-display`, `test-customize-package`, `test-customize-inject`.
