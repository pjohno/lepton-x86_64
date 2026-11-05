#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Exercise CI packaging and wrapper/child integration without building Android."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def write(path, text, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    if executable:
        path.chmod(0o755)


class BuildIntegrationTests(unittest.TestCase):
    def test_ci_archive_loads_runtime_without_optional_ndk_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            script = repo / '.ci_scripts/build-compat_tool.sh'
            write(script, (ROOT / '.ci_scripts/build-compat_tool.sh').read_text())
            library = repo / 'compat_tool/liblepton'
            for source in (ROOT / 'compat_tool/liblepton').glob('*.sh'):
                write(library / source.name, source.read_text())
            write(library / 'soreplacements.txt',
                  (ROOT / 'compat_tool/liblepton/soreplacements.txt').read_text())
            write(library / 'ndk_auxv/runtime.sh',
                  (ROOT / 'compat_tool/liblepton/ndk_auxv/runtime.sh').read_text())
            for path in ('compat_tool/lepton', 'compat_tool/toolmanifest.vdf',
                         'README.md', 'LICENSE.md', 'LICENSES/fixture',
                         'compat_tool/liblepton/lepton.seccomp.json',
                         'compat_tool/liblepton/openvrpaths.vrpath',
                         'compat_tool/liblepton/perfetto/fixture',
                         'compat_tool/images/rootfs_overlay/fixture',
                         'compat_tool/liblepton/apk_extractor/bin/apk-info-extractor'):
                write(repo / path, 'fixture\n')
            write(repo / 'bin/make', '#!/bin/sh\nexit 0\n', True)
            write(repo / 'bin/git', '#!/bin/sh\necho fixture\n', True)
            env = {**os.environ, 'PATH': str(repo / 'bin') + ':' + os.environ['PATH']}
            subprocess.run(['bash', str(script)], cwd=repo, env=env,
                           check=True, capture_output=True, text=True)
            extracted = repo / 'extracted'
            extracted.mkdir()
            subprocess.run(['tar', '-xf', str(repo / 'compat_tool.tar.zst'),
                            '-C', str(extracted)], check=True, capture_output=True)
            result = subprocess.run([
                'bash', '-euc', 'source "$1"; declare -F configure_ndk_compat',
                '--', str(extracted / 'liblepton/liblepton.sh')],
                check=True, capture_output=True, text=True)
            self.assertIn('configure_ndk_compat', result.stdout)
            self.assertFalse((extracted / 'liblepton/ndk_auxv/bin').exists())

    def test_wrapper_passes_builder_to_all_children(self):
        for explicit in (False, True):
            with self.subTest(explicit_setting=explicit), tempfile.TemporaryDirectory() as directory:
                repo = Path(directory) / 'repo'
                wrapper = repo / 'image-14/do_build_x86_64.sh'
                # Simulate an accessible FUSE device on hosts without /dev/fuse.
                write(wrapper, (ROOT / 'image-14/do_build_x86_64.sh').read_text()
                      .replace('/dev/fuse', '/dev/null'))
                config = (f'LEPTON_OUTPUT_DIR={shlex.quote(str(Path(directory) / "output"))}\n'
                          f'LEPTON_LOG_DIR={shlex.quote(str(Path(directory) / "logs"))}\n'
                          'LEPTON_BUILD_TARGET=aosp_lepton_x86_64-ap2a-userdebug\n')
                if explicit:
                    config += 'LEPTON_BUILD_CONTAINER=lepton-builder-ubuntu26:latest\n'
                write(repo / '.build-env', config)
                for name in ('Containerfile.ubuntu26', 'Containerfile.deck-tools'):
                    write(repo / 'image-14/.buildscripts_x86_64' / name, 'fixture\n')
                write(repo / 'image-14/scripts/internal/provision-deck-tools.sh', '# fixture\n')
                for name in ('preflight-x86_64.sh', 'prepare-x86_64.sh', 'build-images-x86_64.sh'):
                    source = (ROOT / 'image-14/scripts' / name).read_text()
                    selection = next(line for line in source.splitlines() if line.startswith('BUILDER='))
                    # Preserve each real child's config loading and builder default,
                    # replacing Android operations with an assertion at the boundary.
                    write(repo / 'image-14/scripts' / name,
                          '#!/bin/bash\nset -eu\n'
                          'source "$(dirname "$0")/../../.build-env"\n'
                          + selection + '\n'
                          '[[ "$BUILDER" == lepton-builder-ubuntu26:latest ]]\n'
                          'printf "%s %s\\n" "${0##*/}" "$1" >> "$CHILD_TRACE"\n'
                          + ('exit 73\n' if name == 'build-images-x86_64.sh' else ''))
                # Dependency probes and Podman image lookups must stay offline.
                for name in ('podman', 'rsync', 'df', 'curl', 'unzip', 'make', 'cargo',
                             'cc', 'weston', 'systemctl', 'getfattr', 'setfattr',
                             'timeout', 'flock', 'fuse-overlayfs', 'simg2img',
                             'sqfs2tar', 'fuse2fs', 'fusermount3', 'tar', 'gzip'):
                    write(repo / 'bin' / name, '#!/bin/sh\nexit 0\n', True)
                write(repo / 'bin/git', '#!/bin/sh\necho fixture\n', True)
                trace = repo / 'children'
                env = {**os.environ, 'PATH': str(repo / 'bin') + ':' + os.environ['PATH'],
                       'CHILD_TRACE': str(trace)}
                env.pop('LEPTON_BUILD_CONTAINER', None)
                result = subprocess.run(['bash', str(wrapper), '--execute', '--bundle-id', 'fixture'],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 73, result.stdout + result.stderr)
                self.assertEqual(trace.read_text().splitlines(), [
                    'preflight-x86_64.sh fresh', 'prepare-x86_64.sh --check',
                    'prepare-x86_64.sh --execute', 'preflight-x86_64.sh existing',
                    'build-images-x86_64.sh --check'])


if __name__ == '__main__':
    unittest.main()
