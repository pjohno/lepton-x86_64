# Hardware video decoding (VA-API): status

Status on 2026-11-24 for branch `feature/video-vaapi`. The branch started from
`main` at `39d77f3` and is not merged. The full description, results and
testing steps are in [video-vaapi.md](video-vaapi.md).

## Where it stands

- **Off by default.** `LEPTON_VIDEO_HWACCEL=true` turns it on. When it is off,
  Android's software decoders and the audio path are unchanged (checked on
  test-25: `c2.android.*` decoders, no service activity, audio and video smoke
  tests pass, ANGLE on Vulkan rendering).
- **Hardware decoding** of H.264, HEVC (Main and Main10), VP9 and, on AMD, AV1,
  on Intel UHD 630 (iHD or i965) and AMD RX 6700 XT (Mesa radeonsi). Only the
  codecs and the HEVC Main10 profile the VA driver reports are offered;
  unsupported streams fall back to FFmpeg software inside the service, logged.
- **Three output paths** (`LEPTON_VIDEO_HWACCEL_OUTPUT`):
  - `copyback` (default): bit-exact against Android's decoders on both GPUs;
  - `direct` (new, patch 0030): the GPU converts each frame into Android's
    buffer. Bit-exact on Intel; within about one code on AMD (Mesa 26.0.8);
  - `vpp` (experimental): GPU 10-to-8-bit conversion before copy-back.
- **4K60 10-bit** (59.94 fps HEVC Main10, VLC): direct output plays at full
  rate with no late pictures on the UHD 630 and the RX 6700 XT, where copy-back
  reaches about 20 and 42 fps. **Not yet measured on the Steam Deck**
  (test-25 is ready for it).
- **Robust:** repeat, flush, seek, resolution change (as before), Surface and
  ByteBuffer output; no growth of service memory or open files over repeated
  sessions.

## What was done

| Commits | Change |
| --- | --- |
| `e3ddc76`–`69478a7` | FFmpeg Codec2 service, libva, Intel i965 and iHD drivers, Mesa VA (patches 0017–0021), bit-exact copy-back on Mesa (0023), launcher option and off defaults, media probe |
| `3b13fd3`–`12c536d` | VA capability gating and session logs (0024), decode-only Mesa, probe codec matrix, video-engine sampler |
| `eaff44b`–`6b900e6` | HEVC Main10 listed when VA decodes it (0025) |
| `10483e7`–`57b7799` | Decoder size limits from VA, up to 8K (0026, 0027) |
| `387203f`–`9fc072c` | Copy-back step timing (0028); faster copy-back (0029); 4K and 10-bit probe clips; throughput mode |
| `0f51f42`–now | Direct output and GPU copy-back conversion (0030); `LEPTON_VIDEO_HWACCEL_OUTPUT` replaces the broken zero-copy option; experimental minigbm patch removed |

## Still to do

1. **Steam Deck with direct output** (test-25): compare `copyback`, `vpp` and
   `direct` on the 4K59.94 Main10 clip.
2. **After the Deck result:** decide whether `direct` becomes the default output
   when hardware decoding is on, and drop `vpp` and the AMD experiment's test
   hooks from 0030 if direct output supersedes them.
3. **HDR is shown as SDR** on every path (no tone mapping).
4. **Resolution change:** one frame is lost where an H.264 stream changes
   resolution mid-stream (the service's frame pairing).
5. **Not tested:** newer Intel GPUs, other AMD generations; VP8, MPEG-2, VC-1,
   VP9 Profile 2 and AV1 10-bit content; real apps other than VLC; long
   playback; direct output while a game loads the GPU.
6. **Existing test failures, also on `main`:** the same 16 test scripts fail on
   both (usage-only scripts run without arguments, runtime-dependent tests,
   `test-local-display`, `test-customize-package`, `test-customize-inject`).
