# Local Android runtime tests

These tests are separate from the legacy CI-only `tests/test-*.sh` harness,
which expects a disposable CI host. The local runner uses private Podman storage
and copied sysbake data, retaining logs beneath the selected stage.

Build a JNI fixture from an existing AOSP checkout:

```bash
bash tests/runtime/build-jni-smoke.sh --aosp /path/to/aosp \
  --abi arm64-v8a --output /path/to/new-smoke.apk
```

Preflight and execute a native/JNI test:

```bash
bash tests/runtime/run-apk.sh --stage-dir /path/to/stage \
  --runtime-dir compat_tool --apk /path/to/new-smoke.apk \
  --expect-abi arm64-v8a --check
# Replace --check with --execute to boot Android and verify the JNI result.
```

For a real game, add `--app --rendering amd --display desktop --seconds 90`.
Use `--until-exit` in app mode to keep a session open until the app exits or the
runner is stopped; this replaces the observation time limit.
The runner forces and verifies the requested ABI for universal APKs. See
[the Fedora guide](../../FEDORA-DEBUGGING.md) and `--help` for all options.

`--apk` also accepts APKMirror `.apkm` bundles in app mode. It installs the base,
selected conventional ABI split, and feature/asset splits in one package-manager
session. Preflight temporarily extracts only base and ABI metadata; execution
retains the full selected APK set beneath the test workspace. APKs must be at
the archive root with safe, unique filenames. `.xapk` and `.apks` formats are not
supported by this path.

## Locale-service framework experiment

`build-locale-services.sh --aosp DIR --output-dir NEW_DIR --execute` incrementally
builds only `services.jar` using an exact, read-only override of SystemServer.java.
It restores the previously disabled LocaleManagerService in that override, saves
baseline and experimental jars, then rebuilds the original source to restore the
shared build cache. The original source, packaged images and runtime stages are
not edited. Use `--check` for preflight. A prepared, previously built Android 14
checkout and local Ubuntu builder are required; this does not download anything.
If interrupted, recover using the same arguments plus `--restore-build --execute`.
`--with-google-services` also restores CrossProfileAppsService, required by the
tested GMS version. This remains a local framework experiment, not a default
change to the Android patch set.

`stage-services-test.sh --source-stage DIR --stage-dir NEW_DIR --services-jar FILE
--baseline-jar FILE --execute` uses the main deployment script to create a new
stage, checks that the source jar matches the experiment baseline, replaces only
services.jar, discards its stale preoptimized artifacts and copies the existing
host tools. Generate fresh sysbake with the normal isolated sysbake script before
using `run-apk.sh`. The runner records Android's registered services in
`services.txt`. See the Fedora guide for observed Kingdom results.

## Optional Google services and network experiment

`stage-google-services.sh --source-stage DIR --stage-dir NEW_DIR --google-images
LOGICAL_PARTITIONS_DIR --execute` adds only Google Play services, Google Services
Framework, their x86_64 native libraries and supporting permission configuration
from a local Android 14 Google image. It uses the main deploy script, leaves
source stages unchanged and requires fresh isolated sysbake. Play Store is
excluded unless `--with-play-store` is supplied with matching Google Play image
partitions. Neither mode downloads files or certifies the resulting environment.

The app runner records `connectivity.txt` and `ip-address.txt`. On the tested
Fedora Podman configuration, Android netd cannot provision Ethernet while
`/proc/sys` is read-only. `--network-sysctls` enables the experimental
`LEPTON_NETWORK_SYSCTLS=true` runtime option, allowing netd sysctl writes only
along the private pasta network path. Sysbake still has no network. The default
runtime configuration is unchanged. This option produced an IPv4 address and a
validated default network in the Fedora test. Do not infer Google certification
or game compatibility from network validation.

For the isolated Deck test, see [Steam Deck instructions](STEAM-DECK-GAPPS.md).
The main deployment packager includes the runtime runner and its APKM/GSF helpers;
no test profiles or game downloads are copied.

## Persistent setup, then install/play

The default runner remains disposable. Add `--profile NAME` to opt into a private
profile under the stage, preserving Android data, Google identity, account state,
external storage and installed APKs. Normal Valve cleanup behavior is unchanged
unless this explicit profile override is used. The separate
`fix/apk-install-persistence` branch has not been merged by this experiment.

First open setup without installing a game (run from a Wayland desktop):

```bash
source .build-env
stage="$LEPTON_OUTPUT_DIR/native-bridge-research/lepton-google-play-test-v2"
bash tests/runtime/run-apk.sh --stage-dir "$stage" --runtime-dir compat_tool \
  --profile kingdom --setup-only --expect-abi arm64-v8a \
  --network-sysctls --rendering amd --display desktop --seconds 900 --execute
```

The Store opens for account setup. If necessary, register the displayed GSF
Android ID at Google's uncertified-device page, then sign in manually. This is
not manufacturer certification or a guarantee of Play Integrity. Stop setup
with Ctrl+C when finished; the profile is retained. ID lookup uses host SQLite
inside Podman's user namespace, never the guest sqlite3 utility.

Install and launch a local APK/APKM with the **same** stage and profile:

```bash
bash tests/runtime/run-apk.sh --stage-dir "$stage" --runtime-dir compat_tool \
  --profile kingdom --app --apk "$PWD/apks/Kingdom.apkm" --expect-abi arm64-v8a \
  --network-sysctls --rendering amd --display desktop --seconds 600 --execute
```

Repeat this command for later launches. The runner hashes the APK set and checks
package presence; unchanged installed packages are reused. Changed APKs are
installed as updates while retaining Android data. The first game pins its
package name to that profile. Profiles are locked against concurrent use and
retain a stable Podman graphroot/runroot configuration. Host debug ports are not
forwarded, allowing independent test profiles without ADB-port collisions.

A changed framework/payload fingerprint requires explicit
`--accept-runtime-update` after review; this retains the existing Google identity
and account data. Do not delete the profile to test an ordinary restart.
Profiles contain personal data: they stay outside Git and are separate from the
compatibility tool's distributable rootfs/sysbake. Keep experimental runtime
profiles local; this is not yet a production Steam registration workflow.

For fast host-side regression tests without booting Android or using the network:

```bash
bash image-14/tests/run-workflow-tests.sh
```

## Internal browser and app-link launches

Lepton now leaves Android VIEW intents inside Android by default. The legacy
Steam browser route requires `LEPTON_FORWARD_WEB_INTENTS=true`; even then, only
untargeted HTTP/HTTPS intents are forwarded. Explicit activities, package-targeted
intents, relative asset paths and callback/content schemes stay in Android.

The framework experiment builder accepts `--fix-view-intents` alongside
`--with-google-services`. It overlays both reviewed source files read-only,
builds services.jar and restores the original build artifact. Android's ProtoLog
tool deliberately chooses random generated class names, so regenerated baseline
DEX can differ. The helper hash-checks original sources, rebuilds them, verifies
the saved baseline JAR hash and reinstates that exact packaged artifact.
Android source files remain untouched.

Use `run-apk.sh --services-jar FILE` to test the compiled framework without
changing the source stage. It requires a stage with stale services dexpreopt
removed. The override hash is part of the persistent profile fingerprint;
`--accept-runtime-update` deliberately retains its identity/account across the
change. Repeat `--services-jar FILE` on subsequent launches. Omitting it rolls
back to the stage framework and requires accepting that change as well.

`stage-google-services.sh --with-browser` optionally includes matching Chrome
and TrichromeLibrary from the downloaded Google image, with x86_64 native
libraries. Browser support is separate from WebView. This is useful for external
OAuth/Custom Tabs; Google binaries remain outside Git.

## Offline media diagnostics

```bash
source .build-env
bash tests/runtime/build-jni-smoke.sh --aosp "$LEPTON_OUTPUT_DIR" \
  --abi x86_64 --media-smoke --output /tmp/lepton-media-smoke.apk
bash tests/runtime/run-apk.sh --stage-dir "$stage" --runtime-dir compat_tool \
  --apk /tmp/lepton-media-smoke.apk --expect-abi x86_64 \
  --media-smoke --codec2 --rendering amd --display headless --seconds 35 --execute
```

The build additionally needs host ffmpeg (libx264/libvorbis). It generates original
local test patterns and tones, with no downloads. The run requires actual AVC
and Vorbis decoded output plus a video-surface rendering marker; process survival
alone cannot pass. `--codec2` enables the experimental Codec2 list and BLOB plus
BUFFERQUEUE allocation (`LEPTON_CODEC2=true`). Default codec behavior is retained
until decode/rendering pass. The current AMD probe fails on an invalid YCbCr
layout from gralloc, after fixing missing ION/system-heap input allocation. That
remaining graphics-buffer problem is separate from VIEW-intent interception.
