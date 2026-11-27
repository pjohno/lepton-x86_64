# SPDX-License-Identifier: MIT
"""Host-side Android Library storage, package metadata and update staging.

Library layout (docs/android-library.md describes the design):

  ROOT/.lepton-library.json       identity marker, matched against the settings
  ROOT/Container Storage/         common folder shared with every profile
  ROOT/PACKAGE/
      PACKAGE.apk | PACKAGE.apkm  active APK: the stable Steam shortcut target
      config.json                 active metadata and per-app settings
      obb/                        versioned OBB files, mounted read-only
      .candidate/                 staged update Android has not yet accepted
      .previous/                  APK replaced by the most recent promotion
      .update/                    journal of an unfinished file replacement
      .profiles/                  one receipt per Android profile

Android's package manager is authoritative for signatures, signing-key
rotation, replacement and downgrades. A staged update becomes the active APK
only after Android has installed it in a profile, so the active APK is always
a version Android accepted (or the original import).
"""
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
import time
import uuid
import zipfile

TOOLS = Path(__file__).resolve().parent
PACKAGE = re.compile(r"[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+")
DIGEST = re.compile(r"[a-f0-9]{64}")
SIGNER = re.compile(r"(?im)^Signer (?:#\d+|\(minSdkVersion=[^\r\n]+\)) certificate SHA-256 digest: ([a-f0-9]{64})[ \t]*$")
STORAGE = "Container Storage"
MARKER = ".lepton-library.json"
CANDIDATE = ".candidate"
JOURNAL = ".update"
PREVIOUS = ".previous"
FORMATS = (".apk", ".apkm")
DEFAULTS = ("Documents", "Downloads", "Videos", "Music", "Pictures")
LONG_MIN, LONG_MAX = -(1 << 63), (1 << 63) - 1
# Package metadata replaced by an update. Everything else in config.json (the
# per-app shared-folder settings) belongs to the user and is kept.
METADATA = ("name", "version_name", "version_code", "min_sdk", "signers", "abis", "apks",
            "splits", "sha256", "launchable_activity", "extract_native_libs", "revision")
OBB_NAME = r"(?:main|patch)\.[0-9]+\.{}\.obb"


class Unavailable(ValueError):
    """The configured library cannot be reached or is not the same library."""


class Interrupted(ValueError):
    """A library file replacement was interrupted and must be finished first."""


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


def exists(path):
    return path.exists() or path.is_symlink()


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
def lock(path, exclusive, wait=0):
    """flock on a directory. WAIT seconds to obtain it; 0 fails at once."""
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        deadline = time.monotonic() + wait
        while True:
            try:
                fcntl.flock(fd, (fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH) | fcntl.LOCK_NB)
                break
            except BlockingIOError as exc:
                if time.monotonic() >= deadline:
                    raise ValueError("Android Library is busy. Close running managed applications and retry.") from exc
                time.sleep(0.2)
        yield
    finally:
        os.close(fd)


# Library location -----------------------------------------------------------

def configured():
    """(root, settings) from the user's configuration, without checking that
    the library is reachable. None when no library is configured."""
    conf = settings_path()
    if not exists(conf):
        return None
    settings = read_json(conf)
    if not isinstance(settings.get("path"), str) or not isinstance(settings.get("id"), str):
        raise ValueError(f"Invalid Android Library configuration in {conf}")
    root = Path(settings["path"])
    validate_root(root)
    return root, settings


def check_available(root, settings):
    """Raise Unavailable unless ROOT is the configured library, on a connected
    drive. Never creates anything."""
    try:
        real_dir(root)
        real_dir(root / STORAGE)
        if read_json(root / MARKER)["id"] != settings["id"]:
            raise ValueError("library identity changed")
    except (ValueError, OSError) as exc:
        raise Unavailable(f"Android Library unavailable at {root}. Reconnect its drive or restore the "
                          f"directory, or run lepton-library forget to stop using it. ({exc})") from exc


def library():
    """The configured, available library root; None if none is configured."""
    found = configured()
    if found is None:
        return None
    check_available(*found)
    return found[0]


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
        found = configured()
        if found is not None:
            if found[0] != path:
                raise ValueError(f"Library already configured at {found[0]}. Run lepton-library forget first "
                                 "to use another location; no files are deleted.")
            check_available(*found)
            return path
        # Only the library directory itself is created, so a mistyped path or
        # a disconnected drive does not produce a chain of directories.
        if not path.parent.is_dir():
            raise ValueError(f"Parent directory does not exist: {path.parent}. Connect the drive or create it first.")
        path.mkdir(mode=0o700, exist_ok=True)
        real_dir(path)
        with lock(path, True):
            marker = path / MARKER
            if exists(marker):
                state = read_json(marker)
                real_dir(path / STORAGE)
            else:
                (path / STORAGE).mkdir(mode=0o700, exist_ok=True)
                real_dir(path / STORAGE)
                state = {"schema_version": 1, "id": uuid.uuid4().hex}
                atomic_json(marker, state)
            atomic_json(conf, dict(state, path=str(path)))
    return path


def forget():
    """Remove the library association. Library files and profiles are kept."""
    conf = settings_path()
    found = configured()
    if found is None:
        return None
    with lock(conf.parent, True):
        conf.unlink()
        sync_dir(conf.parent)
    return found[0]


# Files ----------------------------------------------------------------------

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


def obb_files(paths, package):
    name = re.compile(OBB_NAME.format(re.escape(package)))
    result = {}
    for path in paths:
        path = path.expanduser().absolute()
        regular(path)
        if not name.fullmatch(path.name) or path.name in result:
            raise ValueError(f"Invalid or duplicate OBB filename for {package}: {path.name}")
        result[path.name] = path
    return result


# Package metadata -----------------------------------------------------------

def extractor():
    path = os.environ.get("LEPTON_APK_EXTRACTOR") or str(TOOLS.parent / "liblepton/apk_extractor/bin/apk-info-extractor")
    if not os.access(path, os.X_OK):
        raise ValueError(f"The bundled APK metadata reader is missing ({path}). Reinstall the Lepton bundle.")
    return path


def manifest(path):
    """The bundled extractor's JSON description of one APK."""
    try:
        data = json.loads(command([extractor(), "--json", str(path)]))
    except ValueError as exc:
        raise ValueError(f"Cannot read Android package metadata from {path.name}: {exc}") from exc
    if not isinstance(data, dict):
        raise ValueError(f"Unexpected metadata for {path.name}; reinstall the Lepton bundle")
    return data


def apksigner():
    """Optional host signature check: LEPTON_APKSIGNER (a path, or none), then
    LEPTON_ANDROID_BUILD_TOOLS/apksigner, then apksigner on PATH."""
    choice = os.environ.get("LEPTON_APKSIGNER", "")
    if choice == "none":
        return None
    if choice:
        candidate = str(Path(choice).expanduser())
    elif os.environ.get("LEPTON_ANDROID_BUILD_TOOLS"):
        candidate = str(Path(os.environ["LEPTON_ANDROID_BUILD_TOOLS"]).expanduser() / "apksigner")
    else:
        return shutil.which("apksigner")
    if not os.access(candidate, os.X_OK):
        raise ValueError(f"apksigner is not executable at {candidate}. Unset LEPTON_APKSIGNER and "
                         "LEPTON_ANDROID_BUILD_TOOLS to leave signature checks to Android.")
    return candidate


def host_signers(path):
    """Verified signing-certificate digests, or None when apksigner is not
    available. Android verifies the signature again on installation."""
    tool = apksigner()
    if tool is None:
        return None
    try:
        output = command([tool, "verify", "--print-certs", str(path)])
    except ValueError as exc:
        raise ValueError(f"apksigner did not verify {path.name}: {exc}. Set LEPTON_APKSIGNER=none to leave "
                         "signature checks to Android.") from exc
    signers = sorted(set(SIGNER.findall(output.lower())))
    if not signers:
        # A changed output format must not pass silently as "unsigned".
        raise ValueError(f"apksigner verified {path.name}, but its output did not list signer digests in "
                         "a known format. Set LEPTON_APKSIGNER=none to leave signature checks to Android.")
    return signers


def android_sdk():
    """API level of the bundled Android image (Android 14 for image-14)."""
    try:
        text = (TOOLS.parent / "images/rootfs/system/build.prop").read_text(errors="replace")
        return int(re.search(r"(?m)^ro\.build\.version\.sdk=([0-9]+)$", text)[1])
    except (OSError, TypeError):
        return 34


def apk_metadata(path):
    with zipfile.ZipFile(path) as archive:
        names = archive_entries(archive)
        if "AndroidManifest.xml" not in names:
            raise ValueError(f"{path.name} has no AndroidManifest.xml")
        damaged = archive.testzip()
        if damaged is not None:
            raise ValueError(f"{path.name} is damaged (bad data in {damaged})")
    data = manifest(path)
    package = data.get("package")
    if not isinstance(package, str) or not PACKAGE.fullmatch(package):
        raise ValueError(f"Invalid Android package name in {path.name}: {package!r}")
    code = data.get("long_version_code")
    if type(code) is not int or not LONG_MIN <= code <= LONG_MAX:
        raise ValueError(f"Cannot read the Android version code of {path.name}")
    if data.get("min_sdk_codename"):
        raise ValueError(f"{path.name} targets the preview Android release {data['min_sdk_codename']}")
    return {
        "package": package,
        "name": data.get("label") or package,
        "version_name": data.get("version_name") or "",
        "version_code": code,
        "min_sdk": data.get("min_sdk"),
        "split": data.get("split") or "",
        "abis": data.get("abis") or [],
        "launchable_activity": data.get("launchable_activity"),
        "extract_native_libs": data.get("extract_native_libs"),
        "signers": host_signers(path),
        "sha256": sha256(path),
    }


def inspect(path, suffix):
    """Metadata for an APK or APKM file, checked for internal consistency."""
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
        raise ValueError("Expected a base APK, not a split")
    split_ids = set()
    for name, entry in entries.items():
        if entry["package"] != base["package"] or entry["version_code"] != base["version_code"]:
            raise ValueError(f"Package or version differs in {name}")
        if entry["signers"] != base["signers"]:
            raise ValueError(f"Verified signers differ in {name}")
        if name != "base.apk":
            if not entry["split"] or entry["split"] in split_ids:
                raise ValueError(f"Missing or duplicate split ID in {name}")
            split_ids.add(entry["split"])
    if base["min_sdk"] is not None and base["min_sdk"] > android_sdk():
        raise ValueError(f"{base['package']} needs Android API {base['min_sdk']}; this Lepton image "
                         f"provides API {android_sdk()}")
    info = {key: base[key] for key in ("package", "name", "version_name", "version_code", "min_sdk",
                                       "signers", "launchable_activity", "extract_native_libs")}
    info.update(format=suffix, sha256=sha256(path),
                abis=sorted({abi for entry in entries.values() for abi in entry["abis"]}),
                apks={name: entry["sha256"] for name, entry in entries.items()},
                splits={name: entry["split"] for name, entry in entries.items() if name != "base.apk"})
    return info


def check_metadata(config, package, what):
    """Raise unless CONFIG holds usable metadata for PACKAGE."""
    def digest(value):
        return isinstance(value, str) and DIGEST.fullmatch(value)

    signers = config.get("signers")
    apks = config.get("apks")
    checks = {
        "package": config.get("package") == package,
        "format": config.get("format") in FORMATS,
        "name": isinstance(config.get("name"), str),
        "version_name": isinstance(config.get("version_name"), str),
        "version_code": type(config.get("version_code")) is int and LONG_MIN <= config["version_code"] <= LONG_MAX,
        "sha256": digest(config.get("sha256")),
        "revision": isinstance(config.get("revision"), str) and bool(config["revision"]),
        # None: no host signature check was available.
        "signers": signers is None or (isinstance(signers, list) and bool(signers) and all(map(digest, signers))),
        "apks": isinstance(apks, dict) and "base.apk" in apks and all(map(digest, apks.values())),
    }
    failed = [name for name, ok in checks.items() if not ok]
    if failed:
        raise ValueError(f"Invalid {what} for {package} ({', '.join(failed)})")
    return config


def load_app(root, package, verify=False):
    if not PACKAGE.fullmatch(package):
        raise ValueError(f"Invalid Android package: {package}")
    directory = root / package
    real_dir(directory)
    if exists(directory / JOURNAL):
        raise Interrupted(f"Interrupted library update for {package}. Run lepton-library recover {package}.")
    config = check_metadata(read_json(directory / "config.json"), package, "application metadata")
    apk = directory / (package + config["format"])
    regular(apk)
    if verify and sha256(apk) != config["sha256"]:
        raise ValueError(f"APK contents differ from library metadata: {apk}")
    return directory, config, apk


def load_candidate(directory, config, verify=False):
    """The staged update, or None: {"config", "apk", "rejected"}."""
    stage = directory / CANDIDATE
    if not exists(stage):
        return None
    real_dir(stage)
    candidate = check_metadata(read_json(stage / "config.json"), directory.name, "staged update")
    if candidate["format"] != config["format"]:
        raise ValueError("Staged update changes between APK and APKM")
    apk = stage / (directory.name + config["format"])
    regular(apk)
    if verify and sha256(apk) != candidate["sha256"]:
        raise ValueError(f"Staged APK contents differ from its metadata: {apk}")
    rejected = read_json(stage / "rejected.json") if exists(stage / "rejected.json") else None
    return {"config": candidate, "apk": apk, "rejected": rejected}


def default_share(item):
    if not isinstance(item, str):
        return False
    name, separator, mode = item.partition(":")
    return name in DEFAULTS and (not separator or mode in {"ro", "rw"})


def custom_share(item):
    if not isinstance(item, dict):
        return False
    name, path, ro = item.get("name"), item.get("path"), item.get("read_only")
    return (isinstance(name, str) and bool(name) and not any(char in name for char in "=,/:") and
            isinstance(path, str) and path.startswith("/") and "," not in path and type(ro) is bool and
            not any(ord(char) < 32 or ord(char) == 127 for char in name + path))


def sharing(config):
    """The LEPTON_SHARED_FOLDERS value for the app's saved settings, or None
    when the app keeps Lepton's defaults."""
    settings = config.get("shared_folders", {})
    if not isinstance(settings, dict):
        raise ValueError("Invalid shared-folder configuration")
    defaults = settings.get("defaults")
    custom = settings.get("custom", [])
    if defaults is not None and (not isinstance(defaults, list) or not all(map(default_share, defaults))):
        raise ValueError("Invalid shared-folder defaults")
    if not isinstance(custom, list) or not all(map(custom_share, custom)):
        raise ValueError("Invalid custom shared folder")
    items = [] if defaults is None else defaults or ["none"]
    items += [f"{item['name']}={item['path']}:{'ro' if item['read_only'] else 'rw'}" for item in custom]
    return ",".join(items) if items else None


def steam_shortcuts(apk, *, removing=False):
    from lepton_steam import shortcuts_for, steam_running

    if removing and steam_running():
        raise ValueError("Exit Steam before removing library apps. Steam may have unsaved shortcuts.")
    yield from shortcuts_for(apk)


# Library transactions -------------------------------------------------------

def discard_dir(directory, name):
    """Move NAME out of the way atomically, then delete it."""
    path = directory / name
    if not exists(path):
        return
    trash = directory / f".discarded-{uuid.uuid4().hex}"
    os.rename(path, trash)
    sync_dir(directory)
    shutil.rmtree(trash)


def commit_update(directory):
    """Finish the replacement journalled in .update. Idempotent: rerun after an
    interruption at any point. The journal's config.json holds the incoming
    metadata. The app's settings come from the active config.json."""
    pending = directory / JOURNAL
    real_dir(pending)
    package = directory.name
    incoming = check_metadata(read_json(pending / "config.json"), package, "pending update")
    old = read_json(directory / "config.json")
    if old.get("package") != package or old.get("format") != incoming["format"]:
        raise ValueError("Pending update does not match the active library metadata")
    apk = directory / (package + incoming["format"])
    regular(apk)
    staged = pending / apk.name
    if exists(staged):
        regular(staged)
        if sha256(staged) != incoming["sha256"]:
            raise ValueError("Staged APK contents changed")
    elif sha256(apk) != incoming["sha256"]:
        raise ValueError("Missing staged APK and active APK does not match the pending update")
    obb = directory / "obb"
    real_dir(obb)
    for name, digest in incoming.get("pending_obb", {}).items():
        if not re.fullmatch(OBB_NAME.format(re.escape(package)), name):
            raise ValueError("Unsafe pending OBB name")
        src, dst = pending / name, obb / name
        if exists(dst):
            regular(dst)
            if sha256(dst) != digest:
                raise ValueError(f"Existing OBB differs: {dst}")
        else:
            regular(src)
            if sha256(src) != digest:
                raise ValueError(f"Staged OBB contents changed: {src}")
            os.replace(src, dst)
            sync_dir(obb)
    if exists(staged):
        if sha256(apk) != old["sha256"]:
            raise ValueError("Active APK no longer matches the previous library metadata")
        backup = directory / PREVIOUS
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
    atomic_json(directory / "config.json", {**old, **{key: incoming.get(key) for key in METADATA}})
    # Rename the journal out of the critical path before deleting its contents.
    discard_dir(directory, JOURNAL)


def journal(directory, name):
    """Turn the staging directory NAME into the .update journal, then commit."""
    os.rename(directory / name, directory / JOURNAL)
    sync_dir(directory)
    commit_update(directory)


def promote_candidate(directory):
    """Make the staged update the active APK once Android has accepted it.
    The replaced APK is kept in .previous."""
    stage = directory / CANDIDATE
    (stage / "rejected.json").unlink(missing_ok=True)
    journal(directory, CANDIDATE)


def reject_candidate(directory, revision, error):
    stage = directory / CANDIDATE
    candidate = read_json(stage / "config.json")
    if candidate.get("revision") == revision:
        atomic_json(stage / "rejected.json", {"schema_version": 1, "revision": revision, "error": error,
                                              "time": int(time.time())})


def refuse_replacement(old, incoming, candidate, replace, mode, files):
    """None if the incoming APK may be staged, "unchanged" for a no-op, or
    raise with the reason it is refused."""
    if incoming["format"] != old["format"]:
        raise ValueError("Changing between APK and APKM is unsupported because it changes the Steam target")
    if incoming["version_code"] < old["version_code"]:
        raise ValueError(f"Android version downgrade refused (library has {old['version_code']}, "
                         f"incoming {incoming['version_code']})")
    if incoming["sha256"] == old["sha256"] and not files:
        if mode == "import" or candidate is None:
            return "unchanged"
        raise ValueError("This is the library's current APK; run lepton-library discard to drop the staged update")
    if mode == "import":
        raise ValueError("Package already imported. To replace it, run lepton-library update FILE.")
    if incoming["version_code"] == old["version_code"] and incoming["sha256"] != old["sha256"] and not replace:
        raise ValueError("Same version with different contents; use update --replace-same-version")
    return None


def import_app(root, source, *, mode, replace=False, obbs=(), dry_run=False, verbose=True):
    """Import a new app as the active APK, or stage an update for an existing
    one. Returns (directory, metadata, path, staged)."""
    source = source.expanduser().absolute()
    regular(source)
    suffix = source.suffix.lower()
    if suffix not in FORMATS:
        raise ValueError("Expected an APK or APKM file")
    with lock(root, not dry_run), tempfile.TemporaryDirectory(
            prefix=".import-", dir=None if dry_run else root) as scratch:
        stage = Path(scratch)
        candidate_file = stage / ("candidate" + suffix)
        copy_file(source, candidate_file)
        incoming = inspect(candidate_file, suffix)
        package = incoming["package"]
        files = obb_files(obbs, package)
        directory = root / package
        apk = directory / (package + suffix)
        staged = stage / apk.name
        candidate_file.rename(staged)
        if not exists(directory):
            if mode == "update":
                raise ValueError(f"{package} is not imported; run lepton-library import FILE")
            return new_app(root, stage, directory, apk, incoming, files, dry_run)
        if exists(directory / JOURNAL):
            commit_update(directory)
        _, old, active = load_app(root, package, verify=True)
        current = load_candidate(directory, old, verify=False)
        if verbose:
            print(f"{package}: library {old['version_name']} ({old['version_code']}), "
                  f"incoming {incoming['version_name']} ({incoming['version_code']})")
        if refuse_replacement(old, incoming, current, replace, mode, files) == "unchanged":
            return directory, old, active, False
        if current and current["config"]["sha256"] == incoming["sha256"] and not files:
            return directory, current["config"], active, True
        if verbose and old["signers"] and incoming["signers"] and old["signers"] != incoming["signers"]:
            print("WARNING: the signing certificate differs from the library APK. Android installs it only "
                  "if this is a valid signing-key rotation; otherwise the update is refused and the "
                  "installed version is kept.")
        if verbose and current:
            print(f"Replacing the staged update {current['config']['version_name']} "
                  f"({current['config']['version_code']}), which Android had not accepted.")
        config = dict(incoming, schema_version=1, revision=uuid.uuid4().hex, pending_obb={})
        obb_dir = directory / "obb"
        real_dir(obb_dir)
        for name, src in files.items():
            dst = obb_dir / name
            if exists(dst):
                regular(dst)
                if sha256(src) != sha256(dst):
                    raise ValueError(f"Refusing to replace existing OBB {dst}")
                continue
            if not dry_run:
                copy_file(src, stage / name)
                config["pending_obb"][name] = sha256(stage / name)
        if dry_run:
            return directory, config, apk, True
        staged.rename(stage / apk.name)  # same name; keeps the layout explicit
        atomic_json(stage / "config.json", config)
        stage.chmod(0o700)
        # Replace any previous candidate. The active APK is never touched here.
        discard_dir(directory, CANDIDATE)
        os.rename(stage, directory / CANDIDATE)
        sync_dir(directory)
        return directory, config, apk, True


def new_app(root, stage, directory, apk, incoming, files, dry_run):
    config = dict(incoming, schema_version=1, revision=uuid.uuid4().hex, shared_folders={"custom": []})
    if dry_run:
        return directory, config, apk, False
    obb_dir = stage / "obb"
    obb_dir.mkdir()
    for name, src in files.items():
        copy_file(src, obb_dir / name)
    sync_dir(obb_dir)
    atomic_json(stage / "config.json", config)
    stage.chmod(0o700)
    os.rename(stage, directory)
    sync_dir(root)
    return directory, config, apk, False


def restore_previous(directory, config, apk, dry_run):
    """Make the APK kept in .previous the active library APK again. Android
    profiles that already installed a newer version keep it."""
    backup = directory / PREVIOUS
    real_dir(backup)
    previous = check_metadata(read_json(backup / "config.json"), directory.name, "previous APK metadata")
    source = backup / apk.name
    regular(source)
    if sha256(source) != previous["sha256"] or previous["format"] != config["format"]:
        raise ValueError("Previous APK or metadata is invalid")
    if not dry_run:
        stage = Path(tempfile.mkdtemp(prefix=".restore-", dir=directory))
        copy_file(source, stage / apk.name)
        atomic_json(stage / "config.json", {**{key: previous.get(key) for key in METADATA},
                                            "schema_version": 1, "package": directory.name,
                                            "format": config["format"]})
        journal(directory, stage.name)
    return previous


def runtime_app(root, target):
    """For a launch of TARGET: None if it is not a library APK, else the saved
    shared-folder option, the app directory, the OBB directory and the
    launcher activity of the version this launch installs."""
    raw = Path(os.path.abspath(target))
    path = raw.resolve()
    if raw.parent.parent == root and raw != path:
        raise ValueError(f"Managed APK path must contain real files and directories: {raw}")
    if path.parent.parent != root or path.suffix not in FORMATS:
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
    candidate = load_candidate(directory, config)
    target_config = candidate["config"] if candidate and not candidate["rejected"] else config
    return value, str(directory), str(obb) if any(obb.iterdir()) else "", target_config.get("launchable_activity") or ""


def profile_key(baked):
    return hashlib.sha256(os.fsencode(baked)).hexdigest()


def profile_receipts(directory):
    index = directory / ".profiles"
    if not exists(index):
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
