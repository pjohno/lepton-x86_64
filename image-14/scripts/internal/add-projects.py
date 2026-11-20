#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Plan (and with --execute, apply the host side of) adding Android projects
to an already prepared checkout: prepare-x86_64.sh --add-projects.

Only NEW local manifest files may be added; an installed local manifest that
differs from the repository is refused, as the normal sync stage refuses it.
A new manifest may <remove-project> an existing project (to replace it at a
new path). Such a project is retired by MOVING its worktree out of the
source tree, never deleted, and only when it is clean and no Lepton patch or
copied folder touches it.

Writes a plan file for the container stage:
    manifest <file name>      new local manifest to install
    project <path>            project to sync
    retired <path> <dest>     worktree moved out of the tree (with --execute)
"""
import argparse
import datetime
import filecmp
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def fail(message):
    sys.exit(f'ERROR: {message}')


def protected_paths(provenance):
    """Checkout paths Lepton copies into or patches (image-provenance.sh)."""
    text = Path(provenance).read_text()
    paths = set()
    for array in ('LEPTON_COPIED_TREES', 'LEPTON_CUSTOM_PATCHES'):
        block = re.search(array + r'=\((.*?)\n\)', text, flags=re.S)
        for entry in re.findall(r'"([^"]+)"', block.group(1) if block else ''):
            paths.add(entry.split('|')[1] if array == 'LEPTON_COPIED_TREES' else entry.split('|')[0])
    return paths


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--manifests', required=True, help='repository manifests-34 directory')
    parser.add_argument('--checkout', required=True, help='prepared AOSP checkout')
    parser.add_argument('--provenance', required=True, help='image-provenance.sh')
    parser.add_argument('--retire-root', required=True, help='directory outside the checkout')
    parser.add_argument('--plan', required=True, help='plan file to write')
    parser.add_argument('--execute', action='store_true', help='move retired worktrees')
    args = parser.parse_args()

    checkout = Path(args.checkout).resolve()
    retire_root = Path(args.retire_root).resolve()
    if retire_root == checkout or checkout in retire_root.parents:
        fail('Retired projects must go outside the checkout')
    installed = checkout / '.repo/local_manifests'
    resolved = checkout / '.lepton-resolved-manifest.xml'
    if not installed.is_dir() or not resolved.is_file():
        fail('Checkout has no installed local manifests or resolved manifest')

    new = []
    for source in sorted(Path(args.manifests).glob('*.xml')):
        destination = installed / source.name
        if destination.exists():
            if not filecmp.cmp(source, destination, shallow=False):
                fail(f'Changed local manifest: {destination} (only new manifest files can be added)')
        else:
            new.append(source)
    if not new:
        print('Nothing to add: every repository manifest is already installed')
        Path(args.plan).write_text('')
        return

    by_name, by_path = {}, {}
    for project in ET.parse(resolved).getroot().iter('project'):
        path = project.get('path') or project.get('name')
        by_name[project.get('name')] = path
        by_path[path] = project.get('name')

    projects, retire = [], []
    for manifest in new:
        root = ET.parse(manifest).getroot()
        for removed in root.iter('remove-project'):
            name, path = removed.get('name'), removed.get('path')
            path = path or by_name.get(name)
            if not path or path not in by_path:
                fail(f'{manifest.name}: remove-project {name or path} is not in the checkout')
            retire.append(path)
        for project in root.iter('project'):
            path = project.get('path') or project.get('name')
            if path in by_path and path not in retire:
                fail(f'{manifest.name}: {path} already belongs to {by_path[path]}')
            if (checkout / path).exists() and path not in retire:
                fail(f'{manifest.name}: {path} already exists in the checkout')
            if not project.get('revision', '').strip():
                fail(f'{manifest.name}: {path} must pin a revision')
            projects.append(path)
    clash = set(retire) & set(projects)
    if clash:
        # Same path, different project: repo would need --force-sync. Refused.
        fail(f'Replacement must use a new path, not {sorted(clash)}')

    protected = protected_paths(args.provenance)
    for path in retire:
        if any(path == p or path.startswith(p + '/') or p.startswith(path + '/') for p in protected):
            fail(f'{path} is copied into or patched by Lepton; it cannot be retired')
        tree = checkout / path
        if tree.exists():
            status = subprocess.run(['git', '-C', str(tree), 'status', '--porcelain'],
                                    capture_output=True, text=True)
            if status.returncode != 0 or status.stdout.strip():
                fail(f'{path} has local changes or is not a Git worktree; inspect it first')

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    lines = [f'manifest {m.name}' for m in new] + [f'project {p}' for p in projects]
    for path in retire:
        tree = checkout / path
        destination = retire_root / stamp / path
        if args.execute and tree.exists():
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(tree), str(destination))
            print(f'[RETIRED] {path} -> {destination}')
        lines.append(f'retired {path} {destination}')
    for line in lines:
        print(f'[PLAN] {line}')
    Path(args.plan).write_text('\n'.join(lines) + '\n')


if __name__ == '__main__':
    main()
