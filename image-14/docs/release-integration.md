# Release integration validation

**Current status (17 November 2026):** integration is merged into `main` through
PR #31, followed by the fixes in PR #32. Release hardware validation remains
outstanding; the existing candidate bundle is the reference for those tests.
The review and automated results below record the integration work historically.

Historical branch: `feature/release-integration`, based on `origin/main` at
`d4641cc`. The following branches were merged in order with separate,
non-squashed merge commits:

| Source | Integrated tip |
| --- | --- |
| `fix/sysbake-acl-private-storage` | `eb1f1ed7d1a230321772a4c54d2a1bff922f9b2b` |
| `feature/intel-graphics` | `69408beaad39ab45458859924a05c1efd10f39a2` |
| `feature/steam-compat-install` | `016b6149775eec8b70700c49e0124a0024dbdf32` |

## Merge and semantic review

Git reported no textual conflicts. All three tips are ancestors of the
integration branch. The source branches change 46 distinct files; comparisons
against each original tip confirmed preservation of the source changes.
The four overlapping files were reviewed semantically:

- `lepton-install-bundle`: Intel bundle-driver detection, saved Intel rendering
  and driver-specific next steps coexist with both installation layouts,
  version-first names, registration, migration, saved profiles and rollback.
- `lepton-host-check`: Intel's experimental-driver warning coexists with native
  Steam resolution and both installation profiles. Binder, required tools,
  Flatpak and X11 checks retain their existing policy.
- `BUILDING.md`: Intel build/test instructions and GPU-selection policy coexist
  with version-first display names and the Steam Deck instructions.
- `run-workflow-tests.sh`: every test reference from every source branch is
  retained. Host preflight and rootfs packaging suites were added as well.

Intel Mesa build dependencies, bootstrap tools, driver configuration, selected
render-node mounting and Android graphics properties are unchanged from the
Intel branch. Steam registration, install management, release-manager support,
packaging names and customization retain the Steam branch behaviour, with
the sysbake dependency fix described below.
The private-storage helper itself is unchanged from the sysbake branch.

## Integration fixes and incompatibilities

- Sysbake previously exposed only `software|amd`, and `amd` did not pin the
  runtime driver on an Intel or hybrid host. The runner, wrappers and capability
  preflight now accept `software|amd|intel`; hardware modes require their staged
  driver and explicitly select RADV or ANV. Software remains the default and
  clears any inherited hardware-driver override. Weston remains headless with
  Pixman; Android's renderer is selected independently.
- Persistent-profile shortcuts previously hardcoded `--rendering amd`. They now
  use the selected install's saved, validated rendering setting. Older installs
  without settings retain their AMD default.
- The Intel installer fixture lacked a native Steam directory required by the
  new resolver. It now supplies one; production Steam checks were preserved.
- The packaging fixture omitted the private-storage module imported by the
  updated capability checker. It now copies that dependency.
- Installed bundles shipped the updated sysbake script without its new
  `private_storage.py` dependency. This broke standalone customization sysbake.
  The packager now includes the helper, customization requires it, and archive
  tests compare its contents with the source. Customization also accepts Intel
  rendering and tests its staged-driver validation.
- Installer/host-check messages and the installation guide no longer claim that
  the combined image contains only AMD drivers.

Regression coverage now includes Intel installs without `--allow-non-amd` in
both layouts, migration retaining Intel rendering, driver-specific sysbake
preflight, hardware-driver pinning, software override cleanup and saved-profile
rendering selection.

Unsupported GPUs still require an explicit software-testing opt-in. Runtime
checks still reject missing drivers, mismatched overrides and pre-Gen9 Intel
hardware. No isolation or ACL checks were weakened. ACL removal remains limited
to newly created empty private storage directories; staged rootfs ACL inspection
is read-only. No recursive ownership, mode or ACL changes were performed on
user data.

## Automated validation

Validation uses synthetic bundles, fake host/device trees and temporary homes;
it does not build or boot Android, invoke real Steam or publish a release.

- Full suite: `bash image-14/tests/run-workflow-tests.sh` passed (exit 0).
  Includes GPU selection, host checks, private storage, build preflight,
  packaging, Steam compatibility installation, registration, migration,
  release installation/management and the existing runtime unit regressions.
- Additional host-only suites: `python3 -B tests/test-install-profiles.py`
  (10 tests passed) and `python3 -B tests/test-lepton-lock.py` (12 passed).
- Individual preflight (18), rootfs packaging (19) and private storage (15)
  suites passed; private storage skipped its one optional live Podman test.
- `bash -n`: all 26 changed shell files passed, including extensionless tools.
- Python compilation: all 16 changed Python files passed, including extensionless
  tools; compilation was in memory, without writing bytecode.
- ShellCheck error-level checks passed for the host checker, installer, sysbake
  runner, Steam installer test, GPU selection test and workflow runner.
- `git diff --check` passed. Source ancestry, changed-file comparisons and
  workflow-test reference preservation passed.

The sandbox blocked a temporary group-change fixture and Unix socket creation;
these checks were rerun successfully with the required local access.
Validation was restarted against the finalized runner after fixing the bundled
sysbake dependency.

The optional live private-storage test requires `LEPTON_TEST_PODMAN_IMAGE` set
to an existing local image and has not been run. It should verify rootless
Podman startup under an ACL-bearing workspace using the private store.
The two optional real-bundle customization tests also require
`LEPTON_TEST_COMPLETE_BUNDLE` or `LEPTON_TEST_BASE_BUNDLE` and were skipped.
The real Google-input injection test also requires `LEPTON_TEST_BASE_STAGE`
and `LEPTON_TEST_GOOGLE_INPUTS` and was skipped. There was no full AOSP image
build or real isolated Android sysbake execution.

## Required hardware validation before release

The integration's recorded automated suite was green; this is not release
sign-off. Integration is already on `main`. Record these hardware checks against
the candidate before approving a release; the build/sysbake items describe
validation of the candidate's existing artifacts, not a request to replace them:

1. Build the combined Android image on the supported Ubuntu 26 builder. Verify
   Mesa host-tool bootstrap and both `vulkan.radeon.so` and `vulkan.intel.so`.
   This build was deliberately excluded from the integration task.
2. AMD desktop: run the installed bundle's `tests/runtime/run-apk.sh
   --gpu-check --execute`; confirm RADV, the selected render node, a game launch,
   video and persistent data. Exercise legacy and Steam-folder installations.
3. Intel Gen9 or newer desktop: repeat the graphics check and confirm ANV/Intel
   and the Intel HAL in SurfaceFlinger, without SwiftShader or an AMD
   requirement. Validate direct Wayland on GNOME/KDE, game launch and saved
   profiles. Test available i915/xe generations separately.
4. Hybrid GPU host: confirm AMD-first default selection, explicit
   `LEPTON_VULKAN_DRIVER=intel` selection and gralloc/render-node consistency.
   Verify unavailable-driver and unsupported-GPU refusals remain actionable.
5. Steam Deck: test Gaming and Desktop modes, Gamescope bridge, touch,
   controllers, audio/video and existing game data. Exercise fresh installation,
   legacy-to-Steam migration, versioned names, tool selection, update, repair,
   rollback and removal without affecting other compatibility tools.
6. Isolated sysbake: boot the staged combined image with default software
   rendering and optional AMD/Intel modes on matching hardware. Verify the
   published bake and xattrs, Ethernet cleanup, timeout/process/lock cleanup,
   private graphroot/runroot, ACL rejection and unchanged default Podman data.
   Validate hardware rendering with the headless Pixman compositor in practice.

Integration has merged. Do not tag a release until the release hardware results
are reviewed; automated fixtures do not establish live hardware compatibility.
