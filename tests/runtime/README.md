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

For fast host-side regression tests without booting Android or using the network:

```bash
bash image-14/tests/run-workflow-tests.sh
```
