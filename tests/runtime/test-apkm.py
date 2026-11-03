#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Synthetic APKM selection and extraction regression tests."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("unpack_apkm", Path(__file__).with_name("unpack-apkm.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ApkmTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / "game.apkm"
        self.output = self.root / "out"

    def bundle(self, names):
        with zipfile.ZipFile(self.archive, "w") as archive:
            for name in names:
                archive.writestr(name, name.encode())

    def test_selects_arm64_and_preserves_assets(self):
        self.bundle(["base.apk", "split_config.arm64_v8a.apk", "split_config.armeabi_v7a.apk",
                     "split_UnityDataAssetPack.apk", "info.json"])
        module.unpack(self.archive, self.output, "arm64-v8a")
        self.assertEqual({p.name for p in self.output.iterdir()},
                         {"base.apk", "split_config.arm64_v8a.apk", "split_UnityDataAssetPack.apk"})
        self.assertEqual((self.output / "base.apk").read_bytes(), b"base.apk")

    def test_metadata_does_not_extract_asset_pack(self):
        self.bundle(["base.apk", "split_config.arm64_v8a.apk", "split_UnityDataAssetPack.apk"])
        module.unpack(self.archive, self.output, "arm64-v8a", metadata_only=True)
        self.assertEqual({p.name for p in self.output.iterdir()},
                         {"base.apk", "split_config.arm64_v8a.apk"})

    def test_rejects_path_traversal(self):
        self.bundle(["base.apk", "../escaped.apk"])
        with self.assertRaises(ValueError):
            module.unpack(self.archive, self.output, "arm64-v8a")
        self.assertFalse(self.output.exists())

    def test_requires_base(self):
        self.bundle(["split_config.arm64_v8a.apk"])
        with self.assertRaises(ValueError):
            module.unpack(self.archive, self.output, "arm64-v8a")

    def test_refuses_existing_output(self):
        self.bundle(["base.apk"])
        self.output.mkdir()
        with self.assertRaises(FileExistsError):
            module.unpack(self.archive, self.output, "arm64-v8a")

    def test_guest_package_directory_uses_only_base(self):
        repo = Path(__file__).resolve().parents[2]
        wrapper = (repo / "compat_tool/images/rootfs_overlay/system/bin/cmd").read_text()
        functions = wrapper.split('if [ "$1" = "package" ]', 1)[0]
        command = 'cmd_real() { printf "%s\\n" "$MOCK_PATHS"; }\n' + functions
        command += '\npackage_install_dir example.game\n'
        for paths, expected in [
            ("package:/data/app/game/base.apk", "/data/app/game"),
            ("package:/data/app/game/base.apk\npackage:/data/app/game/split_assets.apk\n"
             "package:/data/app/game/split_config.arm64_v8a.apk", "/data/app/game"),
            ("package:/data/app/game/split_assets.apk", ""),
        ]:
            with self.subTest(paths=paths):
                result = subprocess.run(["bash", "-c", command], check=True, text=True,
                                        capture_output=True, env={**os.environ, "MOCK_PATHS": paths})
                self.assertEqual(result.stdout.strip(), expected)

    def test_last_installed_package_ignores_uid_tokens(self):
        repo = Path(__file__).resolve().parents[2]
        wrapper = (repo / "compat_tool/images/rootfs_overlay/system/bin/cmd").read_text()
        functions = wrapper.split('if [ "$1" = "package" ]', 1)[0]
        command = functions + '''
cmd_real() {
    if [[ "$*" == *"-U"* ]]; then return 1; fi
    printf 'package:example.old\npackage:com.yodo1.crossyroad\n'
}
dumpsys() {
    case "$2" in
        example.old) echo 'firstInstallTime=2026-11-01 12:00:00';;
        com.yodo1.crossyroad) echo 'firstInstallTime=2026-11-02 12:00:00';;
        *) return 1;;
    esac
}
last_installed_package
'''
        result = subprocess.run(["bash", "-c", command], check=True, text=True, capture_output=True)
        self.assertEqual(result.stdout.strip(), "com.yodo1.crossyroad")


if __name__ == "__main__":
    unittest.main()
