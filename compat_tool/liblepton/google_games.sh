#!/bin/bash
# SPDX-License-Identifier: MIT
# x86_64 port: Google games and split-APK bundles on the normal Steam launch
# path (Valve's flow, kept app data in the game's compatdata):
#   - .apkm bundles: unpacked once into compatdata, installed with
#     adb install-multiple; Valve's post-install hook keeps all splits;
#   - LEPTON_GOOGLE_SIGNIN=true: install the game but open the Play Store
#     (sign-in is kept with the game's data);
#   - games marked as needing Google services refuse non-GApps tools.

PLAY_STORE_PACKAGE="com.android.vending"

function lepton_rootfs_dir() { print "${LEPTON_TEST_ROOTFS:-${LEPTON_DIR}/../images/rootfs}"; }

function rootfs_has_google_services()
{
    [[ -f "$(lepton_rootfs_dir)/system/product/priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk" ]]
}

function rootfs_has_arm_translation()
{
    [[ -f "$(lepton_rootfs_dir)/system/lib64/libndk_translation.so" ]]
}

function is_apkm_path() { [[ "${1,,}" == *.apkm ]]; }

function google_signin_mode() { [[ "${LEPTON_GOOGLE_SIGNIN:-false}" == true ]]; }

# Package whose process decides when the session ends (process observer).
function lepton_observed_app_id()
{
    if google_signin_mode; then print "${PLAY_STORE_PACKAGE}"; else print "$(get_app_id)"; fi
}

# The command the app-launch rc runs once the app is installed.
function lepton_launch_commands()
{
    if google_signin_mode; then
        print "am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p ${PLAY_STORE_PACKAGE}"
    else
        print "$(run_app_commands "$(get_app_id)" "$(get_app_activity)" no-force-stop)"
    fi
}

# Unpack an .apkm into ${STEAM_COMPAT_DATA_PATH}/lepton-apkm/<hash>/ (base.apk,
# the chosen ABI split, language/density/feature splits). Kept between
# launches so the installed app counts as unchanged; a new bundle replaces it.
function prepare_apkm()
{
    local APKM="$1" KEY CACHE_ROOT CACHE ABI
    [[ -n "${STEAM_COMPAT_DATA_PATH:-}" ]] || die "Split-APK bundles (.apkm) need a Steam launch (STEAM_COMPAT_DATA_PATH)."
    LEPTON_APKM_HASH="$(sha256sum "${APKM}" | cut -d' ' -f1)" || die "Cannot read ${APKM}"
    export LEPTON_APKM_HASH
    KEY="${LEPTON_APKM_HASH:0:16}"
    CACHE_ROOT="${STEAM_COMPAT_DATA_PATH}/lepton-apkm"
    CACHE="${CACHE_ROOT}/${KEY}"
    if [[ ! -f "${CACHE}/base.apk" ]]; then
        mkdir -p -- "${CACHE_ROOT}"
        python3 - "${APKM}" "${CACHE}.tmp" <<'PY' || die "Cannot unpack ${APKM} (expected an APKMirror-style bundle with base.apk)."
import re, shutil, sys, zipfile
from pathlib import Path
ABI = {"arm64_v8a", "armeabi_v7a", "x86", "x86_64"}
with zipfile.ZipFile(sys.argv[1]) as bundle:
    apks = [e for e in bundle.infolist() if e.filename.endswith(".apk")]
    names = {e.filename for e in apks}
    if "base.apk" not in names or len(names) != len(apks):
        raise SystemExit("needs exactly one base.apk")
    if any(not re.fullmatch(r"[A-Za-z0-9_.-]+\.apk", n) for n in names):
        raise SystemExit("unsafe APK names")
    abi_of = lambda n: n[len("split_config."):-4] if n.startswith("split_config.") and n[len("split_config."):-4] in ABI else None
    present = {abi_of(n) for n in names} - {None}
    # Native x86_64 first; otherwise ARM64 (needs ARM translation).
    chosen = "x86_64" if "x86_64" in present else ("arm64_v8a" if "arm64_v8a" in present else None)
    out = Path(sys.argv[2]); out.mkdir()
    for entry in apks:
        abi = abi_of(entry.filename)
        if abi is not None and abi != chosen:
            continue
        with bundle.open(entry) as src, (out / entry.filename).open("xb") as dst:
            shutil.copyfileobj(src, dst)
    (out / "lepton-abi").write_text((chosen or "none").replace("_v8a", "-v8a") + "\n")
PY
        mv -T -- "${CACHE}.tmp" "${CACHE}"
    fi
    ABI="$(cat "${CACHE}/lepton-abi" 2>/dev/null || echo none)"
    if [[ "${ABI}" == arm64-v8a ]] && ! rootfs_has_arm_translation; then
        die "This game only contains ARM64 code. Select a Lepton tool with ARM translation (an NDK bundle) in the game's Properties > Compatibility."
    fi
    export LEPTON_APKM_DIR="${CACHE}"
    export APP_PATH="${CACHE}/base.apk"
}

# The split APKs to install next to base.apk (one per line).
function apkm_split_paths()
{
    [[ -n "${LEPTON_APKM_DIR:-}" ]] || return 0
    compgen -G "${LEPTON_APKM_DIR}/*.apk" | grep -v '/base\.apk$' || true
}
