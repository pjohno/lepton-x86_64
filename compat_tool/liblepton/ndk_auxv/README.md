# Experimental Google API 34 NDK compatibility shim

This shim is now part of standard Lepton startup for the matching bridge.
No per-game preload settings are required in new deployments/bundles.
`LEPTON_NDK_COMPAT=false` disables it for comparisons. Native rootfs builds and
unrecognized translators are left unchanged; forcing `true` requires a match.
The deploy script builds it for matching NDK images, and the Deck packager
refreshes the module and compiled binary from this checkout.

This fixes two problems seen with AAAAXY 1.8.34's Go 1.27.2 ARM64 library:

- Without Android's usual auxv restriction, the Go runtime reads x86 HWCAP bits
  from `/proc/self/auxv` as ARM64 bits and tries unsupported CPU identification
  instructions. Deny that exact path only when opened by the NDK translator;
  Go uses its existing Android fallback. Native callers retain access.
- This bridge does not implement `MIDR_EL1`, `CNTFRQ_EL0`, or `CNTVCT_EL0` reads.
  Let the light JIT fall back to the interpreter for unsupported instructions,
  then emulate those three reads. Use a generic Cortex-A53 identity and a
  consistent 1 GHz counter backed by CLOCK_MONOTONIC nanoseconds. XZR writes
  are discarded. Other instructions retain the bridge interpreter's behaviour.

The light JIT remains enabled. Heavy optimization is disabled while using this
shim. This is a compatibility experiment for one translator version, not a
complete ARM system-register implementation or a general Go compatibility claim.

The APK, proprietary bridge and original rootfs remain unchanged. This directory
contains only original source for the shim, not Google binaries.

## Build and run

From the repository root, using the existing Android 14 compiler:

```bash
source .build-env
bash compat_tool/liblepton/ndk_auxv/build.sh --aosp "$LEPTON_OUTPUT_DIR"
bash compat_tool/liblepton/ndk_auxv/test.sh

bash tests/runtime/run-apk.sh \
  --stage-dir "$LEPTON_OUTPUT_DIR/native-bridge-research/lepton-ndk-test-v2" \
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
