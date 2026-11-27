# Android Library release validation

Use a disposable library and profiles. Keep the logs, package versions,
Steam AppIDs and bundle checksums with the release review. Move the final
results into the pull request before merging.

## Build and install a candidate

Package a previously validated Android stage from this checkout. This keeps
the stage's rootfs and sysbake; no Android rebuild is needed. The library
needs the extractor's `--json` mode, so rebuild the extractor first.
Packaging refuses an extractor without it.

```bash
make -C compat_tool/liblepton/apk_extractor install-native
bundle_id=v0.4.0-android-library-test4
bundle_dir="$HOME/lepton-test-bundles"
bash image-14/scripts/internal/deploy-compat-x86_64.sh --package-only --execute \
  --stage-dir "$VALIDATED_STAGE" --bundle-dir "$bundle_dir" --bundle-id "$bundle_id"
cd "$bundle_dir" && sha256sum -c "lepton-x86_64-$bundle_id.tar.gz.sha256"
```

Fedora (Intel or AMD), from the Wayland session:
`bash "lepton-x86_64-$bundle_id.install.sh" --install-profile local-desktop`.
Steam Deck, from Konsole in Desktop Mode, then restart Steam:
`bash "lepton-x86_64-$bundle_id.install.sh" --install-profile steamos`.
Use an NDK stage for the ARM64 tests and a GApps stage for Google Play.

## Test APKs

Real apps: the ARM64-only Crossy Road APKM (Unity, extracted libraries) and
AAAAXY APK (libraries loaded from the APK), plus x86_64 and multi-ABI APKs.

The update fixture (`tests/runtime/build-library-update-fixtures.sh`) still
needs a JDK and SDK Build Tools to *build*, on a development machine only.
Copy the whole set to the test machines so all versions share signing keys.
To make key-rotation variants of an existing fixture with only a Java
runtime, use AOSP's prebuilt `apksigner.jar`:

```bash
AS() { java -jar "$AOSP/prebuilts/sdk/tools/linux/lib/apksigner.jar" "$@"; }
for k in a b c; do keytool -genkeypair -keystore $k.jks -storepass testpass -keypass testpass \
  -alias $k -keyalg RSA -keysize 2048 -validity 3650 -dname "CN=Lepton test $k"; done
AS rotate --out lineage --old-signer --ks a.jks --ks-pass pass:testpass --new-signer --ks b.jks --ks-pass pass:testpass
AS sign --ks a.jks --ks-pass pass:testpass --out v1-a.apk v1.apk
AS sign --ks a.jks --ks-pass pass:testpass --next-signer --ks b.jks --ks-pass pass:testpass \
  --lineage lineage --out v2-rotated.apk v2.apk
AS sign --ks c.jks --ks-pass pass:testpass --out v2-c.apk v2.apk   # unrelated key
```

## Results so far

### This round: SDK-free library, staged updates, managed NDK preparation

Fedora 44, AMD, a disposable copy of the installed `v0.4.0-test-ndk` bundle
with this branch's launcher, library and extractor. There was no `aapt2`,
`apksigner` or `LEPTON_ANDROID_BUILD_TOOLS`. The library was on a second
drive in a path with spaces, standing in for an SD card.

| Test | Result |
| --- | --- |
| Import without SDK tools | Crossy Road APKM (180 MB) imported in 3.5 s; `strace` showed only the bundled extractor run, no Java, `aapt2` or `apksigner` |
| ARM64 managed vs unmanaged (Crossy Road) | Managed: Android verified 7.15.0; 52 SEVL and 52 WFE patched in `libunity.so` in Android's own `/data/app` directory; tiered chosen. The same APKM unmanaged gave identical counts and choice. Second managed launch used tiered from the recorded choice, with no reinstall or re-patching. Unity started and the activity was displayed. Without GApps, its ads and Firebase SDKs log missing Google Play services and continue |
| ARM64, libraries in the APK (AAAAXY) | Managed and unmanaged both: nothing extracted to patch, light mode kept; the NDK shim was active |
| Reinstall and update of ARM64 code | Found and fixed: an identical reinstall goes to a new code directory with unpatched libraries, and the code identity now includes the directory. After the fix, relaunching patched the new directory before the app started |
| Data-preserving update (fixture) | v1 → stage v2 → `apply`: Android accepted it and the library promoted it, keeping v1 in `.previous`. The launch counter went 1 → 2 → 3 across updates and launches |
| Refused updates | Wrong key and unrelated key C: Android refused (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`), the active APK and installed version were unchanged, `info` showed the refusal, the next launch played the installed version with its data, and `discard` removed it. Downgrade, truncated file and damaged member were refused on the host (the damaged-member traceback was found and fixed) |
| Signing-key rotation | v1 (key A) → v2 with lineage A→B: Android accepted it and kept the data. The optional `apksigner` read the `Signer (minSdkVersion=…)` format. A B-only APK was then accepted, as B is the current signer |
| Interrupted installation | Installer killed after the package-manager session was recorded: the launch stopped with the profile kept, and the next launch abandoned the session and installed again. Found and fixed: an interrupted identical reinstall had been recorded as committed |
| Steam Stop | SIGTERM to the process group: HOME sent, Android powered off cleanly, profile retained |
| Container Storage | Files copied both ways between the host and `/storage/emulated/0/Container Storage` with default sharing |
| Library drive removed | `status` reported it unavailable. A managed launch through the compatibility entry stopped with "This game is in the Android Library, which is not available", and the desktop dialog showed the reconnect/forget advice. An unmanaged APK launched and logged "Container Storage not shared this launch". Nothing was created at the missing path. After reconnecting, launches and files were back |
| `forget` and a second library | `forget` kept all files; `init --path` set up a second library and later re-adopted the first by its marker |
| Host workflow suite | `run-workflow-tests.sh` passed (86 PASS lines) with the repository's environment-dependent Python skips |

### Earlier rounds (SDK-based implementation, before this round's changes)

| Environment | Observed result |
| --- | --- |
| Fedora, Intel | Signed APK and APKM updates preserved the launch counter across repeated shutdowns. Both APKM members and the test OBB remained available. Apply-only verified the replacement without opening the app. Interrupting the installer before and after Android's commit recovered the original counter. A regular app with storage access wrote to Container Storage with optional sharing disabled. |
| Fedora, Intel with disposable Steam files | Created a real shortcut VDF entry and launched through the Steam compatibility entry point with a separate compatdata path. The signed SDK-incompatible update failed in Android. Restoring the library APK and applying a valid signing-key rotation retained the saved counter. Shortcut, mapping and artwork checksums were unchanged. |
| Fedora, AMD | Updated an APKM library on a mounted ext4 drive. The counter survived the update and restart. An Android-side write appeared in Container Storage with optional sharing off. Simulating a missing drive left the replacement mount-point directory empty. A legacy OBB fixture in a secondary Steam library launched after falling back to streamed installation, and both OBB and Container Storage were visible. |
| Installed candidate `v0.4.0-android-library-test3` | Package and installer checksums passed. Removing and re-importing a running fixture's library entry after shutdown preserved the Android launch counter and the Container Storage file. |

## Outstanding

### Standard Steam Deck installation (candidate bundle)

- Confirm `leptron --help`, `import`, `update` and `info` work with no
  Java or SDK Build Tools installed.
- First `import` creates `~/Android_Library`; `add-to-steam`; launch in Gaming
  Mode; `update` a newer APK; confirm saved data, Steam AppID, artwork and
  controller layout are unchanged; Steam Stop ends it cleanly.
- A refused update in Gaming Mode shows a popup once, then the game plays.

### ARM64 on Steam Deck and Intel

- Repeat the Crossy Road and AAAAXY comparison on an NDK bundle. Update an
  ARM64 app to a real newer version (not only `reinstall`) and check that the
  mode is re-evaluated (light while the update installs, then the new
  choice). Test an ARM64 split APKM update.
- Early-exit fallback for a managed app in the tiered mode.

### Update failures without SDK Build Tools

- A signed APK whose minimum SDK is above 34 (now refused at `update`; also
  confirm a hand-edited candidate is refused by Android).
- Interruption just after Android's commit, on hardware (unit-tested; earlier
  rounds tested it with the previous code).
- Several updates staged before a profile has launched, with a Steam and a
  standalone profile on different installed versions.
- Power loss during promotion (`recover`).

### External storage on Steam Deck

- Library on a physical SD card; Container Storage read/write from an Android
  file manager; remove the card: managed apps fail with a popup, unmanaged
  apps and Google Play start, nothing is created at the mount point; reinsert.

### Google Play (GApps bundle)

- Sign in; install and update an app through the Play Store; Container
  Storage accessible; Play apps not imported into the library; works with
  optional sharing off; launches with the library drive removed.
- Crossy Road with Play services running in the background (no sign-in).

### Legacy regressions

- Existing unmanaged APK and APKM profiles, Steam-distributed apps, secondary
  Steam libraries (now aliased when under `/mnt`), existing OBB support,
  existing profiles and fingerprint checks, hardware video acceleration.
  Unmanaged APK and APKM launches passed on Fedora AMD in this round.
- A profile created by the library refuses an unmanaged launch of the same
  package with a clear message.
