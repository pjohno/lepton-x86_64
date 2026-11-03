#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Exercise generated properties, preserving the default media behavior.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
LEPTON_DIR="$ROOT/compat_tool/liblepton"  # normally set by liblepton.sh
source "$ROOT/compat_tool/liblepton/properties.sh"
prefix() { printf '%s' "$work"; }
print() { printf '%s' "$*"; }
println() { printf '%s\n' "$*"; }
steamos_devmode_enabled() { return 1; }
is_app() { return 1; }
is_app_baked() { return 1; }
is_sysbake() { return 0; }
android_sdk_version() { printf '%s' "$probe_sdk"; }
export LEPTON_CONTEXT='test'
export LEPTON_FORCE_SOFTWARE=false
probe_sdk=34
unset LEPTON_CODEC2 LEPTON_FORWARD_WEB_INTENTS
setup_props
grep -qx 'persist.lepton.forward_web_intents=false' "$work/lepton.prop"
grep -qx 'debug.stagefright.ccodec=0' "$work/lepton.prop"
! grep -q 'c2-poolmask' "$work/lepton.prop"
# Valve upstream: shared-library replacements by GNU build ID.
grep -qx 'ro.lepton.soreplace.25f52dbf904d24e2=/data/steamvr/runtime/bin/androidarm64/libopenxr_loader.so' "$work/lepton.prop"
LEPTON_CODEC2=true LEPTON_FORWARD_WEB_INTENTS=true setup_props
grep -qx 'persist.lepton.forward_web_intents=true' "$work/lepton.prop"
grep -qx 'debug.stagefright.ccodec=4' "$work/lepton.prop"
grep -qx 'debug.stagefright.c2-poolmask=786432' "$work/lepton.prop"
probe_sdk=30
LEPTON_CODEC2=true setup_props
grep -qx 'debug.stagefright.ccodec=0' "$work/lepton.prop"
printf 'PASS: Android URL routing default, explicit Steam opt-in, codec opt-in and legacy SDK properties, so replacements\n'
