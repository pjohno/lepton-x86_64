#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Review the exact source rewrite and production patch agreement."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

path = Path(__file__).with_name("patch-view-intents.py")
spec = importlib.util.spec_from_file_location("view_patch", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class ViewTests(unittest.TestCase):
    def test_rewrites_only_reviewed_interceptor(self):
        source = "prefix\n" + module.original + "suffix\n"
        result = module.transform(source)
        self.assertTrue(result.startswith("prefix\n"))
        self.assertTrue(result.endswith("suffix\n"))
        self.assertIn('"persist.lepton.forward_web_intents", false)', result)
        self.assertIn('mRequest.intent.getComponent() == null', result)
        self.assertIn('mRequest.intent.getPackage() == null', result)
        self.assertIn('"http".equalsIgnoreCase(uri.getScheme())', result)
        self.assertIn('"https".equalsIgnoreCase(uri.getScheme())', result)
        self.assertLess(result.index("return START_SUCCESS"), result.rindex("                }"))

    def test_rejects_changed_or_duplicate_source(self):
        for source in ("unknown", module.original * 2):
            with self.assertRaises(ValueError): module.transform(source)

    def test_production_patch_applies_to_unmodified_context(self):
        patch = path.resolve().parents[2] / ("image-14/android_vendor_valve/patches/"
            "base-patches-34/frameworks/base/0023-lepton-Intercept-VIEW-intent-for-URIs-and-forward-it.patch")
        context = ("            onExecutionStarted();\n\n" +
            "            if (mRequest.intent != null) {\n" +
            "                // Refuse possible leaked file descriptors\n" +
            "                if (mRequest.intent.hasFileDescriptors()) {\n")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "services/core/java/com/android/server/wm/ActivityStarter.java"
            target.parent.mkdir(parents=True)
            target.write_text("\n" * 715 + "        try {\n" + context)
            result = subprocess.run(["git", "apply", str(patch)], cwd=root,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(module.transform(module.original).strip(), target.read_text())

if __name__ == "__main__": unittest.main()
