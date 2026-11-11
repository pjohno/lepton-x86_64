#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Host-only installer regression tests; no root, downloads or Android builds.

A tiny bundle uses the real installer, registration and installation manager.
Only the ADB pin in the temporary installer is changed to accept a fake adb.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / 'compat_tool/tools'


def write(path, contents, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(contents)
    if executable:
        path.chmod(0o755)


class InstallProfiles(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.home = self.work / 'home'
        (self.home / '.local/share/Steam').mkdir(parents=True)
        self.bin = self.work / 'bin'
        for tool in ('podman', 'setfattr', 'zenity'):
            write(self.bin / tool, '#!/bin/sh\nexit 0\n', True)
        write(self.bin / 'pgrep', '#!/bin/sh\nexit 1\n', True)
        write(self.work / 'os-release', 'ID=fedora\nPRETTY_NAME="Fedora Linux"\n')
        write(self.work / 'filesystems', 'nodev\tbinder\n')
        write(self.work / 'drm/renderD128/device/vendor', '0x1002\n')
        runtime = self.work / 'runtime'
        runtime.mkdir()
        sock = socket.socket(socket.AF_UNIX)
        sock.bind(str(runtime / 'wayland-0'))
        self.addCleanup(sock.close)
        self.env = {
            **os.environ, 'HOME': str(self.home),
            'XDG_DATA_HOME': str(self.home / '.local/share'),
            'XDG_CONFIG_HOME': str(self.home / '.config'),
            'PATH': f'{self.bin}:/usr/bin:/bin',
            'LEPTON_HOST_OS_RELEASE': str(self.work / 'os-release'),
            'LEPTON_HOST_OS_RELEASE_FALLBACK': str(self.work / 'missing'),
            'LEPTON_HOST_FILESYSTEMS': str(self.work / 'filesystems'),
            'LEPTON_SYSFS_DRM': str(self.work / 'drm'),
            'LEPTON_INSTALL_IN_TERMINAL': '1',
            'XDG_SESSION_TYPE': 'wayland', 'XDG_CURRENT_DESKTOP': 'GNOME',
            'WAYLAND_DISPLAY': 'wayland-0', 'XDG_RUNTIME_DIR': str(runtime),
        }
        self.env.pop('LEPTON_SKIP_HOST_CHECK', None)
        self.env.pop('LEPTON_INSTALL_PROFILE', None)
        self.payload = self.work / 'payload'
        for name in ('lepton-install-bundle', 'lepton-host-check',
                     'lepton-manage-installs', 'lepton-register-tool',
                     'lepton-direct-wayland', 'lepton-display-common.sh'):
            target = self.payload / 'compat_tool/tools' / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(TOOLS / name, target)
        shutil.copy2(ROOT / 'compat_tool/lepton-x86_64-entry',
                     self.payload / 'compat_tool/lepton-x86_64-entry')
        write(self.payload / 'compat_tool/lepton', '#!/bin/sh\nexit 0\n', True)
        (self.payload / 'compat_tool/liblepton').mkdir()
        write(self.payload / 'compat_tool/sysbake/system/packages.xml', 'fixture\n')
        write(self.payload / 'compat_tool/images/rootfs/sentinel', 'unchanged\n')
        # Even an archived local profile must be discarded on SteamOS.
        write(self.payload / 'compat_tool/install-profile', 'local-desktop\n')
        adb = '#!/bin/sh\necho "Version 37.0.1-15733141"\n'
        write(self.payload / 'tools/platform-tools/adb', adb, True)
        pin = hashlib.sha256(adb.encode()).hexdigest()
        template = (TOOLS / 'lepton-install-bundle').read_text()
        old_pin = next(line for line in template.splitlines() if line.startswith('ADB_SHA256='))
        template = template.replace(old_pin, f"ADB_SHA256='{pin}'")
        self.transfer = self.work / 'transferred'
        self.installer = self.transfer / 'lepton-x86_64-test.install.sh'
        self.archive = self.transfer / 'lepton-x86_64-test.tar.gz'
        write(self.installer, template.replace("DEFAULT_ARCHIVE=''", f"DEFAULT_ARCHIVE='{self.archive.name}'"), True)
        write(self.payload / 'BUNDLE.json', json.dumps({
            'tool_id': 'lepton_test', 'display_name': 'Lepton Test',
            'install_directory': 'lepton_test', 'bundle_id': 'test',
        }))
        self.pack()
        self.dest = self.home / '.local/share/lepton_test'
        # No ZIP is extracted: the bundled fake adb matches the temporary pin.
        write(self.work / 'adb.zip', '')

    def pack(self):
        with tarfile.open(self.archive, 'w:gz') as archive:
            for path in self.payload.iterdir():
                archive.add(path, arcname=path.name)
        digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        write(Path(str(self.archive) + '.sha256'), f'{digest}  {self.archive.name}\n')

    def run_script(self, script, *args, success=True):
        result = subprocess.run(['bash', str(script), *args], env=self.env,
                                cwd=self.transfer, capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def install(self, *args, success=True):
        return self.run_script(self.installer, '--allow-non-amd', '--adb-zip',
                               str(self.work / 'adb.zip'), *args, success=success)

    def steam_os(self):
        write(self.work / 'os-release', "ID='steamos'\nNAME=SteamOS\n")
        write(self.bin / 'gamescope', '#!/bin/sh\nexit 0\n', True)

    def assert_profile(self, profile, dest=None):
        dest = dest or self.dest
        marker = dest / 'compat_tool/install-profile'
        if profile == 'steamos':
            self.assertFalse(marker.exists())
        else:
            self.assertEqual(marker.read_text(), 'local-desktop\n')
        self.assertEqual((dest / 'compat_tool/images/rootfs/sentinel').read_text(), 'unchanged\n')

    def test_standalone_fedora_gnome_and_kde(self):
        for desktop in ('GNOME', 'KDE'):
            with self.subTest(desktop=desktop):
                self.env['XDG_CURRENT_DESKTOP'] = desktop
                out = self.install(*(['--replace'] if self.dest.exists() else []))
                self.assertIn('[PASS] Detected Fedora Linux', out)
                self.assertIn('[PASS] Installation profile: local-desktop', out)
                self.assertIn('Launcher: direct Wayland', out)
                self.assertIn('Default display mode: native fullscreen', out)
                self.assertNotIn('[PASS] Gamescope', out)
                self.assert_profile('local-desktop')

    def test_steamos_gaming_and_desktop(self):
        self.steam_os()
        for session, desktop in (('x11', 'gamescope'), ('wayland', 'KDE')):
            self.env.update(XDG_SESSION_TYPE=session, XDG_CURRENT_DESKTOP=desktop)
            out = self.install(*(['--replace'] if self.dest.exists() else []))
            self.assertIn('Detected SteamOS', out)
            self.assertIn('Launcher: Gamescope bridge', out)
            self.assertIn('Steam Deck Gaming/Desktop modes preserved', out)
            self.assert_profile('steamos')

    def test_explicit_overrides(self):
        self.steam_os()
        self.install('--install-profile', 'local-desktop')
        self.assert_profile('local-desktop')
        write(self.work / 'os-release', 'ID=fedora\n')
        self.install('--replace', '--install-profile', 'steamos')
        self.assert_profile('steamos')
        self.run_script(self.installer, '--detect-profile', '--install-profile', 'invalid', success=False)

    def test_replace_unmarked_on_fedora(self):
        self.steam_os()
        self.install()
        write(self.work / 'os-release', 'ID=fedora\n')
        self.install('--replace')
        self.assert_profile('local-desktop')

    def test_replace_local_on_steamos(self):
        self.install()
        self.steam_os()
        self.install('--replace')
        self.assert_profile('steamos')

    def test_into_keeps_tool_identity_but_reselects_profile(self):
        self.install()
        metadata = json.loads((self.payload / 'BUNDLE.json').read_text())
        metadata.update(tool_id='lepton_new', install_directory='lepton_new')
        write(self.payload / 'BUNDLE.json', json.dumps(metadata))
        self.pack()
        self.steam_os()
        self.install('--into', 'lepton_test')
        self.assert_profile('steamos')
        self.assertEqual(json.loads((self.dest / 'BUNDLE.json').read_text())['tool_id'], 'lepton_test')
        self.assertFalse((self.dest.parent / 'lepton_new').exists())

    def test_check_changes_no_install(self):
        out = self.install('--check')
        self.assertIn('Installation profile: local-desktop', out)
        self.assertFalse(self.dest.exists())

    def test_x11_diagnostic(self):
        self.env['XDG_SESSION_TYPE'] = 'x11'
        out = self.install(success=False)
        self.assertIn('X11 sessions are unsupported', out)
        self.assertFalse(self.dest.exists())

    def test_safe_detection_fallback_and_unknown_os(self):
        self.env['LEPTON_HOST_OS_RELEASE'] = str(self.work / 'absent')
        self.env['LEPTON_HOST_OS_RELEASE_FALLBACK'] = str(self.work / 'os-release')
        self.steam_os()
        self.assertEqual(self.run_script(self.installer, '--detect-profile').strip(), 'steamos')
        write(self.work / 'os-release', f'ID=other\nNAME="$(touch {self.work}/executed)"\n')
        self.assertEqual(self.run_script(self.installer, '--detect-profile').strip(), 'local-desktop')
        self.install()
        self.assertFalse((self.work / 'executed').exists())
        write(self.work / 'os-release', 'ID="steamos"\n')
        self.assertEqual(self.run_script(self.installer, '--detect-profile').strip(), 'steamos')
        (self.work / 'os-release').unlink()
        self.assertEqual(self.run_script(self.installer, '--detect-profile').strip(), 'local-desktop')

    def test_local_wrapper_detection_and_overrides(self):
        # Minimal source layout; the standalone tests above have no checkout.
        wrapper = self.work / 'source/image-14/scripts/install-local.sh'
        write(wrapper, (ROOT / 'image-14/scripts/install-local.sh').read_text())
        for name in ('lepton-install-bundle', 'lepton-host-check'):
            target = self.work / 'source/compat_tool/tools' / name
            write(target, (TOOLS / name).read_text())
        args = ('--execute', '--bundle-id', 'test', '--bundle-dir', str(self.transfer),
                '--stage-dir', str(self.work / 'unused'), '--allow-non-amd',
                '--adb-zip', str(self.work / 'adb.zip'))
        self.run_script(wrapper, *args)
        self.assert_profile('local-desktop')
        self.steam_os()
        self.run_script(wrapper, *args, '--replace')
        self.assert_profile('steamos')
        self.run_script(wrapper, *args, '--replace', '--install-profile', 'local-desktop')
        self.assert_profile('local-desktop')
        write(self.work / 'os-release', 'ID=fedora\n')
        self.run_script(wrapper, *args, '--replace', '--install-profile', 'steamos')
        self.assert_profile('steamos')


if __name__ == '__main__':
    unittest.main()
