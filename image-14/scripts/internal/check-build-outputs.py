#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Find (and optionally delete) damaged Android build outputs.

A power cut or crash during a build can leave files that the build already
recorded as finished but whose contents never reached the disk: empty or
zero-filled object files, archives and zips. The next build trusts them and
fails much later, e.g. "archive member 'x.o' is neither ET_REL nor LLVM
bitcode". Deleting them makes ninja rebuild just those files.

Only compiled/packaged file types are checked, and only in output folders
that ninja regenerates (out/soong/.intermediates, out/target, out/host/linux-x86).
"""
import argparse
import os
from pathlib import Path
import sys

ELF = b"\x7fELF"
BITCODE = (b"BC\xc0\xde", b"\xde\xc0\x17\x0b")  # LLVM bitcode, bitcode wrapper
ZIP = (b"PK\x03\x04", b"PK\x05\x06")            # zip with entries / empty zip
EXPECTED = {
    ".o": (ELF,) + BITCODE,
    ".so": (ELF,),
    ".a": (b"!<arch>\n", b"!<thin>\n"),
    ".jar": ZIP, ".srcjar": ZIP, ".apk": ZIP, ".apex": ZIP, ".zip": ZIP,
}
SCAN_DIRS = ("soong/.intermediates", "target", "host/linux-x86")


def damaged(path):
    """True if the file lacks the header its type always has."""
    expected = EXPECTED[path.suffix]
    try:
        with path.open("rb") as handle:
            head = handle.read(8)
    except OSError:
        return False  # unreadable is not evidence of damage; leave it alone
    if path.suffix == ".so" and head[:2] in (b"/*", b"GR", b"IN", b"OU"):
        return False  # GNU ld linker scripts named .so (e.g. libc.so)
    return not any(head.startswith(magic) for magic in expected)


def scan(out, since=None):
    for sub in SCAN_DIRS:
        top = out / sub
        if not top.is_dir():
            continue
        for directory, _, files in os.walk(top):
            for name in files:
                path = Path(directory, name)
                if path.suffix not in EXPECTED or path.is_symlink():
                    continue
                if since is not None and path.stat().st_mtime < since:
                    continue
                if damaged(path):
                    yield path


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("out", type=Path, help="The Android checkout's out/ folder")
    parser.add_argument("--since-file", type=Path,
                        help="Only check files written after this file's modification time")
    parser.add_argument("--delete", action="store_true", help="Delete the damaged files (ninja rebuilds them)")
    parser.add_argument("--report", type=Path, help="Write the list of damaged files here")
    args = parser.parse_args()
    out = args.out.resolve(strict=True)
    if out.name != "out":
        raise SystemExit("ERROR: expected an Android out/ folder: " + str(out))
    since = args.since_file.stat().st_mtime if args.since_file else None
    found = sorted(scan(out, since))
    if args.report:
        args.report.write_text("".join(str(p) + "\n" for p in found), encoding="utf-8")
    for path in found[:20]:
        print("  damaged:", path.relative_to(out))
    if len(found) > 20:
        print("  ... and", len(found) - 20, "more" + (" (see " + str(args.report) + ")" if args.report else ""))
    if args.delete:
        for path in found:
            path.unlink(missing_ok=True)
    action = "deleted; they will be rebuilt" if args.delete else "found"
    print("Damaged build files:", len(found), action if found else "")


if __name__ == "__main__":
    try:
        main()
    except OSError as exc:
        print("ERROR:", exc, file=sys.stderr)
        sys.exit(1)
