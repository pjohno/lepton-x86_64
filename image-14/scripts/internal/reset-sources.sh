#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Container stage; called only after host lock recovery and reset.started.
set -Eeuo pipefail
cd "${1:-/workspace/output}"
[[ -f .repo/manifest.xml && -f build/envsetup.sh ]] || { echo 'Missing synced AOSP checkout'; exit 1; }
# Projects whose .git link was overwritten (older vendoring copied a
# submodule's .git file over hardware/waydroid): check them out again from
# the local .repo store, without any download.
broken=()
while read -r path; do
  git -C "$path" rev-parse --git-dir >/dev/null 2>&1 || broken+=("$path")
done < .repo/project.list
if (( ${#broken[@]} )); then
  echo "Repairing git checkouts: ${broken[*]}"
  rm -rf -- "${broken[@]}"
  .repo/repo/repo sync -q -l -d "${broken[@]}"
fi
# Every project: abandon interrupted patch series, return to the manifest
# revision and delete untracked files (vendored copies, patch-added files).
# REPO_* variables are expanded by repo's per-project shell.
# shellcheck disable=SC2016
.repo/repo/repo forall -e -c '
  lock=$(git rev-parse --path-format=absolute --git-path index.lock) || exit 1
  failed() {
    echo "RESET FAILED: project=$REPO_PATH operation=$1 revision=$REPO_LREV lock=$lock" >&2
    echo "Inspect the Git error above; rerun prepare-x86_64.sh --reset after resolving it." >&2
    exit 1
  }
  am_state=$(git rev-parse --git-path rebase-apply) || failed "resolve am state"
  if test -d "$am_state"; then
    git am --abort || failed "git am --abort"
  fi
  git reset --hard "$REPO_LREV" || failed "git reset --hard"
  git clean -fdx || failed "git clean -fdx"
'
# Vendored Valve tree (not a repo project); recreated by the vendoring stage.
rm -rf -- vendor/extra
# shellcheck disable=SC2016
dirty=$(.repo/repo/repo forall -e -c '
  status=$(git status --porcelain) || exit 1
  test -z "$status" || { echo "Still modified: $REPO_PATH" >&2; exit 1; }
')
[[ -z "$dirty" ]] || { echo "Projects still modified after reset:"; echo "$dirty"; exit 1; }
echo '[PASS] All Android projects match the pinned manifest'
# Installed build outputs may hold files from the previous sources.
set +u
# shellcheck disable=SC1091
source build/envsetup.sh >/dev/null
lunch aosp_lepton_x86_64-ap2a-userdebug >/dev/null
m installclean
echo '[PASS] Installed build outputs removed (intermediates kept for speed)'
