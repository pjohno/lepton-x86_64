#!/bin/bash


function is_sysbake() { [[ "${LEPTON_CONTEXT}" == "sysbake" ]]; }
function is_system_baked() {
    local PACKAGES_XML_PATH="${BAKED_SYSTEM_DATA_DIR}/system/packages.xml"

    # System is not baked if `packages.xml` does not exist
    [[ -f "${PACKAGES_XML_PATH}" ]]
}


# Run startup once, to get a `data` directory that we can overlay in the future
BAKED_SYSTEM_DATA_DIR="${LEPTON_DIR}/../sysbake"
function update_baked_system_data()
{
    if [[ ! -f "$(data_mount_path)/system/packages.xml" ]]; then
        die "ERROR! System data bake failed!"
    fi

    # Ethernet IP settings are per-container; never bake the build host address.
    rm -f "$(data_mount_path)/misc/ethernet/ipconfig.txt" \
          "$(data_mount_path)/misc/apexdata/com.android.tethering/misc/ethernet/ipconfig.txt"
    cp -Ra "$(data_mount_path)" "${BAKED_SYSTEM_DATA_DIR}"
}

function wipe_baked_system_data()
{
    # Might not exist yet:
    chmod 700 -R "${BAKED_SYSTEM_DATA_DIR}" 2>/dev/null || true
    # Now wipe it
    rm -rf "${BAKED_SYSTEM_DATA_DIR}"
}

# These are the files we track for app pre-baking
function get_baked_app_data_dir()
{
    local CONTEXT="${1:-${LEPTON_CONTEXT}}"
    local DATA_PATH="${2:-${STEAM_COMPAT_DATA_PATH:-}}"

    if [[ -n "${DATA_PATH:-}" ]]; then
        print "${DATA_PATH:-}/baked"
    else
        print "${LEPTON_DATA_DIR}/${CONTEXT}/baked"
    fi
}

function update_baked_app_metadata()
{
    if is_steamlaunch; then
        # Save out app metadata
        save_app_metadata
    fi
}

# The package manager writes `packages.xml` before we move the app into its
# overlay. An interrupted install can leave this file behind even if native
# libraries are missing. Write this marker only after installation is complete.
function app_install_complete_path()
{
    print "$(get_baked_app_data_dir)/app_install_complete"
}

function mark_app_install_complete()
{
    touch "$(app_install_complete_path)"
}

function clear_app_install_complete()
{
    rm -f "$(app_install_complete_path)"
}

# Validate the complete code set, including split-only changes. Legacy app_hash
# metadata may identify either base.apk or an APKM archive. Neither is proof of
# the full installed set: compare each selected APK and reject extra/missing code.
function app_apk_set_matches()
{
    local INSTALLED="$(get_baked_app_data_dir)/app_overlay" BASE SRC NAME RESULT
    local -A SOURCES=()
    BASE="$(get_apk_path)"
    SOURCES[base.apk]="$BASE"
    [[ -d "$INSTALLED" && -r "$INSTALLED" && -x "$INSTALLED" && ! -L "$INSTALLED" ]] || {
        println "Installation invalid: installed APK directory missing, unreadable or a symlink" >&2; return 1;
    }
    if [[ -n "${LEPTON_APKM_DIR:-}" ]]; then
        [[ "$BASE" == "$LEPTON_APKM_DIR/base.apk" && -r "$LEPTON_APKM_DIR" && -x "$LEPTON_APKM_DIR" && ! -L "$LEPTON_APKM_DIR" ]] || {
            println "Installation invalid: selected APKM cache cannot be validated" >&2; return 1;
        }
        for SRC in "$LEPTON_APKM_DIR"/*.apk; do
            [[ -e "$SRC" || -L "$SRC" ]] || continue
            NAME="${SRC##*/}"
            [[ "$NAME" =~ ^[A-Za-z0-9_.-]+\.apk$ ]] || {
                println "Installation invalid: unrecognised split APK filename" >&2; return 1;
            }
            SOURCES["$NAME"]="$SRC"
        done
    fi
    for NAME in "${!SOURCES[@]}"; do
        SRC="${SOURCES[$NAME]}"
        [[ -f "$SRC" && -s "$SRC" && -r "$SRC" && ! -L "$SRC" &&
           -f "$INSTALLED/$NAME" && -s "$INSTALLED/$NAME" && -r "$INSTALLED/$NAME" && ! -L "$INSTALLED/$NAME" ]] || {
            println "Installation invalid: selected/installed APK missing, unreadable or a symlink: $NAME" >&2; return 1;
        }
        RESULT=0
        cmp -s -- "$SRC" "$INSTALLED/$NAME" || RESULT=$?
        case "$RESULT" in
            0) ;;
            1) println "APK content changed: yes; installed $NAME differs from selected source; safe update required" >&2; return 1 ;;
            *) println "Installation invalid: could not compare APK contents: $NAME" >&2; return 1 ;;
        esac
    done
    for SRC in "$INSTALLED"/*.apk; do
        [[ -e "$SRC" || -L "$SRC" ]] || continue
        NAME="${SRC##*/}"
        # Single-APK installs overlay the game's folder, then rename/delete its
        # APKs; deletions leave overlay whiteouts (0:0 character devices). They
        # hide files from Android and are not code. Selected names were already
        # required to be regular files above, so a whiteout never replaces code.
        if [[ -c "$SRC" && ! -L "$SRC" && "$(stat -c '%t:%T' -- "$SRC" 2>/dev/null)" == 0:0 ]]; then
            continue
        fi
        [[ -n "${SOURCES[$NAME]+present}" ]] || {
            println "APK split set changed: installed APK absent from selected source: $NAME" >&2; return 1;
        }
    done
}

function is_app_baked()
{
    is_app || return 1
    local DIR="$(get_baked_app_data_dir)" CODE STORED_HASH CURRENT_HASH
    [[ -f "$(app_install_complete_path)" ]] || { println "Installation marker present: no" >&2; return 1; }
    println "Installation marker present: yes" >&2
    grep -qaF -- "$(get_app_id)" "$DIR/data_overlay/system/packages.xml" 2>/dev/null || {
        println "Installation invalid: package absent or packages.xml unreadable/unrecognised" >&2; return 1;
    }
    CODE="$(extract_app_mount_dir)"
    [[ -n "$CODE" && -s "$DIR/app_overlay/base.apk" ]] || {
        println "Installation invalid: installed codePath or app_overlay/base.apk missing" >&2; return 1;
    }
    app_apk_set_matches || return 1
    CURRENT_HASH="$(extract_app_hash)" || return 1
    [[ "$CURRENT_HASH" =~ ^[0-9a-f]{64}$ ]] || { println "Installation invalid: cannot hash selected base APK" >&2; return 1; }
    STORED_HASH="$(cat "$DIR/app_hash" 2>/dev/null || true)"
    if [[ "$STORED_HASH" != "$CURRENT_HASH" ]]; then
        println "Stored APK hash missing/stale or uses a different scheme; complete installed APK set verified unchanged; metadata retained" >&2
    fi
    println "APK content changed: no; complete installed APK set matches selected source" >&2
    println "Installation validation passed; launcher release identity does not invalidate profile" >&2
}

# Existing profiles are validated before mounting. Android 14 renames
# packages.xml aside while rewriting it during boot, so a post-start re-check
# must never turn a validated profile into an install over existing data.
function app_install_needed()
{
    [[ "${APP_REUSE_VALIDATED:-}" != yes ]] || return 1
    ! is_app_baked
}

function autobake()
{
    if ! is_system_baked; then
        echo "Lepton system is not baked. Please verify the files of Lepton in Settings->Properties->Installed files"
        exit 1
    else
        # The depot does not contain xattrs, so we need to restore them from a
        # file. We perform this always in case someone interrupted the process.
        pushd "${LEPTON_DIR}"/.. >/dev/null || exit
        setfattr --restore "${LEPTON_DIR}"/../sysbake.xattrs
        popd >/dev/null || exit
    fi
}
