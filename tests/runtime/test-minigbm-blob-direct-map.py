#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Patch 0016: gbm_mesa maps 1D (BLOB) buffers with a direct dma-buf mmap.

gbm_bo_map returns a staging copy on iris and radeonsi that reaches the buffer
only at unmap. Codec2 keeps the writer's mapping open while the decoder in
another process reads the block, so the decoder read stale bytes (dropouts on
Intel). This applies 0004, 0014 and 0016 to the gralloc source and checks the
1D mapping path; tests/runtime/gbm-blob-coherence.c shows the driver behaviour
on a host (DIRECT=1 for the 0016 mapping).
"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PATCHES = ROOT / 'image-14/patches'
BASE = PATCHES / '0004-minigbm-gbm-mesa-driver.patch'
SURFACE = PATCHES / '0014-minigbm-gbm-mesa-blob-cpu-surface.patch'
FIX = PATCHES / '0016-minigbm-gbm-mesa-blob-direct-map.patch'
INTERNALS = 'gbm_mesa_driver/gbm_mesa_internals.cpp'


def function_body(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n}\n', start) + 3]


class BlobDirectMapTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tree = Path(temp.name)
        subprocess.run(['git', 'apply', '--no-index', '--include', INTERNALS, str(BASE)],
                       cwd=self.tree, check=True)
        subprocess.run(['git', 'apply', '--no-index', str(SURFACE)], cwd=self.tree, check=True)
        subprocess.run(['git', 'apply', '--no-index', str(FIX)], cwd=self.tree, check=True)
        self.src = (self.tree / INTERNALS).read_text()

    def test_1d_buffers_map_the_dma_buf_with_sync(self):
        body = function_body(self.src, 'void *gbm_mesa_bo_map(')
        direct = body.index('if (gbm_mesa_is_1d(')
        # The direct path comes before any Mesa map or null-bo bail-out.
        self.assertLess(direct, body.index('if (priv->gbm_bo == nullptr)'))
        self.assertLess(direct, body.index('wr->map('))
        self.assertIn('mmap(nullptr, vma->length, drv_get_prot(map_flags), MAP_SHARED, fd, 0)', body)
        self.assertIn('DMA_BUF_SYNC_START', body)
        self.assertIn('vma->priv = &gbm_mesa_direct_map_tag;', body)
        # A failed mmap falls back to the Mesa map instead of failing the lock.
        self.assertIn('using a Mesa map', body)

    def test_unmap_ends_sync_before_the_mesa_path(self):
        body = function_body(self.src, 'int gbm_mesa_bo_unmap(')
        tag = body.index('if (vma->priv == &gbm_mesa_direct_map_tag)')
        self.assertLess(tag, body.index('assert(priv->gbm_bo != nullptr);'))
        block = body[tag:body.index('return 0;', tag)]
        self.assertIn('DMA_BUF_SYNC_END', block)
        self.assertIn('munmap(vma->addr, vma->length);', block)

    @unittest.skipUnless(shutil.which('c++'), 'needs a C++ compiler')
    def test_only_1d_buffers_take_the_direct_path(self):
        helper = function_body(self.src, 'static bool gbm_mesa_is_1d(')
        program = ('#include <cstdint>\n#include <cstdio>\n#define DRM_FORMAT_R8 0x20203852u\n'
                   f'{helper}\nint main() {{\n'
                   '  printf("%d %d %d %d %d\\n", gbm_mesa_is_1d(true, DRM_FORMAT_R8, 1),\n'
                   '         gbm_mesa_is_1d(false, 0x34325241u, 1080), gbm_mesa_is_1d(true, DRM_FORMAT_R8, 64),\n'
                   '         gbm_mesa_is_1d(true, 0x34325241u, 1), gbm_mesa_is_1d(true, 0x32315659u, 480));\n}\n')
        (self.tree / 'p.cpp').write_text(program)
        subprocess.run(['c++', '-std=c++17', '-Wall', '-Werror', '-o', 'p', 'p.cpp'], cwd=self.tree, check=True)
        out = subprocess.run([str(self.tree / 'p')], capture_output=True, text=True, check=True).stdout.split()
        # BLOB yes, spoofed format yes, R8 image no, RGBA row no, YV12 no.
        self.assertEqual(out, ['1', '1', '0', '0', '0'])

    def test_registered_after_0014_and_0015(self):
        prepare = (ROOT / 'image-14/scripts/prepare-x86_64.sh').read_text()
        provenance = (ROOT / 'image-14/scripts/lib/image-provenance.sh').read_text()
        self.assertIn(f'apply_custom /workspace/output/external/minigbm /workspace/patches/{FIX.name}', prepare)
        self.assertIn(f'"$IMAGE/patches/{FIX.name}"', prepare)
        self.assertIn(f'"external/minigbm|{FIX.name}"', provenance)
        applies = re.findall(r'^apply_custom \S+ /workspace/patches/(\S+)', prepare, flags=re.M)
        self.assertLess(applies.index(SURFACE.name), applies.index(FIX.name))
        self.assertLess(applies.index('0015-libopus-float-decode-x86_64.patch'), applies.index(FIX.name))


if __name__ == '__main__':
    unittest.main()
