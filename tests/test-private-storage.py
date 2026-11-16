#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Private rootless-Podman storage must not inherit workspace POSIX ACLs.

The ACL fixtures are written as raw system.posix_acl_* xattrs, so neither the
helper nor these tests need getfacl/setfacl. The optional Podman test runs only
with LEPTON_TEST_PODMAN_IMAGE set to an image already in the user's store
(for example docker.io/library/debian:12-slim); it copies that image into a
disposable private store and never pulls, prunes or resets anything.
"""
import errno
import importlib.util
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'image-14/scripts/internal/private_storage.py'
SYSBAKE = ROOT / 'image-14/scripts/internal/sysbake-isolated-x86_64.sh'
spec = importlib.util.spec_from_file_location('private_storage', HELPER)
private_storage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(private_storage)

OTHER_UID = os.getuid() + 4242  # any UID that a rootless namespace leaves unmapped
UNDEFINED = 0xFFFFFFFF


def acl_xattr(named_uid):
    """posix_acl_xattr v2: u::rwx, u:named:r-x, g::---, m::r-x, o::---."""
    entries = [(0x01, 7, UNDEFINED), (0x02, 5, named_uid), (0x04, 0, UNDEFINED),
               (0x10, 5, UNDEFINED), (0x20, 0, UNDEFINED)]
    return struct.pack('<I', 2) + b''.join(struct.pack('<HHI', *entry) for entry in entries)


def acls(path):
    found = {}
    for name in private_storage.ACL_XATTRS:
        try:
            found[name] = os.getxattr(path, name, follow_symlinks=False)
        except OSError as exc:
            if exc.errno not in (errno.ENODATA, errno.ENOTSUP, errno.EOPNOTSUPP):
                raise
    return found


def give_acls(path, default=True):
    os.setxattr(path, 'system.posix_acl_access', acl_xattr(OTHER_UID))
    if default:
        os.setxattr(path, 'system.posix_acl_default', acl_xattr(OTHER_UID))


def snapshot(path):
    info = os.stat(path)
    return stat.S_IMODE(info.st_mode), acls(path)


class Base(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.parent = self.root / 'workspace'
        self.parent.mkdir(mode=0o750)
        os.chmod(self.parent, 0o750)

    def acl_parent(self):
        try:
            give_acls(self.parent)
        except OSError as exc:
            if exc.errno in (errno.ENOTSUP, errno.EOPNOTSUPP):
                self.skipTest(f'{self.root} has no POSIX ACL support')
            raise
        return snapshot(self.parent)

    def assert_private(self, path):
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o700)
        self.assertEqual(acls(path), {})


class MakePrivateTests(Base):
    def test_strips_inherited_acls_before_storage_is_created(self):
        before = self.acl_parent()
        work = Path(tempfile.mkdtemp(prefix='.sysbake-work.', dir=self.parent))
        self.assertEqual(set(acls(work)), set(private_storage.ACL_XATTRS), 'fixture did not inherit ACLs')
        private_storage.make_private(work)
        self.assert_private(work)
        graph = work / 'podman-storage' / 'overlay'
        graph.mkdir(parents=True)
        self.assertEqual(acls(graph), {})
        self.assertEqual(acls(graph.parent), {})
        self.assertEqual(snapshot(self.parent), before, 'parent ACLs or mode changed')

    def test_clears_inherited_setgid(self):
        try:
            os.chmod(self.parent, 0o2750)
        except PermissionError:
            self.skipTest('cannot set setgid on test directory')
        work = Path(tempfile.mkdtemp(dir=self.parent))
        if not os.stat(work).st_mode & stat.S_ISGID:
            self.skipTest('filesystem does not propagate setgid')
        private_storage.make_private(work)
        self.assert_private(work)
        self.assertEqual(stat.S_IMODE(os.stat(self.parent).st_mode), 0o2750)

    def test_parent_without_acls(self):
        before = snapshot(self.parent)
        work = Path(tempfile.mkdtemp(dir=self.parent))
        private_storage.make_private(work)
        self.assert_private(work)
        self.assertEqual(snapshot(self.parent), before)

    def test_refuses_non_empty_directories_and_symlinks(self):
        self.acl_parent()
        before = snapshot(self.parent)
        (self.parent / 'source.txt').write_text('user data')
        with self.assertRaises(private_storage.PrivateDirError):
            private_storage.make_private(self.parent)
        link = self.root / 'link'
        link.symlink_to(self.parent)
        with self.assertRaises(private_storage.PrivateDirError):
            private_storage.make_private(link)
        self.assertEqual(snapshot(self.parent), before)

    def test_filesystem_without_acl_support(self):
        work = Path(tempfile.mkdtemp(dir=self.parent))
        unsupported = OSError(errno.EOPNOTSUPP, 'Operation not supported')
        with mock.patch.object(private_storage.os, 'getxattr', side_effect=unsupported), \
                mock.patch.object(private_storage.os, 'removexattr') as remove:
            private_storage.make_private(work)
        remove.assert_not_called()
        self.assertEqual(stat.S_IMODE(os.stat(work).st_mode), 0o700)

    def test_fails_clearly_when_acls_cannot_be_removed(self):
        self.acl_parent()
        work = Path(tempfile.mkdtemp(dir=self.parent))
        denied = OSError(errno.EPERM, 'Operation not permitted')
        with mock.patch.object(private_storage.os, 'removexattr', side_effect=denied):
            with self.assertRaisesRegex(private_storage.PrivateDirError, 'Cannot remove inherited system.posix_acl'):
                private_storage.make_private(work)

    def test_fails_when_acls_survive_removal(self):
        self.acl_parent()
        work = Path(tempfile.mkdtemp(dir=self.parent))
        with mock.patch.object(private_storage.os, 'removexattr'):
            with self.assertRaisesRegex(private_storage.PrivateDirError, 'not private after cleanup'):
                private_storage.make_private(work)


class CommandLineTests(Base):
    def run_helper(self, *args, path=None):
        env = {**os.environ, 'PATH': str(path)} if path else None
        return subprocess.run([sys.executable, '-I', '-B', str(HELPER), *args],
                              capture_output=True, text=True, env=env)

    def test_works_without_acl_utilities(self):
        before = self.acl_parent()
        empty_path = self.root / 'no-tools'
        empty_path.mkdir()  # no getfacl, setfacl or chmod on PATH
        work = Path(tempfile.mkdtemp(dir=self.parent))
        run = Path(tempfile.mkdtemp(dir=self.parent))
        result = self.run_helper('private', str(work), str(run), path=empty_path)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_private(work)
        self.assert_private(run)
        self.assertEqual(snapshot(self.parent), before)

    def test_reports_refusal(self):
        (self.parent / 'data').write_text('x')
        result = self.run_helper('private', str(self.parent))
        self.assertEqual(result.returncode, 1)
        self.assertIn('[FAIL] Refusing to modify', result.stderr)

    def test_scan_acls_is_read_only(self):
        rootfs = self.parent / 'rootfs'
        (rootfs / 'system/etc').mkdir(parents=True)
        (rootfs / 'system/etc/hosts').write_text('127.0.0.1 localhost\n')
        outside = self.root / 'outside'
        outside.mkdir()
        self.acl_parent()  # the fixture skips here if ACLs are unsupported
        give_acls(outside)  # a symlink target: must not be followed
        (rootfs / 'escape').symlink_to(outside)
        result = self.run_helper('scan-acls', str(rootfs))
        self.assertEqual((result.returncode, result.stdout), (0, ''), result.stderr)
        give_acls(rootfs / 'system/etc/hosts', default=False)
        before = snapshot(rootfs / 'system/etc/hosts')
        result = self.run_helper('scan-acls', str(rootfs))
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stdout.split(), [str(rootfs / 'system/etc/hosts')])
        self.assertEqual(snapshot(rootfs / 'system/etc/hosts'), before)


class SysbakeOrderingTests(unittest.TestCase):
    def test_storage_is_private_before_anything_is_created_in_it(self):
        text = SYSBAKE.read_text()
        lines = text.splitlines()
        def first(pattern):
            return next(i for i, line in enumerate(lines) if re.search(pattern, line))
        work = first(r'^WORK="\$\(mktemp -d "\$STAGE/')
        runroot = first(r'^RUNROOT="\$\(mktemp -d')
        private = first(r'PRIVATE_STORAGE" private "\$WORK" "\$RUNROOT"')
        trap = first(r'^trap cleanup EXIT')
        creates = [i for i, line in enumerate(lines) if re.search(r'"\$(WORK|RUNROOT|GRAPHROOT)[/"]', line)
                   and re.search(r'\b(mkdir|touch|rsync|cp|ln|>)\b|> "\$WORK', line) and i > work]
        self.assertLess(max(work, runroot, trap), private)
        self.assertGreater(min(creates), private, 'storage created before ACLs were removed')
        # setfacl may be suggested to the user, never run (it may be missing).
        self.assertEqual([line for line in lines if re.match(r'\s*(setfacl|getfacl)\b', line)], [])
        self.assertTrue(any('scan-acls "$ROOTFS"' in line for line in lines))


@unittest.skipUnless(os.environ.get('LEPTON_TEST_PODMAN_IMAGE'), 'set LEPTON_TEST_PODMAN_IMAGE to run rootless Podman')
class RootlessPodmanTests(Base):
    """Small containers only; no Android image is built or booted."""

    def setUp(self):
        super().setUp()
        for tool in ('podman', 'fuse-overlayfs'):
            if not shutil.which(tool):
                self.skipTest(f'{tool} not installed')
        if os.getuid() == 0:
            self.skipTest('rootless test')
        self.image = os.environ['LEPTON_TEST_PODMAN_IMAGE']
        runtime = os.environ.get('XDG_RUNTIME_DIR') or f'/run/user/{os.getuid()}'
        self.acl_parent()
        self.work = Path(tempfile.mkdtemp(prefix='.sysbake-work.', dir=self.parent))
        self.runroot = Path(tempfile.mkdtemp(prefix='lepton-acl-test-run.', dir=runtime))
        private_storage.make_private(self.work)
        private_storage.make_private(self.runroot)
        self.graph = self.work / 'podman-storage'
        self.graph.mkdir()
        self.podman = ['podman', '--remote=false', f'--root={self.graph}', f'--runroot={self.runroot}',
                       '--storage-driver=overlay',
                       f'--storage-opt=overlay.mount_program={shutil.which("fuse-overlayfs")}']
        self.addCleanup(self.remove_store)
        archive = self.work / 'image.tar'
        subprocess.run(['podman', 'save', '-q', '-o', str(archive), self.image], check=True)
        subprocess.run(self.podman + ['load', '-q', '-i', str(archive)], check=True, capture_output=True)
        archive.unlink()

    def remove_store(self):
        # Only this test's private store: files owned by sub-UIDs need unshare.
        subprocess.run(self.podman + ['unshare', 'rm', '-rf', '--', str(self.graph)], capture_output=True)
        shutil.rmtree(self.work, ignore_errors=True)
        shutil.rmtree(self.runroot, ignore_errors=True)

    def container(self, *args):
        return subprocess.run(self.podman + ['run', '--rm', *args], capture_output=True, text=True, timeout=180)

    def test_containers_start_in_private_storage_below_acl_workspace(self):
        self.assertEqual(acls(self.graph), {})
        result = self.container(self.image, 'sh', '-c',
                                'test -L /etc/mtab && touch /tmp/a && cp -p /tmp/a /tmp/b && stat -c %a /tmp/b')
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.container('--userns=keep-id', self.image, '/bin/bash', '-c', 'id -u')
        self.assertEqual((result.returncode, result.stdout.strip()), (0, str(os.getuid())), result.stderr)
        result = self.container('--userns=keep-id:uid=0,gid=0', '--user', '0:0', self.image, '/bin/bash', '-c', 'id -u')
        self.assertEqual((result.returncode, result.stdout.strip()), (0, '0'), result.stderr)


if __name__ == '__main__':
    unittest.main()
