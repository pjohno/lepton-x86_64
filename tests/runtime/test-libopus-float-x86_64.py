#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Patch 0015: x86_64 devices decode Opus in floating point.

Android builds libopus fixed-point, and Codec2's c2.android.opus.decoder
decodes to int16 with opus_multistream_decode. Fixed point saturates decoded
peaks above full scale into flat tops (crackle on loud music, e.g. Metrolist,
which ships its own Opus decoder for ARM only); the float build soft-clips.

Structural checks always run. With LEPTON_AOSP_DIR pointing at a prepared
Android 14 checkout (external/libopus unpatched or patched) and a C compiler,
the behaviour is checked too: the same packets decoded by a fixed-point and a
0015 float build of that libopus, counting flat-topped runs at full scale.
"""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / 'image-14/patches/0015-libopus-float-decode-x86_64.patch'
HARNESS = ROOT / 'tests/runtime/opus-clip/opusclip.c'
AOSP = Path(os.environ['LEPTON_AOSP_DIR']) if os.environ.get('LEPTON_AOSP_DIR') else None


def make_list(src, *names):
    script = ('include celt_sources.mk\ninclude silk_sources.mk\ninclude opus_sources.mk\n'
              'all: ; @echo ' + ' '.join(f'$({n})' for n in names) + '\n')
    return subprocess.run(['make', '-s', '-f', '-', '-C', str(src)], input=script, text=True,
                          capture_output=True, check=True).stdout.split()


class StructureTests(unittest.TestCase):
    def setUp(self):
        self.patch = PATCH.read_text()

    def test_only_the_android_x86_64_target_changes(self):
        added = [l[1:] for l in self.patch.splitlines() if l.startswith('+') and not l.startswith('+++')]
        bp = '\n'.join(added[:added.index('#ifdef FIXED_POINT')] if '#ifdef FIXED_POINT' in added else added)
        self.assertIn('android_x86_64: {', bp)
        self.assertIn('cflags: ["-UFIXED_POINT"],', bp)
        self.assertIn('local_include_dirs: ["silk/float"],', bp)
        for arch in ('arm', 'arm64', 'x86', 'host', 'linux_glibc'):
            self.assertNotRegex(bp, rf'^\s*{arch}(_x86_64)?: {{', arch)
        # Every fixed SILK source removed is replaced by the float set.
        fixed = re.findall(r'"(silk/fixed/[^"]+\.c)"', bp)
        floats = re.findall(r'"(silk/float/[^"]+\.c)"', bp)
        self.assertEqual(len(fixed), 25)  # 23 SILK_SOURCES_FIXED + 2 SSE4.1
        self.assertEqual(len(floats), 28)

    def test_analysis_overflow_check_kept_for_fixed_point(self):
        self.assertIn('+#ifdef FIXED_POINT\n         if(__builtin_add_overflow(hp_ener', self.patch)
        self.assertIn('+        hp_ener += out32_hp*(opus_val64)out32_hp;', self.patch)

    def test_registered_after_0014(self):
        prepare = (ROOT / 'image-14/scripts/prepare-x86_64.sh').read_text()
        provenance = (ROOT / 'image-14/scripts/lib/image-provenance.sh').read_text()
        self.assertIn(f'apply_custom /workspace/output/external/libopus /workspace/patches/{PATCH.name}', prepare)
        self.assertIn(f'"$IMAGE/patches/{PATCH.name}"', prepare)
        self.assertIn(f'"external/libopus|{PATCH.name}"', provenance)
        applies = re.findall(r'^apply_custom \S+ /workspace/patches/(\S+)', prepare, flags=re.M)
        self.assertEqual(applies[-1], PATCH.name)


@unittest.skipUnless(AOSP and (AOSP / 'external/libopus/celt_sources.mk').is_file() and shutil.which('cc'),
                     'set LEPTON_AOSP_DIR to a prepared Android 14 checkout to compile libopus')
class DecodeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        work = Path(cls.tmp.name)
        src = work / 'libopus'
        shutil.copytree(AOSP / 'external/libopus', src, ignore=shutil.ignore_patterns('.git'))
        # Accept a checkout with 0015 already applied, as prepared trees have.
        if subprocess.run(['git', 'apply', '--no-index', '--reverse', '--check', str(PATCH)],
                          cwd=src, capture_output=True).returncode != 0:
            subprocess.run(['git', 'apply', '--no-index', str(PATCH)], cwd=src, check=True)
        flags = ['-O2', '-w', '-DOPUS_BUILD', '-DUSE_ALLOCA', '-DSIMD_EXTRA_ALLOC_BYTES=16',
                 '-DHAVE_LRINT', '-DHAVE_LRINTF', '-DNULL=0', '-Drestrict=']
        flags += [f'-I{src / d}' for d in ('include', 'celt', 'silk', 'silk/fixed', 'silk/float', 'src')]
        common = ['CELT_SOURCES', 'SILK_SOURCES', 'OPUS_SOURCES', 'OPUS_SOURCES_FLOAT']
        for mode, extra, silk in (('fixed', ['-DFIXED_POINT'], 'SILK_SOURCES_FIXED'),
                                  ('float', [], 'SILK_SOURCES_FLOAT')):
            subprocess.run(['cc', *flags, *extra, '-o', str(work / mode), str(HARNESS),
                            *make_list(src, *common, silk), '-lm'], cwd=src, check=True)
        subprocess.run([str(work / 'float'), 'gen', str(work / 'in.pcm'), '20'], check=True)
        subprocess.run([str(work / 'float'), 'enc', str(work / 'in.pcm'), str(work / 'in.pkt'), '160000'],
                       check=True)
        cls.result = {}
        for mode in ('fixed', 'float'):
            out = subprocess.run([str(work / mode), 'dec', str(work / 'in.pkt'), os.devnull],
                                 check=True, capture_output=True, text=True).stdout
            cls.result[mode] = {k: int(v) for k, v in re.findall(r'(\w[\w>=]*)=(\d+)', out)}

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_fixed_point_flat_tops_premise(self):
        self.assertGreater(self.result['fixed']['flat_runs'], 50, self.result)

    def test_float_build_has_no_flat_tops(self):
        self.assertEqual(self.result['float']['flat_runs'], 0, self.result)
        self.assertLess(self.result['float']['at_full_scale'], self.result['fixed']['at_full_scale'])


if __name__ == '__main__':
    unittest.main()
