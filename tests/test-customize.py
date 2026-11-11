#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Offline bundle-to-stage tests. Compilers build tiny fixtures only; the copied
standalone CLI runs with no compiler, source checkout, build config or AOSP.
"""
import argparse
import contextlib
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / 'compat_tool/tools/lepton-customize'
loader = importlib.machinery.SourceFileLoader('customize_test', str(SCRIPT))
M = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(M)


def digest(data):
    return hashlib.sha256(data).hexdigest()


class CustomizeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiled = tempfile.TemporaryDirectory()
        root = Path(cls.compiled.name)
        cc = shutil.which('cc')
        if not cc:
            raise unittest.SkipTest('A host C compiler is needed only to construct ELF test fixtures')
        def compile(source, output, *flags):
            subprocess.run([cc, '-x', 'c', '-', '-o', str(root / output), *flags],
                           input=source.encode(), check=True, capture_output=True)
            return (root / output).read_bytes()
        cls.shim = compile('void shim(void) {}', 'shim.so', '-shared', '-fPIC', '-nostdlib',
                           '-Wl,-soname,liblepton_ndk_auxv.so')
        cls.library = compile('int fixture(void) { return 0; }', 'libinotifytools.so.0',
                              '-shared', '-fPIC', '-Wl,-soname,libinotifytools.so.0')
        cls.native = compile('extern int fixture(void); int main(void) { return fixture(); }',
                             'inotifywait', '-x', 'none', str(root / 'libinotifytools.so.0'))
        cls.executable = Path('/bin/true').read_bytes()
        cls.android = compile('int _start(void) { return 0; }', 'android-sh', '-nostdlib', '-fPIE', '-pie',
                              '-Wl,--dynamic-linker=/system/bin/linker64')
        cls.wrapper = (REPO / 'image-14/scripts/internal/inotifywait-wrapper').read_bytes()
        cls.keys = root / 'key'
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(cls.keys)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.compiled.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.outside = self.root / 'outside-repository'
        self.outside.mkdir()
        self.bootstrap = self.root / 'bootstrap/compat_tool/tools'
        self.bootstrap.mkdir(parents=True)
        self.tool = self.bootstrap / 'lepton-customize'
        shutil.copyfile(SCRIPT, self.tool)
        self.stage = self.root / 'stage'
        self.archive = self.root / 'lepton-x86_64-v0.2.0-alpha.tar.gz'
        self.checksum = Path(str(self.archive) + '.sha256')
        self.nodes = {name: (b'#!/bin/bash\n', 0o755, None) for name in M.REQUIRED}
        self.metadata = dict(format_version=2, bundle_id='v0.2.0-alpha',
                             tool_id='lepton_x86_64_v0_2_0_alpha',
                             install_directory='lepton_x86_64_v0_2_0_alpha',
                             display_name='Lepton base', gapps=False, ndk=False)
        self.put('BUNDLE.json', json.dumps(self.metadata).encode(), 0o644)
        self.put(M.SHIM, self.shim)
        self.put(M.EXTRACTOR, self.executable)
        self.put(M.INOTIFY, self.native)
        self.put(M.INOTIFY_LIB, self.library)
        self.put('tools/bin/inotifywait', self.wrapper)
        self.put(M.ROOTFS + 'system/bin/sh', b'', 0o777, ('symlink', 'mksh'))
        self.put(M.ROOTFS + 'system/bin/mksh', self.android)
        self.put(M.ROOTFS + 'vendor/lib64/hw/vulkan.radeon.so', self.shim)
        self.put(M.ROOTFS + 'system/build.prop', b'ro.build.version.sdk=34\nro.product.cpu.abi=x86_64\n'
                 b'ro.dalvik.vm.native.bridge=0\nro.system.product.cpu.abilist=x86_64\n'
                 b'ro.system.product.cpu.abilist64=x86_64\nro.system.product.cpu.abilist32=\n', 0o644)
        self.put(M.ROOTFS + 'vendor/build.prop', b'ro.vendor.product.cpu.abilist=x86_64\n', 0o644)
        self.put(M.ROOTFS + 'system/etc/unchanged.conf', b'preserved rootfs bytes', 0o640)
        self.put('compat_tool/sysbake/system/packages.xml', b'old final sysbake', 0o000)
        self.put('compat_tool/sysbake.xattrs', b'old attributes', 0o600)
        for name in ('.runtime-profile.google/token', 'compat_tool/.runtime-profile.google/token',
                     'compatdata/123/save', 'compat_tool/install-profile', 'tools/.ssh/id_ed25519'):
            self.put(name, b'private state', 0o600)
        # Only ordinary runtime dependencies are on PATH for the CLI.
        bindir = self.root / 'host-tools'
        bindir.mkdir()
        for program in ('python3', 'readelf', 'ssh-keygen', 'ldconfig'):
            source = shutil.which(program)
            if source:
                (bindir / program).symlink_to(source)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('LEPTON_')}
        self.env.update(PATH=str(bindir), PYTHONDONTWRITEBYTECODE='1', HOME=str(self.outside))
        self.write_bundle()

    def put(self, name, data, mode=0o755, link=None):
        self.nodes[name] = (data, mode, link)

    def write_bundle(self, extras=()):
        with tarfile.open(self.archive, 'w:gz') as tar:
            for name, (data, mode, link) in list(self.nodes.items()) + list(extras):
                member = tarfile.TarInfo('./' + name if not name.startswith('/') else name)
                member.mode, member.mtime = mode, 1234567890
                if link:
                    kind, target = link
                    member.type = {'symlink': tarfile.SYMTYPE, 'hardlink': tarfile.LNKTYPE,
                                   'directory': tarfile.DIRTYPE, 'fifo': tarfile.FIFOTYPE}[kind]
                    member.linkname = target
                    tar.addfile(member)
                else:
                    member.size = len(data)
                    tar.addfile(member, io.BytesIO(data))
        self.checksum.write_text(digest(self.archive.read_bytes()) + '  ' + self.archive.name + '\n' +
                                 '0' * 64 + '  ' + self.archive.name[:-7] + '.install.sh\n')

    def args(self, mode='--execute'):
        return [mode, '--bundle', str(self.archive), '--checksum', str(self.checksum),
                '--stage-dir', str(self.stage)]

    def cli(self, mode='--execute', *extra, ok=True):
        result = subprocess.run([sys.executable, '-B', str(self.tool), *self.args(mode), *extra],
                                cwd=self.outside, env=self.env, capture_output=True, text=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def signed(self):
        keys = self.bootstrap.parent / 'release-keys/allowed_signers'
        keys.parent.mkdir()
        keys.write_text('lepton-release namespaces="lepton-release" ' +
                        Path(str(self.keys) + '.pub').read_text())
        subprocess.run(['ssh-keygen', '-Y', 'sign', '-f', str(self.keys), '-n', 'lepton-release',
                        str(self.checksum)], check=True, capture_output=True)

    def namespace(self):
        return argparse.Namespace(bundle=self.archive, checksum=self.checksum, signature=None,
                                  stage_dir=str(self.stage), check=False, execute=True)

    def test_valid_standalone_stage_no_compiler_adb_aosp_or_source_needed(self):
        original = self.archive.read_bytes()
        result = self.cli()
        self.assertIn('authenticity NOT verified', result.stdout)
        self.assertEqual(self.archive.read_bytes(), original)
        self.assertEqual((self.stage / 'source-bundle/BUNDLE.json').read_bytes(), self.nodes['BUNDLE.json'][0])
        identity = json.loads((self.stage / 'source-bundle/SOURCE.json').read_text())
        self.assertEqual(identity['sha256'], digest(original))
        self.assertFalse(identity['authenticated'])
        self.assertTrue(json.loads((self.stage / 'STAGE.json').read_text())['sysbake_required'])
        self.assertFalse((self.stage / 'BUNDLE.json').exists())
        for name in (M.SHIM, M.EXTRACTOR, M.INOTIFY, M.INOTIFY_LIB, 'tools/bin/inotifywait',
                     M.ROOTFS + 'system/build.prop', M.ROOTFS + 'system/etc/unchanged.conf'):
            self.assertEqual((self.stage / name).read_bytes(), self.nodes[name][0])
        self.assertEqual((self.stage / (M.ROOTFS + 'system/etc/unchanged.conf')).stat().st_mode & 0o777, 0o640)
        self.assertEqual(os.readlink(self.stage / (M.ROOTFS + 'system/bin/sh')), 'mksh')
        for name in ('compat_tool/sysbake', 'compat_tool/sysbake.xattrs', '.runtime-profile.google',
                     'compat_tool/.runtime-profile.google', 'compatdata', 'tools/.ssh',
                     'compat_tool/install-profile', 'tools/platform-tools/adb'):
            self.assertFalse((self.stage / name).exists(), name)
        # The extracted stage owns separate bytes, independent of the download.
        (self.stage / (M.ROOTFS + 'system/etc/unchanged.conf')).write_bytes(b'changed stage')
        self.assertEqual(self.archive.read_bytes(), original)

    def test_check_writes_nothing(self):
        before = sorted(str(p.relative_to(self.root)) for p in self.root.rglob('*'))
        self.cli('--check')
        self.assertEqual(before, sorted(str(p.relative_to(self.root)) for p in self.root.rglob('*')))
        self.assertFalse(self.stage.exists())

    def test_checksum_mismatch(self):
        self.checksum.write_text('0' * 64 + '  ' + self.archive.name + '\n')
        self.assertIn('SHA256', self.cli(ok=False).stderr)
        self.assertFalse(self.stage.exists())

    def test_malformed_duplicate_and_unrelated_checksums(self):
        good = self.checksum.read_text()
        for manifest in (good + good, good + '0' * 64 + '  ../other\n', 'invalid\n'):
            with self.subTest(manifest=manifest):
                self.checksum.write_text(manifest)
                self.cli('--check', ok=False)

    def test_signed_release_and_metadata(self):
        self.signed()
        self.cli('--check')
        self.cli()
        self.assertTrue(json.loads((self.stage / 'source-bundle/SOURCE.json').read_text())['authenticated'])
        self.assertEqual((self.stage / 'source-bundle/SHA256SUMS.sig').read_bytes(),
                         Path(str(self.checksum) + '.sig').read_bytes())

    def test_installed_key_requires_signature(self):
        self.signed()
        Path(str(self.checksum) + '.sig').unlink()
        self.assertIn('signature', self.cli('--check', ok=False).stderr)

    def test_wrong_signature_rejected_even_with_matching_checksum(self):
        self.signed()
        self.put(M.ROOTFS + 'system/etc/unchanged.conf', b'modified')
        self.write_bundle()
        self.assertIn('signature is NOT valid', self.cli(ok=False).stderr)
        self.assertFalse(self.stage.exists())

    def test_no_trust_root_cannot_claim_valid_signature(self):
        self.signed()
        (self.bootstrap.parent / 'release-keys/allowed_signers').unlink()
        self.assertIn('no trusted release keys', self.cli('--check', ok=False).stderr)

    def test_missing_and_corrupt_binaries(self):
        for name in (M.SHIM, M.EXTRACTOR, M.INOTIFY, M.INOTIFY_LIB, 'tools/bin/inotifywait'):
            original = self.nodes[name]
            for corrupt in (False, True):
                with self.subTest(name=name, corrupt=corrupt):
                    if corrupt:
                        self.put(name, b'corrupt binary')
                    else:
                        self.nodes.pop(name)
                    self.write_bundle()
                    self.cli('--check', ok=False)
                    self.nodes[name] = original

    def test_wrong_binary_architecture(self):
        data = bytearray(self.nodes[M.EXTRACTOR][0])
        data[18:20] = (183).to_bytes(2, 'little')
        self.put(M.EXTRACTOR, bytes(data))
        self.write_bundle()
        self.assertIn('x86_64 ELF', self.cli(ok=False).stderr)

    def test_native_library_compatibility(self):
        data = self.nodes[M.EXTRACTOR][0]
        self.put(M.EXTRACTOR, data.replace(b'libc.so.6', b'nope.so.6'))
        self.write_bundle()
        self.assertIn('Host runtime library missing', self.cli('--check', ok=False).stderr)

    def test_host_symbol_version_mismatch_rejected(self):
        self.assertIn(b'GLIBC_2.2.5', self.executable)
        self.put(M.EXTRACTOR, self.executable.replace(b'GLIBC_2.2.5', b'GLIBC_9.9.9'))
        self.write_bundle()
        self.assertIn('lacks required versions', self.cli('--check', ok=False).stderr)

    def test_executable_permission_required(self):
        self.put(M.EXTRACTOR, self.executable, 0o644)
        self.write_bundle()
        self.assertIn('Executable bit', self.cli('--check', ok=False).stderr)

    def test_invalid_rootfs_and_base_metadata(self):
        name = M.ROOTFS + 'system/build.prop'
        original = self.nodes[name]
        for replacement in (b'34', b'arm64', b'libndk_translation.so'):
            with self.subTest(replacement=replacement):
                data = original[0].replace(b'34', b'33') if replacement == b'34' else original[0].replace(
                    b'x86_64' if replacement == b'arm64' else b'bridge=0',
                    b'arm64' if replacement == b'arm64' else b'bridge=libndk_translation.so')
                self.put(name, data)
                self.write_bundle()
                self.cli('--check', ok=False)
        self.nodes[name] = original
        for field, value in [('gapps', True), ('ndk', True), ('format_version', 1),
                             ('tool_id', '../escape'), ('install_directory', '../escape')]:
            with self.subTest(field=field):
                metadata = {**self.metadata, field: value}
                self.put('BUNDLE.json', json.dumps(metadata).encode())
                self.write_bundle()
                self.cli('--check', ok=False)

    def test_host_binary_in_android_rootfs_rejected(self):
        self.put(M.ROOTFS + 'system/bin/mksh', self.executable)
        self.write_bundle()
        self.assertIn('Host binary found in Android rootfs', self.cli(ok=False).stderr)

    def test_optional_flags_are_not_implemented(self):
        for option in ('--with-ndk', '--with-gapps', '--with-widevine'):
            self.assertIn('unrecognized arguments', self.cli('--check', option, ok=False).stderr)

    def test_invalid_json_and_duplicate_keys(self):
        for data in (b'[]', b'invalid', b'{"format_version": 2, "format_version": 2}'):
            self.put('BUNDLE.json', data)
            self.write_bundle()
            self.cli('--check', ok=False)

    def test_rootfs_user_state_rejected(self):
        self.put(M.ROOTFS + 'data/user/0/com.google/token', b'credentials')
        self.write_bundle()
        self.assertIn('User state', self.cli(ok=False).stderr)

    def test_missing_launcher_and_overlay(self):
        for name in ('compat_tool/lepton', 'compat_tool/liblepton/mounting.sh',
                     'compat_tool/images/rootfs_overlay/system/bin/binderfs-ensure'):
            with self.subTest(name=name):
                original = self.nodes.pop(name)
                self.write_bundle()
                self.cli('--check', ok=False)
                self.nodes[name] = original

    def test_existing_destination_and_symlink_refused(self):
        self.stage.mkdir()
        (self.stage / 'marker').write_text('unchanged')
        self.cli(ok=False)
        self.assertEqual((self.stage / 'marker').read_text(), 'unchanged')
        shutil.rmtree(self.stage)
        self.stage.symlink_to(self.outside, target_is_directory=True)
        self.cli(ok=False)

    def test_installed_tool_and_symlink_parent_untouched(self):
        installed = self.root / 'installed'
        (installed / 'compat_tool').mkdir(parents=True)
        (installed / 'compat_tool/lepton').write_text('installed launcher')
        self.stage = installed / 'new-stage'
        self.assertIn('outside any installed', self.cli(ok=False).stderr)
        self.assertEqual((installed / 'compat_tool/lepton').read_text(), 'installed launcher')
        alias = self.root / 'alias'
        alias.symlink_to(self.outside, target_is_directory=True)
        self.stage = alias / 'stage'
        self.assertIn('symlink ancestors', self.cli(ok=False).stderr)

    def test_unsafe_archives(self):
        cases = [('../escaped', (b'bad', 0o644, None)),
                 ('/absolute', (b'bad', 0o644, None)),
                 ('compat_tool/tools/escape', (b'', 0o777, ('symlink', '../../../../escaped'))),
                 ('compat_tool/tools/escape', (b'', 0o777, ('symlink', '/tmp/escaped'))),
                 ('compat_tool/tools/escape', (b'', 0o777, ('hardlink', '../escaped'))),
                 (M.ROOTFS + 'escape', (b'', 0o777, ('symlink', '/etc/passwd'))),
                 (M.ROOTFS + 'escape', (b'', 0o777, ('symlink', '/system/../etc/passwd'))),
                 ('compat_tool/tools/pipe', (b'', 0o600, ('fifo', ''))),
                 ('./compat_tool/lepton', (b'duplicate', 0o755, None))]
        for name, node in cases:
            with self.subTest(name=name, node=node):
                self.write_bundle([(name, node)])
                self.cli(ok=False)
                self.assertFalse(self.stage.exists())
                self.assertFalse(list(self.root.glob('.lepton-customize-*')))

    def test_symlink_parent_write_rejected_in_either_order(self):
        for reverse in (False, True):
            additions = [('compat_tool/tools/link', (b'', 0o777, ('symlink', 'target'))),
                         ('compat_tool/tools/link/file', (b'bad', 0o644, None))]
            self.write_bundle(additions[::-1] if reverse else additions)
            self.assertIn('below a link', self.cli(ok=False).stderr)

    def test_hardlinks_and_android_absolute_symlinks_preserved(self):
        target = M.ROOTFS + 'system/etc/unchanged.conf'
        self.put(M.ROOTFS + 'system/etc/hardlink', b'', 0o640, ('hardlink', './' + target))
        self.put(M.ROOTFS + 'etc', b'', 0o777, ('symlink', '/system/etc'))
        self.write_bundle()
        self.cli()
        self.assertEqual((self.stage / target).stat().st_ino,
                         (self.stage / (M.ROOTFS + 'system/etc/hardlink')).stat().st_ino)
        self.assertEqual(os.readlink(self.stage / (M.ROOTFS + 'etc')), '/system/etc')

    def test_hardlink_cycle_rejected(self):
        self.put('tools/bin/a', b'', 0o755, ('hardlink', 'tools/bin/b'))
        self.put('tools/bin/b', b'', 0o755, ('hardlink', 'tools/bin/a'))
        self.write_bundle()
        self.assertIn('Link cycle', self.cli(ok=False).stderr)

    def test_truncated_gzip_rejected(self):
        self.archive.write_bytes(self.archive.read_bytes()[:-8])
        self.checksum.write_text(digest(self.archive.read_bytes()) + '  ' + self.archive.name + '\n')
        self.cli(ok=False)
        self.assertFalse(self.stage.exists())

    def test_insufficient_space_before_extraction(self):
        with mock.patch.object(M, 'HERE', self.bootstrap), mock.patch.object(M.shutil, 'disk_usage',
                return_value=shutil._ntuple_diskusage(1024, 1024, 0)):
            with self.assertRaisesRegex(M.InvalidBundle, 'Insufficient disk space'):
                M.run(self.namespace())
        self.assertFalse(self.stage.exists())

    def test_failed_staging_cleans_temporary_copy_and_preserves_source(self):
        original = self.archive.read_bytes()
        def fail(bundle, destination):
            (destination / 'partial').write_text('partial')
            raise OSError('simulated extraction failure')
        with mock.patch.object(M, 'HERE', self.bootstrap), mock.patch.object(M.Bundle, 'extract', fail):
            with self.assertRaisesRegex(OSError, 'simulated'):
                M.run(self.namespace())
        self.assertEqual(self.archive.read_bytes(), original)
        self.assertFalse(self.stage.exists())
        self.assertFalse(list(self.root.glob('.lepton-customize-*')))

    def test_failed_publication_cleans_restrictive_rootfs_permissions(self):
        self.put(M.ROOTFS + 'private-dir', b'', 0o000, ('directory', ''))
        self.put(M.ROOTFS + 'private-dir/file', b'original bytes', 0o000)
        self.write_bundle()
        original = self.archive.read_bytes()
        with mock.patch.object(M, 'HERE', self.bootstrap), mock.patch.object(M, 'publish',
                side_effect=OSError('simulated publication failure')):
            with self.assertRaisesRegex(OSError, 'publication failure'):
                M.run(self.namespace())
        self.assertEqual(self.archive.read_bytes(), original)
        self.assertFalse(self.stage.exists())
        self.assertFalse(list(self.root.glob('.lepton-customize-*')))

    def test_interrupt_cleans_temporary_copy(self):
        original = self.archive.read_bytes()
        old_handlers = {s: signal.getsignal(s) for s in (signal.SIGINT, signal.SIGTERM)}
        def interrupt(bundle, destination):
            (destination / 'partial').write_text('partial')
            signal.raise_signal(signal.SIGTERM)
        try:
            with mock.patch.object(M, 'HERE', self.bootstrap), mock.patch.object(M.Bundle, 'extract', interrupt), \
                    mock.patch.object(sys, 'argv', [str(self.tool), *self.args()]), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(M.main(), 1)
        finally:
            for sig, handler in old_handlers.items():
                signal.signal(sig, handler)
        self.assertEqual(self.archive.read_bytes(), original)
        self.assertFalse(self.stage.exists())
        self.assertFalse(list(self.root.glob('.lepton-customize-*')))

    def test_atomic_publication_refuses_concurrent_destination(self):
        real_publish = M.publish
        def collide(source, destination):
            destination.mkdir()
            (destination / 'marker').write_text('concurrent owner')
            real_publish(source, destination)
        with mock.patch.object(M, 'HERE', self.bootstrap), mock.patch.object(M, 'publish', collide):
            with self.assertRaisesRegex(M.InvalidBundle, 'refusing overwrite'):
                M.run(self.namespace())
        self.assertEqual((self.stage / 'marker').read_text(), 'concurrent owner')
        self.assertFalse(list(self.root.glob('.lepton-customize-*')))

    def test_atomic_publication_refuses_empty_concurrent_destination(self):
        real_publish = M.publish
        def collide(source, destination):
            destination.mkdir()
            real_publish(source, destination)
        with mock.patch.object(M, 'HERE', self.bootstrap), mock.patch.object(M, 'publish', collide):
            with self.assertRaisesRegex(M.InvalidBundle, 'refusing overwrite'):
                M.run(self.namespace())
        self.assertTrue(self.stage.is_dir())
        self.assertEqual(list(self.stage.iterdir()), [])
        self.assertFalse(list(self.root.glob('.lepton-customize-*')))


if __name__ == '__main__':
    unittest.main()
