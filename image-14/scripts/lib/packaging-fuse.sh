#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Shared host prerequisites and unprivileged FUSE checks for rootfs packaging.
lepton_packaging_requirements() {
    local tool implementation missing=0 device="${LEPTON_FUSE_DEVICE:-/dev/fuse}"
    for tool in simg2img sqfs2tar tar unzip fuse2fs rsync \
                mountpoint mkfs.ext4 truncate timeout python3 sha256sum mktemp \
                cp mv rm chmod mkdir readlink dirname head cut sed cmp find; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            printf '[FAIL] Missing rootfs packaging executable: %s\n' "$tool" >&2
            missing=1
        fi
    done
    implementation="$(lepton_fuse_implementation)"
    for tool in fusermount fusermount3; do
        if command -v "$tool" >/dev/null 2>&1; then
            continue
        fi
        if [[ "$implementation" == unknown || ( "$implementation" == 2 && "$tool" == fusermount ) ||
              ( "$implementation" == 3 && "$tool" == fusermount3 ) ]]; then
            printf '[FAIL] Missing rootfs packaging executable: %s (fuse2fs implementation: %s)\n' "$tool" "$implementation" >&2
            missing=1
        else
            printf '[INFO] %s is absent; installed fuse2fs uses FUSE %s and does not require it.\n' "$tool" "$implementation"
        fi
    done
    if ((missing)); then
        printf '%s\n' \
          '[INFO] Fedora: sudo dnf install fuse fuse-libs fuse3 e2fsprogs fuse2fs squashfs-tools-ng android-tools rsync unzip util-linux coreutils python3' \
          '[INFO] Ubuntu: install fuse2fs e2fsprogs squashfs-tools-ng android-sdk-libsparse-utils rsync unzip util-linux coreutils python3, plus fuse (fusermount for FUSE 2) OR fuse3 (fusermount3 for FUSE 3), matching the installed fuse2fs implementation.' \
          '[INFO] Ensure /usr/sbin and /sbin are in PATH for host tools such as mkfs.ext4 and fuse2fs.' \
          '[INFO] FUSE 2 and FUSE 3 helpers are distinct; do not symlink one to the other. Some Ubuntu releases make fuse/fuse3 conflict; do not replace a desktop dependency blindly. If detection is unknown, both helpers are required until the mount implementation can be established.' >&2
        return 1
    fi
    if [[ ! -c "$device" ]]; then
        printf '[FAIL] FUSE device missing or not a character device: %s. Enable FUSE in the host/WSL2 kernel and expose /dev/fuse to this environment.\n' "$device" >&2
        return 1
    fi
    if [[ ! -r "$device" || ! -w "$device" ]]; then
        printf '[FAIL] FUSE device inaccessible: %s. Grant this user read/write access through the host device policy; containers need /dev/fuse passed through.\n' "$device" >&2
        return 1
    fi
}

# Never remove a temporary tree containing mounts, even after a failed unmount.
lepton_remove_packaging_tree() {
    local tree="$1" status=0
    python3 - "$tree" <<'PY' || status=$?
import os, re, sys
try:
    root = os.path.realpath(sys.argv[1])
    with open('/proc/self/mountinfo') as mounts:
        for line in mounts:
            path = re.sub(r'\\([0-7]{3})', lambda m: chr(int(m[1], 8)), line.split()[4])
            if path == root or path.startswith(root + '/'):
                sys.exit(1)
except OSError:
    sys.exit(2)
PY
    if ((status)); then
        printf '[WARN] Retaining packaging directory (mounted or mount state unavailable): %s\n' "$tree" >&2
        return 1
    fi
    # Only call for temporary directories created by this invocation.
    chmod -R u+rwX -- "$tree" 2>/dev/null || true
    rm -rf -- "$tree"
}

# Detect the actual helper dependency without assuming FUSE versions are
# interchangeable. Unknown/static implementations conservatively need both.
lepton_fuse_implementation() {
    local libraries=''
    if command -v ldd >/dev/null 2>&1 && command -v fuse2fs >/dev/null 2>&1; then
        libraries="$(ldd "$(command -v fuse2fs)" 2>/dev/null || true)"
    fi
    case "$libraries" in
        *libfuse3.so*) printf '3\n' ;;
        *libfuse.so.2*) printf '2\n' ;;
        *) printf 'unknown\n' ;;
    esac
}

lepton_fuse_unmount_helper() {
    if [[ "$(lepton_fuse_implementation)" == 3 ]]; then
        printf '%s\n' fusermount3
    else
        printf '%s\n' fusermount
    fi
}

lepton_fuse_smoke_test() (
    set -Eeuo pipefail
    lepton_packaging_requirements || exit 1
    local work candidate='' rc helper
    helper="$(lepton_fuse_unmount_helper)"
    work="$(mktemp -d "${TMPDIR:-/tmp}/lepton-fuse-check.XXXXXXXX")" || return 1
    cleanup_fuse_smoke() {
        rc=$?
        trap - EXIT
        if [[ -n "$candidate" ]] && mountpoint -q -- "$candidate"; then
            if ! timeout 15 "$helper" -u "$candidate" || mountpoint -q -- "$candidate"; then
                printf '[FAIL] FUSE smoke-test cleanup could not unmount %s; directory retained.\n' "$candidate" >&2
                exit 1
            fi
        fi
        lepton_remove_packaging_tree "$work" || rc=1
        exit "$rc"
    }
    trap cleanup_fuse_smoke EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if ! truncate -s 8M "$work/probe.ext4" || ! mkfs.ext4 -q -F "$work/probe.ext4"; then
        printf '[FAIL] Could not create the disposable ext4 FUSE probe; check mkfs.ext4, temporary-directory permissions and free space.\n' >&2
        exit 1
    fi
    mkdir "$work/mount" || exit 1
    candidate="$work/mount"
    if ! timeout 20 fuse2fs -o ro,fakeroot "$work/probe.ext4" "$candidate" || ! mountpoint -q -- "$candidate"; then
        printf '[FAIL] FUSE mount permission/helper smoke test failed. Check fuse2fs output, fusermount, /etc/fuse.conf and host/WSL/container FUSE support.\n' >&2
        exit 1
    fi
    if ! timeout 15 "$helper" -u "$candidate" || mountpoint -q -- "$candidate"; then
        printf '[FAIL] FUSE smoke-test unmount failed: %s. Check FUSE 2 helper permissions and processes using the mount.\n' "$candidate" >&2
        exit 1
    fi
    candidate=''
    printf '[PASS] Unprivileged fuse2fs mount/unmount smoke test\n'
)
