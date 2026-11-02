# Android 14 Google services investigation

Status: research only. GApps installation, account sign-in, and Google services
used by sideloaded games have **not** been validated in Lepton.
The `feature/android14-gapps` branch starts from the NDK work merged into
`feature/ubuntu26-build-pipeline` at `08dd1d7`.

The requested scope is **optional Google services for sideloaded games**, without
installing or using Play Store. Games continue to be installed from local APKs
through Lepton. A Store download/installation workflow is outside this experiment.

## Existing local image

The image already used for NDK extraction is a useful candidate source, but it
does not provide the complete Play Store environment. Its build properties are:

```text
ro.system.build.fingerprint=google/sdk_gphone64_x86_64/emu64xa:14/UE1A.230829.050/12077443:userdebug/dev-keys
ro.build.version.sdk=34
ro.build.version.release=14
ro.build.flavor=sdk_gphone64_x86_64-userdebug
```

Read-only `debugfs` inspection of the unpacked logical partitions found:

| Partition | Internal path | Finding |
| --- | --- | --- |
| product | `/priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk` | Google Play services present |
| system_ext | `/priv-app/GoogleServicesFramework/GoogleServicesFramework.apk` | Google Services Framework present |
| product | `/etc/permissions/privapp-permissions-google-p.xml` | Google privileged permission allowlists, including GMS and Vending entries |
| product | `/etc/sysconfig/` and `/etc/default-permissions/` | Google configuration present |
| system_ext | `/etc/permissions/privapp-permissions-google-se.xml` | Google privileged permission allowlists present |
| system | `/system/etc/permissions/privapp-permissions-google.xml` | Google privileged permission allowlists present |
| all three | app and priv-app directories | No Phonesky/Vending/Play Store APK found |

An allowlist entry for `com.android.vending` does not establish that its APK is
included. These findings identify candidate files, not a tested minimal payload.
APK signatures, manifests, native libraries, and dependencies still need auditing.

The logical images are under
`$LEPTON_OUTPUT_DIR/native-bridge-research/google-api34/logical-partitions`.
For example, from the repository root:

```bash
source .build-env
google_parts="$LEPTON_OUTPUT_DIR/native-bridge-research/google-api34/logical-partitions"
debugfs -R 'cat /system/build.prop' "$google_parts/system.img"
debugfs -R 'ls -p /priv-app' "$google_parts/product.img"
debugfs -R 'ls -p /priv-app' "$google_parts/system_ext.img"
```

These commands do not mount or write to the images. Do not pass `-w` to debugfs.

Android distinguishes [Google APIs images from images containing Play Store](https://developer.android.com/studio/run/managing-avds).
The existing Android 14 x86_64 Google APIs image is the first candidate for the
services-only experiment. No additional Google Play image is required to start.
Whether its packages satisfy a particular game's dependencies must be tested.

## Services availability versus validation

[Google Play services APIs](https://developers.google.com/android/guides/overview)
communicate with the Google Play services application at runtime. Supplying that
application and its dependencies may resolve missing-service failures in some
sideloaded games. It does not establish that the device is Google-certified or
that the user has a game license.

Some games require more than those background services:

- [Google Play Licensing](https://developer.android.com/google/play/licensing/overview)
  requires the Google Play client, which handles license-check requests.
- [Play Integrity](https://developer.android.com/google/play/integrity/error-codes)
  can fail with `PLAY_STORE_NOT_FOUND` when the official Store package is absent.
- [Integrity licensing verdicts](https://developer.android.com/google/play/integrity/verdicts)
  can report sideloaded apps as `UNLICENSED`. Device and application integrity
  checks are additional, separate requirements.

Consequently services-only support is a compatibility experiment, not a promise
that all Play-distributed games will run. Capture the exact game's logcat to
distinguish missing services from Store dependencies, licensing/integrity
rejection, missing split APKs/assets, and native-library failures. Even games
that do not use licensing may have SDK-specific Store-package dependencies.

## What Waydroid does

Waydroid exposes a [GAPPS system image choice](https://docs.waydro.id/usage/waydroid-command-line-options).
Its [legacy Android-Generic build documentation](https://docs.waydro.id/development/compile-waydroid-using-android-generic-project)
also describes selecting Google app variants during image compilation. That
legacy recipe is not an Android 14 Lepton integration recipe.

The post-install approach in
[`casualsnek/waydroid_script`](https://github.com/casualsnek/waydroid_script/blob/main/stuff/gapps.py)
downloads prebuilt Google apps and copies APKs, native libraries, permission XML,
sysconfig, and other supporting files into the Android filesystem. Its
[`General` implementation](https://github.com/casualsnek/waydroid_script/blob/main/stuff/general.py)
uses the Waydroid overlay when overlayfs is enabled and extracts native libraries
from APKs. Thus this approach can add GApps after the base image is created.

The inspected installer supports Android **11 and 13**, using OpenGApps and
MindTheGapps respectively. It does not define an Android 14 payload. Its paths,
container management, ownership changes, and payload selection are specific to
Waydroid; running it directly is not a Lepton installer.

## Lepton requirements to resolve

- `android_device_valve_lepton/remove_packages/Android.mk` explicitly removes
  `DownloadProvider` and `DownloadProviderUi`. Determine whether the services or
  test game actually need DownloadManager, and restore matching AOSP packages
  if needed. Store downloads are outside scope. Other removed providers and
  disabled framework services need a dependency audit.
- Preserve Lepton's framework, Binder, UID, graphics, and container changes.
  Copying complete Google system/vendor partitions would replace those changes.
- Preserve Google APK signatures and supply matching permission configuration
  in the appropriate partitions. Check privileged grants and shared libraries
  from package-manager logs rather than granting all permissions indiscriminately.
- Audit AccountManager, jobs, networking, TLS/keystore, package installation, and
  services startup. Their compatibility is not established by a successful game
  launch using NDK translation.
- Lepton selects persistent data by runtime context and Steam compatibility data
  path (`compat_tool/liblepton/liblepton.sh`, `mounting.sh`). Test Google-services
  state and any necessary account sign-in in the game's persistent context.
  Do not assume a separate services-test context shares account state with games.
- Waydroid documents [registering an uncertified installation's Android ID](https://docs.waydro.id/faq/google-play-certification).
  Whether Lepton can sign in must be tested. Successful sign-in would not by
  itself establish compatibility with every game's integrity or DRM requirements.

## Proposed experiment

1. Inventory the existing Android 14 x86_64 Google APIs payload, record source and
   hashes, and check package signatures, ABI, libraries, and permission dependencies.
   Exclude Play Store from the payload.
2. Add an opt-in extraction/injection workflow to the existing main scripts,
   following the NDK payload approach. Keep proprietary payloads outside Git.
   No `--with-gapps` option is implemented yet.
3. Build a disposable GApps stage with required AOSP dependencies restored and
   fresh sysbake. Use a separate persistent runtime context on Fedora.
4. Test boot, package registration, service stability, and persistence. Confirm
   that no Play Store package is installed. Test account sign-in only if required.
5. Install the same local game APK set in native and services-enabled stages;
   compare launch results and logcat. Supply required splits/assets. Restart the
   context and test its Google-services interactions and state persistence.
6. Classify remaining failures by dependency, licensing, integrity, or runtime
   behavior. Package the tested variant with the existing deploy script and
   validate on Steam Deck.

GApps should remain opt-in while these checks are unresolved. NDK translation
is independent: native x86_64 Google components do not eliminate the need for
translation when a downloaded game contains only ARM libraries.
