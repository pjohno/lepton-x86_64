#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""lepton-compare-bundles on small synthetic archives: read-only, sectioned
results, exit status, JSON output and rejection of unsafe archives."""
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
TOOL = REPO / 'compat_tool/tools/lepton-compare-bundles'
R = './compat_tool/images/rootfs/'
S = './compat_tool/sysbake/'
XATTRS = b'# file: sysbake\nuser.default=0x01\n\n# file: sysbake/system/packages.xml\nuser.inode_cache="1"\n\n'


def base_entries():
    return {
        './BUNDLE.json': (json.dumps(dict(format_version=2, bundle_id='a', tool_id='lepton_x86_64_a', gapps=False,
                                          ndk=False)).encode(), 0o644),
        './tools/BUNDLE-PROVENANCE.txt': (b'Launcher source commit: ' + b'a' * 40 + b'\n', 0o644),
        './compat_tool/lepton': (b'#!/bin/bash\n', 0o755),
        R + 'system': (None, 0o755),
        R + 'system/build.prop': (b'ro.build.version.sdk=34\n', 0o600),
        R + 'vendor/build.prop': (b'ro.vendor=1\n', 0o600),
        R + 'system/framework/services.jar': (b'jar', 0o644),
        R + 'system/etc/hosts': (b'127.0.0.1 localhost\n', 0o644),
        R + 'system/bin/sh': ('symlink', 'mksh'),
        R + 'bin': ('symlink', '/system/bin'),
        S + 'system': (None, 0o775),
        S + 'system/packages.xml': (b'ABX\x00packages', 0o640),
        S + 'misc': (None, 0o2770),
        S + 'misc/state': (b'state', 0o600),
        './compat_tool/sysbake.xattrs': (XATTRS, 0o644),
    }


def write(path, entries):
    with tarfile.open(path, 'w:gz') as tar:
        top = tarfile.TarInfo('.')
        top.type, top.mode = tarfile.DIRTYPE, 0o755
        tar.addfile(top)
        for name, (data, mode) in entries.items():
            info = tarfile.TarInfo(name)
            if data is None:
                info.type, info.mode = tarfile.DIRTYPE, mode
                tar.addfile(info)
            elif data == 'symlink':
                info.type, info.linkname = tarfile.SYMTYPE, mode
                tar.addfile(info)
            elif data == 'hardlink':
                info.type, info.linkname = tarfile.LNKTYPE, mode
                tar.addfile(info)
            elif data == 'fifo':
                info.type = tarfile.FIFOTYPE
                tar.addfile(info)
            else:
                info.size, info.mode = len(data), mode
                tar.addfile(info, io.BytesIO(data))


class CompareTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.old = self.root / 'old.tar.gz'
        write(self.old, base_entries())

    def compare(self, entries=None, *extra, expect=None, archive=None):
        new = archive or self.root / 'new.tar.gz'
        if entries is not None:
            write(new, entries)
        work = self.root / 'cwd'
        work.mkdir(exist_ok=True)
        before = {p: p.stat().st_mtime_ns for p in (self.old, new)}
        result = subprocess.run([sys.executable, '-B', str(TOOL), str(self.old), str(new), '--json', '-', *extra],
                                cwd=work, capture_output=True, text=True)
        self.assertEqual({p: p.stat().st_mtime_ns for p in (self.old, new)}, before)
        self.assertEqual(list(work.iterdir()), [], 'comparison must not extract anything')
        if expect is not None:
            self.assertEqual(result.returncode, expect, result.stdout + result.stderr)
        return json.loads(result.stdout) if result.returncode in (0, 1) else result

    def test_identical_archives(self):
        report = self.compare(base_entries(), expect=0)
        self.assertTrue(report['summary']['archives_equivalent'])
        self.assertFalse(report['summary']['differences_confined_to_launcher_tooling_metadata'])
        self.assertEqual(report['metadata']['components']['widevine'], dict(old=False, old_legacy=True,
                                                                           new=False, new_legacy=True))

    def test_metadata_and_tooling_only_differences(self):
        entries = base_entries()
        entries['./BUNDLE.json'] = (json.dumps(dict(format_version=2, bundle_id='b', tool_id='lepton_custom_b',
                                                    gapps=False, ndk=False, widevine=False)).encode(), 0o644)
        entries['./compat_tool/lepton'] = (b'#!/bin/bash\n# newer launcher\n', 0o755)
        entries['./tools/BUNDLE-PROVENANCE.txt'] = (b'Packaging: lepton-customize package\n', 0o644)
        report = self.compare(entries, expect=0)
        summary = report['summary']
        self.assertTrue(summary['runtime_inputs_identical'])
        self.assertTrue(summary['differences_confined_to_launcher_tooling_metadata'])
        self.assertEqual(report['metadata']['bundle_json_changes']['bundle_id'], ['a', 'b'])
        self.assertIn('compat_tool/lepton', report['other_files']['content_changed'])
        self.assertFalse(report['metadata']['components']['widevine'].get('new_legacy', False))
        text = subprocess.run([sys.executable, '-B', str(TOOL), str(self.old), str(self.root / 'new.tar.gz')],
                              capture_output=True, text=True).stdout
        self.assertIn('differences are confined to launcher/tooling/metadata', text)
        self.assertIn('not a guarantee', text)

    def test_rootfs_changes(self):
        entries = base_entries()
        entries[R + 'system/etc/hosts'] = (b'changed\n', 0o644)
        entries[R + 'system/etc/new.conf'] = (b'new', 0o644)
        entries[R + 'system/framework/services.jar'] = (b'jar', 0o600)
        entries[R + 'bin'] = ('symlink', '/system/xbin')
        del entries[R + 'system/bin/sh']
        report = self.compare(entries, expect=1)
        rootfs = report['android_rootfs']
        self.assertFalse(rootfs['identical'])
        self.assertEqual(rootfs['content_changed'], ['system/etc/hosts'])
        self.assertEqual(rootfs['added'], ['system/etc/new.conf'])
        self.assertEqual(rootfs['removed'], ['system/bin/sh'])
        self.assertEqual(rootfs['permissions_changed'], [dict(path='system/framework/services.jar', old='0644', new='0600')])
        self.assertEqual(rootfs['link_changed'][0]['new'], '/system/xbin')
        self.assertTrue(report['sysbake']['identical'])
        self.assertTrue(report['fingerprint']['identical'], 'mode-only change does not alter fingerprint content')

    def test_fingerprint_input_change(self):
        entries = base_entries()
        entries[R + 'vendor/build.prop'] = (b'ro.vendor=2\n', 0o600)
        report = self.compare(entries, expect=1)
        self.assertFalse(report['fingerprint']['identical'])
        self.assertEqual(report['fingerprint']['inputs']['images/rootfs/vendor/build.prop']['old'] is None, False)

    def test_sysbake_changes(self):
        entries = base_entries()
        entries[S + 'misc/state'] = (b'other state', 0o600)
        entries[S + 'misc'] = (None, 0o770)
        report = self.compare(entries, expect=1)
        self.assertTrue(report['android_rootfs']['identical'])
        self.assertEqual(report['sysbake']['content_changed'], ['misc/state'])
        self.assertEqual(report['sysbake']['permissions_changed'][0]['old'], '2770')
        self.assertTrue(report['sysbake_xattrs']['identical'])

    def test_registered_package_changes_reported(self):
        entries = base_entries()
        entries[S + 'system/packages.xml'] = (b'<packages><package name="android"/></packages>', 0o640)
        write(self.old, entries)
        entries = dict(entries)
        entries[S + 'system/packages.xml'] = (b'<packages><package name="android"/>'
                                              b'<package name="com.google.android.gms"/></packages>', 0o640)
        report = self.compare(entries, expect=1)
        registered = report['sysbake']['registered_packages']
        self.assertEqual((registered['old_count'], registered['new_count'], registered['added']),
                         (1, 2, ['com.google.android.gms']))
        # An unparseable packages.xml is reported, never silently treated as equal.
        report = self.compare(base_entries(), expect=1)
        self.assertIn('new', report['sysbake']['registered_packages']['problems'])

    def test_xattr_only_changes(self):
        entries = base_entries()
        entries['./compat_tool/sysbake.xattrs'] = (XATTRS.replace(b'user.default=0x01', b'user.default=0x02') +
                                                   b'# file: sysbake/misc\nuser.serial=0x01\n', 0o644)
        report = self.compare(entries, expect=1)
        self.assertTrue(report['android_rootfs']['identical'] and report['sysbake']['identical'])
        x = report['sysbake_xattrs']
        self.assertFalse(x['identical'])
        self.assertEqual(x['added_paths'], ['sysbake/misc'])
        self.assertEqual(x['changed'][0]['changed'], {'user.default': ['0x01', '0x02']})
        self.assertFalse(report['summary']['differences_confined_to_launcher_tooling_metadata'])

    def test_missing_sysbake_is_not_reported_identical(self):
        entries = {k: v for k, v in base_entries().items() if not k.startswith(('./compat_tool/sysbake',))}
        write(self.old, entries)
        report = self.compare(entries, expect=1)
        self.assertFalse(report['sysbake']['identical'])
        self.assertFalse(report['sysbake_xattrs']['identical'])
        self.assertFalse(report['fingerprint']['identical'])

    def test_unsafe_or_malformed_archives_rejected(self):
        cases = {
            'traversal': {'./../escape': (b'x', 0o644)},
            'absolute': {'/etc/passwd': (b'x', 0o644)},
            'fifo': {'./compat_tool/fifo': ('fifo', None)},
            'escaping symlink': {'./compat_tool/link': ('symlink', '../../outside')},
            'absolute symlink outside Android': {'./tools/link': ('symlink', '/etc/passwd')},
            'hardlink to missing': {'./tools/hard': ('hardlink', 'missing')},
        }
        for label, extra in cases.items():
            with self.subTest(label):
                entries = base_entries()
                entries.update(extra)
                result = self.compare(entries, expect=2)
                self.assertIn('ERROR', result.stderr)
        duplicate = self.root / 'duplicate.tar.gz'
        with tarfile.open(duplicate, 'w:gz') as tar:
            for _ in range(2):
                info = tarfile.TarInfo('./BUNDLE.json')
                info.size = 2
                tar.addfile(info, io.BytesIO(b'{}'))
        self.assertIn('Duplicate', self.compare(archive=duplicate, expect=2).stderr)
        truncated = self.root / 'truncated.tar.gz'
        truncated.write_bytes(self.old.read_bytes()[:-40])
        self.compare(archive=truncated, expect=2)

    def test_json_file_and_human_output(self):
        write(self.root / 'new.tar.gz', base_entries())
        out = self.root / 'report.json'
        result = subprocess.run([sys.executable, '-B', str(TOOL), str(self.old), str(self.root / 'new.tar.gz'),
                                 '--json', str(out)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn('Android rootfs: IDENTICAL', result.stdout)
        self.assertTrue(json.loads(out.read_text())['summary']['archives_equivalent'])


if __name__ == '__main__':
    unittest.main()
