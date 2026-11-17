#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Steam directory resolution, both installation layouts, self-contained
registration and version-first names. Throwaway homes; no real Steam."""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

TOOLS = Path(__file__).resolve().parents[1] / 'compat_tool/tools'
sys.path.insert(0, str(TOOLS))
import lepton_bundle_lib as L  # noqa: E402


def load(name):
    loader = importlib.machinery.SourceFileLoader(name.replace('-', '_'), str(TOOLS / name))
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    loader.exec_module(module)
    return module


class Home(unittest.TestCase):
    """A throwaway home with a native Steam folder (~/.local/share/Steam)."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / 'home'
        self.steam = self.home / '.local/share/Steam'
        self.steam.mkdir(parents=True)
        env = {k: v for k, v in os.environ.items() if not k.startswith(('XDG_', 'LEPTON_'))}
        env['HOME'] = str(self.home)
        patcher = mock.patch.dict(os.environ, env, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)

    def manage(self):
        return load('lepton-manage-installs')

    def tools(self):
        path = self.steam / 'compatibilitytools.d'
        path.mkdir(exist_ok=True)
        return path

    def lepton(self, directory, tool, name='Lepton', complete=True):
        """A Lepton install directory (not registered)."""
        (directory / 'compat_tool/liblepton').mkdir(parents=True)
        (directory / 'compat_tool/sysbake/system').mkdir(parents=True)
        for path in ('compat_tool/lepton', 'compat_tool/sysbake/system/packages.xml'):
            (directory / path).write_text('#!/bin/sh\n')
        (directory / 'compat_tool/lepton-x86_64-entry').write_text('#!/bin/sh\n')
        (directory / 'compat_tool/toolmanifest.vdf').write_text(
            '"manifest"\n{\n\t"commandline" "/lepton-x86_64-entry %verb% --"\n\t"version" "2"\n'
            '\t"use_tool_subprocess_reaper" "1"\n\t"compatmanager_layer_name" "lepton"\n}\n')
        if complete:
            (directory / 'BUNDLE.json').write_text(json.dumps(dict(
                format_version=2, bundle_id='v0.1.0-alpha', tool_id=tool, display_name=name,
                install_directory=directory.name, gapps=False, ndk=False, widevine=False)))
        return directory

    def legacy(self, tool, name='Lepton legacy', env=True):
        directory = self.lepton(self.home / '.local/share' / tool, tool, name)
        (self.tools() / (tool + '.vdf')).write_text(
            '"compatibilitytools"\n{\n "compat_tools"\n {\n  "%s"\n  {\n   "install_path" "%s/compat_tool"\n'
            '   "display_name" "%s"\n  }\n }\n}\n' % (tool, directory, name))
        if env:
            config = self.home / '.config/lepton-x86_64'
            config.mkdir(parents=True, exist_ok=True)
            (config / (tool + '.env')).write_text('LEPTON_X86_TOOL_ID=%s\nLEPTON_X86_INSTALL_DIR=%s\n' % (tool, directory))
        return directory

    def self_contained(self, tool, name='Lepton steam', directory=None):
        directory = self.lepton(self.tools() / (directory or tool), tool, name)
        with contextlib.redirect_stdout(io.StringIO()):
            load('lepton-register-tool').register(directory, self.home, execute=True)
        return directory


class SteamRootTests(Home):
    def test_native_steam_folder(self):
        self.assertEqual(self.manage().steam_root(), self.steam.resolve())

    def test_steam_root_link_to_the_same_folder_is_one_installation(self):
        (self.home / '.steam').mkdir()
        (self.home / '.steam/root').symlink_to('../.local/share/Steam')
        (self.home / '.steam/steam').symlink_to('../.local/share/Steam')
        self.assertEqual(self.manage().steam_root(), self.steam.resolve())

    def test_steam_root_elsewhere_in_home(self):
        self.steam.rmdir()
        installation = self.home / '.steam/debian-installation'
        installation.mkdir(parents=True)
        (self.home / '.steam/root').symlink_to('debian-installation')
        self.assertEqual(self.manage().steam_root(), installation.resolve())

    def test_two_different_steam_folders_are_refused(self):
        other = self.home / '.steam/debian-installation'
        other.mkdir(parents=True)
        (self.home / '.steam/root').symlink_to('debian-installation')
        with self.assertRaisesRegex(ValueError, 'Two different Steam directories'):
            self.manage().steam_root()
        os.environ['LEPTON_STEAM_ROOT'] = str(other)
        self.assertEqual(self.manage().steam_root(), other.resolve())

    def test_missing_and_flatpak_steam(self):
        self.steam.rmdir()
        with self.assertRaisesRegex(ValueError, 'Steam not found'):
            self.manage().steam_root()
        self.assertIsNone(self.manage().steam_root(required=False))
        (self.home / '.var/app/com.valvesoftware.Steam').mkdir(parents=True)
        with self.assertRaisesRegex(ValueError, 'Flatpak'):
            self.manage().steam_root()
        self.assertFalse(self.steam.exists(), 'a Steam folder was made up')

    def test_broken_steam_root_link_is_ignored(self):
        (self.home / '.steam').mkdir()
        (self.home / '.steam/root').symlink_to('/nonexistent/Steam')
        self.assertEqual(self.manage().steam_root(), self.steam.resolve())

    def test_untrusted_links_and_permissions(self):
        outside = Path(self.temp.name) / 'outside'
        outside.mkdir()
        (self.home / '.steam').mkdir()
        (self.home / '.steam/root').symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'does not look like Steam'):
            self.manage().steam_root()
        (outside / 'steam.sh').touch()   # a Steam folder on another drive is fine
        self.steam.rmdir()
        self.assertEqual(self.manage().steam_root(), outside.resolve())
        outside.chmod(0o777)
        self.addCleanup(outside.chmod, 0o755)
        with self.assertRaisesRegex(ValueError, 'writable by every user'):
            self.manage().steam_root()

    def test_compat_tools_folder_is_created_only_on_request(self):
        manage = self.manage()
        path = manage.compat_tools_dir()
        self.assertFalse(path.exists())
        self.assertEqual(manage.compat_tools_dir(create=True), path)
        self.assertTrue(path.is_dir())


class DiscoveryTests(Home):
    def listing(self):
        return {e['dir']: e for e in self.manage().discover()}

    def test_both_layouts_side_by_side(self):
        legacy = self.legacy('lepton_a', 'Lepton A')
        steam = self.self_contained('lepton_b', 'Lepton B')
        found = self.listing()
        self.assertEqual(found[str(legacy.resolve())]['layout'], 'legacy')
        self.assertEqual(found[str(steam.resolve())]['layout'], 'steam-compat')
        self.assertEqual({e['id'] for e in found.values()}, {'lepton_a', 'lepton_b'})
        self.assertTrue(all(e['kind'] == 'install' and not e['conflict'] for e in found.values()))
        self.assertEqual(found[str(steam.resolve())]['vdf'], str((steam / 'compatibilitytool.vdf').resolve()))
        self.assertEqual(found[str(steam.resolve())]['steam_root'], str(self.steam.resolve()))
        out = subprocess.run([sys.executable, str(TOOLS / 'lepton-manage-installs'), '--list', '--json'],
                             capture_output=True, text=True, check=True)
        self.assertEqual({e['layout'] for e in json.loads(out.stdout)}, {'legacy', 'steam-compat'})

    def test_self_contained_install_needs_no_env_file(self):
        steam = self.self_contained('lepton_b', 'Lepton B')
        self.assertFalse((self.home / '.config').exists())
        entry = self.manage().lookup(self.manage().discover(), 'lepton_b')
        self.assertEqual((entry['dir'], entry['name']), (str(steam.resolve()), 'Lepton B'))

    def test_same_install_through_a_symlinked_path_is_listed_once(self):
        (self.home / '.steam').mkdir()
        (self.home / '.steam/root').symlink_to('../.local/share/Steam')
        steam = self.self_contained('lepton_b')
        config = self.home / '.config/lepton-x86_64'
        config.mkdir(parents=True)
        via_link = self.home / '.steam/root/compatibilitytools.d/lepton_b'
        (config / 'lepton_b.env').write_text('LEPTON_X86_TOOL_ID=lepton_b\nLEPTON_X86_INSTALL_DIR=%s\n' % via_link)
        entries = [e for e in self.manage().discover() if e['id'] == 'lepton_b']
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]['env'], str(config / 'lepton_b.env'))
        self.assertEqual(entries[0]['dir'], str(steam.resolve()))

    def test_duplicate_tool_id_is_reported_and_refused(self):
        self.legacy('lepton_a')
        self.lepton(self.tools() / 'copy', 'lepton_a')
        (self.tools() / 'copy/compatibilitytool.vdf').write_text(
            '"compatibilitytools"\n{\n "compat_tools"\n {\n  "lepton_a"\n  {\n   "install_path" "."\n  }\n }\n}\n')
        for name in ('toolmanifest.vdf', 'lepton-x86_64-entry'):
            (self.tools() / 'copy' / name).write_text('x')
        manage = self.manage()
        entries = [e for e in manage.discover() if e['id'] == 'lepton_a']
        self.assertEqual(len(entries), 2)
        self.assertTrue(all(e['conflict'] for e in entries))
        with self.assertRaisesRegex(ValueError, 'registered by 2 installs'):
            manage.lookup(manage.discover(), 'lepton_a')
        # Each is still reachable by its directory.
        self.assertEqual(manage.lookup(manage.discover(), str(self.tools() / 'copy'))['layout'], 'steam-compat')

    def test_unrelated_proton_is_never_listed_or_removed(self):
        proton = self.tools() / 'GE-Proton9-20'
        proton.mkdir()
        (proton / 'compatibilitytool.vdf').write_text(
            '"compatibilitytools"\n{\n "compat_tools"\n {\n  "GE-Proton9-20"\n  {\n   "install_path" "."\n'
            '   "from_oslist" "windows"\n   "to_oslist" "linux"\n  }\n }\n}\n')
        (proton / 'proton').write_text('#!/bin/sh\n')
        self.self_contained('lepton_b')
        manage = self.manage()
        self.assertNotIn(str(proton.resolve()), [e['dir'] for e in manage.discover()])
        with contextlib.redirect_stdout(io.StringIO()):
            manage.remove(['lepton_b'], True)
        self.assertTrue((proton / 'compatibilitytool.vdf').is_file() and (proton / 'proton').is_file())
        with self.assertRaisesRegex(ValueError, 'No Lepton install'):
            manage.remove(['GE-Proton9-20'], True)

    def test_incomplete_self_contained_copy_is_not_an_install(self):
        steam = self.self_contained('lepton_b')
        (steam / 'BUNDLE.json').unlink()
        entry = self.listing()[str(steam.resolve())]
        self.assertEqual(entry['kind'], 'unregistered')
        self.assertFalse(entry['default'])

    def test_removal_and_backups_in_both_layouts(self):
        legacy = self.legacy('lepton_a')
        steam = self.self_contained('lepton_b')
        backup = self.tools() / 'lepton_b.previous-20260101-000000'
        self.lepton(backup, 'lepton_b')
        (backup / 'compatibilitytool.vdf.lepton-disabled').write_text('disabled')
        legacy_backup = self.lepton(self.home / '.local/share/lepton_a.previous-20260101-000000', 'lepton_a')
        manage = self.manage()
        kinds = {e['dir']: e['kind'] for e in manage.discover()}
        self.assertEqual(kinds[str(backup.resolve())], 'backup')
        self.assertEqual(kinds[str(legacy_backup.resolve())], 'backup')
        with contextlib.redirect_stdout(io.StringIO()):
            manage.remove(['lepton_b', backup.name, legacy_backup.name], True)
        self.assertFalse(steam.exists() or backup.exists() or legacy_backup.exists())
        self.assertTrue((self.tools() / 'lepton_a.vdf').is_file() and legacy.is_dir())
        with contextlib.redirect_stdout(io.StringIO()):
            manage.remove(['lepton_a'], True)
        self.assertFalse(legacy.exists() or (self.tools() / 'lepton_a.vdf').exists())
        self.assertFalse((self.home / '.config/lepton-x86_64/lepton_a.env').exists())
        self.assertEqual(list(self.tools().iterdir()), [])


class RegistrationTests(Home):
    def test_self_contained_registration_files(self):
        steam = self.self_contained('lepton_x86_64_v0_1_0_alpha', 'lepton v0.1.0-alpha x86_64 (community)')
        self.assertEqual((steam / 'compatibilitytool.vdf').read_text(),
                         '"compatibilitytools"\n{\n  "compat_tools"\n  {\n    "lepton_x86_64_v0_1_0_alpha"\n    {\n'
                         '      "install_path" "."\n'
                         '      "display_name" "lepton v0.1.0-alpha x86_64 (community)"\n'
                         '      "from_oslist" "android"\n      "to_oslist" "linux"\n    }\n  }\n}\n')
        manifest = (steam / 'toolmanifest.vdf').read_text()
        self.assertIn('"commandline" "/lepton-x86_64-entry %verb% --"', manifest)
        self.assertIn('"use_tool_subprocess_reaper" "1"', manifest)
        self.assertEqual(manifest, (steam / 'compat_tool/toolmanifest.vdf').read_text())
        self.assertTrue(os.access(steam / 'lepton-x86_64-entry', os.X_OK))
        self.assertEqual(list(self.tools().glob('*.vdf')), [], 'a standalone .vdf was written as well')

    def test_wrapper_forwards_every_argument_without_an_extra_process(self):
        steam = self.self_contained('lepton_b')
        entry = steam / 'compat_tool/lepton-x86_64-entry'
        entry.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$$" "$0" "$@"\n')
        entry.chmod(0o755)
        process = subprocess.Popen([str(steam / 'lepton-x86_64-entry'), 'waitforexitandrun', '--',
                                    '/games/a b.apk', ''], stdout=subprocess.PIPE, text=True)
        lines = process.communicate()[0].split('\n')
        self.assertEqual(lines[0], str(process.pid), 'the wrapper must exec, not start a child')
        self.assertEqual(Path(lines[1]).resolve(), entry.resolve())
        self.assertEqual(lines[2:6], ['waitforexitandrun', '--', '/games/a b.apk', ''])

    def test_conflicting_registrations_are_refused(self):
        self.legacy('lepton_a')
        copy = self.lepton(self.tools() / 'lepton_a', 'lepton_a')
        register = load('lepton-register-tool').register
        with self.assertRaisesRegex(ValueError, 'legacy install'):
            register(copy, self.home, execute=True)
        self.assertFalse((copy / 'compatibilitytool.vdf').exists())
        self.self_contained('lepton_b')
        other = self.lepton(self.home / '.local/share/lepton_b', 'lepton_b')
        with self.assertRaisesRegex(ValueError, 'Steam would see it twice'):
            register(other, self.home, execute=True)
        self.assertFalse((self.tools() / 'lepton_b.vdf').exists())

    def test_check_changes_nothing_and_name_refresh(self):
        steam = self.lepton(self.tools() / 'lepton_b', 'lepton_b', 'lepton v0.1.0-alpha x86_64 (community)')
        before = sorted(self.home.rglob('*'))
        register = load('lepton-register-tool').register
        with contextlib.redirect_stdout(io.StringIO()):
            register(steam, self.home)
        self.assertEqual(sorted(self.home.rglob('*')), before)
        with contextlib.redirect_stdout(io.StringIO()):
            register(steam, self.home, execute=True)
            meta = json.loads((steam / 'BUNDLE.json').read_text())
            meta['display_name'] = 'lepton v0.2.0 x86_64 (community)'
            (steam / 'BUNDLE.json').write_text(json.dumps(meta))
            register(steam, self.home, execute=True, replace=True)
        self.assertIn('"lepton v0.2.0 x86_64 (community)"', (steam / 'compatibilitytool.vdf').read_text())


class NameTests(unittest.TestCase):
    def test_version_first_names(self):
        none = dict(gapps=False, ndk=False, widevine=False)
        self.assertEqual(L.default_display_name('v0.1.0-alpha', none), 'lepton v0.1.0-alpha x86_64 (community)')
        self.assertEqual(L.default_display_name('v0.2.0', none), 'lepton v0.2.0 x86_64 (community)')
        self.assertEqual(L.default_display_name('v0.1.0-beta', dict(none, gapps=True, ndk=True)),
                         'lepton v0.1.0-beta x86_64 (community, GApps + NDK)')
        self.assertEqual(L.default_display_name('my-build', dict(none, widevine=True, gapps=True), 'custom'),
                         'lepton my-build x86_64 (custom, GApps + Widevine)')

    def test_installer_applies_the_same_rule(self):
        """The installer's embedded copy of the rule (it runs without this library)."""
        installer = (TOOLS / 'lepton-install-bundle').read_text()
        start = installer.index("python3 - \"$TEMP/BUNDLE.json\" > \"$TEMP.meta\" <<'PY'")
        script = installer[installer.index('\n', start) + 1:installer.index('\nPY\n', start)]
        cases = [
            ('Lepton x86_64 (community) - v0.2.0-alpha', {}, 'lepton v0.2.0-alpha x86_64 (community)'),
            ('Lepton x86_64 (community) - v0.2.0-alpha', dict(gapps=True, ndk=True),
             'lepton v0.2.0-alpha x86_64 (community, GApps + NDK)'),
            ('Lepton x86_64 (custom) - mine', dict(widevine=True), 'lepton mine x86_64 (custom, Widevine)'),
            ('lepton v0.3.0 x86_64 (community)', {}, 'lepton v0.3.0 x86_64 (community)'),
            ('My own Lepton', dict(gapps=True), 'My own Lepton'),   # an explicit --tool-name
        ]
        with tempfile.TemporaryDirectory() as temp:
            for name, flags, expected in cases:
                bundle = name.rsplit(' - ', 1)[-1] if ' - ' in name else (name.split()[1] if name.startswith('lepton ') else 'x')
                path = Path(temp) / 'BUNDLE.json'
                path.write_text(json.dumps(dict(bundle_id=bundle, tool_id='t', display_name=name,
                                                install_directory='t', **flags)))
                out = subprocess.run([sys.executable, '-', str(path)], input=script, capture_output=True,
                                     text=True, check=True).stdout.splitlines()
                self.assertEqual(out[1], expected)
                meta = json.loads(path.read_text())
                self.assertEqual(meta['display_name'], expected)
                if expected != name:
                    self.assertEqual(meta['packaged_display_name'], name)
                else:
                    self.assertNotIn('packaged_display_name', meta)


if __name__ == '__main__':
    unittest.main()
