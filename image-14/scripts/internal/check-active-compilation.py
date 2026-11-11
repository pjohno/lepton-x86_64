#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Conservatively refuse visible Android build engines before packaging/repair."""
import os
from pathlib import Path
import sys

for proc in Path('/proc').iterdir():
    if not proc.name.isdigit():
        continue
    try:
        # A compiler can run in a rootless container; inspect host-visible argv.
        args = (proc / 'cmdline').read_bytes().split(b'\0')
        if any(Path(os.fsdecode(arg)).name in ('ninja', 'ninja-build', 'soong_ui', 'soong_ui.bash', 'ckati') for arg in args[:2]):
            sys.exit(f'[FAIL] Active compilation detected (PID {proc.name}). Wait for Ninja/Soong/Kati to finish before packaging or repairing images.')
    except (FileNotFoundError, ProcessLookupError):
        continue
    except PermissionError:
        # Other users' restricted /proc entries cannot address this owned tree.
        continue
