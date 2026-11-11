#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Release manager + real bundle installer, end to end: install a release,
# update it in place (tool ID kept), repair it, refuse a clashing new install,
# never downgrade the stable manager, keep the manager when every install is
# removed. Two real bundles from a synthetic stage; GitHub is a fake transport;
# ADB is a fake download; HOME is a throwaway directory.
set -Eeuo pipefail
not() { if "$@"; then echo "FAIL: unexpectedly succeeded: $*" >&2; exit 1; fi; }
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
work="$(mktemp -d)"
trap 'chmod -R u+rwX -- "$work" 2>/dev/null; rm -rf -- "$work"' EXIT
source "$repo/image-14/tests/lib/fake-google-adb.sh"

# A minimal complete stage (as in test-deploy-packaging.sh).
stage="$work/stage"; out="$work/bundles"
mkdir -p "$stage/compat_tool/liblepton" "$stage/compat_tool/sysbake/system" \
    "$stage/compat_tool/images/rootfs/system/etc/init/hw" "$stage/compat_tool/images/rootfs/vendor/lib64/hw" \
    "$stage/compat_tool/images/rootfs_overlay/system/bin" "$stage/tools/bin"
for file in lepton toolmanifest.vdf liblepton/liblepton.sh liblepton/app_metadata.sh liblepton/mounting.sh liblepton/baking.sh; do
    printf '#!/bin/sh\n' > "$stage/compat_tool/$file"
done
printf 'binderfs-ensure\n' > "$stage/compat_tool/images/rootfs/system/etc/init/hw/init.rc"
printf 'ro.build.version.sdk=34\nro.dalvik.vm.native.bridge=0\n' > "$stage/compat_tool/images/rootfs/system/build.prop"
printf 'test-radv\n' > "$stage/compat_tool/images/rootfs/vendor/lib64/hw/vulkan.radeon.so"
printf '#!/bin/sh\n' > "$stage/compat_tool/images/rootfs_overlay/system/bin/binderfs-ensure"
chmod +x "$stage/compat_tool/images/rootfs_overlay/system/bin/binderfs-ensure"
printf '<packages/>\n' > "$stage/compat_tool/sysbake/system/packages.xml"
printf '# file: sysbake/system/packages.xml\nuser.fake=0x31\n' > "$stage/compat_tool/sysbake.xattrs"
printf '#!/bin/sh\n' > "$stage/tools/bin/inotifywait"

mkdir -p "$work/bin"
fake_sha="$(fake_adb_zip "$work/fake-adb")"
install_fake_curl "$work/bin"
export FAKE_ADB_ZIP="$work/fake-adb/platform-tools.zip" FAKE_CURL_LOG="$work/curl.log"
for version in v0.1.0-alpha v0.2.0-alpha; do
    bash "$repo/image-14/scripts/internal/deploy-compat-x86_64.sh" --package-only --execute \
        --stage-dir "$stage" --bundle-dir "$out" --bundle-id "$version" > "$work/package-$version.log"
    name="lepton-x86_64-$version"
    # Pin the fake adb, then refresh the release checksum file accordingly.
    pin_installer "$out/$name.install.sh" "$work/pinned.sh" "$fake_sha"
    mv -- "$work/pinned.sh" "$out/$name.install.sh"
    (cd "$out" && sha256sum "$name.tar.gz" "$name.install.sh" > "$name.tar.gz.sha256")
done

home="$work/home"
mkdir -p "$home/Desktop" "$home/.local/share/Steam/userdata/1/config" \
    "$home/.local/share/Steam/steamapps/compatdata/2000000000/baked/data_overlay"
echo 'level 7' > "$home/.local/share/Steam/steamapps/compatdata/2000000000/baked/data_overlay/save"
env -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u DISPLAY -u WAYLAND_DISPLAY HOME="$home" PATH="$work/bin:$PATH" \
    LEPTON_SKIP_HOST_CHECK=1 python3 -B - "$repo" "$out" "$home" <<'PY'
import hashlib, importlib.machinery, importlib.util, json, os, subprocess, sys
from pathlib import Path
repo, out, home = (Path(p) for p in sys.argv[1:])
loader = importlib.machinery.SourceFileLoader("rm", str(repo / "compat_tool/tools/lepton-release-manager"))
M = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(M)
# These fake releases are unsigned; signatures are covered by test-release-manager.py.
# Ignore whatever release key the repository lists.
M.signing_keys = lambda: None
M.HOME, M.DOWNLOADS, M.DATA = home, home / "Downloads/lepton-deck-bundles", home / ".local/share"
share, steam = home / ".local/share", home / ".local/share/Steam"

class Transport:
    downloads = []
    def download(self, url, destination, progress=None):
        M.check_url(url)
        name = url.rsplit("/", 1)[-1]
        self.downloads.append(name)
        Path(destination).write_bytes((out / name).read_bytes())
        return (out / name).stat().st_size

class UI:
    graphical = False
    def __init__(self, answers=()):
        self.answers, self.questions, self.infos = list(answers), [], []
    def note(self, text): pass
    def info(self, text): self.infos.append(text)
    error = info
    def question(self, text, ok_label="Continue"):
        self.questions.append(text)
        return "Remove older" not in text    # confirm everything except cleanup
    def choose(self, text, rows): return self.answers.pop(0) if self.answers else None
    def text(self, title, body):
        if "[FAIL]" in body: print(body, file=sys.stderr)
    def progress(self, text):
        class P:
            def __enter__(s): return lambda d, t: None
            def __exit__(s, *e): return False
        return P()

def published(*tags):
    items = []
    for tag in tags:
        names = M.asset_names(tag)
        items.append(dict(tag_name=tag, draft=False, prerelease=True, published_at="2026-11-06T00:00:00Z",
                          html_url="", assets=[dict(name=names[k], size=(out / names[k]).stat().st_size,
                                                    state="uploaded",
                                                    browser_download_url="https://github.com/pjohno/lepton-x86_64/releases/download/%s/%s" % (tag, names[k]))
                                               for k in ("archive", "manifest", "installer")]))
    return M.parse_releases(items)[0]

# The installer must accept this non-AMD test machine; everything else is real.
real_run = M.run_installer
M.run_installer = lambda verified, args, ui: real_run(verified, list(args) + ["--allow-non-amd"], ui)
releases = published("v0.1.0-alpha", "v0.2.0-alpha")
old = next(r for r in releases if r.tag == "v0.1.0-alpha")
new = next(r for r in releases if r.tag == "v0.2.0-alpha")
T = Transport()

def check(condition, message):
    if not condition:
        sys.exit("FAIL: " + message)

# 1. Install v0.1.0-alpha as a new tool.
ui = UI()
check(M.install(old, None, ui, T, keys=None) is True, "first install failed")
tool_dir = share / "lepton_x86_64_v0_1_0_alpha"
check(json.loads((tool_dir / "BUNDLE.json").read_text())["bundle_id"] == "v0.1.0-alpha", "installed version")
check((steam / "compatibilitytools.d/lepton_x86_64_v0_1_0_alpha.vdf").is_file(), "Steam registration")
check(any("not signed" in q for q in ui.questions), "unsigned release was not confirmed explicitly")
check((tool_dir / "tools/platform-tools/adb").is_file(), "ADB not provided by the installer")
manager = share / "lepton-release-manager/lepton-release-manager"
check(manager.is_file() and (share / "lepton-release-manager/lepton-manage-installs").is_file(), "stable manager")
check((share / "lepton-release-manager/allowed_signers").is_file(), "release keys installed")
entry = (share / "applications/lepton-release-manager.desktop").read_text()
check("Name=Lepton: Install / Update / Repair" in entry and str(manager) in entry, "manager menu entry")
check((home / ".local/bin/lepton-release-manager").resolve() == manager.resolve(), "manager command link")
for name in ("lepton-x86_64-add-game", "lepton-x86_64-gpu-check", "lepton-x86_64-manage-installs",
             "lepton-release-manager"):
    check((home / "Desktop" / (name + ".desktop")).is_file(), "desktop icon " + name)
tools = {t["id"]: t for t in M.installed_tools()}
check(str(tools["lepton_x86_64_v0_1_0_alpha"]["version"]) == "v0.1.0-alpha", "installed version detected")

# 2. Update it in place: same tool ID, directory and Steam registration.
check(M.update_for(tools["lepton_x86_64_v0_1_0_alpha"], releases).tag == "v0.2.0-alpha", "update offered")
check(M.install(new, "lepton_x86_64_v0_1_0_alpha", UI(), T, keys=None) is True, "update failed")
meta = json.loads((tool_dir / "BUNDLE.json").read_text())
check(meta["bundle_id"] == "v0.2.0-alpha" and meta["tool_id"] == "lepton_x86_64_v0_1_0_alpha", "updated in place")
check(not (share / "lepton_x86_64_v0_2_0_alpha").exists(), "update created a second install")
vdf = (steam / "compatibilitytools.d/lepton_x86_64_v0_1_0_alpha.vdf").read_text()
check('"%s/compat_tool"' % tool_dir in vdf, "Steam registration still points at the same tool")
check(sorted(p.name for p in (steam / "compatibilitytools.d").glob("*.vdf")) ==
      ["lepton_x86_64_v0_1_0_alpha.vdf"], "extra Steam tools registered")

# 3. Repair: the same version over the same tool; cached files reused; game data untouched.
(tool_dir / "compat_tool/lepton").write_text("damaged")
tool = next(t for t in M.installed_tools() if t["id"] == "lepton_x86_64_v0_1_0_alpha")
release, reason = M.repair_target(tool, releases)
check(release is new and reason is None, "repair target")
T.downloads.clear()
check(M.flow_repair(UI(answers=["lepton_x86_64_v0_1_0_alpha"]), releases, T) is True, "repair failed")
check((tool_dir / "compat_tool/lepton").read_text() != "damaged", "repair did not restore files")
check(T.downloads == [new.names["manifest"]], "repair did not reuse the verified downloads: %s" % T.downloads)
save = steam / "steamapps/compatdata/2000000000/baked/data_overlay/save"
check(save.read_text() == "level 7\n", "compatdata changed")

# 4. A new install whose tool ID is taken (by the updated tool) is refused.
try:
    M.install(old, None, UI(), T, keys=None)
    sys.exit("FAIL: clashing new install accepted")
except M.ReleaseError as exc:
    check("already exists" in str(exc), str(exc))

# 5. An installer never replaces a newer stable manager with an older copy.
manager.write_text("#!/usr/bin/env python3\nprint(99)\n")
check(M.install(new, "lepton_x86_64_v0_1_0_alpha", UI(), T, keys=None) is True, "reinstall failed")
check(manager.read_text() == "#!/usr/bin/env python3\nprint(99)\n", "newer manager was downgraded")
manager.write_bytes((repo / "compat_tool/tools/lepton-release-manager").read_bytes())

# 6. Removing every install keeps Lepton: Install / Update / Repair.
subprocess.run([sys.executable, str(tool_dir / "compat_tool/tools/lepton-manage-installs"),
                "--remove", "lepton_x86_64_v0_1_0_alpha", "--execute"], check=True, stdout=subprocess.DEVNULL)
check(not tool_dir.exists(), "install not removed")
check(manager.is_file() and (share / "applications/lepton-release-manager.desktop").is_file(), "manager removed")
check((home / "Desktop/lepton-release-manager.desktop").is_file(), "manager icon removed")
check(not (home / "Desktop/lepton-x86_64-add-game.desktop").exists(), "per-install icons left behind")
check(save.read_text() == "level 7\n", "compatdata changed by removal")
out_ = subprocess.run([sys.executable, str(manager), "--version"], stdout=subprocess.PIPE, text=True, check=True)
check(out_.stdout.strip() == str(M.MANAGER_VERSION), "manager no longer runs")
PY
# Reinstalling never duplicates icons.
test "$(find "$home/Desktop" -name 'lepton-release-manager*' | wc -l)" = 1
echo 'PASS: release install: new install, in-place update (tool ID kept), repair from cached verified files, clashing install refused, manager never downgraded and kept after removing every install, no game data touched'
