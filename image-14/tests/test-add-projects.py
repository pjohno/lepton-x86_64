#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""prepare-x86_64.sh --add-projects: the host-side plan and retirement rules
(scripts/internal/add-projects.py). Fake checkout; no repo or network."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / 'image-14/scripts/internal/add-projects.py'
PROVENANCE = '''LEPTON_COPIED_TREES=(
    "image-14/android_hardware_waydroid|hardware/waydroid"
)
LEPTON_CUSTOM_PATCHES=(
    "external/minigbm|0004-minigbm-gbm-mesa-driver.patch"
)
'''
OLD = '<manifest>\n  <project path="hardware/intel/common/libva" name="WayDroid/libva" revision="lineage-18.1" />\n</manifest>\n'


def git(path, *args):
    subprocess.run(['git', '-C', str(path), *args], check=True, capture_output=True)


class AddProjectsTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        base = Path(temp.name)
        self.repo, self.aosp, self.retire = base / 'manifests', base / 'aosp', base / 'retired'
        self.plan = base / 'plan'
        self.repo.mkdir()
        (self.aosp / '.repo/local_manifests').mkdir(parents=True)
        (self.repo / '02-waydroid.xml').write_text(OLD)
        (self.aosp / '.repo/local_manifests/02-waydroid.xml').write_text(OLD)
        self.copied = self.aosp / 'vendor/extra/manifest_scripts/manifests'
        self.copied.mkdir(parents=True)
        (self.copied / '02-waydroid.xml').write_text(OLD)
        (self.aosp / '.lepton-resolved-manifest.xml').write_text(
            '<manifest>\n'
            '  <project path="hardware/intel/common/libva" name="WayDroid/libva" revision="abc" />\n'
            '  <project path="external/minigbm" name="platform/external/minigbm" revision="def" />\n'
            '  <project path="hardware/waydroid" name="waydroid/hw" revision="012" />\n'
            '</manifest>\n')
        for path in ('hardware/intel/common/libva', 'external/minigbm', 'hardware/waydroid'):
            tree = self.aosp / path
            tree.mkdir(parents=True)
            (tree / 'Android.mk').write_text('# module\n')
            git(tree, 'init', '-q')
            git(tree, 'add', '-A')
            git(tree, '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', 'commit', '-qm', 'base')
        self.provenance = base / 'image-provenance.sh'
        self.provenance.write_text(PROVENANCE)

    def run_tool(self, *extra, execute=True):
        args = ['python3', '-B', str(TOOL), '--manifests', str(self.repo), '--checkout', str(self.aosp),
                '--provenance', str(self.provenance), '--retire-root', str(self.retire), '--plan', str(self.plan)]
        return subprocess.run(args + (['--execute'] if execute else []) + list(extra),
                              capture_output=True, text=True)

    def add(self, body):
        (self.repo / '20-video.xml').write_text('<manifest>\n' + body + '</manifest>\n')

    def test_nothing_new_leaves_an_empty_plan(self):
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.plan.read_text(), '')

    def test_changed_installed_manifest_is_refused(self):
        (self.repo / '02-waydroid.xml').write_text(OLD.replace('lineage-18.1', 'lineage-21'))
        result = self.run_tool()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Changed local manifest', result.stderr)

    def test_new_projects_and_retirement(self):
        self.add('  <remove-project name="WayDroid/libva" />\n'
                 '  <project path="external/libva" name="ATV/libva" revision="e575c67" />\n'
                 '  <project path="external/ffmpeg" name="ATV/ffmpeg" revision="0b23ebd" />\n')
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = self.plan.read_text().splitlines()
        self.assertIn('manifest 20-video.xml', plan)
        # vendor/extra is Lepton's copied tree of the manifests' folder.
        self.assertIn('mirror 20-video.xml', plan)
        self.assertIn('project external/libva', plan)
        self.assertIn('project external/ffmpeg', plan)
        # Moved, not deleted: the module file survives outside the checkout.
        self.assertFalse((self.aosp / 'hardware/intel/common/libva').exists())
        moved = list(self.retire.glob('*/hardware/intel/common/libva/Android.mk'))
        self.assertEqual(len(moved), 1)
        # A rerun after an interrupted container stage plans the same work.
        rerun = self.run_tool()
        self.assertEqual(rerun.returncode, 0, rerun.stderr)
        self.assertIn('project external/libva', self.plan.read_text())

    def test_installed_but_unmirrored_manifest_is_mirrored(self):
        (self.repo / '20-video.xml').write_text('<manifest />\n')
        (self.aosp / '.repo/local_manifests/20-video.xml').write_text('<manifest />\n')
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.plan.read_text().splitlines(), ['mirror 20-video.xml'])

    def test_changed_copied_manifest_is_refused(self):
        (self.copied / '02-waydroid.xml').write_text('<manifest />\n')
        result = self.run_tool()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Changed copied manifest', result.stderr)

    def test_plan_only_moves_nothing(self):
        self.add('  <remove-project name="WayDroid/libva" />\n'
                 '  <project path="external/libva" name="ATV/libva" revision="e575c67" />\n')
        result = self.run_tool(execute=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.aosp / 'hardware/intel/common/libva/Android.mk').exists())

    def test_dirty_project_is_not_retired(self):
        (self.aosp / 'hardware/intel/common/libva/Android.mk').write_text('# local edit\n')
        self.add('  <remove-project name="WayDroid/libva" />\n'
                 '  <project path="external/libva" name="ATV/libva" revision="e575c67" />\n')
        result = self.run_tool()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('local changes', result.stderr)
        self.assertTrue((self.aosp / 'hardware/intel/common/libva').exists())

    def test_patched_or_copied_projects_are_protected(self):
        for name in ('platform/external/minigbm', 'waydroid/hw'):
            self.add(f'  <remove-project name="{name}" />\n')
            result = self.run_tool()
            self.assertNotEqual(result.returncode, 0, name)
            self.assertIn('copied into or patched by Lepton', result.stderr)

    def test_same_path_replacement_is_refused(self):
        self.add('  <remove-project name="WayDroid/libva" />\n'
                 '  <project path="hardware/intel/common/libva" name="ATV/libva" revision="e575c67" />\n')
        result = self.run_tool()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('new path', result.stderr)
        self.assertTrue((self.aosp / 'hardware/intel/common/libva').exists())

    def test_existing_path_and_unpinned_projects_are_refused(self):
        self.add('  <project path="external/minigbm" name="other/minigbm" revision="1" />\n')
        self.assertIn('already belongs', self.run_tool().stderr)
        self.add('  <project path="external/ffmpeg" name="ATV/ffmpeg" />\n')
        self.assertIn('must pin a revision', self.run_tool().stderr)

    def test_retire_root_inside_checkout_is_refused(self):
        self.retire = self.aosp / 'attic'
        self.add('  <project path="external/ffmpeg" name="ATV/ffmpeg" revision="0b23ebd" />\n')
        result = self.run_tool()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('outside the checkout', result.stderr)


if __name__ == '__main__':
    unittest.main()
