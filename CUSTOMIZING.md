# Customising a downloaded Lepton bundle

The planned workflow for `v0.2.0-alpha` is:

Download a base bundle → create an independent stage → inject optional
components → generate a fresh sysbake → package a customised bundle.

**Stage 2 implements only the first two steps.** Optional NDK/GApps/Widevine
injection is Stage 3 work. Fresh sysbake, ADB provisioning and final customised
packaging orchestration remain Stage 4 work. A Stage 2 working stage cannot
be installed as a completed bundle yet.

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

## Working stage layout

```text
my-custom-stage/
  STAGE.json                    prepared state; sysbake_required: true
  source-bundle/
    BUNDLE.json                 original identity, unchanged
    SHA256SUMS[.sig]            supplied integrity/authenticity evidence
    SOURCE.json                 archive name, hash, authentication result
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
explicit `--output DIR` to avoid its build-workspace defaults. They are shipped for later stages;
Stage 2 does not invoke them or expose optional-component CLI flags.

Stage 3 still needs the optional-input validation/injection orchestration,
local legally obtained component inputs, and host extraction dependencies such
as `rsync`, `debugfs`, `unzip`, `sfdisk` and `lpunpack`. The preparation scripts
are included; `lpunpack` itself is not currently a packaged host tool. No
proprietary translator, GApps or Widevine payload is supplied here.

Stage 4 must provision ADB with the existing pinned Google mechanism (or a
matching offline ZIP), run the existing isolated sysbake on the new stage,
and provide a stage-only packager. The existing isolated sysbake helper already
accepts `--stage-dir` without build configuration, and requires a user systemd
session, Podman, BinderFS, Weston, fuse-overlayfs, rsync and xattr utilities.
Its checks can be run later, after ADB provisioning. The current release
packager still refreshes files from a source checkout and requires a completed
sysbake; it is deliberately not the client packaging path yet. Neither
sysbake nor final custom packaging is invoked by `lepton-customize`.
