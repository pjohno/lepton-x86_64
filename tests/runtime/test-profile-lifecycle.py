#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Default and development cleanup preserve Android identity and save contents."""
import os
from pathlib import Path
import subprocess
import sqlite3
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
text = (ROOT / "compat_tool/liblepton/liblepton.sh").read_text()
FUNCTIONS = text.split("function prepare_baked_data_for_removal()", 1)[1]
FUNCTIONS = "function prepare_baked_data_for_removal()" + FUNCTIONS.split("function prefix()", 1)[0]


class ProfileTests(unittest.TestCase):
    def cleanup_case(self, preserve):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            identity = root / "data/data_overlay/google-identity"
            identity.parent.mkdir(parents=True)
            identity.write_text("registered-identity")
            (root / "data/data_workdir").mkdir()
            (root / "data/app_overlay").mkdir()
            (root / "prefix").mkdir()
            code = '''set -euo pipefail
case_root=$1
LEPTON_CONTEXT=dev
LEPTON_PREFIX=$(mktemp -d /tmp/lepton-context.XXXXXXXX)
printf '%s' "$LEPTON_PREFIX" > "$case_root/prefix-path"
podman() {
    case "$1 ${2:-}" in
        'container exists') return 1;;
        'unshare rm') shift; "$@";;
    esac
}
is_app() { return 1; }
data_mount_path() { printf '%s/data/data_overlay\\n' "$case_root"; }
data_workdir() { printf '%s/data/data_workdir\\n' "$case_root"; }
app_datadir() { printf '%s/data/app_overlay\\n' "$case_root"; }
get_baked_app_data_dir() { printf '%s/data\\n' "$case_root"; }
println() { :; }
'''
            code += FUNCTIONS + '\nremove_prefix\n! clear_baked_app_data "normal shutdown"\n'
            result = subprocess.run(["bash", "-c", code, "--", directory], text=True,
                                    capture_output=True, env={**os.environ, "LEPTON_NO_CLEANUP": str(preserve).lower()})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(Path((root / "prefix-path").read_text()).exists())
            self.assertTrue((root / "prefix").exists())
            self.assertEqual(identity.read_text(), "registered-identity")

    def test_default_preserves_identity(self):
        self.cleanup_case(False)

    def test_override_preserves_identity(self):
        self.cleanup_case(True)

    def test_profile_name_cannot_escape_stage(self):
        result = subprocess.run(["bash", str(ROOT / "tests/runtime/run-apk.sh"),
                                 "--stage-dir", "/not-a-stage", "--expect-abi", "arm64-v8a",
                                 "--setup-only", "--profile", "../escape"], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid profile name", result.stderr)

    def test_id_reader_only_returns_id(self):
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "gservices.db"
            with sqlite3.connect(database) as connection:
                connection.execute("create table main (name text, value text)")
                connection.executemany("insert into main values (?, ?)",
                                       [("android_id", "1234567890"), ("other", "private-value")])
            before = database.read_bytes()
            result = subprocess.run(["python3", str(ROOT / "tests/runtime/read-gsf-id.py"), str(database)],
                                    capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout, "1234567890\n")
            self.assertEqual(database.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
