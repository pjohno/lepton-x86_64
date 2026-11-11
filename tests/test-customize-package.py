#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Phase 4 offline tests: stage ADB, fresh isolated sysbake, standalone packaging.

The real bundled sysbake helper runs with hermetic test doubles for Podman,
Weston, systemd and the Android boot (no Android, Binder, network or GPU).
CLIs run from the stage's own copy of lepton-customize with a PATH that holds
no compiler, Cargo or source checkout.
"""
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
FAKE_ADB = REPO / 'image-14/tests/lib/fake-google-adb.sh'


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    loader.exec_module(module)
    return module


BASE = load('customize_fixture', REPO / 'tests/test-customize.py')
M = BASE.M

# Stands in for `./lepton sysbake`: writes Android-like system data with real
# user.* xattrs. It carries the markers the isolated helper patches.
FAKE_LEPTON = rb'''#!/bin/bash
# Synthetic Android boot for isolated sysbake tests.
if systemctl --user is-system-running >/dev/null && [[ -z "${CATATONIT_PID}" ]]; then
    :
fi
function lepton_open_lock() { :; }
[[ "${1:-}" == sysbake ]] || exit 2
[[ "${LEPTON_ISOLATED_SYSBAKE:-}" == 1 && "${LEPTON_FORCE_SOFTWARE:-}" == true ]] || exit 3
[[ "${FAKE_SYSBAKE:-ok}" != fail ]] || { echo 'Android did not finish booting' >&2; exit 1; }
mkdir -p sysbake/system sysbake/misc/keystore sysbake/user_de/0 sysbake/misc/ethernet
packages='com.android.settings'
[[ -z "${FAKE_SYSBAKE_GMS:-}" ]] || packages="$packages com.google.android.gms com.android.vending"
printf 'ABX\0%s\n' "$packages" > sysbake/system/packages.xml
printf 'keys\n' > sysbake/misc/keystore/user_0
printf 'onboot\n' > sysbake/lepton-onboot
ln -s /data/user/0 sysbake/user_de/current
chmod 0700 sysbake/misc/keystore
chmod 0600 sysbake/misc/keystore/user_0
setfattr -n user.default -v 0x3001 sysbake/system
setfattr -n user.inode_cache -v 0x01 sysbake/user_de/0
[[ "${FAKE_SYSBAKE:-ok}" != ipconfig ]] || printf 'host address\n' > sysbake/misc/ethernet/ipconfig.txt
exit 0
'''
FAKE_PODMAN = r'''#!/bin/bash
root=''; run=''
while [[ "${1:-}" == --* ]]; do
    case "$1" in --root=*) root="${1#*=}" ;; --runroot=*) run="${1#*=}" ;; esac
    shift
done
case "${1:-}" in
    info) if [[ "$*" == *GraphRoot* ]]; then echo "$root"; else echo "$run"; fi ;;
    unshare) shift; exec "$@" ;;
    *) exit 0 ;;
esac
'''
FAKE_WESTON = r'''#!/usr/bin/env python3
import os, signal, socket, sys
name = next(a.split('=', 1)[1] for a in sys.argv if a.startswith('--socket='))
path = os.path.join(os.environ['XDG_RUNTIME_DIR'], name)
server = socket.socket(socket.AF_UNIX)
server.bind(path)
def stop(*_):
    os.unlink(path)
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
while True:
    signal.pause()
'''
FAKE_SYSTEMCTL = r'''#!/bin/bash
case "$*" in
    *is-system-running*) echo "${FAKE_SYSTEMD_STATE:-running}"; [[ "${FAKE_SYSTEMD_STATE:-running}" == running ]] ;;
    *is-active*) exit 3 ;;
    *) exit 0 ;;
esac
'''
REAL_TOOLS = ('bash rsync getfattr setfattr timeout flock realpath mktemp pkill sed grep tail cp mv rm mkdir '
              'chmod touch ln id uname cat sleep rmdir dirname basename tr cut awk find sort sha256sum xargs '
              'stty env date head wc cmp ls tar gzip').split()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def tree(root):
    return {p.relative_to(root).as_posix(): (p.lstat().st_mode, os.readlink(p) if p.is_symlink()
            else p.read_bytes() if p.is_file() else None) for p in Path(root).rglob('*')}


def fake_adb(directory, version='37.0.1-15733141'):
    result = subprocess.run(['bash', '-c', 'source "$1"; fake_adb_zip "$2" "$3"', 'x', str(FAKE_ADB),
                             str(directory), version], check=True, capture_output=True, text=True)
    return result.stdout.strip(), Path(directory) / 'platform-tools.zip'


def extend_bundle(base, adb_sha):
    """Upgrade the Stage 2 fixture into a complete runnable stage fixture."""
    for path in sorted((REPO / 'compat_tool/tools').iterdir()):
        if path.is_file() and path.suffix != '.pyc':
            data = path.read_bytes()
            if path.name == 'lepton-install-bundle':
                data = re.sub(rb"^ADB_SHA256='[0-9a-f]{64}'$", f"ADB_SHA256='{adb_sha}'".encode(), data, flags=re.M)
            base.put('compat_tool/tools/' + path.name, data, 0o644 if path.suffix == '.py' else 0o755)
    for name in M.REQUIRED:
        if name.startswith('tools/customize/'):
            base.put(name, (REPO / 'image-14/scripts' / name[len('tools/customize/'):]).read_bytes())
    base.put('compat_tool/lepton', FAKE_LEPTON)
    base.put('compat_tool/lepton-x86_64-entry', (REPO / 'compat_tool/lepton-x86_64-entry').read_bytes())
    base.put('compat_tool/toolmanifest.vdf', b'"manifest" { "commandline" "/lepton-x86_64-entry %verb% --" }\n', 0o644)
    base.put('compat_tool/liblepton/utils.sh', b'#!/bin/bash\nfunction wait_for_file()\n{\n    true\n}\n')
    base.put('compat_tool/liblepton/mounting.sh', b'#!/bin/bash\n# gbm-software-vintf.xml\nETHERNET_APEX_CONFIG=x\n')
    base.put('compat_tool/liblepton/baking.sh', b'#!/bin/bash\n# never bake the build host address\n')
    base.put('compat_tool/liblepton/ndk_auxv/validate.sh', (REPO / 'compat_tool/liblepton/ndk_auxv/validate.sh').read_bytes())
    base.put(M.ROOTFS + 'system/etc/init/hw/init.rc', b'service binderfs /system/bin/binderfs-ensure\n', 0o644)
    for name in ('vendor/lib64/hw/vulkan.pastel.so', 'vendor/lib64/hw/gralloc.default.so'):
        base.put(M.ROOTFS + name, b'software renderer', 0o644)
    if M.ROOTFS + 'system/framework/services.jar' not in base.nodes:
        base.put(M.ROOTFS + 'system/framework/services.jar', b'framework', 0o644)
    base.put('GAPPS.md', b'GApps guide\n', 0o644)


class Harness:
    """Host doubles and CLI helpers shared by the Phase 4 suites."""

    def setup_host(self, root, env):
        runtime = Path(f'/run/user/{os.getuid()}')
        if not (runtime.is_dir() and runtime.stat().st_uid == os.getuid()):
            raise unittest.SkipTest('The isolated sysbake helper requires a /run/user runtime directory')
        probe = root / 'xattr-probe'
        probe.write_text('')
        try:
            os.setxattr(probe, 'user.probe', b'1')
        except OSError:
            raise unittest.SkipTest('Temporary filesystem lacks user extended attributes')
        hosts = root / 'host-tools'
        for program in ('bash', 'grep'):
            if not (hosts / program).exists():
                (hosts / program).symlink_to(shutil.which(program))
        self.fakes = root / 'sysbake-tools'
        self.fakes.mkdir()
        for program in REAL_TOOLS:
            if shutil.which(program) and not (hosts / program).exists():
                (self.fakes / program).symlink_to(shutil.which(program))
        for name, text in (('podman', FAKE_PODMAN), ('weston', FAKE_WESTON), ('systemctl', FAKE_SYSTEMCTL),
                           ('fuse-overlayfs', '#!/bin/sh\nexit 0\n'), ('newuidmap', '#!/bin/sh\nexit 0\n'),
                           ('newgidmap', '#!/bin/sh\nexit 0\n')):
            (self.fakes / name).write_text(text)
            (self.fakes / name).chmod(0o755)
        filesystems = root / 'filesystems'
        filesystems.write_text('nodev\tsysfs\nnodev\tbinder\n')
        self.host_env = dict(env, PATH=f'{hosts}:{self.fakes}', XDG_RUNTIME_DIR=str(runtime),
                             LEPTON_HOST_FILESYSTEMS=str(filesystems))
        self.host_env.pop('FAKE_SYSBAKE', None)

    def run_tool(self, stage, command, *args, ok=True, env=None):
        tool = stage / 'compat_tool/tools/lepton-customize'
        result = subprocess.run([sys.executable, '-B', str(tool), command, *args], cwd=self.outside,
                                env=env or self.host_env, capture_output=True, text=True, timeout=300)
        output = result.stdout + result.stderr
        if ok:
            self.assertEqual(result.returncode, 0, output)
        else:
            self.assertNotEqual(result.returncode, 0, output)
        return output

    def sysbake(self, stage, *extra, ok=True, env=None):
        return self.run_tool(stage, 'sysbake', '--execute', '--stage-dir', str(stage), *extra, ok=ok, env=env)

    def package(self, stage, bundle_id='my-build', mode='--execute', *extra, ok=True):
        return self.run_tool(stage, 'package', mode, '--stage-dir', str(stage), '--output-dir', str(self.bundles),
                             '--bundle-id', bundle_id, *extra, ok=ok)

    def state(self, stage):
        return json.loads((stage / 'STAGE.json').read_text())

    def members(self, archive):
        with tarfile.open(archive) as tar:
            return {m.name: m for m in tar}

    def read_member(self, archive, name):
        with tarfile.open(archive) as tar:
            return tar.extractfile('./' + name).read()

    def install(self, archive_dir, bundle_id, home):
        """Install with the generated installer, as a user would."""
        os_release = home.parent / f'os-release-{bundle_id}'
        os_release.write_text('ID=steamos\nNAME="SteamOS"\n')
        bindir = home.parent / f'curl-{bundle_id}'
        bindir.mkdir()
        subprocess.run(['bash', '-c', 'source "$1"; install_fake_curl "$2"', 'x', str(FAKE_ADB), str(bindir)], check=True)
        env = {k: v for k, v in os.environ.items() if not k.startswith(('LEPTON_', 'XDG_')) and k not in ('DISPLAY', 'WAYLAND_DISPLAY')}
        env.update(HOME=str(home), PATH=f'{bindir}:{os.environ["PATH"]}', LEPTON_SKIP_HOST_CHECK='1',
                   LEPTON_INSTALL_IN_TERMINAL='1', LEPTON_NO_DIALOGS='1', LEPTON_HOST_OS_RELEASE=str(os_release),
                   FAKE_ADB_ZIP=str(self.adb_zip), FAKE_CURL_LOG=str(home.parent / 'curl.log'))
        home.mkdir()
        (home / 'Desktop').mkdir()
        result = subprocess.run(['bash', str(archive_dir / f'lepton-x86_64-{bundle_id}.install.sh'), '--allow-non-amd'],
                                env=env, capture_output=True, text=True, timeout=300)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout


class SysbakePackageTests(Harness, unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        BASE.CustomizeTests.setUpClass()

    @classmethod
    def tearDownClass(cls):
        BASE.CustomizeTests.tearDownClass()

    def setUp(self):
        self.base = BASE.CustomizeTests()
        self.base.setUp()
        self.addCleanup(self.base.doCleanups)
        self.root, self.outside, self.stage = self.base.root, self.base.outside, self.base.stage
        self.adb_sha, self.adb_zip = fake_adb(self.root / 'fake-adb')
        extend_bundle(self.base, self.adb_sha)
        self.base.write_bundle()
        self.base.cli()
        self.setup_host(self.root, self.base.env)
        self.bundles = self.root / 'bundles'

    def test_sysbake_check_reports_every_missing_host_requirement(self):
        empty = self.root / 'no-binder'
        empty.write_text('nodev\tsysfs\n')
        stripped = self.root / 'stripped'
        stripped.mkdir()
        for entry in self.fakes.iterdir():
            if entry.name not in ('podman', 'weston', 'getfattr', 'setfattr', 'fuse-overlayfs'):
                (stripped / entry.name).symlink_to(entry)
        before = tree(self.stage)
        env = dict(self.host_env, PATH=f'{self.root / "host-tools"}:{stripped}', LEPTON_HOST_FILESYSTEMS=str(empty),
                   FAKE_SYSTEMD_STATE='offline')
        output = self.run_tool(self.stage, 'sysbake', '--check', '--stage-dir', str(self.stage), ok=False, env=env)
        for text in ('Missing host command: podman', 'Missing host command: weston', 'Missing host command: getfattr',
                     'Missing host command: setfattr', 'Missing host command: fuse-overlayfs', 'dnf install attr',
                     'BinderFS', 'systemd user session'):
            self.assertIn(text, output)
        self.assertEqual(tree(self.stage), before)

    def test_sysbake_check_changes_nothing(self):
        before = tree(self.stage)
        output = self.run_tool(self.stage, 'sysbake', '--check', '--stage-dir', str(self.stage))
        self.assertIn('Isolated sysbake preflight passed', output)
        self.assertEqual(tree(self.stage), before)

    def test_fresh_sysbake_packages_and_installs_with_existing_installer(self):
        output = self.sysbake(self.stage)
        self.assertIn('fresh sysbake validated', output)
        state = self.state(self.stage)
        self.assertEqual((state['state'], state['baked_from'], state['sysbake_required']), ('baked', 'prepared', False))
        self.assertEqual(state['sysbake']['origin'], 'generated')
        xattrs = (self.stage / 'compat_tool/sysbake.xattrs').read_text()
        self.assertIn('user.default', xattrs)
        self.assertNotIn('security.selinux', xattrs)
        self.assertFalse((self.stage / 'compat_tool/sysbake/lepton-onboot').exists())
        self.assertFalse(list(self.stage.glob('.sysbake-work.*/podman-storage')))
        before = tree(self.stage)
        self.package(self.stage, mode='--check')
        self.assertFalse(self.bundles.exists())
        output = self.package(self.stage)
        self.assertEqual(tree(self.stage), before, 'packaging must not change the stage')
        archive = self.bundles / 'lepton-x86_64-my-build.tar.gz'
        installer = self.bundles / 'lepton-x86_64-my-build.install.sh'
        checksum = self.bundles / 'lepton-x86_64-my-build.tar.gz.sha256'
        self.assertIn('NOT an official', self.read_member(archive, 'tools/BUNDLE-PROVENANCE.txt').decode())
        self.assertIn('not be presented as an official', output)
        self.assertEqual(checksum.read_text(), f'{sha(archive.read_bytes())}  {archive.name}\n'
                                               f'{sha(installer.read_bytes())}  {installer.name}\n')
        self.assertEqual(sorted(p.name for p in self.bundles.iterdir()), sorted([archive.name, installer.name, checksum.name]))
        metadata = json.loads(self.read_member(archive, 'BUNDLE.json'))
        self.assertEqual(metadata['tool_id'], 'lepton_custom_my_build')
        self.assertEqual((metadata['gapps'], metadata['ndk'], metadata['origin']), (False, False, 'lepton-customize'))
        members = self.members(archive)
        for name in ('./compat_tool/sysbake/system/packages.xml', './compat_tool/sysbake.xattrs',
                     './compat_tool/tools/lepton-customize', './STEAM-DECK-INSTALL.txt', './GAPPS.md',
                     './compat_tool/provenance/sources/v0.2.0-alpha/SOURCE.json'):
            self.assertIn(name, members)
        self.assertEqual(members['./compat_tool/sysbake/misc/keystore'].mode & 0o7777, 0o700)
        self.assertEqual(members['./compat_tool/sysbake/user_de/current'].linkname, '/data/user/0')
        self.assertEqual(members['./' + M.ROOTFS + 'system/etc/unchanged.conf'].mode & 0o777, 0o640)
        for name in members:
            self.assertNotRegex(name, r'^\./STAGE\.json$|^\./source-bundle|platform-tools|\.sysbake-work|podman-storage|'
                                      r'install-profile|\.runtime-profile|compatdata')
        # The archive is accepted by the existing installer and Steam registration.
        home = self.root / 'home'
        self.install(self.bundles, 'my-build', home)
        dest = home / '.local/share/lepton_custom_my_build'
        self.assertTrue((dest / 'compat_tool/sysbake/system/packages.xml').is_file())
        self.assertTrue((home / '.local/share/Steam/compatibilitytools.d/lepton_custom_my_build.vdf').is_file())
        self.assertTrue((dest / 'tools/platform-tools/adb').is_file())

    def test_sysbake_failure_leaves_stage_unbaked(self):
        before = self.state(self.stage)
        output = self.sysbake(self.stage, ok=False, env=dict(self.host_env, FAKE_SYSBAKE='fail'))
        self.assertIn('STAGE.json is unchanged', output)
        self.assertIn('diagnostics:', output)
        self.assertEqual(self.state(self.stage), before)
        self.assertFalse((self.stage / 'compat_tool/sysbake').exists())
        self.assertFalse((self.stage / 'compat_tool/sysbake.xattrs').exists())
        self.assertIn('no validated sysbake', self.package(self.stage, ok=False))

    def test_invalid_sysbake_is_moved_aside_never_recorded(self):
        before = self.state(self.stage)
        # A base stage must not register Google Play services.
        output = self.sysbake(self.stage, ok=False, env=dict(self.host_env, FAKE_SYSBAKE_GMS='1'))
        self.assertIn('Google Play services in a stage without GApps', output)
        self.assertEqual(self.state(self.stage), before)
        self.assertFalse((self.stage / 'compat_tool/sysbake').exists())
        rejected = list(self.stage.glob('.sysbake-rejected-*'))
        self.assertEqual(len(rejected), 1)
        self.assertTrue((rejected[0] / 'sysbake/system/packages.xml').is_file())
        # The helper's own checks also leave no state.
        self.sysbake(self.stage, ok=False, env=dict(self.host_env, FAKE_SYSBAKE='ipconfig'))
        self.assertEqual(self.state(self.stage), before)
        # A clean retry still works; rejected output is never packaged.
        self.sysbake(self.stage)
        self.package(self.stage)
        self.assertFalse(any('rejected' in n for n in self.members(self.bundles / 'lepton-x86_64-my-build.tar.gz')))

    def test_existing_sysbake_is_never_overwritten(self):
        (self.stage / 'compat_tool/sysbake').mkdir()
        self.assertIn('refusing overwrite', self.sysbake(self.stage, ok=False))
        self.assertEqual(list((self.stage / 'compat_tool/sysbake').iterdir()), [])
        shutil.rmtree(self.stage / 'compat_tool/sysbake')
        self.sysbake(self.stage)
        self.assertIn('already has a fresh validated sysbake', self.sysbake(self.stage, ok=False))

    def test_rootfs_edit_before_sysbake_is_detected_when_recorded(self):
        state = self.state(self.stage)
        state['android'] = {'rootfs_tree_sha256': '0' * 64}
        (self.stage / 'STAGE.json').write_text(json.dumps(state))
        self.assertIn('changed after this stage was created', self.sysbake(self.stage, ok=False))

    def test_android_or_sysbake_changes_after_bake_block_packaging(self):
        self.sysbake(self.stage)
        rootfs_file = self.stage / M.ROOTFS / 'system/etc/unchanged.conf'
        original = rootfs_file.read_bytes()
        for path, change in ((rootfs_file, lambda p: p.write_bytes(b'modified Android')),
                             (rootfs_file, lambda p: p.chmod(0o644)),
                             (self.stage / 'compat_tool/sysbake/misc/keystore/user_0', lambda p: p.write_text('x')),
                             (self.stage / 'compat_tool/sysbake.xattrs', lambda p: p.write_text(p.read_text() + '\n'))):
            with self.subTest(path=path.name):
                saved = (path.read_bytes(), path.stat().st_mode)
                change(path)
                self.assertRegex(self.package(self.stage, mode='--check', ok=False), 'differs|changed')
                path.write_bytes(saved[0])
                path.chmod(saved[1] & 0o7777)
        self.assertEqual(rootfs_file.read_bytes(), original)
        self.package(self.stage, mode='--check')

    def test_package_identity_and_output_guards(self):
        self.sysbake(self.stage)
        self.assertIn('new --bundle-id', self.package(self.stage, 'v0.2.0-alpha', ok=False))
        self.assertIn('new --tool-id', self.package(self.stage, 'x', '--execute', '--tool-id',
                                                    'lepton_x86_64_v0_2_0_alpha', ok=False))
        self.assertIn('Invalid bundle ID', self.package(self.stage, '../x', ok=False))
        inside = self.run_tool(self.stage, 'package', '--check', '--stage-dir', str(self.stage), '--output-dir',
                               str(self.stage / 'out'), '--bundle-id', 'x', ok=False)
        self.assertIn('outside the stage', inside)
        self.bundles.mkdir()
        existing = self.bundles / 'lepton-x86_64-my-build.install.sh'
        existing.write_text('keep me')
        self.assertIn('refusing overwrite', self.package(self.stage, ok=False))
        self.assertEqual(existing.read_text(), 'keep me')
        self.assertFalse((self.bundles / 'lepton-x86_64-my-build.tar.gz').exists())

    def test_interrupted_packaging_publishes_nothing(self):
        self.sysbake(self.stage)
        P = load('package_test', self.stage / 'compat_tool/tools/lepton_customize_package.py')
        args = mock.Mock(stage_dir=str(self.stage), output_dir=str(self.bundles), bundle_id='broken', tool_id=None,
                         tool_name=None, check=False, execute=True)

        def interrupted(*_):
            raise M.InvalidBundle('Interrupted by signal 15')
        with mock.patch.dict(os.environ, self.host_env, clear=True), mock.patch.object(P, 'write_archive', interrupted):
            with self.assertRaises(M.InvalidBundle):
                P.package_main(args, M)
        self.assertEqual(list(self.bundles.iterdir()), [])

    def test_adb_is_stage_only_and_never_packaged(self):
        output = self.run_tool(self.stage, 'adb', '--check', '--stage-dir', str(self.stage), '--adb-zip', str(self.adb_zip))
        self.assertIn('nothing changed', output)
        self.assertFalse((self.stage / 'tools/platform-tools').exists())
        _, wrong = fake_adb(self.root / 'wrong-adb', '1.0.0-1')
        self.assertIn('pinned', self.run_tool(self.stage, 'adb', '--execute', '--stage-dir', str(self.stage),
                                              '--adb-zip', str(wrong), ok=False))
        self.assertFalse((self.stage / 'tools/platform-tools').exists())
        self.run_tool(self.stage, 'adb', '--execute', '--stage-dir', str(self.stage), '--adb-zip', str(self.adb_zip))
        adb = self.stage / 'tools/platform-tools/adb'
        self.assertEqual(sha(adb.read_bytes()), self.adb_sha)
        self.assertTrue((self.stage / 'tools/licenses/google-platform-tools-NOTICE.txt').is_file())
        self.assertIn('already staged', self.run_tool(self.stage, 'adb', '--execute', '--stage-dir', str(self.stage),
                                                      '--adb-zip', str(self.adb_zip)))
        self.sysbake(self.stage)
        self.package(self.stage)
        names = self.members(self.bundles / 'lepton-x86_64-my-build.tar.gz')
        self.assertFalse([n for n in names if re.search(r'(^|/)adb$|platform-tools', n)])

    def test_adb_download_is_https_google_only(self):
        P = load('package_adb', self.stage / 'compat_tool/tools/lepton_customize_package.py')
        with self.assertRaisesRegex(M.InvalidBundle, 'Unexpected download URL'):
            P.download('http://example.com/platform-tools.zip', self.root / 'x.zip', M)
        handler = P.HttpsOnly()
        with self.assertRaises(Exception):
            handler.redirect_request(mock.Mock(), None, 302, 'Found', {}, 'http://dl.google.com/x')

    def test_no_compiler_cargo_or_checkout_on_path(self):
        path = self.host_env['PATH'].split(':')
        for program in ('cc', 'gcc', 'clang', 'cargo', 'rustc', 'make', 'git', 'repo'):
            self.assertFalse(any((Path(d) / program).exists() for d in path), program)
        self.assertFalse((self.outside / '.build-env').exists())
        self.sysbake(self.stage)
        self.package(self.stage)


INJECT = load('inject_fixture', REPO / 'tests/test-customize-inject.py')


class CustomizedWorkflowTests(Harness, INJECT.InjectionTests):
    """Workflow A: prepared stage -> inject -> fresh sysbake -> installable bundle."""
    # Only the workflow tests below run here; the injection suite runs separately.
    def extend_bundle(self):
        self.adb_sha, self.adb_zip = fake_adb(self.base.root / 'fake-adb')
        extend_bundle(self.base, self.adb_sha)

    def setUp(self):
        super().setUp()
        self.outside = self.base.outside
        self.setup_host(self.root, self.env)
        self.bundles = self.root / 'bundles'

    def customize(self, components):
        self.run_inject(components)
        state = self.state(self.output)
        self.assertEqual(state['state'], 'customized')
        self.assertRegex(state['android']['rootfs_tree_sha256'], '^[0-9a-f]{64}$')
        return state

    def test_gapps_widevine_stage_sysbake_package_install(self):
        self.customize(('gapps', 'widevine'))
        self.assertIn('lacks Google Play services', self.sysbake(self.output, ok=False))
        self.assertEqual(self.state(self.output)['state'], 'customized')
        self.sysbake(self.output, env=dict(self.host_env, FAKE_SYSBAKE_GMS='1'))
        state = self.state(self.output)
        self.assertEqual((state['state'], state['baked_from']), ('baked', 'customized'))
        self.package(self.output, 'gapps-local')
        archive = self.bundles / 'lepton-x86_64-gapps-local.tar.gz'
        metadata = json.loads(self.read_member(archive, 'BUNDLE.json'))
        self.assertEqual((metadata['gapps'], metadata['ndk']), (True, False))
        image = self.read_member(archive, 'tools/IMAGE-PROVENANCE.txt').decode()
        self.assertIn('NOT compiled from a source checkout', image)
        self.assertIn('./tools/BASE-IMAGE-PROVENANCE.txt', self.members(archive))
        provenance = self.read_member(archive, 'tools/BUNDLE-PROVENANCE.txt').decode()
        self.assertIn('modified afterwards by lepton-customize inject', provenance)
        self.assertIn('Sysbake: generated locally', provenance)
        self.assertNotIn('\nLauncher source commit:', provenance)
        self.assertIn('./compat_tool/provenance/gapps/SHA256SUMS', self.members(archive))
        home = self.root / 'home'
        self.install(self.bundles, 'gapps-local', home)
        self.assertTrue((home / '.local/share/lepton_custom_gapps_local/compat_tool/images/rootfs/'
                         'system/product/priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk').is_file())

    def test_injected_component_tampering_blocks_packaging(self):
        self.customize(('gapps',))
        self.sysbake(self.output, env=dict(self.host_env, FAKE_SYSBAKE_GMS='1'))
        apk = self.output / M.ROOTFS / 'system/product/priv-app/Phonesky/Phonesky.apk'
        apk.write_bytes(b'tampered')
        self.assertRegex(self.package(self.output, mode='--check', ok=False), 'provenance|differs')

    def test_component_record_must_match_rootfs(self):
        self.customize(('gapps',))
        self.sysbake(self.output, env=dict(self.host_env, FAKE_SYSBAKE_GMS='1'))
        state = self.state(self.output)
        state['components']['gapps'] = False
        (self.output / 'STAGE.json').write_text(json.dumps(state))
        self.assertIn('does not match the stage record', self.package(self.output, mode='--check', ok=False))


# Do not rerun the inherited injection tests in this suite.
for _name in [n for n in dir(INJECT.InjectionTests) if n.startswith('test_')]:
    if _name not in CustomizedWorkflowTests.__dict__:
        setattr(CustomizedWorkflowTests, _name, None)


if __name__ == '__main__':
    unittest.main()
