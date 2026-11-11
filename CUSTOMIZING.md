# Customising a downloaded Lepton bundle

The planned workflow for `v0.2.0-alpha` is:

Download a base bundle → create an independent stage → inject optional
components → generate a fresh sysbake → package a customised bundle.

Stages 2 and 3 implement base staging and optional NDK/GApps/Widevine injection.
Fresh sysbake, ADB provisioning and final customised packaging remain Phase 4
work. Neither a prepared nor a customised working stage is installable yet.

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
files into a new directory:

```bash
mkdir -p ~/lepton-customize-bootstrap
tar -xzf ~/Downloads/lepton-x86_64-v0.2.0-alpha.tar.gz \
  -C ~/lepton-customize-bootstrap \
  ./compat_tool/tools/lepton-customize \
  ./compat_tool/tools/lepton_customize_inject.py \
  ./compat_tool/release-keys/allowed_signers
```

The command uses the same installed trust keys, OpenSSH signing identity and
namespace as `lepton-release-manager`. With trusted keys installed, a valid
manifest signature is mandatory; missing or invalid signatures fail. By
default it finds `CHECKSUM.sig`; `--signature FILE` selects an explicit file.
Without installed keys, unsigned inputs can be checked for integrity only,
with an explicit **authenticity NOT verified** message. A supplied signature
without trusted keys is rejected. SHA256 alone does not prove publisher
identity. The command never downloads keys or executes programs from the
input bundle during validation.

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
x86_64-only ABIs, disabled native bridge, `format_version: 2`, and `gapps: false`,
`ndk: false`. Incomplete/older bundles are refused. The precompiled NDK shim,
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
`python3`, `binutils`, `rsync`, `e2fsprogs`, `coreutils`, `findutils`, `grep` and
`gawk`. ZIP preparation additionally needs `unzip`, `sfdisk` (`util-linux`) and
`lpunpack`, a host logical-partition unpacker. `lpunpack` is not supplied in the
bundle; install it separately as a host utility. Prepared-input injection does
not need `lpunpack` or `sfdisk`. Widevine extraction needs `unzip` even with
prepared inputs. Missing dependencies produce command/package guidance.
Podman, a compositor and BinderFS are only needed in Phase 4. SteamOS-specific
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

### NDK only

```bash
~/lepton-work/base-stage/compat_tool/tools/lepton-customize inject --check \
  --stage-dir ~/lepton-work/base-stage \
  --output-stage ~/lepton-work/ndk-stage \
  --google-inputs ~/lepton-work/google-inputs --with-ndk
```

Repeat with `--execute`. The reviewed translator SHA256 is mandatory. The
complete ARM64 runtime payload is verified and copied, and the existing NDK
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
bundle identity and Google source/package/partition checksums, and explicitly
sets `sysbake_required: true`. Component evidence is under:

- `compat_tool/ndk-provenance/`: NDK report, payload hashes and extraction source.
- `compat_tool/provenance/gapps/`: injected files, source images and configuration.
- `compat_tool/provenance/widevine/`: flattened APEX hashes and L3 identification.
- `compat_tool/provenance/google-inputs/`: original input metadata and image manifest.

**The result is not installable until Phase 4 generates fresh sysbake and
packages it.** Phase 3 does not boot Android, provision ADB, regenerate sysbake,
produce an archive or register a compatibility tool.

## Working stage layout

```text
my-custom-stage/
  STAGE.json                    prepared state; sysbake_required: true
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
    customize/                  existing helpers reserved for later stages
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

## Developer boundaries and remaining dependencies

Original release creation still uses `make-deck-bundle-x86_64.sh` and
`deploy-compat-x86_64.sh`: these read `.build-env`, build the shim/APK extractor
and use the build workspace. `provision-deck-tools.sh --execute` still compiles
inotify in its existing Debian container. **Client staging calls none of
these scripts.** The existing inotify implementation is unchanged.

The release packager (`deck-bundle.sh`) includes `lepton-customize`, this guide,
and the source-only helpers `tools/customize/internal/sysbake-isolated-x86_64.sh`,
`internal/inject-ndk-translation.sh`, `internal/extract-ndk-translation.sh`,
`lib/google-services.sh`, `lib/workspace.sh` and `prepare-google-inputs.sh`. These helpers operate on
explicit directories, not an AOSP checkout. The input preparer needs an
explicit `--output DIR` to avoid its build-workspace defaults. Phase 3 delegates
to these helpers through the bundled `lepton_customize_inject.py` companion.
The Stage 2 CLI remains compatible. No proprietary translator, GApps or
Widevine payload is supplied in official bundles.

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

Stage 4 must provision ADB with the existing pinned Google mechanism (or a
matching offline ZIP), run the existing isolated sysbake on the new stage,
and provide a stage-only packager. The existing isolated sysbake helper already
accepts `--stage-dir` without build configuration, and requires a user systemd
session, Podman, BinderFS, Weston, fuse-overlayfs, rsync and xattr utilities.
Its checks can be run later, after ADB provisioning. The current release
packager still refreshes files from a source checkout and requires a completed
sysbake; it is deliberately not the client packaging path yet. Neither
sysbake nor final custom packaging is invoked by `lepton-customize`. Phase 4
must also distinguish the original base image provenance from the added
components and keep Google-containing personal bundles out of the official
Google-free publisher path.
