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

## Local desktop direct Wayland

Both the transferred bundle installer and `install-local.sh` detect Fedora,
write a persistent `local-desktop` profile and bypass nested Gamescope by default. Use `%command%` for the direct test or
`LEPTON_LOCAL_USE_GAMESCOPE=1 %command%` for the windowed fallback. Existing
unmarked tools keep their previous routing until replaced; replacement now
reselects the profile for the current host.
See [profile, deployment, rollback and geometry limitations](compat_tool/LOCAL-DESKTOP.md).
Direct routing is a new Fedora test version; rendering, redraw, scaling, pointer
alignment, focus and exit/relaunch need manual validation before release.

Phase 2 adds a local-only native fullscreen request and physical/logical scale
negotiation through an isolated hwcomposer patch. Use
`LEPTON_LOCAL_FULLSCREEN=0 %command%` to compare the original direct geometry.
The existing Gamescope fallback stays windowed. See the local routing document
for the component-only build, read-only overlay deployment and runtime commands.
A fresh Phase 1 baseline on 2026-11-11 passed without the issue #8 redraw/focus
freeze; do not interpret that as proof that all games or Phase 2 are validated.

## Testing the Steam Gamescope bridge

The desktop mouse fix changes the bridge script only; an existing installed
tool supplies the same Android rootfs, sysbake, ADB and game profile. The
repository bridge may be newer than an installed bundle's bridge, including
its window sizing and error dialogs. Use a per-launch override to test it
without replacing installed files or rebuilding Android.

On Fedora, save and stop the game, then run from this repository:

```bash
realpath compat_tool/tools/lepton-gamescope-bridge
```

In the existing Steam shortcut, keep the selected compatibility tool and
replace its Launch Options with the printed absolute path in quotes, followed
by `%command%`:

```text
"/absolute/path/to/lepton-x86_64/compat_tool/tools/lepton-gamescope-bridge" %command%
```

The candidate bridge sets `LEPTON_BRIDGE_ACTIVE=1`, so the installed tool's
entry point runs inside it without starting a second bridge. Replace earlier
diagnostic Launch Options rather than appending: remove any temporary
Gamescope `PATH` wrapper and `LEPTON_ISSUE9_TOUCH_MODE`, which can mask the new
bridge's arguments. An unset `LEPTON_DESKTOP_TOUCH_MODE` now uses mode 1 (left-click emulation).

For a controlled 1280×800 window and touch-passthrough comparison, use:

```text
LEPTON_RESOLUTION=1280x800 LEPTON_DESKTOP_TOUCH_MODE=4 "/absolute/path/to/lepton-x86_64/compat_tool/tools/lepton-gamescope-bridge" %command%
```

Remove `LEPTON_DESKTOP_TOUCH_MODE=4` for the mode-1 default. Experimental direct
Wayland remains available by setting `LEPTON_DESKTOP_DIRECT=1` before the
candidate bridge path instead; it ignores the Gamescope touch-mode setting.

For Steam Deck testing, copy only the candidate bridge to a separate file
(substitute the Deck's SSH address):

```bash
scp compat_tool/tools/lepton-gamescope-bridge deck@DECK_IP:/home/deck/lepton-gamescope-bridge-issue9
ssh deck@DECK_IP 'chmod 755 /home/deck/lepton-gamescope-bridge-issue9'
```

Use `/home/deck/lepton-gamescope-bridge-issue9 %command%` as the existing
game's Launch Options. In Desktop Mode, compare default mode 1 against
`LEPTON_DESKTOP_TOUCH_MODE=4 /home/deck/lepton-gamescope-bridge-issue9 %command%`.
Keep the same game, window size, scaling, controller layout and Steam settings.
Test physical mouse movement/clicks, keyboard, Alt-Tab/refocus, and separately
the actual touchscreen's finger taps and drags. A touchpad acting as a mouse
or Android-injected touch does not validate physical touchscreen forwarding.
Deck tests confirm mode 1 supports mouse and single-touch taps/drags without
native multitouch. Mode 0 provides pointer-only compatibility; mode 4 supports
native multitouch but can reproduce the mouse failure. Gamescope's upstream
nested Wayland touch support is another dependency; record the installed
version and touch results rather than assuming they work.

Also check Gaming Mode's existing touch/controller behavior with the candidate
bridge: its SDL/X11 command defaults to touch mode 4 even if the desktop override
is present. Keep issue #9 open for review and remaining compatibility testing. To undo candidate deployment, stop the game and restore the
shortcut's previous Launch Options; the installed tool and game data have not
been replaced. The separate candidate file can then be removed.

### Fedora mode-1 validation

On 2026-11-10, the installed `lepton_x86_64_v0_1_1_alpha` tool's bridge was
updated for the existing 2048 Steam shortcut (AppID `2826395812`). Steam's
`logs/console-linux.txt` recorded `--default-touch-mode 1` and a windowed
1472×920 Desktop Mode launch at 14:59:04. Android also reported 1472×920.
The user tested mouse movement/clicks, keyboard, window focus and game
interaction and reported no failures. Physical Fedora touchscreen input and
native multitouch were not validated by this test. Gaming Mode retains its
mode-4 default; no rootfs, game data or Steam configuration was changed.

### Replacing only the installed Steam Deck bridge

Save and stop the game normally before replacing its bridge. This updates only
one script: no Android rebuild, Gamescope package change, tool reinstallation,
game-data reset or compatibility-prefix change is needed. The selected tool
may differ from the repository version; verify its registration first. These
commands do not change any Steam shortcut.

From the repository on Fedora, copy the candidate (replace `DECK_IP`):

```bash
scp compat_tool/tools/lepton-gamescope-bridge deck@DECK_IP:/home/deck/lepton-gamescope-bridge-candidate
```

On the Deck, open Konsole in Desktop Mode. Check the game's selected
compatibility tool in Steam Properties → Compatibility. List registrations
and match its display name to the corresponding VDF file:

```bash
grep -H -E '"(display_name|install_path)"' "$HOME/.local/share/Steam/compatibilitytools.d/"*.vdf
```

Paste the matching VDF's absolute path when prompted below. The script reads
its registered install path, verifies the entry point and bridge, validates the
candidate, makes a unique backup preserving permissions, then replaces only
the bridge using a temporary file in the same directory. An error stops the
operation. Do not proceed if the displayed registration is not the selected
tool. Nonstandard registrations need their actual path supplied instead.

```bash
(
    set -euo pipefail
    read -r -p 'Selected tool registration (absolute VDF path): ' REGISTRATION
    cat -- "$REGISTRATION"
    TOOL=$(python3 - "$REGISTRATION" <<'PYTHON'
import json, re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
paths = re.findall(r'"install_path"\s*("(?:[^"\\]|\\.)*")', text)
if len(paths) != 1:
    raise SystemExit('Expected exactly one registered install_path; inspect registration manually')
print(json.loads(paths[0]))
PYTHON
    )
    test -x "$TOOL/lepton-x86_64-entry"
    BRIDGE="$TOOL/tools/lepton-gamescope-bridge"
    test -f "$BRIDGE" && test -x "$BRIDGE" && test ! -L "$BRIDGE"
    printf 'Bridge to replace: %s\n' "$BRIDGE"
    read -r -p 'Does this match the selected Steam tool? Type yes: ' CONFIRM
    test "$CONFIRM" = yes
    CANDIDATE="$HOME/lepton-gamescope-bridge-candidate"
    bash -n "$CANDIDATE"
    grep -n 'LEPTON_GAMING_TOUCH_MODE' "$CANDIDATE"
    BACKUP="${BRIDGE}.before-gaming-touch-$(date +%Y%m%dT%H%M%S)-$$"
    cp -p -- "$BRIDGE" "$BACKUP"
    cmp -- "$BRIDGE" "$BACKUP"
    printf 'Backup for rollback: %s\n' "$BACKUP"
    TEMP=$(mktemp "$TOOL/tools/.lepton-gamescope-bridge.XXXXXX")
    trap 'rm -f -- "$TEMP"' EXIT
    cat -- "$CANDIDATE" > "$TEMP"
    chmod --reference="$BRIDGE" "$TEMP"
    test -x "$TEMP"
    bash -n "$TEMP"
    mv -f -- "$TEMP" "$BRIDGE"
    cmp -- "$CANDIDATE" "$BRIDGE"
    printf 'Installed bridge: %s\n' "$BRIDGE"
)
```

In Gaming Mode, use the [three launch options](INSTALL-STEAM-DECK.md#gaming-mode-touch-experiments)
to compare the same installed game. Earlier candidate-path or Gamescope `PATH`
wrappers in Launch Options would bypass or mask the installed bridge; use the
listed option by itself for this comparison. Check the selected mode in
`~/.steam/steam/logs/lepton-steamlaunch-APPID.log`. Test a physical mouse,
Steam Input mouse emulation and the actual touchscreen separately. A touchpad
emulating a mouse does not validate native touchscreen delivery.

To roll back, stop the game and run the following with the two exact paths
printed above; this restores the backed-up bridge and its executable mode:

```bash
cp -p -- '/absolute/path/printed/as/Backup for rollback' '/absolute/path/printed/as/Installed bridge'
```

The repository source and installed tool remain separate; later bundle updates
may replace this local bridge patch. Keep the backup until testing is complete.

## Optional ARM64 translation

NDK deployment is **opt-in**. Native x86_64 is the default because the translator
comes from a separately obtained Google image and game compatibility is still
experimental. Extract a local payload using
`image-14/scripts/internal/extract-ndk-translation.sh`; see that script's `--help`.

Once images have been built and packaged, assemble a NEW NDK-enabled stage:

```bash
source .build-env
PAYLOAD="$LEPTON_OUTPUT_DIR/google-inputs/ndk-translation/payload"
STAGE="$LEPTON_OUTPUT_DIR/stages/ndk"

bash image-14/scripts/internal/deploy-compat-x86_64.sh --check \
  --stage-dir "$STAGE" --with-ndk --ndk-payload "$PAYLOAD"
bash image-14/scripts/internal/deploy-compat-x86_64.sh --execute \
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

The tools are organized under `tests/runtime/`. For fast workflow regressions
without Android or network access, run `bash image-14/tests/run-workflow-tests.sh`.

The examples below use an existing stage from the development machine. Substitute
another complete stage as needed. Build the local shim when testing this
checkout's scripts against an older matching NDK stage:

```bash
source .build-env
STAGE="$LEPTON_OUTPUT_DIR/stages/ndk-test"
bash compat_tool/liblepton/ndk_auxv/build.sh --aosp "$LEPTON_OUTPUT_DIR/aosp"

bash tests/runtime/run-apk.sh --stage-dir "$STAGE" --runtime-dir compat_tool \
  --apk "$PWD/apks/AAAAXY-arm64.apk" --expect-abi arm64-v8a --app --check

bash tests/runtime/run-apk.sh --stage-dir "$STAGE" --runtime-dir compat_tool \
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
  bash tests/runtime/run-apk.sh --stage-dir "$STAGE" --runtime-dir compat_tool \
    --apk "$PWD/apks/SuperTuxKart-1.4.apk" --expect-abi "$abi" --app \
    --rendering amd --display desktop --seconds 90 --execute
done
```

Results include continuous `app-logcat.log`, boot logs, install/activity output,
package/activity details, native stacks, and `screen.png` when capture succeeds.
A surviving process alone does not prove gameplay, controls or sound work.

### APKMirror split bundles

App mode accepts `.apkm` as well as a single `.apk`. For example:

```bash
source .build-env
bash tests/runtime/run-apk.sh \
  --stage-dir "$LEPTON_OUTPUT_DIR/stages/ndk-test" \
  --runtime-dir compat_tool --apk "$PWD/apks/Kingdom.apkm" \
  --expect-abi arm64-v8a --app --rendering amd --display desktop \
  --seconds 180 --execute
```

The runner extracts the base APK, selected ABI split and feature/asset splits,
then installs them together in an Android package-manager session. Files remain
under the private workspace's `apks/`. Additional evidence includes
`install-session.log`, `apk-paths.txt`, `installed-packages-before.txt` and
`properties.txt`. Preflight temporarily extracts only base and ABI metadata.

Kingdom 7.10.002 (version code 218152), tested without GApps on 2 November 2026:

- Installed base, `split_config.arm64_v8a.apk` and `split_UnityDataAssetPack.apk`;
  package manager confirmed `primaryCpuAbi=arm64-v8a`.
- Initial testing exposed multiline `pm path` handling in Lepton's install hook
  and OBB helper. Both now select the base APK's directory explicitly.
- After that fix, startup still aborted with
  `JNI DETECTED ERROR IN APPLICATION: java_object == null`, in `GetObjectClass`.
  The log immediately preceding it reports `No service published for: locale`.
  Lepton's framework patch disables `LocaleManagerService`; causation remains
  unproven. Google-services and missing-Play-Store warnings occur as well and
  do not alone establish the fatal dependency.
- No gameplay or successful login was observed. The runtime package inventory
  confirmed GMS, GSF and Play Store were absent. Restoring the locale service is
  a candidate follow-up before treating this as solely a GApps problem.

APKM SHA-256: `8bb748a916db6988c209780524f60aa214001c5068e1f2486285133f9f1da0cd`.
Evidence after the split-path fix: `.jni-smoke-work.U9nAuY0K` beneath the NDK v2
stage. APK files remain local and ignored by Git.

### Kingdom locale-service experiment

The follow-up used `tests/runtime/build-locale-services.sh` to re-enable only
`LocaleManagerService` in a read-only SystemServer.java source override. The
source file's SHA-256 remained unchanged. The script also rebuilds the baseline
after saving the experimental jar, avoiding stale experimental build-cache
outputs. The baseline jar matched its original hash after restoration.

`tests/runtime/stage-services-test.sh` assembled a separate
`native-bridge-research/lepton-locale-test-v2` stage, checked the baseline jar,
installed the experimental jar, removed only services preoptimization artifacts,
and copied existing host tools. Fresh sysbake succeeded using software rendering.
The packaged working NDK stage was not modified. GApps were not installed.

Kingdom's ARM64 test on this stage registered `locale: [android.app.ILocaleManager]`.
The missing-locale warning and null-object JNI abort did not recur. Startup
progressed to a later `SIGILL` after roughly four seconds. That tombstone reports
no useful instruction address (zero registers and a single unknown frame), so
neither an unsupported translated instruction nor game environment detection is
established as the cause. Missing Google-services/Play-Store warnings remain;
their necessity for reaching gameplay is still unresolved.

The locale change remains experimental, outside the standard framework patch set.
Evidence: `lepton-locale-test-v2/.jni-smoke-work.LoJ8NSAE`, including
`services.txt`, `installed-packages-before.txt`, `package.txt`, `app-logcat.log`
and `native-stacks.txt`. Build evidence is under `locale-service-test-v1`.
AAAAXY's ARM64 regression run on the locale-enabled stage passed the 20-second
process-survival and installed-ABI checks (`.jni-smoke-work.ke0W7GTJ`).

| services.jar | SHA-256 |
| --- | --- |
| Baseline | `71af177e8921251cb60c5c5f28dff1e6846fbb564fde9e78c576fbf33ef75ed4` |
| Locale enabled | `6a3a4ade6e77894673af77daea35a4d20b0854b1a710bd0c4d549ee826dbfdd4` |

### Optional Google Play experiment and persistent registration

A final experiment on 2 November 2026 added the genuine GMS and GSF packages
from the local Google APIs image, then a matching Google Play payload from
Google's official Android 14 x86_64 revision 14 image. The latter archive was
verified against the SHA-1 in Google's repository metadata:
`01d32617fd1937e540faf8731d70cf50e35af854`.

Findings and fixes:

- The initial container had no IPv4 address or default network. Android netd was
  unable to write required sysctls. The opt-in `--network-sysctls` test option
  enabled IPv4 provisioning, a validated default network, and Google check-in.
- Services-only mode registered GMS and GSF, but Kingdom's Play Games SDK reported
  `SERVICE_INVALID` with explicit missing-Play-Store warnings. The Store package
  was then included with the user's approval as a dependency; game installation
  continued to use local APKs.
- GMS repeatedly crashed on a missing CrossProfileAppsService. A services.jar
  experiment restoring that service alongside LocaleManagerService removed the
  observed crash loop. The user then successfully signed into Google.
- The user registered the persistent profile's GSF Android ID. The same ID
  survived framework replacement and repeated boots. After the install/play run,
  a read-only snapshot check confirmed one saved Google account. No account
  names or credentials are part of these notes.
- Guest sqlite3 aborts on ICU initialization when invoked directly through Podman
  exec. Its repeated lookup was stopped and replaced with host-side read-only
  SQLite via `read-gsf-id.py`; it must not be used as a polling command.
- `--profile` now separates one-time setup/registration from install/play. The
  default disposable runner still accepts reinstalls. A second AAAAXY launch
  with the same profile passed and explicitly skipped package installation.

The final Kingdom test used `lepton-google-play-test-v2/.runtime-profile.kingdom`:
GMS, GSF, Play Store, validated networking, locale and cross-profile services,
registered GSF identity, and a saved Google account. Kingdom installed all ARM64
splits and still exited with `SIGILL` before gameplay. The previous JNI abort
and missing-Store warnings were absent. The tombstone again had no useful
instruction address, so the remaining native/translation/environment failure is
unresolved. GApps and sign-in are not by themselves a fix for this game.

The Google-enabled services.jar hash is
`95b2d03af5a723b1fa4bb164ee47fc3e4eede5f5cc02539ed68c4667ce903fad`.
Its build evidence is under `native-bridge-research/google-framework-test-v1`;
the shared incremental build was restored to its original baseline afterward.
The working NDK stage and default Android framework patch set remain unchanged.
See [runtime test instructions](tests/runtime/README.md) for the two-phase commands.

Omit `--app` for the purpose-built JNI smoke APK, which must return
`LEPTON_JNI_SMOKE_PASS value=42`. `tests/runtime/build-jni-smoke.sh --help` describes
building either ABI from an existing Android 14 checkout without an image rebuild.

## Crossy Road APKM experiment

Tested local `apks/crossyroad.apkm`: Crossy Road 7.14.2, version code 263670,
package `com.yodo1.crossyroad`, Unity 6000.3.12f1, ARM64. Bundle SHA-256:
`ed7076af613c32fd0b444a7ec2dbe5264c247534455526f8c0695ae7f3253885`.

The install hook's fallback previously treated `uid:` fields as package names.
The runner now sets `lepton.active_app_id` before installing, and the fallback
reads package names without UID tokens. Its misspelled property write was also
corrected. The persistent `crossyroad` profile successfully reused its installed
APK set on the next launch.

The first run reached Unity, then the NDK bridge rejected `SEVL` (`0xd50320bf`)
in both UnityMain and Loading.Preload. The guarded shim now handles the event
hints SEVL/SEV/WFE without sleeping; unit tests check unchanged registers and PC
advancement, and leave WFI and memory barriers unhandled. AOSP LLVM assembly and
disassembly confirmed the instruction encodings.

With the updated shim and the Google-enabled v2 stage, the unsupported-instruction
failure disappeared, followed by a new `SIGABRT`: `stack corruption detected
(-fstack-protector)` on UnityMain. Gameplay was not reached. Google login and
registration were not requested for this separate profile; the signed-in Kingdom
profile was preserved. Evidence is in `.runtime-profile.crossyroad`, including
`event-hints-logcat.log` and `event-hints-native-stacks.txt`.

The same bundle and updated shim on the known-working **non-GApps**
`lepton-ndk-test-v2` stage survived a 60-second run and rendered the age-entry
screen. After the user entered age, the game stayed alive with a blank screen.
Logcat identified `Firebase modules failed to initialize: messaging (missing
dependency)` in `BootController.Awake`, with explicit missing-Play-Store warnings.
Thus reaching age entry did not establish gameplay compatibility without GApps.
The Google-enabled retry again hit the stack-protector abort before age entry.
This comparison also changes the framework and profile, so it does not isolate
Google services as the cause of the other stage's stack-protector abort.
A controlled test in the Google-enabled Crossy Road profile temporarily disabled
GMS, GSF and Store for user 0. The same UnityMain stack-protector abort persisted,
so it does not require those Google packages to be running. All three packages
were restored to their default enabled state afterward. The signed-in Kingdom
profile was never modified. Evidence: `google-retry-logcat.log` and
`google-disabled-logcat.log` in the Google stage's Crossy Road profile.
The bridge and ARM64 libc hashes match between the two stages; the framework,
Google payload/configuration and profile remain differences to investigate.
The ARM64 JNI regression
passed (`LEPTON_JNI_SMOKE_PASS value=42`) after the shim change, and the complete
host workflow regression suite passed.

Reopen the retained non-GApps installation on Fedora:

```bash
source .build-env
bash tests/runtime/run-apk.sh \
  --stage-dir "$LEPTON_OUTPUT_DIR/stages/ndk-test" \
  --runtime-dir compat_tool --apk "$PWD/apks/crossyroad.apkm" \
  --app --expect-abi arm64-v8a --profile crossyroad \
  --rendering amd --display desktop --seconds 900 --execute
```

## Native Google Play Games control

Local bundle `apks/com.google.android.play.games.apkm`: version 2026.10.70836,
code 708362480, package `com.google.android.play.games`, x86_64, minimum API 32.
SHA-256: `23829b72ee769108987160d020e1ec9c6d5bd2f474de3e09c653da87eae64f1a`.
Its native ABI split contains x86_64 libframesequence/libvpx libraries and no ARM
libraries. The installed package reports `primaryCpuAbi=x86_64`, no secondary ABI.

The APK reader previously ignored launcher activity aliases. It now checks both
activities and aliases, skipping ones explicitly disabled by default. The runner
uses the selected runtime checkout's reader so an updated reader can be tested
without restaging Android. The original extractor fixture outputs were unchanged;
a new original binary-manifest fixture covers an enabled launcher alias following
a disabled alias. Run its regression with:

```bash
cargo test --offline --release --locked \
  --manifest-path compat_tool/liblepton/apk_extractor/Cargo.toml
```

On `lepton-google-play-test-v2`, profile `playgames-native`, the app reached
Google sign-in without the Unity crash. The user completed sign-in and confirmed
the Play Games home screen. Android's account service reports one saved account
(count only; no names or credentials recorded). Both Play Games and Play services
report primary ABI x86_64 and no secondary ABI. Play services updated from the
image's 23.18.18 to 26.42.31 (190800-1005867181) during this run. One background
GMS CancellationException occurred during startup, but subsequent sign-in and
home-screen navigation succeeded; no native SIGILL/SIGABRT was observed for Play
Games. Built-in gameplay remains to be verified. The bridge stays installed:
its library can be inherited
from zygote by a native app, so its presence in a process map alone does not mean
ARM code is being translated. The captured map had no ARM guest library paths.
The runner now saves `app-maps.txt` for subsequent ABI investigations.

## Android-first VIEW intents and browser testing

The native Play Games home screen worked but its Play controls silently did
nothing. This was a framework policy failure, not evidence of an absent WebView:
Valve's ActivityStarter interceptor returned START_SUCCESS for every ACTION_VIEW,
including explicit in-app game activities with empty/relative URLs. Logcat
recorded intercepted `logos/2010/pacman10-i.html` and GameSnacks URLs.

The production patch now defaults to Android routing. Legacy Steam forwarding
requires `LEPTON_FORWARD_WEB_INTENTS=true`, and even then applies only to
untargeted HTTP/HTTPS. Explicit game WebViews, relative assets, content URIs and
app-link callbacks remain inside Android. A standard deployment needs a rebuilt
framework for this policy; launcher changes alone cannot fix old images.

The disposable framework build `google-view-intents-test-v3` restores locale and
cross-profile services and fixes VIEW interception. Its services.jar SHA-256 is
`d82f1d0afa895cd849ad035fb7f07aaea1b961d02e46715844b09b87fa49b28e`.
The current native Play Games command adds:

```text
--services-jar "$LEPTON_OUTPUT_DIR/native-bridge-research/google-view-intents-test-v3/services-locale.jar"
--accept-runtime-update
```

The profile kept its saved account and installed APK set. After this change,
Snake's PrebundledWebGameActivity started and rendered. The user confirmed
playing with up/down/left/right keys. Mouse/touch gestures were not confirmed;
Android reports the Wayland pointer as MOUSE. Steam Deck touchscreen behavior
has not been tested. The older Waydroid fake-touch patch exists in the repository
but is not present in this prepared Android 14 ViewRootImpl; setting its property
alone would not enable that feature.

The matching downloaded Google Play image also supplied Chrome 113.0.5672.136
and TrichromeLibrary. Their APKs are ignored under `apks/`; both were installed
in this profile using the real package-manager command without rebinding the
game-code overlay. Chrome reports x86_64 and advertises CustomTabsConnectionService.
Chrome was selected as this test profile's browser role holder; a BROWSABLE
HTTPS intent resolves to Chrome's IntentDispatcher. Complete external OAuth
callback flows with Chrome still need testing. GApps staging now supports
`--with-browser` to include both matching APKs and x86_64 libraries.

The framework sources in the shared AOSP checkout were never edited. Baseline
sources were rebuilt and hash-checked, and the exact saved packaged services.jar
was restored (SHA-256 `71af177e8921251cb60c5c5f28dff1e6846fbb564fde9e78c576fbf33ef75ed4`).
ProtoLog's intentionally random generated class names prevent assuming rebuilt
DEX is byte-identical. The source finder now skips disposable research mounts
using their `.find-ignore` marker.

## Separate media decoding findings

The runtime's `debug.stagefright.ccodec=0` suppresses Codec2 even though the image
has only the Codec2 software store, with no OMX service. Default decoder listings
were empty and NuPlayer failed to create an audio/vorbis decoder. Enabling Codec2
restored the advertised decoders, but did not establish successful decoding.

The new offline media probe generates original AVC test-pattern and Vorbis-tone
assets, enumerates codecs, requires decoded output and checks video-surface
rendering. Its first run failed because the default linear allocator required
Android ION/system DMA heaps absent on this host. BLOB plus BUFFERQUEUE allocation
(pool mask 786432) got past input allocation, then AVC output failed in
C2AllocatorGralloc with `cstride=0` / `graphic view map failed 14`.

These remain explicit experiments via `--codec2` / `LEPTON_CODEC2=true`; default
media configuration is retained until the decode/render test passes. The two
failed probes are retained under the Google v2 stage as
`.jni-smoke-work.boSlnDmN` and `.jni-smoke-work.KtTNhnr1`. They expose a concrete
media-buffer problem relevant to the reported YouTube failure, but do not prove
that YouTube or protected-content playback is fixed. Snake's launch failure was
resolved separately by VIEW routing.

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

### Phase 2 native Wayland test (2026-11-11)

At KDE 125% on DP-1 (3440×1440 physical), Steam launched the local profile
with native fullscreen requested. 2048 reported a 3440×1440 Android surface;
the user confirmed the game covered the Plasma panels and input/redraw worked.
Normal exit retained the profile. The original rootfs was not replaced: the
test used a read-only overlay for the component-only hwcomposer build. The subsequent live session confirmed hwcomposer's acknowledged state:
`fullscreen=1 logical=2752x1152 buffer=3440x1440 scale=1.2500`.
Android `wm size`, DisplayManager and SurfaceFlinger agreed on 3440×1440.
Use `logcat -b all` to include the early hwcomposer configure diagnostics.
See [local desktop validation](compat_tool/LOCAL-DESKTOP.md#fedora-validation-record)
for the implementation, remaining hardware tests and diagnostic commands.
