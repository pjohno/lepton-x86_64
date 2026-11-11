#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate complete sparse Android images (or raw SquashFS) without mounting."""
import os
from pathlib import Path
import struct
import sys


def validate(path):
    with open(path, 'rb') as stream:
        size = os.fstat(stream.fileno()).st_size
        header = stream.read(28)
        if header[:4] == b'hsqs':
            if size < 96:
                raise ValueError('truncated SquashFS header')
            stream.seek(40)
            used = struct.unpack('<Q', stream.read(8))[0]
            if not 96 <= used <= size:
                raise ValueError('incomplete SquashFS image')
            return
        if len(header) != 28:
            raise ValueError('empty/truncated image')
        magic, major, minor, fh, ch, block, blocks, chunks, checksum = struct.unpack('<I4H4I', header)
        if magic != 0xED26FF3A or major != 1 or fh < 28 or ch < 12 or block == 0 or block % 4 or not blocks or not chunks:
            raise ValueError('unsupported or incomplete sparse image header')
        stream.seek(fh)
        total = 0
        for _ in range(chunks):
            data = stream.read(ch)
            if len(data) != ch:
                raise ValueError('truncated sparse chunk header')
            kind, reserved, count, length = struct.unpack('<2H2I', data[:12])
            expected = {0xCAC1: count * block, 0xCAC2: 4, 0xCAC3: 0, 0xCAC4: 4}.get(kind)
            if expected is None or length != ch + expected or stream.tell() + expected > size:
                raise ValueError('incomplete/invalid sparse chunk')
            if kind == 0xCAC4 and count:
                raise ValueError('invalid sparse checksum chunk')
            total += count
            stream.seek(expected, 1)
        if total != blocks or stream.tell() != size:
            raise ValueError('sparse block count or file length mismatch')


if __name__ == '__main__':
    for arg in sys.argv[1:]:
        try:
            validate(Path(arg))
        except (OSError, ValueError, struct.error) as exc:
            sys.exit(f'[FAIL] Source image unsuitable for packaging: {arg}: {exc}')
