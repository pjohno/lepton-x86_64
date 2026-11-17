# Post-merge review, 17 November 2026

Reviewed `main` at `8eb0fc8` (PR #32), including PR #31's integration.
Changes are on `fix/post-merge-review`. The existing candidate remains the
reference for the separate hardware tests.

## Findings

| Classification | Finding and response |
| --- | --- |
| Verified defect | Normal teardown deleted an inherited `/tmp/lepton-context.*` solely because its path looked temporary. Both failed-start and normal cleanup now require ownership established by `create_prefix()` in this invocation. |
| Verified defect | The ownership variable could be supplied in the environment despite the original non-exported assignment. Library initialization clears it and removes its export attribute before any allocation. |
| Verified defect | `mktemp -d -t` honours `TMPDIR`, but cleanup accepts only `/tmp`. Creation now explicitly uses `/tmp`; failed allocation propagates its status rather than being masked by `export`. |
| Preventative improvement | Normal teardown now shares the failed-start container inspection policy. Existing containers using the prefix, missing/failed label inspection, unknown Podman state, and mounted or uninspectable paths cause retention. Labels are canonicalized so aliases cannot conceal use of a prefix. |
| Compatibility adjustment | Bootchart removes its container before attempting prefix deletion. Sysbake already removes its container first. `LEPTON_KEEP_CONTEXT` retains the prefix while its container exists. |
| Preventative improvement | Four profile-path helpers now quote argument forwarding, preserving paths with spaces and resolving existing ShellCheck errors. |
| Documentation inconsistency | AMD-only desktop claims, unconditional Intel software fallback, Codec2 opt-in claims, and the broad YouTube playback statement contradicted current implementation/evidence. Corrected across user, build and release documentation. |
| Documentation inconsistency | Added the missing 0009 patch and CUSTOMIZING index entry; documented image requirements for 0012/0013, save limitations on window close, and the already-merged integration status. |
| Preventative improvement | The existing optional AOSP Binder-order test now checks both Bp and Bn offsets, tests parsing without AOSP, rejects unsupported declarations/explicit IDs, and fails on an explicitly requested missing checkout. Current Android 14 offsets are correct; no Binder implementation or Android patch changes were necessary. |
| Hardware-dependent issue | Intel rendering, media playback/video output, window-close behavior and preservation across real launches still require the candidate's manual hardware tests. Mocked tests do not establish these results. |

## Prefix caller and teardown audit

- `create_prefix()` is called by `determine_app --start` (including APK staging),
  `start_early_debug`, `sysbake` and `bootchart`. Repeated calls reuse the prefix.
- `prefix()` and live-context lookup in `determine_app()` can read a container's
  `PREFIX` label. Neither operation establishes ownership. Shell/attach commands
  therefore cannot acquire deletion rights through label lookup.
- Normal game teardown stops/removes the container, then calls `remove_prefix()`.
  That function retains the existing overlay-workdir cleanup and delegates
  temporary deletion to `remove_owned_prefix()`.
- The early-start EXIT trap calls the same helper, preserving failure status and
  retaining prefixes potentially used by a container. `remove_prefix_dir()` itself
  also checks ownership, canonical paths, symlinks, container state and mounts.
- Sysbake removes the container before `remove_prefix()`. Bootchart now follows
  that order too. Early debug intentionally leaves its container/prefix alive.
- `cleanup_container()`, `cleanup_all()` and `remove_context()` do not infer prefix
  ownership or delete an externally supplied prefix. Persistent Android profiles,
  compatdata and sysbake data retain their separate existing cleanup policies.

Conservative retention may leave a temporary directory after a Podman/mount
inspection error or a retained container. Losing deletion permission in another
invocation is intentional: a temporary-looking name or label is not proof of
ownership.

## Documentation audit

Reviewed README plus all twelve requested guides: INSTALL-STEAM-DECK, BUILDING,
GAPPS, CUSTOMIZING, RELEASING, FEDORA-DEBUGGING, compat_tool/LOCAL-DESKTOP,
compat_tool/configuration, .github/RELEASE_TEMPLATE, and image-14/docs/
BUILD-x86_64, DECK-STAGING and release-integration.

The policy now consistently describes AMD-first GPU selection, experimental
Intel Gen9+ support requiring the Intel Vulkan HAL, software fallback, and the
`blob`/`heap`/`off` Codec2 decision. Modes are selected outputs, not accepted
`LEPTON_CODEC2` values; `true` is an experimental forced BLOB override and
`false` disables decoders. Ordinary PCM game audio, media audio, AVC output and
Widevine/application compatibility are distinguished.

Historical Fedora probes and milestone artifact records remain intact and are
identified as historical. Installation examples retain native Steam's
`~/.steam/root/compatibilitytools.d/` layout and version-first tool names.
The README custom patch table matches all ten `apply_custom` calls in prepare.

## Automated validation

- `bash image-14/tests/run-workflow-tests.sh`: **PASS**. Four optional
  real-input tests were skipped (Google injection, two complete/base-bundle
  customization tests, and rootless Podman with a supplied local image). No live Android boot or hardware validation was run.
- The first sandboxed suite attempt stopped at an existing group-ownership
  fixture: its supplementary group was unmapped. The complete suite passed
  outside that sandbox with approved local access; no test was weakened.
- Focused launcher-prefix, kept-data, profile-lifecycle, runtime-property and
  HWC window-close tests: **PASS**. The Binder test ran all eight tests,
  including the comparison against the existing local AOSP checkout, read-only.
- `bash -n` on changed shell files: **PASS**.
- `shellcheck -S error` on the launcher, library and three changed shell tests:
  **PASS**. This is error-level validation, not a claim of warning-free ShellCheck.
- Python compilation of both changed Python tests, with caches redirected to
  `/tmp`: **PASS**.
- All 108 internal Markdown links in the thirteen audited documents resolve to
  existing files/heading anchors. All 97 fenced Bash examples parse with
  `bash -n`; commands were not executed. Example flags, driver modes, native
  Steam paths and patch registration were also reviewed against the scripts.
- `git diff --check`: **PASS**.

Suite output is available in this work session at
`/tmp/lepton-post-merge-workflow.log`. Focused prefix output is at
`/tmp/lepton-review-prefix.log`. These logs describe temporary fixtures and
mocks; they must not be cited as live hardware validation.

## Remaining hardware validation

1. On the existing candidate, confirm AMD RADV and Intel Gen9+ ANV/Iris rendering,
   matching HAL/render-node selection, and any available hybrid-GPU overrides.
2. Check direct Wayland close requests task removal and ends audio/container
   execution. Save explicitly first; task removal does not guarantee save writes.
3. Compare ordinary game audio with Codec2 media audio on patched AMD, older
   images and Intel; record the selected mode and host heap permissions. Retest
   AVC/video output and YouTube separately; Widevine L3 alone proves no app's
   playback compatibility.
4. Confirm Steam Deck Gaming/Desktop controls, repeated launch/save retention,
   Stop/signals and normal container teardown on the tested hardware.

No Android prepare/reset, image build, sysbake regeneration, candidate packaging,
installation, game-profile changes, release creation or merge is part of this
review. No Android patches were changed.
