#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Static checks for the VA-API video configuration (image-14/docs/video-vaapi.md).

Guards against regressions found during development: launcher properties that
lose to vendor defaults, Mesa building hardware encoders, the experimental
zero-copy allocator patch being applied, and video patches missing from the
preparation or provenance lists.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
DEVICE = ROOT / 'image-14/android_device_valve_lepton'
PREPARE = (ROOT / 'image-14/scripts/prepare-x86_64.sh').read_text()
PROVENANCE = (ROOT / 'image-14/scripts/lib/image-provenance.sh').read_text()
VIDEO_PATCHES = {
    '0017-ffmpeg-x86_64-without-vulkan.patch': 'external/ffmpeg',
    '0018-stagefright-plugins-without-raw-codec-data.patch': 'external/stagefright-plugins',
    '0019-mesa-android-gallium-va.patch': 'external/mesa',
    '0020-intel-media-driver-android14-clang.patch': 'external/intel-media-driver',
    '0021-stagefright-plugins-drm-prime-buffer-id.patch': 'external/stagefright-plugins',
    '0023-stagefright-plugins-hw-download-native-format.patch': 'external/stagefright-plugins',
    '0024-stagefright-plugins-va-capabilities-and-diagnostics.patch': 'external/stagefright-plugins',
    '0025-stagefright-plugins-hevc-main10-profile.patch': 'external/stagefright-plugins',
    '0026-stagefright-plugins-va-max-picture-size.patch': 'external/stagefright-plugins',
    '0027-frameworks-av-codec2-ffmpeg-size-limits.patch': 'frameworks/av',
    '0028-stagefright-plugins-copy-back-step-timing.patch': 'external/stagefright-plugins',
    '0029-stagefright-plugins-copy-back-download.patch': 'external/stagefright-plugins',
}


class VideoVaapiConfigTests(unittest.TestCase):
    def test_off_defaults_precede_the_launcher_import(self):
        board = (DEVICE / 'lepton_x86_64/BoardConfig.mk').read_text()
        self.assertIn('TARGET_SYSTEM_PROP := $(DEVICE_PATH)/lepton_x86_64/video-defaults.prop $(TARGET_SYSTEM_PROP)',
                      board)
        defaults = (DEVICE / 'lepton_x86_64/video-defaults.prop').read_text()
        self.assertIn('debug.ffmpeg-codec2.rank=4294967295', defaults)
        self.assertIn('media.sf.hwaccel=0', defaults)
        # Vendor properties load after /vendor/waydroid.prop and would win.
        device = (DEVICE / 'device.mk').read_text()
        self.assertNotRegex(device, r'PRODUCT_VENDOR_PROPERTIES[^\n]*\n(\s+[^\n]*\\\n)*\s*(debug\.ffmpeg-codec2|media\.sf\.hwaccel)')

    def test_mesa_builds_decoders_only(self):
        board = (DEVICE / 'lepton_x86_64/BoardConfig.mk').read_text()
        codecs = re.search(r'-Dvideo-codecs=(\S+)', board).group(1).split(',')
        self.assertTrue(codecs)
        self.assertTrue(all(c.endswith('dec') for c in codecs), codecs)
        self.assertIn('h264dec', codecs)

    def test_video_patches_registered_and_zero_copy_allocator_patch_not_applied(self):
        applied = re.findall(r'^apply_custom (\S+) /workspace/patches/(\S+)', PREPARE, flags=re.M)
        names = [name for _, name in applied]
        for name, project in VIDEO_PATCHES.items():
            self.assertTrue((ROOT / 'image-14/patches' / name).is_file(), name)
            self.assertIn(f'"$IMAGE/patches/{name}"', PREPARE)
            self.assertIn(f'"{project}|{name}"', PROVENANCE)
            self.assertIn(name, names)
        self.assertEqual(sorted(VIDEO_PATCHES), [n for n in names if n in VIDEO_PATCHES])
        self.assertTrue((ROOT / 'image-14/patches/experimental/0022-minigbm-gbm-mesa-nv12-video-layout.patch').is_file())
        self.assertNotIn('0022-minigbm', PREPARE)
        self.assertNotIn('0022-minigbm', PROVENANCE)


if __name__ == '__main__':
    unittest.main()
