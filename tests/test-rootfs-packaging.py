#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Packaging recovery and FUSE failure tests using tiny images and host mocks."""
import fcntl
import hashlib
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def write(path, data, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(data)
    if executable:
        path.chmod(0o755)


def sparse(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(struct.pack('<I4H4I', 0xED26FF3A, 1, 0, 28, 12, 4096, 1, 1, 0)
                     + struct.pack('<2H2I', 0xCAC3, 0, 1, 12))


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.repo = self.work / 'repo'
        self.workspace = self.work / 'workspace'
        self.aosp = self.workspace / 'aosp'
        self.state = self.aosp / '.lepton-clean14-state'
        self.product = self.aosp / 'out/target/product/lepton_x86_64'
        self.images = self.workspace / 'images'
        self.rootfs = self.workspace / 'rootfs'
        self.bin = self.work / 'bin'
        self.bin.mkdir()
        (self.work / "tmp").mkdir()
        scripts = ('build-images-x86_64.sh', 'preflight-x86_64.sh', 'lib/workspace.sh',
                   'lib/packaging-fuse.sh', 'lib/package-images.sh', 'lib/image-provenance.sh',
                   'internal/check-active-compilation.py', 'internal/validate-android-images.py',
                   'internal/package-repro-rootfs.sh', 'internal/patch-binderfs-init.sh')
        for name in scripts:
            dest = self.repo / 'image-14/scripts' / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / 'image-14/scripts' / name, dest)
        write(self.repo / '.build-env', f'LEPTON_OUTPUT_DIR="{self.workspace}"\n'
              'LEPTON_BUILD_TARGET=aosp_lepton_x86_64-ap2a-userdebug\n'
              'LEPTON_BUILD_JOBS=1\nLEPTON_MIN_FREE_GIB=0\n'
              'LEPTON_BUILD_CONTAINER=lepton-builder-ubuntu26:latest\n')
        for marker in ('sync.done', 'vendor.done', 'patches.done'):
            write(self.state / marker, '')
        write(self.aosp / '.lepton-clean14-owner', 'owned')
        write(self.aosp / '.lepton-resolved-manifest.xml', 'manifest')
        write(self.aosp / '.repo/manifest.xml', 'manifest')
        write(self.aosp / 'build/envsetup.sh', 'DO NOT SOURCE\n')
        (self.aosp / 'device/waydroid/waydroid').mkdir(parents=True)
        (self.aosp / 'vendor/extra').mkdir(parents=True)
        for part in ('system', 'vendor'):
            sparse(self.product / f'{part}.img')
        self.env = {**os.environ, 'PATH': f'{self.bin}:/usr/bin:/bin',
                    'LEPTON_FUSE_DEVICE': '/dev/null', 'FIXTURE': str(self.work),
                    'TRACE': str(self.work / 'trace'), 'TMPDIR': str(self.work / 'tmp')}
        for key in ('PACKAGE_FAIL', 'PACKAGE_SIGNAL', 'COMPILE_FAIL', 'FUSE_FAIL', 'UNMOUNT_FAIL', 'RSYNC_SIGNAL'):
            self.env.pop(key, None)
        self.stub('podman', '''if [[ "$1" == image ]]; then exit 0; fi
if [[ "$1" == run ]]; then
    cat >/dev/null
    echo compile >> "$TRACE"
    exit "${COMPILE_FAIL:-0}"
fi
exit 99''')
        self.stub('git', '''case " $* " in
*' rev-parse '*) printf '%040d\\n' 0 ;;
*' submodule status '*) echo ' abc fixture' ;;
esac
exit 0''')
        self.stub('fuse2fs', '''[[ "${FUSE_FAIL:-0}" != 1 ]] || exit 9
mount="${!#}"
touch "$mount/.fixture-mounted"
echo payload > "$mount/payload.txt"''')
        for tool in ('fusermount', 'fusermount3'):
            self.stub(tool, '''[[ "${UNMOUNT_FAIL:-0}" != 1 ]] || exit 7
rm -f -- "${!#}/.fixture-mounted"''')
        self.stub('mountpoint', '[[ -f "${!#}/.fixture-mounted" ]]')
        self.stub('mkfs.ext4', 'exit 0')
        self.stub('ldd', 'exit 1')
        self.stub('simg2img', 'cp -- "$1" "$2"')
        self.stub('sqfs2tar', '''if [[ "$1" == -r ]]; then tar -cf - -C "$FIXTURE/vendor-tree" vendor; else tar -cf - -C "$FIXTURE/system-tree" system; fi''')
        self.stub('unzip', '''mkdir -p "${!#}"
echo payload > "${!#}/apex_payload.img"''')
        self.stub('rsync', '''if [[ "${RSYNC_SIGNAL:-0}" == 1 ]]; then kill -TERM "$PPID"; exit 143; fi
args=("$@")
cp -a -- "${args[-2]}/." "${args[-1]}"''')
        write(self.work / 'system-tree/system/build.prop', 'ro.build.version.sdk=34\n')
        write(self.work / 'system-tree/system/etc/init/hw/init.rc', '    mount binder binder /dev/binderfs stats=global\n')
        write(self.work / 'system-tree/system/apex/com.fixture.apex', 'apex')
        write(self.work / 'vendor-tree/vendor/lib64/hw/vulkan.radeon.so', 'radv')
        self.real_packager = self.repo / 'image-14/scripts/internal/package-repro-rootfs.sh'
        # The workflow tests isolate the build/transaction; APEX tests below use
        # the real packager, extraction, BinderFS patch and cleanup separately.
        self.packager_source = self.real_packager.read_text()
        self.stub_packager()
        write(self.images / 'old', 'previous images')
        write(self.rootfs / 'old', 'previous valid rootfs')
        write(self.rootfs / 'system/build.prop', 'previous build')
        write(self.rootfs / 'vendor/lib64/hw/vulkan.radeon.so', 'previous radv')
        for part in ('system', 'vendor'):
            shutil.copyfile(self.product / (part + '.img'), self.images / (part + '.img'))
        write(self.images / 'SHA256SUMS', ''.join(
            f'{hashlib.sha256((self.images / (part + ".img")).read_bytes()).hexdigest()}  {part}.img\n'
            for part in ('system', 'vendor')))

    def stub(self, name, body):
        write(self.bin / name, '#!/bin/bash\nset -eu\n' + body + '\n', True)

    def stub_packager(self):
        write(self.real_packager, '''#!/bin/bash
set -eu
if [[ "${PACKAGE_SIGNAL:-0}" == 1 ]]; then kill -TERM "$$"; fi
[[ "${PACKAGE_FAIL:-0}" != 1 ]] || exit 12
mkdir -p "$2/system" "$2/vendor/lib64/hw"
echo 'ro.build.version.sdk=34' > "$2/system/build.prop"
echo radv > "$2/vendor/lib64/hw/vulkan.radeon.so"
''', True)

    def build(self, action='--package-only', success=True, **env):
        result = subprocess.run(['bash', str(self.repo / 'image-14/scripts/build-images-x86_64.sh'), action],
                                env={**self.env, **env}, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def assert_previous(self):
        self.assertEqual((self.rootfs / 'old').read_text(), 'previous valid rootfs')
        self.assertEqual((self.images / 'old').read_text(), 'previous images')

    def assert_metadata(self):
        lines = (self.images / 'SHA256SUMS').read_text().splitlines()
        for part, line in zip(('system', 'vendor'), lines):
            self.assertEqual(line, f'{hashlib.sha256((self.product / (part + ".img")).read_bytes()).hexdigest()}  {part}.img')
        info = (self.images / 'BUILD-INFO.txt').read_text()
        self.assertEqual(info, (self.rootfs / '.lepton-image-provenance').read_text())
        self.assertIn(hashlib.sha256((self.rootfs / 'system/build.prop').read_bytes()).hexdigest(), info)
        return '\n'.join(line for line in info.splitlines() if not line.startswith('Built:'))

    def test_package_only_success_repeated_and_same_metadata_as_execute(self):
        self.build()
        first = self.assert_metadata()
        self.assertFalse((self.work / 'trace').exists(), 'package-only must not invoke Podman compilation')
        self.build()
        self.assertEqual(first, self.assert_metadata())
        self.build('--execute')
        self.assertEqual((self.work / 'trace').read_text(), 'compile\n')
        self.assertEqual(first, self.assert_metadata())

    def test_packaging_failure_and_signal_preserve_previous_outputs(self):
        for env in ({'PACKAGE_FAIL': '1'}, {'PACKAGE_SIGNAL': '1'}):
            with self.subTest(env=env):
                self.build(success=False, **env)
                self.assert_previous()
        out = self.build('--execute', success=False, PACKAGE_FAIL='1')
        self.assertIn('Android images compiled successfully, but rootfs packaging failed', out)
        self.assertIn('--package-only', out)
        self.assertNotIn('--repair', out)
        self.assert_previous()
        self.build()
        self.assert_metadata()

    def test_missing_truncated_or_incomplete_source_images(self):
        original = (self.product / 'system.img').read_bytes()
        for data in (None, b'', original[:-1], b'bad image'):
            with self.subTest(data=data):
                path = self.product / 'system.img'
                if data is None:
                    path.unlink()
                else:
                    path.write_bytes(data)
                out = self.build(success=False)
                self.assertIn('Source image unsuitable', out)
                self.assert_previous()
                path.write_bytes(original)
        self.assertFalse((self.work / 'trace').exists())

    def test_active_workflow_and_external_ninja_are_refused(self):
        with open(self.state / 'images.lock', 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertIn('Another image build', self.build(success=False))
        proc = subprocess.Popen(['bash', '-c', 'exec -a ninja sleep 30'])
        try:
            # Synchronize with exec rather than rely on timing.
            for _ in range(100):
                if Path(f'/proc/{proc.pid}/cmdline').read_bytes().startswith(b'ninja\0'):
                    break
                import time
                time.sleep(.01)
            self.assertIn('Active compilation', self.build(success=False))
        finally:
            proc.terminate()
            proc.wait()
        self.assert_previous()

    def test_interrupted_or_failed_compilation_requires_successful_build(self):
        write(self.state / 'build.running', 'interrupted')
        self.assertIn('Interrupted or failed compilation', self.build(success=False))
        (self.state / 'build.running').unlink()
        self.build('--execute', success=False, COMPILE_FAIL='3')
        self.assertTrue((self.state / 'build.failed').exists())
        self.build(success=False)
        self.assert_previous()

    def test_missing_fuse_helpers_and_bad_device_fail_before_compilation(self):
        for helper in ('fusermount', 'fusermount3'):
            with self.subTest(helper=helper):
                self.stub('ldd', 'echo ' + ('libfuse.so.2' if helper == 'fusermount' else 'libfuse3.so.3'))
                # Isolate dependency lookup to avoid an installed host helper.
                hidden = self.bin / 'isolated'
                hidden.mkdir(exist_ok=True)
                source = (ROOT / 'image-14/scripts/lib/packaging-fuse.sh').read_text()
                import re
                tools = re.search(r'for tool in (.*?); do', source, re.S)[1].replace('\\\n', '').split()
                for name in tools + ['fusermount', 'fusermount3', 'ldd']:
                    path = hidden / name
                    if name != helper and not path.exists():
                        path.symlink_to(self.bin / name if (self.bin / name).exists() else shutil.which(name))
                missing_path = hidden / helper
                if missing_path.exists():
                    missing_path.unlink()
                result = subprocess.run(['/bin/bash', '-c', 'source "$1"; lepton_packaging_requirements', '--',
                                         str(self.repo / 'image-14/scripts/lib/packaging-fuse.sh')],
                                        env={**self.env, 'PATH': str(hidden)}, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f'Missing rootfs packaging executable: {helper}', result.stderr)
                self.assertIn('fuse fuse-libs', result.stderr)
                self.assertIn('Ubuntu', result.stderr)
                # A known FUSE implementation must not require the other
                # version's helper (important on Ubuntu package combinations).
                missing_path.symlink_to(self.bin / helper)
                other = 'fusermount3' if helper == 'fusermount' else 'fusermount'
                (hidden / other).unlink()
                available = subprocess.run(['/bin/bash', '-c', 'source "$1"; lepton_packaging_requirements', '--',
                                            str(self.repo / 'image-14/scripts/lib/packaging-fuse.sh')],
                                           env={**self.env, 'PATH': str(hidden)}, capture_output=True, text=True)
                self.assertEqual(available.returncode, 0, available.stdout + available.stderr)
        out = self.build('--execute', success=False, LEPTON_FUSE_DEVICE=str(self.work / 'missing-device'))
        self.assertIn('FUSE device missing', out)
        self.assertFalse((self.work / 'trace').exists())
        out = self.build('--execute', success=False, FUSE_FAIL='1')
        self.assertIn('mount permission/helper smoke test failed', out)
        self.assert_previous()

    def test_inaccessible_fuse_device(self):
        # No mknod/root needed: emulate only the character-device predicate;
        # the real permission checks still run as the unprivileged test user.
        helper = self.repo / 'image-14/scripts/lib/packaging-fuse.sh'
        helper.write_text(helper.read_text().replace('! -c "$device"', '! -f "$device"'))
        device = self.work / 'blocked-device'
        device.touch(mode=0o000)
        out = self.build(success=False, LEPTON_FUSE_DEVICE=str(device))
        self.assertIn('FUSE device inaccessible', out)
        self.assert_previous()

    def test_smoke_unmount_failure_is_diagnosed(self):
        out = self.build('--execute', success=False, UNMOUNT_FAIL='1')
        self.assertIn('smoke-test unmount failed', out)
        self.assertFalse((self.work / 'trace').exists())
        self.assert_previous()

    def test_normal_preflight_modes_run_packaging_checks(self):
        for mode in ('fresh', 'existing'):
            result = subprocess.run(['bash', str(self.repo / 'image-14/scripts/preflight-x86_64.sh'), mode],
                                    env={**self.env, 'FUSE_FAIL': '1'}, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('FUSE mount permission/helper smoke test failed', result.stdout + result.stderr)

    def test_rename_failure_rolls_back_both_directories(self):
        real_mv = shutil.which('mv')
        self.stub('mv', f'''if [[ "$*" == *"/images "* && "${{!#}}" == "$FIXTURE/workspace/images" ]]; then exit 8; fi
exec "{real_mv}" "$@"''')
        self.build(success=False)
        self.assert_previous()

    def test_signal_during_promotion_rolls_back(self):
        real_mv = shutil.which('mv')
        self.stub('mv', f'''"{real_mv}" "$@"
if [[ "$*" == *"/rootfs "* && "${{!#}}" == "$FIXTURE/workspace/rootfs" ]]; then kill -TERM "$PPID"; fi''')
        self.build(success=False)
        self.assert_previous()

    def test_fuse3_implementation_selects_fuse3_helper(self):
        self.stub('ldd', 'echo libfuse3.so.3')
        self.stub('fusermount', 'echo "wrong helper" >&2; exit 99')
        self.build()
        self.assert_metadata()
        out, target = self.real_rootfs()
        self.assertIn('Flattened 1 APEX', out)

    def test_unrelated_existing_directory_is_never_overwritten(self):
        (self.rootfs / 'system/build.prop').unlink()
        out = self.build(success=False)
        self.assertIn('not a recognized packaged output', out)
        self.assert_previous()

    def real_rootfs(self, success=True, **env):
        write(self.real_packager, self.packager_source, True)
        target = self.workspace / 'new-rootfs'
        result = subprocess.run(['bash', str(self.real_packager), str(self.aosp), str(target)],
                                env={**self.env, **env}, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result.stdout + result.stderr, target

    def test_apex_success_and_binderfs_layout(self):
        out, target = self.real_rootfs()
        self.assertIn('Flattened 1 APEX', out)
        self.assertTrue((target / 'system/apex/com.fixture/payload.txt').exists())
        self.assertFalse((target / 'system/apex/com.fixture.apex').exists())
        self.assertIn('/system/bin/binderfs-ensure', (target / 'system/etc/init/hw/init.rc').read_text())

    def test_apex_mount_failure_does_not_copy_or_unmount_unmounted_tree(self):
        out, target = self.real_rootfs(success=False, FUSE_FAIL='1')
        self.assertIn('APEX com.fixture.apex: fuse2fs mount failed', out)
        self.assertFalse(target.exists())
        self.assertEqual(list(self.workspace.glob('.package-*')), [])

    def test_apex_mount_success_exit_without_mount_is_rejected(self):
        self.stub('fuse2fs', 'exit 0')
        out, target = self.real_rootfs(success=False)
        self.assertIn('did not produce a mounted filesystem', out)
        self.assertFalse(target.exists())
        self.assertEqual(list(self.workspace.glob('.package-*')), [])

    def test_apex_unmount_success_exit_with_live_mount_is_rejected(self):
        self.stub('fusermount', 'exit 0')
        out, target = self.real_rootfs(success=False)
        self.assertIn('unmount failed', out)
        self.assertFalse(target.exists())
        self.assertEqual(len(list(self.workspace.glob('.package-*'))), 1)

    def test_apex_unmount_failure_retains_temporary_tree(self):
        out, target = self.real_rootfs(success=False, UNMOUNT_FAIL='1')
        self.assertIn('APEX com.fixture.apex: unmount failed', out)
        self.assertIn('retaining', out)
        self.assertFalse(target.exists())
        retained = list(self.workspace.glob('.package-*'))
        self.assertEqual(len(retained), 1)
        self.assertTrue((retained[0] / 'apex-mount/.fixture-mounted').exists())

    def test_apex_interruption_cleans_mount_and_partial_tree(self):
        out, target = self.real_rootfs(success=False, RSYNC_SIGNAL='1')
        self.assertFalse(target.exists())
        self.assertEqual(list(self.workspace.glob('.package-*')), [])
        self.assert_previous()


if __name__ == '__main__':
    unittest.main()
