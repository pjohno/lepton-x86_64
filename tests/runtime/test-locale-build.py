#!/usr/bin/env python3
"""Test experiment source isolation and build-cache restoration with a fake builder."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("build-locale-services.sh")
SOURCE = "frameworks/base/services/java/com/android/server/SystemServer.java"
JAR = "out/target/product/lepton_x86_64/system/framework/services.jar"
BLOCK = '''        /*
        t.traceBegin("StartLocaleManagerService");
        try {
            mSystemServiceManager.startService(LocaleManagerService.class);
        } catch (Throwable e) {
            reportWtf("starting LocaleManagerService service", e);
        }
        t.traceEnd();
        */'''


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.aosp = self.root / "aosp"
        self.output = self.root / "experiment"
        for name, value in [(SOURCE, BLOCK), (JAR, "baseline"), ("build/envsetup.sh", "")]:
            target = self.aosp / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(value)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        podman = self.bin / "podman"
        podman.write_text('''#!/usr/bin/env python3
import pathlib, sys
if sys.argv[1:3] == ["image", "exists"]: raise SystemExit(0)
mounts = [sys.argv[i+1] for i, arg in enumerate(sys.argv) if arg == "-v"]
aosp = pathlib.Path(mounts[0].split(":")[0])
source = pathlib.Path(mounts[1].split(":")[0]).read_text()
jar = aosp / "out/target/product/lepton_x86_64/system/framework/services.jar"
jar.write_text("baseline" if "        /*\\n        t.traceBegin" in source else "locale")
''')
        podman.chmod(0o755)
        self.env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}"}

    def run_script(self, *args):
        return subprocess.run(["bash", str(SCRIPT), "--aosp", str(self.aosp),
                               "--output-dir", str(self.output), *args],
                              capture_output=True, text=True, env=self.env)

    def test_experiment_preserves_source_and_restores_build_cache(self):
        result = self.run_script("--execute")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.aosp / SOURCE).read_text(), BLOCK)
        self.assertEqual((self.aosp / JAR).read_text(), "baseline")
        self.assertEqual((self.output / "services-locale.jar").read_text(), "locale")
        self.assertEqual((self.output / "services-baseline.jar").read_text(), "baseline")

    def test_view_override_is_read_only_and_original_source_is_preserved(self):
        import importlib.util
        path = SCRIPT.with_name("patch-view-intents.py")
        spec = importlib.util.spec_from_file_location("view_patch", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        source = self.aosp / "frameworks/base/services/core/java/com/android/server/wm/ActivityStarter.java"
        source.parent.mkdir(parents=True)
        source.write_text(module.original)
        result = self.run_script("--execute", "--fix-view-intents")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(source.read_text(), module.original)
        self.assertIn('"persist.lepton.forward_web_intents", false)',
                      (self.output / "ActivityStarter.java").read_text())
        self.assertEqual((self.output / "ActivityStarter.baseline.java").read_text(), module.original)
        self.assertEqual((self.aosp / JAR).read_text(), "baseline")

    def test_check_has_no_output_side_effects(self):
        result = self.run_script("--check")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.output.exists())

    def test_refuses_unknown_source_shape(self):
        (self.aosp / SOURCE).write_text("different source")
        result = self.run_script("--execute")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.aosp / JAR).read_text(), "baseline")


if __name__ == "__main__":
    unittest.main()
