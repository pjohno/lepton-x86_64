#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Host-side storage and package-manager transaction regressions."""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

tools = Path(__file__).resolve().parents[1] / "compat_tool/tools"
sys.path.insert(0, str(tools))
import lepton_library as lib

loader = importlib.machinery.SourceFileLoader("library_runtime", str(tools / "lepton-library-runtime"))
runtime = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(runtime)
package = "org.example.game"


class LibraryTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        env = patch.dict(os.environ, {"HOME": temp.name, "XDG_CONFIG_HOME": str(self.home / "config")})
        env.start()
        self.addCleanup(env.stop)
        self.root = lib.initialize(self.home / "Android Library")

        def fake_command(args):
            path = Path(args[-1] if args[0] == "apksigner" else args[3])
            with zipfile.ZipFile(path) as archive:
                manifest = json.loads(archive.read("AndroidManifest.xml"))
            if args[1] == "lineage":
                raise ValueError("no embedded lineage")
            if args[0] == "apksigner":
                if manifest["key"] is None:
                    raise ValueError("signature verification failed")
                return f"Signer #1 certificate SHA-256 digest: {manifest['key'] * 64}\n"
            if args[2] == "xmltree":
                major = manifest["major"]
                return ("E: manifest\n" if major is None else
                        f"    A: http://schemas.android.com/apk/res/android:versionCodeMajor(0x01010576)={major}\n")
            return ("package: name='%s' versionCode='%s' versionName='%s' split='%s'\n"
                    "application-label:'Example Game'\n" %
                    (manifest["package"], manifest["version"], manifest["version"], manifest["split"]))

        patcher = patch.multiple(lib, sdk_tool=lambda name: name, command=fake_command)
        patcher.start()
        self.addCleanup(patcher.stop)

    def apk(self, name, version=1, key="a", split="", pkg=package, major=None):
        path = self.home / name
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("AndroidManifest.xml", json.dumps(dict(
                package=pkg, key=key, version=version, split=split, major=major)))
            archive.writestr("classes.dex", name)
        return path

    def install(self, apk, mode="import", **kwargs):
        return lib.import_app(self.root, apk, mode=mode, verbose=False, **kwargs)

    def test_location_and_disconnection(self):
        self.assertEqual(lib.library(), self.root)
        self.assertTrue((self.root / lib.STORAGE).is_dir())
        other = self.home / "Disconnected"
        self.root.rename(other)
        self.root.mkdir()
        with self.assertRaisesRegex(ValueError, "Reconnect"):
            lib.initialize(self.root)
        self.assertEqual(list(self.root.iterdir()), [])
        self.root.rmdir()
        other.rename(self.root)
        storage = self.root / lib.STORAGE
        storage.rmdir()
        storage.symlink_to(self.home, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "unavailable"):
            lib.library()

    def test_init_dry_run_and_default(self):
        lib.settings_path().unlink()
        result = subprocess.run([str(tools / "lepton-library"), "init", "--dry-run"], text=True,
                                capture_output=True, check=True)
        self.assertIn(str(self.home / "Android_Library"), result.stdout)
        self.assertFalse((self.home / "Android_Library").exists())
        subprocess.run([str(tools / "lepton-library"), "init"], check=True, stdout=subprocess.DEVNULL)
        self.assertEqual(lib.library(), self.home / "Android_Library")

    def test_update_identity_and_version(self):
        first, new = self.apk("game v1.apk"), self.apk("game v2.apk", 2)
        directory, one, apk = self.install(first)
        self.assertEqual(self.install(first)[1], one)
        with self.assertRaisesRegex(ValueError, "already imported"):
            self.install(new)
        with self.assertRaisesRegex(ValueError, "same-version"):
            self.install(self.apk("variant.apk"), "update")
        self.assertEqual(self.install(self.apk("variant.apk"), "update", replace=True)[2], apk)
        before = apk.read_bytes()
        self.assertEqual(self.install(new, "update")[2], apk)
        self.assertEqual((directory / ".previous" / apk.name).read_bytes(), before)
        self.assertTrue(first.is_file())
        self.assertEqual(apk.read_bytes(), new.read_bytes())
        with self.assertRaisesRegex(ValueError, "downgrade"):
            self.install(first, "update")
        with self.assertRaisesRegex(ValueError, "signing"):
            self.install(self.apk("wrong.apk", 3, key="b"), "update")
        self.assertEqual(apk.read_bytes(), new.read_bytes())

    def test_long_version_code_orders_by_major_then_minor(self):
        first = self.apk("v1.apk", version=23, major=2)
        second = self.apk("v2.apk", version=1, major=3)
        self.assertEqual(self.install(first)[1]["version_code"], (2 << 32) + 23)
        self.assertEqual(self.install(second, "update")[1]["version_code"], (3 << 32) + 1)
        with self.assertRaisesRegex(ValueError, "downgrade"):
            self.install(first, "update")

    def test_rotation_requires_verified_lineage_and_data_capability(self):
        before = {"signers": ["a" * 64]}
        incoming = {"signers": ["a" * 64, "b" * 64], "format": ".apk"}
        proof = (f"Signer #1 in lineage certificate SHA-256 digest: {'a' * 64}\n"
                 "Has installed data capability: true\n"
                 f"Signer #2 in lineage certificate SHA-256 digest: {'b' * 64}\n"
                 "Has installed data capability: true\n")
        with patch.object(lib, "command", return_value=proof):
            self.assertTrue(lib.validate_rotation(Path("new.apk"), before, incoming))
        with patch.object(lib, "command", return_value=proof.replace("true", "false", 1)):
            self.assertFalse(lib.validate_rotation(Path("new.apk"), before, incoming))

    def test_apkm_and_split_validation(self):
        def bundle(name, version, **split_args):
            path = self.home / name
            with zipfile.ZipFile(path, "w") as archive:
                archive.write(self.apk("base-source.apk", version), "base.apk")
                archive.write(self.apk("split-source.apk", version, split="feature", **split_args), "split_feature.apk")
            return path
        with self.assertRaisesRegex(ValueError, "signers differ"):
            self.install(bundle("bad.apkm", 1, key="b"))
        _, first, apk = self.install(bundle("v1.apkm", 1))
        _, updated, active = self.install(bundle("v2.apkm", 2), "update")
        self.assertEqual(apk, active)
        self.assertEqual(set(first["apks"]), {"base.apk", "split_feature.apk"})
        self.assertEqual(updated["version_code"], 2)
        with self.assertRaisesRegex(ValueError, "Changing between"):
            self.install(self.apk("v3.apk", 3), "update")

    def test_steam_appid_and_renamed_shortcut(self):
        _, _, apk = self.install(self.apk("old.apk"))
        steam = self.home / "Steam"
        user = steam / "userdata/123/config"
        user.mkdir(parents=True)
        with patch.dict(os.environ, {"LEPTON_STEAM_ROOT": str(steam)}):
            argv = [sys.executable, str(tools / "lepton-add-game"), "--print-appid", "--name", "Example Game", str(apk)]
            before = subprocess.check_output(argv, text=True)
            addon_loader = importlib.machinery.SourceFileLoader("shortcut", str(tools / "lepton-add-game"))
            addon = importlib.util.module_from_spec(importlib.util.spec_from_loader(addon_loader.name, addon_loader))
            addon_loader.exec_module(addon)
            vdf = user / "shortcuts.vdf"
            vdf.write_bytes(b"\x00shortcuts\x00" +
                            addon.shortcut_entry(0, int(before), "Renamed in Steam", apk, "custom options") + b"\x08")
            original = vdf.read_bytes()
            self.install(self.apk("new.apk", 2), "update")
            self.assertEqual(subprocess.check_output(argv, text=True), before)
            self.assertEqual(vdf.read_bytes(), original)
            self.assertEqual(list(lib.steam_shortcuts(apk)),
                             [{"user": "123", "appid": int(before), "name": "Renamed in Steam"}])
            result = subprocess.run([str(tools / "lepton-library"), "remove", package, "--yes"],
                                    text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(apk.is_file())

    def test_restore_is_a_library_file_transaction(self):
        first = self.apk("v1.apk")
        directory, _, apk = self.install(first)
        self.install(self.apk("v2.apk", 2), "update")
        _, config, _ = lib.load_app(self.root, package)
        config["shared_folders"] = {"defaults": ["Music:ro"]}
        lib.atomic_json(directory / "config.json", config)
        self.assertEqual(lib.restore_previous(directory, config, apk, dry_run=False), 1)
        self.assertEqual(apk.read_bytes(), first.read_bytes())
        self.assertEqual(lib.load_app(self.root, package)[1]["shared_folders"], {"defaults": ["Music:ro"]})

    def test_unsafe_inputs(self):
        with self.assertRaisesRegex(ValueError, "Invalid package"):
            self.install(self.apk("bad.apk", pkg="../etc"))
        with self.assertRaisesRegex(ValueError, "verification failed"):
            self.install(self.apk("unsigned.apk", key=None))
        path = self.home / "malformed.apk"
        path.write_text("plain text")
        with self.assertRaises(zipfile.BadZipFile):
            self.install(path)
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("../bad", "no")
        with self.assertRaisesRegex(ValueError, "Unsafe archive"):
            self.install(path)
        (self.root / package).symlink_to(self.home, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "real directory"):
            self.install(self.apk("valid.apk"))

    def test_interruption_after_atomic_replacement(self):
        directory, _, apk = self.install(self.apk("v1.apk"))
        new = self.apk("v2.apk", 2)
        real_atomic = lib.atomic_json

        def interrupt(path, obj):
            if path == directory / "config.json":
                raise OSError("power loss")
            real_atomic(path, obj)

        with patch.object(lib, "atomic_json", interrupt), self.assertRaisesRegex(OSError, "power loss"):
            self.install(new, "update")
        self.assertEqual(apk.read_bytes(), new.read_bytes())
        with self.assertRaisesRegex(ValueError, "recover"):
            lib.load_app(self.root, package)
        lib.commit_update(directory)
        self.assertEqual(lib.load_app(self.root, package, verify=True)[1]["version_code"], 2)
        self.assertFalse((directory / ".update").exists())

    def test_lock_readers_exclude_writers(self):
        path = self.apk("v1.apk")
        with lib.lock(self.root, False):
            self.install(path, dry_run=True)
            with self.assertRaisesRegex(ValueError, "busy"):
                self.install(path)
        self.assertEqual(self.install(path)[1]["version_code"], 1)

    def test_configuration_precedence(self):
        directory, config, apk = self.install(self.apk("v1.apk"))
        config["shared_folders"] = {"defaults": [], "custom": [
            {"path": str(self.home / "Books and Comics"), "name": "Books", "read_only": True}]}
        lib.atomic_json(directory / "config.json", config)
        self.assertEqual(lib.runtime_app(self.root, str(apk))[0],
                         f"none,Books={self.home / 'Books and Comics'}:ro")
        for value in ("", "Music"):
            with patch.dict(os.environ, {"LEPTON_SHARED_FOLDERS": value}):
                self.assertIsNone(lib.runtime_app(self.root, str(apk))[0])
        self.assertIsNone(lib.runtime_app(self.root, str(self.home / "download.apk")))
        config["shared_folders"]["custom"][0]["read_only"] = "no"
        with self.assertRaisesRegex(ValueError, "Invalid custom"):
            lib.sharing(config)

    def test_obb_and_removal_preserve_external_data(self):
        path = self.apk("v1.apk")
        obb = self.home / f"main.1.{package}.obb"
        obb.write_text("test OBB")
        directory, _, _ = self.install(path, obbs=[obb])
        wrong = self.home / "main.2.other.app.obb"
        wrong.write_text("wrong app")
        with self.assertRaisesRegex(ValueError, "Invalid or duplicate OBB"):
            self.install(self.apk("v2.apk", 2), "update", obbs=[wrong])
        self.assertEqual((directory / "obb" / obb.name).read_text(), "test OBB")
        profile = self.home / "compatdata"
        profile.mkdir()
        (profile / "save").write_text("save")
        transfer = self.root / lib.STORAGE / "transfer"
        transfer.write_text("transfer")
        subprocess.run([str(tools / "lepton-library"), "remove", package, "--yes"], check=True,
                       stdout=subprocess.DEVNULL)
        self.assertFalse(directory.exists())
        self.assertEqual((profile / "save").read_text(), "save")
        self.assertEqual(transfer.read_text(), "transfer")


class ProfileTests(unittest.TestCase):
    def test_failed_commit_and_interruption_recovery(self):
        from unittest.mock import Mock
        old = {"revision": "old", "code": {"version_code": 1, "base": "old", "splits": []}}
        target = {"revision": "new", "code": {"version_code": 2, "base": "new", "splits": []}}
        android = Mock()
        android.installed.return_value = old["code"]
        android.install.side_effect = ValueError("Package manager refused")
        state = {"installed": old, "pending": None}
        save = Mock()
        with self.assertRaisesRegex(ValueError, "manager refused"):
            runtime.finish_install(android, state, target, [], package, save)
        self.assertEqual(state, {"installed": old, "pending": target})
        save.assert_called_once()
        # A subsequent launch verifies the actual package-manager result after
        # host interruption and must not repeat an already committed update.
        state["session"] = "42"
        android.installed.return_value = target["code"]
        android.install.reset_mock()
        runtime.finish_install(android, state, target, [], package, save)
        android.install.assert_not_called()
        android.abandon.assert_called_once_with("42")
        self.assertEqual(state, {"installed": target, "pending": None})
        with self.assertRaisesRegex(ValueError, "newer"):
            runtime.finish_install(android, state, old, [], package, save)
        android.install.assert_not_called()

    def test_rejects_missing_split(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder) / "base.apk"
            base.write_text("base")
            config = {"format": ".apkm", "version_code": 1,
                      "apks": {"base.apk": lib.sha256(base), "split_feature.apk": "missing"}}
            with self.assertRaisesRegex(ValueError, "differ from verified"):
                runtime.target_code(config, [base])


if __name__ == "__main__":
    unittest.main()
