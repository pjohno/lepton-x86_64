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

`stage-services-test.sh --source-stage DIR --stage-dir NEW_DIR --services-jar FILE
--baseline-jar FILE --execute` uses the main deployment script to create a new
stage, checks that the source jar matches the experiment baseline, replaces only
services.jar, discards its stale preoptimized artifacts and copies the existing
host tools. Generate fresh sysbake with the normal isolated sysbake script before
using `run-apk.sh`. The runner records Android's registered services in
`services.txt`. See the Fedora guide for observed Kingdom results.

For fast host-side regression tests without booting Android or using the network:

```bash
bash image-14/tests/run-workflow-tests.sh
```
