#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Exercise services staging against synthetic ext4 images, without Android boot."""
import io
import gzip
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
        library = repo / "image-14/scripts/lib/google-services.sh"
        library.parent.mkdir(parents=True)
        shutil.copyfile(SCRIPT.parents[2] / "image-14/scripts/lib/google-services.sh", library)
        self.library = library
        deploy = repo / "image-14/scripts/internal/deploy-compat-x86_64.sh"
        deploy.parent.mkdir(parents=True, exist_ok=True)
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
            "product": {"app/Chrome/Chrome.apk.gz": gzip.compress(apk.getvalue()),
                        "app/TrichromeLibrary/TrichromeLibrary.apk.gz": gzip.compress(apk.getvalue()),
                        "priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk": apk.getvalue(),
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

    def test_browser_is_optional_and_preserves_native_shared_library(self):
        result = self.run_script("--execute", "--with-browser")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        rootfs = self.stage / "compat_tool/images/rootfs"
        self.assertEqual(len(list(rootfs.rglob("*.apk"))), 4)
        for name in ("Chrome", "TrichromeLibrary"):
            self.assertTrue((rootfs / f"system/product/app/{name}/{name}.apk").is_file())
            self.assertTrue((rootfs / f"system/product/app/{name}/lib/x86_64/libgms.so").is_file())
            self.assertFalse((rootfs / f"system/product/app/{name}/lib/x86").exists())
        self.assertFalse(list(rootfs.rglob("*.apk.gz")))

    def test_check_does_not_create_stage(self):
        result = self.run_script("--check")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.stage.exists())

    def test_missing_required_google_component_fails_before_staging(self):
        subprocess.run(['debugfs', '-w', '-R', 'rm /app/Chrome/Chrome.apk.gz',
                        str(self.images / 'product.img')], check=True,
                       capture_output=True)
        result = self.run_script('--execute', '--with-browser')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.stage.exists())

    def test_framework_guard_accepts_required_dex_markers_and_rejects_old_jar(self):
        jar = self.root / 'services.jar'
        def check():
            return subprocess.run(['bash', '-c', 'source "$1"; google_services_framework_check "$2"',
                                   'test', str(self.library), str(jar)], capture_output=True)
        with zipfile.ZipFile(jar, 'w') as archive:
            archive.writestr('classes.dex', b'old services')
        self.assertNotEqual(check().returncode, 0)
        with zipfile.ZipFile(jar, 'w') as archive:
            archive.writestr('classes.dex', b'StartLocaleManagerService StartCrossProfileAppsService persist.lepton.forward_web_intents')
        self.assertEqual(check().returncode, 0)

    def test_production_deployer_combines_gapps_and_framework_override_atomically(self):
        repo = self.helper.parents[2]
        actual = SCRIPT.parents[2]
        deploy = repo / 'image-14/scripts/internal/deploy-compat-x86_64.sh'
        deploy.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(actual / 'image-14/scripts/internal/deploy-compat-x86_64.sh', deploy)
        runtime = repo / 'compat_tool/liblepton/ndk_auxv/runtime.sh'
        runtime.parent.mkdir(parents=True)
        shutil.copyfile(actual / 'compat_tool/liblepton/ndk_auxv/runtime.sh', runtime)
        (repo / 'compat_tool/lepton').touch()
        extractor = repo / 'compat_tool/liblepton/apk_extractor'
        extractor.mkdir()
        (extractor / 'Makefile').touch()
        (repo / '.build-env').write_text('LEPTON_OUTPUT_DIR=' + str(self.root / 'output') + '\n')
        rootfs = self.source / 'compat_tool/images/rootfs'
        for name, contents in [('system/bin/sh', '#!/system/bin/sh\n'),
                               ('vendor/lib64/hw/vulkan.radeon.so', 'fixture'),
                               ('system/build.prop', 'ro.build.version.sdk=34\nro.dalvik.vm.native.bridge=0\n'),
                               ('system/framework/oat/x86_64/services.odex', 'stale')]:
            path = rootfs / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)
        (rootfs / 'system/bin/sh').chmod(0o755)
        with zipfile.ZipFile(rootfs / 'system/framework/services.jar', 'w') as jar:
            jar.writestr('classes.dex', b'old framework')
        override = self.root / 'services.jar'
        with zipfile.ZipFile(override, 'w') as jar:
            jar.writestr('classes.dex', b'StartLocaleManagerService StartCrossProfileAppsService persist.lepton.forward_web_intents')
        bindir = self.root / 'bin'
        bindir.mkdir()
        (bindir / 'make').write_text('#!/bin/bash\nmkdir -p "$2/bin"\nprintf "#!/bin/sh\\n" > "$2/bin/apk-info-extractor"\nchmod +x "$2/bin/apk-info-extractor"\n')
        (bindir / 'cargo').write_text('#!/bin/sh\nexit 0\n')
        for command in bindir.iterdir():
            command.chmod(0o755)
        args = ['bash', str(deploy), '--execute', '--stage-dir', str(self.stage),
                '--rootfs-source', str(rootfs), '--with-gapps', '--google-images', str(self.images)]
        env = {**os.environ, 'PATH': str(bindir) + ':' + os.environ['PATH']}
        rejected = subprocess.run(args, capture_output=True, text=True, env=env)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertFalse(self.stage.exists())
        result = subprocess.run(args + ['--services-jar', str(override)], capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        staged = self.stage / 'compat_tool/images/rootfs'
        self.assertEqual(len(list(staged.rglob('*.apk'))), 5)
        self.assertFalse((staged / 'system/framework/oat/x86_64/services.odex').exists())
        self.assertEqual((staged / 'system/framework/services.jar').read_bytes(), override.read_bytes())
        self.assertTrue((rootfs / 'system/framework/oat/x86_64/services.odex').is_file())
        self.assertFalse(list(rootfs.rglob('*.apk')))
        self.assertTrue((self.stage / 'compat_tool/provenance/gapps/SOURCE-IMAGES.sha256').is_file())

    def test_store_is_only_included_when_requested(self):
        result = self.run_script("--execute", "--with-play-store")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        rootfs = self.stage / "compat_tool/images/rootfs"
        self.assertEqual(len(list(rootfs.rglob("*.apk"))), 3)
        self.assertTrue((rootfs / "system/product/priv-app/Phonesky/lib/x86_64/libgms.so").is_file())


if __name__ == "__main__":
    unittest.main()
