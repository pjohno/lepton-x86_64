# Experimental Google API 34 NDK compatibility shim

This shim is now part of standard Lepton startup for the matching bridge.
No per-game preload settings are required in new deployments/bundles.
`LEPTON_NDK_COMPAT=false` disables it for comparisons. Native rootfs builds and
unrecognized translators are left unchanged; forcing `true` requires a match.
Every new bundle, including the x86_64 base bundle, ships this open-source
compatibility component at `compat_tool/liblepton/ndk_auxv/bin/liblepton_ndk_auxv.so`.
It is not Google's proprietary translator and contains no translator files.
The deploy script always compiles it using the existing AOSP Clang Android
x86_64 target, validates its ELF headers and dependencies, and stages it outside
the Android rootfs. Packaging validates and preserves that staged binary;
refreshing source helpers never replaces it with a checkout build artifact.
Packaging needs `readelf`, but no AOSP checkout or compiler. Missing or invalid
staged binaries fail packaging, including `--check`.

The base bundle still reports `gapps: false` and `ndk: false`: shim presence
neither installs translation nor enables the native bridge or ARM64 ABIs.
Runtime activation still requires `ndk_compat_supported()` to recognize the
translator and native-bridge property. Unsupported/incomplete translators stay
inactive (forcing `LEPTON_NDK_COMPAT=true` fails). Future client customisation
can reuse this precompiled binary without AOSP or Android compilation; that
customisation workflow is not implemented yet.

This fixes two problems seen with AAAAXY 1.8.34's Go 1.27.2 ARM64 library:

- Without Android's usual auxv restriction, the Go runtime reads x86 HWCAP bits
  from `/proc/self/auxv` as ARM64 bits and tries unsupported CPU identification
  instructions. Deny that exact path only when opened by the NDK translator;
  Go uses its existing Android fallback. Native callers retain access.
- This bridge does not implement `MIDR_EL1`, `CNTFRQ_EL0`, or `CNTVCT_EL0` reads.
  Let the light JIT fall back to the interpreter for unsupported instructions,
  then emulate those three reads. Use a generic Cortex-A53 identity and a
  consistent 1 GHz counter backed by CLOCK_MONOTONIC nanoseconds. XZR writes
  are discarded.

Crossy Road 7.14.2 (Unity 6000.3.12f1) also reaches an unsupported `SEVL`
(`0xd50320bf`) in Unity's wait loops. The shim handles `SEVL`, `SEV` and `WFE`
as nonblocking event hints, preserving registers and advancing PC by four.
Keeping WFE nonblocking avoids waiting for an event discarded by SEVL/SEV.
Atomic operations and barriers retain their original implementation; WFI and
all other instructions retain the bridge interpreter's behaviour. See Arm's
[description of event hints](https://documentation-service.arm.com/static/5f3fa899428f7a6b3328fd44).
This removes the observed unsupported-instruction failure. On the Google-enabled
experimental stage, Crossy Road then aborts with `stack corruption detected
(-fstack-protector)`. On the baseline non-GApps NDK stage it survived 60 seconds
and rendered age verification, but after age entry its Firebase messaging
initialization failed because Google dependencies were missing. Neither
environment has reached gameplay.

## Translator mode and performance

The shim's instruction emulation only works when the translator falls back to
its interpreter, so the default mode is `light-translate-or-interpret` (light
JIT plus interpreter, no heavy optimizer), which stutters in demanding games.

After installing an ARM64 game, Lepton runs `arm64_hints.py` on its extracted
libraries: it replaces the wait hints `SEVL`, `SEV` and `WFE` (architecturally
allowed to be no-ops) with `NOP` in executable segments, and checks for the
reads only the shim can emulate (`MIDR_EL1`, `CNTFRQ_EL0`, `CNTVCT_EL0`). If none
remain, the game uses the translator's own **tiered** mode (light JIT, then heavy
optimization of hot code) from its next launch. The choice is stored with the
game's data (`baked/lepton-ndk-mode`). If a game exits early in that mode (code
generated at run time, or libraries loaded straight from the APK, cannot be
scanned), Lepton switches it back to the light mode for the next launch.

Crossy Road on Fedora (AMD), 15 s of gameplay each: light mode 56 fps with a
worst frame gap of at least 250 ms; tiered after patching 52 SEVL + 52 WFE in
`libunity.so` 60.8-61.3 fps, worst gap at least 66 ms. AAAAXY's Go runtime reads
the timer registers, so it keeps the light mode.

Per-game override in Steam launch options:
`LEPTON_NDK_TRANSLATION_MODE=light-translate-or-interpret %command%` (or
`tiered`, `heavy-optimize`, `interpret-only`); translator flags via
`LEPTON_ENV_NDK_TRANSLATION_FLAGS` (default `accurate-sigsegv`, `none` for none).
The CPU-feature filtering of `/proc/self/auxv` stays active in every mode. This is a compatibility experiment for one translator version, not a
complete ARM system-register implementation or a general Go compatibility claim.

The APK, proprietary bridge and original rootfs remain unchanged. This directory
contains only original source for the shim, not Google binaries.

## Build and run

From the repository root, using the existing Android 14 compiler:

```bash
source .build-env
bash compat_tool/liblepton/ndk_auxv/build.sh --aosp "$LEPTON_OUTPUT_DIR/aosp"
bash compat_tool/liblepton/ndk_auxv/test.sh

bash tests/runtime/run-apk.sh \
  --stage-dir "$LEPTON_OUTPUT_DIR/stages/ndk-test" \
  --runtime-dir compat_tool \
  --apk "$PWD/apks/AAAAXY-arm64.apk" --expect-abi arm64-v8a --app \
  --rendering amd --display desktop --seconds 300 --execute
```

Standard startup mounts the compiled shim and passes the host
preload and NDK configuration to zygote. The constructor removes LD_PRELOAD
before the ARM64 linker starts, so that linker does not try loading an x86 ELF.
The runner also applies Google's `accurate-sigsegv` flag. Generated binaries are
Git-ignored. Each test has fresh app data and stops at the specified duration.

## Reviewed private ABI

The runner checks SHA-256
`a2086fbc807f697f9b91222065c9d9000ca9727748699c0d9b751319258cbb3e`.
The shim also checks the loaded module's ELF build ID
`553ba82b76bb5a11fd1d67b2c7e01b75` before using private state.
Disassembly of this exact bridge establishes:

- `InitProcessState` initializes the CPU state at offset zero; general registers
  begin there. `InterpretInsn` loads the guest PC from `ProcessState + 0x310`.
- `InterpretInsn` is at module virtual offset `0x1d3bc0`. Non-emulated
  instructions call that original implementation directly.
- `LightTranslator::UndefinedInsn` checks `success_` at offset zero. Clearing it
  makes the JIT reject the block and use interpreter fallback. Emulating a read
  in the runtime `UndefinedInsn` callback instead is insufficient because the
  generated exit path retries the original PC.
- The GNU build-ID descriptor is mapped at module offset `0x298`.

These offsets are intentionally version-specific. An upgraded bridge requires
an ABI review; changing its checksum alone is insufficient. The runtime guard
refuses unrecognized module builds instead of accessing their private state.

## Existing installations

New bundles enable this automatically. Older Deck installations can be updated
with a new bundle; they are not changed by updating this Fedora checkout.
The manual instructions below are only for testing an older installed runtime.

To prepare an existing disposable stage manually, place the compiled shim at
`compat_tool/images/rootfs_overlay/system/lib64/liblepton_ndk_auxv.so`. The
standard Lepton overlay loader mounts it. Set these in that test shortcut's
launch environment (before its existing launch command):

```text
LEPTON_ENV_LD_PRELOAD=/system/lib64/liblepton_ndk_auxv.so
LEPTON_ENV_NDK_TRANSLATION_MODE=light-translate-or-interpret
LEPTON_ENV_NDK_TRANSLATION_FLAGS=accurate-sigsegv
```

Use the same reviewed bridge. The shim has no Fedora-specific dependencies;
Deck functionality still needs its own test. No Deck installation or shortcut
was modified during this investigation.
