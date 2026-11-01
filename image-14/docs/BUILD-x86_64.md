# Fresh Android 14 x86_64 build entry point

`image-14/do_build_x86_64.sh` follows the same entry-point convention as
Valve's `image-14/do_build.sh`. Valve's wrapper builds the host builder if
needed, compiles Android images, and packages the rootfs. The x86_64 wrapper
also assembles a Steam Deck-compatible stage, builds host tools, performs
**isolated** sysbake, and generates a **local-only** tarball with SHA-256.

## Prerequisites

- Linux x86_64 host with rootless Podman, FUSE, Weston, and the Android build
  and rootfs packaging prerequisites (the `--check` mode verifies commands).
- Checked-out Lepton source, pinned initialized submodules, and a trusted
  repository-local `.build-env` based on `.build-env.example`.
- The x86_64-specific Containerfiles in `image-14/.buildscripts_x86_64/`.
- Configure `.build-env` with `LEPTON_OUTPUT_DIR` pointing to an **entirely
  new, nonexistent directory** with sufficient storage. `LEPTON_LOG_DIR` must
  be outside that output. Give each generated bundle a distinct ID.

From the repository root:

```bash
bash image-14/do_build_x86_64.sh --check --bundle-id my-fresh-build-01
bash image-14/do_build_x86_64.sh --execute --bundle-id my-fresh-build-01
```

The wrapper stops on failure and never resumes an existing AOSP checkout or
uses an existing rootfs, stage, sysbake, or bundle. On failure, retain logs
and review checkpoints. To retry an entirely clean build, choose another
nonexistent `LEPTON_OUTPUT_DIR`; do not delete an existing source tree blindly.

The workflow invokes, in sequence:

1. Fresh source preflight and `prepare-x86_64.sh --execute` (AOSP + patches).
2. `build-images-x86_64.sh --execute` (system/vendor images).
3. `package-repro-rootfs.sh` (flattened Android rootfs).
4. `deploy-compat-x86_64.sh --stage-dir ... --execute`.
5. `provision-deck-tools.sh --execute` (pinned ADB and built inotify-tools).
6. `sysbake-isolated-x86_64.sh --execute` (fresh Android boot using
   SwiftShader software rendering, private Podman storage and an isolated
   headless Weston session).
7. `package-lepton-deck.sh` with local checksum and archive checks.

### Sysbake graphics backend

The x86_64 build wrapper uses **software rendering by default** for sysbake.
Android uses ANGLE, SwiftShader (`vulkan.pastel`) and the default software
gralloc allocator. During software mode, Lepton masks the x86_64 GBM allocator
and mapper HAL declarations to prevent Android from selecting GPU-dependent
buffer allocation.

This avoids requiring an AMD GPU or `/dev/dri` passthrough for sysbake.
The resulting Android image retains its AMD RADV and GBM drivers for
hardware-accelerated runtime use on Steam Deck and compatible AMD systems.

For debugging, the standalone sysbake runner also supports
`--rendering amd`. This requires a fresh stage without existing sysbake data.
The main build wrapper always selects the software default.

The software path has been verified on Fedora x86_64 using rootless Podman.
Portability to other host GPU configurations has not yet been independently
tested.

The generated bundle includes `tools/BUILD-PROVENANCE.txt` containing the
Lepton commit, source-tree state, resolved AOSP manifest hash, builder image
ID, compiled image hashes, and baked package-list hash. This is a **build
provenance record**, not a guarantee of bit-for-bit reproducibility: upstream
container base tags, repository/network dependencies, and generated Android
bake timestamps are not all pinned yet.

**Safety:** Never run `.ci_scripts/build-sysbake-14.sh` on a personal Fedora
machine; its privileged CI setup resets Podman storage. The x86_64 wrapper
never transfers files to Steam Deck, registers Steam shortcuts, or overwrites
the known-good Lepton installation.
