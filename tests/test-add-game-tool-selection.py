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

    def run_with_steam(self, running, *args):
        with patch.object(sys, 'argv', [str(SCRIPT), str(self.apk), *args]), \
             patch.object(self.module, 'steam_running', return_value=running), \
             contextlib.redirect_stdout(io.StringIO()):
            self.module.main()

    def test_running_steam_fails_without_changes(self):
        original = self.config.read_bytes()
        with self.assertRaisesRegex(ValueError, 'Steam is still running.*Nothing was changed'):
            self.run_with_steam(True)
        self.assertFalse((self.user / 'shortcuts.vdf').exists())
        self.assertEqual(self.config.read_bytes(), original)

    def test_dry_run_allowed_while_steam_runs(self):
        self.run_with_steam(True, '--dry-run')
        self.assertFalse((self.user / 'shortcuts.vdf').exists())

    def test_never_controls_steam(self):
        # The helper must not be able to close or start Steam.
        source = SCRIPT.read_text()
        for forbidden in ('subprocess', 'os.system', 'Popen', '-shutdown', '--restart-steam'):
            self.assertNotIn(forbidden, source)
        with self.assertRaises(SystemExit):
            with patch.object(sys, 'argv', [str(SCRIPT), str(self.apk), '--restart-steam']), \
                 contextlib.redirect_stderr(io.StringIO()):
                self.module.main()

    def make_self_contained(self, location):
        (location / 'compat_tool/toolmanifest.vdf').write_text('"manifest"\n{\n "commandline" "/lepton-x86_64-entry %verb% --"\n}\n')
        (location / 'compat_tool/lepton-x86_64-entry').touch()

    def test_self_contained_tool_gets_empty_launch_options(self):
        self.make_self_contained(self.module.INSTALL)
        self.run_main()
        entries, _, _ = self.module.read_binary((self.user / 'shortcuts.vdf').read_bytes())
        self.assertEqual(entries['0']['LaunchOptions'], '')

    def test_self_contained_hotplug_is_the_only_option(self):
        self.make_self_contained(self.module.INSTALL)
        self.run_main('--hotplug')
        entries, _, _ = self.module.read_binary((self.user / 'shortcuts.vdf').read_bytes())
        self.assertEqual(entries['0']['LaunchOptions'], 'LEPTON_GAMEPAD_HOTPLUG=true %command%')

    def test_legacy_tool_keeps_bridge_launch_options(self):
        self.run_main()
        entries, _, _ = self.module.read_binary((self.user / 'shortcuts.vdf').read_bytes())
        self.assertIn('lepton-gamescope-bridge %command%', entries['0']['LaunchOptions'])

    def appid(self, name='game'):
        return self.module.zlib.crc32(('"' + str(self.apk) + '"' + name).encode()) | 0x80000000

    def leave_deleted_shortcut(self, tool='lepton_removed_tool'):
        # What Steam leaves after a shortcut is deleted: no shortcuts.vdf entry,
        # but its CompatToolMapping entry and (after a launch) its compatdata.
        self.config.write_text(
            '"InstallConfigStore"\n{\n\t"CompatToolMapping"\n\t{\n'
            '\t\t"' + str(self.appid()) + '"\n\t\t{\n\t\t\t"name"\t\t"' + tool + '"\n'
            '\t\t\t"config"\t\t""\n\t\t\t"priority"\t\t"250"\n\t\t}\n'
            '\t\t"7"\n\t\t{\n\t\t\t"name"\t\t"proton_9"\n\t\t}\n\t}\n}\n')
        data = self.module.STEAM / 'steamapps/compatdata' / str(self.appid())
        data.mkdir(parents=True)
        return data

    def run_main_output(self, *args):
        out = io.StringIO()
        with patch.object(sys, 'argv', [str(SCRIPT), str(self.apk), *args]), \
             patch.object(self.module, 'steam_running', return_value=False), \
             contextlib.redirect_stdout(out):
            self.module.main()
        return out.getvalue()

    def test_readd_after_deleted_shortcut_replaces_leftover_mapping(self):
        data = self.leave_deleted_shortcut()
        (data / 'keep').write_text('saved game')
        dry = self.run_main_output('--dry-run')
        self.assertIn('Replacing the compatibility tool left by a deleted shortcut (lepton_removed_tool)', dry)
        self.assertNotIn(self.module.TOOL, self.config.read_text())
        output = self.run_main_output()
        text = self.config.read_text()
        self.assertEqual(text.count('"' + str(self.appid()) + '"'), 1)
        self.assertIn('"name"\t\t"' + self.module.TOOL + '"', text)
        self.assertNotIn('lepton_removed_tool', text)
        self.assertIn('"proton_9"', text)  # other games' mappings are untouched
        self.assertIn('Reusing the saved game data', output)
        self.assertEqual((data / 'keep').read_text(), 'saved game')  # never deleted
        entries, _, _ = self.module.read_binary((self.user / 'shortcuts.vdf').read_bytes())
        self.assertEqual(entries['0']['appid'], self.appid())
        # With the shortcut back, adding it again is a duplicate (with a hint
        # for shortcuts Steam has not finished deleting).
        with self.assertRaisesRegex(ValueError, '(?s)already exists.*restart the Steam Deck'):
            self.run_main()

    def test_deleted_google_game_needs_gapps_tool_or_new_name(self):
        data = self.leave_deleted_shortcut()
        (data / 'lepton-google-game').touch()
        original = self.config.read_bytes()
        with self.assertRaisesRegex(ValueError, 'Google game.*different name'):
            self.run_main()
        self.assertEqual(self.config.read_bytes(), original)
        self.assertFalse((self.user / 'shortcuts.vdf').exists())
        # A new name is a new AppID with fresh data.
        output = self.run_main_output('--name', 'game (base)')
        self.assertNotIn('Reusing', output)
        self.assertIn('"' + str(self.appid('game (base)')) + '"', self.config.read_text())

    def test_deleted_google_game_data_reused_by_gapps_tool(self):
        (self.leave_deleted_shortcut() / 'lepton-google-game').touch()
        gms = self.module.INSTALL / self.module.GOOGLE_SERVICES_APK
        gms.parent.mkdir(parents=True)
        gms.touch()
        self.assertIn('Reusing the saved game data', self.run_main_output())

    def test_unexpected_mapping_shape_is_not_overwritten(self):
        self.config.write_text('"CompatToolMapping"\n{\n"' + str(self.appid()) + '"\n{\n"x"\n{\n}\n}\n}\n')
        with self.assertRaisesRegex(ValueError, 'unexpected mapping'):
            self.run_main()
        self.assertFalse((self.user / 'shortcuts.vdf').exists())

    def test_invalid_tool_id_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Invalid compatibility-tool ID'):
            self.run_main('--tool-id', '../wrong')


if __name__ == '__main__':
    unittest.main()
