# Hardware video decoding (VA-API): status

Status on 2026-11-24 for branch `feature/video-vaapi`, ready for review and
not merged. The branch started from `main` at `39d77f3`. The full
description, results and testing steps are in [video-vaapi.md](video-vaapi.md).

## Where it stands

- **Opt-in.** `LEPTON_VIDEO_HWACCEL=true` turns it on; it is off by default.
  When it is off, Android's software decoders, audio and rendering are
  unchanged (checked on the release build, test-26).
- **Hardware decoding** of H.264, HEVC (Main and Main10), VP9 and, on AMD, AV1
  with Intel iHD/i965 and AMD Mesa radeonsi. Only the codecs and the HEVC Main10
  profile the VA driver reports are offered, so apps that check profiles now
  find a Main10 decoder; unsupported streams are decoded by FFmpeg in software
  inside the service, and logged.
- **Direct output is the default** when it is on: the GPU converts each frame
  straight into Android's buffer, with no readback. Copy-back
  (`LEPTON_VIDEO_HWACCEL_OUTPUT=copyback`) remains, for older images and as the
  automatic per-session fallback when direct output fails.
- **4K59.94 HEVC Main10 in VLC with direct output:**
  - Intel UHD 630: 60.1 fps, 0 late pictures, 0 SurfaceFlinger drops;
  - AMD RX 6700 XT: 60.1 fps, 0 late pictures;
  - Steam Deck: 60.1 fps in a complete run (56.4 fps in a first run with
    start-up), all 3,597 frames direct, smooth on screen; late-picture and
    displayed-frame counts were not captured there.
  With copy-back none of the three keeps up.
- **Correct output:** direct output is bit-exact on Intel; on AMD (Mesa
  26.0.8) it is within about one code, more next to sharp colour edges.
  Copy-back is bit-exact on both.
- **Robust:** repeat, flush, seek, forced fallback, Surface and ByteBuffer
  output; the service's open files and memory stay flat over repeated sessions.

## What was done

| Commits | Change |
| --- | --- |
| `e3ddc76`–`69478a7` | FFmpeg Codec2 service, libva, Intel i965 and iHD drivers, Mesa VA (patches 0017–0021), bit-exact copy-back on Mesa (0023), launcher option and off defaults, media probe |
| `3b13fd3`–`12c536d` | VA capability gating and session logs (0024), decode-only Mesa, probe codec matrix, video-engine sampler |
| `eaff44b`–`6b900e6` | HEVC Main10 listed when VA decodes it (0025) |
| `10483e7`–`57b7799` | Decoder size limits from VA, up to 8K (0026, 0027) |
| `387203f`–`9fc072c` | Copy-back step timing (0028); faster copy-back (0029) |
| `0f51f42`–`86eff5a` | Direct output (0030), launch option replacing the broken zero-copy option, licences, docs |
| `f6e768f` and later | Direct output by default; GPU copy-back conversion and experiment hooks removed; safe minigbm handle checks (0021); release docs |

## Known limitations

1. **HDR is shown as SDR** (no tone mapping) on every path.
2. **4K60 is not guaranteed** on other hardware, with other apps, or while a
   game loads the GPU; the Steam Deck has about 4 ms of spare time per frame.
3. **Direct output on AMD is not bit-exact** with the image's Mesa 26.0.8.
4. **Resolution change:** one frame is lost where an H.264 stream changes
   resolution mid-stream.
5. **Not tested:** newer Intel GPUs, other AMD generations; VP8, MPEG-2, VC-1,
   VP9 Profile 2 and AV1 10-bit content; real apps other than VLC; playback
   longer than a few minutes.
6. **Existing test failures, also on `main`:** the same 16 test scripts fail
   on both (scripts that need arguments or a running instance,
   `test-local-display`, `test-customize-package`, `test-customize-inject`).
