#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Host-only checks, independent of checkout state or generated Android assets.

Probes use disposable files/stores/namespaces. No image pulls, kernel/module
changes, host Binder mounts, service changes or default Podman store access.
"""
import argparse
import gzip
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

SCRIPTS = Path(__file__).resolve().parents[1]


class Capabilities:
    def __init__(self, args):
        self.args = args
        self.errors = {stage: [] for stage in ('compilation', 'packaging', 'bundle')}
        self.present = {}

    def report(self, stage, message, ok=True):
        print(f'[{"PASS" if ok else "FAIL"}] {message}', flush=True)
        if not ok:
            self.errors[stage].append(message)

    def tools(self, stage, names, purpose, fedora, ubuntu):
        missing = []
        for name in names.split():
            self.present[name] = shutil.which(name) is not None
            if not self.present[name]:
                missing.append(name)
        self.report(stage, f'{purpose}: ' + ('missing ' + ', '.join(missing) if missing else 'executables available'), not missing)
        if missing:
            print(f'       Fedora: {fedora}\n       Ubuntu: {ubuntu}', flush=True)
        return not missing

    def run(self, command, **kwargs):
        # Terminate only this probe's process group on timeout, including children.
        try:
            with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  text=True, start_new_session=True, **kwargs) as proc:
                try:
                    out, err = proc.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    out, err = proc.communicate()
                    return False, (err + '\nProbe timed out').strip()
                except BaseException:
                    # A cancelled preflight must not leave a namespace/Weston
                    # or compiler probe running after its temporary tree exits.
                    try:
                        os.killpg(proc.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    proc.communicate()
                    raise
                return proc.returncode == 0, (out if proc.returncode == 0 else err + out).strip()
        except OSError as exc:
            return False, str(exc)

    def text(self, variable, default):
        path = Path(os.environ.get(variable, default))
        try:
            return path.read_text().strip()
        except OSError:
            return ''

    def resources(self):
        memory = self.text('LEPTON_PREFLIGHT_MEMINFO', '/proc/meminfo')
        match = re.search(r'^MemTotal:\s+(\d+)', memory, re.M)
        gib = int(match[1]) // (1024 * 1024) if match else 0
        self.report('compilation', f'Compilation host RAM: {gib} GiB (minimum 16)', gib >= 16)
        cpus = len(os.sched_getaffinity(0)) if hasattr(os, 'sched_getaffinity') else (os.cpu_count() or 1)
        self.report('compilation', f'Compilation jobs: {self.args.jobs}; available CPUs: {cpus}', 0 < self.args.jobs <= cpus)
        parent = Path(self.args.workspace).absolute()
        while not parent.exists() and parent != parent.parent:
            parent = parent.parent
        free = shutil.disk_usage(parent).free // (1024 ** 3)
        self.report('compilation', f'Workspace free space: {free} GiB; required {self.args.min_free_gib}', free >= self.args.min_free_gib)

    def graphics(self):
        if self.args.rendering != 'amd':
            print('[INFO] Software sysbake selected; no AMD GPU required.')
            return
        drm = Path(os.environ.get('LEPTON_PREFLIGHT_DRM', '/sys/class/drm'))
        nodes = Path(os.environ.get('LEPTON_PREFLIGHT_DEV_DRI', '/dev/dri'))
        usable = False
        for vendor in drm.glob('renderD*/device/vendor'):
            try:
                node = nodes / vendor.parents[1].name
                usable |= vendor.read_text().strip() == '0x1002' and stat.S_ISCHR(node.stat().st_mode) and os.access(node, os.R_OK | os.W_OK)
            except OSError:
                continue
        self.report('bundle', 'AMD sysbake render-node access', usable)
        if not usable:
            print('[INFO] Select --sysbake-rendering software to bake without an AMD GPU, or provide accessible AMD render nodes for the requested hardware path.')

    def binder(self):
        available = any(line.split()[-1:] == ['binder'] for line in
                        self.text('LEPTON_PREFLIGHT_FILESYSTEMS', '/proc/filesystems').splitlines())
        self.report('bundle', 'Android BinderFS registered by the running kernel' if available else
                    'Android BinderFS unavailable: running kernel does not expose the binder filesystem', available)
        if not available:
            # Configuration/module metadata helps explain why, but never proves
            # that a kernel capability is currently usable. Never modprobe here.
            release = self.text('LEPTON_PREFLIGHT_KERNEL_RELEASE', '/proc/sys/kernel/osrelease')
            config_path = Path(os.environ.get('LEPTON_PREFLIGHT_KERNEL_CONFIG', f'/boot/config-{release}'))
            try:
                if config_path.suffix == '.gz':
                    with gzip.open(config_path, 'rt') as config_file:
                        config = config_file.read()
                else:
                    config = config_path.read_text()
                if re.search(r'^CONFIG_ANDROID_BINDERFS=[ym]$', config, re.M):
                    print('[INFO] Kernel configuration advertises BinderFS, but it is not registered; this is not evidence of a usable runtime.')
            except OSError:
                pass
            if shutil.which('modinfo'):
                exists, _ = self.run(['modinfo', '-F', 'filename', 'binder_linux'])
                if exists:
                    print('[INFO] binder_linux module metadata exists, but the capability is inactive/unavailable. An administrator must configure the kernel; no module is loaded by preflight.')
            print('[INFO] Kernel capability failure, not a missing userspace package. Android compilation and rootfs packaging may still work, but sysbake cannot boot Android.')
            print('[INFO] Standard WSL kernels may lack BinderFS. Use a Binder-enabled custom WSL kernel or finish sysbake/bundling on native Linux. No kernel/module installation is attempted.')
        return available

    def session(self):
        pid1 = self.text('LEPTON_PREFLIGHT_PID1_COMM', '/proc/1/comm')
        self.report('bundle', f'Sysbake systemd PID 1: {pid1 or "unavailable"}', pid1 == 'systemd')
        if pid1 != 'systemd':
            print('[INFO] WSL: enable systemd in /etc/wsl.conf and restart the distribution from Windows; preflight never edits system configuration.')
        uid = os.getuid()
        expected = Path(os.environ.get('LEPTON_PREFLIGHT_RUN_USER_BASE', '/run/user')) / str(uid)
        runtime = Path(os.environ.get('XDG_RUNTIME_DIR') or expected)
        try:
            info = runtime.lstat()
            valid = (runtime.is_absolute() and runtime == expected and not stat.S_ISLNK(info.st_mode)
                     and stat.S_ISDIR(info.st_mode) and info.st_uid == uid
                     and info.st_mode & 0o077 == 0 and os.access(runtime, os.R_OK | os.W_OK | os.X_OK))
        except OSError:
            valid = False
        self.report('bundle', f'Isolated sysbake user runtime directory: {runtime}', valid)
        if not valid:
            print(f'[INFO] Expected an owned, private mode-0700 directory at {expected}. A WSLg XDG_RUNTIME_DIR such as /mnt/wslg/runtime-dir is incompatible with isolated sysbake.')
            print(f'[INFO] After enabling systemd/logging in normally, run the build terminal with: export XDG_RUNTIME_DIR={expected}; first verify that directory and systemctl --user work. This does not change WSLg or system configuration.')
        if self.present.get('systemctl'):
            ok, detail = self.run(['systemctl', '--user', 'show-environment'])
            self.report('bundle', 'systemctl --user communication' + ('' if ok else ': ' + detail), ok)
            active, _ = self.run(['systemctl', '--user', 'is-active', '--quiet', 'lepton-sysbake.slice'])
            self.report('bundle', 'Sysbake slice is idle (no running sysbake will be disturbed)', not active)
        for variable, default in (('LEPTON_PREFLIGHT_MAX_USER_NAMESPACES', '/proc/sys/user/max_user_namespaces'),
                                  ('LEPTON_PREFLIGHT_UNPRIVILEGED_USERNS', '/proc/sys/kernel/unprivileged_userns_clone')):
            value = self.text(variable, default)
            if value:
                self.report('bundle', f'User-namespace kernel policy ({default}): {value}', value.isdigit() and int(value) > 0)
        return valid

    def work(self):
        parent = Path(self.args.workspace).absolute()
        while not parent.is_dir() and parent != parent.parent:
            parent = parent.parent
        return Path(tempfile.mkdtemp(prefix='.lepton-host-check.', dir=parent))

    def rootless(self, work, stage):
        needed = ('podman', 'fuse-overlayfs', 'newuidmap', 'newgidmap', 'awk', 'sh')
        if not all(shutil.which(name) for name in needed):
            return None
        command = ['podman', '--remote=false', '--root=' + str(work / 'graph'), '--runroot=' + str(work / 'runroot'),
                   '--storage-driver=overlay', '--storage-opt=overlay.mount_program=' + shutil.which('fuse-overlayfs'),
                   '--events-backend=file']
        self.podman_env = {key: value for key, value in os.environ.items() if key not in ('CONTAINER_HOST', 'CONTAINER_CONNECTION', 'PODMAN_CONNECTION')}
        ok, detail = self.run(command + ['info', '--format', '{{.Host.Security.Rootless}}'], env=self.podman_env)
        ok = ok and detail.lower() == 'true'
        self.report(stage, 'Rootless Podman with private storage' + ('' if ok else ': ' + detail), ok)
        if ok:
            ok, detail = self.run(command + ['unshare', 'sh', '-ec',
                "awk '{n+=$3} END {exit(n<65536)}' /proc/self/uid_map; "
                "awk '{n+=$3} END {exit(n<65536)}' /proc/self/gid_map"], env=self.podman_env)
            self.report(stage, 'Podman subordinate UID/GID mappings (at least 65536 IDs)' + ('' if ok else ': ' + detail), ok)
        if not ok:
            print('[INFO] Configure rootless Podman, newuidmap/newgidmap and this user’s /etc/subuid and /etc/subgid allocations. No default storage, images or mappings are changed by this probe.')
        return command if ok else None

    def binder_access(self, command, work):
        mount = work / 'binder-probe'
        mount.mkdir()
        # This mount exists ONLY in a disposable rootless mount namespace.
        # It never uses/changes /dev/binderfs on the host or loads a module.
        ok, detail = self.run(command + ['unshare', 'unshare', '--mount', '--propagation', 'private',
            'sh', '-ec', 'mount -t binder binder "$1"; '
            'trap \'umount "$1"\' EXIT; python3 "$2" "$1"',
            'binder-preflight', str(mount), str(SCRIPTS / 'internal/probe-binderfs.py')], env=self.podman_env)
        self.report('bundle', 'BinderFS private namespace mount, device allocation and access' + ('' if ok else ': ' + detail), ok)
        if not ok:
            print('[INFO] BinderFS is registered but unusable for rootless sysbake. Inspect kernel, user-namespace and device/security policy; installing a userspace package alone cannot establish this capability.')

    def overlay(self, work):
        device = Path(os.environ.get('LEPTON_FUSE_DEVICE', '/dev/fuse'))
        try:
            valid = stat.S_ISCHR(device.stat().st_mode) and os.access(device, os.R_OK | os.W_OK)
        except OSError:
            valid = False
        self.report('bundle', f'Rootless overlay FUSE device access: {device}', valid)
        if not valid:
            print('[INFO] Expose /dev/fuse and grant device access; this is a kernel/device-policy issue, not a missing Cargo/Android package.')
            return
        if not all(shutil.which(tool) for tool in ('fuse-overlayfs', 'fusermount3', 'mountpoint')):
            return
        lower, upper, scratch, merged = (work / name for name in ('lower', 'upper', 'overlay-work', 'merged'))
        for path in (lower, upper, scratch, merged):
            path.mkdir()
        ok, detail = self.run(['fuse-overlayfs', '-o', f'lowerdir={lower},upperdir={upper},workdir={scratch}', str(merged)])
        mounted, _ = self.run(['mountpoint', '-q', '--', str(merged)])
        self.report('bundle', 'Unprivileged fuse-overlayfs mount' + ('' if ok and mounted else ': ' + detail), ok and mounted)
        if mounted:
            ok, detail = self.run(['fusermount3', '-u', str(merged)])
            still_mounted, _ = self.run(['mountpoint', '-q', '--', str(merged)])
            self.report('bundle', 'fuse-overlayfs unmount' + ('' if ok and not still_mounted else ': ' + detail), ok and not still_mounted)

    def bundle_probes(self, work, command, binder_available):
        if self.present.get('getfattr') and self.present.get('setfattr'):
            probe = work / 'xattr-probe'
            probe.touch()
            ok, detail = self.run(['setfattr', '-n', 'user.lepton_preflight', '-v', '1', str(probe)])
            if ok:
                ok, detail = self.run(['getfattr', '--only-values', '-n', 'user.lepton_preflight', str(probe)])
                ok = ok and detail == '1'
            self.report('bundle', 'Workspace user.* extended attributes' + ('' if ok else ': ' + detail), ok)
        for compiler, source in (('cc', 'int main(void) { return 0; }\n'), ('rustc', 'fn main() {}\n')):
            if self.present.get(compiler):
                src = work / ('probe.c' if compiler == 'cc' else 'probe.rs')
                src.write_text(source)
                compiler_args = [compiler] + (['--edition=2021'] if compiler == 'rustc' else [])
                ok, detail = self.run(compiler_args + [str(src), '-o', str(work / (compiler + '-probe'))], env={**os.environ, 'RUSTUP_AUTO_INSTALL': '0', 'CARGO_NET_OFFLINE': 'true'})
                binary = work / (compiler + '-probe')
                if ok:
                    ok = binary.is_file() and os.access(binary, os.X_OK)
                    if ok:
                        ok, detail = self.run([str(binary)])
                    else:
                        detail = 'compiler did not produce an executable probe'
                self.report('bundle', f'Native {compiler} compilation/linking/execution' + ('' if ok else ': ' + detail), ok)
        if self.present.get('cargo'):
            ok, detail = self.run(['cargo', '--version'], env={**os.environ, 'RUSTUP_AUTO_INSTALL': '0', 'CARGO_NET_OFFLINE': 'true'})
            self.report('bundle', 'Cargo toolchain availability' + ('' if ok else ': ' + detail), ok)
        if command and binder_available and all(self.present.get(name) for name in ('unshare', 'mount', 'umount')):
            self.binder_access(command, work)
        if self.present.get('weston'):
            # Wayland Unix socket paths are short; long workspace paths must
            # not reject a host whose real /run/user socket path is usable.
            runtime = Path(tempfile.mkdtemp(prefix='lepton-weston.', dir='/tmp'))
            env = {**os.environ, 'XDG_RUNTIME_DIR': str(runtime)}
            log = work / 'weston.log'
            proc = None
            try:
                with open(work / 'weston-output', 'w') as output:
                    proc = subprocess.Popen(['weston', '--no-config', '--backend=headless', '--renderer=pixman',
                                             '--socket=lepton-probe', '--log=' + str(log)], env=env,
                                            stdout=output, stderr=output, start_new_session=True)
                    deadline = time.monotonic() + 5
                    ready = False
                    while proc.poll() is None and time.monotonic() < deadline:
                        try:
                            ready = stat.S_ISSOCK((runtime / 'lepton-probe').stat().st_mode)
                        except OSError:
                            pass
                        if ready:
                            break
                        time.sleep(.05)
                    self.report('bundle', 'Headless Weston (headless backend, pixman renderer)', ready)
                    if not ready and log.exists():
                        print(log.read_text()[-3000:])
            except OSError as exc:
                self.report('bundle', f'Headless Weston failed: {exc}', False)
            finally:
                if proc and proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGTERM)
                    try:
                        proc.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        os.killpg(proc.pid, signal.SIGKILL)
                        proc.wait()
                shutil.rmtree(runtime)

    def cleanup(self, work):
        # Same mount-aware deletion guard as rootfs packaging; never remove a
        # tree while a failed FUSE probe leaves a live mount inside it.
        ok, detail = self.run(['bash', '-c', 'source "$1"; lepton_remove_packaging_tree "$2"',
                              '--', str(SCRIPTS / 'lib/packaging-fuse.sh'), str(work)])
        if not ok:
            self.report('bundle' if self.args.workflow in ('bundle', 'complete') else 'packaging', f'Probe cleanup incomplete; files retained for safe inspection: {work}: {detail}', False)

    def check(self):
        selected = self.args.workflow
        print(f'=== Lepton Host Capabilities ({selected}) ===', flush=True)
        compile_selected = selected in ('complete', 'images')
        package_selected = selected in ('complete', 'images', 'packaging')
        bundle_selected = selected in ('complete', 'bundle')
        common = 'bash sh git podman rsync realpath df awk grep python3 tee mktemp timeout flock sha256sum date stat head findmnt nproc cmp'
        if compile_selected:
            try:
                self.resources()
            except OSError as exc:
                self.report('compilation', f'Cannot inspect compilation resources: {exc}', False)
            self.tools('compilation', common, 'Android compilation host tools',
                       'git podman rsync python3 util-linux coreutils', 'git podman rsync python3 util-linux coreutils')
        if bundle_selected:
            self.tools('bundle', common + ' cargo rustc cc make ar strip pkg-config getfattr setfattr weston ip fuse-overlayfs '
                       'systemctl systemd-run newuidmap newgidmap unshare mount umount ldd curl unzip tar gzip fusermount3 mountpoint '
                       'install cp mv rm chmod chgrp mkdir rmdir ln readlink cut sed sort touch cat sleep tail pgrep pkill ps env which seq basename stty',
                       'Bundle/native tools/sysbake host tools',
                       'sudo dnf install cargo rust gcc make pkgconf-pkg-config attr weston iproute fuse-overlayfs podman shadow-utils systemd util-linux curl unzip rsync binutils which procps-ng coreutils',
                       'sudo apt install cargo rustc build-essential pkg-config attr weston iproute2 fuse-overlayfs podman uidmap systemd dbus-user-session util-linux curl unzip rsync binutils debianutils procps coreutils')
            if self.args.with_gapps or self.args.with_widevine:
                self.tools('bundle', 'debugfs', 'Optional Google image extraction', 'e2fsprogs', 'e2fsprogs')
            if self.args.with_ndk:
                self.tools('bundle', 'readelf', 'Optional NDK ELF inspection', 'binutils', 'binutils')
            if self.args.transfer:
                self.tools('bundle', 'ssh', 'Optional bundle transfer', 'openssh-clients', 'openssh-client')
        if compile_selected or bundle_selected:
            self.tools('compilation' if compile_selected else 'bundle', 'fuse-overlayfs newuidmap newgidmap',
                       'Rootless Podman support', 'fuse-overlayfs shadow-utils', 'fuse-overlayfs uidmap')
        binder_available = self.binder() if bundle_selected else False
        if bundle_selected:
            self.session()
            self.graphics()
        work = None
        try:
            work = self.work()
            if package_selected:
                ok, detail = self.run(['bash', '-c', 'source "$1"; lepton_packaging_requirements && lepton_fuse_smoke_test',
                                      '--', str(SCRIPTS / 'lib/packaging-fuse.sh')], env={**os.environ, 'TMPDIR': str(work)})
                if detail:
                    print(detail, flush=True)
                self.report('packaging', 'Rootfs packaging executables, FUSE access and mount/unmount', ok)
            command = self.rootless(work, 'compilation' if compile_selected else 'bundle') if compile_selected or bundle_selected else None
            if bundle_selected:
                self.overlay(work)
                self.bundle_probes(work, command, binder_available)
        except OSError as exc:
            self.report('bundle' if bundle_selected else 'packaging', f'Cannot create disposable workspace probes: {exc}', False)
        finally:
            if work:
                self.cleanup(work)
        for stage, label, requested in (('compilation', 'Compilation', compile_selected),
                                         ('packaging', 'Rootfs packaging', package_selected),
                                         ('bundle', 'Full Steam Deck bundle', bundle_selected)):
            # Complete bundling also depends on compilation and packaging.
            ready = not self.errors[stage]
            if stage == 'bundle' and selected == 'complete':
                ready = not any(self.errors.values())
            print(f'{label}: ' + ('NOT CHECKED (not selected)' if not requested else 'READY' if ready else 'NOT READY'))
        failed = any(self.errors.values())
        if failed:
            print('[FAIL] Selected workflow cannot start. Image-only developers can use prepare-x86_64.sh and build-images-x86_64.sh independently; no BinderFS/systemd check is imposed on those operations.')
        else:
            print('[PASS] Selected host capabilities checked; generated assets and actual Android boot are validated at their later phases.')
        return 1 if failed else 0


def main():
    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workflow', choices=('complete', 'images', 'packaging', 'bundle'), default='complete')
    parser.add_argument('--workspace', default=tempfile.gettempdir())
    parser.add_argument('--rendering', choices=('software', 'amd'), default='software')
    parser.add_argument('--jobs', type=int, default=1)
    parser.add_argument('--min-free-gib', type=int, default=0)
    for name in ('with-gapps', 'with-ndk', 'with-widevine', 'transfer'):
        parser.add_argument('--' + name, action='store_true')
    args = parser.parse_args()
    if args.jobs <= 0 or args.min_free_gib < 0:
        parser.error('--jobs must be positive and --min-free-gib nonnegative')
    return Capabilities(args).check()


if __name__ == '__main__':
    sys.exit(main())
