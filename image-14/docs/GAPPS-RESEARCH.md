# Android 14 Google services investigation

Status: research only. GApps installation, account sign-in, Play Store downloads,
and games installed through Play Store have **not** been validated in Lepton.
The `feature/android14-gapps` branch starts from the NDK work merged into
`feature/ubuntu26-build-pipeline` at `08dd1d7`.

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
A matching Android 14 x86_64 Google Play emulator image is the preferred next
candidate for a complete payload; an Android 14 x86_64 GApps distribution is an
alternative. Compatibility with Lepton must be established in either case.
The existing Google APIs image can support initial services experiments, but
cannot alone provide the requested Store installation workflow.

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
  `DownloadProvider` and `DownloadProviderUi`. Restore the matching AOSP packages
  for the optional GApps variant and test DownloadManager before Store downloads.
  Other removed providers and disabled framework services need a dependency audit.
- Preserve Lepton's framework, Binder, UID, graphics, and container changes.
  Copying complete Google system/vendor partitions would replace those changes.
- Preserve Google APK signatures and supply matching permission configuration
  in the appropriate partitions. Check privileged grants and shared libraries
  from package-manager logs rather than granting all permissions indiscriminately.
- Audit AccountManager, jobs, networking, TLS/keystore, package installation, and
  services startup. Their compatibility is not established by a successful game
  launch using NDK translation.
- Lepton selects persistent data by runtime context and Steam compatibility data
  path (`compat_tool/liblepton/liblepton.sh`, `mounting.sh`). A game installed in
  the Store's context will not automatically appear in another game's context.
  First test Store and games in one persistent development context; then design
  Steam launch integration, including split APKs, asset downloads, and licensing.
- Waydroid documents [registering an uncertified installation's Android ID](https://docs.waydro.id/faq/google-play-certification).
  Whether Lepton can sign in must be tested. Successful sign-in would not by
  itself establish compatibility with every game's integrity or DRM requirements.

## Proposed experiment

1. Inventory a complete Android 14 x86_64 Google payload, record source and hashes,
   and check package signatures, ABI, libraries, and permission dependencies.
2. Add an opt-in extraction/injection workflow to the existing main scripts,
   following the NDK payload approach. Keep proprietary payloads outside Git.
   No `--with-gapps` option is implemented yet.
3. Build a disposable GApps stage with the required AOSP providers restored and
   fresh sysbake. Use a separate persistent runtime context on Fedora.
4. Test boot, package registration, service stability, DownloadManager, Store
   launch, and persistence before interactive account sign-in.
5. With manual sign-in, download a free game, verify installation and assets,
   launch it, restart the context, and test its Google-services interactions.
6. Integrate launching Store-installed packages through Steam, then package the
   tested variant with the existing deploy script and validate on Steam Deck.

GApps should remain opt-in while these checks are unresolved. NDK translation
is independent: native x86_64 Google components do not eliminate the need for
translation when a downloaded game contains only ARM libraries.
