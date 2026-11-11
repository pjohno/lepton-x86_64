#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Real shell injectors + tiny ext4/APK/APEX fixtures; no Google binaries.
The translator pin is patched only in in-process positive tests. The production
CLI has no pin override; unsupported SHA256 is tested through that CLI.
"""
import argparse
import contextlib
import gzip
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
import unittest
from unittest import mock
import zipfile

REPO = Path(__file__).resolve().parents[1]


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    loader.exec_module(module)
    return module


BASE = load('customize_fixture', REPO / 'tests/test-customize.py')
I = load('inject_test', REPO / 'compat_tool/tools/lepton_customize_inject.py')
M = BASE.M


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree(root):
    """Content/mode/link snapshot; read time changes are irrelevant."""
    return {p.relative_to(root).as_posix(): (p.lstat().st_mode, os.readlink(p) if p.is_symlink()
            else p.read_bytes() if p.is_file() else None) for p in root.rglob('*')}


class InjectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not all(shutil.which(p) for p in ('mke2fs', 'debugfs', 'rsync', 'cc', 'ssh-keygen')):
            raise unittest.SkipTest('Fixture construction needs cc, e2fsprogs, rsync and OpenSSH')
        BASE.CustomizeTests.setUpClass()

    @classmethod
    def tearDownClass(cls):
        BASE.CustomizeTests.tearDownClass()

    def setUp(self):
        self.base = BASE.CustomizeTests()
        self.base.setUp()
        self.addCleanup(self.base.doCleanups)
        self.root = self.base.root
        self.source = self.base.stage
        self.output = self.root / 'custom-stage'
        self.inputs = self.root / 'google-inputs'
        self.inputs.mkdir()
        self.images = self.inputs / 'logical-partitions'
        self.images.mkdir()
        self.env = dict(self.base.env)
        bindir = self.root / 'host-tools'
        programs = ('bash rsync sha256sum realpath find grep sort xargs mktemp debugfs unzip wc cmp '
                    'id mv rm mkdir chmod awk sed cut dd cat cp dirname basename').split()
        for program in programs:
            (bindir / program).symlink_to(shutil.which(program))
        # Upgrade the bundle fixture with actual standalone code/helpers.
        for name in M.REQUIRED:
            if name.startswith('tools/customize/'):
                origin = REPO / 'image-14/scripts' / name[len('tools/customize/'):]
            elif name.startswith('compat_tool/tools/lepton-customize'):
                origin = REPO / name
            elif name.startswith('compat_tool/liblepton/ndk_auxv/'):
                origin = REPO / name
            else:
                continue
            self.base.put(name, origin.read_bytes())
        self.base.put('compat_tool/tools/lepton_customize_inject.py',
                      (REPO / 'compat_tool/tools/lepton_customize_inject.py').read_bytes(), 0o644)
        self.base.put(M.ROOTFS + 'vendor/build.prop', b'ro.vendor.product.cpu.abilist=x86_64\n'
                      b'ro.vendor.product.cpu.abilist64=x86_64\nro.vendor.product.cpu.abilist32=\n', 0o644)
        jar = io.BytesIO()
        with zipfile.ZipFile(jar, 'w') as archive:
            archive.writestr('classes.dex', b'StartLocaleManagerService StartCrossProfileAppsService persist.lepton.forward_web_intents')
        self.base.put(M.ROOTFS + 'system/framework/services.jar', jar.getvalue(), 0o644)
        self.base.write_bundle()
        self.base.cli()
        self.before = tree(self.source)
        self.apex_name = 'com.google.android.widevine'
        apk = io.BytesIO()
        with zipfile.ZipFile(apk, 'w') as archive:
            archive.writestr('classes.dex', b'synthetic APK')
            archive.writestr('lib/x86_64/libfixture.so', b'fixture native library')
        xml = b'<permissions/>'
        self.google_props = b'ro.build.version.sdk=34\nro.build.flavor=sdk_gphone64_x86_64-user\n'
        fixtures = {
            'system': {'system/build.prop': self.google_props + b'ro.dalvik.vm.native.bridge=libndk_translation.so\n',
                       'system/etc/permissions/privapp-permissions-google.xml': xml},
            'product': {'app/Chrome/Chrome.apk.gz': gzip.compress(apk.getvalue()),
                        'app/TrichromeLibrary/TrichromeLibrary.apk.gz': gzip.compress(apk.getvalue()),
                        'priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk': apk.getvalue(),
                        'priv-app/Phonesky/Phonesky.apk': apk.getvalue(),
                        'etc/permissions/privapp-permissions-google-p.xml': xml,
                        'etc/sysconfig/google.xml': xml,
                        'etc/sysconfig/google-hiddenapi-package-whitelist.xml': xml,
                        'etc/default-permissions/default-permissions-sdk-google.xml': xml},
            'system_ext': {'priv-app/GoogleServicesFramework/GoogleServicesFramework.apk': apk.getvalue(),
                           'etc/permissions/privapp-permissions-google-se.xml': xml}}
        payload = self.inputs / 'ndk-translation/payload'
        self.bridge = BASE.CustomizeTests.shim
        arm64 = bytearray(self.bridge)
        arm64[18:20] = (183).to_bytes(2, 'little')
        files = {}
        for name in ('libndk_translation.so', 'libndk_translation_exec_region.so',
                     'libndk_translation_proxy_libEGL.so', 'libndk_translation_proxy_libvulkan.so'):
            files['system/lib64/' + name] = self.bridge
        # Real runtime names include '+' and '@'; they must survive extraction.
        for name in (['libc.so', 'libnative_bridge_vdso.so', 'libstdc++.so', 'android.hardware.renderscript@1.0.so'] +
                     [f'fixture-{n}.so' for n in range(50)]):
            files['system/lib64/arm64/' + name] = bytes(arm64)
        # A guest library that depends on libc++.so, as libandroid.so does.
        for name, data in self.arm64_dependency_pair().items():
            files['system/lib64/arm64/' + name] = data
        for name in ('linker64', 'app_process64'):
            files['system/bin/arm64/' + name] = bytes(arm64)
        for name in ('ld.config.arm64.txt', 'cpuinfo.arm64.txt'):
            files['system/etc/' + name] = b'synthetic config\n'
        for name, data in files.items():
            path = payload / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            path.chmod(0o755 if '/bin/' in name else 0o644)
        fixtures['system'].update(files)
        self.fixture_trees = {}
        for part, entries in fixtures.items():
            folder = self.root / ('tree-' + part)
            for name, contents in entries.items():
                path = folder / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(contents)
            self.fixture_trees[part] = folder
            self.image(folder, self.images / (part + '.img'))
        apex_tree = self.root / 'apex-tree'
        entries = {'apex_manifest.pb': self.apex_name.encode(),
                   'bin/hw/android.hardware.drm-service.widevine': b'service',
                   f'etc/{self.apex_name}.rc': b'init config',
                   f'etc/vintf/{self.apex_name}.xml': b'<manifest/>', 'lib64/libcrypto.so': b'library'}
        for name, data in entries.items():
            path = apex_tree / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.image(apex_tree, self.root / 'apex_payload.img', '4096')
        vendor = self.root / 'tree-vendor/apex'
        vendor.mkdir(parents=True)
        with zipfile.ZipFile(vendor / (self.apex_name + '.nonupdatable.apex'), 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.write(self.root / 'apex_payload.img', 'apex_payload.img')
        self.fixture_trees['vendor'] = vendor.parent
        self.image(vendor.parent, self.images / 'vendor.img')
        self.refresh_inputs()

    def image(self, folder, path, blocks='8192'):
        path.unlink(missing_ok=True)
        subprocess.run(['mke2fs', '-q', '-t', 'ext4', '-d', str(folder), str(path), blocks],
                       check=True, capture_output=True)

    def refresh_inputs(self):
        (self.inputs / 'SOURCE.properties').write_text(''.join(f'{k}={v}\n' for k, v in I.IDENTITY.items()))
        (self.inputs / 'BUILD.prop').write_bytes(self.google_props)
        (self.inputs / 'SOURCE.txt').write_text('Source zip: x86_64-34_r14.zip\nSource SHA256: ' + 'a' * 64 + '\n')
        (self.inputs / 'SOURCE-IMAGES.sha256').write_text(''.join(
            f'{sha(p)}  {p.name}\n' for p in sorted(self.images.glob('*.img'))))
        payload = self.inputs / 'ndk-translation/payload'
        (payload.parent / 'SHA256SUMS').write_text(''.join(f'{sha(p)}  ./{p.relative_to(payload).as_posix()}\n'
                                                        for p in sorted(payload.rglob('*')) if p.is_file()))
        (payload.parent / 'SOURCE.txt').write_text(f'Source SHA256: {sha(self.images / "system.img")}\n')
        (payload.parent / 'GOOGLE-BRIDGE-PROPERTIES.txt').write_text('ro.dalvik.vm.native.bridge=libndk_translation.so\n')

    def args(self, components=('gapps',), check=False, use_zip=False, save=False):
        return argparse.Namespace(stage_dir=self.source, output_stage=self.output,
                                  google_inputs=None if use_zip else self.inputs,
                                  google_zip=self.root / 'x86_64-34_r14.zip' if use_zip else None,
                                  save_google_inputs=self.root / 'cached-inputs' if save else None,
                                  with_ndk='ndk' in components, with_gapps='gapps' in components,
                                  with_widevine='widevine' in components, check=check, execute=not check)

    def run_inject(self, components=('gapps',), check=False, **kwargs):
        args = self.args(components, check, **kwargs)
        with mock.patch.dict(os.environ, self.env, clear=True), mock.patch.object(I, 'EXPECTED_TRANSLATOR', hashlib.sha256(self.bridge).hexdigest()):
            I.run(args, M)
        return args

    def assert_source_unchanged(self):
        self.assertEqual(tree(self.source), self.before)
        self.assertFalse(list(self.root.glob('.lepton-inject-*')))

    def cli(self, components=('gapps',), check=False, ok=True):
        command = [sys.executable, '-B', str(self.source / 'compat_tool/tools/lepton-customize'), 'inject',
                   '--check' if check else '--execute', '--stage-dir', str(self.source),
                   '--output-stage', str(self.output), '--google-inputs', str(self.inputs)]
        command += ['--with-' + c for c in components]
        result = subprocess.run(command, env=self.env, cwd=self.base.outside, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def check_result(self, components):
        metadata = json.loads((self.output / 'STAGE.json').read_text())
        self.assertEqual(metadata['state'], 'customized')
        self.assertEqual(metadata['components'], {c: c in components for c in ('ndk', 'gapps', 'widevine')})
        self.assertTrue(metadata['sysbake_required'])
        self.assertEqual(metadata['source_bundle']['bundle_id'], 'v0.2.0-alpha')
        self.assertEqual(metadata['google_source']['partitions']['system.img'], sha(self.images / 'system.img')) if 'ndk' in components or 'gapps' in components else None
        for name in (M.SHIM, M.EXTRACTOR, M.INOTIFY, M.INOTIFY_LIB, 'tools/bin/inotifywait'):
            self.assertEqual((self.output / name).read_bytes(), (self.source / name).read_bytes())
        self.assertEqual(tree(self.output / 'source-bundle'), tree(self.source / 'source-bundle'))
        self.assertFalse((self.output / 'BUNDLE.json').exists())
        self.assertFalse((self.output / 'compat_tool/sysbake').exists())
        self.assertFalse((self.output / 'compat_tool/sysbake.xattrs').exists())
        self.assertFalse((self.output / M.ROOTFS / 'system/lib64/liblepton_ndk_auxv.so').exists())
        self.assertEqual((self.output / 'compat_tool/liblepton/ndk_auxv/runtime.sh').read_bytes(),
                         (self.source / 'compat_tool/liblepton/ndk_auxv/runtime.sh').read_bytes())
        self.assert_source_unchanged()

    def test_ndk_only_reuses_shim_and_complete_payload(self):
        self.run_inject(('ndk',))
        self.check_result(('ndk',))
        rootfs = self.output / M.ROOTFS
        props = M.properties((rootfs / 'system/build.prop').read_bytes())
        self.assertEqual(props['ro.dalvik.vm.native.bridge'], 'libndk_translation.so')
        self.assertGreater(len(list((rootfs / 'system/lib64/arm64').iterdir())), 50)
        self.assertTrue((self.output / 'compat_tool/ndk-provenance/NDK-INJECTION-REPORT.txt').is_file())
        self.assertFalse((rootfs / 'system/product/priv-app/PrebuiltGmsCore').exists())

    def test_gapps_only_standalone_no_aosp_or_compiler(self):
        self.cli()
        self.check_result(('gapps',))
        rootfs = self.output / M.ROOTFS
        self.assertEqual(len(list(rootfs.rglob('*.apk'))), 5)
        self.assertTrue((rootfs / 'system/product/app/Chrome/lib/x86_64/libfixture.so').is_file())
        self.assertEqual((rootfs / 'system/framework/services.jar').read_bytes(),
                         (self.source / M.ROOTFS / 'system/framework/services.jar').read_bytes())

    def test_widevine_only_independent_and_flattened(self):
        # No NDK payload or GApps partitions/tools are required.
        shutil.rmtree(self.inputs / 'ndk-translation')
        (self.images / 'system.img').unlink()
        (self.images / 'product.img').unlink()
        (self.images / 'system_ext.img').unlink()
        self.cli(('widevine',))
        self.check_result(('widevine',))
        path = self.output / M.ROOTFS / 'vendor/apex' / self.apex_name
        self.assertTrue((path / 'bin/hw/android.hardware.drm-service.widevine').stat().st_mode & 0o111)
        self.assertIn('L3', (self.output / 'compat_tool/provenance/widevine/COMPONENTS.txt').read_text())

    def test_all_components_one_copy_and_provenance(self):
        real = I.command
        copy_commands = []
        def inspect(args, *a, **kw):
            if args[0] == 'rsync':
                copy_commands.append(args)
            return real(args, *a, **kw)
        with mock.patch.object(I, 'command', inspect):
            self.run_inject(('ndk', 'gapps', 'widevine'))
        self.check_result(('ndk', 'gapps', 'widevine'))
        self.assertEqual(len(copy_commands), 1)
        self.assertIn('--exclude=/compat_tool/images/rootfs/', copy_commands[0])
        for part in ('gapps', 'widevine', 'google-inputs'):
            self.assertTrue((self.output / 'compat_tool/provenance' / part).is_dir())

    def test_ndk_component_pairs(self):
        for components in (('ndk', 'gapps'), ('ndk', 'widevine')):
            with self.subTest(components=components):
                self.output = self.root / ('-'.join(components) + '-stage')
                self.run_inject(components)
                self.check_result(components)

    def test_no_component_selection_rejected(self):
        self.assertIn('Select at least one', self.cli((), ok=False).stderr)
        self.assert_source_unchanged()

    def test_unsafe_injection_parent_refused(self):
        directory = self.source / M.ROOTFS / 'system/product'
        directory.mkdir()
        (directory / 'priv-app').symlink_to('/system/priv-app')
        self.before = tree(self.source)
        self.assertIn('symlink parent', self.cli(check=True, ok=False).stderr)
        self.assert_source_unchanged()

    def test_logical_image_identity_checked_after_manifest(self):
        (self.fixture_trees['system'] / 'system/build.prop').write_text(
            'ro.build.version.sdk=33\nro.build.flavor=sdk_gphone64_x86_64-user\n')
        self.image(self.fixture_trees['system'], self.images / 'system.img')
        self.refresh_inputs()
        self.assertIn('Logical system.img', self.cli(check=True, ok=False).stderr)
        self.assert_source_unchanged()

    def test_prepared_inputs_do_not_require_zip_extractors(self):
        with mock.patch.object(I.zipfile, 'ZipFile', side_effect=AssertionError('ZIP must not be reopened')):
            self.run_inject(('ndk',), check=True)
        self.assertFalse((self.root / 'host-tools/lpunpack').exists())
        self.assertFalse(self.output.exists())
        self.assert_source_unchanged()

    def test_wrong_translator_pin_rejected_in_production_cli(self):
        result = self.cli(('ndk',), check=True, ok=False)
        self.assertIn('Unsupported translator SHA256', result.stderr)
        self.assert_source_unchanged()

    def test_incomplete_payload_rejected(self):
        (self.inputs / 'ndk-translation/payload/system/bin/arm64/linker64').unlink()
        self.refresh_inputs()
        with self.assertRaises(M.InvalidBundle):
            self.run_inject(('ndk',), check=True)
        self.assertFalse(self.output.exists())
        self.assert_source_unchanged()

    def test_missing_or_old_framework_refused(self):
        path = self.source / M.ROOTFS / 'system/framework/services.jar'
        for missing in (False, True):
            with self.subTest(missing=missing):
                if missing:
                    path.unlink()
                else:
                    with zipfile.ZipFile(path, 'w') as archive:
                        archive.writestr('classes.dex', b'old framework')
                result = self.cli(check=True, ok=False)
                self.assertIn('services.jar', result.stderr)
        self.assertFalse(self.output.exists())

    def test_missing_widevine_and_incomplete_gapps(self):
        for part, remote, component in [('vendor', f'/apex/{self.apex_name}.nonupdatable.apex', 'widevine'),
                                        ('product', '/priv-app/Phonesky/Phonesky.apk', 'gapps')]:
            subprocess.run(['debugfs', '-w', '-R', 'rm ' + remote, str(self.images / (part + '.img'))],
                           check=True, capture_output=True)
            self.refresh_inputs()
            self.cli((component,), check=True, ok=False)
        self.assert_source_unchanged()

    def test_incompatible_api_flavour_or_revision(self):
        for file, old, new in [('BUILD.prop', b'sdk=34', b'sdk=33'),
                               ('BUILD.prop', b'sdk_gphone64_x86_64-user', b'other'),
                               ('SOURCE.properties', b'Pkg.Revision=14', b'Pkg.Revision=15')]:
            path = self.inputs / file
            original = path.read_bytes()
            path.write_bytes(original.replace(old, new))
            self.cli(check=True, ok=False)
            path.write_bytes(original)
        self.assert_source_unchanged()

    def test_image_and_payload_checksums_rejected(self):
        with (self.images / 'system.img').open('ab') as stream:
            stream.write(b'changed')
        self.assertIn('checksum mismatch', self.cli(check=True, ok=False).stderr)
        self.assert_source_unchanged()

    def test_existing_output_unsafe_links_and_overlaps(self):
        self.output.mkdir()
        (self.output / 'marker').write_text('unchanged')
        self.cli(ok=False)
        self.assertEqual((self.output / 'marker').read_text(), 'unchanged')
        shutil.rmtree(self.output)
        self.output = self.source / 'nested'
        self.cli(ok=False)
        self.output = self.root / 'custom-stage'
        (self.inputs / 'external').symlink_to(self.source)
        self.assertIn('symlinks', self.cli(check=True, ok=False).stderr)
        self.assert_source_unchanged()

    def test_dirty_stage_refused(self):
        metadata = json.loads((self.source / 'STAGE.json').read_text())
        metadata['state'] = 'customized'
        (self.source / 'STAGE.json').write_text(json.dumps(metadata))
        self.assertIn('already customized', self.cli(check=True, ok=False).stderr)
        self.assertFalse(self.output.exists())

    def test_injected_output_as_source_gets_clear_refusal(self):
        self.cli(('gapps',))
        # Real NDK outputs also carry ndk-provenance, which previously produced
        # a misleading "unexpected state" refusal.
        (self.output / 'compat_tool/ndk-provenance').mkdir()
        result = subprocess.run([sys.executable, '-B', str(self.source / 'compat_tool/tools/lepton-customize'),
                                 'inject', '--check',
                                 '--stage-dir', str(self.output), '--output-stage', str(self.root / 'again'),
                                 '--google-inputs', str(self.inputs), '--with-gapps'],
                                env=self.env, cwd=self.base.outside, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('already customized', result.stderr)
        self.assertNotIn('unexpected state', result.stderr)

    def test_invalid_source_provenance_rejected_cleanly(self):
        path = self.source / 'source-bundle/SOURCE.json'
        metadata = json.loads(path.read_text())
        metadata['sha256'] = None
        path.write_text(json.dumps(metadata))
        self.before = tree(self.source)
        self.assertIn('Invalid source-bundle provenance', self.cli(check=True, ok=False).stderr)
        self.assertFalse(self.output.exists())
        self.assert_source_unchanged()

    def test_missing_host_dependency_actionable(self):
        (self.root / 'host-tools/rsync').unlink()
        result = self.cli(check=True, ok=False)
        self.assertIn('Missing host command: rsync; install rsync', result.stderr)
        self.assert_source_unchanged()

    def test_insufficient_space(self):
        with mock.patch.object(I.shutil, 'disk_usage', return_value=shutil._ntuple_diskusage(1, 1, 0)):
            with self.assertRaisesRegex(M.InvalidBundle, 'Insufficient disk space'):
                self.run_inject()
        self.assert_source_unchanged()

    def test_helper_failure_rolls_back_partial_output(self):
        real = I.shell_function
        def fail(lib, function, args, *a, **kw):
            if function == 'google_services_inject':
                (Path(args[0]) / 'partial').write_text('partial injection')
                raise M.InvalidBundle('simulated interrupted injection')
            return real(lib, function, args, *a, **kw)
        with mock.patch.object(I, 'shell_function', fail):
            with self.assertRaisesRegex(M.InvalidBundle, 'interrupted injection'):
                self.run_inject()
        self.assertFalse(self.output.exists())
        self.assert_source_unchanged()

    def test_signal_stops_helper_group_before_cleanup(self):
        # A real helper process would wait indefinitely; interrupt it locally.
        old = signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(M.InvalidBundle('interrupted')))
        try:
            signal.setitimer(signal.ITIMER_REAL, 0.1)
            with self.assertRaisesRegex(M.InvalidBundle, 'interrupted'):
                I.command(['bash', '-c', 'sleep 30 & wait'], M)
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, old)
        self.assert_source_unchanged()

    def zip_fixture(self, flavour=None, revision='14'):
        path = self.root / 'x86_64-34_r14.zip'
        identity = {**I.IDENTITY, 'Pkg.Revision': revision}
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('x86_64/build.prop', self.google_props if flavour is None else flavour)
            archive.writestr('x86_64/source.properties', ''.join(f'{k}={v}\n' for k, v in identity.items()))
            archive.writestr('x86_64/system.img', b'X' * 512)
        bindir = self.root / 'host-tools'
        for name, script in {
            'sfdisk': '#!/bin/sh\nprintf \'{"partitiontable":{"partitions":[{"name":"super","start":0,"size":1}]}}\\n\'\n',
            'lpunpack': '#!/bin/sh\necho unpack >> "$UNPACK_LOG"\ncp "$FIXTURE_IMAGES/"*.img "$2/"\n'}.items():
            (bindir / name).write_text(script)
            (bindir / name).chmod(0o755)
        self.env.update(FIXTURE_IMAGES=str(self.images), UNPACK_LOG=str(self.root / 'unpack.log'))
        return path

    def arm64_dependency_pair(self):
        build = self.root / 'arm64-deps'
        build.mkdir(exist_ok=True)
        def compile(source, output, *flags):
            subprocess.run(['cc', '-x', 'c', '-', '-o', str(build / output), '-shared', '-fPIC', '-nostdlib', *flags],
                           input=source.encode(), check=True, capture_output=True)
        compile('void cxx(void) {}', 'libc++.so', '-Wl,-soname,libc++.so')
        compile('extern void cxx(void); void android(void) { cxx(); }', 'libandroid.so',
                '-Wl,-soname,libandroid.so', '-Wl,--no-as-needed', '-x', 'none', str(build / 'libc++.so'))
        result = {}
        for name in ('libc++.so', 'libandroid.so'):
            data = bytearray((build / name).read_bytes())
            data[18:20] = (183).to_bytes(2, 'little')  # Present as AArch64.
            result[name] = bytes(data)
        return result

    def test_zip_preparation_keeps_plus_and_at_names_and_checks_dependencies(self):
        zip_path = self.zip_fixture()
        prepared = self.root / 'names-prepared'
        with mock.patch.dict(os.environ, self.env, clear=True), \
                mock.patch.object(I, 'EXPECTED_TRANSLATOR', hashlib.sha256(self.bridge).hexdigest()):
            I.command(['bash', self.source / 'tools/customize/prepare-google-inputs.sh',
                       '--zip', zip_path, '--output', prepared, '--with-ndk'], M)
        arm64 = prepared / 'ndk-translation/payload/system/lib64/arm64'
        for name in ('libc++.so', 'libstdc++.so', 'android.hardware.renderscript@1.0.so', 'libandroid.so'):
            self.assertTrue((arm64 / name).is_file(), name)
        listed = (prepared / 'ndk-translation/SHA256SUMS').read_text()
        self.assertIn('libc++.so', listed)
        # Without libc++.so, libandroid.so's dependency is unmet: refuse.
        subprocess.run(['debugfs', '-w', '-R', 'rm /system/lib64/arm64/libc++.so', str(self.images / 'system.img')],
                       check=True, capture_output=True)
        zip_path = self.zip_fixture()
        with mock.patch.dict(os.environ, self.env, clear=True), self.assertRaises(M.InvalidBundle):
            I.command(['bash', self.source / 'tools/customize/prepare-google-inputs.sh',
                       '--zip', zip_path, '--output', self.root / 'names-refused', '--with-ndk'], M)
        self.assertFalse((self.root / 'names-refused/ndk-translation/payload').exists())

    def test_reused_inputs_without_arm64_dependencies_are_refused(self):
        # Inputs made by the faulty 5588b21 extractor lack libc++.so but have a
        # self-consistent manifest; reuse must still refuse them.
        selected = dict(ndk=True, gapps=False, widevine=False)
        payload = self.inputs / 'ndk-translation/payload/system/lib64/arm64'
        needs_missing = self.arm64_dependency_on('libmissing.so')  # Host cc, before the restricted PATH.
        with mock.patch.dict(os.environ, self.env, clear=True), \
                mock.patch.object(I, 'EXPECTED_TRANSLATOR', hashlib.sha256(self.bridge).hexdigest()):
            I.validate_inputs(self.inputs, selected, M)  # Complete payload passes.
            (payload / 'libc++.so').rename(self.root / 'libc++.so')
            self.refresh_inputs()
            with self.assertRaisesRegex(M.InvalidBundle, 'lacks libc\\+\\+.so'):
                I.validate_inputs(self.inputs, selected, M)
            # A dependency other than libc++.so is also detected.
            (self.root / 'libc++.so').rename(payload / 'libc++.so')
            (payload / 'libc++.so').rename(payload / 'renamed.so')
            (payload / 'libc++.so').write_bytes((payload / 'libc.so').read_bytes())
            (payload / 'libandroid.so').write_bytes(needs_missing)
            self.refresh_inputs()
            with self.assertRaisesRegex(M.InvalidBundle, 'missing ARM64 dependencies \\(libmissing.so\\)'):
                I.validate_inputs(self.inputs, selected, M)

    def arm64_dependency_on(self, library):
        build = self.root / ('dep-' + library)
        build.mkdir()
        stub = build / library
        subprocess.run(['cc', '-x', 'c', '-', '-o', str(stub), '-shared', '-fPIC', '-nostdlib', '-Wl,-soname,' + library],
                       input=b'void dep(void) {}', check=True, capture_output=True)
        subprocess.run(['cc', '-x', 'c', '-', '-o', str(build / 'user.so'), '-shared', '-fPIC', '-nostdlib',
                        '-Wl,--no-as-needed', '-x', 'none', str(stub)],
                       input=b'extern void dep(void); void user(void) { dep(); }', check=True, capture_output=True)
        data = bytearray((build / 'user.so').read_bytes())
        data[18:20] = (183).to_bytes(2, 'little')
        return bytes(data)

    def test_default_zip_preparation_preserves_all_component_build_workflow(self):
        zip_path = self.zip_fixture()
        prepared = self.root / 'all-prepared'
        with mock.patch.dict(os.environ, self.env, clear=True), \
                mock.patch.object(I, 'EXPECTED_TRANSLATOR', hashlib.sha256(self.bridge).hexdigest()):
            I.command(['bash', self.source / 'tools/customize/prepare-google-inputs.sh',
                       '--zip', zip_path, '--output', prepared], M)
            identity = I.validate_inputs(prepared, dict(ndk=True, gapps=True, widevine=True), M)
        self.assertEqual(set(identity['partitions']), {'system.img', 'product.img', 'system_ext.img', 'vendor.img'})
        self.assertTrue((prepared / 'ndk-translation/payload/system/bin/arm64/linker64').is_file())
        self.assert_source_unchanged()

    def test_zip_preparation_widevine_only_and_saved_inputs_reuse(self):
        self.zip_fixture()
        self.run_inject(('widevine',), use_zip=True, save=True)
        cache = self.root / 'cached-inputs'
        self.assertTrue(cache.is_dir())
        self.assertFalse((cache / 'ndk-translation').exists())
        self.assertEqual((self.root / 'unpack.log').read_text(), 'unpack\n')
        self.assert_source_unchanged()
        self.output = self.root / 'second-output'
        self.inputs = cache
        self.cli(('widevine',))
        self.assertEqual((self.root / 'unpack.log').read_text(), 'unpack\n')

    def test_zip_check_leaves_no_stage_or_cache(self):
        self.zip_fixture()
        self.run_inject(('gapps',), use_zip=True, check=True, save=True)
        self.assertFalse(self.output.exists())
        self.assertFalse((self.root / 'cached-inputs').exists())
        self.assert_source_unchanged()

    def test_zip_invalid_revision_or_flavour_rejected_before_extraction(self):
        for flavour, revision in [(b'ro.build.version.sdk=33\n', '14'),
                                  (b'ro.build.version.sdk=34\nro.build.flavor=wrong\n', '14'),
                                  (None, '15')]:
            self.zip_fixture(flavour, revision)
            with self.assertRaises(M.InvalidBundle):
                self.run_inject(('widevine',), use_zip=True, check=True)
        self.assertFalse((self.root / 'unpack.log').exists())
        self.assert_source_unchanged()

    def test_zip_missing_unpacker_dependency(self):
        self.zip_fixture()
        (self.root / 'host-tools/lpunpack').unlink()
        with self.assertRaisesRegex(M.InvalidBundle, 'Missing host command: lpunpack'):
            self.run_inject(('widevine',), use_zip=True, check=True)
        self.assert_source_unchanged()

    def test_atomic_output_refuses_concurrent_directory(self):
        publish = M.publish
        def collide(source, target):
            if target == self.output:
                target.mkdir()
            publish(source, target)
        with mock.patch.object(M, 'publish', collide):
            with self.assertRaisesRegex(M.InvalidBundle, 'refusing overwrite'):
                self.run_inject(('widevine',))
        self.assertTrue(self.output.is_dir())
        self.assertEqual(list(self.output.iterdir()), [])
        self.assert_source_unchanged()

    def test_widevine_apex_symlink_rejected(self):
        payload = self.root / 'apex-tree'
        (payload / 'lib64/libcrypto.so').unlink()
        (payload / 'lib64/libcrypto.so').symlink_to('/etc/passwd')
        self.image(payload, self.root / 'apex_payload.img', '4096')
        with zipfile.ZipFile(self.fixture_trees['vendor'] / 'apex' /
                             (self.apex_name + '.nonupdatable.apex'), 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.write(self.root / 'apex_payload.img', 'apex_payload.img')
        self.image(self.fixture_trees['vendor'], self.images / 'vendor.img')
        self.refresh_inputs()
        self.cli(('widevine',), ok=False)
        self.assertFalse(self.output.exists())
        self.assert_source_unchanged()

    def test_spaces_in_output_path_supported(self):
        self.output = self.root / 'stage with spaces'
        self.cli(('gapps', 'widevine'))
        self.check_result(('gapps', 'widevine'))


class LocalGoogleIntegration(unittest.TestCase):
    @unittest.skipUnless(os.environ.get('LEPTON_TEST_BASE_STAGE') and os.environ.get('LEPTON_TEST_GOOGLE_INPUTS'),
                         'Optional real integration: set LEPTON_TEST_BASE_STAGE and LEPTON_TEST_GOOGLE_INPUTS')
    def test_real_inputs(self):
        # Executes the production CLI/pin. Real inputs are never added to Git.
        import tempfile
        with tempfile.TemporaryDirectory() as work:
            source = Path(os.environ['LEPTON_TEST_BASE_STAGE'])
            result = subprocess.run([sys.executable, '-B', str(REPO / 'compat_tool/tools/lepton-customize'), 'inject',
                '--execute', '--stage-dir', str(source), '--output-stage', work + '/stage',
                '--google-inputs', os.environ['LEPTON_TEST_GOOGLE_INPUTS'], '--with-ndk', '--with-gapps', '--with-widevine'])
            self.assertEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
