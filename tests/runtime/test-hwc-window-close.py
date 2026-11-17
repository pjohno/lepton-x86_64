#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Closing a desktop window must end the game on Android 14 (patch 0012).

The Waydroid task service calls IActivityTaskManager over raw binder with
hard-coded transaction codes. Upstream's Android 13 codes are one method off
on Android 14, so a window close ran getTasks() and removed nothing. This
applies the HWC patches in order to the pinned submodule, checks the codes,
and compiles the close decision on the host. When a prepared AOSP checkout is
available, the codes are also checked against its IActivityTaskManager.aidl.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SUBMODULE = ROOT / 'image-14/android_hardware_waydroid'
PATCHES = [ROOT / 'image-14/patches' / name for name in (
    '0009-hwc-local-wayland-fullscreen.patch',
    '0011-hwc-present-framebuffer-after-color-layers.patch',
    '0012-hwc-window-close-android14-task-codes.patch')]
BINDER = 'interfaces/task/1.0/default/binder-interfaces/IActivityTaskManager.cpp'
METHODS = ('setFocusedTask', 'removeTask', 'removeAllVisibleRecentTasks')
ANDROID14 = {'setFocusedTask': 19, 'removeTask': 20, 'removeAllVisibleRecentTasks': 21}


def transaction_codes(source):
    """{method: [codes]} from the Bp (transact) and Bn (case) sides."""
    found = {}
    for code, name in re.findall(r'FIRST_CALL_TRANSACTION \+ (\d+) /\* (\w+) \*/', source):
        found.setdefault(name, []).append(int(code))
    return found


def aidl_method_index(aidl_text):
    """Declaration order of IActivityTaskManager methods (AIDL's default codes)."""
    text = re.sub(r'/\*.*?\*/', '', aidl_text, flags=re.S)
    text = re.sub(r'//[^\n]*', '', text)
    # Hide annotation strings before removing annotations, including nested
    # Java annotation calls inside JavaPassthrough's quoted argument.
    text = re.sub(r'"(?:\\.|[^"\\])*"', '""', text)
    text = re.sub(r'@\w+(?:\([^()]*\))?', '', text)
    body = text[text.index('interface IActivityTaskManager'):]
    body = body[body.index('{') + 1:body.rindex('}')]
    names = []
    for decl in body.split(';'):
        decl = decl.strip()
        if not decl or decl.startswith('const '):
            continue
        match = re.fullmatch(r'[\w.<>,\[\] ?]+\s+(\w+)\s*\([^;]*\)', decl)
        if not match:
            # Do not silently ignore a changed AIDL syntax (e.g. explicit IDs)
            # and accidentally certify the wrong declaration order.
            raise ValueError(f'Unsupported AIDL declaration: {decl}')
        name = match.group(1)
        if name in names:
            raise ValueError(f'Duplicate AIDL method: {name}')
        names.append(name)
    return {name: index for index, name in enumerate(names)}


def prepared_aosp():
    relative = 'frameworks/base/core/java/android/app/IActivityTaskManager.aidl'
    explicit = os.environ.get('LEPTON_AOSP_DIR')
    if explicit:
        aidl = Path(explicit) / relative
        if not aidl.is_file():
            raise FileNotFoundError(f'Explicit LEPTON_AOSP_DIR has no {relative}: {explicit}')
        return aidl
    candidates = []
    config = ROOT / '.build-env'
    if config.is_file():
        # Read literal paths only; never execute a developer's shell config.
        values = dict(re.findall(r'^LEPTON_(AOSP|OUTPUT)_DIR=["\']?([^"\'\n]+)["\']?$',
                                 config.read_text(), flags=re.M))
        if 'AOSP' in values:
            candidates.append(values['AOSP'])
        if 'OUTPUT' in values:
            candidates.append(os.path.join(values['OUTPUT'], 'aosp'))
    for candidate in candidates:
        aidl = Path(candidate) / relative
        if aidl.is_file():
            return aidl
    return None


class AidlOrderTests(unittest.TestCase):
    """Offline parser checks: no submodule, AOSP checkout or downloads needed."""

    def test_order_annotations_comments_and_constants(self):
        source = '''
        interface IActivityTaskManager {
            const int UNUSED = 42;
            // fakeMethod();
            @JavaPassthrough(annotation="@annotation.Call(nested())")
            void before(in List<String> values);
            /* void alsoFake(); */
            void setFocusedTask(int id);
            boolean removeTask(int id);
            oneway void removeAllVisibleRecentTasks();
        }
        '''
        index = aidl_method_index(source)
        self.assertEqual(index, dict(before=0, setFocusedTask=1, removeTask=2,
                                     removeAllVisibleRecentTasks=3))
        changed = aidl_method_index(source.replace('void before', 'void inserted(); void before'))
        self.assertEqual(changed['removeTask'], index['removeTask'] + 1)

    def test_no_checkout_is_optional_but_explicit_missing_checkout_fails(self):
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(Path, 'is_file', return_value=False):
            self.assertIsNone(prepared_aosp())
        with tempfile.TemporaryDirectory() as empty:
            with mock.patch.dict(os.environ, {'LEPTON_AOSP_DIR': empty}):
                with self.assertRaises(FileNotFoundError):
                    prepared_aosp()

    def test_explicit_transaction_ids_and_unknown_syntax_fail_closed(self):
        for declaration in ('void removeTask(int id) = 42;', 'unrecognised;',
                            'void same(); void same();'):
            with self.subTest(declaration=declaration), self.assertRaises(ValueError):
                aidl_method_index('interface IActivityTaskManager {' + declaration + '}')


class WindowCloseTests(unittest.TestCase):
    def setUp(self):
        if not (SUBMODULE / 'hwcomposer/wayland-hwc.cpp').is_file():
            self.skipTest('image-14/android_hardware_waydroid is not checked out')
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tree = Path(temp.name)
        for part in ('hwcomposer', 'interfaces/task'):
            shutil.copytree(SUBMODULE / part, self.tree / part)
        for patch in PATCHES:
            subprocess.run(['git', 'apply', '--no-index', str(patch)], cwd=self.tree, check=True)

    def test_android14_transaction_codes_on_both_sides(self):
        upstream = transaction_codes((SUBMODULE / BINDER).read_text())
        # The pinned source still carries the Android 13 numbers this fixes.
        self.assertEqual(upstream['removeAllVisibleRecentTasks'], [22, 22])
        patched = transaction_codes((self.tree / BINDER).read_text())
        self.assertEqual(set(patched), set(METHODS))
        for name in METHODS:
            self.assertEqual(patched[name], [ANDROID14[name]] * 2, name)

    def test_codes_match_the_prepared_android_framework(self):
        aidl = prepared_aosp()
        if aidl is None:
            self.skipTest('no prepared AOSP checkout (set LEPTON_AOSP_DIR or LEPTON_OUTPUT_DIR)')
        index = aidl_method_index(aidl.read_text())
        patched = transaction_codes((self.tree / BINDER).read_text())
        for name in METHODS:
            self.assertEqual(patched[name], [index[name]] * 2, f'{name} in {aidl}')

    def test_close_decision(self):
        cpp = self.tree / 'test.cpp'
        cpp.write_text(r'''
#include "hwcomposer/lepton-close.h"
#include <cassert>
#include <cstring>
using lepton::close_action;
using lepton::close_action_for;
int main() {
    // The full-UI window (Lepton's only window) ends the visible tasks.
    assert(close_action_for("0", true) == close_action::remove_visible_tasks);
    assert(close_action_for("17", true) == close_action::remove_task);
    // No task behind the window, or no service: nothing is removed.
    assert(close_action_for("none", true) == close_action::window_only);
    assert(close_action_for("none", false) == close_action::window_only);
    assert(close_action_for("0", false) == close_action::no_task_service);
    assert(close_action_for("17", false) == close_action::no_task_service);
    // Never pass something stoi/stoul would reject or truncate.
    for (const char *bad : {"", "-1", "12a", "Waydroid", "4294967296", " 1"})
        assert(close_action_for(bad, true) == close_action::invalid_task_id);
    assert(std::strcmp(lepton::close_action_name(close_action::remove_visible_tasks),
                       "removeAllVisibleRecentTasks") == 0);
}
''')
        subprocess.run(['c++', '-std=c++17', '-Wall', '-Wextra', '-Werror', str(cpp), '-I', str(self.tree),
                        '-o', str(self.tree / 'test')], check=True)
        subprocess.run([str(self.tree / 'test')], check=True)

    def test_close_handler_logs_and_uses_the_decision(self):
        source = (self.tree / 'hwcomposer/wayland-hwc.cpp').read_text()
        handler = source[source.index('xdg_toplevel_handle_close(void *data'):]
        handler = handler[:handler.index('\n}\n')]
        self.assertIn('lepton::close_action_for(window->taskID, display->task != nullptr)', handler)
        self.assertIn('ALOGI("Lepton: xdg_toplevel.close task=%s app=%s action=%s"', handler)
        self.assertNotIn('stoi(', handler)
        # The window bookkeeping that hides the closed window is unchanged.
        self.assertIn('display->ignored_apps.insert(key);', handler)
        self.assertIn('display->windows.erase(key);', handler)
        # Verbose per-configure output only with lepton.hwc.trace.
        configure = source[source.index('xdg_toplevel_handle_configure(void *data'):]
        configure = configure[:configure.index('\n}\n')]
        self.assertRegex(configure, r'if \(property_get_bool\("lepton\.hwc\.trace", false\)\)\s*\n\s*ALOGI\(')
        for patch in reversed(PATCHES):
            subprocess.run(['git', 'apply', '--no-index', '--reverse', str(patch)], cwd=self.tree, check=True)
        for part in ('hwcomposer/wayland-hwc.cpp', BINDER, 'interfaces/task/1.0/default/WaydroidTask.cpp'):
            self.assertEqual((self.tree / part).read_text(), (SUBMODULE / part).read_text(), part)

    def test_patch_is_registered_for_prepare_and_provenance(self):
        prepare = (ROOT / 'image-14/scripts/prepare-x86_64.sh').read_text()
        provenance = (ROOT / 'image-14/scripts/lib/image-provenance.sh').read_text()
        name = PATCHES[-1].name
        self.assertIn(f'apply_custom /workspace/output/hardware/waydroid /workspace/patches/{name}', prepare)
        self.assertIn(f'"hardware/waydroid|{name}"', provenance)
        # Applied after 0011, which touches the same project.
        self.assertLess(prepare.index('0011-hwc-present'), prepare.index(name))


if __name__ == '__main__':
    unittest.main()
