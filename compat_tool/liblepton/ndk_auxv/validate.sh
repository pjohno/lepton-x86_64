#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Structural checks for our dependency-free Android shim; never executes it.
set -Eeuo pipefail
export LC_ALL=C
[[ $# == 1 ]] || { echo "Usage: bash $0 SHIM.so" >&2; exit 2; }
fail() { echo "ERROR: missing or invalid Android x86_64 NDK shim: $1" >&2; exit 1; }
[[ -f "$1" && -s "$1" ]] || fail "$1"
command -v readelf >/dev/null || { echo 'ERROR: readelf required to validate NDK shim' >&2; exit 1; }
headers="$(readelf -hW -lW -dW -VW -- "$1")" || fail "$1"
grep -Eq 'Class: +ELF64' <<< "$headers" &&
grep -Eq "Data: +2's complement, little endian" <<< "$headers" &&
grep -Eq 'Type: +DYN \(Shared object file\)' <<< "$headers" &&
grep -Eq 'Machine: +Advanced Micro Devices X86-64' <<< "$headers" &&
grep -Eq '^ +LOAD ' <<< "$headers" &&
grep -Fq 'Library soname: [liblepton_ndk_auxv.so]' <<< "$headers" || fail "$1"
# -nostdlib deliberately leaves Bionic symbols to the Android loader. Host
# libc dependencies/version requirements or an executable interpreter are wrong.
if grep -Eq '\(NEEDED\)|GLIBC_|^ +INTERP ' <<< "$headers"; then fail "$1"; fi
