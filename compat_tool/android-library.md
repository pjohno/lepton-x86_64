# Android Library: design and maintenance notes

How the Android Library installs, updates and recovers sideloaded apps, and
why. The user-facing workflow is in the
[README](../README.md#manage-sideloaded-apps-with-android-library), and
recovery is in the
[installation guide](../INSTALL-STEAM-DECK.md#android-library-profiles-and-recovery).

| Code | Responsibility |
| --- | --- |
| `tools/leptron` | Command line: argument parsing, messages, `info` and `status` reports |
| `tools/android_library.py` | Library storage: location, metadata, staging, the `.update` journal |
| `tools/android-library-runtime` | Called by the launcher: launch decisions, Android package-manager installs, receipts |
| `tools/lepton_steam.py` | Reading Steam shortcuts (shared with `lepton-add-game`) |
| `liblepton/android_library.sh` | Launcher integration: every managed-route decision goes through its functions |
| `liblepton/ndk_auxv/runtime.sh` | NDK preparation for both routes |
| `liblepton/apk_extractor` | `apk-info-extractor --json`: package metadata without the Android SDK |

## Two installation routes

| Route | Used for | How the app is installed | Who updates it |
| --- | --- | --- | --- |
| **Managed** | APKs imported into the Android Library | Android's package manager, natively, into `/data/app` in the profile | `leptron update`; Android verifies and keeps data |
| **Legacy (baked overlay)** | Other sideloaded APKs, Steam-distributed games, every existing profile | Valve's route: installed once, code moved into the `app_overlay` and bind-mounted back | Replaced when the APK file changes |
| **Google Play** | Apps installed from the Play Store in the shared Google Play profile | The Play Store | The Play Store |

Managed installation is the intended route for new sideloaded apps. The
legacy route stays supported. Steam-distributed games need it, and existing
profiles depend on it. The launcher decides the route once, in
`lepton_library_resolve`. Everywhere else it asks `lepton_managed_app` and
calls `lepton_managed_*` (profile receipt, mounts, launch rc, install). There
are no `LEPTON_MANAGED_*` tests elsewhere.

What differs in a managed launch:

- No app overlay and no `/data/steam_app` mount. Android owns `/data/app`.
- `is_app_baked` is false. The baked-APK identity checks don't apply; the
  profile receipt `lepton-managed.json` replaces them.
- OBBs are bound read-only at `/lepton/managed-obb` and linked from
  `Android/obb/PACKAGE`.
- After `app_baked=1`, the launch rc mounts the enabled Vulkan layers.
- `LEPTON_RESET_APP_DATA` is refused, and an unmanaged launch refuses a
  profile with a receipt.

**Profile conversion (future work).** Converting a legacy profile would mean
installing natively over an app whose `packages.xml` code path exists only
through the overlay bind mount. If that mount were missing while Android
scanned packages, Android would treat the package as removed and could
delete its data. A safe conversion needs a launch that keeps the legacy
mount until a native `install -r` has committed, plus a backup step. It is
deferred, and the library never adopts a legacy profile: `leptron install` of
an APK you already play creates a separate profile.

## Library layout

```text
ROOT/.lepton-library.json        identity marker, matched against the settings file
ROOT/Container Storage/          common folder
ROOT/PACKAGE/PACKAGE.apk|.apkm   active APK, the stable Steam shortcut target
ROOT/PACKAGE/config.json         active metadata and the user's per-app settings
ROOT/PACKAGE/obb/                versioned OBB files
ROOT/PACKAGE/.candidate/         staged update (APK, metadata, staged OBBs, rejected.json)
ROOT/PACKAGE/.previous/          APK replaced by the latest promotion
ROOT/PACKAGE/.update/            journal of an unfinished file replacement
ROOT/PACKAGE/.profiles/          one receipt per Android profile, for info
```

Each profile also holds `baked/lepton-managed.json`. It records what Android
verified (`installed`), an installation in progress (`pending`, with the
package-manager `session` and the code directory it started from), and, for
NDK preparation, `lepton-ndk-code` and `lepton-ndk-mode`.

The library root takes a shared `flock` for each launch and an exclusive one
for CLI changes, so `update` waits until managed apps are closed. A
per-package `flock` serialises launches of the same app in two profiles,
because a launch can promote a staged update.

## Metadata without the Android SDK

`apk-info-extractor --json` reads the binary manifest. It reports package,
split, versionCode, versionCodeMajor, long version code, version name,
minimum/target SDK, a literal label, the launcher activity,
`extractNativeLibs` and the archive's ABIs. Split APKs without `<uses-sdk>`
or a launcher are accepted. Labels given as resource references are not
resolved; the package ID is used instead (`add-to-steam --name` overrides
it). Bundles refuse an extractor without `--json`.

**Version codes.** Android 14 composes `(long) versionCodeMajor << 32 |
(versionCode & 0xffffffff)` (`PackageInfo.composeLongVersionCode`). The low
word is unsigned, the major is signed, and `checkDowngrade` compares the
signed 64-bit result. `dumpsys package` prints that long value. The library
stores and compares the same signed value, so `versionCode="-1"` is
4294967295 and a negative major gives a negative code. Fixtures in
`apk_extractor/test/Version*.xml` were compiled with `aapt2`. Also checked
on import: a minimum SDK above the bundled image's API level, preview
codenames, damaged or truncated archives, unsafe entry names, and consistent
package/version (and signers, when checked) across APKM members.

## Signatures: Android decides

Android's package manager is authoritative for signatures, signing-key
rotation, replacement and downgrades. Options considered:

| Option | Outcome |
| --- | --- |
| Bundle a standalone verifier | Not done. A maintained one would have to be built and shipped as another binary (the Java `apksigner` needs a JRE, which SteamOS lacks), and it would only repeat Android's check |
| Optional `apksigner` | Kept. `LEPTON_APKSIGNER` (a path, or `none`), else `LEPTON_ANDROID_BUILD_TOOLS/apksigner`, else `apksigner` on `PATH`. A failed verification is refused. Output without signer digests in a known format is an error, never "unsigned". `info` reports "checked by apksigner" |
| Lineage parsing on the host | Removed. Whether a new key is a valid rotation is Android's decision |
| Defer to Android | The default. `info` says "not checked on the host" until a profile has installed the APK ("installed and verified by Android") |

Without a host check, safety comes from staging. An update is never the
active APK until Android has accepted it.

## Update lifecycle

```text
import ─────────────► active APK (never yet installed: "not yet installed by Android")
update ─────────────► .candidate/            (replaces an earlier unaccepted candidate)
launch or apply, in each profile:
  Android installs the candidate ─► accepted ─► promote: active → .previous, candidate → active
                                  └► refused (Failure [...]) ─► rejected.json; launch stops once;
                                                               later launches play the installed version
  transient failure (timeout, interruption) ─► candidate kept and retried next launch
discard ────────────► candidate removed (active and installed apps unchanged)
restore-apk ────────► .previous → active (profiles that are newer keep their version)
```

Properties this keeps:

- The active APK is the original import, or a version Android installed. Any
  number of unverified updates replace only one another.
- Android does every replacement as `install -r` in a session. Lepton never
  uninstalls, clears data or downgrades. A profile newer than the library
  (after `restore-apk`) keeps its version and launches with a warning.
- Each profile updates independently, on its own next launch. `info`
  reports each profile's last verified version, using Steam shortcuts found
  by their APK target (so renamed ones too).
- Promotion and restore use the `.update` journal (`commit_update`). It is
  idempotent and runs again automatically on the next launch or with
  `recover`. App settings come from the active `config.json` at commit time,
  so edits made after staging survive.
- The installer streams the selected APKs from the library file into the
  session and checks each one's SHA-256 on the way. It then compares what
  Android installed (APK hashes and long version code) with the target
  before recording it.

Interruptions and what the next launch does:

| Interrupted | Next launch |
| --- | --- |
| Staging an update | Active APK untouched; the candidate is absent or complete |
| Upload into the package-manager session | Session abandoned; installed code matches `installed`; installs again |
| After Android's commit, before the receipt | Installed code matches `pending`, so it is recorded, not repeated. For an identical reinstall, a new code directory is the evidence |
| After the receipt, before promotion | Installed already matches the candidate; promotes without installing |
| Promotion or restore file replacement | `.update` journal finished first |
| Library drive missing | Managed launch stops before touching the profile; see below |

These are covered by `tests/test-android-library.py` with a fake package
manager. Interruption during upload and refusals by Android were also run on
a real NDK bundle.

## Native code and NDK translation

The legacy route prepares ARM64 games in `ndk_prepare_installed_app` after
installing into the app overlay. Managed apps bypass that, so the runtime
reports Android's installed code directory and an identity of the installed
code, and `ndk_prepare_managed_app` then:

- patches the SEVL/SEV/WFE hints in `DATA_OVERLAY/app/.../lib/arm64/*.so` (the
  profile's `/data` upperdir, owned by the host user) before the app starts;
- records the translator mode with the code identity, and re-evaluates both
  when the code changes. Android uses a new directory for every
  installation, even of identical APKs, so the directory is part of the
  identity. An early-exit fallback to the light mode lasts until then;
- leaves APKs alone. Android doesn't re-verify extracted libraries, and the
  installed-APK hashes Lepton compares are of the APK files only;
- records nothing without the reviewed translator, so a later NDK bundle
  still prepares the code.

The zygote's translator mode is set before Android boots. A launch that will
install new code therefore uses the light mode rather than the old code's
choice (`lepton_managed_install_pending`). Apps with
`extractNativeLibs=false` (for example AAAAXY) have nothing to patch and keep
the light mode, as on the legacy route. Configuration splits install into the
same `lib/arm64`.

### Legacy `cmd` wrapper operations

The managed installer calls `cmd_real` directly, because the wrapper's
post-install step moves code into the legacy overlay. What each wrapper step
means for managed installs:

| Legacy step | Managed route |
| --- | --- |
| Grant runtime permissions | `install-create -g`: requested runtime permissions are granted at install, as `adb install -g` does for unmanaged installs. This is a Lepton compatibility choice, so games don't stop at permission prompts; Play Store installs keep Android's normal prompts |
| `compile -m speed-profile` | Not repeated. Android 14 runs dexopt for the install reason during the session |
| Unmount / remount Vulkan layers around installs | Layers are mounted only after `app_baked=1`, after the managed install, so nothing is mounted in an old code directory during replacement |
| OBB link to the overlay | Replaced by the read-only `/lepton/managed-obb` link; an occupied OBB path stops the launch |
| Move code into `/data/steam_app` and bind-mount | Not applicable: Android owns `/data/app` |
| Copy `steam_appid.txt`, `UECommandLine.txt` | Steam-distributed games only |

## Container Storage

`ROOT/Container Storage` is a real directory, shared through the
shared-folder mechanism (`lepton_library_storage_entry`) at
`/lepton/shared/Container Storage`, and linked as `Container Storage` in the
profile's shared storage. It is independent of the five optional folders and
stays shared with `LEPTON_SHARED_FOLDERS=none`. Nested symlinks inside it
aren't followed or mounted.

| Situation | Behaviour |
| --- | --- |
| Managed APK, library available | Launches normally |
| Managed APK, library unavailable | Stops with a message (and a popup in Gaming Mode); nothing changed |
| Unmanaged APK, Steam game or Google Play, library unavailable | Launches without Container Storage and logs why |
| Library not configured | Existing Lepton behaviour |
| Settings file damaged | Warning in the log; unrelated launches continue |

The configured location (`LEPTON_LIBRARY_CONFIGURED`) is read separately from
the availability check (`LEPTON_LIBRARY_ROOT`, set only when the directory,
its Container Storage and the identity marker are all present). Nothing is
created at a missing location, and an empty mount point is not accepted as
the library.

Other cases:

- **A profile with its own real `Container Storage` folder.** Empty, it is
  replaced by the link. With files, it is kept, not linked, and the log says
  so.
- **Library unavailable, then back.** While it is unavailable, Lepton removes
  its own link and nothing is mounted. Apps can't write into a stand-in. The
  link returns on the next launch with the library.
- **Removing or renaming an app.** `uninstall` deletes only `ROOT/PACKAGE`.
  Container Storage and profiles are kept.
- **Changing the association.** `leptron forget` removes the settings
  file only. `init --path` adopts an existing library by its marker.

## Launcher changes outside the library

Each has a focused test:

| Change | Why | Prerequisite for the library? |
| --- | --- | --- |
| `podman_attach` runs Podman with a controlled environment (`test-podman-attach-env.sh`) | `env -i PATH=<Android path>` gave Podman Android's PATH, no `HOME`/`XDG_*`/`CONTAINERS_*`, needed `which`, and never passed the PATH into the container. Removing `env -i` entirely exposed Podman to Steam's `LD_PRELOAD` and runtime paths. Now Podman gets its own settings and the container gets Android's PATH with `--env` | No; a general fix |
| `/lepton/profile-external` alias for profiles under `/mnt` and `/tmp` (`test-shared-folders.sh`) | Android's init mounts tmpfs over both, so a profile there (such as a secondary Steam library on a `/mnt` drive) had dangling shared storage. Previously aliased only when a library was configured | No; needed for Container Storage to be reachable in such profiles |
| Streamed install when Android can't read the Steam APK path (`test-steamlaunch-install-route.sh`) | Valve's `pm install` shortcut fails for APKs under a hidden `/mnt` library | No; legacy route |
| Vulkan layers remounted after a failed legacy install (`system/bin/cmd`) | The wrapper unmounts every app's layers before installing; a failed install left them unmounted | No; legacy route |
| Shared APKM unpacking (`android-library-runtime unpack`) | One implementation of the ABI split choice, used by legacy APKM launches and the library's split selection | Shared code |
