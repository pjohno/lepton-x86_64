# SPDX-License-Identifier: MIT
"""Phase 3 orchestration. Component extraction stays in the bundled helpers."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import stat
import subprocess
import tarfile
import tempfile
import uuid
import zipfile

EXPECTED_TRANSLATOR = 'a2086fbc807f697f9b91222065c9d9000ca9727748699c0d9b751319258cbb3e'
IDENTITY = {'Pkg.Revision': '14', 'AndroidVersion.ApiLevel': '34',
            'SystemImage.Abi': 'x86_64', 'SystemImage.TagId': 'google_apis_playstore'}
PACKAGES = {'debugfs': 'e2fsprogs', 'rsync': 'rsync', 'unzip': 'unzip', 'sfdisk': 'util-linux',
            'readelf': 'binutils', 'lpunpack': 'an Android logical-partition unpacker (host utility)',
            'python3': 'python3', 'bash': 'bash'}
PACKAGES.update(dict.fromkeys('sha256sum realpath sort mktemp dirname mkdir chmod rm cat dd cut mv wc basename'.split(), 'coreutils'))
PACKAGES.update(awk='gawk', sed='sed', cmp='diffutils', find='findutils', xargs='findutils', grep='grep')


def command(argv, core, env=None, capture=False):
    """Stop the whole helper process group before cleaning temporary files."""
    proc = subprocess.Popen([str(a) for a in argv], env=env, start_new_session=True,
                            stdout=subprocess.PIPE if capture else None)
    try:
        output, _ = proc.communicate()
    except BaseException:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
        # A shell may exit before a TERM-ignoring child. Stop any remaining
        # group members before the caller removes its private workspace.
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        raise
    core.require(proc.returncode == 0, f'{Path(argv[0]).name} helper failed (exit {proc.returncode}); see diagnostics above')
    return output


def shell_function(library, function, arguments, core, env=None):
    # Function names are internal constants; every user path is a separate argv.
    return command(['bash', '-euo', 'pipefail', '-c',
                    'source "$1"; shift; ' + function + ' "$@"', 'lepton-customize',
                    library, *arguments], core, env)


def safe_path(value, core, existing=True):
    path = Path(os.path.abspath(value))
    core.require(not any(c in str(path) for c in '\\"\n\r\t'),
                 f'Path contains characters unsupported by debugfs: {path}')
    core.require(path.resolve() == path and not path.is_symlink(), f'Unsafe symlink path: {path}')
    core.require(not existing or path.exists(), f'Input does not exist: {path}')
    return path


def disjoint(a, b, core):
    core.require(a != b and a not in b.parents and b not in a.parents,
                 f'Paths must not overlap: {a} and {b}')


def inventory(root, core):
    entries = {}
    def inaccessible(error):
        raise error
    for parent, dirs, files in os.walk(root, followlinks=False, onerror=inaccessible):
        for name in dirs + files:
            path = Path(parent) / name
            info = path.lstat()
            relative = path.relative_to(root).as_posix()
            core.canonical(relative)
            core.require(stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode),
                         f'Unsupported stage/input filesystem entry: {relative}')
            entries[relative] = (info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns,
                                 os.readlink(path) if stat.S_ISLNK(info.st_mode) else None)
    return entries


class StageView:
    """Present a disk stage to Stage 2's existing base-bundle validator."""
    def __init__(self, root, core):
        self.root, self.core = root, core
        self.snapshot = inventory(root, core)
        self.members = {}
        state = root / 'STAGE.json'
        if state.is_file() and not state.is_symlink():
            try:
                current = json.loads(core.read_small(state)).get('state')
            except (ValueError, AttributeError):
                current = None
            core.require(current != 'customized',
                         'This stage is already customized; inject into the clean prepared stage it came from, '
                         'selecting all components in one operation')
        for name, (mode, size, _, _, link) in self.snapshot.items():
            core.require(name in {'STAGE.json', 'source-bundle', 'tests', 'tests/runtime'} or
                         name.startswith('source-bundle/') or core.retained(name),
                         f'Source is not a clean Stage 2 stage: unexpected state {name}')
            member = tarfile.TarInfo(name)
            member.mode, member.size = stat.S_IMODE(mode), size
            member.offset_data = 0  # No compressed-archive seeking needed.
            if stat.S_ISDIR(mode):
                member.type = tarfile.DIRTYPE
            elif stat.S_ISLNK(mode):
                member.type, member.linkname = tarfile.SYMTYPE, link
                core.symbolic_target(name, link)
            self.members[name] = member
        core.require('BUNDLE.json' not in self.members, 'A working stage must not have a release BUNDLE.json')
        core.require('source-bundle/BUNDLE.json' in self.members, 'Source bundle identity is missing')
        self.members['BUNDLE.json'] = self.members['source-bundle/BUNDLE.json']

    def regular(self, name):
        return self.core.Bundle.regular(self, name)

    def read(self, name):
        name = self.regular(name)
        if name == 'BUNDLE.json':
            name = 'source-bundle/BUNDLE.json'
        self.core.require(self.members[name].size <= self.core.MAX_INSPECT, f'Inspection file too large: {name}')
        return (self.root / name).read_bytes()

    def validate(self):
        stage = json.loads(self.read('STAGE.json'), object_pairs_hook=self.core.unique_keys)
        self.core.require(isinstance(stage, dict) and type(stage.get('format_version')) is int and
                          stage['format_version'] == 1 and stage.get('state') == 'prepared' and
                          stage.get('sysbake_required') is True and not stage.get('components'),
                          'Injection requires a clean Stage 2 prepared stage; select all components in one operation')
        metadata, _ = self.core.Bundle.validate(self)
        self.core.require(stage.get('source_bundle_id') == metadata['bundle_id'], 'Stage/source bundle identity mismatch')
        provenance = json.loads(self.read('source-bundle/SOURCE.json'), object_pairs_hook=self.core.unique_keys)
        self.core.require(isinstance(provenance, dict) and isinstance(provenance.get('sha256'), str) and
                          re.fullmatch(r'[0-9a-f]{64}', provenance['sha256']),
                          'Invalid source-bundle provenance')
        return stage, metadata, provenance


def file_hash(path, core):
    with path.open('rb') as stream:
        return core.sha256(stream)


def manifest(path, core):
    entries = {}
    for line in core.read_small(path).decode('utf-8').splitlines():
        match = re.fullmatch(r'([0-9a-f]{64}) [ *](.+)', line)
        core.require(match, f'Malformed checksum manifest: {path}')
        name = core.canonical(match[2])
        core.require(name and name not in entries, f'Duplicate/empty checksum path: {path}')
        entries[name] = match[1]
    core.require(entries, f'Empty checksum manifest: {path}')
    return entries


def validate_inputs(inputs, selected, core):
    tree = inventory(inputs, core)
    core.require(all(link is None for *_, link in tree.values()), 'Prepared Google inputs must not contain symlinks')
    for name in ('SOURCE.txt', 'SOURCE.properties', 'BUILD.prop', 'SOURCE-IMAGES.sha256'):
        core.require((inputs / name).is_file(), f'Prepared inputs lack {name}; reprepare with the updated bundled helper')
    identity = core.properties(core.read_small(inputs / 'SOURCE.properties'))
    core.require(all(identity.get(k) == v for k, v in IDENTITY.items()),
                 'Unsupported Google inputs: require Google Play x86_64 API 34 revision 14')
    props = core.properties(core.read_small(inputs / 'BUILD.prop'))
    core.require(props.get('ro.build.version.sdk') == '34' and
                 props.get('ro.build.flavor') == 'sdk_gphone64_x86_64-user', 'Invalid Google API level or image flavour')
    text = core.read_small(inputs / 'SOURCE.txt').decode()
    source_hash = re.search(r'^Source SHA256: ([0-9a-f]{64})$', text, re.M)
    source_name = re.search(r'^Source zip: (.+)$', text, re.M)
    core.require(source_hash and source_name, 'Prepared Google inputs lack ZIP source identity/checksum')
    checksums = manifest(inputs / 'SOURCE-IMAGES.sha256', core)
    core.require(all('/' not in n and n.endswith('.img') for n in checksums), 'Unsafe Google image manifest')
    partitions = {'system'} if selected['ndk'] or selected['gapps'] else set()
    if selected['gapps']:
        partitions.update(('product', 'system_ext'))
    if selected['widevine']:
        partitions.add('vendor')
    verified = {}
    for part in sorted(partitions):
        name = part + '.img'
        image = inputs / 'logical-partitions' / name
        core.require(image.is_file() and name in checksums, f'Missing Google partition or checksum: {name}')
        actual = file_hash(image, core)
        core.require(actual == checksums[name], f'Google image checksum mismatch: {name}')
        verified[name] = actual
    if 'system.img' in verified:
        logical_props = command(['debugfs', '-R', 'cat /system/build.prop',
                                 inputs / 'logical-partitions/system.img'], core, capture=True)
        actual_props = core.properties(logical_props)
        core.require(actual_props.get('ro.build.version.sdk') == '34' and
                     actual_props.get('ro.build.flavor') == 'sdk_gphone64_x86_64-user',
                     'Logical system.img has an invalid Android API or Google image flavour')
    if selected['ndk']:
        payload = inputs / 'ndk-translation/payload'
        bridge = payload / 'system/lib64/libndk_translation.so'
        core.require(bridge.is_file() and file_hash(bridge, core) == EXPECTED_TRANSLATOR,
                     'Unsupported translator SHA256; require the reviewed Google API 34 r14 bridge')
        sums = manifest(inputs / 'ndk-translation/SHA256SUMS', core)
        actual_files = {name[len('ndk-translation/payload/'):] for name, (mode, *_) in tree.items()
                        if name.startswith('ndk-translation/payload/') and stat.S_ISREG(mode)}
        core.require(set(sums) == actual_files, 'Incomplete NDK payload or checksum inventory')
        for name, expected in sums.items():
            core.require(file_hash(payload / name, core) == expected, f'NDK payload checksum mismatch: {name}')
        check_arm64_dependencies(payload, core)
        ndk_source = core.read_small(inputs / 'ndk-translation/SOURCE.txt').decode('utf-8')
        core.require(f'Source SHA256: {verified["system.img"]}\n' in ndk_source,
                     'NDK extraction provenance does not match logical system.img')
    return dict(zip_name=source_name[1], zip_sha256=source_hash[1], package=IDENTITY,
                partitions=verified, manifest_sha256=file_hash(inputs / 'SOURCE-IMAGES.sha256', core),
                metadata_sha256={name: file_hash(inputs / name, core)
                                 for name in ('SOURCE.txt', 'SOURCE.properties', 'BUILD.prop')})


def check_arm64_dependencies(payload, core):
    """Refuse payloads whose guest libraries need a library that is absent.

    The payload manifest is written by the same extraction, so it cannot reveal
    files the extractor skipped (inputs from commit 5588b21 lacked libc++.so).
    """
    libraries = payload / 'system/lib64/arm64'
    for name in ('libc.so', 'libc++.so'):
        core.require((libraries / name).is_file(),
                     f'NDK payload lacks {name}; prepare the Google inputs again with the current helper')
    elves = sorted(libraries.glob('*.so')) + sorted((payload / 'system/bin/arm64').iterdir())
    missing = set()
    for elf in elves:
        text = command(['readelf', '-dW', elf], core, env={**os.environ, 'LC_ALL': 'C'}, capture=True).decode(errors='replace')
        for needed in re.findall(r'\(NEEDED\).*\[([^\]]+)\]', text):
            if needed != 'linux-vdso.so.1' and not (libraries / needed).is_file():
                missing.add(needed)
    core.require(not missing, 'NDK payload is missing ARM64 dependencies (' + ', '.join(sorted(missing)) +
                 '); prepare the Google inputs again with the current helper')


def check_write_paths(source, selected, core):
    paths = []
    if selected['ndk']:
        paths += ['system/lib64/arm64', 'system/bin/arm64', 'system/etc', 'system/build.prop', 'vendor/build.prop',
                  'vendor/odm/etc/build.prop']
    if selected['gapps']:
        paths += ['system/product/priv-app/PrebuiltGmsCore', 'system/product/priv-app/Phonesky',
                  'system/product/app/Chrome/lib/x86_64', 'system/product/app/TrichromeLibrary/lib/x86_64',
                  'system/product/etc/permissions', 'system/product/etc/sysconfig',
                  'system/product/etc/default-permissions', 'system/system_ext/priv-app/GoogleServicesFramework',
                  'system/system_ext/etc/permissions', 'system/etc/permissions']
    if selected['widevine']:
        paths += ['vendor/apex']
    for name in paths:
        relative = Path(core.ROOTFS + name)
        for item in (relative, *relative.parents):
            if str(item) != '.':
                core.require(not (source / item).is_symlink(), f'Injection destination has a symlink parent: {item}')


def preflight_components(source, inputs, selected, core, env=None):
    helpers = source / 'tools/customize'
    library = helpers / 'lib/google-services.sh'
    rootfs = source / core.ROOTFS
    if selected['ndk']:
        placeholder = source.parent / ('.lepton-ndk-check-' + uuid.uuid4().hex)
        command(['bash', helpers / 'internal/inject-ndk-translation.sh', '--check', '--rootfs', rootfs,
                 '--payload', inputs / 'ndk-translation/payload', '--output', placeholder], core, env)
    if selected['gapps']:
        jar = rootfs / 'system/framework/services.jar'
        core.require(jar.is_file() and not jar.is_symlink(), 'Base rootfs services.jar is missing or unsafe')
        try:
            shell_function(library, 'google_services_framework_check', [jar], core, env)
        except core.InvalidBundle as exc:
            raise core.InvalidBundle('Base services.jar lacks required Lepton GApps/VIEW modifications; '
                                     'use a compatible base bundle. Phase 3 cannot rebuild the framework.') from exc
        shell_function(library, 'google_services_check', [inputs / 'logical-partitions', 'true', 'true'], core, env)
    if selected['widevine']:
        shell_function(library, 'widevine_check', [inputs / 'logical-partitions'], core, env)


def verify_component_manifest(rootfs, path, core):
    for name, expected in manifest(path, core).items():
        file = rootfs / name
        core.require(file.resolve() == file and not file.is_symlink() and file.is_file() and file_hash(file, core) == expected,
                     f'Injected component validation failed: {name}')


def run(args, core):
    core.require(os.geteuid() != 0 and platform.system() == 'Linux' and platform.machine() == 'x86_64',
                 'Run as an unprivileged user on a Linux x86_64 PC')
    core.require(hasattr(ctypes.CDLL(None), 'renameat2'), 'glibc renameat2 is required for atomic stage publication')
    selected = {name: getattr(args, 'with_' + name) for name in ('ndk', 'gapps', 'widevine')}
    core.require(any(selected.values()), 'Select at least one of --with-ndk, --with-gapps or --with-widevine')
    source = safe_path(args.stage_dir, core)
    output = safe_path(args.output_stage, core, existing=False)
    output = core.destination_path(output)
    disjoint(source, output, core)
    google = safe_path(args.google_inputs or args.google_zip, core)
    core.require(source.is_dir() and (google.is_file() if args.google_zip else google.is_dir()),
                 'Source stage/prepared inputs must be directories; --google-zip must be a regular file')
    disjoint(source, google, core)
    disjoint(output, google, core)
    cache = None
    if args.save_google_inputs:
        core.require(args.google_zip is not None, '--save-google-inputs requires --google-zip')
        cache = core.destination_path(safe_path(args.save_google_inputs, core, existing=False))
        for path in (source, output, google):
            disjoint(cache, path, core)
    tools = {'bash', 'readelf', 'rsync', 'python3', 'sha256sum', 'realpath', 'find', 'grep', 'sort', 'mktemp', 'debugfs', 'dirname', 'mkdir', 'chmod', 'rm'}
    if args.google_zip:
        tools.update(('lpunpack', 'sfdisk', 'dd', 'unzip', 'debugfs', 'cut', 'mv', 'rm', 'mkdir', 'chmod', 'cat', 'basename'))
    if selected['gapps'] or selected['widevine'] or (args.google_zip and selected['ndk']):
        tools.add('xargs')
    if selected['gapps']:
        tools.add('cat')
    if selected['widevine']:
        tools.update(('unzip', 'mv'))
    if selected['ndk']:
        tools.update(('wc', 'cmp', 'cut', 'mv'))
        if args.google_zip:
            tools.update(('awk', 'sed'))
    for tool in sorted(tools):
        core.require(shutil.which(tool), f'Missing host command: {tool}; install {PACKAGES.get(tool, "coreutils/findutils/grep as appropriate")}')
    view = StageView(source, core)
    stage, metadata, _ = view.validate()
    check_write_paths(source, selected, core)
    helpers = source / 'tools/customize'
    flags = ['--with-' + name for name, enabled in selected.items() if enabled]
    # One stage/rootfs copy. Allow space for extracted component data as well.
    size = sum(info[1] for info in view.snapshot.values() if stat.S_ISREG(info[0]))
    extra = 0
    if args.google_zip:
        with zipfile.ZipFile(google) as archive:
            extra = 2 * archive.getinfo('x86_64/system.img').file_size
        placeholder = output.parent / ('.lepton-input-check-' + uuid.uuid4().hex)
        command(['bash', helpers / 'prepare-google-inputs.sh', '--check', '--zip', google,
                 '--output', placeholder, *flags], core)
    else:
        prepared_tree = inventory(google, core)
        if selected['ndk']:
            extra += sum(info[1] for name, info in prepared_tree.items()
                         if name.startswith('ndk-translation/payload/') and stat.S_ISREG(info[0]))
        # Partition sizes provide conservative bounds for APK/native-library
        # expansion and the flattened APEX, without reserving a second copy
        # of the complete prepared input cache.
        parts = {'system', 'product', 'system_ext'} if selected['gapps'] else set()
        if selected['widevine']:
            parts.add('vendor')
        extra += sum(prepared_tree.get('logical-partitions/' + part + '.img', (0, 0))[1] for part in parts)
    if cache and cache.parent.stat().st_dev != output.parent.stat().st_dev:
        core.require(shutil.disk_usage(cache.parent).free >= extra + 64 * 1024 * 1024,
                     'Insufficient disk space on the Google input cache filesystem')
        extra //= 2  # Cache preparation is on its own filesystem.
    needed = size + extra + max(64 * 1024 * 1024, size // 10)
    core.require(shutil.disk_usage(output.parent).free >= needed,
                 f'Insufficient disk space: need at least {needed // (1024 * 1024) + 1} MiB free')
    zip_snapshot = google.stat() if args.google_zip else None
    work = None
    input_work = None
    try:
        inputs = google
        if args.google_zip:
            input_work = Path(tempfile.mkdtemp(prefix='.lepton-inject-', dir=cache.parent if cache else output.parent))
            os.chown(input_work, -1, os.getgid())
            inputs = input_work / 'google-inputs'
            command(['bash', helpers / 'prepare-google-inputs.sh', '--zip', google, '--output', inputs, *flags], core)
        google_identity = validate_inputs(inputs, selected, core)
        preflight_components(source, inputs, selected, core)
        if args.check:
            print('PASS: injection preflight; source/output unchanged' +
                  (' (ZIP checked by disposable temporary extraction)' if args.google_zip else ''))
            return
        if cache:
            core.publish(inputs, cache)
            inputs = cache
            print(f'PASS: validated Google inputs retained at {cache}', flush=True)
        work = Path(tempfile.mkdtemp(prefix='.lepton-inject-', dir=output.parent))
        os.chown(work, -1, os.getgid())
        env = {**os.environ, 'TMPDIR': str(work)}
        target = work / 'stage'
        target.mkdir(mode=0o700)
        excludes = ['--exclude=/STAGE.json']
        if selected['ndk']:
            excludes.append('--exclude=/compat_tool/images/rootfs/')
        command(['rsync', '-a', '--no-owner', '--no-group', *excludes, '--', str(source) + '/', str(target) + '/'], core, env)
        rootfs = target / core.ROOTFS
        library = helpers / 'lib/google-services.sh'
        if selected['ndk']:
            ndk = work / 'ndk-output'
            command(['bash', helpers / 'internal/inject-ndk-translation.sh', '--execute', '--rootfs', source / core.ROOTFS,
                     '--payload', inputs / 'ndk-translation/payload', '--output', ndk], core, env)
            rootfs.parent.mkdir(parents=True, exist_ok=True)
            ndk.joinpath('rootfs').rename(rootfs)
            provenance = target / 'compat_tool/ndk-provenance'
            ndk.rename(provenance)
            for file in ('SHA256SUMS', 'SOURCE.txt', 'GOOGLE-BRIDGE-PROPERTIES.txt'):
                shutil.copy2(inputs / 'ndk-translation' / file, provenance / file)
            verify_component_manifest(rootfs, provenance / 'SHA256SUMS', core)
        if selected['gapps']:
            shell_function(library, 'google_services_inject', [rootfs, inputs / 'logical-partitions', 'true', 'true',
                           target / 'compat_tool/provenance/gapps'], core, env)
            verify_component_manifest(rootfs, target / 'compat_tool/provenance/gapps/SHA256SUMS', core)
            core.require(file_hash(rootfs / 'system/framework/services.jar', core) ==
                         file_hash(source / core.ROOTFS / 'system/framework/services.jar', core), 'services.jar changed unexpectedly')
        if selected['widevine']:
            shell_function(library, 'widevine_inject', [rootfs, inputs / 'logical-partitions',
                           target / 'compat_tool/provenance/widevine'], core, env)
            verify_component_manifest(rootfs, target / 'compat_tool/provenance/widevine/SHA256SUMS', core)
        for name in (core.SHIM, core.EXTRACTOR, core.INOTIFY, core.INOTIFY_LIB, 'tools/bin/inotifywait',
                     core.ROOTFS + 'vendor/lib64/hw/vulkan.radeon.so'):
            core.require(file_hash(target / name, core) == file_hash(source / name, core), f'Precompiled/base asset changed: {name}')
        for part in ('system', 'vendor'):
            name = part + '/build.prop'
            props = core.properties((rootfs / name).read_bytes())
            expected = 'libndk_translation.so' if selected['ndk'] else '0'
            if part == 'system':
                core.require(props.get('ro.dalvik.vm.native.bridge') == expected, 'Result has incorrect native bridge property')
                if selected['ndk']:
                    core.require(props.get('ro.dalvik.vm.isa.arm64') == 'x86_64' and
                                 props.get('ro.ndk_translation.flags') == 'accurate-sigsegv', 'Incorrect NDK runtime properties')
            if not selected['ndk']:
                core.require((rootfs / name).read_bytes() == (source / core.ROOTFS / name).read_bytes(), 'Base ABI properties changed unexpectedly')
            else:
                prefix = f'ro.{part}.product.cpu.'
                core.require(props.get(prefix + 'abilist') == 'x86_64,arm64-v8a' and
                             props.get(prefix + 'abilist64') == 'x86_64,arm64-v8a' and props.get(prefix + 'abilist32') == '',
                             f'Incorrect result ABI properties in {name}')
        odm = rootfs / 'vendor/odm/etc/build.prop'
        if selected['ndk'] and odm.is_file():
            props = core.properties(odm.read_bytes())
            core.require(props.get('ro.odm.product.cpu.abilist') == 'x86_64,arm64-v8a' and
                         props.get('ro.odm.product.cpu.abilist64') == 'x86_64,arm64-v8a' and
                         props.get('ro.odm.product.cpu.abilist32') == '', 'Incorrect result ODM ABI properties')
        provenance = target / 'compat_tool/provenance/google-inputs'
        provenance.mkdir(parents=True)
        for file in ('SOURCE.txt', 'SOURCE.properties', 'BUILD.prop', 'SOURCE-IMAGES.sha256'):
            shutil.copy2(inputs / file, provenance / file)
        stage.update(state='customized', components=selected, source_bundle=metadata,
                     google_source=google_identity, sysbake_required=True)
        (target / 'STAGE.json').write_text(json.dumps(stage, indent=2) + '\n')
        core.require(inventory(source, core) == view.snapshot, 'Source stage changed during injection; refusing publication')
        core.require(validate_inputs(inputs, selected, core) == google_identity, 'Google inputs changed during injection')
        if zip_snapshot is not None:
            now = google.stat()
            core.require((now.st_ino, now.st_size, now.st_mtime_ns, now.st_ctime_ns) ==
                         (zip_snapshot.st_ino, zip_snapshot.st_size, zip_snapshot.st_mtime_ns, zip_snapshot.st_ctime_ns),
                         'Google ZIP changed during injection; refusing publication')
        core.publish(target, output)
        print(f'PASS: customized stage: {output}\nFresh sysbake and packaging are still required (Phase 4).')
        if selected['widevine']:
            print('Widevine L3 software DRM only; no service certification or hardware DRM is implied.')
    finally:
        if work is not None:
            core.cleanup(work)
        if input_work is not None:
            core.cleanup(input_work)


def main(argv, core):
    parser = argparse.ArgumentParser(prog='lepton-customize inject', description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--check', action='store_true')
    mode.add_argument('--execute', action='store_true')
    parser.add_argument('--stage-dir', required=True, type=Path, help='clean Stage 2 prepared source')
    parser.add_argument('--output-stage', required=True, type=Path, help='new independent output stage')
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument('--google-zip', type=Path)
    inputs.add_argument('--google-inputs', type=Path)
    parser.add_argument('--save-google-inputs', type=Path, help='with a ZIP, retain validated prepared inputs at this new path')
    for component in ('ndk', 'gapps', 'widevine'):
        parser.add_argument('--with-' + component, action='store_true')
    args = parser.parse_args(argv)
    return run(args, core)
