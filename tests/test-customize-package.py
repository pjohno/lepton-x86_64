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
L = load('bundle_lib', REPO / 'compat_tool/tools/lepton_bundle_lib.py')

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
packages="${FAKE_PACKAGES_BASE:?}"
[[ -z "${FAKE_SYSBAKE_GMS:-}" ]] || packages="${FAKE_PACKAGES_GMS:?}"
cp -- "$packages" sysbake/system/packages.xml
printf 'keys\n' > sysbake/misc/keystore/user_0
printf 'onboot\n' > sysbake/lepton-onboot
ln -s /data/user/0 sysbake/user_de/current
# Android leaves Unix sockets in /data/system; tar never archives them.
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' sysbake/system/ndebugsocket
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


def abx(packages, permissions=()):
    """Android binary XML (ABX) packages.xml, encoded as BinaryXmlSerializer does."""
    out, table = bytearray(b'ABX\x00'), {}

    def utf(text):
        raw = text.encode()
        out.extend(len(raw).to_bytes(2, 'big') + raw)

    def interned(text):
        if text in table:
            out.extend(table[text].to_bytes(2, 'big'))
        else:
            out.extend(b'\xff\xff')
            utf(text)
            table[text] = len(table)

    def tag(event, name):
        out.append(0x30 | event)
        interned(name)
    out.append(0x10)                       # START_DOCUMENT
    tag(2, 'packages')
    for name in permissions:               # <permissions><item name=.../></permissions>
        tag(2, 'permissions')
        tag(2, 'item')
        out.append(0x20 | 15)
        interned('name')
        utf(name)
        tag(3, 'item')
        tag(3, 'permissions')
    for user, name in enumerate(packages, 10000):
        tag(2, 'package')
        out.append(0x20 | 15)              # name: TYPE_STRING
        interned('name')
        utf(name)
        out.append(0x60 | 15)              # userId: TYPE_INT
        interned('userId')
        out.extend(user.to_bytes(4, 'big'))
        out.append(0xC0 | 15)              # isOrphaned: TYPE_BOOLEAN_TRUE
        interned('isOrphaned')
        tag(3, 'package')
    tag(3, 'packages')
    out.append(0x11)                       # END_DOCUMENT
    return bytes(out)


BASE_PACKAGES = ('android', 'com.android.settings', 'com.android.systemui')
GAPPS_PACKAGES = BASE_PACKAGES + ('com.google.android.gms', 'com.android.vending', 'com.google.android.gsf')


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
    # Runtime helpers the installer links (lepton-run-apk) and add-game uses.
    for helper in ('run-apk.sh', 'unpack-apkm.py', 'read-gsf-id.py', 'README.md'):
        base.put('tests/runtime/' + helper, (REPO / 'tests/runtime' / helper).read_bytes(),
                 0o644 if helper.endswith('.md') else 0o755)


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
        (root / 'packages-base.xml').write_bytes(abx(BASE_PACKAGES))
        (root / 'packages-gms.xml').write_bytes(abx(GAPPS_PACKAGES))
        self.host_env = dict(env, PATH=f'{hosts}:{self.fakes}', XDG_RUNTIME_DIR=str(runtime),
                             LEPTON_HOST_FILESYSTEMS=str(filesystems),
                             LEPTON_HOST_SELINUXFS=str(root / 'no-selinux'),
                             FAKE_PACKAGES_BASE=str(root / 'packages-base.xml'),
                             FAKE_PACKAGES_GMS=str(root / 'packages-gms.xml'))
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

    def compare(self, old, new, tool=None):
        """Run lepton-compare-bundles (from a stage or the repository) and return its JSON report."""
        tool = tool or REPO / 'compat_tool/tools/lepton-compare-bundles'
        result = subprocess.run([sys.executable, '-B', str(tool), str(old), str(new), '--json', '-'],
                                cwd=self.outside, capture_output=True, text=True, timeout=600)
        self.assertIn(result.returncode, (0, 1), result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(result.returncode, 0 if report['summary']['runtime_inputs_identical'] else 1)
        return report

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
        (home / '.local/share/Steam').mkdir(parents=True)  # a native Steam install
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
        none = self.root / 'no-subids'
        none.write_text('someone-else:100000:65536\n')
        env.update(LEPTON_HOST_SUBUID=str(none), LEPTON_HOST_SUBGID=str(none),
                   LEPTON_HOST_FUSE=str(self.root / 'no-fuse'), LEPTON_HOST_USERNS=str(self.root / 'userns'))
        (self.root / 'userns').write_text('0\n')
        output = self.run_tool(self.stage, 'sysbake', '--check', '--stage-dir', str(self.stage), ok=False, env=env)
        for text in ('No subordinate UID range', 'No subordinate GID range', 'usermod --add-subuids',
                     '/dev/fuse is missing', 'User namespaces are disabled', 'Missing host command: podman', 'Missing host command: weston', 'Missing host command: getfattr',
                     'Missing host command: setfattr', 'Missing host command: fuse-overlayfs', 'dnf install attr',
                     'BinderFS', 'systemd user session'):
            self.assertIn(text, output)
        self.assertEqual(tree(self.stage), before)

    def test_selinux_binder_denial_is_reported_with_the_fix(self):
        P = load('selinux_test', self.stage / 'compat_tool/tools/lepton_customize_package.py')
        fs = self.root / 'selinuxfs'
        perms = fs / 'class/binder/perms'
        perms.mkdir(parents=True)
        (fs / 'enforce').write_text('1')
        (fs / 'class/binder/index').write_text('97')
        for bit, name in enumerate(('call', 'set_context_mgr', 'transfer', 'impersonate'), 1):
            (perms / name).write_text(str(bit))
        cases = ((0b1111, True), (0b1101, False), (0, False))
        for vector, allowed in cases:
            with mock.patch.object(P, 'selinux_allowed_vector', return_value=vector):
                self.assertIs(P.selinux_binder_allowed(fs), allowed)
        (fs / 'enforce').write_text('0')
        self.assertIsNone(P.selinux_binder_allowed(fs), 'permissive SELinux is not a blocker')
        self.assertIsNone(P.selinux_binder_allowed(self.root / 'absent'), 'no SELinux is not a blocker')
        with mock.patch.object(P, 'selinux_binder_allowed', return_value=False):
            inline = P.selinux_problem(self.stage)
            self.assertIn("printf '%s\\n' 'module lepton_binder 1.2;'", inline)
            self.assertIn('sudo semodule -i /tmp/lepton_binder.pp', inline)
            policy = self.stage / P.SELINUX_POLICY
            policy.parent.mkdir(parents=True)
            shutil.copyfile(REPO / 'fedora/lepton_binder.te', policy)
            shipped = P.selinux_problem(self.stage)
            self.assertIn(f'checkmodule -M -m -o /tmp/lepton_binder.mod {policy}', shipped)
            self.assertNotIn('printf', shipped)
            self.assertIn(shipped, P.host_problems('software', self.stage))
        with mock.patch.object(P, 'selinux_binder_allowed', return_value=True):
            self.assertIsNone(P.selinux_problem(self.stage))

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
        self.assertIn('podman unshare rm -rf', output)
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
        self.assertTrue((home / '.local/bin/lepton-run-apk').resolve().is_file(), 'lepton-run-apk must resolve')
        for helper in ('run-apk.sh', 'unpack-apkm.py', 'read-gsf-id.py'):
            self.assertIn('./tests/runtime/' + helper, members)
        self.assertTrue((self.stage / 'compat_tool/sysbake/system/ndebugsocket').is_socket())
        self.assertNotIn('./compat_tool/sysbake/system/ndebugsocket', members)

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
        self.assertIn('registers GApps packages without GApps', output)
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

    def test_baked_packages_xml_is_parsed_not_searched(self):
        # A base image may declare permissions whose names merely contain a
        # GApps package name; only registered <package> entries count.
        decoy = abx(BASE_PACKAGES, permissions=('com.google.android.gms.permission.AD_ID',))
        self.assertIn(b'com.google.android.gms', decoy)
        self.assertNotIn('com.google.android.gms', L.check_registered_packages(decoy, False))
        complete = abx(GAPPS_PACKAGES)
        for broken, message in ((complete[:-1], 'Incomplete|Truncated'), (complete[:-9], 'Truncated|Incomplete'),
                                (complete[:4] + b'\x0b' + complete[5:], 'Unknown Android binary XML event'),
                                (complete + b'\x10', 'after the end'),
                                (abx(('com.android.settings',)), 'Android framework package'),
                                (abx(GAPPS_PACKAGES[:-1]), 'lacks GApps packages: com.google.android.gsf'),
                                (b'<?xml version="1.0"?><packages><package name="android"/>', 'not well-formed')):
            with self.subTest(message):
                with self.assertRaisesRegex(L.BundleError, message):
                    L.check_registered_packages(broken, True)
        self.assertEqual(L.check_registered_packages(b'<packages><package name="android"/></packages>', False), {'android'})
        self.assertEqual(L.check_registered_packages(complete, True), set(GAPPS_PACKAGES))

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


XATTRS = b"""# file: sysbake
user.default=0x01

# file: sysbake/misc
user.inode_cache=0x02

# file: sysbake/system/packages.xml
user.default="1"

# file: sysbake/system/unsolzygotesocket
user.default=0x03

"""


def complete_bundle(base):
    """A complete base bundle as published: rootfs plus its original sysbake."""
    base.put('compat_tool/sysbake', b'', 0o755, ('directory', ''))
    base.put('compat_tool/sysbake/system', b'', 0o775, ('directory', ''))
    base.put('compat_tool/sysbake/misc', b'', 0o2770, ('directory', ''))
    base.put('compat_tool/sysbake/user', b'', 0o711, ('directory', ''))
    base.put('compat_tool/sysbake/system/packages.xml', abx(BASE_PACKAGES), 0o640)
    base.put('compat_tool/sysbake/misc/state', b'android state', 0o600)
    base.put('compat_tool/sysbake/user/current', b'', 0o777, ('symlink', '/data/user/0'))
    base.put('compat_tool/sysbake.xattrs', XATTRS, 0o644)
    base.put('tools/platform-tools/adb', b'old bundled adb', 0o755)
    # Published bundles (tar -cf - .) list every directory.
    for name in list(base.nodes):
        for parent in Path(name).parents:
            if str(parent) != '.' and str(parent) not in base.nodes:
                base.put(str(parent), b'', 0o755, ('directory', ''))


def scan(archive):
    return L.ArchiveScan(archive)


class RestoreTests(Harness, unittest.TestCase):
    """Workflow B: complete bundle -> restored stage (sysbake kept) -> new bundle."""
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
        self.root, self.outside = self.base.root, self.base.outside
        self.adb_sha, self.adb_zip = fake_adb(self.root / 'fake-adb')
        extend_bundle(self.base, self.adb_sha)
        complete_bundle(self.base)
        self.base.write_bundle()
        # A bootstrap made by extracting compat_tool/tools from a verified bundle.
        for module in ('lepton_customize_inject.py', 'lepton_customize_package.py', 'lepton_bundle_lib.py'):
            shutil.copyfile(REPO / 'compat_tool/tools' / module, self.base.bootstrap / module)
        self.setup_host(self.root, self.base.env)
        self.bundles = self.root / 'bundles'
        self.restored = self.root / 'restored'

    def restore(self, mode='--execute', *extra, archive=None, ok=True):
        archive = archive or self.base.archive
        result = subprocess.run([sys.executable, '-B', str(self.base.tool), 'restore', mode, '--bundle', str(archive),
                                 '--checksum', str(archive) + '.sha256', '--stage-dir', str(self.restored), *extra],
                                cwd=self.outside, env=self.host_env, capture_output=True, text=True)
        output = result.stdout + result.stderr
        (self.assertEqual if ok else self.assertNotEqual)(result.returncode, 0, output)
        return output

    def test_restore_check_writes_nothing(self):
        before = sorted(str(p) for p in self.root.rglob('*'))
        self.assertIn('restore preflight', self.restore('--check'))
        self.assertEqual(before, sorted(str(p) for p in self.root.rglob('*')))

    def test_restore_retains_rootfs_sysbake_and_xattrs(self):
        original = self.base.archive.read_bytes()
        output = self.restore()
        self.assertIn('unsolzygotesocket', output)
        self.assertEqual(self.base.archive.read_bytes(), original)
        state = self.state(self.restored)
        self.assertEqual((state['state'], state['sysbake_required'], state['sysbake']['origin']),
                         ('restored-complete', False, 'source-bundle'))
        self.assertEqual(state['components'], dict(gapps=False, ndk=False, widevine=False))
        for name, (data, mode, link) in self.base.nodes.items():
            if name.startswith(('compat_tool/sysbake', M.ROOTFS)):
                path = self.restored / name
                if link and link[0] == 'symlink':
                    self.assertEqual(os.readlink(path), link[1])
                elif link:
                    self.assertTrue(path.is_dir())
                    self.assertEqual(path.stat().st_mode & 0o7777, mode, name)
                elif not path.is_symlink():
                    self.assertEqual((path.read_bytes(), path.stat().st_mode & 0o7777), (data, mode), name)
        self.assertEqual((self.restored / 'compat_tool/sysbake.xattrs').read_bytes(), XATTRS)
        self.assertEqual(json.loads((self.restored / 'source-bundle/SOURCE.json').read_text())['sha256'], sha(original))
        for name in ('BUNDLE.json', 'tools/platform-tools', 'compat_tool/install-profile', '.runtime-profile.google',
                     'compatdata', 'tools/.ssh'):
            self.assertFalse((self.restored / name).exists(), name)
        self.assertIn('already exists', self.restore('--check', ok=False))

    def test_repackaging_unchanged_stage_preserves_android_and_sysbake(self):
        self.restore()
        self.assertIn('keeps its original validated sysbake', self.sysbake(self.restored, ok=False))
        self.package(self.restored, 'repacked')
        repacked = self.bundles / 'lepton-x86_64-repacked.tar.gz'
        # The bundled comparison tool proves preservation, including the xattr record.
        report = self.compare(self.base.archive, repacked, self.restored / 'compat_tool/tools/lepton-compare-bundles')
        summary = report['summary']
        self.assertTrue(summary['android_rootfs_identical'] and summary['sysbake_identical'] and
                        summary['sysbake_xattrs_identical'] and summary['fingerprint_inputs_identical'])
        self.assertTrue(summary['differences_confined_to_launcher_tooling_metadata'])
        self.assertIn('tools/platform-tools/adb', report['other_files']['removed'])
        # Only ADB and private/local state may disappear in a repack.
        allowed = re.compile(r'^(tools/platform-tools|\.runtime-profile|compat_tool/\.runtime-profile|compatdata|'
                             r'compat_tool/install-profile|tools/\.ssh)')
        unexpected = [n for n in report['other_files']['removed'] if not allowed.match(n)]
        self.assertEqual(unexpected, [], 'repackaging dropped distributable files')
        before, after = scan(self.base.archive), scan(repacked)
        self.assertEqual(before.rootfs, after.rootfs)
        self.assertEqual(before.sysbake, after.sysbake)
        self.assertEqual(before.files[L.XATTRS], after.files[L.XATTRS])
        self.assertEqual(before.fingerprint(), after.fingerprint())
        old, new = before.metadata(), after.metadata()
        self.assertNotEqual(old['bundle_id'], new['bundle_id'])
        self.assertEqual({k: old[k] for k in ('gapps', 'ndk')}, {k: new[k] for k in ('gapps', 'ndk')})
        self.assertIn('retained unchanged from the source bundle',
                      self.read_member(self.bundles / 'lepton-x86_64-repacked.tar.gz', 'tools/BUNDLE-PROVENANCE.txt').decode())
        # A second, differently named repack has the same runtime fingerprint.
        self.package(self.restored, 'repacked-again')
        self.assertEqual(scan(self.bundles / 'lepton-x86_64-repacked-again.tar.gz').fingerprint(), after.fingerprint())
        # The new bundle restores again (its own installer, checksum and layout).
        shutil.rmtree(self.restored, onerror=lambda f, p, e: (os.chmod(p, 0o700), f(p)))
        self.restore(archive=self.bundles / 'lepton-x86_64-repacked.tar.gz')
        self.assertEqual(self.state(self.restored)['source_bundle_id'], 'repacked')

    def test_restored_stage_refuses_android_changes(self):
        self.restore()
        inputs = self.root / 'inputs'
        inputs.mkdir()
        output = self.run_tool(self.restored, 'inject', '--check', '--stage-dir', str(self.restored), '--output-stage',
                               str(self.root / 'out'), '--google-inputs', str(inputs), '--with-gapps', ok=False)
        self.assertIn('restored complete stage', output)
        self.assertIn('fresh prepared stage', output)
        target = self.restored / M.ROOTFS / 'system/etc/unchanged.conf'
        target.write_bytes(b'edited Android with old sysbake')
        self.assertIn('differs from the one this sysbake belongs to', self.package(self.restored, mode='--check', ok=False))

    def test_restore_rejects_incomplete_or_inconsistent_bundles(self):
        cases = {
            'sysbake missing': lambda b: b.nodes.pop('compat_tool/sysbake/system/packages.xml'),
            'gapps flag without GApps': lambda b: b.put('BUNDLE.json', json.dumps(dict(b.metadata, gapps=True)).encode(), 0o644),
            'widevine flag without Widevine': lambda b: b.put('BUNDLE.json', json.dumps(dict(b.metadata, widevine=True)).encode(), 0o644),
            'selinux xattr': lambda b: b.put('compat_tool/sysbake.xattrs', XATTRS + b'# file: sysbake/misc\nsecurity.selinux="x"\n', 0o644),
            'escaping xattr path': lambda b: b.put('compat_tool/sysbake.xattrs', b'# file: sysbake/../etc\nuser.a=1\n', 0o644),
            'xattr path without parent': lambda b: b.put('compat_tool/sysbake.xattrs', b'# file: sysbake/gone/x\nuser.a=1\n', 0o644),
            'user data in rootfs': lambda b: b.put(M.ROOTFS + 'data/app/x.apk', b'x', 0o644),
        }
        for label, change in cases.items():
            with self.subTest(label):
                saved = dict(self.base.nodes)
                change(self.base)
                self.base.write_bundle()
                self.restore('--check', ok=False)
                self.assertFalse(self.restored.exists())
                self.base.nodes = saved
        self.base.write_bundle()
        self.restore('--check')

    def test_legacy_metadata_without_widevine_field_records_installed_widevine(self):
        apex = M.ROOTFS + 'vendor/apex/com.google.android.widevine/'
        for name in L.WIDEVINE_FILES:
            self.base.put(apex + name, b'com.google.android.widevine' if name == 'apex_manifest.pb' else b'x', 0o644)
        self.base.write_bundle()
        self.assertNotIn('widevine', self.base.metadata)
        self.assertIn('recorded as widevine=true', self.restore())
        self.assertTrue(self.state(self.restored)['components']['widevine'])
        self.package(self.restored, 'legacy-repack')
        metadata = json.loads(self.read_member(self.bundles / 'lepton-x86_64-legacy-repack.tar.gz', 'BUNDLE.json'))
        self.assertIs(metadata['widevine'], True)
        # An explicit false that contradicts the rootfs is still refused.
        shutil.rmtree(self.restored, onerror=lambda f, p, e: (os.chmod(p, 0o700), f(p)))
        self.base.put('BUNDLE.json', json.dumps(dict(self.base.metadata, widevine=False)).encode(), 0o644)
        self.base.write_bundle()
        self.assertIn('widevine=false does not match', self.restore('--check', ok=False))

    def test_failed_restore_publishes_nothing_and_keeps_input(self):
        P = load('restore_test', REPO / 'compat_tool/tools/lepton_customize_package.py')
        original = self.base.archive.read_bytes()
        args = mock.Mock(stage_dir=str(self.restored), bundle=str(self.base.archive), checksum=str(self.base.checksum),
                         signature=None, trusted_signers=None, allow_unsigned=False, check=False, execute=True)

        def interrupted(*_):
            raise M.InvalidBundle('Interrupted by signal 15')
        with mock.patch.dict(os.environ, self.host_env, clear=True), mock.patch.object(M, 'publish', interrupted):
            with self.assertRaises(M.InvalidBundle):
                P.restore_main(args, M)
        self.assertFalse(self.restored.exists())
        self.assertFalse(list(self.root.glob('.lepton-customize-*')))
        self.assertEqual(self.base.archive.read_bytes(), original)

    def test_stage2_still_refuses_complete_customised_or_prepares_base(self):
        # The original Stage 2 workflow discards sysbake from the same archive.
        self.base.cli()
        self.assertFalse((self.base.stage / 'compat_tool/sysbake').exists())
        self.assertEqual(self.state(self.base.stage)['state'], 'prepared')


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
        self.assertIn('lacks GApps packages', self.sysbake(self.output, ok=False))
        self.assertEqual(self.state(self.output)['state'], 'customized')
        self.sysbake(self.output, env=dict(self.host_env, FAKE_SYSBAKE_GMS='1'))
        state = self.state(self.output)
        self.assertEqual((state['state'], state['baked_from']), ('baked', 'customized'))
        self.package(self.output, 'gapps-local')
        archive = self.bundles / 'lepton-x86_64-gapps-local.tar.gz'
        metadata = json.loads(self.read_member(archive, 'BUNDLE.json'))
        self.assertEqual((metadata['gapps'], metadata['ndk'], metadata['widevine']), (True, False, True))
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
        env = (home / '.config/lepton-x86_64/lepton_custom_gapps_local.env').read_text()
        self.assertIn('LEPTON_X86_GAPPS=true', env)
        self.assertIn('LEPTON_X86_WIDEVINE=true', env)

    def test_widevine_only_is_detected_independently(self):
        self.customize(('widevine',))
        self.sysbake(self.output)
        self.package(self.output, 'drm-only')
        archive = self.bundles / 'lepton-x86_64-drm-only.tar.gz'
        metadata = json.loads(self.read_member(archive, 'BUNDLE.json'))
        self.assertEqual((metadata['gapps'], metadata['ndk'], metadata['widevine']), (False, False, True))
        self.assertEqual(metadata['tool_id'], 'lepton_custom_drm_only')
        restored = self.root / 'restored'
        self.run_tool(self.output, 'restore', '--execute', '--bundle', str(archive), '--checksum',
                      str(archive) + '.sha256', '--stage-dir', str(restored))
        self.assertEqual(self.state(restored)['components'], dict(gapps=False, ndk=False, widevine=True))
        report = self.compare(self.base.archive, archive)
        self.assertEqual(report['metadata']['components']['widevine'], dict(old=False, old_legacy=True, new=True))

    def test_widevine_presence_comes_from_the_rootfs_layout(self):
        self.customize(('widevine',))
        self.sysbake(self.output)
        apex = self.output / M.ROOTFS / 'vendor/apex/com.google.android.widevine'
        library = apex / 'lib64/libcrypto.so'
        library.unlink()
        self.assertIn('Incomplete Widevine APEX', self.package(self.output, mode='--check', ok=False))
        # A recorded flag never substitutes for the installed files.
        shutil.rmtree(apex)
        self.assertIn('does not match the stage record', self.package(self.output, mode='--check', ok=False))

    def test_ndk_provenance_survives_packaging_restore_and_repackaging(self):
        self.customize(('ndk',))
        self.sysbake(self.output)
        self.package(self.output, 'ndk-local')
        archive = self.bundles / 'lepton-x86_64-ndk-local.tar.gz'
        self.assertTrue(json.loads(self.read_member(archive, 'BUNDLE.json'))['ndk'])
        self.assertIn('./compat_tool/ndk-provenance/SHA256SUMS', self.members(archive))
        restored = self.root / 'restored'
        self.run_tool(self.output, 'restore', '--execute', '--bundle', str(archive), '--checksum',
                      str(archive) + '.sha256', '--stage-dir', str(restored))
        self.assertTrue((restored / 'compat_tool/ndk-provenance/SHA256SUMS').is_file())
        self.package(restored, 'ndk-local-2')
        report = self.compare(archive, self.bundles / 'lepton-x86_64-ndk-local-2.tar.gz')
        self.assertTrue(report['summary']['differences_confined_to_launcher_tooling_metadata'])
        self.assertFalse([n for n in report['other_files']['removed'] if 'provenance' in n])

    def test_injected_component_tampering_blocks_packaging(self):
        self.customize(('gapps',))
        self.sysbake(self.output, env=dict(self.host_env, FAKE_SYSBAKE_GMS='1'))
        apk = self.output / M.ROOTFS / 'system/product/priv-app/Phonesky/Phonesky.apk'
        apk.write_bytes(b'tampered')
        self.assertRegex(self.package(self.output, mode='--check', ok=False), 'provenance|differs')

    def test_restore_customised_bundle_keeps_flags_and_repackages(self):
        self.customize(('gapps',))
        self.sysbake(self.output, env=dict(self.host_env, FAKE_SYSBAKE_GMS='1'))
        self.package(self.output, 'gapps-local')
        archive = self.bundles / 'lepton-x86_64-gapps-local.tar.gz'
        restored = self.root / 'restored'
        # Installed release keys make unsigned local bundles an explicit choice.
        (self.output / 'compat_tool/release-keys/allowed_signers').write_text(
            'lepton-release namespaces="lepton-release" ' + Path(str(self.base.keys) + '.pub').read_text())
        refused = self.run_tool(self.output, 'restore', '--check', '--bundle', str(archive), '--checksum',
                                str(archive) + '.sha256', '--stage-dir', str(restored), ok=False)
        self.assertIn('--allow-unsigned', refused)
        self.run_tool(self.output, 'restore', '--execute', '--allow-unsigned', '--bundle', str(archive), '--checksum',
                      str(archive) + '.sha256', '--stage-dir', str(restored))
        state = self.state(restored)
        self.assertEqual(state['components'], dict(gapps=True, ndk=False, widevine=False))
        self.assertTrue(json.loads((restored / 'source-bundle/SOURCE.json').read_text())['unsigned_override'])
        self.package(restored, 'gapps-local-2')
        again = self.bundles / 'lepton-x86_64-gapps-local-2.tar.gz'
        self.assertTrue(json.loads(self.read_member(again, 'BUNDLE.json'))['gapps'])
        report = self.compare(archive, again)
        self.assertTrue(report['summary']['differences_confined_to_launcher_tooling_metadata'])
        self.assertEqual(report['metadata']['components']['gapps'], dict(old=True, new=True))
        # Against the base bundle, Workflow A changed Android and its sysbake.
        base = self.compare(self.base.archive, archive)
        self.assertFalse(base['summary']['android_rootfs_identical'])
        self.assertIn('system/product/priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk', base['android_rootfs']['added'])
        self.assertFalse(base['sysbake']['present']['old'] and base['sysbake']['identical'])
        names = self.members(again)
        self.assertIn('./compat_tool/provenance/sources/v0.2.0-alpha/SOURCE.json', names)
        self.assertIn('./compat_tool/provenance/sources/gapps-local/SOURCE.json', names)

    def test_component_record_must_match_rootfs(self):
        self.customize(('gapps',))
        self.sysbake(self.output, env=dict(self.host_env, FAKE_SYSBAKE_GMS='1'))
        state = self.state(self.output)
        state['components']['gapps'] = False
        (self.output / 'STAGE.json').write_text(json.dumps(state))
        self.assertIn('does not match the stage record', self.package(self.output, mode='--check', ok=False))



@unittest.skipUnless(os.environ.get('LEPTON_TEST_COMPLETE_BUNDLE'), 'set LEPTON_TEST_COMPLETE_BUNDLE to a real bundle')
class LocalBundleIntegration(Harness, unittest.TestCase):
    """Workflow B with a real complete bundle (optional; read-only on the input).

    LEPTON_TEST_COMPLETE_BUNDLE=/path/lepton-x86_64-ID.tar.gz (its .sha256 alongside)
    LEPTON_TEST_ALLOW_UNSIGNED=1 for your own unsigned build. Needs ~3x the
    archive size free in TMPDIR.
    """
    def test_restore_repackage_compare(self):
        archive = Path(os.environ['LEPTON_TEST_COMPLETE_BUNDLE']).resolve()
        work = Path(tempfile.mkdtemp(prefix='lepton-workflow-b-'))
        def remove():
            subprocess.run(['chmod', '-R', 'u+rwX', str(work)], check=False)
            shutil.rmtree(work)
        self.addCleanup(remove)
        self.outside, self.bundles = work, work / 'bundles'
        tool = REPO / 'compat_tool/tools/lepton-customize'
        extra = ['--allow-unsigned'] if os.environ.get('LEPTON_TEST_ALLOW_UNSIGNED') == '1' else []
        subprocess.run([sys.executable, '-B', str(tool), 'restore', '--execute', *extra, '--bundle', str(archive),
                        '--checksum', str(archive) + '.sha256', '--stage-dir', str(work / 'stage')], check=True)
        subprocess.run([sys.executable, '-B', str(tool), 'package', '--execute', '--stage-dir', str(work / 'stage'),
                        '--output-dir', str(self.bundles), '--bundle-id', 'workflow-b-test'], check=True)
        report = self.compare(archive, self.bundles / 'lepton-x86_64-workflow-b-test.tar.gz')
        self.assertTrue(report['summary']['runtime_inputs_identical'], json.dumps(report['summary'], indent=2))


@unittest.skipUnless(os.environ.get('LEPTON_TEST_BASE_BUNDLE'), 'set LEPTON_TEST_BASE_BUNDLE for a real Fedora Workflow A run')
class LocalSysbakeIntegration(Harness, unittest.TestCase):
    """Workflow A on a real Fedora host: real Podman, Weston, BinderFS and Android boot.

    LEPTON_TEST_BASE_BUNDLE=/path/lepton-x86_64-ID.tar.gz (.sha256 and .sig alongside)
    LEPTON_TEST_GOOGLE_INPUTS=/path/prepared-google-inputs   (optional)
    LEPTON_TEST_COMPONENTS="ndk gapps widevine"               (default: all three with inputs)
    LEPTON_TEST_ALLOW_UNSIGNED=1                               (your own unsigned build)
    """
    def test_customise_sysbake_package_compare(self):
        base = Path(os.environ['LEPTON_TEST_BASE_BUNDLE']).resolve()
        inputs = os.environ.get('LEPTON_TEST_GOOGLE_INPUTS')
        components = os.environ.get('LEPTON_TEST_COMPONENTS', 'ndk gapps widevine' if inputs else '').split()
        work = Path(tempfile.mkdtemp(prefix='lepton-workflow-a-', dir=os.environ.get('LEPTON_TEST_WORK_DIR')))
        tool = REPO / 'compat_tool/tools/lepton-customize'
        extra = ['--allow-unsigned'] if os.environ.get('LEPTON_TEST_ALLOW_UNSIGNED') == '1' else []
        run = lambda *args: subprocess.run([sys.executable, '-B', str(tool), *map(str, args)], check=True)
        run('--execute', *extra, '--bundle', base, '--checksum', str(base) + '.sha256', '--stage-dir', work / 'prepared')
        stage = work / 'prepared'
        if components:
            run('inject', '--execute', '--stage-dir', stage, '--output-stage', work / 'custom',
                '--google-inputs', inputs, *('--with-' + c for c in components))
            stage = work / 'custom'
        run('sysbake', '--check', '--stage-dir', stage)
        run('sysbake', '--execute', '--stage-dir', stage)
        run('package', '--execute', '--stage-dir', stage, '--output-dir', work / 'bundles', '--bundle-id', 'workflow-a-test')
        archive = work / 'bundles/lepton-x86_64-workflow-a-test.tar.gz'
        self.outside = work
        report = self.compare(base, archive)
        self.assertFalse(report['sysbake']['identical'], 'a fresh sysbake was expected')
        for name in ('gapps', 'ndk', 'widevine'):
            self.assertEqual(report['metadata']['components'][name]['new'], name in components)
        home = work / 'home'
        home.mkdir()
        result = subprocess.run(['bash', str(work / 'bundles/lepton-x86_64-workflow-a-test.install.sh'), '--check',
                                 '--allow-non-amd'], env=dict(os.environ, HOME=str(home), LEPTON_INSTALL_IN_TERMINAL='1',
                                                              LEPTON_NO_DIALOGS='1'), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        print(f'Workflow A outputs kept in {work} (remove with: podman unshare rm -rf {work})')


# Do not rerun the inherited injection tests in this suite.
for _name in [n for n in dir(INJECT.InjectionTests) if n.startswith('test_')]:
    if _name not in CustomizedWorkflowTests.__dict__:
        setattr(CustomizedWorkflowTests, _name, None)


if __name__ == '__main__':
    unittest.main()
