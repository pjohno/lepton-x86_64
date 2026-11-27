#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Android Library storage, staging and package-manager transaction regressions.

Package metadata comes from a stand-in for the bundled apk-info-extractor
(--json) that reads a JSON "manifest" from each test APK. No Android SDK is
needed. A stand-in apksigner covers the optional host signature check.
"""
import contextlib
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

tools = Path(__file__).resolve().parents[1] / "compat_tool/tools"
sys.path.insert(0, str(tools))
import android_library as lib  # noqa: E402

loader = importlib.machinery.SourceFileLoader("library_runtime", str(tools / "android-library-runtime"))
runtime = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(runtime)
package = "org.example.game"

EXTRACTOR = r'''#!/usr/bin/env python3
import json, sys, zipfile
assert sys.argv[1] == "--json", sys.argv
m = json.loads(zipfile.ZipFile(sys.argv[2]).read("AndroidManifest.xml"))
major, minor = m.get("major") or 0, m["version"] & 0xffffffff
print(json.dumps({"package": m["package"], "split": m["split"] or None, "version_code": minor,
                  "version_code_major": major, "long_version_code": (major << 32) | minor,
                  "version_name": str(m["version"]), "min_sdk": m.get("min_sdk", 24),
                  "min_sdk_codename": m.get("codename"), "label": m.get("label"),
                  "launchable_activity": m.get("activity", ".Main"), "extract_native_libs": None,
                  "abis": m.get("abis", [])}))
'''
APKSIGNER = r'''#!/usr/bin/env python3
import json, sys, zipfile
m = json.loads(zipfile.ZipFile(sys.argv[-1]).read("AndroidManifest.xml"))
if m["key"] is None:
    sys.exit("DOES NOT VERIFY")
if m["key"] == "odd":
    print("Signer one: something new")
else:
    print(f"Signer #1 certificate SHA-256 digest: {m['key'] * 64}")
'''


def script(path, text):
    path.write_text(text)
    path.chmod(0o755)
    return path


class LibraryCase(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.extractor = script(self.home / "extractor", EXTRACTOR)
        self.signer = script(self.home / "apksigner", APKSIGNER)
        env = patch.dict(os.environ, {"HOME": temp.name, "XDG_CONFIG_HOME": str(self.home / "config"),
                                      "LEPTON_APK_EXTRACTOR": str(self.extractor), "LEPTON_APKSIGNER": "none"})
        env.start()
        self.addCleanup(env.stop)
        self.root = lib.initialize(self.home / "Android Library")

    def apk(self, name, version=1, key="a", split="", pkg=package, **manifest):
        path = self.home / name
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("AndroidManifest.xml", json.dumps(dict(
                package=pkg, key=key, version=version, split=split, **manifest)))
            archive.writestr("classes.dex", name)
        return path

    def bundle(self, name, version, **split_args):
        path = self.home / name
        with zipfile.ZipFile(path, "w") as archive:
            archive.write(self.apk("base-source.apk", version), "base.apk")
            archive.write(self.apk("split-source.apk", version, split="config.x86_64", **split_args),
                          "split_config.x86_64.apk")
        return path

    def install(self, apk, mode="import", **kwargs):
        return lib.import_app(self.root, apk, mode=mode, verbose=False, **kwargs)

    def promote(self):
        lib.promote_candidate(self.root / package)

    def cli(self, *args, check=True):
        return subprocess.run([str(tools / "leptron"), *args], text=True, capture_output=True, check=check)


class LibraryTests(LibraryCase):
    def test_configured_location_is_separate_from_availability(self):
        self.assertEqual(lib.library(), self.root)
        self.assertEqual(lib.configured()[0], self.root)
        self.assertTrue((self.root / lib.STORAGE).is_dir())
        other = self.home / "Disconnected"
        self.root.rename(other)
        # A disconnected drive: the location is still known, nothing is made.
        self.assertEqual(lib.configured()[0], self.root)
        with self.assertRaisesRegex(lib.Unavailable, "Reconnect"):
            lib.library()
        with self.assertRaisesRegex(ValueError, "Reconnect"):
            lib.initialize(self.root)
        self.assertFalse(self.root.exists())
        self.root.mkdir()  # an empty mount point is not the library
        with self.assertRaisesRegex(lib.Unavailable, "unavailable"):
            lib.library()
        self.assertEqual(list(self.root.iterdir()), [])
        self.root.rmdir()
        other.rename(self.root)
        storage = self.root / lib.STORAGE
        storage.rmdir()
        storage.symlink_to(self.home, target_is_directory=True)
        with self.assertRaisesRegex(lib.Unavailable, "unavailable"):
            lib.library()

    def test_forget_keeps_files_and_init_adopts_library(self):
        storage = self.root / lib.STORAGE / "save.txt"
        storage.write_text("kept")
        self.install(self.apk("v1.apk"))
        self.assertIn("Stopped using", self.cli("forget").stdout)
        self.assertIsNone(lib.configured())
        self.assertEqual(storage.read_text(), "kept")
        self.assertTrue((self.root / package / f"{package}.apk").is_file())
        lib.initialize(self.root)
        self.assertEqual(lib.load_app(self.root, package)[1]["version_code"], 1)

    def test_init_dry_run_default_and_first_import(self):
        lib.settings_path().unlink()
        result = self.cli("init", "--dry-run")
        self.assertIn(str(self.home / "Android_Library"), result.stdout)
        self.assertFalse((self.home / "Android_Library").exists())
        result = self.cli("install", str(self.apk("first.apk")))
        self.assertIn("Creating the Android Library at", result.stdout)
        self.assertEqual(lib.library(), self.home / "Android_Library")
        self.assertTrue((self.home / "Android_Library" / package / f"{package}.apk").is_file())

    def test_first_import_does_not_adopt_an_unrelated_directory(self):
        lib.settings_path().unlink()
        (self.home / "Android_Library").mkdir()
        (self.home / "Android_Library/notes.txt").write_text("mine")
        result = self.cli("install", str(self.apk("first.apk")), check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is not an Android Library", result.stderr)
        self.assertEqual(sorted(p.name for p in (self.home / "Android_Library").iterdir()), ["notes.txt"])

    def test_update_is_staged_until_android_accepts_it(self):
        first, new = self.apk("game v1.apk"), self.apk("game v2.apk", 2)
        directory, one, apk, staged = self.install(first)
        self.assertFalse(staged)
        self.assertEqual(self.install(first)[1], one)
        with self.assertRaisesRegex(ValueError, "already in the library"):
            self.install(new)
        _, two, active, staged = self.install(new, "update")
        self.assertTrue(staged)
        self.assertEqual(active, apk)
        self.assertEqual(apk.read_bytes(), first.read_bytes())  # known-good copy untouched
        self.assertEqual(lib.load_candidate(directory, one, verify=True)["config"]["version_code"], 2)
        # Several unaccepted updates replace one another, never the active APK.
        third = self.apk("game v3.apk", 3)
        self.install(third, "update")
        self.assertEqual(apk.read_bytes(), first.read_bytes())
        self.assertEqual(lib.load_candidate(directory, one)["config"]["version_code"], 3)
        self.promote()
        self.assertEqual(apk.read_bytes(), third.read_bytes())
        self.assertEqual((directory / lib.PREVIOUS / apk.name).read_bytes(), first.read_bytes())
        self.assertIsNone(lib.load_candidate(directory, lib.load_app(self.root, package)[1]))
        with self.assertRaisesRegex(ValueError, "downgrade"):
            self.install(new, "update")
        with self.assertRaisesRegex(ValueError, "same-version"):
            self.install(self.apk("variant.apk", 3), "update")
        self.assertTrue(self.install(self.apk("variant.apk", 3), "update", replace=True)[3])

    def test_settings_survive_promotion(self):
        directory, config, _, _ = self.install(self.apk("v1.apk"))
        self.install(self.apk("v2.apk", 2), "update")
        config["shared_folders"] = {"defaults": ["Music:ro"], "custom": []}
        lib.atomic_json(directory / "config.json", config)  # edited after staging
        self.promote()
        promoted = lib.load_app(self.root, package)[1]
        self.assertEqual(promoted["version_code"], 2)
        self.assertEqual(promoted["shared_folders"], {"defaults": ["Music:ro"], "custom": []})

    def test_long_version_codes_are_signed_64_bit(self):
        first = self.apk("v1.apk", version=23, major=2)
        second = self.apk("v2.apk", version=1, major=3)
        self.assertEqual(self.install(first)[1]["version_code"], (2 << 32) + 23)
        self.assertEqual(self.install(second, "update")[1]["version_code"], (3 << 32) + 1)
        self.promote()
        with self.assertRaisesRegex(ValueError, "downgrade"):
            self.install(first, "update")
        # versionCode -1 is the unsigned low word; a negative major is a
        # negative long version code, which Android orders below zero.
        low = self.apk("neg.apk", version=-1, major=-1, pkg="org.example.negative")
        _, config, _, _ = self.install(low)
        self.assertEqual(config["version_code"], -1 << 32 | 0xffffffff)
        lib.check_metadata(config, "org.example.negative", "test")
        self.assertTrue(self.install(self.apk("zero.apk", version=0, pkg="org.example.negative"), "update")[3])

    def test_minimum_sdk_and_preview_builds(self):
        with self.assertRaisesRegex(ValueError, "needs Android API 35"):
            self.install(self.apk("too-new.apk", min_sdk=35))
        with self.assertRaisesRegex(ValueError, "preview"):
            self.install(self.apk("preview.apk", min_sdk=None, codename="Baklava"))
        self.assertEqual(self.install(self.apk("ok.apk", min_sdk=34))[1]["min_sdk"], 34)

    def test_apkm_and_split_validation(self):
        with self.assertRaisesRegex(ValueError, "version differs"):
            self.install(self.bundle("bad.apkm", 1, pkg="org.other.app"))
        _, first, apk, _ = self.install(self.bundle("v1.apkm", 1))
        self.assertEqual(first["splits"], {"split_config.x86_64.apk": "config.x86_64"})
        self.assertEqual(self.install(self.bundle("v2.apkm", 2), "update")[2], apk)
        self.promote()
        self.assertEqual(set(lib.load_app(self.root, package)[1]["apks"]), {"base.apk", "split_config.x86_64.apk"})
        with self.assertRaisesRegex(ValueError, "Changing between"):
            self.install(self.apk("v3.apk", 3), "update")

    def test_optional_host_signature_check(self):
        _, config, _, _ = self.install(self.apk("other.apk", pkg="org.example.other"))
        self.assertIsNone(config["signers"])  # no apksigner: Android checks
        with patch.dict(os.environ, {"LEPTON_APKSIGNER": str(self.signer)}):
            self.assertEqual(self.install(self.apk("v1.apk"))[1]["signers"], ["a" * 64])
            _, staged, _, _ = self.install(self.apk("v2.apk", 2), "update")
            self.assertEqual(staged["signers"], ["a" * 64])
            with self.assertRaisesRegex(ValueError, "did not verify"):
                self.install(self.apk("unsigned.apk", 3, key=None), "update")
            with self.assertRaisesRegex(ValueError, "known format"):
                self.install(self.apk("odd.apk", 3, key="odd"), "update")
            # A different key may be a valid rotation: Android decides.
            with contextlib.redirect_stdout(io.StringIO()) as out:
                lib.import_app(self.root, self.apk("rotated.apk", 3, key="b"), mode="update")
            self.assertIn("valid signing-key rotation", out.getvalue())
            with self.assertRaisesRegex(ValueError, "Verified signers differ"):
                self.install(self.bundle("mixed.apkm", 1, key="b", pkg=package))
        with patch.dict(os.environ, {"LEPTON_APKSIGNER": str(self.home / "missing")}):
            with self.assertRaisesRegex(ValueError, "not executable"):
                self.install(self.apk("v4.apk", 4), "update")

    def test_steam_appid_and_renamed_shortcut(self):
        _, _, apk, _ = self.install(self.apk("old.apk"))
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
            vdf.write_bytes(b"\x00shortcuts\x00" + addon.shortcut_entry(
                0, int(before), "Renamed in Steam", apk, "LEPTON_SHARED_FOLDERS=none %command%") + b"\x08")
            original = vdf.read_bytes()
            self.install(self.apk("new.apk", 2), "update")
            self.promote()
            self.assertEqual(subprocess.check_output(argv, text=True), before)
            self.assertEqual(vdf.read_bytes(), original)
            self.assertEqual(list(lib.steam_shortcuts(apk)), [{
                "user": "123", "appid": int(before), "name": "Renamed in Steam",
                "launch_options": "LEPTON_SHARED_FOLDERS=none %command%"}])
            profile = self.home / "compatdata" / before.strip()
            lib.real_dir(self.root / package)
            (self.root / package / ".profiles").mkdir()
            lib.atomic_json(self.root / package / ".profiles" / "x.json", dict(
                schema_version=1, profile=str(profile), kind="steam", state="applied",
                installed_revision=lib.load_app(self.root, package)[1]["revision"], installed_version=2))
            info = self.cli("info", package).stdout
            self.assertIn('Steam shortcut "Renamed in Steam"', info)
            self.assertIn("up to date", info)
            self.assertIn("LEPTON_SHARED_FOLDERS=none, which overrides", info)
            result = self.cli("uninstall", package, "--yes", check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(apk.is_file())

    def test_restore_is_a_library_file_transaction(self):
        first = self.apk("v1.apk")
        directory, _, apk, _ = self.install(first)
        self.install(self.apk("v2.apk", 2), "update")
        self.promote()
        _, config, _ = lib.load_app(self.root, package)
        config["shared_folders"] = {"defaults": ["Music:ro"]}
        lib.atomic_json(directory / "config.json", config)
        self.assertEqual(lib.restore_previous(directory, config, apk, dry_run=False)["version_code"], 1)
        self.assertEqual(apk.read_bytes(), first.read_bytes())
        restored = lib.load_app(self.root, package)[1]
        self.assertEqual(restored["shared_folders"], {"defaults": ["Music:ro"]})
        self.assertEqual(restored["version_code"], 1)

    def test_discard_leaves_the_library_apk(self):
        first = self.apk("v1.apk")
        directory, _, apk, _ = self.install(first)
        self.install(self.apk("v2.apk", 2), "update")
        self.assertIn("Discarded the staged update", self.cli("discard", package).stdout)
        self.assertFalse((directory / lib.CANDIDATE).exists())
        self.assertEqual(apk.read_bytes(), first.read_bytes())
        self.assertIn("No staged update", self.cli("discard", package).stdout)

    def test_unsafe_inputs(self):
        with self.assertRaisesRegex(ValueError, "Invalid Android package"):
            self.install(self.apk("bad.apk", pkg="../etc"))
        path = self.home / "malformed.apk"
        path.write_text("plain text")
        with self.assertRaisesRegex(ValueError, "malformed.apk is not a complete APK"):
            self.install(path)
        valid = self.apk("valid.apk").read_bytes()
        (self.home / "truncated.apk").write_bytes(valid[:len(valid) // 2])
        with self.assertRaisesRegex(ValueError, "not a complete APK"):
            self.install(self.home / "truncated.apk")
        # A damaged compressed member is refused, not a traceback.
        damaged = self.home / "damaged.apk"
        with zipfile.ZipFile(damaged, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("AndroidManifest.xml", json.dumps(dict(package=package, key="a", version=1, split="")))
            archive.writestr("classes.dex", os.urandom(4096) + b"x" * 65536)
        data = bytearray(damaged.read_bytes())
        offset = data.find(b"x" * 64) - 2000
        data[offset:offset + 64] = b"\xff" * 64
        damaged.write_bytes(bytes(data))
        with self.assertRaisesRegex(ValueError, "damaged.apk is damaged"):
            self.install(damaged)
        bundle = self.home / "damaged.apkm"
        with zipfile.ZipFile(bundle, "w") as archive:
            archive.write(damaged, "base.apk")
        with self.assertRaisesRegex(ValueError, "base.apk in damaged.apkm is damaged"):
            self.install(bundle)
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("../bad", "no")
        with self.assertRaisesRegex(ValueError, "Unsafe archive"):
            self.install(path)
        (self.root / package).symlink_to(self.home, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "real directory"):
            self.install(self.apk("valid.apk"))

    def test_missing_or_old_extractor_fails_clearly(self):
        with patch.dict(os.environ, {"LEPTON_APK_EXTRACTOR": str(self.home / "absent")}):
            with self.assertRaisesRegex(ValueError, "Reinstall the Lepton bundle"):
                self.install(self.apk("v1.apk"))
        old = script(self.home / "old-extractor", "#!/bin/sh\necho \"error: unexpected argument '--json'\" >&2; exit 2\n")
        with patch.dict(os.environ, {"LEPTON_APK_EXTRACTOR": str(old)}):
            with self.assertRaisesRegex(ValueError, "Cannot read Android package metadata.*--json"):
                self.install(self.apk("v1.apk"))

    def test_interrupted_promotion_is_recoverable(self):
        directory, _, apk, _ = self.install(self.apk("v1.apk"))
        new = self.apk("v2.apk", 2)
        self.install(new, "update")
        real_atomic = lib.atomic_json

        def interrupt(path, obj):
            if path == directory / "config.json":
                raise OSError("power loss")
            real_atomic(path, obj)

        with patch.object(lib, "atomic_json", interrupt), self.assertRaisesRegex(OSError, "power loss"):
            self.promote()
        self.assertEqual(apk.read_bytes(), new.read_bytes())
        with self.assertRaisesRegex(lib.Interrupted, "recover"):
            lib.load_app(self.root, package)
        self.assertIn("Finished", self.cli("recover", package).stdout)
        self.assertEqual(lib.load_app(self.root, package, verify=True)[1]["version_code"], 2)
        self.assertFalse((directory / lib.JOURNAL).exists())
        self.assertIn("No interrupted", self.cli("recover", package).stdout)

    def test_interrupted_staging_keeps_the_active_apk(self):
        first = self.apk("v1.apk")
        directory, _, apk, _ = self.install(first)
        self.install(self.apk("v2.apk", 2), "update")
        real_rename = os.rename

        def interrupt(source, target):
            if Path(target) == directory / lib.CANDIDATE:
                raise OSError("power loss")
            real_rename(source, target)

        with patch.object(lib.os, "rename", interrupt), self.assertRaisesRegex(OSError, "power loss"):
            self.install(self.apk("v3.apk", 3), "update")
        self.assertEqual(apk.read_bytes(), first.read_bytes())
        self.assertEqual(lib.load_app(self.root, package, verify=True)[1]["version_code"], 1)
        self.assertIsNone(lib.load_candidate(directory, lib.load_app(self.root, package)[1]))
        self.assertEqual([p.name for p in directory.iterdir() if p.name.startswith(".discarded")], [])

    def test_lock_readers_exclude_writers(self):
        path = self.apk("v1.apk")
        with lib.lock(self.root, False):
            self.install(path, dry_run=True)
            with self.assertRaisesRegex(ValueError, "busy"):
                self.install(path)
        self.assertEqual(self.install(path)[1]["version_code"], 1)

    def test_configuration_precedence(self):
        directory, config, apk, _ = self.install(self.apk("v1.apk", activity=".Old"))
        config["shared_folders"] = {"defaults": [], "custom": [
            {"path": str(self.home / "Books and Comics"), "name": "Books", "read_only": True}]}
        lib.atomic_json(directory / "config.json", config)
        self.assertEqual(lib.runtime_app(self.root, str(apk))[0], f"none,Books={self.home / 'Books and Comics'}:ro")
        for value in ("", "Music"):
            with patch.dict(os.environ, {"LEPTON_SHARED_FOLDERS": value}):
                self.assertIsNone(lib.runtime_app(self.root, str(apk))[0])
        self.assertIsNone(lib.runtime_app(self.root, str(self.home / "download.apk")))
        # The launch starts the activity of the version it installs.
        self.assertEqual(lib.runtime_app(self.root, str(apk))[3], ".Old")
        self.install(self.apk("v2.apk", 2, activity=".New"), "update")
        self.assertEqual(lib.runtime_app(self.root, str(apk))[3], ".New")
        lib.reject_candidate(directory, lib.load_candidate(directory, config)["config"]["revision"], "refused")
        self.assertEqual(lib.runtime_app(self.root, str(apk))[3], ".Old")
        config["shared_folders"]["custom"][0]["read_only"] = "no"
        with self.assertRaisesRegex(ValueError, "Invalid custom"):
            lib.sharing(config)

    def test_obb_and_removal_preserve_external_data(self):
        path = self.apk("v1.apk")
        obb = self.home / f"main.1.{package}.obb"
        obb.write_text("test OBB")
        directory, _, _, _ = self.install(path, obbs=[obb])
        wrong = self.home / "main.2.other.app.obb"
        wrong.write_text("wrong app")
        with self.assertRaisesRegex(ValueError, "Invalid or duplicate OBB"):
            self.install(self.apk("v2.apk", 2), "update", obbs=[wrong])
        patch_obb = self.home / f"patch.2.{package}.obb"
        patch_obb.write_text("patch")
        self.install(self.apk("v2.apk", 2), "update", obbs=[patch_obb])
        self.assertFalse((directory / "obb" / patch_obb.name).exists())  # with the staged APK
        self.promote()
        self.assertEqual((directory / "obb" / patch_obb.name).read_text(), "patch")
        self.assertEqual((directory / "obb" / obb.name).read_text(), "test OBB")
        profile = self.home / "compatdata"
        profile.mkdir()
        (profile / "save").write_text("save")
        transfer = self.root / lib.STORAGE / "transfer"
        transfer.write_text("transfer")
        self.cli("uninstall", package, "--yes")
        self.assertFalse(directory.exists())
        self.assertEqual((profile / "save").read_text(), "save")
        self.assertEqual(transfer.read_text(), "transfer")

    def test_status_reports_unavailable_library(self):
        self.install(self.apk("v1.apk"))
        self.install(self.apk("v2.apk", 2), "update")
        status = self.cli("status").stdout
        self.assertIn("(available)", status)
        self.assertIn("[update 2 (2) staged]", status)
        self.root.rename(self.home / "away")
        result = self.cli("status", check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("UNAVAILABLE", result.stdout)
        self.assertIn("Google Play still start", result.stdout)
        self.assertFalse(self.root.exists())


class FakeAndroid:
    """Android's package manager, as far as the runtime installer sees it."""
    timeout = 5

    def __init__(self, refuse=None):
        self.code = None
        self.refuse = refuse
        self.installs = []
        self.abandoned = []

    def wait_ready(self):
        pass

    def installed(self, package):
        # Android uses a new code directory for every installation.
        return self.code and {"code": self.code, "dir": f"/data/app/~~x{len(self.installs)}==/{package}-y=="}

    def checked(self, *args, **kwargs):
        return ""

    def abandon(self, session):
        self.abandoned.append(session)

    def obb(self, package, check=False):
        pass

    def install(self, sources, on_created):
        on_created("7")
        hashes = {}
        for name, size, digest, opener in sources:
            with opener() as stream:
                data = stream.read()
            if len(data) != size:
                raise ValueError("size differs")
            hashes[name] = hashlib.sha256(data).hexdigest()
            if hashes[name] != digest:
                raise ValueError("changed while installing")
        if self.refuse:
            raise runtime.Rejected(self.refuse)
        self.installs.append(hashes)
        base = hashes.pop("base.apk")
        self.code = {"version_code": self.version_for(base), "base": base, "splits": sorted(hashes.values())}

    def version_for(self, digest):
        return self.versions[digest]


class ProfileTests(LibraryCase):
    def setUp(self):
        super().setUp()
        self.android = FakeAndroid()
        patcher = patch.object(runtime, "Android", lambda context: self.android)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.profiles = {}

    def profile(self, name):
        baked = self.home / "profiles" / name / "baked"
        if not baked.exists():
            baked.mkdir(parents=True)
            lib.atomic_json(baked / "lepton-managed.json",
                            dict(schema_version=1, package=package, installed=None, pending=None))
        return baked

    def launch(self, name="steam", android=None):
        if android is not None:
            self.android = android
        self.android.versions = {}
        directory = self.root / package
        for config in [lib.load_app(self.root, package)[1]] + [
                c["config"] for c in [lib.load_candidate(directory, lib.load_app(self.root, package)[1])] if c]:
            self.android.versions[config["apks"]["base.apk"]] = config["version_code"]
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()) as err:
            runtime.profile_install(self.root, package, self.profile(name), "ctx", False)
        self.messages = err.getvalue()
        return out.getvalue().splitlines()

    def receipt(self, name="steam"):
        return lib.read_json(self.profile(name) / "lepton-managed.json")

    def test_first_install_and_ndk_code_identity(self):
        self.install(self.apk("v1.apk"))
        code_dir, code_id = self.launch()
        self.assertEqual(code_dir, f"/data/app/~~x1==/{package}-y==")
        self.assertRegex(code_id, "^[0-9a-f]{64}$")
        self.assertEqual(self.receipt()["installed"]["code"]["version_code"], 1)
        self.assertEqual(len(self.android.installs), 1)
        self.assertEqual(self.launch(), [code_dir, code_id])  # nothing to do
        self.assertEqual(len(self.android.installs), 1)
        # Reinstalling identical APKs gives freshly extracted libraries in a
        # new directory: a new identity, so NDK preparation runs again.
        self.cli("reinstall", package)
        new_dir, new_id = self.launch()
        self.assertEqual(len(self.android.installs), 2)
        self.assertNotEqual((new_dir, new_id), (code_dir, code_id))

    def test_accepted_update_is_promoted(self):
        directory, _, apk, _ = self.install(self.apk("v1.apk"))
        self.launch()
        new = self.apk("v2.apk", 2)
        self.install(new, "update")
        self.assertTrue(runtime.install_pending(self.root, package, self.profile("steam")))
        self.launch()
        self.assertEqual(apk.read_bytes(), new.read_bytes())
        self.assertFalse((directory / lib.CANDIDATE).exists())
        self.assertIn("now the library version", self.messages)
        self.assertFalse(runtime.install_pending(self.root, package, self.profile("steam")))

    def test_refused_update_keeps_the_installed_version(self):
        first = self.apk("v1.apk")
        directory, _, apk, _ = self.install(first)
        self.launch()
        before = dict(self.android.code)
        self.install(self.apk("wrong.apk", 2, key="b"), "update")
        self.android.refuse = "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: signatures do not match]"
        with self.assertRaisesRegex(ValueError, "refused the update.*unchanged; launch again"):
            self.launch()
        self.assertEqual(self.android.code, before)
        self.assertEqual(apk.read_bytes(), first.read_bytes())
        candidate = lib.load_candidate(directory, lib.load_app(self.root, package)[1])
        self.assertIn("INSTALL_FAILED_UPDATE_INCOMPATIBLE", candidate["rejected"]["error"])
        self.android.refuse = None
        self.launch()  # plays the installed version; the refused update is not retried
        self.assertEqual(self.android.code, before)
        self.assertIn("REFUSED by Android", self.cli("info", package).stdout)
        # A new update replaces the refused one and is tried again.
        self.install(self.apk("v3.apk", 3), "update")
        self.launch()
        self.assertEqual(self.android.code["version_code"], 3)

    def test_transient_failure_is_retried(self):
        self.install(self.apk("v1.apk"))
        self.launch()
        self.install(self.apk("v2.apk", 2), "update")
        with patch.object(FakeAndroid, "install", side_effect=ValueError("Package upload failed: timeout")):
            with self.assertRaisesRegex(ValueError, "upload failed"):
                self.launch()
        candidate = lib.load_candidate(self.root / package, lib.load_app(self.root, package)[1])
        self.assertIsNone(candidate["rejected"])
        self.assertEqual(self.receipt()["pending"]["code"]["version_code"], 2)
        self.launch()
        self.assertEqual(self.android.code["version_code"], 2)

    def test_interruption_after_android_commit(self):
        directory, _, apk, _ = self.install(self.apk("v1.apk"))
        self.launch()
        new = self.apk("v2.apk", 2)
        self.install(new, "update")
        real_save = lib.atomic_json
        calls = []

        def crash_after_commit(path, value):
            # The receipt write after Android's commit never happens.
            if path.name == "lepton-managed.json" and value.get("installed", {}) and \
                    value["installed"]["code"]["version_code"] == 2:
                raise OSError("host interrupted")
            calls.append(path)
            real_save(path, value)

        with patch.object(lib, "atomic_json", crash_after_commit), self.assertRaisesRegex(OSError, "interrupted"):
            self.launch()
        self.assertEqual(self.android.code["version_code"], 2)
        self.assertNotEqual(apk.read_bytes(), new.read_bytes())  # not yet promoted
        installs = len(self.android.installs)
        self.launch()
        self.assertEqual(len(self.android.installs), installs)  # verified, not repeated
        self.assertEqual(self.android.abandoned, ["7"])
        self.assertEqual(apk.read_bytes(), new.read_bytes())
        self.assertEqual(self.receipt()["installed"]["code"]["version_code"], 2)

    def test_interruption_after_install_before_promotion(self):
        directory, _, apk, _ = self.install(self.apk("v1.apk"))
        self.launch()
        new = self.apk("v2.apk", 2)
        self.install(new, "update")
        with patch.object(lib, "promote_candidate", side_effect=OSError("host interrupted")):
            with self.assertRaises(OSError):
                self.launch()
        self.assertEqual(self.receipt()["installed"]["code"]["version_code"], 2)
        installs = len(self.android.installs)
        self.launch()
        self.assertEqual(len(self.android.installs), installs)
        self.assertEqual(apk.read_bytes(), new.read_bytes())

    def test_interrupted_identical_reinstall_is_retried(self):
        self.install(self.apk("v1.apk"))
        self.launch()
        self.cli("reinstall", package)
        with patch.object(FakeAndroid, "install", side_effect=OSError("host interrupted")):
            with self.assertRaises(OSError):
                self.launch()
        self.assertIsNotNone(self.receipt()["pending"])
        # Same APKs, same directory: not committed, so it is installed again.
        self.launch()
        self.assertEqual(len(self.android.installs), 2)
        self.assertIsNone(self.receipt().get("pending_from"))

    def test_interrupted_identical_reinstall_after_commit(self):
        self.install(self.apk("v1.apk"))
        self.launch()
        self.cli("reinstall", package)
        real_install = FakeAndroid.install

        def commit_then_crash(fake, sources, on_created):
            real_install(fake, sources, on_created)
            raise OSError("host interrupted after commit")

        with patch.object(FakeAndroid, "install", commit_then_crash), self.assertRaises(OSError):
            self.launch()
        self.launch()  # new directory: recognised as committed, not repeated
        self.assertEqual(len(self.android.installs), 2)
        self.assertEqual(self.receipt()["installed"]["revision"], lib.load_app(self.root, package)[1]["revision"])

    def test_unexplained_installed_code_is_refused(self):
        self.install(self.apk("v1.apk"))
        self.android.code = {"version_code": 9, "base": "f" * 64, "splits": []}
        with self.assertRaisesRegex(ValueError, "differs from the last verified state"):
            self.launch()
        self.assertEqual(self.receipt()["installed"], None)

    def test_profiles_update_independently(self):
        self.install(self.apk("v1.apk"))
        steam, standalone = FakeAndroid(), FakeAndroid()
        self.launch("steam", steam)
        self.launch("standalone", standalone)
        self.install(self.apk("v2.apk", 2), "update")
        self.launch("steam", steam)  # accepted and promoted
        self.assertEqual(standalone.code["version_code"], 1)  # untouched until launched
        info = json.loads(self.cli("info", package, "--json").stdout)
        self.assertEqual(sorted(p["installed_version"] for p in info["profiles"]), [1, 2])
        self.launch("standalone", standalone)
        self.assertEqual(standalone.code["version_code"], 2)

    def test_profile_newer_than_library_keeps_its_version(self):
        directory, config, apk, _ = self.install(self.apk("v1.apk"))
        self.launch()
        self.install(self.apk("v2.apk", 2), "update")
        self.launch()
        lib.restore_previous(directory, lib.load_app(self.root, package)[1], apk, dry_run=False)
        self.assertFalse(runtime.install_pending(self.root, package, self.profile("steam")))
        self.launch()
        self.assertEqual(self.android.code["version_code"], 2)
        self.assertIn("newer than the library", self.messages)

    def test_apkm_streams_only_selected_members(self):
        self.install(self.bundle("v1.apkm", 1))
        self.launch()
        self.assertEqual(set(self.android.installs[0]), {"split_config.x86_64.apk"})  # base popped
        directory, config, apk = lib.load_app(self.root, package)
        sources = runtime.install_sources(config, apk)
        self.assertEqual([name for name, *_ in sources], ["base.apk", "split_config.x86_64.apk"])
        with self.assertRaisesRegex(ValueError, "lacks split_config.arm64_v8a.apk"):
            runtime.install_sources(dict(config, apks={"base.apk": "0" * 64,
                                                        "split_config.arm64_v8a.apk": "0" * 64}), apk)

    def test_digest_mismatch_aborts_installation(self):
        self.install(self.apk("v1.apk"))
        directory, config, apk = lib.load_app(self.root, package)
        lib.atomic_json(directory / "config.json", dict(config, apks={"base.apk": "0" * 64}))
        with self.assertRaisesRegex(ValueError, "differ from library metadata|changed while installing"):
            self.launch()
        self.assertIsNone(self.android.code)


RECORDER = r'''#!/usr/bin/env python3
import json, os, sys
with open(os.environ["RECORD"], "a") as log:
    log.write(json.dumps(dict(tool=os.environ.get("TOOL") or os.path.basename(sys.argv[0]), argv=sys.argv[1:],
                              apply_only=os.environ.get("LEPTON_LIBRARY_APPLY_ONLY"))) + "\n")
'''
COMMANDS = {"init", "status", "list", "forget", "install", "update", "info", "run", "apply", "add-to-steam",
            "discard", "recover", "restore-apk", "reinstall", "uninstall", "config"}


class CommandTests(LibraryCase):
    """The leptron command line: its commands, documentation and hand-off to the launch tools."""

    def setUp(self):
        super().setUp()
        install = tempfile.TemporaryDirectory()  # an install directory outside HOME and the library
        self.addCleanup(install.cleanup)
        self.tools = Path(install.name) / "compat_tool/tools"
        self.tools.mkdir(parents=True)
        for name in ("leptron", "android_library.py", "lepton_steam.py", "lepton-manage-installs"):
            (self.tools / name).write_bytes((tools / name).read_bytes())
            (self.tools / name).chmod(0o755)
        # lepton-play runs under bash and lepton-add-game under Python; both record their arguments.
        script(self.tools / "lepton-add-game", RECORDER)
        script(self.tools / "lepton-play", 'TOOL=lepton-play exec python3 "$(dirname "$0")/lepton-add-game" "$@"\n')
        self.record = self.home / "record"
        os.environ["RECORD"] = str(self.record)

    def leptron(self, *args, check=True):
        return subprocess.run([str(self.tools / "leptron"), *args], text=True, capture_output=True, check=check)

    def calls(self):
        calls = [json.loads(line) for line in self.record.read_text().splitlines()]
        self.record.unlink()
        return calls

    def test_help_lists_exactly_the_documented_commands(self):
        result = self.leptron("--help")
        self.assertTrue(result.stdout.startswith("usage: leptron "), result.stdout)
        listed = set(re.findall(r"(?m)^    ([a-z][a-z-]*)", result.stdout))
        self.assertEqual(listed, COMMANDS)
        repo = tools.parents[1]
        for doc in ("README.md", "INSTALL-STEAM-DECK.md", "compat_tool/android-library.md", "PENDING_TESTS.md",
                    "compat_tool/tools/leptron"):
            text = (repo / doc).read_text()
            used = set(re.findall(r"\bleptron ([a-z][a-z-]*)", text))
            self.assertLessEqual(used, COMMANDS, doc)
        for old in ("import", "play", "remove"):
            self.assertNotEqual(self.leptron(old, package, check=False).returncode, 0, old)

    def test_run_apply_and_add_to_steam_use_the_library_apk(self):
        result = self.leptron("install", str(self.apk("game.apk")))
        self.assertIn(f"Next: leptron add-to-steam {package}, or leptron run {package}", result.stdout)
        apk = str(self.root / package / f"{package}.apk")
        self.leptron("run", package, "--shared-folders", "none")
        self.leptron("apply", package)
        self.leptron("add-to-steam", package, "--userdata", str(self.home / "userdata"))
        run, apply, steam = self.calls()
        self.assertEqual((run["tool"], run["argv"], run["apply_only"]),
                         ("lepton-play", [apk, "--shared-folders", "none"], None))
        self.assertEqual((apply["tool"], apply["argv"], apply["apply_only"]), ("lepton-play", [apk], "true"))
        self.assertEqual((steam["tool"], steam["apply_only"]), ("lepton-add-game", None))
        self.assertEqual(steam["argv"], [apk, "--userdata", str(self.home / "userdata"), "--name", package])

    def test_uninstall_keeps_profiles_and_container_storage(self):
        self.leptron("install", str(self.apk("game.apk")))
        refused = self.leptron("uninstall", package, check=False)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("Confirm with --yes", refused.stderr)
        self.assertTrue(refused.stderr.startswith("leptron: "), refused.stderr)
        (self.root / lib.STORAGE / "keep").write_text("kept")
        self.leptron("uninstall", package, "--yes")
        self.assertFalse((self.root / package).exists())
        self.assertEqual((self.root / lib.STORAGE / "keep").read_text(), "kept")


if __name__ == "__main__":
    unittest.main()
