# SPDX-License-Identifier: MIT
"""Host-side Android Library storage and package validation."""
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tempfile
import uuid
import zipfile

TOOLS = Path(__file__).resolve().parent
PACKAGE = re.compile(r"[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+")
DIGEST = re.compile(r"[a-f0-9]{64}")
SIGNER = re.compile(r"(?im)^Signer (?:#\d+|\(minSdkVersion=[^\r\n]+\)) certificate SHA-256 digest: ([a-f0-9]{64})[ \t]*$")
STORAGE = "Container Storage"
DEFAULTS = ("Documents", "Downloads", "Videos", "Music", "Pictures")


def settings_path():
    return Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "lepton-x86_64/android-library.json"


def read_json(path):
    regular(path)
    result = json.loads(path.read_text())
    if not isinstance(result, dict) or result.get("schema_version") != 1:
        raise ValueError(f"Unsupported metadata in {path}")
    return result


def sync_dir(path):
    fd = os.open(path, os.O_DIRECTORY | os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_json(path, value):
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".metadata-", delete=False) as out:
        temp = Path(out.name)
        try:
            out.write((json.dumps(value, indent=4, ensure_ascii=False) + "\n").encode())
            out.flush()
            os.fsync(out.fileno())
            os.replace(temp, path)
            sync_dir(path.parent)
        finally:
            temp.unlink(missing_ok=True)


def real_dir(path):
    if path.is_symlink() or not path.is_dir() or path != path.resolve():
        raise ValueError(f"Expected a real directory at {path}")


def regular(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"Expected a regular file at {path}")


def safe_path(path):
    if any(ord(char) < 32 or ord(char) == 127 or char in ',:"\\' for char in str(path)):
        raise ValueError(f"Unsupported character in path: {path}")


def overlap(first, second):
    return first == second or first in second.parents or second in first.parents


def validate_root(path):
    safe_path(path)
    protected = [
        settings_path().parent.resolve(),
        (Path.home() / ".local/share/Steam").resolve(),
        (Path.home() / ".steam/root").resolve(),
        (Path.home() / ".local/share/lepton").resolve(),
        (Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share") / "lepton-compat-data").resolve(),
        TOOLS.parent.parent,
    ]
    if any(overlap(path, other) for other in protected):
        raise ValueError(f"Library location overlaps protected data: {path}")


@contextlib.contextmanager
def lock(path, exclusive):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        try:
            fcntl.flock(fd, (fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH) | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ValueError("Android Library is busy. Close running managed applications and retry.") from exc
        yield
    finally:
        os.close(fd)


def library():
    conf = settings_path()
    if not conf.exists() and not conf.is_symlink():
        return None
    settings = read_json(conf)
    root = Path(settings["path"])
    validate_root(root)
    marker = root / ".lepton-library.json"
    try:
        real_dir(root)
        real_dir(root / STORAGE)
        if read_json(marker)["id"] != settings["id"]:
            raise ValueError("Library identity changed")
    except (ValueError, OSError) as exc:
        raise ValueError(f"Android Library unavailable at {root}. Reconnect its drive or restore the real directory. ({exc})") from exc
    return root


def initialize(path, dry_run=False):
    path = Path(os.path.abspath(path.expanduser()))
    validate_root(path)
    if path != path.resolve() or path.is_symlink():
        raise ValueError(f"Library location must use real directories: {path}")
    conf = settings_path()
    if dry_run:
        return path
    conf.parent.mkdir(parents=True, exist_ok=True)
    with lock(conf.parent, True):
        existing = library()
        if existing is not None:
            if existing != path:
                raise ValueError(f"Library already configured at {existing}")
            return existing
        # Require the parent to exist so a mistyped or disconnected mount
        # does not cause us to create a chain of directories.
        path.mkdir(mode=0o700, exist_ok=True)
        real_dir(path)
        with lock(path, True):
            marker = path / ".lepton-library.json"
            if marker.exists() or marker.is_symlink():
                state = read_json(marker)
                real_dir(path / STORAGE)
            else:
                (path / STORAGE).mkdir(mode=0o700, exist_ok=True)
                real_dir(path / STORAGE)
                state = {"schema_version": 1, "id": uuid.uuid4().hex}
                atomic_json(marker, state)
            atomic_json(conf, dict(state, path=str(path)))
    return path


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def copy_file(source, target):
    with source.open("rb") as src, target.open("xb") as out:
        shutil.copyfileobj(src, out)
        out.flush()
        os.fsync(out.fileno())


def command(args):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise ValueError(f"{Path(args[0]).name} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def sdk_tool(name):
    # SDK Build Tools can live in a user directory on immutable SteamOS.
    directory = os.getenv("LEPTON_ANDROID_BUILD_TOOLS")
    result = str(Path(directory).expanduser() / name) if directory else shutil.which(name)
    if not result or not os.access(result, os.X_OK):
        raise ValueError(f"Install Android SDK Build Tools and set LEPTON_ANDROID_BUILD_TOOLS (missing {name})")
    return result


def archive_entries(archive):
    entries = archive.infolist()
    names = {entry.filename for entry in entries}
    if len(entries) != len(names):
        raise ValueError("Archive contains duplicate entries")
    for entry in entries:
        name = entry.filename.rstrip("/")
        if (not name or PurePosixPath(name).is_absolute() or
                any(part in {"", ".", ".."} for part in name.split("/")) or
                "\\" in name or any(ord(char) < 32 for char in name) or
                stat.S_ISLNK(entry.external_attr >> 16) or entry.flag_bits & 1):
            raise ValueError(f"Unsafe archive entry: {entry.filename!r}")
    return names


def apk_metadata(path):
    with zipfile.ZipFile(path) as archive:
        names = archive_entries(archive)
        if "AndroidManifest.xml" not in names:
            raise ValueError("APK has no AndroidManifest.xml")
        abis = sorted({name.split("/")[1] for name in names if re.fullmatch(r"lib/[^/]+/[^/]+\.so", name)})
    badging = command([sdk_tool("aapt2"), "dump", "badging", str(path)])
    package_line = next((line for line in badging.splitlines() if line.startswith("package: ")), "")
    fields = dict(re.findall(r"([A-Za-z]+)='([^']*)'", package_line))
    package = fields.get("name", "")
    code = fields.get("versionCode", "")
    manifest = command([sdk_tool("aapt2"), "dump", "xmltree", str(path), "--file", "AndroidManifest.xml"])
    major_field = re.search(r"(?m)^\s*A: android:versionCodeMajor(?:\(0x[0-9a-f]+\))?=(?:\(type 0x[0-9a-f]+\))?(0x[0-9a-f]+|[0-9]+)\s*$", manifest)
    if "android:versionCodeMajor" in manifest and major_field is None:
        raise ValueError(f"Cannot read versionCodeMajor in {path.name}")
    major = int(major_field[1], 0) if major_field else 0
    if not PACKAGE.fullmatch(package) or not re.fullmatch(r"[0-9]+", code):
        raise ValueError(f"Invalid package or version in {path.name}")
    if int(code) > 0xffffffff or major > 0x7fffffff:
        raise ValueError("Android version code is outside its supported range")
    result = command([sdk_tool("apksigner"), "verify", "--print-certs", str(path)])
    signers = sorted(set(SIGNER.findall(result.lower())))
    if not signers:
        raise ValueError(f"No verified Android signing certificates in {path.name}")
    label = re.search(r"(?m)^application-label:'(.*)'$", badging)
    if label is None:
        label = re.search(r"(?m)^application: label='(.*)' icon=", badging)
    return dict(package=package, name=(label[1] if label and label[1] else package), version_name=fields.get("versionName", ""),
                version_code=(major << 32) | int(code), signers=signers, abis=abis,
                split=fields.get("split", ""), sha256=sha256(path))


def inspect(path, suffix):
    if suffix == ".apk":
        entries = {"base.apk": apk_metadata(path)}
    else:
        with zipfile.ZipFile(path) as archive, tempfile.TemporaryDirectory() as tmp:
            apks = sorted(name for name in archive_entries(archive) if name.lower().endswith(".apk"))
            if "base.apk" not in apks or any(not re.fullmatch(r"[A-Za-z0-9_.-]+\.apk", name) for name in apks):
                raise ValueError("APKM requires base.apk and flat split APK filenames")
            entries = {}
            for name in apks:
                dest = Path(tmp) / name
                with archive.open(name) as src, dest.open("xb") as out:
                    shutil.copyfileobj(src, out)
                entries[name] = apk_metadata(dest)
                dest.unlink()
    base = entries["base.apk"]
    if base["split"]:
        raise ValueError("Expected a base APK")
    split_ids = set()
    for name, entry in entries.items():
        if any(entry[key] != base[key] for key in ("package", "version_code", "signers")):
            raise ValueError(f"Package, version or verified signers differ in {name}")
        if name != "base.apk":
            if not entry["split"] or entry["split"] in split_ids:
                raise ValueError(f"Missing or duplicate split ID in {name}")
            split_ids.add(entry["split"])
    info = {key: base[key] for key in ("package", "name", "version_name", "version_code", "signers")}
    info.update(format=suffix, sha256=sha256(path), abis=sorted({abi for entry in entries.values() for abi in entry["abis"]}),
                apks={name: entry["sha256"] for name, entry in entries.items()})
    return info



def validate_rotation(path, old, new):
    # apksigner verify has already authenticated every member. Check that each
    # embeds the successor proof and retains access to its predecessors' data.
    def accepts(apk):
        try:
            proof = command([sdk_tool("apksigner"), "lineage", "--print-certs", "--in", str(apk)])
        except ValueError:
            return False
        certificates = re.split(r"(?m)^Signer #\d+ in lineage certificate SHA-256 digest: ([a-f0-9]{64})[ \t]*$", proof)
        if len(certificates) < 5:
            return False
        lineage = dict(zip(certificates[1::2], certificates[2::2]))
        successor = next(reversed(lineage))
        return (successor in new["signers"] and set(new["signers"]).issubset(lineage) and
                all(digest in lineage and "Has installed data capability: true" in lineage[digest].splitlines()
                    for digest in old["signers"]))

    if new["format"] == ".apk":
        return accepts(path)
    with zipfile.ZipFile(path) as archive, tempfile.TemporaryDirectory() as folder:
        for name in new["apks"]:
            apk = Path(folder) / name
            with archive.open(name) as source, apk.open("xb") as output:
                shutil.copyfileobj(source, output)
            if not accepts(apk):
                return False
            apk.unlink()
    return True

def load_app(root, package, verify=False):
    if not PACKAGE.fullmatch(package):
        raise ValueError(f"Invalid Android package: {package}")
    directory = root / package
    real_dir(directory)
    if (directory / ".update").exists() or (directory / ".update").is_symlink():
        raise ValueError(f"Interrupted library update for {package}. Run lepton-library recover {package}.")
    config = read_json(directory / "config.json")
    if (config.get("package") != package or config.get("format") not in {".apk", ".apkm"} or
            not isinstance(config.get("name"), str) or not isinstance(config.get("version_name"), str) or
            type(config.get("version_code")) is not int or not 0 <= config["version_code"] < (1 << 63) or
            not isinstance(config.get("sha256"), str) or not DIGEST.fullmatch(config["sha256"]) or
            not isinstance(config.get("revision"), str) or not config["revision"] or
            not isinstance(config.get("signers"), list) or not config["signers"] or
            any(not isinstance(digest, str) or not DIGEST.fullmatch(digest) for digest in config["signers"]) or
            not isinstance(config.get("apks"), dict) or "base.apk" not in config["apks"]):
        raise ValueError(f"Invalid application metadata for {package}")
    apk = directory / (package + config["format"])
    regular(apk)
    if verify and sha256(apk) != config["sha256"]:
        raise ValueError(f"APK contents differ from library metadata: {apk}")
    return directory, config, apk


def default_share(item):
    if not isinstance(item, str):
        return False
    name, separator, mode = item.partition(":")
    return name in DEFAULTS and (not separator or mode in {"ro", "rw"})


def sharing(config):
    settings = config.get("shared_folders", {})
    if not isinstance(settings, dict):
        raise ValueError("Invalid shared-folder configuration")
    defaults = settings.get("defaults")
    custom = settings.get("custom", [])
    if defaults is not None and (not isinstance(defaults, list) or
            any(not default_share(item) for item in defaults)):
        raise ValueError("Invalid shared-folder defaults")
    if not isinstance(custom, list):
        raise ValueError("Invalid custom shared folders")
    items = [] if defaults is None else defaults or ["none"]
    for item in custom:
        if not isinstance(item, dict):
            raise ValueError("Invalid custom shared folder")
        name, path, ro = item.get("name"), item.get("path"), item.get("read_only")
        if (not isinstance(name, str) or not name or any(char in name for char in "=,/:") or
                not isinstance(path, str) or not path.startswith("/") or "," in path or
                type(ro) is not bool or any(ord(char) < 32 or ord(char) == 127 for char in name + path)):
            raise ValueError("Invalid custom shared folder")
        items = [*items, f"{name}={path}:{'ro' if ro else 'rw'}"]
    return ",".join(items) if items else None


def steam_shortcuts(apk, *, removing=False):
    from importlib.machinery import SourceFileLoader
    from importlib.util import module_from_spec, spec_from_loader

    loader = SourceFileLoader("lepton_shortcuts", str(TOOLS / "lepton-add-game"))
    module = module_from_spec(spec_from_loader(loader.name, loader))
    loader.exec_module(module)
    steam = module.manage_module().steam_root(required=False)
    if steam is None:
        return
    if removing and module.steam_running():
        raise ValueError("Exit Steam before removing library apps. Steam may have unsaved shortcuts.")
    for user, _ in module.steam_users(steam):
        shortcuts = user / "config/shortcuts.vdf"
        if not shortcuts.exists():
            continue
        entries, _, _ = module.read_binary(shortcuts.read_bytes())
        for entry in entries.values():
            if not isinstance(entry, dict):
                continue
            exe = entry.get("Exe", "").strip('"')
            if exe and Path(exe).resolve() == apk:
                yield {"user": user.name, "appid": entry.get("appid"), "name": entry.get("AppName")}


def obb_files(paths, package):
    name = re.compile(rf"(?:main|patch)\.[0-9]+\.{re.escape(package)}\.obb")
    result = {}
    for path in paths:
        path = path.expanduser().absolute()
        regular(path)
        if not name.fullmatch(path.name) or path.name in result:
            raise ValueError(f"Invalid or duplicate OBB filename for {package}: {path.name}")
        result[path.name] = path
    return result


def commit_update(directory):
    pending = directory / ".update"
    real_dir(pending)
    config = read_json(pending / "config.json")
    package = directory.name
    if config.get("package") != package or config.get("format") not in {".apk", ".apkm"}:
        raise ValueError("Invalid pending update metadata")
    apk = directory / (package + config["format"])
    regular(apk)
    staged = pending / apk.name
    if staged.exists() or staged.is_symlink():
        regular(staged)
        if sha256(staged) != config["sha256"]:
            raise ValueError("Staged APK contents changed")
    elif sha256(apk) != config["sha256"]:
        raise ValueError("Missing staged APK and active APK does not match the pending update")
    obb = directory / "obb"
    real_dir(obb)
    for name, digest in config.get("pending_obb", {}).items():
        if not re.fullmatch(rf"(?:main|patch)\.[0-9]+\.{re.escape(package)}\.obb", name):
            raise ValueError("Unsafe pending OBB name")
        src, dst = pending / name, obb / name
        if dst.exists() or dst.is_symlink():
            regular(dst)
            if sha256(dst) != digest:
                raise ValueError(f"Existing OBB differs: {dst}")
        else:
            regular(src)
            if sha256(src) != digest:
                raise ValueError(f"Staged OBB contents changed: {src}")
            os.replace(src, dst)
            sync_dir(obb)
    if staged.exists():
        old = read_json(directory / "config.json")
        if old["package"] != package or old["format"] != config["format"] or sha256(apk) != old["sha256"]:
            raise ValueError("Active APK no longer matches the previous library metadata")
        backup = directory / ".previous"
        backup.mkdir(mode=0o700, exist_ok=True)
        real_dir(backup)
        backup_stage = pending / "previous"
        backup_stage.unlink(missing_ok=True)
        copy_file(apk, backup_stage)
        os.replace(backup_stage, backup / apk.name)
        atomic_json(backup / "config.json", old)
        os.replace(staged, apk)
        sync_dir(directory)
        sync_dir(pending)
    config.pop("pending_obb", None)
    atomic_json(directory / "config.json", config)
    # Rename the journal out of the critical path before deleting its contents.
    with tempfile.TemporaryDirectory(prefix=".finished-", dir=directory) as trash:
        os.rename(pending, Path(trash) / "journal")
        sync_dir(directory)


def import_app(root, source, *, mode, replace=False, obbs=(), dry_run=False, verbose=True):
    source = source.expanduser().absolute()
    regular(source)
    suffix = source.suffix.lower()
    if suffix not in {".apk", ".apkm"}:
        raise ValueError("Expected an APK or APKM file")
    with lock(root, not dry_run), tempfile.TemporaryDirectory(
            prefix=".import-", dir=None if dry_run else root) as scratch:
        stage = Path(scratch)
        candidate = stage / ("candidate" + suffix)
        copy_file(source, candidate)
        incoming = inspect(candidate, suffix)
        package = incoming["package"]
        files = obb_files(obbs, package)
        directory = root / package
        apk = directory / (package + suffix)
        staged = stage / apk.name
        candidate.rename(staged)
        old = None
        if directory.exists() or directory.is_symlink():
            _, old, active = load_app(root, package, verify=True)
            if verbose:
                print(f"{package}: library {old['version_name']} ({old['version_code']}), "
                      f"incoming {incoming['version_name']} ({incoming['version_code']})")
            if old["signers"] != incoming["signers"] and not validate_rotation(staged, old, incoming):
                raise ValueError("Incompatible signing certificates or missing Android signing lineage")
            if incoming["version_code"] < old["version_code"]:
                raise ValueError("Android version downgrade refused")
            if active != apk:
                raise ValueError("Changing between APK and APKM is unsupported because it changes the Steam target")
            same_version = incoming["version_code"] == old["version_code"]
            same_file = incoming["sha256"] == old["sha256"]
            if same_version and not replace:
                if same_file and mode == "import" and not files:
                    return directory, old, apk
                raise ValueError("Identical APK" + ("; use reinstall" if same_file else
                                 " version with different contents; use update --replace-same-version"))
            if mode == "import":
                raise ValueError("Package already imported. To replace it, run lepton-library update FILE.")
        elif mode == "update":
            raise ValueError(f"{package} is not imported; run lepton-library import FILE")
        config = dict(old or {"schema_version": 1, "shared_folders": {"custom": []}},
                      **incoming, revision=uuid.uuid4().hex)
        config["pending_obb"] = {}
        obb_dir = directory / "obb" if old else stage / "obb"
        if not old:
            obb_dir.mkdir()
        else:
            real_dir(obb_dir)
        for name, src in files.items():
            dst = obb_dir / name
            if dst.exists() or dst.is_symlink():
                regular(dst)
                if sha256(src) != sha256(dst):
                    raise ValueError(f"Refusing to replace existing OBB {dst}")
                continue
            if not dry_run:
                target = (stage if old else obb_dir) / name
                copy_file(src, target)
                config["pending_obb"][name] = sha256(target)
        if dry_run:
            return directory, config, apk
        if old:
            atomic_json(stage / "config.json", config)
            os.rename(stage, directory / ".update")
            sync_dir(root)
            sync_dir(directory)
            commit_update(directory)
        else:
            config.pop("pending_obb")
            sync_dir(obb_dir)
            atomic_json(stage / "config.json", config)
            os.rename(stage, directory)
            sync_dir(root)
        return directory, config, apk



def restore_previous(directory, config, apk, dry_run):
    backup = directory / ".previous"
    real_dir(backup)
    previous = read_json(backup / "config.json")
    source = backup / apk.name
    regular(source)
    if (sha256(source) != previous["sha256"] or previous["package"] != config["package"] or
            previous["format"] != config["format"]):
        raise ValueError("Previous APK or metadata is invalid")
    if not dry_run:
        restored = dict(config, **{key: previous[key] for key in (
            "name", "version_name", "version_code", "signers", "abis", "apks", "sha256")})
        restored["revision"] = previous["revision"]
        with tempfile.TemporaryDirectory(prefix=".restore-", dir=directory) as scratch:
            stage = Path(scratch)
            copy_file(source, stage / apk.name)
            atomic_json(stage / "config.json", restored)
            os.rename(stage, directory / ".update")
            sync_dir(directory)
            commit_update(directory)
    return previous["version_code"]


def runtime_app(root, target):
    raw = Path(os.path.abspath(target))
    path = raw.resolve()
    if raw.parent.parent == root and raw != path:
        raise ValueError(f"Managed APK path must contain real files and directories: {raw}")
    if path.parent.parent != root or path.suffix not in {".apk", ".apkm"}:
        return None
    directory, config, apk = load_app(root, path.parent.name, verify=True)
    if apk != path:
        raise ValueError(f"Expected the managed APK at {apk}")
    value = None if "LEPTON_SHARED_FOLDERS" in os.environ else sharing(config)
    obb = directory / "obb"
    real_dir(obb)
    # A read-only bind of OBB assets is separate from optional shared folders.
    for entry in obb.iterdir():
        regular(entry)
        obb_files([entry], config["package"])
    return value, str(directory), str(obb) if any(obb.iterdir()) else ""


def profile_key(baked):
    return hashlib.sha256(os.fsencode(baked)).hexdigest()


def profile_receipts(directory):
    index = directory / ".profiles"
    if not index.exists():
        return []
    real_dir(index)
    return [read_json(path) for path in sorted(index.glob("*.json"))]


def require_unmounted(directory):
    # A directory can contain bind mounts on the same filesystem. Check the
    # mount table before recursing, including paths with escaped spaces.
    with open("/proc/self/mountinfo") as mounts:
        for line in mounts:
            target = re.sub(r"\\([0-7]{3})", lambda match: chr(int(match[1], 8)), line.split()[4])
            path = Path(target)
            if path == directory or directory in path.parents:
                raise ValueError(f"Cannot remove an app containing a mount: {path}")


def selected_apkm_names(names):
    abi_names = {f"split_config.{abi}.apk": abi for abi in ("arm64_v8a", "armeabi_v7a", "x86", "x86_64")}
    present = {abi_names[name] for name in names if name in abi_names}
    chosen = next((abi for abi in ("x86_64", "arm64_v8a") if abi in present), None)
    return {name for name in names if name not in abi_names or abi_names[name] == chosen}, chosen
