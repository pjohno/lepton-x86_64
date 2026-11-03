#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Exercise alternate Steam tool registration using only temporary fixtures."""
import contextlib
import importlib.machinery
import importlib.util
import io
import shlex
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'compat_tool/tools/lepton-add-game'


class ToolSelectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        loader = importlib.machinery.SourceFileLoader('lepton_add_game_test', str(SCRIPT))
        self.module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
        loader.exec_module(self.module)
        self.module.STEAM = self.root / 'Steam'
        self.module.INSTALL = self.root / 'standard'
        self.alt = self.root / 'ndk'
        for location, tool in [(self.module.INSTALL, self.module.TOOL), (self.alt, 'lepton_ndk_x86_64_dev')]:
            bridge = location / 'compat_tool/tools/lepton-gamescope-bridge'
            bridge.parent.mkdir(parents=True)
            bridge.touch()
            registration = self.module.STEAM / 'compatibilitytools.d' / (tool + '.vdf')
            registration.parent.mkdir(parents=True, exist_ok=True)
            registration.write_text('"install_path" "' + str(location / 'compat_tool') + '"\n')
        self.user = self.module.STEAM / 'userdata/123/config'
        self.user.mkdir(parents=True)
        self.config = self.module.STEAM / 'config/config.vdf'
        self.config.parent.mkdir()
        self.config.write_text('"CompatToolMapping"\n{\n}\n')
        self.apk = self.root / 'game.apk'
        self.apk.touch()

    def run_main(self, *args):
        with patch.object(sys, 'argv', [str(SCRIPT), str(self.apk), *args]), \
             patch.object(self.module, 'steam_running', return_value=False), \
             contextlib.redirect_stdout(io.StringIO()):
            self.module.main()

    def test_default_dry_run_does_not_write(self):
        original = self.config.read_bytes()
        self.run_main('--dry-run')
        self.assertEqual(self.config.read_bytes(), original)
        self.assertFalse((self.user / 'shortcuts.vdf').exists())
        self.assertEqual(self.module.TOOL, 'lepton_x86_64_dev')

    def test_alternate_tool_controls_mapping_and_launcher(self):
        self.run_main('--tool-id', 'lepton_ndk_x86_64_dev', '--install-dir', str(self.alt))
        self.assertIn('"name"\t\t"lepton_ndk_x86_64_dev"', self.config.read_text())
        entries, _, _ = self.module.read_binary((self.user / 'shortcuts.vdf').read_bytes())
        self.assertIn(str(self.alt / 'compat_tool/tools/lepton-gamescope-bridge'), entries['0']['LaunchOptions'])

    def test_alternate_tool_requires_explicit_install(self):
        with self.assertRaisesRegex(ValueError, '--install-dir is required'):
            self.run_main('--tool-id', 'lepton_ndk_x86_64_dev')

    def test_registration_mismatch_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'does not match'):
            self.run_main('--tool-id', 'lepton_ndk_x86_64_dev', '--install-dir', str(self.module.INSTALL))
        self.assertFalse((self.user / 'shortcuts.vdf').exists())

    def prepare_profile(self):
        runner = self.alt / 'tests/runtime/run-apk.sh'
        runner.parent.mkdir(parents=True)
        runner.touch()
        profile = self.alt / '.runtime-profile.playgames-native'
        profile.mkdir()
        (profile / 'profile-fingerprint').write_text('test')
        self.apk = self.root / 'Play Games.apkm'
        self.apk.touch()
        return runner

    def test_profile_apkm_uses_runner_and_keeps_steam_mapping_unchanged(self):
        runner = self.prepare_profile()
        # A runtime profile needs no registered compatibility tool.
        (self.module.STEAM / 'compatibilitytools.d/lepton_x86_64_dev.vdf').unlink()
        original = self.config.read_bytes()
        self.run_main('--install-dir', str(self.alt), '--runtime-profile', 'playgames-native')
        self.assertEqual(self.config.read_bytes(), original)
        entries, _, _ = self.module.read_binary((self.user / 'shortcuts.vdf').read_bytes())
        entry = entries['0']
        self.assertEqual(entry['Exe'], '"/usr/bin/bash"')
        options = shlex.split(entry['LaunchOptions'])
        tail = options[options.index('%command%') + 1:]
        self.assertEqual(tail[0], str(runner))
        self.assertEqual(tail[tail.index('--apk') + 1], str(self.apk))
        self.assertEqual(tail[tail.index('--profile') + 1], 'playgames-native')
        self.assertIn('--until-exit', tail)
        self.assertNotIn('--accept-runtime-update', tail)

    def test_profile_dry_run_and_duplicate_guard(self):
        self.prepare_profile()
        args = ('--install-dir', str(self.alt), '--runtime-profile', 'playgames-native')
        self.run_main(*args, '--dry-run')
        self.assertFalse((self.user / 'shortcuts.vdf').exists())
        self.run_main(*args)
        with self.assertRaisesRegex(ValueError, 'already exists'):
            self.run_main(*args, '--name', 'Different display name')

    def test_profile_requires_saved_setup(self):
        with self.assertRaisesRegex(ValueError, 'saved profile missing'):
            self.run_main('--install-dir', str(self.alt), '--runtime-profile', 'playgames-native')
        self.assertFalse((self.user / 'shortcuts.vdf').exists())

    def test_invalid_tool_id_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Invalid compatibility-tool ID'):
            self.run_main('--tool-id', '../wrong')


if __name__ == '__main__':
    unittest.main()
