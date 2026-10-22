# Lepton x86_64 — experimental community port

> **Unofficial developer preview.** This repository contains an experimental x86_64 Linux port of [Valve's Lepton](https://gitlab.steamos.cloud/frame-public/lepton), intended to explore running Android applications through Steam on Linux desktops and Steam Deck. **It is not affiliated with, supported by, or endorsed by Valve.**
>
> **Source code and build recipes only.** No Android system or vendor images, extracted Android root filesystems, Steam depot binaries, proprietary applications, or APKs are supplied.

## Status

**Experimental — October 2026.** The port has booted Android 14 on an x86_64 AMD/Fedora development system and on a Steam Deck, and has launched local Android applications through Steam. These results are development observations, not a general compatibility guarantee.

Verified on the development setup:

- Android 14 boots through Lepton's rootless Podman integration.
- An ANGLE → Vulkan → Mesa RADV graphics path provides interactive output on the tested AMD hardware.
- A local Android 2048 APK was launched through Steam with persistent saves.
- Steam Deck gamepad axes are recognised by Android after correcting inherited EventHub handling of native evdev axis ranges.
- Native Steam Deck touchscreen input works in the tested Android applications when the launcher and Steam Input are configured appropriately.

Known limitations:

- This is **not** a complete, validated from-scratch build on an arbitrary computer. The tested image workflow reuses an already prepared Android 14 source checkout and build environment.
- USB mouse interaction is incomplete; connecting/disconnecting a mouse may affect application touch handling.
- Multiple controllers, controller hotplugging, and controller selection order are not yet reliable.
- Steam shortcuts, input configuration, Binder support, host graphics, and Android application compatibility vary by system.
- ARM-only Android native libraries are not supported without an additional translation solution; x86_64-native or pure-Java applications are the initial target.
- Native Android depots, broad game compatibility, clean sysbake generation, and other GPUs/platforms remain unverified.

## Repository layout

| Path | Purpose |
| --- | --- |
| `compat_tool/` | Lepton runtime and x86_64 adaptations |
| `compat_tool/tools/lepton-gamescope-bridge` | Experimental nested Gamescope launcher used on Steam Deck |
| `image-14/` | Android 14 image build configuration, vendor projects, and scripts |
| `image-14/patches/` | Reviewed source patches, including native evdev input-axis handling |
| `image-14/scripts/build-images-x86_64.sh` | Incremental Android system/vendor image build in the configured builder |
| `image-14/scripts/package-repro-rootfs.sh` | Packages a separate Android test rootfs from locally built images |

Some build components are Git submodules. Confirm that the URLs in `.gitmodules` are publicly accessible before attempting a fresh clone or reporting a reproducible clean build.

## Building the Android image (developer workflow)

**Prerequisites:** an existing and correctly prepared Android 14/AOSP checkout, a working `lepton-builder:latest` container image, rootless Podman and the image-building utilities described by the scripts. The supported developer workflow also needs a local glslang 14 validator; the build script will report if it is missing. This repository is **not** a turnkey Android image downloader or installer.

From `image-14/`, with a separately prepared source/output checkout:

```bash
./scripts/build-images-x86_64.sh /path/to/lepton-output
./scripts/package-repro-rootfs.sh /path/to/lepton-output
```

The build script uses the Android target `aosp_lepton_x86_64-ap2a-userdebug` inside the configured builder container and builds `systemimage vendorimage`. The packaging script extracts `system.img` and `vendor.img`, flattens APEX packages, and writes to `/path/to/lepton-output/repro-rootfs-auto/rootfs`. It refuses to overwrite an existing packaged target. **Do not point packaging scripts at a working Steam Deck rootfs or distribute the output without a separate license and security review.**

The native controller range correction is held in `image-14/patches/0007-eventhub-preserve-evdev-axes.patch` and is applied by the build script to the AOSP `frameworks/native` checkout. It preserves synthetic Wayland input ranges while restoring the evdev axis information of real controllers.

## Steam Deck input notes (experimental)

The checked-in `compat_tool/tools/lepton-gamescope-bridge` reflects a tested nested Gamescope configuration with `--default-touch-mode 4`. **That switch alone is not enough** for native touch on the Steam Deck. The Lepton Steam shortcut's Steam Input configuration must also enable:

**Controller Settings → Edit Layout → Default Action Set → Always-On Command → System → Touchscreen Native Support**

With this combination, touch worked in the tested 2048 application and RetroArch's menu (with RetroArch's Mouse Support disabled). Results are specific to the development configuration. A USB mouse is not a substitute for native touch and may behave inconsistently.

The experimental controller passthrough presently selects the first matching Steam virtual Xbox input device. Do not assume multi-controller or hotplug support. RetroArch may also require manual right-stick and trigger bindings.

## Upstream, attribution and licenses

This is a community modification of [Valve's public Lepton project](https://gitlab.steamos.cloud/frame-public/lepton). Retain Valve's copyright notices, third-party attribution, and the license headers in files taken from upstream. Valve's public GitLab is the authoritative upstream project; this repository is an independent experimental port.

**The repository is not covered by one universal license.** Read:

- [`LICENSE.md`](LICENSE.md) — Valve's top-level license index.
- [`LICENSES/compat_tool.md`](LICENSES/compat_tool.md) — MIT terms for the top level and compatibility tool, retaining Valve's notice.
- [`LICENSES/image.md`](LICENSES/image.md) — Android-image license information; the combined image has a GPL-3.0 declaration and its component projects retain their own licenses.
- [`LICENSES/x86_64-contributions.md`](LICENSES/x86_64-contributions.md) — terms for original standalone material written for this port; this does **not** relicense Valve, Android, Waydroid, Mesa, or other third-party code.

Source patches against upstream components retain the copyright and license requirements applicable to the code they modify. Building or distributing Android binaries would require a separate corresponding-source, third-party notice and license-compliance review. No Android binaries are included here.

## Contributing

Issues and patches reproducing problems on x86_64 Linux are welcome. Please include host hardware and OS, a precise launch configuration, relevant command output, and whether the problem reproduces without local modifications. Do not upload proprietary game files, Android images, Steam depot binaries, credentials, or personal logs.

The primary goal of this repository is reproducible technical investigation, not a claim of supported consumer compatibility.
