# Local Fedora APK debugging

Lepton can run local APK tests without a Steam shortcut or Deck transfer. Run
from the Fedora user's Wayland desktop session, without sudo.

## Runtime and test prerequisites

A complete stage needs `compat_tool/images/rootfs`, matching `sysbake` and
`sysbake.xattrs`, the native APK metadata extractor, and `tools/bin/inotifywait`.
A rootfs alone is insufficient. See the main README for image packaging, stage
creation, Deck utility provisioning, and isolated sysbake generation.

Host tools include Podman, fuse-overlayfs, rsync, attr, unzip, Python 3, Weston,
and a working systemd user session. Android also needs BinderFS. AMD graphics
mode requires accessible AMD devices and the rootfs's RADV driver.

Store local test APKs in the Git-ignored `apks/` directory. No APKs, Google
translator binaries, Android images or generated compatibility libraries are
committed to this repository.

## Optional ARM64 translation

NDK deployment is **opt-in**. Native x86_64 is the default because the translator
comes from a separately obtained Google image and game compatibility is still
experimental. Extract a local payload using
`image-14/scripts/extract-ndk-translation.sh`; see that script's `--help`.

Once images have been built and packaged, assemble a NEW NDK-enabled stage:

```bash
source .build-env
PAYLOAD="$LEPTON_OUTPUT_DIR/native-bridge-research/ndk-google-api34-r14-v2/payload"
STAGE="$LEPTON_OUTPUT_DIR/deck-stage-ndk"

bash image-14/scripts/deploy-compat-x86_64.sh --check \
  --stage-dir "$STAGE" --with-ndk --ndk-payload "$PAYLOAD"
bash image-14/scripts/deploy-compat-x86_64.sh --execute \
  --stage-dir "$STAGE" --with-ndk --ndk-payload "$PAYLOAD"
```

`LEPTON_NDK_PAYLOAD` in the ignored `.build-env` can supply the payload path.
The deploy step verifies payload hashes, injects into a new rootfs copy, builds
our compatibility shim and saves the injection report under
`compat_tool/ndk-provenance/`. It downloads nothing and refuses to overwrite a
stage. Provision tools and generate a **fresh** sysbake for the new stage;
existing native sysbake data is not copied into an NDK stage.

`--rootfs-source DIR` remains available for already assembled alternate
rootfs builds. Omitting `--with-ndk` leaves the selected source unchanged.

For the reviewed Google API 34 r14 translator, standard runtime startup enables
our CPU/timer compatibility shim automatically. No per-game preload settings
are needed in updated stages/bundles. Set `LEPTON_NDK_COMPAT=false` for a control
run; unknown translator versions and native rootfs builds are left unchanged.
See [shim internals and tests](compat_tool/liblepton/ndk_auxv/README.md).

## Repeatable app tests

The examples below use an existing stage from the development machine. Substitute
another complete stage as needed. Build the local shim when testing this
checkout's scripts against an older matching NDK stage:

```bash
source .build-env
STAGE="$LEPTON_OUTPUT_DIR/native-bridge-research/lepton-ndk-test-v2"
bash compat_tool/liblepton/ndk_auxv/build.sh --aosp "$LEPTON_OUTPUT_DIR"

bash test-lepton-jni-smoke.sh --stage-dir "$STAGE" --runtime-dir compat_tool \
  --apk "$PWD/apks/AAAAXY-arm64.apk" --expect-abi arm64-v8a --app --check

bash test-lepton-jni-smoke.sh --stage-dir "$STAGE" --runtime-dir compat_tool \
  --apk "$PWD/apks/AAAAXY-arm64.apk" --expect-abi arm64-v8a --app \
  --rendering amd --display desktop --seconds 300 --execute
```

`--runtime-dir compat_tool` selects current checkout scripts; without it, the
runner tests the scripts already in the stage. Default graphics are software
with a private headless Weston. Desktop mode uses the current Wayland socket;
set `GAMESCOPE_WAYLAND_DISPLAY` explicitly if its selection is wrong.

Each run copies launcher and sysbake data into a new `.jni-smoke-work.*` directory
under the stage, uses private Podman storage, and references the original rootfs
through a read-only overlay. It stops the container afterward. The source stage,
normal Podman store and Deck are unchanged. Workspaces remain for inspection;
app saves are not reused between these fresh-install tests.

The runner forces installation of `--expect-abi` and verifies the installed
package ABI. This matters for universal APKs: otherwise Android may select
x86_64 while appearing to test ARM translation. For SuperTuxKart:

```bash
for abi in x86_64 arm64-v8a; do
  bash test-lepton-jni-smoke.sh --stage-dir "$STAGE" --runtime-dir compat_tool \
    --apk "$PWD/apks/SuperTuxKart-1.4.apk" --expect-abi "$abi" --app \
    --rendering amd --display desktop --seconds 90 --execute
done
```

Results include continuous `app-logcat.log`, boot logs, install/activity output,
package/activity details, native stacks, and `screen.png` when capture succeeds.
A surviving process alone does not prove gameplay, controls or sound work.

Omit `--app` for the purpose-built JNI smoke APK, which must return
`LEPTON_JNI_SMOKE_PASS value=42`. `build-lepton-jni-smoke.sh --help` describes
building either ABI from an existing Android 14 checkout without an image rebuild.

## Steam shortcuts for a separate NDK installation

The shortcut helper accepts a tool ID and matching installation directory.
After fully exiting Steam, for example:

```bash
python3 /path/to/lepton-add-game /absolute/path/to/game.apk \
  --tool-id lepton_ndk_x86_64_dev \
  --install-dir "$HOME/.local/share/lepton-ndk-x86_64-dev" --dry-run
```

Remove `--dry-run` to create the shortcut. The selected compatibility tool must
already be registered; the helper checks that its VDF install path matches.
Default tool selection remains `lepton_x86_64_dev`.

## Validation on 2 November 2026

Fedora 44, kernel `7.2.13-200.fc44.x86_64`, AMD graphics:

| Application/test | ABI | Result |
| --- | --- | --- |
| JNI smoke | x86_64 | Passed; native function returned 42 |
| JNI smoke with compatibility shim | ARM64 | Passed; translated function returned 42 |
| AAAAXY 1.8.34 | ARM64 | Rendered and played; automatic startup verified |
| SuperTuxKart 1.4, F-Droid code 312 | x86_64 | 60-second run passed; active race captured; user confirmed gameplay |
| Same SuperTuxKart APK, forced installation ABI | ARM64 | 90-second run passed; rendered scene captured; user confirmed gameplay |

SuperTuxKart source/download listing:
[SuperTuxKart on F-Droid](https://f-droid.org/en/packages/org.supertuxkart.stk/).
Test APK SHA-256:
`b6469d2888970b0c87df0c9eb472ea7d12f331f57f7623c6769986209e830a2f`.
No performance benchmark or Steam Deck validation is implied.

Evidence retained under the development machine's NDK v2 stage:

| Run | Workspace |
| --- | --- |
| Saved shim, AAAAXY 60 seconds | `.jni-smoke-work.IYXxLOPr` |
| ARM64 JNI regression | `.jni-smoke-work.bGnxqBK4` |
| AAAAXY with automatic standard setup | `.jni-smoke-work.Kw2cyFCv` |
| SuperTuxKart x86_64 | `.jni-smoke-work.UJZyewBu` |
| SuperTuxKart ARM64 | `.jni-smoke-work.mADxmP98` |

## Findings behind the fix

Go interpreted the host's x86 auxiliary-vector flags as ARM64 capabilities and
attempted `MIDR_EL1`. After blocking that misleading read, Go's timing code also
hit unsupported `CNTFRQ_EL0`/`CNTVCT_EL0` reads. The version-guarded shim adds
interpreter handling while keeping the light JIT for supported code. It changes
neither the game APK nor Google's translator binary.

Google's excluded `ndk_translation.rc` only registers binfmt_misc executable
handlers; the tested JNI path does not need it. Google's `accurate-sigsegv`
setting is preserved by injection and supplied for older stages at runtime.

Other corrected test issues were missing isolated Steam directories, shared-disk
group ownership outside Podman's user mapping, missing MAIN/LAUNCHER intent
fields, and an older software stage without GBM HAL masking. Host SELinux
policy/enforcement was not changed. Do not infer an SELinux failure from every
Android permission message; inspect the first fatal error.
