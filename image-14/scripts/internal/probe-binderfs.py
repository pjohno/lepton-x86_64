#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Run ONLY inside the disposable BinderFS/user/mount namespace host probe.

ABI: https://kernel.org/doc/html/latest/admin-guide/binderfs.html
Devices are allocated in this namespace's private instance, never host /dev.
"""
import fcntl
import os
from pathlib import Path
import stat
import struct
import sys

root = Path(sys.argv[1])
try:
    with open(root / 'binder-control', 'r+b', buffering=0) as control:
        for name in ('binder', 'hwbinder', 'vndbinder'):
            device = bytearray(struct.pack('<256sII', name.encode(), 0, 0))
            # _IOWR('b', 1, struct binderfs_device), x86_64 Linux ABI.
            fcntl.ioctl(control, 0xC1086201, device, True)
            path = root / name
            if not stat.S_ISCHR(path.stat().st_mode):
                raise OSError(f'{path} is not a character device')
            fd = os.open(path, os.O_RDWR | os.O_CLOEXEC)
            os.close(fd)
except OSError as exc:
    sys.exit(f'Private BinderFS device allocation/access failed: {exc}')
