#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Patch 0013: the gbm_mesa allocator never maps buffers itself.

The allocator used to map every CPU-usage buffer after creating it, only to
record an unused map stride. On AMD that map ran a radeonsi compute copy that
crashed the allocator as soon as Codec2 allocated BLOB buffers through gralloc
(Valve's pool mask), so Android stopped booting. This applies 0004 and 0013 to
the wrapper source and checks the result; the launcher's use of the marker is
covered by test-runtime-properties.sh.
"""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PATCHES = ROOT / 'image-14/patches'
BASE = PATCHES / '0004-minigbm-gbm-mesa-driver.patch'
FIX = PATCHES / '0013-minigbm-gbm-mesa-no-allocator-map.patch'
WRAPPER = 'gbm_mesa_driver/gbm_mesa_wrapper.cpp'
MARKER = 'lepton-gbm-allocator-no-map-probe'


def function_body(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n}\n', start)]


class NoAllocatorMapTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tree = Path(temp.name)
        # 0004 creates the wrapper as a new file, so it can be applied alone.
        subprocess.run(['git', 'apply', '--no-index', '--include', WRAPPER, str(BASE)],
                       cwd=self.tree, check=True)
        self.before = (self.tree / WRAPPER).read_text()
        subprocess.run(['git', 'apply', '--no-index', str(FIX)], cwd=self.tree, check=True)
        self.after = (self.tree / WRAPPER).read_text()

    def test_the_allocator_no_longer_maps(self):
        signature = 'static int gbm_mesa_alloc(struct alloc_args *args)'
        self.assertIn('gbm_bo_map(', function_body(self.before, signature), 'premise: 0004 mapped')
        body = function_body(self.after, signature)
        for call in ('gbm_bo_map(', 'gbm_bo_unmap(', 'gbm_bo_import('):
            self.assertNotIn(call, body)
        self.assertIn('args->out_map_stride = args->out_stride;', body)
        # The mapper still maps (CPU access in client processes is unchanged).
        self.assertIn('gbm_bo_map(', self.after.split('// MAPPER ONLY!', 1)[1])

    def test_marker_is_exported_for_the_launcher(self):
        self.assertRegex(self.after, r'visibility\("default"\), used\)\) const char\s+'
                                     r'lepton_gbm_allocator_no_map_probe\[\] = "' + MARKER + '";')
        launcher = (ROOT / 'compat_tool/liblepton/properties.sh').read_text()
        self.assertIn(f"LEPTON_GBM_NO_MAP_MARKER='{MARKER}'", launcher)

    def test_patch_reverses_and_is_registered_after_0004(self):
        subprocess.run(['git', 'apply', '--no-index', '--reverse', '--check', str(FIX)],
                       cwd=self.tree, check=True)
        prepare = (ROOT / 'image-14/scripts/prepare-x86_64.sh').read_text()
        provenance = (ROOT / 'image-14/scripts/lib/image-provenance.sh').read_text()
        self.assertIn(f'apply_custom /workspace/output/external/minigbm /workspace/patches/{FIX.name}', prepare)
        self.assertIn(f'"$IMAGE/patches/{FIX.name}"', prepare)
        self.assertIn(f'"external/minigbm|{FIX.name}"', provenance)
        applies = re.findall(r'^apply_custom \S+ /workspace/patches/(\S+)', prepare, flags=re.M)
        self.assertLess(applies.index(BASE.name), applies.index(FIX.name))


if __name__ == '__main__':
    unittest.main()
