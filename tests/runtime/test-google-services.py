#!/usr/bin/env python3
"""Exercise services staging against synthetic ext4 images, without Android boot."""
import io
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

SCRIPT = Path(__file__).with_name("stage-google-services.sh")


@unittest.skipUnless(shutil.which("mke2fs") and shutil.which("debugfs"), "ext4 tools required")
class ServicesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        repo = self.root / "repo"
        helper = repo / "tests/runtime/stage-google-services.sh"
        helper.parent.mkdir(parents=True)
        shutil.copyfile(SCRIPT, helper)
        self.helper = helper
        deploy = repo / "image-14/scripts/deploy-compat-x86_64.sh"
        deploy.parent.mkdir(parents=True)
        deploy.write_text('''#!/bin/bash
set -eu
mode=$1; shift
while (($#)); do
 case "$1" in --stage-dir) stage=$2;; --rootfs-source) source=$2;; *) exit 2;; esac
 shift 2
done
[[ "$mode" == --execute ]] || exit 0
mkdir -p "$stage/compat_tool/images"
cp -a "$source" "$stage/compat_tool/images/rootfs"
''')
        self.source = self.root / "source-stage"
        (self.source / "tools").mkdir(parents=True)
        rootfs = self.source / "compat_tool/images/rootfs"
        rootfs.mkdir(parents=True)
        (rootfs / "baseline").write_text("unchanged")
        self.stage = self.root / "test-stage"
        self.images = self.root / "images"
        self.images.mkdir()
        apk = io.BytesIO()
        with zipfile.ZipFile(apk, "w") as bundle:
            bundle.writestr("classes.dex", b"synthetic")
            bundle.writestr("lib/x86_64/libgms.so", b"host-native-fixture")
            bundle.writestr("lib/x86/libgms.so", b"wrong-abi-fixture")
        xml = b"<permissions/>"
        fixtures = {
            "system": {"system/build.prop": b"ro.build.version.sdk=34\n",
                       "system/etc/permissions/privapp-permissions-google.xml": xml},
            "product": {"priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk": apk.getvalue(),
                        "priv-app/Phonesky/Phonesky.apk": apk.getvalue(),
                        "etc/permissions/privapp-permissions-google-p.xml": xml,
                        "etc/sysconfig/google.xml": xml,
                        "etc/sysconfig/google-hiddenapi-package-whitelist.xml": xml,
                        "etc/default-permissions/default-permissions-sdk-google.xml": xml},
            "system_ext": {"priv-app/GoogleServicesFramework/GoogleServicesFramework.apk": apk.getvalue(),
                           "etc/permissions/privapp-permissions-google-se.xml": xml},
        }
        for part, entries in fixtures.items():
            tree = self.root / part
            for name, contents in entries.items():
                path = tree / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(contents)
            subprocess.run(["mke2fs", "-q", "-t", "ext4", "-d", str(tree),
                            str(self.images / f"{part}.img"), "8192"], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def run_script(self, mode, *options):
        return subprocess.run(["bash", str(self.helper), "--source-stage", str(self.source),
                               "--stage-dir", str(self.stage), "--google-images", str(self.images), mode, *options],
                              capture_output=True, text=True, env={**os.environ})

    def test_extracts_services_and_host_libraries_without_modifying_source(self):
        result = self.run_script("--execute")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        rootfs = self.stage / "compat_tool/images/rootfs"
        self.assertTrue((rootfs / "system/product/priv-app/PrebuiltGmsCore/lib/x86_64/libgms.so").is_file())
        self.assertFalse((rootfs / "system/product/priv-app/PrebuiltGmsCore/lib/x86").exists())
        self.assertEqual(len(list(rootfs.rglob("*.apk"))), 2)
        self.assertTrue((rootfs / "system/system_ext/etc/permissions/lepton-google.xml").is_file())
        self.assertTrue((self.stage / "google-services.sha256").is_file())
        self.assertEqual(list((self.source / "compat_tool/images/rootfs").iterdir()),
                         [self.source / "compat_tool/images/rootfs/baseline"])
        self.assertFalse((self.stage / "compat_tool/sysbake").exists())

    def test_check_does_not_create_stage(self):
        result = self.run_script("--check")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.stage.exists())

    def test_store_is_only_included_when_requested(self):
        result = self.run_script("--execute", "--with-play-store")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        rootfs = self.stage / "compat_tool/images/rootfs"
        self.assertEqual(len(list(rootfs.rglob("*.apk"))), 3)
        self.assertTrue((rootfs / "system/product/priv-app/Phonesky/lib/x86_64/libgms.so").is_file())


if __name__ == "__main__":
    unittest.main()
