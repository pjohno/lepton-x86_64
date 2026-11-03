#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Apply the production service patch to its reviewed old-side contexts."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

PATCH = Path(__file__).resolve().parents[2] / 'image-14/android_vendor_valve/patches/base-patches-34/frameworks/base/0028-lepton-restore-app-framework-services.patch'


class FrameworkPatchTests(unittest.TestCase):
    def test_services_patch_applies_and_restores_only_required_services(self):
        old = ['\n'] * 2800
        position = None
        for line in PATCH.read_text().splitlines(keepends=True):
            match = re.match(r'@@ -(\d+)', line)
            if match:
                position = int(match[1]) - 1
            elif position is not None and line[:1] in (' ', '-'):
                old[position] = line[1:]
                position += 1
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'services/java/com/android/server/SystemServer.java'
            source.parent.mkdir(parents=True)
            source.write_text(''.join(old))
            subprocess.run(['git', 'apply', '--check', str(PATCH)], cwd=root, check=True)
            subprocess.run(['git', 'apply', str(PATCH)], cwd=root, check=True)
            patched = source.read_text()
            self.assertNotIn('/*\n        t.traceBegin("StartLocaleManagerService")', patched)
            self.assertNotIn('/*\n            t.traceBegin("StartCrossProfileAppsService")', patched)
            self.assertIn('/*\n            t.traceBegin("StartPeopleService")', patched)


if __name__ == '__main__':
    unittest.main()
