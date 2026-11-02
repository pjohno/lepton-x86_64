#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
for name in test test-open; do
    "${CC:-cc}" -Wall -Wextra -Werror "$HERE/$name.c" -o "$work/$name"
    "$work/$name"
done
bash "$HERE/test-runtime.sh"
