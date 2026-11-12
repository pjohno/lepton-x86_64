#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Full host capability preflight with fake hosts; no root or Android build.

Only the Weston stand-in uses a real temporary Unix socket. Mounts, Binder
namespaces, Podman stores, native compilers and kernel files are fixtures.
"""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def write(path, text, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    if executable:
        path.chmod(0o755)


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.repo = self.work / 'repo'
        self.workspace = self.work / 'workspace'
        self.bin = self.work / 'bin'
        self.bin.mkdir()
        files = ('image-14/do_build_x86_64.sh', 'image-14/scripts/preflight-x86_64.sh',
                 'image-14/scripts/make-deck-bundle-x86_64.sh',
                 'image-14/scripts/build-incremental-bundle-x86_64.sh',
                 'image-14/scripts/lib/workspace.sh', 'image-14/scripts/lib/packaging-fuse.sh',
                 'image-14/scripts/internal/check-host-capabilities.py',
                 'image-14/scripts/internal/probe-binderfs.py')
        for name in files:
            dest = self.repo / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, dest)
        for name in ('image-14/.buildscripts/container.sh', 'image-14/.buildscripts/update_repositories.sh',
                     'image-14/.buildscripts/copy_vendored_projects.sh', 'image-14/android_vendor_valve/vendorsetup.sh',
                     'image-14/android_vendor_valve/patches/apply-patches.sh',
                     'image-14/.buildscripts_x86_64/Containerfile.ubuntu26',
                     'image-14/.buildscripts_x86_64/Containerfile.deck-tools',
                     'image-14/scripts/internal/provision-deck-tools.sh',
                     'image-14/scripts/internal/bootstrap-glslang14.sh'):
            write(self.repo / name, 'fixture\n')
        for name in ('prepare-x86_64.sh', 'build-images-x86_64.sh', 'internal/deploy-compat-x86_64.sh'):
            write(self.repo / 'image-14/scripts' / name, '#!/bin/bash\nprintf "%s\\n" "$0 $*" >> "$EXPENSIVE_LOG"\nexit 0\n')
        write(self.repo / '.build-env', f'LEPTON_OUTPUT_DIR="{self.workspace}"\n'
              'LEPTON_BUILD_TARGET=aosp_lepton_x86_64-ap2a-userdebug\n'
              'LEPTON_BUILD_JOBS=1\nLEPTON_MIN_FREE_GIB=0\n'
              'LEPTON_BUILD_CONTAINER=lepton-builder-ubuntu26:latest\n')
        tools = ('bash sh dirname uname id git podman rsync realpath df awk grep python3 tee mktemp timeout flock sha256sum '
                 'date stat head findmnt nproc cmp cargo rustc cc make ar strip pkg-config getfattr setfattr '
                 'weston ip fuse-overlayfs systemctl systemd-run newuidmap newgidmap unshare mount umount '
                 'ldd readelf curl unzip tar gzip install cp mv rm chmod chgrp mkdir ln readlink cut sed sort '
                 'touch cat sleep tail pgrep pkill ps env which seq basename stty rmdir simg2img sqfs2tar fuse2fs fusermount fusermount3 '
                 'mountpoint mkfs.ext4 truncate find modinfo').split()
        for name in tools:
            source = shutil.which(name)
            if source:
                (self.bin / name).symlink_to(source)
            else:
                self.stub(name, 'exit 0')
        # Fix the interpreter for probes regardless of the caller's Python env.
        (self.bin / 'python3').unlink()
        (self.bin / 'python3').symlink_to(sys.executable)
        for name in ('make', 'pkg-config', 'newuidmap', 'newgidmap', 'rsync', 'curl', 'ip'):
            self.stub(name, 'exit 0')
        for name in ('cc', 'rustc'):
            self.stub(name, '''[[ "${NATIVE_FAIL:-0}" == 0 ]] || { echo 'toolchain unavailable' >&2; exit 1; }
printf '#!/bin/sh\\nexit 0\\n' > "${!#}"
chmod 755 "${!#}"''')
        self.stub('cargo', 'echo "cargo fixture"')
        self.stub('getfattr', '[[ "${XATTR_FAIL:-0}" == 0 ]] || exit 1; echo 1')
        self.stub('setfattr', '[[ "${XATTR_FAIL:-0}" == 0 ]]')
        self.stub('ldd', 'exit 1')
        self.stub('mkfs.ext4', 'exit 0')
        self.stub('fuse2fs', '[[ "${FUSE_FAIL:-0}" == 0 ]] || exit 1; touch "${!#}/.mounted"')
        self.stub('fuse-overlayfs', '[[ "${OVERLAY_FAIL:-0}" == 0 ]] || exit 1; touch "${!#}/.mounted"')
        self.stub('mountpoint', '[[ -f "${!#}/.mounted" ]]')
        for name in ('fusermount', 'fusermount3'):
            self.stub(name, 'rm -f "${!#}/.mounted"')
        self.stub('modinfo', 'echo /lib/modules/binder_linux.ko')
        self.stub('systemctl', '''if [[ "$*" == *"show-environment"* ]]; then exit "${USER_MANAGER_FAIL:-0}"; fi
if [[ "$*" == *"lepton-sysbake.slice"* ]]; then exit 1; fi
exit 0''')
        self.stub('podman', '''case " $* " in
*" image exists "*) exit "${BUILDER_MISSING:-0}" ;;
*" image inspect "*) echo fixture ;;
*" info "*) [[ "${ROOTLESS_FAIL:-0}" == 0 ]] || exit 1; echo true ;;
*" binder-preflight "*) [[ "${BINDER_ACCESS_FAIL:-0}" == 0 ]] || { echo 'permission denied' >&2; exit 1; } ;;
*" unshare "*) exit "${USERNS_FAIL:-0}" ;;
*) echo "podman $*" >> "$EXPENSIVE_LOG"; exit 90 ;;
esac''')
        self.stub('git', '''case " $* " in
*" submodule status "*) echo ' abc fixture' ;;
*" rev-parse "*) printf '%040d\\n' 1 ;;
esac''')
        self.stub('nproc', 'echo 64')
        self.stub('df', '''if [[ "$*" == *-Pi* ]]; then
printf 'Filesystem Inodes IUsed IFree IUse Mounted\\nfixture 10000000 0 10000000 0 /\\n'
else
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\\nfixture 9999999999 0 9999999999 0 /\\n'
fi''')
        real_awk = shutil.which('awk')
        self.stub('awk', f'''if [[ "${{!#}}" == /proc/meminfo ]]; then echo 33554432; else exec "{real_awk}" "$@"; fi''')
        self.stub_python('weston', '''import os, socket, time
from pathlib import Path
if os.environ.get('WESTON_FAIL') == '1': raise SystemExit(2)
s = socket.socket(socket.AF_UNIX)
s.bind(str(Path(os.environ['XDG_RUNTIME_DIR']) / 'lepton-probe'))
while True: time.sleep(1)
''')
        fixture = self.work / 'host'
        uid = os.getuid()
        runtime = fixture / 'run/user' / str(uid)
        runtime.mkdir(parents=True, mode=0o700)
        write(fixture / 'filesystems', 'nodev\tbinder\n')
        write(fixture / 'pid1', 'systemd\n')
        write(fixture / 'kernel', '6.8.0-native\n')
        write(fixture / 'meminfo', 'MemTotal: 33554432 kB\n')
        write(fixture / 'max-user-ns', '10000\n')
        write(fixture / 'unprivileged-userns', '1\n')
        home = self.work / 'home'
        home.mkdir()
        self.env = {**os.environ, 'PATH': str(self.bin), 'HOME': str(home),
                    'XDG_RUNTIME_DIR': str(runtime),
                    'LEPTON_PREFLIGHT_RUN_USER_BASE': str(fixture / 'run/user'),
                    'LEPTON_PREFLIGHT_FILESYSTEMS': str(fixture / 'filesystems'),
                    'LEPTON_PREFLIGHT_PID1_COMM': str(fixture / 'pid1'),
                    'LEPTON_PREFLIGHT_MEMINFO': str(fixture / 'meminfo'),
                    'LEPTON_PREFLIGHT_KERNEL_RELEASE': str(fixture / 'kernel'),
                    'LEPTON_PREFLIGHT_MAX_USER_NAMESPACES': str(fixture / 'max-user-ns'),
                    'LEPTON_PREFLIGHT_UNPRIVILEGED_USERNS': str(fixture / 'unprivileged-userns'),
                    'LEPTON_FUSE_DEVICE': '/dev/null', 'EXPENSIVE_LOG': str(self.work / 'expensive')}
        for key in ('XATTR_FAIL', 'FUSE_FAIL', 'OVERLAY_FAIL', 'ROOTLESS_FAIL', 'USERNS_FAIL',
                    'BINDER_ACCESS_FAIL', 'USER_MANAGER_FAIL', 'BUILDER_MISSING', 'WESTON_FAIL', 'NATIVE_FAIL'):
            self.env.pop(key, None)

    def stub(self, name, source):
        path = self.bin / name
        if path.is_symlink():
            path.unlink()
        write(path, '#!/bin/bash\nset -eu\n' + source + '\n', True)

    def stub_python(self, name, source):
        path = self.bin / name
        if path.is_symlink():
            path.unlink()
        write(path, f'#!{sys.executable}\n' + source, True)

    def run_check(self, script='internal/check-host-capabilities.py', args=(), ok=True, **env):
        path = self.repo / 'image-14/scripts' / script
        if script == '../do_build_x86_64.sh':
            path = self.repo / 'image-14/do_build_x86_64.sh'
        command = [sys.executable if path.suffix == '.py' else '/bin/bash', str(path), *args]
        if path.suffix == '.py':
            command += ['--workspace', str(self.workspace)]
        result = subprocess.run(command, env={**self.env, **env}, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def no_binder(self):
        Path(self.env['LEPTON_PREFLIGHT_FILESYSTEMS']).write_text('nodev\tproc\n')

    def test_native_host_passes_and_clean_checkout_needs_no_images(self):
        out = self.run_check('preflight-x86_64.sh', ('fresh',))
        self.assertIn('PREFLIGHT PASSED (fresh)', out)
        self.assertIn('Full Steam Deck bundle: READY', out)
        self.assertFalse((self.workspace / 'aosp').exists())
        self.assertFalse((self.work / 'expensive').exists())

    def test_missing_tools_reported_together(self):
        missing = ('cargo', 'rustc', 'getfattr', 'setfattr', 'weston', 'ip')
        for tool in missing:
            (self.bin / tool).unlink()
        out = self.run_check(ok=False)
        for tool in missing:
            self.assertIn(tool, out)
        self.assertIn('Fedora:', out)
        self.assertIn('Ubuntu:', out)
        self.assertIn('Compilation: READY', out)
        self.assertIn('Full Steam Deck bundle: NOT READY', out)

    def test_base_bundle_requires_readelf_without_ndk(self):
        # Every stage validates the bundled NDK shim with readelf, so a base
        # bundle must not pass preflight and then fail after compilation.
        (self.bin / 'readelf').unlink()
        out = self.run_check(args=('--workflow', 'bundle'), ok=False)
        self.assertIn('readelf', out)
        self.assertIn('Full Steam Deck bundle: NOT READY', out)
        out = self.run_check(args=('--workflow', 'images'))
        self.assertNotIn('missing readelf', out)

    def test_missing_fuse_helpers(self):
        for helper in ('fusermount', 'fusermount3'):
            original = (self.bin / helper).read_text()
            (self.bin / helper).unlink()
            out = self.run_check(ok=False)
            self.assertIn('Missing rootfs packaging executable: ' + helper, out)
            write(self.bin / helper, original, True)

    def test_missing_binder_blocks_full_build_before_any_expensive_command(self):
        self.no_binder()
        for mode in ('--check', '--execute'):
            out = self.run_check('../do_build_x86_64.sh', (mode, '--bundle-id', 'test'), ok=False, BUILDER_MISSING='1')
            self.assertIn('Android BinderFS unavailable', out)
            self.assertIn('custom WSL kernel', out)
            self.assertNotIn('PREFLIGHT PASSED', out)
            self.assertFalse((self.workspace / 'aosp').exists())
            self.assertFalse((self.work / 'expensive').exists())

    def test_missing_binder_does_not_block_image_only_or_packaging_only_checks(self):
        self.no_binder()
        for workflow in ('images', 'packaging'):
            out = self.run_check(args=('--workflow', workflow))
            self.assertNotIn('Android BinderFS unavailable', out)
            self.assertIn('Full Steam Deck bundle: NOT CHECKED', out)
        out = self.run_check('preflight-x86_64.sh', ('fresh', '--workflow', 'images'))
        self.assertIn('PREFLIGHT PASSED', out)

    def test_registered_binder_with_unusable_devices_is_blocking(self):
        out = self.run_check(ok=False, BINDER_ACCESS_FAIL='1')
        self.assertIn('BinderFS registered by the running kernel', out)
        self.assertIn('BinderFS is registered but unusable', out)
        self.assertIn('device allocation and access: permission denied', out)

    def test_module_filename_is_not_evidence_of_available_binderfs(self):
        self.no_binder()
        out = self.run_check(ok=False)
        self.assertIn('module metadata exists', out)
        self.assertIn('Full Steam Deck bundle: NOT READY', out)

    def test_wsl_without_systemd(self):
        Path(self.env['LEPTON_PREFLIGHT_PID1_COMM']).write_text('init(Fedora)\n')
        Path(self.env['LEPTON_PREFLIGHT_KERNEL_RELEASE']).write_text('6.6.87.2-microsoft-standard-WSL2\n')
        out = self.run_check(ok=False)
        self.assertIn('Sysbake systemd PID 1: init(Fedora)', out)
        self.assertIn('/etc/wsl.conf', out)

    def test_wslg_runtime_mismatch_is_actionable(self):
        out = self.run_check(ok=False, XDG_RUNTIME_DIR='/mnt/wslg/runtime-dir')
        self.assertIn('incompatible with isolated sysbake', out)
        self.assertIn('export XDG_RUNTIME_DIR=', out)

    def test_systemctl_and_rootless_podman_failures(self):
        for key in ('USER_MANAGER_FAIL', 'ROOTLESS_FAIL', 'USERNS_FAIL', 'OVERLAY_FAIL', 'XATTR_FAIL', 'WESTON_FAIL', 'NATIVE_FAIL'):
            with self.subTest(failure=key):
                self.run_check(ok=False, **{key: '1'})

    def test_bundle_check_refuses_before_creating_stage_without_binder(self):
        self.no_binder()
        out = self.run_check('make-deck-bundle-x86_64.sh', ('--check', '--bundle-id', 'test'), ok=False)
        self.assertIn('Android BinderFS unavailable', out)
        self.assertFalse((self.workspace / 'stages').exists())
        self.assertFalse((self.work / 'expensive').exists())

    def test_bundle_check_covers_hosts_before_checking_generated_assets(self):
        out = self.run_check('make-deck-bundle-x86_64.sh', ('--check', '--bundle-id', 'test'))
        self.assertIn('Full Steam Deck bundle: READY', out)
        self.assertIn('Generated stage assets and Android boot are validated', out)
        self.assertIn('--check', (self.work / 'expensive').read_text())
        self.assertFalse((self.workspace / 'stages').exists())

    def test_fresh_check_without_builder_still_checks_all_hosts(self):
        out = self.run_check('../do_build_x86_64.sh', ('--check', '--bundle-id', 'test'), BUILDER_MISSING='1')
        self.assertIn('Full Steam Deck bundle: READY', out)
        self.assertIn('Builder image is absent', out)
        self.assertFalse((self.work / 'expensive').exists())

    def test_incremental_bundle_also_refuses_before_compilation(self):
        self.no_binder()
        self.run_check('build-incremental-bundle-x86_64.sh',
                       ('--execute', '--bundle-id', 'test', '--output-dir', str(self.work / 'new-incremental')),
                       ok=False)
        self.assertFalse((self.work / 'expensive').exists())

    def test_amd_sysbake_requires_gpu_but_software_does_not(self):
        out = self.run_check(args=('--workflow', 'bundle', '--rendering', 'amd'), ok=False,
                             LEPTON_PREFLIGHT_DRM=str(self.work / 'no-drm'))
        self.assertIn('AMD sysbake render-node access', out)
        self.run_check(args=('--workflow', 'bundle', '--rendering', 'software'))

    def test_individual_image_build_and_package_retain_no_binder_requirement(self):
        # Reuse the real image-workflow fixture; only Android execution and
        # extraction are mocked. This exercises both actual command entrypoints.
        spec = importlib.util.spec_from_file_location('packaging_fixtures', ROOT / 'tests/test-rootfs-packaging.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        fixture = module.PackagingTests('test_package_only_success_repeated_and_same_metadata_as_execute')
        fixture.setUp()
        try:
            path = fixture.work / 'no-binder-filesystems'
            path.write_text('nodev\tproc\n')
            fixture.env['LEPTON_PREFLIGHT_FILESYSTEMS'] = str(path)
            fixture.build('--execute')
            fixture.build('--package-only')
            fixture.assert_metadata()
        finally:
            fixture.doCleanups()


if __name__ == '__main__':
    unittest.main()
