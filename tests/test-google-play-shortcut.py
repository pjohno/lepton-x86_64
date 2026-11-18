#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""lepton-add-game --google-play and --artwork, with temporary Steam fixtures
only (never this computer's Steam or Lepton installs)."""
import contextlib
import importlib.machinery
import importlib.util
import io
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
import zlib

SCRIPT = Path(__file__).resolve().parents[1] / 'compat_tool/tools/lepton-add-game'
GMS = 'compat_tool/images/rootfs/system/product/priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk'


def png(width, height):
    return b'\x89PNG\r\n\x1a\n' + struct.pack('>I', 13) + b'IHDR' + struct.pack('>II', width, height) + b'\x08\x06\x00\x00\x00' + b'\x00' * 16


def jpeg(width, height):
    sof = b'\xff\xc0' + struct.pack('>HBHHB', 11, 8, height, width, 1) + b'\x01\x11\x00'
    return b'\xff\xd8' + b'\xff\xe0' + struct.pack('>H', 16) + b'JFIF\x00' + b'\x00' * 9 + sof + b'\xff\xd9'


def ico():
    return b'\x00\x00\x01\x00\x01\x00' + bytes([64, 64]) + b'\x00' * 14


class GooglePlayShortcutTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / 'home'
        self.env = patch.dict(os.environ, {'HOME': str(self.home),
                                           'XDG_CONFIG_HOME': str(self.home / '.config'),
                                           'XDG_DATA_HOME': str(self.root / 'elsewhere')})
        self.env.start()
        self.addCleanup(self.env.stop)
        loader = importlib.machinery.SourceFileLoader('lepton_add_game_gp', str(SCRIPT))
        self.module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
        loader.exec_module(self.module)
        self.module.STEAM = self.steam = self.root / 'Steam'
        self.module.INSTALL = self.gapps = self.root / 'gapps'
        self.module.TOOL = 'lepton_gapps_x86_64'
        self.plain = self.root / 'plain'
        self.legacy_tool(self.gapps, 'lepton_gapps_x86_64', gapps=True)
        self.legacy_tool(self.plain, 'lepton_plain_x86_64', gapps=False)
        self.user = self.steam / 'userdata/123'
        (self.user / 'config').mkdir(parents=True)
        self.config = self.steam / 'config/config.vdf'
        self.config.parent.mkdir()
        self.config.write_text('"CompatToolMapping"\n{\n}\n')
        self.steam_running = False
        self.target = self.home / '.local/share/lepton-google-play/google-play.lepton-launch'
        self.expected_appid = zlib.crc32(('"%s"Google Play (Lepton)' % self.target).encode()) | 0x80000000

    def legacy_tool(self, location, tool, gapps):
        bridge = location / 'compat_tool/tools/lepton-gamescope-bridge'
        bridge.parent.mkdir(parents=True)
        bridge.touch()
        if gapps:
            (location / GMS).parent.mkdir(parents=True)
            (location / GMS).touch()
        registration = self.root / 'Steam/compatibilitytools.d' / (tool + '.vdf')
        registration.parent.mkdir(parents=True, exist_ok=True)
        registration.write_text('"install_path" "' + str(location / 'compat_tool') + '"\n')

    def run_tool(self, *args):
        out = io.StringIO()
        with patch.object(sys, 'argv', [str(SCRIPT), *args]), \
             patch.object(self.module, 'steam_running', return_value=self.steam_running), \
             patch.object(self.module, 'manage_module', side_effect=self.real_manage()), \
             contextlib.redirect_stdout(out):
            self.module.main()
        return out.getvalue()

    def real_manage(self):
        module = self.module
        original = module.manage_module
        cache = {}
        def wrapped():
            if 'm' not in cache:
                cache['m'] = original()
                steam = self.steam
                cache['m'].steam_root = lambda required=True: steam
            return cache['m']
        return lambda: wrapped()

    def shortcuts(self, user=None):
        path = (user or self.user) / 'config/shortcuts.vdf'
        return self.module.read_binary(path.read_bytes())[0]

    def snapshot(self):
        path = self.user / 'config/shortcuts.vdf'
        return (path.read_bytes() if path.exists() else None, self.config.read_bytes())

    # ---------------------------------------------------------- shortcut
    def test_creates_shortcut_without_apk(self):
        out = self.run_tool('--google-play')
        entries = self.shortcuts()
        self.assertEqual(len(entries), 1)
        entry = entries['0']
        self.assertEqual(entry['AppName'], 'Google Play (Lepton)')
        self.assertEqual(entry['Exe'], '"%s"' % self.target)
        self.assertEqual(entry['StartDir'], '"%s"' % self.target.parent)
        self.assertEqual(entry['appid'], self.expected_appid)
        self.assertIn('package=com.android.vending\n', self.target.read_text())
        self.assertFalse(list(self.target.parent.glob('*.apk')))
        config = self.config.read_text()
        self.assertIn('"%d"' % self.expected_appid, config)
        self.assertIn('"name"\t\t"lepton_gapps_x86_64"', config)
        self.assertIn('Steam AppID: %d' % self.expected_appid, out)
        self.assertIn('compatdata/%d' % self.expected_appid, out)

    def test_appid_is_stable_across_tools_and_environment(self):
        printed = self.run_tool('--google-play', '--print-appid').strip()
        self.assertEqual(int(printed), self.expected_appid)
        self.alt_gapps = self.root / 'gapps2'
        self.legacy_tool(self.alt_gapps, 'lepton_gapps2_x86_64', gapps=True)
        with patch.dict(os.environ, {'XDG_DATA_HOME': str(self.root / 'other')}):
            again = self.run_tool('--google-play', '--print-appid', '--tool-id', 'lepton_gapps2_x86_64',
                                  '--install-dir', str(self.alt_gapps)).strip()
        self.assertEqual(printed, again)

    def test_non_gapps_tool_is_rejected_without_changes(self):
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, 'no Google services'):
            self.run_tool('--google-play', '--tool-id', 'lepton_plain_x86_64', '--install-dir', str(self.plain))
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(self.target.exists())

    def test_gapps_detection_uses_selected_tool(self):
        self.run_tool('--google-play', '--dry-run')  # GApps default install passes
        (self.gapps / GMS).unlink()
        with self.assertRaisesRegex(ValueError, 'no Google services'):
            self.run_tool('--google-play', '--dry-run')

    def test_selected_tool_is_mapped(self):
        self.alt_gapps = self.root / 'gapps2'
        self.legacy_tool(self.alt_gapps, 'lepton_gapps2_x86_64', gapps=True)
        self.run_tool('--google-play', '--tool-id', 'lepton_gapps2_x86_64', '--install-dir', str(self.alt_gapps))
        self.assertIn('"name"\t\t"lepton_gapps2_x86_64"', self.config.read_text())
        # Legacy layout: the shortcut runs that install's bridge.
        self.assertIn(str(self.alt_gapps / 'compat_tool/tools/lepton-gamescope-bridge'),
                      self.shortcuts()['0']['LaunchOptions'])

    def test_self_contained_layout_needs_no_launch_options(self):
        tool = 'lepton_sc_x86_64'
        location = self.steam / 'compatibilitytools.d/lepton-sc'
        (location / 'compat_tool/tools').mkdir(parents=True)
        (location / 'compat_tool/tools/lepton-gamescope-bridge').touch()
        (location / 'compat_tool/lepton-x86_64-entry').touch()
        (location / 'compat_tool/toolmanifest.vdf').write_text('"commandline" "/compat_tool/lepton-x86_64-entry %verb% --"\n')
        (location / GMS).parent.mkdir(parents=True)
        (location / GMS).touch()
        (location / 'compatibilitytool.vdf').write_text(
            '"compatibilitytools"\n{\n "compat_tools"\n {\n  "%s"\n  {\n   "install_path" "."\n  }\n }\n}\n' % tool)
        self.run_tool('--google-play', '--tool-id', tool, '--install-dir', str(location))
        self.assertEqual(self.shortcuts()['0']['LaunchOptions'], '')
        self.assertIn('"name"\t\t"%s"' % tool, self.config.read_text())

    def test_existing_shortcut_is_left_intact(self):
        self.run_tool('--google-play')
        before = self.snapshot()
        out = self.run_tool('--google-play')
        self.assertEqual(self.snapshot(), before)
        self.assertIn('already in Steam', out)
        self.assertEqual(len(self.shortcuts()), 1)

    def test_renamed_and_customised_shortcut_is_not_duplicated_or_changed(self):
        self.run_tool('--google-play')
        path = self.user / 'config/shortcuts.vdf'
        # The user renamed it and changed its launch options and tool in Steam.
        data = path.read_bytes().replace(b'Google Play (Lepton)\x00', b'My Store\x00')
        data = data.replace(b'LaunchOptions\x00', b'LaunchOptions\x00X=1 ', 1)
        path.write_bytes(data)
        self.config.write_text(self.config.read_text().replace('lepton_gapps_x86_64', 'proton_experimental'))
        before = self.snapshot()
        out = self.run_tool('--google-play')
        self.assertEqual(self.snapshot(), before)
        self.assertIn('"My Store"', out)
        self.assertIn('Steam AppID: %d' % self.expected_appid, out)

    def test_install_is_idempotent_and_repairs_launch_file(self):
        self.run_tool('--google-play')
        self.target.unlink()
        before = self.snapshot()
        self.run_tool('--google-play')
        self.assertEqual(self.snapshot(), before)
        self.assertTrue(self.target.is_file())

    def test_running_steam_is_refused_and_dry_run_allowed(self):
        self.steam_running = True
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, 'Steam is still running.*Nothing was changed'):
            self.run_tool('--google-play')
        with self.assertRaisesRegex(ValueError, 'Steam is still running'):
            self.run_tool('--google-play', '--artwork', 'portrait=' + str(self.image('a.png', png(600, 900))))
        out = self.run_tool('--google-play', '--dry-run')
        self.assertIn('PASS', out)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(self.target.exists())

    def test_multiple_users_need_a_choice(self):
        other = self.steam / 'userdata/456'
        (other / 'config').mkdir(parents=True)
        (self.steam / 'config/loginusers.vdf').write_text(
            '"users"\n{\n\t"%d"\n\t{\n\t\t"AccountName"\t\t"acct"\n\t\t"PersonaName"\t\t"Player Two"\n\t}\n}\n'
            % (76561197960265728 + 456))
        with self.assertRaisesRegex(ValueError, 'Found 2 Steam users; specify --userdata'):
            self.run_tool('--google-play')
        users = self.run_tool('--list-users').splitlines()
        self.assertEqual(users, ['%s\tSteam user 123' % self.user, '%s\tPlayer Two' % other])
        self.run_tool('--google-play', '--userdata', str(other))
        self.assertFalse((self.user / 'config/shortcuts.vdf').exists())
        self.assertEqual(self.shortcuts(other)['0']['appid'], self.expected_appid)
        status = self.run_tool('--google-play', '--status').splitlines()
        self.assertEqual(status[0], '%s\t-\t' % self.user)
        self.assertEqual(status[1], '%s\t%d\tGoogle Play (Lepton)\t' % (other, self.expected_appid))

    def test_apk_and_google_play_are_exclusive(self):
        apk = self.root / 'game.apk'
        apk.touch()
        with self.assertRaisesRegex(ValueError, 'takes no APK'):
            self.run_tool(str(apk), '--google-play')
        with self.assertRaisesRegex(ValueError, 'need --google-play'):
            self.run_tool(str(apk), '--artwork', 'icon=x.png')

    # ---------------------------------------------------------- artwork
    def image(self, name, data):
        path = self.root / 'Downloads' / name
        path.parent.mkdir(exist_ok=True)
        path.write_bytes(data)
        return path

    def grid(self):
        return self.user / 'config/grid'

    def test_artwork_filenames_use_shortcut_appid(self):
        appid = self.expected_appid
        out = self.run_tool('--google-play',
                            '--artwork', 'portrait=' + str(self.image('cover.png', png(600, 900))),
                            '--artwork', 'horizontal=' + str(self.image('wide.jpeg', jpeg(920, 430))),
                            '--artwork', 'hero=' + str(self.image('hero.png', png(1920, 620))),
                            '--artwork', 'logo=' + str(self.image('logo.png', png(640, 360))),
                            '--artwork', 'icon=' + str(self.image('icon.ico', ico())))
        names = sorted(p.name for p in self.grid().iterdir())
        self.assertEqual(names, sorted(['%dp.png' % appid, '%d.jpg' % appid, '%d_hero.png' % appid,
                                        '%d_logo.png' % appid, '%d_icon.ico' % appid]))
        self.assertEqual(self.shortcuts()['0']['icon'], str(self.grid() / ('%d_icon.ico' % appid)))
        self.assertEqual((self.grid() / ('%dp.png' % appid)).read_bytes(), png(600, 900))
        self.assertIn('Imported Portrait', out)
        # SteamGridDB's game ID never appears in a filename.
        self.assertFalse(any('5451976' in n for n in names))

    def test_partial_artwork_and_later_import_keep_shortcut(self):
        self.run_tool('--google-play', '--artwork', 'hero=' + str(self.image('hero.png', png(1920, 620))))
        self.assertEqual([p.name for p in self.grid().iterdir()], ['%d_hero.png' % self.expected_appid])
        before = (self.user / 'config/shortcuts.vdf').read_bytes()
        config = self.config.read_bytes()
        self.run_tool('--google-play', '--artwork-only', '--artwork', 'portrait=' + str(self.image('p.png', png(600, 900))))
        self.assertEqual((self.user / 'config/shortcuts.vdf').read_bytes(), before)
        self.assertEqual(self.config.read_bytes(), config)
        self.assertEqual(len(list(self.grid().iterdir())), 2)
        status = self.run_tool('--google-play', '--status').strip().split('\t')
        self.assertEqual(status[3], 'portrait,hero')

    def test_artwork_only_needs_existing_shortcut(self):
        with self.assertRaisesRegex(ValueError, 'not in Steam yet'):
            self.run_tool('--google-play', '--artwork-only', '--artwork', 'hero=' + str(self.image('h.png', png(10, 10))))
        self.assertFalse((self.user / 'config/shortcuts.vdf').exists())
        self.assertFalse(self.grid().exists())

    def test_invalid_artwork_changes_nothing(self):
        fake = self.image('cover.png', b'<html>not an image</html>')
        empty = self.image('empty.png', b'')
        for args in (['portrait=' + str(fake)], ['portrait=' + str(empty)],
                     ['portrait=' + str(self.root / 'missing.png')],
                     ['logo=' + str(self.image('logo.jpg', jpeg(10, 10)))],
                     ['icon=' + str(self.image('i.jpg', jpeg(10, 10)))],
                     ['banner=' + str(self.image('b.png', png(10, 10)))],
                     ['hero=' + str(self.image('h.png', png(10, 10))), 'hero=' + str(self.image('h2.png', png(10, 10)))]):
            with self.subTest(args=args):
                with self.assertRaises(ValueError):
                    self.run_tool('--google-play', *[x for a in args for x in ('--artwork', a)])
                self.assertFalse((self.user / 'config/shortcuts.vdf').exists())
                self.assertFalse(self.grid().exists())

    def test_existing_artwork_is_kept_unless_replacement_confirmed(self):
        self.run_tool('--google-play')
        appid = self.expected_appid
        self.grid().mkdir()
        (self.grid() / ('%dp.png' % appid)).write_bytes(b'user artwork')
        new = str(self.image('new.jpg', jpeg(600, 900)))
        out = self.run_tool('--google-play', '--artwork-only', '--artwork', 'portrait=' + new)
        self.assertIn('Kept existing', out)
        self.assertEqual((self.grid() / ('%dp.png' % appid)).read_bytes(), b'user artwork')
        self.assertFalse((self.grid() / ('%dp.jpg' % appid)).exists())
        self.run_tool('--google-play', '--artwork-only', '--artwork', 'portrait=' + new, '--replace-artwork', 'portrait')
        self.assertEqual([p.name for p in self.grid().iterdir()], ['%dp.jpg' % appid])

    def test_icon_set_by_user_in_steam_is_kept(self):
        self.run_tool('--google-play')
        path = self.user / 'config/shortcuts.vdf'
        path.write_bytes(path.read_bytes().replace(b'\x01icon\x00\x00', b'\x01icon\x00/my/icon.png\x00'))
        out = self.run_tool('--google-play', '--artwork-only', '--artwork', 'icon=' + str(self.image('i.png', png(64, 64))))
        self.assertIn('Kept existing', out)
        self.assertEqual(self.shortcuts()['0']['icon'], '/my/icon.png')
        self.assertFalse(self.grid().exists())

    def test_reinstall_keeps_artwork(self):
        self.run_tool('--google-play', '--artwork', 'hero=' + str(self.image('hero.png', png(1920, 620))))
        hero = self.grid() / ('%d_hero.png' % self.expected_appid)
        before = hero.read_bytes()
        self.run_tool('--google-play')  # e.g. a later bundle upgrade
        self.assertEqual(hero.read_bytes(), before)


if __name__ == '__main__':
    unittest.main(verbosity=1)
