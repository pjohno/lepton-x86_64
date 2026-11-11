#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""lepton-release-manager: release parsing, version order, downloads,
verification and install decisions. Fake GitHub transport and fake UI; no
network, no real Steam, nothing outside a throwaway home."""
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "compat_tool/tools/lepton-release-manager"


def load():
    loader = importlib.machinery.SourceFileLoader("lepton_release_manager_test", str(SCRIPT))
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    loader.exec_module(module)
    return module


M = load()
BASE = "https://github.com/pjohno/lepton-x86_64/releases/download/"


def sha(data):
    return hashlib.sha256(data).hexdigest()


class FakeTransport:
    """GitHub as a dict: url -> bytes (or a list for the release API)."""

    def __init__(self):
        self.files, self.pages, self.downloads, self.truncate = {}, {}, [], {}

    def get_json(self, url):
        data, next_url = self.pages[url]
        return data, next_url

    def download(self, url, destination, progress=None):
        M.check_url(url)
        self.downloads.append(url.rsplit("/", 1)[-1])
        data = self.files[url]
        data = data[: self.truncate[url]] if url in self.truncate else data
        with open(destination, "xb") as out:
            out.write(data)
        if progress:
            progress(len(data), len(data))
        return len(data)


class FakeUI:
    graphical = False

    def __init__(self, answers=(), confirm=True):
        self.answers, self.confirm, self.questions, self.notes, self.infos = list(answers), confirm, [], [], []

    def note(self, text):
        self.notes.append(text)

    def info(self, text):
        self.infos.append(text)

    error = info

    def question(self, text, ok_label="Continue"):
        self.questions.append(text)
        return self.confirm(text) if callable(self.confirm) else self.confirm

    def choose(self, text, rows):
        self.last_rows = rows
        return self.answers.pop(0) if self.answers else None

    def text(self, title, body):
        self.notes.append(body)

    def progress(self, text):
        class P:
            def __enter__(s):
                return lambda done, total: None

            def __exit__(s, *exc):
                return False
        return P()


def release_item(tag, files, prerelease=False, draft=False, extra=(), state="uploaded", prefix=M.PREFIX):
    names = M.asset_names(tag, prefix)
    assets = []
    for key in ("archive", "manifest", "installer", "signature"):
        if key in files:
            assets.append(dict(name=names[key], size=len(files[key]), state=state,
                               browser_download_url=BASE + tag + "/" + names[key]))
    assets += [dict(name=n, size=1, state="uploaded", browser_download_url=BASE + tag + "/" + n) for n in extra]
    return dict(tag_name=tag, draft=draft, prerelease=prerelease, assets=assets,
                published_at=None if draft else "2026-11-0%dT10:00:00Z" % (len(tag) % 9 + 1),
                html_url="https://github.com/pjohno/lepton-x86_64/releases/tag/" + tag)


def bundle_files(tag, archive=b"archive-bytes", installer=b"#!/bin/bash\necho installer\n", prefix=M.PREFIX):
    names = M.asset_names(tag, prefix)
    manifest = ("%s  %s\n%s  %s\n" % (sha(archive), names["archive"], sha(installer), names["installer"])).encode()
    return dict(archive=archive, installer=installer, manifest=manifest)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = self.tmp / "home"
        self.downloads = self.home / "Downloads/lepton-deck-bundles"
        self.home.mkdir()
        for name, value in (("HOME", self.home), ("DOWNLOADS", self.downloads),
                            ("DATA", self.home / ".local/share")):
            patcher = mock.patch.object(M, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        env = mock.patch.dict(os.environ, {"HOME": str(self.home)})
        env.start()
        self.addCleanup(env.stop)
        self.transport = FakeTransport()

    def publish(self, tag, files, **kw):
        item = release_item(tag, files, **kw)
        for key, data in files.items():
            self.transport.files[BASE + tag + "/" + M.asset_names(tag, kw.get("prefix", M.PREFIX))[key]] = data
        return item

    def release(self, tag="v0.1.0-alpha", **files):
        files = files or bundle_files(tag)
        releases, skipped = M.parse_releases([self.publish(tag, files, prerelease="-" in tag)])
        self.assertEqual(skipped, [])
        return releases[0], files


class Versions(unittest.TestCase):
    def test_semver_order_not_lexical(self):
        tags = ["v0.10.0", "v0.2.0", "v0.2.0-alpha", "v0.2.0-alpha.10", "v0.2.0-alpha.2",
                "v0.2.0-beta", "v0.2.0-alpha.beta", "v1.0.0-rc.1", "v0.9.9"]
        ordered = [str(v) for v in sorted(M.Version(t) for t in tags)]
        self.assertEqual(ordered, ["v0.2.0-alpha", "v0.2.0-alpha.2", "v0.2.0-alpha.10",
                                   "v0.2.0-alpha.beta", "v0.2.0-beta", "v0.2.0", "v0.9.9", "v0.10.0",
                                   "v1.0.0-rc.1"])

    def test_invalid_tags(self):
        for tag in ("0.1.0", "v0.1", "v01.0.0", "v0.1.0+build", "v0.1.0-", "v0.1.0-al pha", "latest", ""):
            self.assertIsNone(M.parse_version(tag), tag)
        self.assertTrue(M.Version("v0.1.0-alpha").is_prerelease)
        self.assertEqual(M.packaged_tool_id("v0.1.0-alpha.2"), "lepton_x86_64_v0_1_0_alpha_2")


class Releases(Base):
    def test_default_asset_names(self):
        self.assertEqual(M.asset_names("v1.2.3"), {
            "archive": "lepton-x86_64-v1.2.3.tar.gz",
            "manifest": "lepton-x86_64-v1.2.3.tar.gz.sha256",
            "signature": "lepton-x86_64-v1.2.3.tar.gz.sha256.sig",
            "installer": "lepton-x86_64-v1.2.3.install.sh",
        })

    def test_mixed_naming_conventions_are_refused(self):
        tag = "v0.1.0"
        files = bundle_files(tag)
        item = self.publish(tag, files)
        item["assets"][0]["name"] = M.asset_names(tag, M.LEGACY_PREFIX)["archive"]
        releases, skipped = M.parse_releases([item])
        self.assertEqual(releases, [])
        self.assertIn("unexpected", skipped[0][1])

    def test_parsing_filters_and_orders(self):
        good = bundle_files("v0.1.0")
        items = [
            self.publish("v0.1.0", good),
            self.publish("v0.2.0-alpha", bundle_files("v0.2.0-alpha"), prerelease=True),
            self.publish("v0.3.0-alpha", bundle_files("v0.3.0-alpha"), prerelease=True, draft=True),
            self.publish("v0.2.1-alpha", {"archive": b"x", "manifest": b"x"}, prerelease=True),
            self.publish("v0.2.2", bundle_files("v0.2.2"), extra=["notes.txt"]),
            self.publish("v0.2.3", bundle_files("v0.2.3"), state="new"),
            self.publish("nightly", bundle_files("nightly")),
        ]
        releases, skipped = M.parse_releases(items)
        self.assertEqual([r.tag for r in releases], ["v0.2.0-alpha", "v0.1.0"])
        self.assertNotIn("v0.3.0-alpha", [t for t, _ in skipped])  # drafts are silently ignored
        reasons = dict(skipped)
        self.assertIn("missing", reasons["v0.2.1-alpha"])
        self.assertIn("unexpected", reasons["v0.2.2"])
        self.assertIn("missing", reasons["v0.2.3"])
        self.assertIn("not a Lepton version", reasons["nightly"])
        self.assertEqual(M.latest(releases, False).tag, "v0.1.0")
        self.assertEqual(M.latest(releases, True).tag, "v0.2.0-alpha")
        self.assertIsNone(M.latest(releases[:1], False))
        # A version with a prerelease part is a prerelease even if not flagged.
        unflagged, _ = M.parse_releases([self.publish("v0.4.0-alpha", bundle_files("v0.4.0-alpha"))])
        self.assertTrue(unflagged[0].prerelease)

    def test_pagination_and_alpha_default(self):
        page1 = [self.publish("v0.1.0", bundle_files("v0.1.0"))]
        page2 = [self.publish("v0.2.0-alpha", bundle_files("v0.2.0-alpha"), prerelease=True)]
        self.transport.pages = {M.API: (page1, "https://api.github.com/page2"),
                                "https://api.github.com/page2": (page2, None)}
        releases, _ = M.fetch_releases(self.transport)
        self.assertEqual([r.tag for r in releases], ["v0.2.0-alpha", "v0.1.0"])
        ui = FakeUI(answers=[None])
        with mock.patch.object(M, "installed_tools", return_value=[]):
            with self.assertRaises(M.Cancelled):
                M.main_menu(ui, self.transport)
        self.assertEqual(ui.last_rows[0][0], "alpha")  # alpha preselected during the alpha period
        self.assertIn("v0.2.0-alpha", ui.last_rows[0][1])
        self.assertIn("v0.1.0", ui.last_rows[1][1])

    def test_missing_category_is_explained(self):
        self.transport.pages = {M.API: ([self.publish("v0.1.0-alpha", bundle_files("v0.1.0-alpha"),
                                                      prerelease=True)], None)}
        ui = FakeUI(answers=["stable"])
        with mock.patch.object(M, "installed_tools", return_value=[]):
            self.assertIsNone(M.main_menu(ui, self.transport))
        self.assertIn("No stable release has been published yet", ui.infos[0])

    def test_urls_are_restricted(self):
        M.check_url("https://github.com/pjohno/x")
        M.check_url("https://release-assets.githubusercontent.com/x")
        for url in ("http://github.com/x", "https://evil.example/x", "https://github.com.evil.example/x",
                    "file:///etc/passwd", "ftp://github.com/x"):
            with self.assertRaises(M.ReleaseError):
                M.check_url(url)
        with self.assertRaises(M.ReleaseError):
            M._SafeRedirect().redirect_request(None, None, 302, "", {}, "https://evil.example/a")

    def test_rate_limit_and_offline_messages(self):
        transport = M.Transport()
        headers = {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800000000"}
        error = urllib.error.HTTPError(M.API, 403, "rate limit", headers, io.BytesIO())
        with mock.patch.object(transport.opener, "open", side_effect=error):
            with self.assertRaisesRegex(M.ReleaseError, "limit for anonymous requests"):
                transport.get_json(M.API)
        missing = urllib.error.HTTPError(M.API, 404, "Not Found", {}, io.BytesIO())
        with mock.patch.object(transport.opener, "open", side_effect=missing):
            with self.assertRaisesRegex(M.ReleaseError, "may not be public"):
                transport.get_json(M.API)
        with mock.patch.object(transport.opener, "open", side_effect=urllib.error.URLError("no route")):
            with self.assertRaisesRegex(M.ReleaseError, "Could not connect to GitHub"):
                transport.get_json(M.API)


class Downloads(Base):
    def test_legacy_release_download_preserves_names_and_manifest(self):
        tag = "v0.1.0"
        files = bundle_files(tag, prefix=M.LEGACY_PREFIX)
        item = self.publish(tag, files, prefix=M.LEGACY_PREFIX)
        releases, skipped = M.parse_releases([item])
        self.assertEqual(skipped, [])
        release = releases[0]
        self.assertEqual(release.names, M.asset_names(tag, M.LEGACY_PREFIX))
        verified = M.download_release(release, FakeUI(), self.transport, keys=None)
        self.assertEqual(verified.archive.read_bytes(), files["archive"])
        self.assertEqual(verified.installer.read_bytes(), files["installer"])
        self.assertEqual((self.downloads / release.names["manifest"]).read_bytes(), files["manifest"])

    def test_download_cache_and_redownload(self):
        release, files = self.release()
        verified = M.download_release(release, FakeUI(), self.transport, keys=None)
        self.assertFalse(verified.authenticated)
        names = release.names
        for key in ("archive", "installer", "manifest"):
            self.assertEqual((self.downloads / names[key]).read_bytes(), files[key])
        self.assertEqual(sorted(p.name for p in self.downloads.iterdir()),
                         sorted([names["archive"], names["installer"], names["manifest"]]))
        # Second time: only the small manifest is fetched again.
        self.transport.downloads.clear()
        M.download_release(release, FakeUI(), self.transport, keys=None)
        self.assertEqual(self.transport.downloads, [names["manifest"]])
        # A damaged cached archive is downloaded again.
        (self.downloads / names["archive"]).write_bytes(b"damaged")
        self.transport.downloads.clear()
        M.download_release(release, FakeUI(), self.transport, keys=None)
        self.assertIn(names["archive"], self.transport.downloads)
        self.assertEqual((self.downloads / names["archive"]).read_bytes(), files["archive"])

    def test_interrupted_and_corrupt_downloads_leave_nothing(self):
        release, files = self.release()
        url = BASE + release.tag + "/" + release.names["archive"]
        self.transport.truncate[url] = 5
        with self.assertRaisesRegex(M.ReleaseError, "incomplete"):
            M.download_release(release, FakeUI(), self.transport, keys=None)
        self.assertFalse((self.downloads / release.names["archive"]).exists())
        self.assertEqual([p.name for p in self.downloads.iterdir() if p.name.startswith(".")], [])
        del self.transport.truncate[url]
        self.transport.files[url] = b"X" * len(files["archive"])  # same size, wrong content
        with self.assertRaisesRegex(M.ReleaseError, "does not match the release checksum"):
            M.download_release(release, FakeUI(), self.transport, keys=None)
        self.assertFalse((self.downloads / release.names["archive"]).exists())
        self.assertFalse((self.downloads / release.names["manifest"]).exists())

    def test_manifest_must_list_exactly_the_release_files(self):
        tag = "v0.1.0-alpha"
        files = bundle_files(tag)
        files["manifest"] += ("%s  other.sh\n" % ("0" * 64)).encode()
        release, _ = self.release(tag, **files)
        with self.assertRaisesRegex(M.ReleaseError, "exactly the archive and installer"):
            M.download_release(release, FakeUI(), self.transport, keys=None)
        files["manifest"] = b"not a checksum\n"
        release, _ = self.release(tag, **files)
        with self.assertRaisesRegex(M.ReleaseError, "malformed"):
            M.download_release(release, FakeUI(), self.transport, keys=None)

    def test_insufficient_space(self):
        release, _ = self.release()
        usage = shutil.disk_usage(self.tmp)._replace(free=10)
        with mock.patch.object(M.shutil, "disk_usage", return_value=usage):
            with self.assertRaisesRegex(M.ReleaseError, "Not enough free space"):
                M.download_release(release, FakeUI(), self.transport, keys=None)

    def test_download_dir_must_be_inside_home(self):
        outside = self.tmp / "outside"
        outside.mkdir()
        self.downloads.parent.mkdir(parents=True)
        self.downloads.symlink_to(outside)
        release, _ = self.release()
        with self.assertRaisesRegex(M.ReleaseError, "Refusing to use"):
            M.download_release(release, FakeUI(), self.transport, keys=None)


@unittest.skipUnless(shutil.which("ssh-keygen"), "needs ssh-keygen")
class Signatures(Base):
    def setUp(self):
        super().setUp()
        self.key = self.tmp / "key"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "test", "-f", str(self.key)],
                       check=True)
        public = (self.tmp / "key.pub").read_text().split()
        self.keys = self.tmp / "allowed_signers"
        self.keys.write_text('lepton-release namespaces="lepton-release" %s %s\n' % (public[0], public[1]))

    def sign(self, data, key=None):
        path = self.tmp / "manifest"
        path.write_bytes(data)
        Path(str(path) + ".sig").unlink(missing_ok=True)
        subprocess.run(["ssh-keygen", "-q", "-Y", "sign", "-f", str(key or self.key), "-n", "lepton-release",
                        str(path)], check=True, stderr=subprocess.DEVNULL)
        return Path(str(path) + ".sig").read_bytes()

    def test_legacy_signature_authenticates_original_manifest(self):
        tag = "v0.1.0"
        files = bundle_files(tag, prefix=M.LEGACY_PREFIX)
        files["signature"] = self.sign(files["manifest"])
        item = self.publish(tag, files, prefix=M.LEGACY_PREFIX)
        releases, skipped = M.parse_releases([item])
        self.assertEqual(skipped, [])
        verified = M.download_release(releases[0], FakeUI(), self.transport, keys=self.keys)
        self.assertTrue(verified.authenticated)

    def test_valid_signature_authenticates(self):
        files = bundle_files("v0.1.0-alpha")
        files["signature"] = self.sign(files["manifest"])
        release, _ = self.release(**files)
        self.assertTrue(release.signed)
        verified = M.download_release(release, FakeUI(), self.transport, keys=self.keys)
        self.assertTrue(verified.authenticated)
        self.assertTrue((self.downloads / release.names["signature"]).is_file())

    def test_wrong_key_or_altered_manifest_is_refused(self):
        other = self.tmp / "other"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(other)], check=True)
        files = bundle_files("v0.1.0-alpha")
        files["signature"] = self.sign(files["manifest"], other)
        release, _ = self.release(**files)
        with self.assertRaisesRegex(M.ReleaseError, "signature is NOT valid"):
            M.download_release(release, FakeUI(), self.transport, keys=self.keys)
        self.assertEqual(list(self.downloads.iterdir()), [])
        files = bundle_files("v0.1.0-alpha")
        files["signature"] = self.sign(files["manifest"])
        files["manifest"] = files["manifest"].replace(b"a", b"b", 1)
        release, _ = self.release(**files)
        with self.assertRaisesRegex(M.ReleaseError, "signature is NOT valid"):
            M.download_release(release, FakeUI(), self.transport, keys=self.keys)

    def test_unsigned_release_refused_when_a_key_is_trusted(self):
        release, _ = self.release()
        with self.assertRaisesRegex(M.ReleaseError, "not signed"):
            M.download_release(release, FakeUI(), self.transport, keys=self.keys)
        self.assertEqual(self.transport.downloads, [])

    def test_trusted_keys_file_with_only_comments_means_no_key(self):
        empty = self.tmp / "keys"
        empty.mkdir()
        (empty / "allowed_signers").write_text("# no keys yet\n\n")
        with mock.patch.object(M, "HERE", empty):
            self.assertIsNone(M.signing_keys())
        repo_keys = SCRIPT.parents[1] / "release-keys/allowed_signers"
        self.assertTrue(repo_keys.is_file())


def tool(tool_id, bundle, variant="base", shortcuts=0):
    return dict(id=tool_id, dir="/x/" + tool_id, name="Lepton x86_64 (community) - " + bundle, kind="install",
                bundle=bundle, version=M.parse_version(bundle), variant=variant, shortcuts=shortcuts)


class Installing(Base):
    def test_nothing_runs_before_verification(self):
        release, files = self.release()
        url = BASE + release.tag + "/" + release.names["installer"]
        self.transport.files[url] = b"#!/bin/bash\necho tampered\n"
        with mock.patch.object(M, "run_installer") as run:
            with self.assertRaises(M.ReleaseError):
                M.install(release, None, FakeUI(), self.transport, keys=None, tools=[])
            run.assert_not_called()

    def test_unsigned_needs_explicit_confirmation(self):
        release, _ = self.release()
        ui = FakeUI(confirm=False)
        with mock.patch.object(M, "run_installer") as run:
            with self.assertRaises(M.Cancelled):
                M.install(release, None, ui, self.transport, keys=None, tools=[])
            run.assert_not_called()
        self.assertIn("not signed", ui.questions[-1])
        self.assertIn("not prove who published", ui.questions[-1])

    def test_new_and_replace_arguments_and_no_silent_cleanup(self):
        release, _ = self.release()
        calls = []

        def record(args, **kw):
            calls.append(list(args))
            return subprocess.CompletedProcess(args, 0, "", "")
        with mock.patch.object(M, "run_installer", return_value=True) as run, \
                mock.patch.object(M, "installed_tools", return_value=[tool("lepton_x86_64_old", "v0.0.9")]), \
                mock.patch.object(M.subprocess, "run", side_effect=record):
            ui = FakeUI(confirm=lambda text: "Remove older" not in text)
            M.install(release, None, ui, self.transport, keys=None, tools=[])
            self.assertEqual(run.call_args[0][1], ["--new"])
            M.install(release, "lepton_x86_64_old", ui, self.transport, keys=None, tools=[])
            self.assertEqual(run.call_args[0][1], ["--into", "lepton_x86_64_old"])
        # Cleanup was offered but declined: lepton-manage-installs never ran,
        # and the manager itself never removes anything.
        self.assertTrue(any("Remove older" in q for q in ui.questions))
        self.assertEqual(calls, [])
        self.assertNotIn('"--remove"', SCRIPT.read_text(encoding="utf-8"))

    def test_existing_tool_id_needs_replace(self):
        release, _ = self.release()
        with mock.patch.object(M, "run_installer") as run:
            with self.assertRaisesRegex(M.ReleaseError, "already exists"):
                M.install(release, None, FakeUI(), self.transport, keys=None,
                          tools=[tool(M.packaged_tool_id(release.tag), release.tag)])
            run.assert_not_called()

    def test_installer_rechecked_before_running(self):
        release, _ = self.release()
        verified = M.download_release(release, FakeUI(), self.transport, keys=None)
        verified.installer.write_text("#!/bin/bash\necho swapped\n")
        with mock.patch.object(M.subprocess, "run") as run:
            with self.assertRaisesRegex(M.ReleaseError, "changed after it was verified"):
                M.run_installer(verified, ["--new"], FakeUI())
            run.assert_not_called()


class Decisions(Base):
    def setUp(self):
        super().setUp()
        items = [self.publish(t, bundle_files(t), prerelease="-" in t)
                 for t in ("v0.1.0-alpha", "v0.2.0-alpha", "v0.3.0", "v0.4.0-alpha")]
        self.releases, _ = M.parse_releases(items)

    def test_repair_targets(self):
        release, reason = M.repair_target(tool("lepton_x86_64_v0_2_0_alpha", "v0.2.0-alpha"), self.releases)
        self.assertEqual(release.tag, "v0.2.0-alpha")
        for t, expected in ((tool("lepton_gapps_x", "gapps-ndk-20261103", "GApps"), "GApps install"),
                            (tool("lepton_x86_64_combined_test", "combined-test"), "not installed from a published"),
                            (tool("lepton_x86_64_v0_0_1", "v0.0.1"), "not (or no longer) published"),
                            (tool("lepton_ndk", "v0.2.0-alpha", "NDK"), "NDK install")):
            release, reason = M.repair_target(t, self.releases)
            self.assertIsNone(release)
            self.assertIn(expected, reason)

    def test_repair_keeps_the_tool_id(self):
        installed = [tool("lepton_x86_64_mine", "v0.2.0-alpha", shortcuts=3)]
        ui = FakeUI(answers=["lepton_x86_64_mine"])
        with mock.patch.object(M, "installed_tools", return_value=installed), \
                mock.patch.object(M, "install", return_value=True) as install:
            M.flow_repair(ui, self.releases, self.transport)
        release, target = install.call_args[0][:2]
        self.assertEqual((release.tag, target), ("v0.2.0-alpha", "lepton_x86_64_mine"))
        ui = FakeUI(answers=["lepton_gapps_x"])
        with mock.patch.object(M, "installed_tools", return_value=[tool("lepton_gapps_x", "v0.2.0-alpha", "GApps")]), \
                mock.patch.object(M, "install") as install:
            M.flow_repair(ui, self.releases, self.transport)
            install.assert_not_called()
        self.assertIn("GApps", ui.infos[0])

    def test_updates(self):
        self.assertEqual(M.update_for(tool("a", "v0.1.0-alpha"), self.releases).tag, "v0.4.0-alpha")
        # A stable install is offered the newest stable release first.
        self.assertEqual(M.update_for(tool("b", "v0.2.9"), self.releases).tag, "v0.3.0")
        self.assertIsNone(M.update_for(tool("c", "v0.4.0-alpha"), self.releases))
        self.assertIsNone(M.update_for(tool("d", "v0.1.0-alpha", "GApps"), self.releases))
        self.assertIsNone(M.update_for(tool("e", "local-build"), self.releases))

    def test_replace_choices_and_warnings(self):
        tools = [tool("lepton_x86_64_new", "v0.4.0-alpha", shortcuts=2), tool("lepton_gapps", "x", "GApps")]
        old = next(r for r in self.releases if r.tag == "v0.1.0-alpha")
        ui = FakeUI(answers=["lepton_x86_64_new"])
        kind, target = M.choose_target(ui, old, tools)
        self.assertEqual((kind, target["id"]), ("replace", "lepton_x86_64_new"))
        self.assertEqual([r[0] for r in ui.last_rows], ["new", "lepton_x86_64_new"])
        self.assertIn("DOWNGRADE", ui.last_rows[1][1])
        self.assertIn("2 Steam shortcut(s)", ui.last_rows[1][1])
        M.confirm_replace(ui, old, tools[0])
        self.assertIn("DOWNGRADE", ui.questions[-1])
        self.assertIn("fresh Android data", ui.questions[-1])
        same = next(r for r in self.releases if r.tag == "v0.4.0-alpha")
        M.confirm_replace(ui, same, tools[0])
        self.assertIn("keep their Android data", ui.questions[-1])


class Windows(Base):
    """zenity/kdialog arguments, with stand-ins that log them (no real windows)."""

    def stand_in(self, name, output, rc=0):
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir(exist_ok=True)
        log = self.tmp / (name + ".log")
        script = bin_dir / name
        script.write_text('#!/bin/sh\nprintf "%%s\\n" "$@" >> "%s"\nprintf "%s"\nexit %d\n' % (log, output, rc))
        script.chmod(0o755)
        return bin_dir, log

    def test_zenity_and_kdialog(self):
        bin_dir, log = self.stand_in("zenity", "alpha\\n")
        with mock.patch.dict(os.environ, {"PATH": "%s:%s" % (bin_dir, os.environ["PATH"])}):
            ui = M.UI("zenity")
            self.assertEqual(ui.choose("Pick", [("alpha", "Latest alpha"), ("stable", "Latest stable")]), "alpha")
            args = log.read_text().splitlines()
            self.assertIn("--radiolist", args)
            self.assertIn("--hide-column=2", args)
            self.assertEqual(args[args.index("alpha") - 1], "TRUE")      # first row preselected
            self.assertEqual(args[args.index("stable") - 1], "FALSE")
            log.unlink()
            self.assertTrue(ui.question("Sure?", "Install anyway"))
            self.assertIn("--default-cancel", log.read_text().splitlines())   # Cancel is the default
        bin_dir, log = self.stand_in("kdialog", "stable", rc=0)
        with mock.patch.dict(os.environ, {"PATH": "%s:%s" % (bin_dir, os.environ["PATH"])}):
            ui = M.UI("kdialog")
            self.assertEqual(ui.choose("Pick", [("alpha", "A"), ("stable", "S")]), "stable")
            self.assertEqual(log.read_text().splitlines()[-2:], ["S", "off"])
        bin_dir, _ = self.stand_in("zenity", "", rc=1)
        with mock.patch.dict(os.environ, {"PATH": "%s:%s" % (bin_dir, os.environ["PATH"])}):
            self.assertIsNone(M.UI("zenity").choose("Pick", [("alpha", "A")]))   # cancelled
            self.assertFalse(M.UI("zenity").question("Sure?"))


class InstalledTools(Base):
    def test_reads_versions_with_lepton_manage_installs(self):
        share = self.home / ".local/share"
        config = self.home / ".config/lepton-x86_64"
        config.mkdir(parents=True)
        for tool_id, bundle, gapps in (("lepton_x86_64_v0_1_0_alpha", "v0.1.0-alpha", False),
                                       ("lepton_gapps_x", "gapps-test", True)):
            d = share / tool_id
            (d / "compat_tool/liblepton").mkdir(parents=True)
            (d / "compat_tool/lepton").write_text("#!/bin/sh\n")
            (d / "BUNDLE.json").write_text(json.dumps(dict(bundle_id=bundle, gapps=gapps, ndk=False)))
            (config / (tool_id + ".env")).write_text(
                "LEPTON_X86_TOOL_ID=%s\nLEPTON_X86_TOOL_NAME=%s\nLEPTON_X86_INSTALL_DIR=%s\n" % (tool_id, tool_id, d))
        with mock.patch.dict(os.environ, {"XDG_DATA_HOME": "", "XDG_CONFIG_HOME": ""}):
            tools = {t["id"]: t for t in M.installed_tools()}
        self.assertEqual(str(tools["lepton_x86_64_v0_1_0_alpha"]["version"]), "v0.1.0-alpha")
        self.assertEqual(tools["lepton_gapps_x"]["variant"], "GApps")
        self.assertIsNone(tools["lepton_gapps_x"]["version"])

    def test_component_kind_includes_widevine_and_reads_legacy_metadata(self):
        self.assertEqual(M.component_kind(dict(gapps=False, ndk=False)), "base")
        self.assertEqual(M.component_kind(dict(gapps=False, ndk=False, widevine=False)), "base")
        self.assertEqual(M.component_kind(dict(gapps=False, ndk=False, widevine=True)), "Widevine")
        self.assertEqual(M.component_kind(dict(gapps=True, ndk=True, widevine=True)), "GApps + NDK + Widevine")
        self.assertEqual(M.component_kind({}), "base")


if __name__ == "__main__":
    unittest.main()
