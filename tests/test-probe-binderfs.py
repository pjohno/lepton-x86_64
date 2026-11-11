#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""BinderFS probe: devices the kernel pre-creates are used, not re-allocated."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PROBE = Path(__file__).resolve().parents[1] / 'image-14/scripts/internal/probe-binderfs.py'
NAMES = ('binder', 'hwbinder', 'vndbinder')


class ProbeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        # A regular file: any BINDER_CTL_ADD ioctl on it fails (ENOTTY).
        (self.root / 'binder-control').touch()

    def probe(self):
        return subprocess.run([sys.executable, '-I', str(PROBE), str(self.root)],
                              capture_output=True, text=True)

    def test_precreated_devices_pass_without_allocation(self):
        # As with CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder".
        for name in NAMES:
            (self.root / name).symlink_to('/dev/null')
        result = self.probe()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_device_is_allocated(self):
        for name in NAMES[:2]:
            (self.root / name).symlink_to('/dev/null')
        result = self.probe()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('allocation/access failed', result.stderr)

    def test_existing_non_device_is_refused(self):
        for name in NAMES:
            (self.root / name).touch()
        result = self.probe()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not a character device', result.stderr)


if __name__ == '__main__':
    unittest.main()
