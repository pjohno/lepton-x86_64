# Experimental patches (not applied)

Patches here are kept for development and are **not** applied by
`prepare-x86_64.sh` or listed in image provenance.

- `0022-minigbm-gbm-mesa-nv12-video-layout.patch`: gives NV12 gralloc buffers
  256-byte row pitches and a linear modifier, so VA-API drivers can decode
  straight into them (zero-copy, `LEPTON_VIDEO_HWACCEL_ZEROCOPY=true`). With it,
  AMD (radeonsi) imports the buffers and decodes them bit-exactly, but
  SurfaceFlinger aborts creating a texture from them; iHD on Intel writes wrong
  data. It changes every NV12 allocation, and copy-back (the default) does not
  need it. Apply by hand to `external/minigbm` to work on zero-copy:
  `git -C <aosp>/external/minigbm apply <this file>`.
