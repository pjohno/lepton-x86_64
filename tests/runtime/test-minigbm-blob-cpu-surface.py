#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Patch 0014: gbm_mesa imports and maps BLOB buffers as they were allocated.

gbm_mesa_bo_create allocates a 1D buffer (R8 x 1: Android BLOB, or a format gbm
cannot describe) as a linear 4096 x ceil(W/4096) R8 surface. Import and map
described it as W x 1 with the real 4096-byte stride. iris rejects that import,
so every Codec2 BLOB lock failed on Intel and media apps were silent (issue
#30). This applies 0004 and 0014, then compiles the patched geometry helper and
checks it against the allocation geometry. The launcher's use of the marker is
covered by test-runtime-properties.sh.
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
NO_MAP = PATCHES / '0013-minigbm-gbm-mesa-no-allocator-map.patch'
FIX = PATCHES / '0014-minigbm-gbm-mesa-blob-cpu-surface.patch'
INTERNALS = 'gbm_mesa_driver/gbm_mesa_internals.cpp'
MARKER = 'lepton-gbm-blob-cpu-surface'
R8, YV12, ARGB = 0x20203852, 0x32315659, 0x34325241


def function_body(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n}\n', start) + 3]


def allocated_surface(supported, fmt, width, height, total_size):
    """The surface gbm_mesa_bo_create allocates (mirrors its reshaping)."""
    if not supported:
        fmt, width, height = R8, total_size, 1
    if fmt == R8 and height == 1:
        return R8, 4096, -(-width // 4096)
    if fmt == YV12:
        return fmt, (-(-(width // 2) // 512)) * 512, height + -(-height // 2)
    return fmt, width, height


class BlobCpuSurfaceTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tree = Path(temp.name)
        # 0004 creates the internals as a new file, so it can be applied alone.
        subprocess.run(['git', 'apply', '--no-index', '--include', INTERNALS, str(BASE)],
                       cwd=self.tree, check=True)
        self.before = (self.tree / INTERNALS).read_text()
        subprocess.run(['git', 'apply', '--no-index', str(FIX)], cwd=self.tree, check=True)
        self.after = (self.tree / INTERNALS).read_text()

    def test_premise_import_used_a_row_wider_than_its_stride(self):
        body = function_body(self.before, 'int gbm_mesa_bo_import(')
        self.assertNotIn('DIV_ROUND_UP(s_width', body)
        self.assertIn('DIV_ROUND_UP(alloc_args.width, 4096)', self.before)

    def test_import_and_map_use_the_allocated_surface(self):
        for signature in ('int gbm_mesa_bo_import(', 'void *gbm_mesa_bo_map('):
            body = function_body(self.after, signature)
            self.assertIn('gbm_mesa_cpu_surface(', body, signature)
            self.assertNotIn('s_height = 1;', body, signature)
        create = function_body(self.after, 'int gbm_mesa_bo_create(')
        self.assertIn('DIV_ROUND_UP(alloc_args.width, GBM_MESA_1D_SURFACE_WIDTH)', create)
        # A failed CPU import is logged and never mapped as a null bo.
        self.assertIn('if (priv->gbm_bo == nullptr) {',
                      function_body(self.after, 'void *gbm_mesa_bo_map('))

    @unittest.skipUnless(shutil.which('c++'), 'needs a C++ compiler')
    def test_compiled_helper_matches_allocation(self):
        helper = function_body(self.after, 'static void gbm_mesa_cpu_surface(')
        cases = [(True, R8, w, 1, w) for w in (1, 4095, 4096, 4097, 8192, 65536, 1 << 20)]
        cases += [(False, ARGB, 0, 0, size) for size in (4096, 12288, 1 << 20)]
        cases += [(True, YV12, w, h, 0) for w, h in ((640, 480), (1920, 1080), (1000, 7))]
        cases += [(True, ARGB, 1920, 1080, 0), (True, R8, 64, 64, 0)]
        rows = ''.join('{%d,0x%xu,%du,%du,%du},' % (s, f, w, h, t) for s, f, w, h, t in cases)
        program = (
            '#include <cstdint>\n#include <cstdio>\n'
            f'#define DRM_FORMAT_R8 0x{R8:x}u\n#define DRM_FORMAT_YVU420_ANDROID 0x{YV12:x}u\n'
            '#define DIV_ROUND_UP(n, d) (((n) + (d) - 1) / (d))\n'
            '#define ALIGN(v, a) (((v) + (a) - 1) & ~((a) - 1))\n'
            '#define GBM_MESA_1D_SURFACE_WIDTH 4096\n'
            f'{helper}\n'
            'struct C { int s; uint32_t f, w, h; uint64_t t; };\n'
            f'static const C cases[] = {{{rows}}};\n'
            'int main() { for (const C &c : cases) { uint32_t f; int w, h;\n'
            '  gbm_mesa_cpu_surface(c.s, c.f, c.w, c.h, c.t, &f, &w, &h);\n'
            '  printf("%u %d %d\\n", f, w, h); } }\n')
        (self.tree / 'probe.cpp').write_text(program)
        subprocess.run(['c++', '-std=c++17', '-Wall', '-Werror', '-o', 'probe', 'probe.cpp'],
                       cwd=self.tree, check=True)
        lines = subprocess.run([str(self.tree / 'probe')], check=True, capture_output=True,
                               text=True).stdout.split('\n')
        for case, line in zip(cases, lines):
            fmt, width, height = allocated_surface(*case)
            self.assertEqual(line, f'{fmt} {width} {height}', case)
            if fmt == R8 and case[3] in (0, 1):
                # Never a row wider than the 4096-byte allocated stride.
                self.assertLessEqual(width, 4096, case)

    def test_marker_is_exported_for_the_launcher(self):
        self.assertRegex(self.after, r'visibility\("default"\), used\)\) const char\s+'
                                     r'lepton_gbm_blob_cpu_surface\[\] = "' + MARKER + '";')
        launcher = (ROOT / 'compat_tool/liblepton/properties.sh').read_text()
        self.assertIn(f"LEPTON_GBM_BLOB_CPU_SURFACE_MARKER='{MARKER}'", launcher)
        self.assertIn('vendor/lib64/libminigbm_gralloc_gbm_mesa.so', launcher)

    def test_patch_reverses_and_is_registered_after_0013(self):
        subprocess.run(['git', 'apply', '--no-index', '--reverse', '--check', str(FIX)],
                       cwd=self.tree, check=True)
        prepare = (ROOT / 'image-14/scripts/prepare-x86_64.sh').read_text()
        provenance = (ROOT / 'image-14/scripts/lib/image-provenance.sh').read_text()
        self.assertIn(f'apply_custom /workspace/output/external/minigbm /workspace/patches/{FIX.name}', prepare)
        self.assertIn(f'"$IMAGE/patches/{FIX.name}"', prepare)
        self.assertIn(f'"external/minigbm|{FIX.name}"', provenance)
        applies = re.findall(r'^apply_custom \S+ /workspace/patches/(\S+)', prepare, flags=re.M)
        self.assertLess(applies.index(BASE.name), applies.index(NO_MAP.name))
        self.assertLess(applies.index(NO_MAP.name), applies.index(FIX.name))


if __name__ == '__main__':
    unittest.main()
