#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Compile the production display math from the applied hwcomposer patch."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / 'image-14/patches/0009-hwc-local-wayland-fullscreen.patch'

class LocalDisplayTests(unittest.TestCase):
    def test_patch_and_physical_logical_coordinate_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            source = ROOT / 'image-14/android_hardware_waydroid/hwcomposer'
            (temp / 'hwcomposer').mkdir()
            for name in ('Android.bp', 'wayland-hwc.cpp', 'wayland-hwc.h', 'hwcomposer.cpp'):
                shutil.copyfile(source / name, temp / 'hwcomposer' / name)
            subprocess.run(['git', 'apply', '--no-index', str(PATCH)], cwd=temp, check=True)
            cpp = temp / 'test.cpp'
            cpp.write_text(r'''
#include "hwcomposer/local-display.h"
#include <cassert>
int main() {
    // Compositor logical geometry and monitor modes are separate inputs.
    assert(lepton::pixel_extent(1920, 1.0) == 1920);
    assert(lepton::pixel_extent(2752, 1.25) == 3440);
    assert(lepton::pixel_extent(1152, 1.25) == 1440);
    assert(lepton::pixel_extent(1707, 1.5) == 2561);
    // Fullscreen uses the output's exact 2560 mode rather than that rounded hint.
    double sx = lepton::axis_scale(1707, 2560);
    double sy = lepton::axis_scale(960, 1440);
    assert(lepton::input_coordinate(853.5, sx) == 1280);
    assert(lepton::input_coordinate(480, sy) == 720);
    assert(lepton::input_coordinate(1706.75, sx) == 2559);
    assert(lepton::logical_extent(2560, sx) == 1707);
    assert(lepton::logical_extent(1440, sy) == 960);
    // Retain wl_fixed fractional precision until conversion, not int(x) * scale.
    assert(lepton::input_coordinate(1.75, 1.5) == 2);
    assert(lepton::input_coordinate(0.0, sx) == 0);
    assert(lepton::input_coordinate(1376, lepton::axis_scale(2752,3440)) == 1720);
    for (int transform : {1,3,5,7}) assert(lepton::rotated_output(transform));
    for (int transform : {0,2,4,6}) assert(!lepton::rotated_output(transform));
    assert(lepton::axis_scale(0, 3440) == 1);
}
''')
            subprocess.run(['c++', '-std=c++17', '-Wall', '-Wextra', '-Werror', str(cpp), '-I', str(temp), '-o', str(temp / 'test')], check=True)
            subprocess.run([str(temp / 'test')], check=True)
            subprocess.run(['git', 'apply', '--no-index', '--reverse', '--check', str(PATCH)], cwd=temp, check=True)

if __name__ == '__main__':
    unittest.main()
