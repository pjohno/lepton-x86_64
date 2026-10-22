#!/usr/bin/env bash
set -Eeuo pipefail
export LD_PRELOAD=

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMAND=test-0200
LEPTON_CONTEXT="test-0200-$$"
NAME="lepton-$LEPTON_CONTEXT"
PODMAN_CMDLINE=()

exec {LEPTON_LOCKFD}>/tmp/lepton.lock
flock --timeout 10 "$LEPTON_LOCKFD"

source "$HERE/liblepton/liblepton.sh"
create_prefix

finish() {
    result=$?
    trap - EXIT
    podman rm -f "$NAME" >/dev/null 2>&1 || true
    remove_prefix >/dev/null 2>&1 || true
    if ((result == 0)); then
        echo "PASS: container start, stop and cleanup"
    else
        echo "FAIL: test 0200 (exit $result)"
    fi
    exit "$result"
}
trap finish EXIT

echo "TEST 0200: Container lifecycle without Android"

# A static x86_64 Linux probe: checks /system/build.prop,
# handles SIGTERM, and otherwise waits for shutdown.
cat > "$LEPTON_PREFIX/probe.S" <<'ASM'
.global _start
.section .text
_start:
    mov $13, %eax
    mov $15, %edi
    lea action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js failed

    mov $2, %eax
    lea path(%rip), %rdi
    xor %esi, %esi
    syscall
    test %rax, %rax
    js failed

    mov %rax, %rdi
    mov $3, %eax
    syscall

waiting:
    mov $34, %eax
    syscall
    jmp waiting

onterm:
    mov $60, %eax
    xor %edi, %edi
    syscall

failed:
    mov $60, %eax
    mov $42, %edi
    syscall

.section .rodata
path: .asciz "/system/build.prop"
.section .data
.align 8
action:
    .quad onterm, 0x04000000, sigreturn, 0
.section .text
sigreturn:
    mov $15, %rax
    syscall
ASM

cc -nostdlib -static -no-pie \
    -o "$LEPTON_PREFIX/probe" "$LEPTON_PREFIX/probe.S"


# Isolated test data: do not depend on or modify the real sysbake.
BAKED_SYSTEM_DATA_DIR="$LEPTON_PREFIX/test-data"
mkdir -p "$BAKED_SYSTEM_DATA_DIR"

setup_container

ROOTFS="$(readlink -f "$HERE/images/rootfs")"

podman run -d \
    --read-only \
    --env-host=false \
    --init=false \
    --name "$NAME" \
    --userns=keep-id:uid=0,gid=0 \
    --user 0:0 \
    --group-add keep-groups \
    "${PODMAN_CMDLINE[@]}" \
    --volume "$LEPTON_PREFIX/probe:/lepton-probe:ro,Z" \
    --rootfs "$ROOTFS:O" \
    /lepton-probe

sleep 2

state="$(podman inspect -f '{{.State.Status}}' "$NAME")"
echo "Container state: $state"

if [[ "$state" != running ]]; then
    podman logs "$NAME"
    exit 1
fi

echo "PASS: container running; Android rootfs accessible"

podman stop --time 3 "$NAME" >/dev/null
exit_code="$(podman inspect -f '{{.State.ExitCode}}' "$NAME")"
echo "Shutdown exit code: $exit_code"
[[ "$exit_code" == 0 ]]

podman rm "$NAME" >/dev/null
! podman container exists "$NAME"
