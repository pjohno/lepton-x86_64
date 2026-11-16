# Customising a downloaded Lepton bundle

Two AOSP-free workflows start from a downloaded bundle:

- **Workflow A, customise Android:** base bundle → prepared stage → inject
  NDK/GApps/Widevine → fresh sysbake → new installable bundle.
- **Workflow B, compatible repackaging:** existing bundle → restored complete
  stage (its sysbake kept) → new installable bundle, with no Android rebuild
  and no new sysbake.

The downloaded bundle supplies the Android rootfs, launcher and precompiled
runtime tools. No AOSP checkout, Cargo, C compiler, Android compilation or large
source download is needed. `lepton-compare-bundles` verifies what changed.

Bundles you make here are **local builds**: unsigned, marked
`origin: lepton-customize`, and refused by the official release publisher.
Bundles containing Google components (NDK translation, GApps, Widevine) from
your own image are for **your personal use**; never present them as official
Google-free Lepton releases.

| Stage type (`STAGE.json` `state`) | Made by | Android changes | Sysbake |
| --- | --- | --- | --- |
| `prepared` | `lepton-customize --execute` | allowed (inject) | discarded; `sysbake_required: true` |
| `customized` | `lepton-customize inject` | done | `sysbake_required: true` |
| `baked` | `lepton-customize sysbake` | refused | fresh, validated, recorded |
| `restored-complete` | `lepton-customize restore` | refused | original from the archive, `sysbake_required: false` |

Only `baked` and `restored-complete` stages can be packaged. Both record digests
of the rootfs, sysbake and `sysbake.xattrs`; packaging refuses if any changed.

Run as an unprivileged user on a compatible **x86_64 Linux PC**, primarily Fedora or another glibc desktop.
SteamOS customisation is experimental and is not a supported mainstream flow.
No AOSP checkout, source repository, `.build-env`, compiler, Rust or Cargo is
needed. The staging command needs Python 3, `readelf` (binutils), Linux memfd
and glibc `renameat2` support. Signed releases also need `ssh-keygen` (OpenSSH).
It checks the host loader and shared-library symbol versions needed by the
packaged host executables. Podman, Android Binder and a compositor are not
needed for Stage 2; they are needed later for sysbake.

## Obtain the tool and verify the download

Download the base `.tar.gz`, its `.tar.gz.sha256` manifest, and its
`.tar.gz.sha256.sig` signature from the same official release. Preserve their
original filenames. The checksum manifest may also list the installer; the
installer and Google's ADB are not needed to create a stage.

Run `compat_tool/tools/lepton-customize` from a **previously verified** bundle,
keeping its `compat_tool/release-keys/allowed_signers` file alongside it. An
existing release-manager verified download can supply the bootstrap tool. If
bootstrapping manually, verify the manifest signature using an independently
trusted release key and the existing `lepton-release` identity and namespace,
then verify the archive checksum before running code from it. Do not treat a
key obtained from an unverified input archive as a new trust root.

For a bundle you have already verified, you can unpack only the bootstrap
tools (`lepton-customize`, its Python companions and `lepton-compare-bundles`)
and the release keys into a new directory:

```bash
mkdir -p ~/lepton-customize-bootstrap
tar -xzf ~/Downloads/lepton-x86_64-v0.2.0-alpha.tar.gz \
  -C ~/lepton-customize-bootstrap \
  ./compat_tool/tools ./compat_tool/release-keys
```

The command uses the same installed trust keys, OpenSSH signing identity and
namespace as `lepton-release-manager`. With trusted keys installed, a valid
manifest signature is mandatory; missing or invalid signatures fail. By
default it finds `CHECKSUM.sig`; `--signature FILE` selects an explicit file.
Without installed keys, unsigned inputs can be checked for integrity only,
with an explicit **authenticity NOT verified** message. A supplied signature
without trusted keys is rejected. SHA256 alone does not prove publisher
identity. Staging (`--check`/`--execute`) never downloads keys and never runs
programs from the input bundle; it only reads and validates it.

`lepton-customize inject` (Phase 3) is different: it runs the shell helpers in
the source stage's `tools/customize/`, which came from that bundle. Those
helpers are trusted exactly as far as the bundle was verified, so inject only
into stages made from a bundle you verified or built yourself.

Two explicit options cover bundles that were not signed by the release key:

- `--trusted-signers FILE` verifies the signature against your own OpenSSH
  `allowed_signers` file (identity `lepton-release`, namespace
  `lepton-release`) instead of the installed release keys, for example a local
  test key. A signature is still required.
- `--allow-unsigned` accepts a bundle **you built yourself** with
  `make-deck-bundle-x86_64.sh`, which does not sign its manifest. Only integrity
  (SHA256) is checked; a warning is printed and `source-bundle/SOURCE.json`
  records `"unsigned_override": true`. A signature that is supplied is still
  verified and must be valid.

The two options cannot be combined. `SOURCE.json` also records which trust root
verified a signature (`trust_root`).

## Create a stage

Create the destination's parent first. The destination itself must not exist,
and must be outside any installed or extracted Lepton compatibility tool.

```bash
mkdir -p ~/lepton-work

~/lepton-customize-bootstrap/compat_tool/tools/lepton-customize \
  --check \
  --bundle ~/Downloads/lepton-x86_64-v0.2.0-alpha.tar.gz \
  --checksum ~/Downloads/lepton-x86_64-v0.2.0-alpha.tar.gz.sha256 \
  --stage-dir ~/lepton-work/my-custom-stage

# Repeat with --execute to create the stage.
~/lepton-customize-bootstrap/compat_tool/tools/lepton-customize \
  --execute \
  --bundle ~/Downloads/lepton-x86_64-v0.2.0-alpha.tar.gz \
  --checksum ~/Downloads/lepton-x86_64-v0.2.0-alpha.tar.gz.sha256 \
  --stage-dir ~/lepton-work/my-custom-stage
```

`--check` validates without writing files, extracting the archive or running
bundle programs. `--execute` extracts into a private temporary sibling and
atomically publishes the stage without replacing an existing directory.
Handled interruptions and failures remove the temporary copy. A forced
`SIGKILL` or power loss may leave a `.lepton-customize-*` sibling to remove
manually; the destination is never published partially.

The source must be a new self-contained base bundle: Android 14/API 34,
x86_64-only ABIs, disabled native bridge, `format_version: 2`, `gapps: false`,
`ndk: false` and no Widevine (`widevine: false` or absent in older metadata). Incomplete/older bundles are refused. The precompiled NDK shim,
APK extractor and packaged inotify wrapper, executable and library are reused
byte-for-byte. There is no compilation and no ADB download.

## Inject optional components (Phase 3)

Start from a **clean Stage 2 prepared stage** and create a different output
stage. Select all desired components together; injecting into a stage whose
state is already `customized` is refused. Nothing edits the base stage, an
installed Lepton tool, Steam registration, the source ZIP or prepared inputs.
No Android code or bundled runtime utility is compiled. The original shim,
APK extractor and inotify tools are reused byte-for-byte. No ADB is needed.

Supply your own **Google Play Intel x86_64 Atom API 34 revision 14** emulator
image ZIP (`x86_64-34_r14.zip`, sometimes renamed with a Google Play suffix).
The SDK `source.properties` must identify revision 14, API 34, `x86_64` and
`google_apis_playstore`; the API and image flavour are checked as well.
Images are never downloaded automatically. Google-containing custom stages
and later bundles are intended for **your own use**, not official redistribution.
Checksums record the local Google source and detect changes; they do not
independently authenticate a Google download.

Phase 3 needs `bash`, Python 3, `readelf`, `rsync`, `debugfs` and normal checksum,
filesystem and text utilities. On Fedora, these generally come from `bash`,
`python3`, `binutils`, `rsync`, `e2fsprogs`, `coreutils`, `findutils`, `grep`,
`sed` and `gawk`. ZIP preparation additionally needs `unzip`, `sfdisk`
(`util-linux`) and `lpunpack`, a host logical-partition unpacker. `lpunpack` is not supplied in the
bundle; install it separately as a host utility. Prepared-input injection does
not need `lpunpack` or `sfdisk`. Widevine extraction needs `unzip` even with
prepared inputs. Missing dependencies produce command/package guidance.
Podman, a compositor and BinderFS are only needed for sysbake. SteamOS-specific
dependency installation is outside this workflow.

### Prepare and reuse Google inputs

Use the helpers in the base stage, with an explicit output directory (no
`.build-env` is read):

```bash
bash ~/lepton-work/base-stage/tools/customize/prepare-google-inputs.sh \
  --zip ~/Downloads/x86_64-34_r14.zip \
  --output ~/lepton-work/google-inputs \
  --with-ndk --with-gapps --with-widevine
```

The output must not exist. Component flags limit preparation; without flags,
the helper retains its existing build behaviour and prepares all components.
For example, `--with-widevine` skips NDK extraction. Add `--check` to validate
ZIP identity and preparation dependencies without extracting anything.
Preparation records `SOURCE.txt`, SDK `SOURCE.properties`, `BUILD.prop`,
`SOURCE-IMAGES.sha256`, logical partition images and, when selected, the NDK
payload and its manifest/provenance. Previously prepared inputs with this
metadata can be reused without reading the ZIP again. Older input directories
without this provenance must be prepared once with the updated helper.

**Prepare NDK inputs again if they were made by the first Phase 3 helper
(commit `5588b21`).** Its extractor silently skipped ARM64 libraries whose names
contain `+` or `@`, including `libc++.so`, which most guest system libraries
need. The fixed extractor keeps those names and refuses a payload in which any
guest library dependency is missing. The payload manifest cannot reveal the
problem by itself, because it was written by the same extraction.

### NDK only

```bash
~/lepton-work/base-stage/compat_tool/tools/lepton-customize inject --check \
  --stage-dir ~/lepton-work/base-stage \
  --output-stage ~/lepton-work/ndk-stage \
  --google-inputs ~/lepton-work/google-inputs --with-ndk
```

Repeat with `--execute`. The reviewed translator SHA256 is mandatory. The
ARM64 runtime payload is checked against its manifest and copied (at
preparation, extraction also checks that every guest library dependency, such
as `libc++.so`, is present), and the existing NDK
injector changes the native bridge and system/vendor/ODM ABI properties in
the new rootfs only. The bundled shim is never rebuilt. Existing automatic
translator recognition still controls its activation. Unsupported versions,
incomplete payloads and checksum/provenance mismatches fail.

### GApps only

```bash
~/lepton-work/base-stage/compat_tool/tools/lepton-customize inject --execute \
  --stage-dir ~/lepton-work/base-stage \
  --output-stage ~/lepton-work/gapps-stage \
  --google-inputs ~/lepton-work/google-inputs --with-gapps
```

This includes Play services, Google Services Framework, Play Store,
Chrome/Trichrome and the established permissions/configuration. The base
`services.jar` must already have Lepton's required framework modifications.
An incompatible framework produces an error instructing you to use a compatible
base bundle; Phase 3 does not build, replace or patch `services.jar`.

### Widevine only

```bash
~/lepton-work/base-stage/compat_tool/tools/lepton-customize inject --execute \
  --stage-dir ~/lepton-work/base-stage \
  --output-stage ~/lepton-work/widevine-stage \
  --google-inputs ~/lepton-work/google-inputs --with-widevine
```

Widevine is independently selectable. The existing helper installs the
flattened vendor APEX at `vendor/apex/com.google.android.widevine` and records
its checksums. This is **L3 software DRM**; it promises neither hardware DRM
nor streaming-service certification or acceptance.

### All components, directly from a ZIP

```bash
~/lepton-work/base-stage/compat_tool/tools/lepton-customize inject --execute \
  --stage-dir ~/lepton-work/base-stage \
  --output-stage ~/lepton-work/full-stage \
  --google-zip ~/Downloads/x86_64-34_r14.zip \
  --save-google-inputs ~/lepton-work/google-inputs \
  --with-ndk --with-gapps --with-widevine
```

Any combination of component flags works. Omit `--save-google-inputs` for a
private disposable preparation. With it, validated inputs are atomically
retained at that new directory for future `--google-inputs` operations. The
cache may be on another filesystem. A valid saved cache can remain if later
injection fails; the requested output stage remains unpublished.

For injection, `--check` validates the source stage, selected components and
inputs without publishing an output stage. With a ZIP it needs temporary
extraction to inspect partition contents; it removes that temporary work and
does not save a cache. This differs from the original Stage 2 archive `--check`,
which performs no extraction or disk writes.

### Space, safety and output state

Budget one independent stage/rootfs copy plus injected components. ZIP
preparation additionally needs temporary disk space for the unpacked emulator
disk, its super partition and logical images (often around 10 GiB). The command
uses a conservative estimate based on the ZIP's uncompressed disk size, source
stage size and component inputs, and checks the relevant destination/cache
filesystems. Reusing prepared inputs avoids the ZIP preparation overhead.
NDK's existing injector creates the only new rootfs copy; other components are
then applied to that same copy.

Outputs are built in private temporary directories and published atomically
without replacing existing paths. Stage/input/output overlaps and unsafe
symlinks are rejected. Handled interruptions stop helper process groups before
cleaning temporary files. No source is overwritten. A forced kill or power loss
can leave a private `.lepton-inject-*` sibling to remove manually.

The output retains `source-bundle/` unchanged, has no root-level `BUNDLE.json`
and contains no `sysbake` or `sysbake.xattrs`. `STAGE.json` keeps format version 1,
records state `customized`, the three selected-component booleans, original
bundle identity, Google source/package/partition checksums and the new rootfs
tree digest, and explicitly sets `sysbake_required: true`. Component evidence is under:

- `compat_tool/ndk-provenance/`: NDK report, payload hashes and extraction source.
- `compat_tool/provenance/gapps/`: injected files, source images and configuration.
- `compat_tool/provenance/widevine/`: flattened APEX hashes and L3 identification.
- `compat_tool/provenance/google-inputs/`: original input metadata and image manifest.

**The result is not installable until a fresh sysbake is generated and the
stage is packaged** (below). Injection does not boot Android, provision ADB,
produce an archive or register a compatibility tool.

## Stage ADB (optional)

Sysbake and packaging do not need ADB. To test APKs against a stage before
packaging (for example with `tests/runtime/run-apk.sh` and `LEPTON_ADB`),
stage Google's pinned Platform-Tools `adb`:

```bash
# Verified download directly from Google (dl.google.com, HTTPS only)
lepton-customize adb --execute --stage-dir ~/lepton-work/ndk-stage
# Offline, with the same official ZIP downloaded earlier
lepton-customize adb --execute --stage-dir ~/lepton-work/ndk-stage \
  --adb-zip ~/Downloads/platform-tools_r37.0.1-linux.zip
```

The URL, SHA256 and version pins are read from the stage's own installer
(`compat_tool/tools/lepton-install-bundle`), so they always match what the
bundle installer accepts. Only `adb` and Google's `NOTICE.txt` are extracted;
a mismatching hash or version changes nothing. Staged ADB lives in
`tools/platform-tools/` and is **never packaged**; installers download it
themselves. inotify-tools are reused from the bundle, never rebuilt.

## Generate a fresh sysbake

Android data must be baked again whenever Android changes. Run the bundled
isolated sysbake helper on a `prepared` or `customized` stage:

```bash
lepton-customize sysbake --check   --stage-dir ~/lepton-work/ndk-stage
lepton-customize sysbake --execute --stage-dir ~/lepton-work/ndk-stage \
  [--rendering software|amd] [--timeout 600]
```

Host requirements are checked together and reported with Fedora/Ubuntu package
names: rootless Podman with `newuidmap`/`newgidmap` (`shadow-utils`),
`fuse-overlayfs`, headless Weston, attr (`getfattr`/`setfattr`), `rsync`,
`flock`, `pkill`, Android Binder (BinderFS) kernel support, a running systemd
user session (`systemctl --user is-system-running`) and `/run/user/UID`. On
Fedora: `sudo dnf install podman fuse-overlayfs weston attr rsync util-linux
procps-ng shadow-utils`. Software rendering is the default and needs no GPU;
`--rendering amd` uses the AMD Vulkan driver.

**Fedora and other SELinux-enforcing hosts** also need Lepton's small policy
module once. Without it, Android's service managers are denied
`binder { set_context_mgr }` inside the container (an `AVC denied` in
`journalctl`), and Android never finishes booting. The module keeps SELinux
enforcing and only adds Binder permissions for the container type:

```bash
sudo dnf install checkpolicy semodule-utils
checkmodule -M -m -o /tmp/lepton_binder.mod ~/lepton-work/base-stage/tools/customize/selinux/lepton_binder.te
semodule_package -o /tmp/lepton_binder.pp -m /tmp/lepton_binder.mod
sudo semodule -i /tmp/lepton_binder.pp
```

`sysbake --check` asks the kernel whether this permission is granted (no root
needed) and prints these commands when it is not. Bundles made before the
policy file was shipped get an equivalent inline `printf` instead.

The helper uses a fresh private Podman graphroot/runroot inside the stage and
a temporary headless Weston socket. It never touches your ordinary Podman
containers or storage, and refuses to run while another isolated sysbake or
`lepton-sysbake.slice` is active. It refuses to overwrite an existing sysbake.

The result is validated before it is recorded: `system/packages.xml` must be
Android XML, `sysbake.xattrs` may hold only user attributes for paths inside
the sysbake (Android sockets are recorded but never archived), no host Ethernet
configuration may be baked in, Google Play services must be registered exactly
when GApps were injected, and the rootfs must not change during the run.
`STAGE.json` then becomes `state: baked`, `sysbake_required: false`, with the
rootfs, sysbake and xattr digests and runtime fingerprint.

If sysbake fails, `STAGE.json` is unchanged and still requires sysbake.
Diagnostics (`sysbake.log`, `weston.log`) stay in the stage's
`.sysbake-work.*` folder. Output that fails validation is moved to
`.sysbake-rejected-*` rather than deleted; neither is ever packaged. Remove them
with `podman unshare rm -rf PATH` when no longer needed.

## Package an installable bundle

```bash
lepton-customize package --check \
  --stage-dir ~/lepton-work/ndk-stage \
  --output-dir ~/lepton-work/bundles \
  --bundle-id my-ndk-build

lepton-customize package --execute \
  --stage-dir ~/lepton-work/ndk-stage \
  --output-dir ~/lepton-work/bundles \
  --bundle-id my-ndk-build
```

This writes `lepton-x86_64-my-ndk-build.tar.gz`, its `.tar.gz.sha256` and
`.install.sh`, compatible with the normal bundle installer and Steam
compatibility-tool registration. Packaging uses only the stage: its validated
scripts, precompiled binaries, installer template, rootfs and sysbake. There is
no source checkout, `.build-env`, compilation or new sysbake.

- The rootfs, sysbake and `sysbake.xattrs` must still match the digests
  recorded by `sysbake` or `restore`; component flags (`gapps`, `ndk`,
  `widevine`) must match what is actually installed in the rootfs and its
  provenance manifests.
- Choose a new bundle ID; the default tool ID is `lepton_custom_<ID>` and the
  display name `lepton <ID> x86_64 (custom)`, with any GApps, NDK or Widevine
  after it, e.g. `lepton <ID> x86_64 (custom, GApps + NDK)` (`--tool-id`/`--tool-name` to
  override). The source bundle's IDs are refused.
- File types, permissions, symlinks and hardlinks are preserved. Temporary and
  sysbake work folders, Podman storage, staged ADB, saved profiles, install
  profiles and `STAGE.json`/`source-bundle/` are excluded.
- Outputs are written in a private folder and published without overwriting;
  the archive is read back and compared with the stage before publication.
  An interrupted run leaves no outputs.
- `tools/BUNDLE-PROVENANCE.txt` states that this is a local customised bundle,
  names the source bundle and whether the sysbake is fresh or retained. A
  customised rootfs is never described as compiled from a source checkout: its
  base image record moves to `tools/BASE-IMAGE-PROVENANCE.txt`. Source
  provenance is kept in `compat_tool/provenance/sources/<source-id>/`.
- The archive is not signed with the official release identity.

## Repackage an existing bundle without sysbake

To change only host-side packaging (a new bundle/tool ID, or a bundle you no
longer have a stage for), restore the archive as a complete stage. Unlike the
prepared stage above, this keeps the Android rootfs, runtime overlays,
`compat_tool/sysbake/`, `sysbake.xattrs`, precompiled utilities, launcher and
registration assets and source provenance:

```bash
lepton-customize restore --execute \
  --bundle ~/Downloads/lepton-x86_64-v0.2.0-alpha.tar.gz \
  --checksum ~/Downloads/lepton-x86_64-v0.2.0-alpha.tar.gz.sha256 \
  --stage-dir ~/lepton-work/restored-stage

lepton-customize package --execute \
  --stage-dir ~/lepton-work/restored-stage \
  --output-dir ~/lepton-work/bundles --bundle-id v0.2.0-alpha-repack
```

Restore uses the same checksum/signature verification and secure extractor as
stage creation (add `--allow-unsigned` for your own unsigned local bundles).
Official and customised bundles are accepted, including older bundles.
`BUNDLE.json` must describe the rootfs: a legacy file without `widevine`
counts as false, unless the rootfs contains the Widevine APEX, which is then
recorded as true. After extraction the rootfs and sysbake are compared with a
second read of the archive. `STAGE.json` records `state: restored-complete`,
`sysbake_required: false`, the component flags and digests; the original
identity is in `source-bundle/`.

A restored stage refuses `inject` and `sysbake`, and packaging refuses if its
Android or sysbake changed. To customise Android, create a new prepared stage
from the base bundle (which discards sysbake) and follow Workflow A. Matching
content does not make arbitrary Android modifications safe.

Unchanged Android and sysbake contents are preserved exactly. Changing only
the bundle ID does not change the runtime fingerprint.

## Compare bundles

```bash
lepton-compare-bundles lepton-x86_64-v0.2.0-alpha.tar.gz \
  ~/lepton-work/bundles/lepton-x86_64-v0.2.0-alpha-repack.tar.gz \
  [--json report.json] [--all]
```

Each archive is streamed once; nothing is extracted, installed or booted, and
unsafe or malformed entries are rejected. The report covers, separately:

- **Android rootfs** and **sysbake**: added/removed entries, content (SHA256),
  types, symlink targets and permissions;
- **sysbake.xattrs**: user extended attributes per path;
- **runtime fingerprint inputs** (exactly what the launcher hashes);
- **metadata**: `BUNDLE.json` flags, components found in each rootfs, other
  changes and provenance;
- **other files** (launcher/tooling/metadata).

It then says whether the Android rootfs, sysbake, xattrs and fingerprint inputs
are identical and whether differences are confined to launcher/tooling/metadata.
Exit status: 0 identical runtime inputs, 1 different or incomplete, 2 invalid
archive. This is evidence about content, not a promise that saved game profiles
are compatible.

## Complete examples

Run the tools from a verified bundle (`~/lepton-customize-bootstrap` above,
or the stage's own `compat_tool/tools/`). `C=~/lepton-customize-bootstrap/compat_tool/tools`.

**Workflow A: NDK + GApps + Widevine from the base bundle.**

```bash
mkdir -p ~/lepton-work
$C/lepton-customize --execute \
  --bundle ~/Downloads/lepton-x86_64-v0.2.0-alpha.tar.gz \
  --checksum ~/Downloads/lepton-x86_64-v0.2.0-alpha.tar.gz.sha256 \
  --stage-dir ~/lepton-work/base-stage
$C/lepton-customize inject --execute \
  --stage-dir ~/lepton-work/base-stage --output-stage ~/lepton-work/full-stage \
  --google-zip ~/Downloads/x86_64-34_r14.zip --save-google-inputs ~/lepton-work/google-inputs \
  --with-ndk --with-gapps --with-widevine
$C/lepton-customize sysbake --execute --stage-dir ~/lepton-work/full-stage
$C/lepton-customize package --execute --stage-dir ~/lepton-work/full-stage \
  --output-dir ~/lepton-work/bundles --bundle-id my-full-build
$C/lepton-compare-bundles ~/Downloads/lepton-x86_64-v0.2.0-alpha.tar.gz \
  ~/lepton-work/bundles/lepton-x86_64-my-full-build.tar.gz
bash ~/lepton-work/bundles/lepton-x86_64-my-full-build.install.sh
```

**Workflow B: repackage without a stage you kept.**

```bash
$C/lepton-customize restore --execute \
  --bundle ~/Downloads/lepton-x86_64-v0.2.0-alpha.tar.gz \
  --checksum ~/Downloads/lepton-x86_64-v0.2.0-alpha.tar.gz.sha256 \
  --stage-dir ~/lepton-work/restored-stage
$C/lepton-customize package --execute --stage-dir ~/lepton-work/restored-stage \
  --output-dir ~/lepton-work/bundles --bundle-id v0.2.0-alpha-repack
$C/lepton-compare-bundles ~/Downloads/lepton-x86_64-v0.2.0-alpha.tar.gz \
  ~/lepton-work/bundles/lepton-x86_64-v0.2.0-alpha-repack.tar.gz
# RESULT: identical Android rootfs, sysbake, xattrs and fingerprint inputs;
#         differences are confined to launcher/tooling/metadata.
```

Stages are disposable once packaged: `podman unshare rm -rf ~/lepton-work/full-stage`.

## Working stage layout

```text
my-custom-stage/
  STAGE.json                    stage type, components and digests (see table above)
  source-bundle/
    BUNDLE.json                 original identity, unchanged
    SHA256SUMS[.sig]            supplied integrity/authenticity evidence
    SOURCE.json                 archive name, hash, authentication result and trust root
    *PROVENANCE.txt             original build/tool provenance
  compat_tool/
    images/rootfs/              independent original Android rootfs
    images/rootfs_overlay/      existing runtime overlay
    liblepton/                  launcher helpers and compiled shim/extractor
    tools/                      runtime tools and lepton-customize
    release-keys/
  tools/
    bin/inotifywait
    native/inotifywait
    lib/libinotifytools.so.0
    licenses/
    customize/                  helpers run by inject and sysbake
  tests/runtime/                bundled runtime helpers, when present
```

Original source provenance is separate from `STAGE.json`; there is no new
`BUNDLE.json` at the stage root claiming to be a completed release. Permissions,
executable bits, internal hardlinks and symlinks are preserved without restoring
archive ownership. Absolute Android rootfs symlinks retain their guest-namespace
targets. The extractor never follows archive links while writing, rejects
entries below links, and rejects traversal, duplicate paths and special files.

The original `compat_tool/sysbake` and `sysbake.xattrs` are excluded. Saved
profiles, compatdata, local installation markers, credentials in standard
private directories, build caches and host ADB are excluded. A populated
Android userdata tree is rejected. The download and installed tools are
never changed. The existing NDK shim remains inactive until the existing
runtime checks recognise a compatible translator; Stage 2 changes no Android
properties or optional components.

## Developer boundaries and host dependencies

Original release creation still uses `make-deck-bundle-x86_64.sh` and
`deploy-compat-x86_64.sh`: these read `.build-env`, build the shim/APK extractor
and use the build workspace. `provision-deck-tools.sh --execute` still compiles
inotify in its existing Debian container. **Client staging calls none of
these scripts.** The existing inotify implementation is unchanged.

The release packager (`deck-bundle.sh`) includes `lepton-customize` with its
companions (`lepton_customize_inject.py`, `lepton_customize_package.py`,
`lepton_bundle_lib.py`), `lepton-compare-bundles`, this guide,
and the source-only helpers `tools/customize/internal/sysbake-isolated-x86_64.sh`,
`internal/inject-ndk-translation.sh`, `internal/extract-ndk-translation.sh`,
`lib/google-services.sh`, `lib/workspace.sh` and `prepare-google-inputs.sh`. These helpers operate on
explicit directories, not an AOSP checkout. The input preparer needs an
explicit `--output DIR` to avoid its build-workspace defaults. Injection delegates
to these helpers; sysbake runs the bundled isolated helper. The Stage 2 CLI
remains compatible. No proprietary translator, GApps or Widevine payload is
supplied in official bundles. `BUNDLE.json` component flags and the
official packager's metadata come from the same detection code
(`lepton_bundle_lib.py`).

Offline regression tests use synthetic ext4/APK/APEX fixtures with the actual
shell injectors. Positive synthetic NDK tests patch the expected digest only
inside the test process; the production command has no translator-pin override.
An optional real-input integration test uses the production pin:

```bash
LEPTON_TEST_BASE_STAGE=/absolute/path/to/clean-base-stage \
LEPTON_TEST_GOOGLE_INPUTS=/absolute/path/to/prepared-google-inputs \
  python3 -B tests/test-customize-inject.py LocalGoogleIntegration
```

Real Google inputs are never committed or required by the offline suite.

Client-side host dependencies: Python 3 and `readelf` for every operation;
`ssh-keygen` for signed bundles; the Phase 3 tools above for injection; the
sysbake requirements listed above (Podman, Weston, fuse-overlayfs, attr,
BinderFS, systemd user session); `bash` for packaging. Restore and compare need
only Python 3. SteamOS customisation remains **experimental** and is not a
supported mainstream flow; primary targets are Fedora and compatible x86_64
Linux PCs.

Offline regression tests (no Android, network, Binder or GPU; the real bundled
sysbake helper runs against Podman/Weston/systemd test doubles):

```bash
python3 -B tests/test-customize.py           # prepared stages
python3 -B tests/test-customize-inject.py    # injection
python3 -B tests/test-customize-package.py   # adb, sysbake, package, restore, install
python3 -B tests/test-compare-bundles.py     # comparison
```

Optional real-data checks on Fedora:

```bash
# Workflow B with a real complete bundle (input untouched)
LEPTON_TEST_COMPLETE_BUNDLE=/path/lepton-x86_64-ID.tar.gz [LEPTON_TEST_ALLOW_UNSIGNED=1] \
  python3 -B tests/test-customize-package.py LocalBundleIntegration
# Workflow A with real Podman, Weston, BinderFS and an Android boot
LEPTON_TEST_BASE_BUNDLE=/path/lepton-x86_64-v0.2.0-alpha.tar.gz \
LEPTON_TEST_GOOGLE_INPUTS=/path/google-inputs [LEPTON_TEST_COMPONENTS="ndk gapps widevine"] \
  python3 -B tests/test-customize-package.py LocalSysbakeIntegration
```
