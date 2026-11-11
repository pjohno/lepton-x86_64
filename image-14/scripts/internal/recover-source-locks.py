#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Host-side, fail-closed index.lock recovery for an owned repo checkout.

No process is killed. Run before any reset/repair in the container so /proc
includes host Git and rootless-container Git processes, not just our container.
"""
import os
from pathlib import Path
import stat
import subprocess
import sys
import time
import xml.etree.ElementTree as ET


class Unsafe(RuntimeError):
    pass


def git(project, *args):
    # Never let caller Git overrides redirect inspection to another checkout.
    env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    return subprocess.check_output(['git', '-C', str(project), *args], env=env,
                                   stderr=subprocess.PIPE, text=True).strip()


def inside(path, parent):
    return path == parent or parent in path.parents


def inventory(root):
    if not (root / '.lepton-clean14-owner').is_file():
        raise Unsafe('Unmarked checkout; refusing lock recovery')
    paths = (root / '.repo/project.list').read_text().splitlines()
    if not paths:
        raise Unsafe('Empty .repo/project.list; cannot inventory managed projects')
    revisions = {}
    manifest = root / '.lepton-resolved-manifest.xml'
    if manifest.exists():
        for project in ET.parse(manifest).getroot().iter('project'):
            revisions[project.get('path', project.get('name'))] = project.get('revision')
    for name in paths:
        if Path(name).parts and (Path(name).parts[0] in ('out', '.repo', '.git') or name == 'vendor'
                                 or Path(name).parts[0].startswith('.lepton-')):
            raise Unsafe(f'Unsafe managed project path: {name!r}')
    paths += [p for p in ('.repo/manifests', '.repo/repo') if (root / p / '.git').exists()]
    locks = {}
    for name in paths:
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts or name in ('', '.'):
            raise Unsafe(f'Unsafe managed project path: {name!r}')
        project = root / relative
        if not inside(project.resolve(), root):
            raise Unsafe(f'Project escapes checkout: {project}')
        try:
            # --git-path honours gitfiles, linked worktrees and repo gitdirs.
            if not (project / '.git').exists():
                raise subprocess.CalledProcessError(1, 'missing project .git')
            # Do not canonicalize the final component: --path-format=absolute
            # can follow an index.lock symlink and hide its unsafe type.
            lock = Path(git(project, 'rev-parse', '--git-path', 'index.lock'))
            if not lock.is_absolute():
                lock = project / lock
        except subprocess.CalledProcessError:
            # Older vendoring could overwrite .git. Inspect the local repo
            # store too, before the existing local-only repair recreates it.
            store = root / '.repo/projects' / (name + '.git')
            if not store.is_dir():
                raise Unsafe(f'Cannot resolve Git directory for {name}; inspect .git manually')
            lock = store / 'index.lock'
        # Only actual index locks in the managed project or repo store qualify.
        # Never follow a lock symlink or an external gitdir.
        parent = lock.parent.resolve()
        if not (inside(parent, root / '.repo') or inside(parent, project.resolve())):
            raise Unsafe(f'External Git directory for {name}: {lock}; inspect manually')
        lock = parent / lock.name
        if lock.exists() or lock.is_symlink():
            revision = revisions.get(name)
            if not revision:
                try:
                    revision = git(project, 'rev-parse', 'HEAD')
                except subprocess.CalledProcessError:
                    revision = 'unresolved (see pinned manifest / REPO_LREV)'
            print(f'INDEX LOCK: project={name} revision={revision} operation=git reset --hard lock={lock}', flush=True)
            locks[lock] = (name, lock.lstat())
    return locks


def fingerprint(st):
    return st.st_dev, st.st_ino, st.st_mode, st.st_uid, st.st_nlink, st.st_size, st.st_mtime_ns, st.st_ctime_ns


def check_processes(locks):
    proc = Path('/proc')
    if not (proc / 'self/stat').exists():
        raise Unsafe('Host /proc is unavailable; active operations cannot be ruled out')
    # A restricted proc mount cannot prove that other users/containers are idle.
    for line in (proc / 'mounts').read_text().splitlines():
        fields = line.split()
        if fields[1] == '/proc' and any(o.startswith('hidepid=') and o != 'hidepid=0' for o in fields[3].split(',')):
            raise Unsafe('Restricted host /proc (hidepid); inspect active operations manually')
    identities = {(st.st_dev, st.st_ino) for _, st in locks.values()}
    for entry in proc.iterdir():
        if not entry.name.isdigit() or int(entry.name) == os.getpid():
            continue
        try:
            comm = (entry / 'comm').read_text().strip()
            cmd = (entry / 'cmdline').read_bytes().split(b'\0')
            args = [os.fsdecode(a) for a in cmd if a]
            # Conservatively refuse even Git/repo in another checkout: -C,
            # GIT_DIR, shared object stores and child editors defeat cwd-only checks.
            operation = comm == 'git' or comm.startswith('git-') or comm == 'repo'
            operation |= any(Path(a).name == 'repo' or
                             (Path(a).name == 'main.py' and Path(a).parent.name == 'repo')
                             for a in args)
            if operation:
                raise Unsafe(f'Active Git/repo operation PID {entry.name} ({comm}); inspect ps -fp {entry.name}')
        except (FileNotFoundError, ProcessLookupError):
            continue
        except PermissionError as exc:
            # Without the command line, a Git/repo operation cannot be ruled out.
            raise Unsafe(f'Cannot inspect host process {entry.name}: {exc}') from exc
        # Open files only matter when there is a lock to look for. Non-dumpable
        # processes (ssh-agent, gpg-agent, keyring daemons, programs with file
        # capabilities) hide their fd lists even from their owner; they must not
        # block a reset of a checkout that has no index locks at all.
        if not identities:
            continue
        try:
            if entry.stat().st_uid != os.getuid():
                continue
            if not args:  # kernel task or exited/zombie process
                continue
            for fd in (entry / 'fd').iterdir():
                try:
                    st = fd.stat()
                    if (st.st_dev, st.st_ino) in identities:
                        raise Unsafe(f'Index lock held open by PID {entry.name} ({comm})')
                except FileNotFoundError:
                    pass
        except (FileNotFoundError, ProcessLookupError):
            continue
        except PermissionError as exc:
            raise Unsafe(f'Cannot inspect the open files of PID {entry.name} ({comm}) while index locks exist: {exc}. '
                         f'Check it with: ps -fp {entry.name}') from exc


def recover(root):
    locks = inventory(root)
    # Also refuse active Git/repo without a lock: a reset must not race sync.
    check_processes(locks)
    for lock, (_, st) in locks.items():
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_nlink != 1:
            raise Unsafe(f'Not a regular, solely linked, user-owned index lock: {lock}')
        if time.time() - st.st_mtime < 60:
            raise Unsafe(f'Index lock is less than 60 seconds old: {lock}; wait and retry')
    # Check all candidates before deleting any; recheck processes and identity
    # immediately before each unlink. No wildcard lock deletion, no retry loop
    # that could delete a lock newly created by a racing Git command.
    for lock, (_, st) in locks.items():
        check_processes(locks)
        if fingerprint(lock.lstat()) != fingerprint(st):
            raise Unsafe(f'Index lock changed during inspection: {lock}')
        lock.unlink()
        print(f'[RECOVERED] Removed stale index lock: {lock}', flush=True)


def main():
    try:
        recover(Path(sys.argv[1]).resolve(strict=True))
    except (Unsafe, OSError, ET.ParseError) as exc:
        print(f'ERROR: Unsafe to reset: {exc}', file=sys.stderr)
        print('Leave the reported lock in place. Inspect host and builder Git/repo processes '
              '(ps -ef / podman top); let them finish or stop only a verified operation yourself. '
              'Then rerun prepare-x86_64.sh --reset. Restore host /proc visibility if restricted. '
              'For manual lock recovery, '
              'verify all operations have stopped, resolve the project lock with '
              'git -C PROJECT rev-parse --path-format=absolute --git-path index.lock, '
              'and remove only that exact file after confirming it is stale. Never delete *.lock.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
