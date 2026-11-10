#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Offline reset regressions: real tiny Git stores, synthetic repo/Podman stages."""
import importlib.util
import fcntl
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / 'image-14/scripts'
SPEC = importlib.util.spec_from_file_location('recovery', SCRIPTS / 'internal/recover-source-locks.py')
recovery = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(recovery)
REAL_GIT = shutil.which('git')


def write(path, content='', executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    if executable:
        path.chmod(0o755)


def git(path, *args):
    return subprocess.check_output([REAL_GIT, '-C', str(path), *args], stderr=subprocess.STDOUT, text=True).strip()


class SourceResetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='lepton-reset-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        # Hermetic process view, backed by actual /proc entries for this test
        # and its deliberately spawned processes. Unrelated desktop services
        # (or another concurrent Git test) must not influence fixture outcomes.
        # Production always inspects the full host /proc; there is no override.
        self.proc = self.base / 'proc'
        self.proc.mkdir()
        (self.proc / 'self').symlink_to('/proc/self', target_is_directory=True)
        (self.proc / 'mounts').symlink_to('/proc/mounts')
        self.track_process(os.getpid())
        self.checker = self.base / 'recover-fixture.py'
        write(self.checker, self.checker_source())
        self.root = self.base / 'ws/aosp'
        self.state = self.root / '.lepton-clean14-state'
        self.state.mkdir(parents=True)
        write(self.root / '.lepton-clean14-owner', 'fixture\n')
        for marker in ('sync.done', 'vendor.done', 'patches.done', 'patches.started'):
            write(self.state / marker)
        self.projects = ['prebuilts/clang/host/linux-x86', 'frameworks/native', 'hardware/waydroid']
        self.revisions = {}
        for index, name in enumerate(self.projects):
            path = self.root / name
            path.mkdir(parents=True)
            if index == 1:
                store = self.root / '.repo/projects' / (name + '.git')
                store.parent.mkdir(parents=True)
                git(path, 'init', '-q', '--separate-git-dir', str(store))
            elif index == 2:
                git(self.root / self.projects[1], 'worktree', 'add', '-q', '--detach', str(path))
            else:
                git(path, 'init', '-q')
            write(path / 'tracked', 'pinned\n')
            git(path, 'add', '.')
            if index != 2:
                git(path, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@localhost', 'commit', '-qm', 'pinned')
            self.revisions[name] = git(path, 'rev-parse', 'HEAD')
            write(path / 'tracked', 'interrupted patch\n')
            write(path / 'untracked', 'interrupted vendoring\n')
        write(self.root / '.repo/project.list', '\n'.join(self.projects) + '\n')
        write(self.root / '.repo/manifest.xml', '<manifest/>')
        write(self.root / '.lepton-resolved-manifest.xml', '<manifest>' + ''.join(
            f'<project path="{p}" revision="{r}"/>' for p, r in self.revisions.items()) + '</manifest>')
        write(self.root / 'build/envsetup.sh', '''lunch() { :; }
m() {
  echo installclean >> "$RESET_TRACE"
  if [[ -e .lepton-clean14-state/hang-installclean ]]; then
    touch .lepton-clean14-state/installclean.running
    while :; do sleep 0.1; done
  fi
  [[ ! -e .lepton-clean14-state/fail-installclean ]]
}
''')
        # Exercise the exact repo forall shell passed by reset-sources.sh.
        write(self.root / '.repo/repo/repo', '''#!/usr/bin/env python3
import os, pathlib, subprocess, sys
root = pathlib.Path.cwd()
if sys.argv[1] == 'forall':
    command = sys.argv[sys.argv.index('-c') + 1]
    for name in (root / '.repo/project.list').read_text().splitlines():
        revision = (root / '.lepton-clean14-state/revisions' / name.replace('/', '_')).read_text().strip()
        env = dict(os.environ, REPO_PATH=name, REPO_LREV=revision)
        if (root / '.lepton-clean14-state/fail-project').exists() and name.startswith('frameworks'):
            env['REPO_LREV'] = 'missing-revision'
        result = subprocess.run(['bash', '-c', command], cwd=root / name, env=env)
        if result.returncode: sys.exit(result.returncode)
else:
    raise SystemExit('Unexpected repo operation (no downloads allowed): ' + repr(sys.argv))
''', True)
        for name, revision in self.revisions.items():
            write(self.state / 'revisions' / name.replace('/', '_'), revision)
        write(self.root / 'out/soong/keep.o', 'compiled intermediate\n')
        self.env = dict(os.environ, RESET_TRACE=str(self.base / 'trace'))

    def checker_source(self):
        return (SCRIPTS / 'internal/recover-source-locks.py').read_text().replace(
            "proc = Path('/proc')", f"proc = Path({str(self.proc)!r})")

    def track_process(self, pid):
        link = self.proc / str(pid)
        if not link.exists():
            link.symlink_to(f'/proc/{pid}', target_is_directory=True)

    def lock(self, name=None, old=True):
        project = self.root / (name or self.projects[0])
        path = Path(git(project, 'rev-parse', '--path-format=absolute', '--git-path', 'index.lock'))
        write(path)
        if old:
            os.utime(path, (time.time() - 120,) * 2)
        return path

    def recover(self, success=True):
        result = subprocess.run(['python3', '-B', str(self.checker), str(self.root)],
                                text=True, capture_output=True, env=self.env)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def prepare_fixture(self):
        fake = self.base / 'source'
        for name in ('prepare-x86_64.sh', 'lib/workspace.sh', 'internal/recover-source-locks.py', 'internal/reset-sources.sh'):
            dest = fake / 'image-14/scripts' / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(SCRIPTS / name, dest)
        write(fake / 'image-14/scripts/internal/recover-source-locks.py', self.checker_source())
        # Required local inputs, without copying any Android source.
        source = (SCRIPTS / 'prepare-x86_64.sh').read_text()
        import re
        for name in re.findall(r'"\$IMAGE/([^"$]+)"', source):
            if name.endswith(('.sh', '.patch', '.h')) and not (fake / 'image-14' / name).exists():
                write(fake / 'image-14' / name)
        for name in ('00-remotes', '01-removes', '02-waydroid', '10-valve-remotes', '11-removes', '12-valve-replacements'):
            write(fake / f'image-14/android_vendor_valve/manifest_scripts/manifests-34/{name}.xml')
        write(fake / '.build-env', f'LEPTON_OUTPUT_DIR={shlex.quote(str(self.root.parent))}\n'
              'LEPTON_BUILD_TARGET=aosp_lepton_x86_64-ap2a-userdebug\nLEPTON_BUILD_JOBS=1\nLEPTON_MIN_FREE_GIB=0\n')
        binary = self.base / 'bin'
        write(binary / 'rsync', '#!/bin/sh\nexit 0\n', True)
        write(binary / 'git', f'''#!/bin/bash
if [[ "$1" == -C && "$2" == "$FAKE_SOURCE" && "$3" == submodule ]]; then
  [[ "$4" != status ]] || echo ' fixture pinned-submodule'
  exit 0
fi
if [[ "$1" == -C && "$2" == "$FAKE_SOURCE" && "$3" == rev-parse ]]; then echo fixture; exit 0; fi
if [[ "$1" == -C && "$2" == "$FAKE_SOURCE/image-14/"* && "$3" == status ]]; then exit 0; fi
exec {shlex.quote(REAL_GIT)} "$@"
''', True)
        # Only the Android copy/patch/build environment is synthetic. Run the
        # actual reset script and its real Git operations, preserving errors.
        write(binary / 'podman', '''#!/bin/bash
set -eu
[[ "$1" == run ]] || exit 0
input=$(cat)
if [[ "$input" == *reset-sources.sh* ]]; then
  bash "$FAKE_SOURCE/image-14/scripts/internal/reset-sources.sh" "$FAKE_AOSP"
elif [[ "$input" == *copy_vendored_projects.sh* ]]; then
  [[ ! -e "$FAKE_AOSP/.lepton-clean14-state/fail-vendor" ]]
else
  [[ ! -e "$FAKE_AOSP/.lepton-clean14-state/fail-patch" ]]
fi
''', True)
        self.env.update(PATH=str(binary) + ':' + os.environ['PATH'], FAKE_SOURCE=str(fake), FAKE_AOSP=str(self.root))
        return fake / 'image-14/scripts/prepare-x86_64.sh'

    def prepare(self, script, action='--reset', success=True):
        result = subprocess.run(['bash', str(script), action], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def test_stale_gitfile_worktree_and_unrelated_files(self):
        locks = [self.lock(p) for p in self.projects]
        unrelated = self.base / 'other'
        unrelated.mkdir()
        git(unrelated, 'init', '-q')
        keep = [unrelated / '.git/index.lock', self.root / 'random.lock', self.root / self.projects[0] / '.git/HEAD.lock']
        for path in keep: write(path, 'untouched')
        output = self.recover()
        self.assertIn(self.revisions[self.projects[0]], output)
        for path in locks: self.assertFalse(path.exists())
        for path in keep: self.assertEqual(path.read_text(), 'untouched')

    def test_active_git_in_other_checkout_is_not_killed(self):
        lock = self.lock()
        # Conservatively refuse unrelated Git too; never kill it or touch its files.
        other = self.base / 'unrelated'
        other.mkdir()
        git(other, 'init', '-q')
        child = subprocess.Popen([REAL_GIT, '-C', str(other), 'hash-object', '--stdin'],
                                 stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
        try:
            self.track_process(child.pid)
            time.sleep(0.1)
            self.assertIn('Active Git/repo operation PID', self.recover(False))
            self.assertTrue(lock.exists())
            self.assertIsNone(child.poll())
        finally:
            child.terminate()
            child.wait()
            child.stdin.close()

    def test_active_python_repo_launcher(self):
        lock = self.lock()
        launcher = self.root / '.repo/repo/main.py'
        write(launcher, 'import time; time.sleep(30)\n')
        child = subprocess.Popen(['python3', str(launcher)])
        try:
            self.track_process(child.pid)
            time.sleep(0.05)
            self.assertIn('Active Git/repo operation PID', self.recover(False))
            self.assertTrue(lock.exists())
            self.assertIsNone(child.poll())
        finally:
            child.terminate()
            child.wait()

    def test_workflow_serialization(self):
        script = self.prepare_fixture()
        lock = self.root.parent / 'logs/prepare.lock'
        lock.parent.mkdir()
        with lock.open('w') as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertIn('Another preparation operation', self.prepare(script, success=False))
        self.assertFalse((self.state / 'reset.started').exists())

    def test_non_git_lock_holder_and_fresh_lock(self):
        lock = self.lock()
        with lock.open('r'):
            self.assertIn('held open by PID', self.recover(False))
        fresh = self.lock(old=False)
        self.assertIn('less than 60 seconds', self.recover(False))
        self.assertTrue(fresh.exists())

    def test_ambiguous_proc_and_symlink_locks(self):
        lock = self.lock()
        with patch.object(recovery.Path, 'read_bytes', side_effect=PermissionError('proc restricted')):
            with self.assertRaisesRegex(recovery.Unsafe, 'Cannot inspect host process'):
                recovery.recover(self.root)
        self.assertTrue(lock.exists())
        lock.unlink()
        outside = self.base / 'precious'
        write(outside, 'keep')
        lock.symlink_to(outside)
        self.assertIn('Not a regular', self.recover(False))
        self.assertEqual(outside.read_text(), 'keep')

    def test_external_gitdir_and_unmarked_checkout_refused(self):
        project = self.root / self.projects[1]
        store = self.base / 'outside.git'
        shutil.move(str(self.root / '.repo/projects' / (self.projects[1] + '.git')), store)
        write(project / '.git', f'gitdir: {store}\n')
        write(store / 'index.lock')
        self.assertIn('External Git directory', self.recover(False))
        self.assertTrue((store / 'index.lock').exists())
        (self.root / '.lepton-clean14-owner').unlink()
        self.assertIn('Unmarked checkout', self.recover(False))

    def test_interrupted_am_with_stale_lock(self):
        script = self.prepare_fixture()
        project = self.root / self.projects[0]
        git(project, 'reset', '--hard', 'HEAD')
        patch_text = git(project, 'format-patch', '-1', '--stdout') + '\n'
        result = subprocess.run([REAL_GIT, '-C', str(project), '-c', 'user.name=Fixture',
                                 '-c', 'user.email=fixture@localhost', 'am'],
                                input=patch_text, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((project / '.git/rebase-apply').is_dir())
        self.lock()
        self.prepare(script)
        self.assertFalse((project / '.git/rebase-apply').exists())

    def test_broken_gitfile_local_store_lock(self):
        project = self.root / self.projects[1]
        lock = self.lock(self.projects[1])
        write(project / '.git', 'gitdir: /missing/old/vendor/submodule\n')
        self.assertIn('[RECOVERED]', self.recover())
        self.assertFalse(lock.exists())

    def test_unsafe_project_inventory(self):
        outside = self.base / 'outside'
        write(outside / 'keep', 'safe')
        write(self.root / '.repo/project.list', '../outside\n')
        self.assertIn('Unsafe managed project path', self.recover(False))
        self.assertEqual((outside / 'keep').read_text(), 'safe')

    def test_sigterm_reset_then_successful_retry(self):
        script = self.prepare_fixture()
        write(self.state / 'hang-installclean')
        with (self.base / 'interrupted.log').open('w') as log:
            child = subprocess.Popen(['bash', str(script), '--reset'], env=self.env,
                                     stdout=log, stderr=log, start_new_session=True)
            try:
                for _ in range(200):
                    if (self.state / 'installclean.running').exists() or child.poll() is not None:
                        break
                    time.sleep(0.01)
                self.assertTrue((self.state / 'installclean.running').exists(),
                                (self.base / 'interrupted.log').read_text())
            finally:
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGTERM)  # only our synthetic test group
                child.wait()
        self.assertNotEqual(child.returncode, 0)
        self.assertTrue((self.state / 'reset.started').exists())
        self.assertTrue((self.state / 'patches.done').exists())
        (self.state / 'hang-installclean').unlink()
        self.lock()
        self.prepare(script)
        self.assertFalse((self.state / 'reset.started').exists())
        self.assertTrue((self.state / 'patches.done').exists())

    def test_all_locks_validated_before_any_removal(self):
        old = self.lock()
        fresh = self.lock(self.projects[1], old=False)
        self.recover(False)
        self.assertTrue(old.exists())
        self.assertTrue(fresh.exists())

    def test_changed_lock_is_preserved(self):
        lock = self.lock()
        calls = 0
        def racing_operation(locks):
            nonlocal calls
            calls += 1
            if calls == 2:
                lock.write_text('new owner')
        with patch.object(recovery, 'check_processes', side_effect=racing_operation):
            with self.assertRaisesRegex(recovery.Unsafe, 'changed during inspection'):
                recovery.recover(self.root)
        self.assertEqual(lock.read_text(), 'new owner')

    def test_repeated_reset_failures_then_resume_success(self):
        script = self.prepare_fixture()
        self.lock()
        write(self.state / 'fail-project')
        output = self.prepare(script, success=False)
        for text in ('frameworks/native', 'git reset --hard', 'missing-revision', 'index.lock', 'fatal:'):
            self.assertIn(text, output)
        self.assertTrue((self.state / 'reset.started').exists())
        for marker in ('sync.done', 'vendor.done', 'patches.done', 'patches.started'):
            self.assertTrue((self.state / marker).exists())
        self.assertIn('Reset was interrupted', self.prepare(script, '--resume', False))
        # Another interruption after all project resets, inside installclean.
        (self.state / 'fail-project').unlink()
        self.lock(self.projects[1])
        write(self.state / 'fail-installclean')
        self.prepare(script, success=False)
        self.assertTrue((self.state / 'reset.started').exists())
        self.assertTrue((self.state / 'patches.started').exists())
        (self.state / 'fail-installclean').unlink()
        # Reset succeeds; vendoring fails. Resume may now safely continue.
        write(self.state / 'fail-vendor')
        self.prepare(script, success=False)
        self.assertFalse((self.state / 'reset.started').exists())
        self.assertFalse((self.state / 'vendor.done').exists())
        self.assertFalse((self.state / 'patches.done').exists())
        (self.state / 'fail-vendor').unlink()
        self.prepare(script, '--resume')
        self.assertTrue((self.state / 'patches.done').exists())
        self.assertFalse((self.state / 'patches.started').exists())
        self.assertEqual((self.root / 'out/soong/keep.o').read_text(), 'compiled intermediate\n')
        for name in self.projects:
            self.assertEqual(git(self.root / name, 'rev-parse', 'HEAD'), self.revisions[name])
            self.assertEqual(git(self.root / name, 'status', '--porcelain'), '')


if __name__ == '__main__':
    unittest.main()
