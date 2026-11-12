#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate isolated registration and refusal to overwrite another tool."""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'compat_tool/tools/lepton-register-tool'
loader = importlib.machinery.SourceFileLoader('register_tool', str(SCRIPT))
module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(module)


class RegistrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / 'home'
        self.root = Path(self.temp.name) / 'GApps bundle'
        (self.root / 'compat_tool/sysbake/system').mkdir(parents=True)
        (self.root / 'compat_tool/lepton').touch()
        (self.root / 'compat_tool/sysbake/system/packages.xml').touch()
        (self.root / 'BUNDLE.json').write_text(json.dumps(dict(tool_id='lepton_gapps_v1', display_name='Lepton "GApps"')))

    def register(self, execute=False, replace=False):
        with contextlib.redirect_stdout(io.StringIO()):
            return module.register(self.root, self.home, execute, replace)

    def expected(self, from_os):
        return ('"compatibilitytools"\n{\n  "compat_tools"\n  {\n    "lepton_gapps_v1"\n    {\n'
                '      "install_path" ' + json.dumps(str(self.root / 'compat_tool')) + '\n'
                '      "display_name" "Lepton \\"GApps\\""\n'
                '      "from_oslist" "' + from_os + '"\n      "to_oslist" "linux"\n    }\n  }\n}\n')

    def test_registers_android_to_linux(self):
        target = self.register(True)
        self.assertEqual(target.read_text(), self.expected('android'))
        self.assertNotIn('windows', target.read_text())

    def test_legacy_windows_registration_is_migrated_in_place(self):
        target = self.register(True)
        target.write_text(self.expected('windows'))
        self.register()  # --check reports the update but changes nothing
        self.assertEqual(target.read_text(), self.expected('windows'))
        self.register(True)  # plain --execute, as a --replace reinstall runs it
        self.assertEqual(target.read_text(), self.expected('android'))

    def test_legacy_registration_for_another_path_is_not_migrated(self):
        target = self.register(True)
        other = self.expected('windows').replace(str(self.root), '/elsewhere')
        target.write_text(other)
        with self.assertRaisesRegex(ValueError, 'already registered elsewhere'):
            self.register(True)
        with self.assertRaisesRegex(ValueError, 'already registered elsewhere'):
            self.register(True, replace=True)
        self.assertEqual(target.read_text(), other)

    def test_check_creates_no_files(self):
        self.register()
        self.assertFalse(self.home.exists())

    def test_registration_preserves_other_tools_and_is_idempotent(self):
        directory = self.home / '.local/share/Steam/compatibilitytools.d'
        directory.mkdir(parents=True)
        existing = directory / 'lepton_x86_64_dev.vdf'
        existing.write_text('old working installation')
        target = self.register(True)
        self.assertIn(str(self.root / 'compat_tool'), target.read_text())
        self.assertIn('Lepton \\"GApps\\"', target.read_text())
        self.register(True)
        self.assertEqual(existing.read_text(), 'old working installation')

    def test_conflicting_tool_id_is_not_overwritten(self):
        target = self.register(True)
        target.write_text('another installation')
        with self.assertRaisesRegex(ValueError, 'already registered elsewhere'):
            self.register(True)
        self.assertEqual(target.read_text(), 'another installation')

    def test_symlink_registration_is_refused(self):
        target = self.register(True)
        other = self.home / 'other'
        other.write_text('keep')
        target.unlink()
        target.symlink_to(other)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            self.register(True)
        self.assertEqual(other.read_text(), 'keep')


if __name__ == '__main__':
    unittest.main()
