#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Keep disposable rootless-Podman storage free of inherited POSIX ACLs.

A workspace whose parent has default ACLs (for example
``default:user:otheruser:r-x``) passes them to every new subdirectory. Inside a
rootless user namespace those entries name an unmapped UID; crun and
fuse-overlayfs then fail with EINVAL ("creating /etc/mtab symlink: invalid
argument", "get xattr system.posix_acl_access ... Invalid argument").

``private DIR...`` makes freshly created, empty, user-owned directories private
(mode 0700, no setgid, no access or default ACL). It never recurses and refuses
any other directory. ``scan-acls DIR`` reports, read-only, entries below DIR
that carry ACLs. Only the Python standard library is used: getfacl/setfacl
need not be installed, and filesystems without ACL/xattr support are accepted.
"""
import errno
import os
import stat
import sys

ACL_XATTRS = ('system.posix_acl_access', 'system.posix_acl_default')
# getxattr errors meaning "this filesystem cannot hold an ACL here".
UNSUPPORTED = {errno.ENOTSUP, errno.EOPNOTSUPP}


class PrivateDirError(OSError):
    pass


def _acl_names(target, follow_symlinks=True):
    """ACL xattrs present on a path or fd. Unsupported filesystems have none."""
    found = []
    for name in ACL_XATTRS:
        try:
            os.getxattr(target, name, follow_symlinks=follow_symlinks)
        except OSError as exc:
            if exc.errno == errno.ENODATA or exc.errno in UNSUPPORTED:
                continue
            raise
        found.append(name)
    return found


def make_private(path):
    """Make a newly created empty directory private to the current user."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as exc:
        raise PrivateDirError(exc.errno, f'Cannot open private storage directory {path}: {exc.strerror}') from exc
    try:
        info = os.fstat(fd)
        if info.st_uid != os.geteuid():
            raise PrivateDirError(errno.EPERM, f'Refusing to modify {path}: not owned by the current user')
        if os.listdir(fd):
            raise PrivateDirError(errno.ENOTEMPTY, f'Refusing to modify {path}: not a new, empty directory')
        for name in _acl_names(fd):
            try:
                os.removexattr(fd, name)
            except OSError as exc:
                if exc.errno != errno.ENODATA:
                    raise PrivateDirError(exc.errno, f'Cannot remove inherited {name} from {path}: {exc.strerror}. '
                                          'Container storage here would inherit the parent ACLs; '
                                          'use a parent directory without default ACLs.') from exc
        # An explicit chmod(2) mode also clears an inherited setgid bit.
        os.fchmod(fd, 0o700)
        mode = stat.S_IMODE(os.fstat(fd).st_mode)
        remaining = _acl_names(fd)
        if mode != 0o700 or remaining:
            raise PrivateDirError(errno.EPERM, f'{path} is not private after cleanup '
                                  f'(mode {mode:04o}, ACLs: {", ".join(remaining) or "none"})')
    except PrivateDirError:
        raise
    except OSError as exc:
        raise PrivateDirError(exc.errno, f'Cannot make {path} private: {exc.strerror}') from exc
    finally:
        os.close(fd)


def find_acls(root):
    """Read-only: paths at or below root that carry access or default ACLs."""
    def check(path):
        try:
            return bool(_acl_names(path, follow_symlinks=False))
        except OSError as exc:
            raise PrivateDirError(exc.errno, f'Cannot read ACLs of {path}: {exc.strerror}') from exc

    def walk_error(exc):
        raise PrivateDirError(exc.errno, f'Cannot scan {exc.filename}: {exc.strerror}')

    found = [root] if check(root) else []
    for parent, dirs, files in os.walk(root, onerror=walk_error):
        for name in dirs + files:
            path = os.path.join(parent, name)
            # Symlinks cannot hold ACLs; never follow them out of the tree.
            if not os.path.islink(path) and check(path):
                found.append(path)
    return found


def main(argv):
    if len(argv) >= 2 and argv[0] == 'private':
        try:
            for path in argv[1:]:
                make_private(path)
        except PrivateDirError as exc:
            print(f'[FAIL] {exc.strerror}', file=sys.stderr)
            return 1
        return 0
    if len(argv) == 2 and argv[0] == 'scan-acls':
        try:
            found = find_acls(argv[1])
        except PrivateDirError as exc:
            print(f'[FAIL] {exc.strerror}', file=sys.stderr)
            return 2
        for path in found[:5]:
            print(path)
        if len(found) > 5:
            print(f'... and {len(found) - 5} more')
        return 1 if found else 0
    print('Usage: private_storage.py private DIR... | scan-acls DIR', file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
