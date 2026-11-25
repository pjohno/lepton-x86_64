#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Container stage for fresh/resumed preparation and reset synchronization.
set -Eeuo pipefail
cd "${1:-/workspace/output}"
manifests=${2:-/workspace/android_vendor_valve/manifest_scripts/manifests-34}
[[ -f /run/.containerenv || -f /.dockerenv ]] || { echo 'Not in container'; exit 1; }
if [[ ! -f .repo/manifest.xml ]]; then
  echo "[$(date -u +%H:%M:%SZ)] [INFO] Initializing Android 14 manifest (android-14.0.0_r75)"
  repo init -u https://android.googlesource.com/platform/manifest \
    -b android-14.0.0_r75 -g default,-trusty --git-lfs
fi
echo "[$(date -u +%H:%M:%SZ)] [INFO] Installing current local manifests"
mkdir -p .repo/local_manifests
for source in "$manifests"/*.xml; do
  destination=".repo/local_manifests/${source##*/}"
  if [[ -e "$destination" && ! -e .lepton-clean14-state/reset.started ]]; then
    cmp -s "$source" "$destination" || { echo "Changed local manifest: $destination (use --reset)"; exit 1; }
  else
    cp "$source" "$destination"
  fi
done
echo "[$(date -u +%H:%M:%SZ)] [START] Synchronizing Android repositories (4 jobs)"
sync_args=(-j4)
if [[ -e .lepton-clean14-state/reset.started ]]; then
  # Reset explicitly discards source edits, including local branches.
  sync_args+=(-d)
fi
.repo/repo/repo sync "${sync_args[@]}"
.repo/repo/repo manifest -r -o .lepton-resolved-manifest.xml
echo "[$(date -u +%H:%M:%SZ)] [PASS] Android sources synchronized; resolved manifest updated"
