#!/usr/bin/env python3
"""Unpack root-level APKMirror APK sets for isolated runtime tests."""
import argparse
from pathlib import Path
import re
import shutil
import zipfile

ABI_SPLITS = {
    "arm64_v8a": "arm64-v8a",
    "armeabi_v7a": "armeabi-v7a",
    "x86": "x86",
    "x86_64": "x86_64",
}


def unpack(archive, output, abi, metadata_only=False):
    with zipfile.ZipFile(archive) as bundle:
        members = [entry for entry in bundle.infolist() if entry.filename.endswith(".apk")]
        names = [entry.filename for entry in members]
        if "base.apk" not in names or len(names) != len(set(names)):
            raise ValueError("APKM requires one base.apk and unique APK names")
        if any(not re.fullmatch(r"[A-Za-z0-9_.-]+\.apk", name) for name in names):
            raise ValueError("APKM APKs must have safe root-level filenames")
        selected = []
        for entry in members:
            split_abi = ABI_SPLITS.get(entry.filename.removeprefix("split_config.").removesuffix(".apk"))
            if split_abi is not None and split_abi != abi:
                continue
            if metadata_only and entry.filename != "base.apk" and split_abi != abi:
                continue
            selected.append(entry)
        output = Path(output)
        output.mkdir()  # Refuse to overwrite an existing extraction.
        for entry in selected:
            with bundle.open(entry) as source, (output / entry.filename).open("xb") as dest:
                shutil.copyfileobj(source, dest)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive")
    parser.add_argument("--output", required=True)
    parser.add_argument("--abi", required=True, choices=ABI_SPLITS.values())
    parser.add_argument("--metadata-only", action="store_true",
                        help="Extract only base and selected conventional ABI split for preflight")
    args = parser.parse_args()
    try:
        unpack(args.archive, args.output, args.abi, args.metadata_only)
    except (OSError, ValueError, zipfile.BadZipFile) as exc:
        parser.exit(1, f"APKM extraction failed: {exc}\n")


if __name__ == "__main__":
    main()
