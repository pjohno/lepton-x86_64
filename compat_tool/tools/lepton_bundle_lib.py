# SPDX-License-Identifier: MIT
"""Shared bundle helpers: Android/sysbake tree records, portable xattrs,
optional-component detection and release metadata.

Used by the official packager (image-14/scripts/lib/deck-bundle.sh), by
lepton-customize (sysbake, package, restore) and by lepton-compare-bundles.
Standard library only; nothing here compiles, downloads or runs bundle code.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tarfile

ROOTFS = 'compat_tool/images/rootfs/'
SYSBAKE = 'compat_tool/sysbake/'
XATTRS = 'compat_tool/sysbake.xattrs'
# Exactly the inputs of lepton_runtime_fingerprint (compat_tool/liblepton/liblepton.sh),
# concatenated in this order.
FINGERPRINT_INPUTS = (ROOTFS + 'system/build.prop', ROOTFS + 'vendor/build.prop',
                      ROOTFS + 'system/framework/services.jar', SYSBAKE + 'system/packages.xml')
GAPPS_MARKER = 'system/product/priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk'
NDK_MARKER = 'system/lib64/libndk_translation.so'
WIDEVINE_NAME = 'com.google.android.widevine'
WIDEVINE_DIR = 'vendor/apex/' + WIDEVINE_NAME
WIDEVINE_FILES = ('apex_manifest.pb', 'bin/hw/android.hardware.drm-service.widevine',
                  f'etc/{WIDEVINE_NAME}.rc', f'etc/vintf/{WIDEVINE_NAME}.xml', 'lib64/libcrypto.so')
COMPONENTS = ('gapps', 'ndk', 'widevine')
# Packages GApps registers in packages.xml: Play services, Play Store, GSF.
GAPPS_PACKAGES = ('com.google.android.gms', 'com.android.vending', 'com.google.android.gsf')
# Components recorded in BUNDLE.json. Bundles made before widevine was
# recorded lack the field; readers treat it as false (metadata_components).
METADATA_COMPONENTS = COMPONENTS
CHUNK = 1024 * 1024


class BundleError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise BundleError(message)


def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as stream:
        for chunk in iter(lambda: stream.read(CHUNK), b''):
            digest.update(chunk)
    return digest.hexdigest()


# ---------------------------------------------------------------- tree records
# A record is (kind, permissions, value): kind 'd' directory, 'f' regular file
# (hardlinks included, by content), 'l' symlink. value is the content SHA256
# for files and the verbatim target for symlinks. Owners and times are ignored.

def tree_digest(records):
    digest = hashlib.sha256()
    for name in sorted(records):
        kind, mode, value = records[name]
        digest.update(f'{name}\0{kind}\0{mode:04o}\0{value}\n'.encode('utf-8', 'surrogateescape'))
    return digest.hexdigest()


def scan_directory(root, sockets=None):
    """Records for everything below root (root itself excluded). Never follows links.

    Unix sockets left by Android are skipped, as tar skips them when bundles
    are made; their names are appended to `sockets` when a list is given.
    """
    root = Path(root)
    require(root.is_dir() and not root.is_symlink(), f'Missing directory: {root}')
    records = {}

    def failed(error):
        raise BundleError(f'Cannot read {error.filename}: {error.strerror}')
    for parent, dirs, files in os.walk(root, onerror=failed, followlinks=False):
        dirs.sort()
        for name in dirs + sorted(files):
            path = Path(parent) / name
            relative = path.relative_to(root).as_posix()
            info = path.lstat()
            mode = stat.S_IMODE(info.st_mode)
            if stat.S_ISDIR(info.st_mode):
                require(os.access(path, os.R_OK | os.X_OK, follow_symlinks=False),
                        f'Unreadable directory (fix permissions before packaging): {path}')
                records[relative] = ('d', mode, '')
            elif stat.S_ISLNK(info.st_mode):
                records[relative] = ('l', 0, os.readlink(path))
            elif stat.S_ISSOCK(info.st_mode):
                if sockets is not None:
                    sockets.append(relative)
            elif stat.S_ISREG(info.st_mode):
                try:
                    records[relative] = ('f', mode, file_sha256(path))
                except PermissionError:
                    raise BundleError(f'Unreadable file (fix permissions before packaging): {path}') from None
            else:
                raise BundleError(f'Unsupported special file: {path}')
    return records


def safe_name(name):
    require(not name.startswith('/') and '\\' not in name and
            not any(ord(c) < 32 or ord(c) == 127 for c in name), f'Unsafe archive path: {name!r}')
    parts = name.split('/')
    require('..' not in parts, f'Archive path traversal: {name!r}')
    return '/'.join(p for p in parts if p not in ('', '.'))


def link_escapes(name, target):
    """True if a relative symlink would leave the archive root."""
    if target.startswith('/'):
        return False
    depth = len(name.split('/')) - 1
    for part in target.split('/'):
        if part == '..':
            depth -= 1
            if depth < 0:
                return True
        elif part not in ('', '.'):
            depth += 1
    return False


class ArchiveScan:
    """One streaming read of a bundle archive; nothing is extracted.

    Records the rootfs and sysbake trees, every other entry, the xattr record,
    BUNDLE.json, provenance and the runtime fingerprint inputs. Unsafe or
    malformed entries are rejected.
    """
    KEEP = {XATTRS, 'BUNDLE.json', 'tools/BUNDLE-PROVENANCE.txt', 'tools/IMAGE-PROVENANCE.txt',
            ROOTFS + WIDEVINE_DIR + '/apex_manifest.pb'} | set(FINGERPRINT_INPUTS)
    MAX_KEEP = 256 * 1024 * 1024

    def __init__(self, path):
        self.path = Path(path)
        self.rootfs, self.sysbake, self.other = {}, {}, {}
        self.files = {}
        self.sha256 = None
        names = set()
        hashes = {}
        digest = hashlib.sha256()

        class Hashing:
            def __init__(self, stream):
                self.stream = stream

            def read(self, size=-1):
                data = self.stream.read(size)
                digest.update(data)
                return data
        try:
            with open(self.path, 'rb') as raw:
                hashing = Hashing(raw)
                with tarfile.open(fileobj=hashing, mode='r|gz') as tar:
                    for member in tar:
                        name = safe_name(member.name)
                        if not name:
                            require(member.isdir(), 'Archive root must be a directory')
                            continue
                        require(name not in names, f'Duplicate archive path: {name}')
                        names.add(name)
                        require(member.isdir() or member.isreg() or member.issym() or member.islnk(),
                                f'Unsupported archive entry (device/FIFO/special): {name}')
                        require(not member.sparse, f'Sparse archive entries are unsupported: {name}')
                        for parent in Path(name).parents:
                            entry = self.lookup(str(parent))
                            require(str(parent) == '.' or entry is None or entry[0] == 'd',
                                    f'Archive entry below a link/non-directory: {name}')
                        mode = member.mode & 0o7777
                        if member.isdir():
                            record = ('d', mode, '')
                        elif member.issym():
                            target = member.linkname
                            require(target and not any(ord(c) < 32 for c in target), f'Invalid symlink: {name}')
                            require(not link_escapes(name, target), f'Symlink escapes the archive: {name}')
                            require(not target.startswith('/') or name.startswith((ROOTFS, SYSBAKE)),
                                    f'Absolute symlink outside the Android namespace: {name} -> {target}')
                            record = ('l', 0, target)
                        elif member.islnk():
                            target = safe_name(member.linkname)
                            require(target in hashes, f'Hardlink to a missing or later entry: {name}')
                            record = ('f', mode, hashes[target])
                            hashes[name] = hashes[target]
                            if name in self.KEEP and target in self.files:
                                self.files[name] = self.files[target]
                        else:
                            stream = tar.extractfile(member)
                            content = hashlib.sha256()
                            keep = name in self.KEEP and member.size <= self.MAX_KEEP
                            kept = bytearray()
                            size = 0
                            for chunk in iter(lambda: stream.read(CHUNK), b''):
                                content.update(chunk)
                                size += len(chunk)
                                if keep:
                                    kept += chunk
                            require(size == member.size, f'Truncated archive entry: {name}')
                            hashes[name] = content.hexdigest()
                            record = ('f', mode, hashes[name])
                            if keep:
                                self.files[name] = bytes(kept)
                        self.store(name, record)
                    # Consume the gzip trailer so its CRC is verified as well.
                    while tar.fileobj.read(CHUNK):
                        pass
                while hashing.read(CHUNK):
                    pass
        except (tarfile.TarError, EOFError, OSError, UnicodeError) as exc:
            raise BundleError(f'Malformed or unreadable archive {self.path}: {exc}') from None
        self.sha256 = digest.hexdigest()

    def lookup(self, name):
        for prefix, table in ((ROOTFS, self.rootfs), (SYSBAKE, self.sysbake)):
            if name.startswith(prefix):
                return table.get(name[len(prefix):])
        return self.other.get(name)

    def store(self, name, record):
        for prefix, table in ((ROOTFS, self.rootfs), (SYSBAKE, self.sysbake)):
            if name.startswith(prefix):
                table[name[len(prefix):]] = record
                return
        self.other[name] = record

    def metadata(self):
        data = self.files.get('BUNDLE.json')
        if data is None:
            return None
        try:
            value = json.loads(data)
        except ValueError:
            raise BundleError('Invalid BUNDLE.json') from None
        require(isinstance(value, dict), 'Invalid BUNDLE.json')
        return value

    def fingerprint(self):
        return fingerprint_from(lambda name: self.files.get(name))

    def components(self):
        """Optional components installed in the archived rootfs (not BUNDLE.json)."""
        return records_components(self.rootfs, lambda name: self.files.get(ROOTFS + name, b''))


def fingerprint_from(read):
    """Runtime fingerprint (liblepton.sh) and its per-input SHA256."""
    inputs = {}
    combined = hashlib.sha256()
    complete = True
    for name in FINGERPRINT_INPUTS:
        data = read(name)
        if data is None:
            inputs[name] = None
            complete = False
            continue
        inputs[name] = hashlib.sha256(data).hexdigest()
        combined.update(data)
    return dict(inputs=inputs, fingerprint=combined.hexdigest() if complete else None)


def stage_fingerprint(stage):
    def read(name):
        path = Path(stage) / name
        return path.read_bytes() if path.is_file() and not path.is_symlink() else None
    return fingerprint_from(read)


# ---------------------------------------------------------------- portable xattrs
def _unescape(text):
    # getfattr escapes control characters, '=' and '\\' as octal \ooo.
    return re.sub(rb'\\([0-7]{3})', lambda m: bytes([int(m[1], 8)]), text.encode('utf-8', 'surrogateescape')
                  ).decode('utf-8', 'surrogateescape')


def parse_xattrs(data, strict=True):
    """Parse a `getfattr -R -P -h -d -m -` record: {path: {name: value}}.

    Paths must stay inside sysbake/ and attributes must be restorable by an
    ordinary user (user.* only; never security.selinux or trusted.*).
    strict=False only parses (for reporting differences); it validates nothing
    beyond the record syntax.
    """
    require(isinstance(data, bytes), 'Invalid xattr record')
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError:
        raise BundleError('sysbake.xattrs is not valid UTF-8') from None
    entries = {}
    current = None
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            current = None
            continue
        if line.startswith('# file: '):
            path = _unescape(line[len('# file: '):])
            parts = path.split('/')
            require(not strict or (parts[0] == 'sysbake' and not any(p in ('', '.', '..') for p in parts)),
                    f'sysbake.xattrs line {number}: path outside sysbake/: {path!r}')
            require(path not in entries, f'sysbake.xattrs line {number}: duplicate path {path!r}')
            current = entries[path] = {}
            continue
        require(current is not None and '=' in line, f'sysbake.xattrs line {number}: malformed entry')
        name, value = line.split('=', 1)
        require(not strict or (name.startswith('user.') and len(name) > 5),
                f'sysbake.xattrs line {number}: attribute {name!r} cannot be restored by an ordinary user')
        require(name not in current, f'sysbake.xattrs line {number}: duplicate attribute {name}')
        current[name] = value
    if strict:
        require(entries, 'sysbake.xattrs records no files')
        require(any(entries.values()), 'sysbake.xattrs records no user.* attributes')
    return entries


def check_xattr_paths(entries, records):
    """Recorded paths must name sysbake entries (records are sysbake-relative).

    Android sockets are recorded by getfattr but never archived, so a path may
    be absent only directly inside an existing directory. Returns those paths.
    """
    def kind(path):
        if path == 'sysbake':
            return 'd'
        return (records.get(path[len('sysbake/'):]) or (None,))[0]
    missing = sorted(path for path in entries if kind(path) is None)
    orphaned = [path for path in missing if kind(path.rsplit('/', 1)[0]) != 'd']
    require(not orphaned, 'sysbake.xattrs names paths outside the sysbake tree: ' + ', '.join(orphaned[:5]))
    return missing


# ---------------------------------------------------------------- packages.xml
# Android Binary XML (ABX), as written by
# frameworks/base/core/java/com/android/internal/util/BinaryXmlSerializer.java.
# A token byte holds the event in its low nibble and the value type in its high
# nibble. Strings are modified UTF-8 with a big-endian 16-bit length; interned
# strings are a 16-bit table index, or 0xFFFF followed by a new string.
_ABX_EVENTS = {0: 'start_document', 1: 'end_document', 2: 'start_tag', 3: 'end_tag', 4: 'text', 5: 'cdsect',
               6: 'entity_ref', 7: 'ignorable_whitespace', 8: 'processing_instruction', 9: 'comment',
               10: 'docdecl', 15: 'attribute'}
_ABX_FIXED = {0x60: 4, 0x70: 4, 0x80: 8, 0x90: 8, 0xA0: 4, 0xB0: 8, 0xC0: 0, 0xD0: 0}


class _AbxReader:
    def __init__(self, data):
        self.data, self.pos, self.interned = data, 4, []

    def take(self, size):
        require(self.pos + size <= len(self.data), 'Truncated Android binary XML (packages.xml)')
        chunk = self.data[self.pos:self.pos + size]
        self.pos += size
        return chunk

    def utf(self):
        raw = self.take(int.from_bytes(self.take(2), 'big'))
        # Modified UTF-8 encodes NUL as C0 80 and supplementary characters as surrogate pairs.
        return raw.replace(b'\xc0\x80', b'\x00').decode('utf-8', 'surrogatepass')

    def interned_utf(self):
        index = int.from_bytes(self.take(2), 'big')
        if index == 0xFFFF:
            value = self.utf()
            self.interned.append(value)
            return value
        require(index < len(self.interned), 'Invalid interned string in Android binary XML')
        return self.interned[index]

    def value(self, kind):
        if kind == 0x10:
            return None
        if kind == 0x20:
            return self.utf()
        if kind == 0x30:
            return self.interned_utf()
        if kind in (0x40, 0x50):
            return self.take(int.from_bytes(self.take(2), 'big'))
        require(kind in _ABX_FIXED, f'Unknown Android binary XML value type 0x{kind:02x}')
        return self.take(_ABX_FIXED[kind])


def parse_abx(data):
    """Parse ABX into (tag, attributes, children) trees under the document."""
    require(data.startswith(b'ABX\x00'), 'Not Android binary XML')
    reader = _AbxReader(data)
    root = ('#document', {}, [])
    stack = [root]
    ended = False
    while reader.pos < len(data):
        require(not ended, 'Data after the end of the Android binary XML document')
        token = reader.take(1)[0]
        event, kind = _ABX_EVENTS.get(token & 0x0F), token & 0xF0
        require(event is not None, f'Unknown Android binary XML event {token & 0x0F}')
        if event == 'attribute':
            require(len(stack) > 1, 'Android binary XML attribute outside an element')
            name = reader.interned_utf()
            stack[-1][1][name] = reader.value(kind)
        elif event == 'start_tag':
            require(kind == 0x30, 'Android binary XML element name is not interned')
            element = (reader.interned_utf(), {}, [])
            stack[-1][2].append(element)
            stack.append(element)
        elif event == 'end_tag':
            require(kind == 0x30 and len(stack) > 1, 'Unbalanced Android binary XML end tag')
            require(reader.interned_utf() == stack.pop()[0], 'Mismatched Android binary XML end tag')
        elif event == 'end_document':
            require(len(stack) == 1, 'Android binary XML ended inside an element')
            ended = True
        elif event != 'start_document':
            reader.value(kind)  # text, comments and other content are not needed
    require(ended and len(stack) == 1, 'Incomplete Android binary XML document')
    return root


def registered_packages(data):
    """Package names registered in packages.xml (binary ABX or text XML).

    Raises BundleError unless the file is a complete, well-formed package list.
    """
    if data.startswith(b'ABX\x00'):
        document = parse_abx(data)
        roots = [child for child in document[2] if child[0] == 'packages']
        require(len(roots) == 1, 'packages.xml has no single <packages> root')
        entries = [(child[0], child[1].get('name')) for child in roots[0][2]]
    else:
        import xml.etree.ElementTree as ElementTree
        try:
            element = ElementTree.fromstring(data)
        except ElementTree.ParseError as exc:
            raise BundleError(f'packages.xml is not well-formed XML: {exc}') from None
        require(element.tag == 'packages', 'packages.xml has no <packages> root')
        entries = [(child.tag, child.get('name')) for child in element]
    names = {name for tag, name in entries if tag == 'package' and isinstance(name, str) and name}
    require(names, 'packages.xml registers no packages')
    return names


# ---------------------------------------------------------------- components
def check_registered_packages(data, gapps):
    """packages.xml must be a complete package list with the framework, and
    must register the GApps packages exactly when GApps are installed."""
    names = registered_packages(data)
    require('android' in names, 'packages.xml does not register the Android framework package')
    present = sorted(name for name in GAPPS_PACKAGES if name in names)
    if gapps:
        require(len(present) == len(GAPPS_PACKAGES), 'packages.xml lacks GApps packages: ' +
                ', '.join(sorted(set(GAPPS_PACKAGES) - set(present))))
    else:
        require(not present, 'packages.xml registers GApps packages without GApps: ' + ', '.join(present))
    return names


def detect_components(kind_of, read):
    """Optional components actually installed in a rootfs.

    kind_of(rel) -> 'f'|'d'|'l'|None and read(rel) -> bytes describe the rootfs
    (a directory or archive). A flag reflects the installed files, never a request.
    """
    gapps = kind_of(GAPPS_MARKER) == 'f'
    ndk = kind_of(NDK_MARKER) == 'f'
    widevine = False
    apex = kind_of(WIDEVINE_DIR)
    if apex is not None:
        require(apex == 'd', f'Unsupported Widevine installation (not a flattened APEX directory): {WIDEVINE_DIR}')
        for name in WIDEVINE_FILES:
            require(kind_of(WIDEVINE_DIR + '/' + name) == 'f', f'Incomplete Widevine APEX: {WIDEVINE_DIR}/{name}')
        require(WIDEVINE_NAME.encode() in read(WIDEVINE_DIR + '/apex_manifest.pb'), 'Unexpected Widevine APEX manifest')
        widevine = True
    return dict(gapps=gapps, ndk=ndk, widevine=widevine)


def stage_components(rootfs):
    rootfs = Path(rootfs)

    def kind_of(name):
        path = rootfs / name
        for parent in Path(name).parents:
            if str(parent) != '.' and (rootfs / parent).is_symlink():
                return None
        if path.is_symlink():
            return 'l'
        if path.is_dir():
            return 'd'
        return 'f' if path.is_file() else None
    return detect_components(kind_of, lambda name: (rootfs / name).read_bytes())


def implied_kind(kinds, name):
    """Kind of an archived path; a directory may be implied by entries below it."""
    kind = kinds.get(name)
    if kind is None and any(other.startswith(name + '/') for other in kinds):
        return 'd'
    return kind


def records_components(records, read):
    kinds = {name: record[0] for name, record in records.items()}
    return detect_components(lambda name: implied_kind(kinds, name), read)


def metadata_components(metadata):
    """Component flags from BUNDLE.json; legacy bundles lack widevine (false)."""
    flags = {}
    for name in COMPONENTS:
        value = metadata.get(name, False if name == 'widevine' else None)
        require(type(value) is bool, f'BUNDLE.json {name} must be true or false')
        flags[name] = value
    return flags


# ---------------------------------------------------------------- release metadata
COMPONENT_LABELS = (('gapps', 'GApps'), ('ndk', 'NDK'), ('widevine', 'Widevine'))


def default_display_name(bundle_id, components, kind='community'):
    """Steam's name for a tool, version first so it shows in narrow menus:
    "lepton v0.2.0-alpha x86_64 (community)", or with optional components
    "lepton v0.2.0-alpha x86_64 (community, GApps + NDK)". lepton-install-bundle
    applies the same rule to bundles packaged with the older names."""
    extras = [label for key, label in COMPONENT_LABELS if components.get(key)]
    detail = kind + (', ' + ' + '.join(extras) if extras else '')
    return f'lepton {bundle_id} x86_64 ({detail})'


def bundle_metadata(bundle_id, tool_id, display_name, install_directory, components, **extra):
    data = dict(format_version=2, bundle_id=bundle_id, tool_id=tool_id, display_name=display_name,
                install_directory=install_directory)
    data.update({name: bool(components[name]) for name in METADATA_COMPONENTS})
    data.update(extra)
    return json.dumps(data, indent=2) + '\n'


def install_text(name, bundle, installer, directory, tool):
    return f'''Lepton Steam Deck bundle: {name}

Install (Desktop Mode): double-tap the "Install Lepton {bundle}" desktop icon
(or the .install.sh file in Dolphin), or in Konsole:
  bash ~/Downloads/lepton-deck-bundles/{installer}

The installer needs an internet connection: Google's Android Debug Bridge
(adb) is not included in this bundle. The installer downloads the official
Android Platform-Tools ZIP directly from Google (dl.google.com), installs only
adb (pinned SHA256 and version) plus Google's NOTICE.txt, and changes nothing
if that download or check fails. Offline: --adb-zip FILE with a copy of the
same official ZIP.

The installer verifies the checksum, extracts to ~/.local/share/{directory},
registers the Steam compatibility tool "{name}", and writes
~/.config/lepton-x86_64/{tool}.env. With --steam-compat it installs instead
into Steam's own folder, ~/.steam/root/compatibilitytools.d/{directory}, as
one self-contained compatibility tool (like GE-Proton); updates keep the
folder an install already uses. It never overwrites an existing install
unless you choose to: from the desktop icon it asks "new tool or replace?" and
then offers to remove older installs; in a terminal use --into TOOL_ID,
--replace or --remove TOOL_ID. "Lepton: Remove installs" cleans up later.
Steam does not need to be closed to install or remove; restart it afterwards.

Then use the new desktop/menu entries (no typing needed):
  "Lepton: Install / Update / Repair"  later versions from GitHub Releases,
                                updates, repair; stays when installs are removed
  "Lepton: Check graphics"      confirms AMD RADV graphics
  "Lepton: Add Android game"    picks an APK/APKM; asks you to exit Steam, then
                                says when it is safe to start Steam again
Terminal equivalents:
  ~/.local/bin/lepton-run-apk --gpu-check --execute
  ~/.local/bin/lepton-add-game ~/path/to/game.apk   # with Steam exited

Enable Touchscreen Native Support in the game's controller
layout (Controller Settings > Edit Layout > Default Action Set >
Always-On Command > System > Touchscreen Native Support).

Save using the game's own save/exit function before pressing Steam Stop.
In 2048, Exit or going back through moves saves the board. Steam Stop keeps
the last saved board but does not guarantee that new moves are saved.

For Google sign-in and APKM games in a persistent profile, see GAPPS.md.
Saved profiles and credentials are never bundled.
'''


def write_metadata(payload, bundle, tool, name, directory, archive, installer):
    """Official packager: flags come from the payload rootfs."""
    payload = Path(payload)
    components = stage_components(payload / ROOTFS)
    # An empty name means the default (an explicit --tool-name is kept).
    name = name or default_display_name(bundle, components)
    (payload / 'BUNDLE.json').write_text(bundle_metadata(bundle, tool, name, directory, components))
    (payload / 'STEAM-DECK-INSTALL.txt').write_text(install_text(name, bundle, installer, directory, tool))
    return components


def main(argv):
    if len(argv) == 8 and argv[0] == 'write-metadata':
        try:
            components = write_metadata(*argv[1:])
        except (BundleError, OSError) as exc:
            print(f'ERROR: {exc}', file=sys.stderr)
            return 1
        print('Components: ' + ', '.join(f'{k}={str(v).lower()}' for k, v in components.items()))
        return 0
    print('Usage: lepton_bundle_lib.py write-metadata PAYLOAD BUNDLE_ID TOOL_ID NAME DIRECTORY ARCHIVE INSTALLER',
          file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
