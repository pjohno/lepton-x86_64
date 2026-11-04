#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Prepare an installed ARM64 game for the NDK translator's fast (tiered) mode.

The Google API 34 translator cannot run a few ARM64 instructions. The Lepton
NDK shim emulates them, but only when the translator falls back to its
interpreter (light-translate-or-interpret mode), which is slower and stutters.

  arm64_hints.py patch LIB_DIR   replace the wait hints SEVL, SEV and WFE with
                                 NOP in executable segments of LIB_DIR/*.so
                                 (architecturally allowed: they are hints),
                                 then print the translation mode to use:
  tiered                         nothing unsupported is left (fast mode)
  light-translate-or-interpret   MRS reads of MIDR_EL1/CNTFRQ_EL0/CNTVCT_EL0
                                 remain, which only the shim can emulate
  arm64_hints.py scan LIB_DIR    report counts without changing anything

Code generated at run time, or libraries loaded straight from an APK, cannot be
seen here; Lepton falls back to the light mode if such a game exits early.
"""
import os
import struct
import sys

NOP = 0xD503201F
HINTS = {0xD50320BF: "SEVL", 0xD503209F: "SEV", 0xD503205F: "WFE"}
# MRS Xt, <reg>: the low five bits select the destination register.
MRS_READS = {0xD5380000: "MIDR_EL1", 0xD53BE000: "CNTFRQ_EL0", 0xD53BE040: "CNTVCT_EL0"}
EM_AARCH64 = 183


def executable_ranges(data):
    """File ranges of loadable, executable segments of a 64-bit ARM64 ELF."""
    if len(data) < 64 or data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        return []
    if struct.unpack_from("<H", data, 0x12)[0] != EM_AARCH64:
        return []
    phoff, = struct.unpack_from("<Q", data, 0x20)
    phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
    ranges = []
    for index in range(phnum):
        base = phoff + index * phentsize
        if base + 56 > len(data):
            break
        p_type, p_flags, p_offset, _, _, p_filesz = struct.unpack_from("<IIQQQQ", data, base)
        if p_type == 1 and p_flags & 1:  # PT_LOAD with PF_X
            start = p_offset + (-p_offset % 4)
            ranges.append((start, min(p_offset + p_filesz, len(data))))
    return ranges


def process(path, patch):
    with open(path, "rb") as handle:
        data = bytearray(handle.read())
    hints, reads = {}, {}
    changed = False
    for start, end in executable_ranges(data):
        for offset in range(start, end - 3, 4):
            word, = struct.unpack_from("<I", data, offset)
            if word in HINTS:
                hints[HINTS[word]] = hints.get(HINTS[word], 0) + 1
                if patch:
                    struct.pack_into("<I", data, offset, NOP)
                    changed = True
            elif word & 0xFFFFFFE0 in MRS_READS:
                name = MRS_READS[word & 0xFFFFFFE0]
                reads[name] = reads.get(name, 0) + 1
    if changed:
        # Rewrite in place (same inode): the library is in a live overlay.
        with open(path, "r+b") as handle:
            handle.write(data)
    return hints, reads


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("patch", "scan"):
        print(__doc__, file=sys.stderr)
        return 2
    patch, lib_dir = sys.argv[1] == "patch", sys.argv[2]
    remaining_reads = False
    for name in sorted(os.listdir(lib_dir)):
        path = os.path.join(lib_dir, name)
        if not name.endswith(".so") or not os.path.isfile(path) or os.path.islink(path):
            continue
        hints, reads = process(path, patch)
        if hints or reads:
            action = "patched" if patch and hints else "found"
            print(f"{name}: {action} hints {hints or 'none'}; shim-only reads {reads or 'none'}", file=sys.stderr)
        remaining_reads = remaining_reads or bool(reads)
    print("light-translate-or-interpret" if remaining_reads else "tiered")
    return 0


if __name__ == "__main__":
    sys.exit(main())
