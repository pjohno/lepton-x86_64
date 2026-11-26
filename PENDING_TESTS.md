# Android Library release validation

Use a disposable library and profiles for these tests. Keep the logs, package
versions, Steam AppIDs and bundle checksums with the release review.

## Build and install a candidate

Package a previously validated Android stage from the
`feature/android-library` checkout. This uses the stage's existing rootfs and
sysbake. Use a stage with the GPU support appropriate to the machine.

```bash
bundle_id=v0.4.0-android-library-test
bundle_dir="$HOME/lepton-test-bundles"
bash image-14/scripts/internal/deploy-compat-x86_64.sh --package-only --execute \
  --stage-dir "$VALIDATED_STAGE" --bundle-dir "$bundle_dir" --bundle-id "$bundle_id"
cd "$bundle_dir"
sha256sum -c "lepton-x86_64-$bundle_id.tar.gz.sha256"
```

Copy the verified archive and installer to each test system. On Fedora with
Intel or AMD graphics, run the installer from the Wayland desktop session.

```bash
bash "lepton-x86_64-$bundle_id.install.sh" --install-profile local-desktop
```

On Steam Deck, run it from Konsole in Desktop Mode, then restart Steam.

```bash
bash "lepton-x86_64-$bundle_id.install.sh" --install-profile steamos
```

On each system, check `~/.local/bin/lepton-library --help` after installation.
For the GApps regression, use a separately prepared GApps bundle with the
same launcher scripts.

## Build the test APKs

On a machine with a JDK, `zip`, Android SDK Build Tools and the Android 34
SDK platform installed, generate a fixture set. Copy the entire set to the
test machines so v1 and v2 come from the same signing keys.

```bash
export LEPTON_ANDROID_BUILD_TOOLS="$HOME/Android/Sdk/build-tools/34.0.0"
tests/runtime/build-library-update-fixtures.sh \
  "$HOME/Android/Sdk/platforms/android-34/android.jar" "$HOME/lepton-update-fixtures"
```

The fixture shows its version and increments a saved launch counter. The
APKM variants add a feature split. The set also contains an APK signed by
an unrelated key, an APK with a verified key rotation, and a signed v3 APK
whose minimum SDK is deliberately higher than Android 14.

## Data-preserving update

1. Initialise a library. Import `v1.apk` and launch it with
   `lepton-library play org.lepton.updatefixture`. See version 1 and
   launch count 1.
2. Close the app and wait for the container to stop. Run
   `lepton-library update "$HOME/lepton-update-fixtures/v2.apk"`. Use
   `info` to see library version 2 and the standalone profile pending.
3. Run `lepton-library apply org.lepton.updatefixture`. Check that
   `info` reports the applied version without starting the app. Play it and
   confirm version 2 and launch count 2. Shut down and launch again.
4. Run `update` with `wrong-key.apk`, with `v1.apk`, and with a
   truncated APK. Confirm each is refused and the profile still plays v2.
5. Stage `too-new.apk`, then launch. Android should reject the replacement.
   Inspect `info` for a failed attempt and the last verified installed version.
   Restore the library file with `restore-apk --yes`, launch again, and check
   the version and counter. On the restored v2, try
   `update rotated-v2.apk --replace-same-version` and confirm Android accepts
   the lineage and retains the same saved counter.
6. With v1 installed in a fresh disposable profile, interrupt installation
   during the v2 upload and again in a separate run immediately after Android
   commits the update. Use the package path, version, counter and `info` to
   check that a restart either verifies the commit or safely retries it.
   Test a host interruption after replacing the active APK and before writing
   `config.json`. Confirm the launch asks for `recover PACKAGE` and that
   recovery then allows the profile to update.

## Steam, split APKs and shared storage

- Repeat the update with a Steam shortcut, alongside a standalone installation
  of the same APK. Record AppID, shortcut settings, compatdata path, artwork and
  controller layout before the update. Rename the shortcut in Steam and check
  that `info` still discovers it by its executable. Launch each profile
  separately and confirm the other one stays pending until launched.
- Repeat the update with `v1.apkm` and `v2.apkm` in a fresh library. Supply
  an OBB named `main.1.org.lepton.updatefixture.obb` using `--obb` on import
  and read it from Android before and after the update. Verify both base and
  feature APK paths after restart. Confirm APK/APKM format changes are refused.
- Use a library directory containing spaces on a removable drive or SD card.
  With `LEPTON_SHARED_FOLDERS=none`, copy files in both directions through
  Container Storage. Use an Android file manager with storage permission.
  Add a nested symlink in Container Storage and check that its host destination
  is not mounted. Disconnect the drive, attempt a launch, and verify the
  expected error and an untouched mount point. Reconnect and launch again.
- Recheck a legacy OBB game from a secondary Steam library and an unmanaged
  standalone APK. They should use the same Container Storage directory and
  retain their original profile and OBB contents.
- With the shared Google Play shortcut, test sign-in, install/update one Play
  app through the store, then relaunch. Verify it can use Container Storage and
  that the app stays outside the managed library. Repeat with optional sharing
  disabled.
- In Steam Deck Gaming Mode, repeat the Steam shortcut test and use Steam Stop.
  Confirm the profile saves, the shortcut and controller layout are preserved,
  and the removable-drive checks work in both modes.
- Remove the fixture from the library after deleting its Steam shortcut. Verify
  the standalone and Steam profiles and Container Storage remain on disk.

Android media indexing and app-specific file picker behavior can be tested
separately from package updates and direct file access.

## Results so far

| Environment | Observed result |
|---|---|
| Fedora, Intel | Signed APK and APKM updates preserved the launch counter across repeated shutdowns. Both APKM members and the test OBB remained available. Apply-only verified the replacement without opening the app. Interrupting the installer helper before and after Android's commit recovered the original counter. The committed code path was reused after recovery. |
| Fedora, Intel with disposable Steam files | Created a real shortcut VDF entry and launched through the Steam compatibility entry point with a separate compatdata path. The signed SDK-incompatible update failed in Android. Restoring the library APK and applying a valid signing-key rotation retained the saved counter. Shortcut, mapping and artwork checksums were unchanged. |
| Fedora, AMD | Updated an APKM library on a mounted ext4 drive. The counter survived the update and restart. An Android-side write appeared in Container Storage with optional sharing off. Simulating a missing drive left the replacement mount-point directory empty. A legacy OBB fixture in a secondary Steam library launched after falling back to streamed installation, and both OBB and Container Storage were visible. |
| Steam Deck and shared Google Play | Live Gaming Mode, controller layout, physical SD-card removal, Android file-manager access under app permissions and the authenticated GApps workflow are pending. |
