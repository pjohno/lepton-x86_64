#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Exercise the real launcher with fake runtime libraries; no Android or root."""
import fcntl
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


def write(path, content, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    if executable:
        path.chmod(0o755)


class LauncherLocks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.launcher = self.work / 'tool/lepton'
        self.launcher.parent.mkdir()
        shutil.copy2(ROOT / 'compat_tool/lepton', self.launcher)
        for command in ('systemctl', 'pgrep'):
            write(self.work / 'bin' / command, '#!/bin/sh\nexit 1\n', True)
        real_flock = shutil.which('flock')
        write(self.work / 'bin/flock', '#!/bin/bash\n'
              'printf "%s\\n" "$*" >> "$FLOCK_LOG"\n'
              f'exec "{real_flock}" "$@"\n', True)
        write(self.launcher.parent / 'liblepton/liblepton.sh', '''
# Simulate an older installed library: launcher-only upgrades must override it.
lock_lepton() { echo UNSAFE_OLD_LOCK; }
list_containers() {
    printf '%s\\n' "$LEPTON_LOCK_PATH"
    if [[ "${TEST_REACQUIRE:-0}" == 1 ]]; then
        flock -u "$LEPTON_LOCKFD"
        printf 'READY\\n'
        read -r _
        lock_lepton
    fi
    echo COMPLETED
}
''')
        self.env = {
            **os.environ, 'TERM': 'dumb', 'LEPTON_DEBUG': 'false',
            'PATH': f'{self.work}/bin:/usr/bin:/bin',
            'FLOCK_LOG': str(self.work / 'flock.log'),
        }
        for key in ('LEPTON_ISOLATED_SYSBAKE', 'LEPTON_LOCK_PATH', 'LEPTON_LOCK_TIMEOUT', 'SteamAppId'):
            self.env.pop(key, None)
        self.users = {}
        # Two account/session roots simulate independent Linux users. Ownership
        # checks still use the real unprivileged UID; no setuid/chown is needed.
        for name in ('fedora-gnome', 'steamdeck'):
            home = self.work / name / 'home'
            runtime = self.work / name / 'runtime'
            home.mkdir(parents=True, mode=0o700)
            runtime.mkdir(mode=0o700)
            self.users[name] = {**self.env, 'HOME': str(home), 'XDG_RUNTIME_DIR': str(runtime)}
        self.user = self.users['fedora-gnome']

    def run_launcher(self, env=None, success=True):
        result = subprocess.run(['bash', str(self.launcher), 'ps'],
                                env=env or self.user, capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('COMPLETED', result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('ERROR: Lepton lock:', result.stderr)
            self.assertNotIn('COMPLETED', result.stdout)
        return result

    def test_same_user_same_path_and_default_timeout(self):
        first = self.run_launcher().stdout.splitlines()[0]
        second = self.run_launcher().stdout.splitlines()[0]
        self.assertEqual(first, second)
        self.assertEqual(first, self.user['XDG_RUNTIME_DIR'] + '/lepton.lock')
        self.assertEqual(Path(first).stat().st_mode & 0o777, 0o600)
        self.assertTrue(all(line.startswith('--timeout 10 ') for line in
                            (self.work / 'flock.log').read_text().splitlines()))

    def test_simulated_users_do_not_contend(self):
        first = self.run_launcher(self.users['fedora-gnome']).stdout.splitlines()[0]
        with open(first, 'a') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            second = self.run_launcher({**self.users['steamdeck'], 'LEPTON_LOCK_TIMEOUT': '0'}).stdout.splitlines()[0]
        self.assertNotEqual(first, second)

    def test_timeout_fails_without_proceeding(self):
        path = self.run_launcher().stdout.splitlines()[0]
        with open(path, 'a') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            start = time.monotonic()
            result = self.run_launcher({**self.user, 'LEPTON_LOCK_TIMEOUT': '0.2'}, success=False)
            self.assertGreaterEqual(time.monotonic() - start, 0.15)
        self.assertIn('Cannot acquire', result.stderr)
        self.assertIn('timeout: 0.2s', result.stderr)
        self.assertIn('Another Lepton command for this user', result.stderr)
        self.run_launcher()

    def test_reacquisition_also_stops_with_old_installed_library(self):
        proc = subprocess.Popen(['bash', str(self.launcher), 'ps'],
                                env={**self.user, 'TEST_REACQUIRE': '1', 'LEPTON_LOCK_TIMEOUT': '0'},
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: proc.poll() is not None or proc.kill())
        path = proc.stdout.readline().strip()
        self.assertEqual(proc.stdout.readline().strip(), 'READY')
        with open(path, 'a') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            out, err = proc.communicate('\n', timeout=5)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn('Cannot acquire', err)
        self.assertNotIn('UNSAFE_OLD_LOCK', out)
        self.assertNotIn('COMPLETED', out)

    def test_fallback_is_private_and_stable_for_each_user(self):
        paths = []
        for user in self.users.values():
            env = {**user, 'XDG_RUNTIME_DIR': ''}
            first = self.run_launcher(env).stdout.splitlines()[0]
            self.assertEqual(first, self.run_launcher(env).stdout.splitlines()[0])
            self.assertEqual(first, user['HOME'] + '/.lepton-runtime/lepton.lock')
            self.assertEqual(Path(first).parent.stat().st_mode & 0o777, 0o700)
            paths.append(first)
        self.assertNotEqual(*paths)

    def test_unsuitable_runtime_uses_fallback(self):
        bad = self.work / 'bad-runtime'
        bad.mkdir(mode=0o777)
        bad.chmod(0o777)
        for runtime in (str(bad), '/run', 'relative', str(self.work / 'missing')):
            with self.subTest(runtime=runtime):
                path = self.run_launcher({**self.user, 'XDG_RUNTIME_DIR': runtime}).stdout.splitlines()[0]
                self.assertEqual(path, self.user['HOME'] + '/.lepton-runtime/lepton.lock')
        link = self.work / 'runtime-link'
        link.symlink_to(self.user['XDG_RUNTIME_DIR'])
        for runtime in (str(link), str(link) + '/'):
            path = self.run_launcher({**self.user, 'XDG_RUNTIME_DIR': runtime}).stdout.splitlines()[0]
            self.assertIn('/.lepton-runtime/', path)

    def test_unwritable_directories_fail_actionably(self):
        home = Path(self.user['HOME'])
        runtime = Path(self.user['XDG_RUNTIME_DIR'])
        home.chmod(0o500)
        runtime.chmod(0o500)
        try:
            result = self.run_launcher(success=False)
            self.assertIn('Restore XDG_RUNTIME_DIR', result.stderr)
            self.assertNotIn('Permission denied', result.stderr)
        finally:
            home.chmod(0o700)
            runtime.chmod(0o700)

    def test_unsafe_fallback_or_lock_files_are_rejected(self):
        runtime = Path(self.user['XDG_RUNTIME_DIR'])
        lock = runtime / 'lepton.lock'
        target = self.work / 'target'
        target.write_text('do not truncate')
        lock.symlink_to(target)
        result = self.run_launcher(success=False)
        self.assertIn('Unsafe or unwritable lock file', result.stderr)
        self.assertEqual(target.read_text(), 'do not truncate')
        lock.unlink()
        os.link(target, lock)
        self.run_launcher(success=False)
        lock.unlink()
        os.mkfifo(lock)
        self.run_launcher(success=False)
        lock.unlink()
        lock.write_text('')
        lock.chmod(0o400)
        self.run_launcher(success=False)
        lock.unlink()
        fallback = Path(self.user['HOME']) / '.lepton-runtime'
        fallback.symlink_to(runtime)
        self.run_launcher({**self.user, 'XDG_RUNTIME_DIR': ''}, success=False)

    def test_open_error_is_not_a_raw_shell_failure(self):
        env = {**self.user, 'LEPTON_ISOLATED_SYSBAKE': '1',
               'LEPTON_LOCK_PATH': self.user['XDG_RUNTIME_DIR'] + '/' + 'x' * 300}
        result = self.run_launcher(env, success=False)
        self.assertIn('Cannot open', result.stderr)
        self.assertNotIn('File name too long', result.stderr)

    def test_normal_launch_ignores_unscoped_override(self):
        path = self.run_launcher({**self.user, 'LEPTON_LOCK_PATH': '/tmp/unsafe-override'}).stdout.splitlines()[0]
        self.assertEqual(path, self.user['XDG_RUNTIME_DIR'] + '/lepton.lock')

    def test_steamos_session_modes_share_lock(self):
        paths = []
        for mode in ({'XDG_SESSION_TYPE': 'x11', 'XDG_CURRENT_DESKTOP': 'gamescope'},
                     {'XDG_SESSION_TYPE': 'wayland', 'XDG_CURRENT_DESKTOP': 'KDE'}):
            paths.append(self.run_launcher({**self.users['steamdeck'], **mode}).stdout.splitlines()[0])
        self.assertEqual(*paths)

    def test_isolated_workflow_patches_support_current_and_legacy_launchers(self):
        for name in ('tests/runtime/run-apk.sh', 'image-14/scripts/internal/sysbake-isolated-x86_64.sh'):
            script = (ROOT / name).read_text()
            # Execute each real disposable-launcher Python block, without
            # entering Podman, baking sysbake or changing a source checkout.
            match = re.search(r'python3 - "\$WORK/compat_tool/lepton"[^\n]* <<\'PY\'\n(.*?)\nPY\n', script, re.S)
            self.assertIsNotNone(match)
            for legacy in (False, True):
                with self.subTest(workflow=name, legacy=legacy):
                    copy = self.work / 'disposable/lepton'
                    text = (ROOT / 'compat_tool/lepton').read_text()
                    if legacy:
                        start = text.index('# This lock guards commands')
                        end = text.index('# Automatically set the context', start)
                        text = text[:start] + 'exec {LEPTON_LOCKFD}>/tmp/lepton.lock\n' + text[end:]
                    write(copy, text)
                    utils = copy.parent / 'utils.sh'
                    write(utils, 'function wait_for_file()\n{\n    :\n}\n')
                    result = subprocess.run(['python3', '-', str(copy), str(utils)],
                                            input=match.group(1), text=True, capture_output=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    subprocess.run(['bash', '-n', str(copy)], check=True)
                    if legacy:
                        self.assertNotIn('/tmp/lepton.lock', copy.read_text())
                    else:
                        isolated = self.work / 'private-isolated'
                        isolated.mkdir(mode=0o700, exist_ok=True)
                        path = self.run_launcher({**self.user, 'LEPTON_ISOLATED_SYSBAKE': '1',
                                                  'LEPTON_LOCK_PATH': str(isolated / 'lock')}).stdout.splitlines()[0]
                        self.assertEqual(path, str(isolated / 'lock'))


if __name__ == '__main__':
    unittest.main()
