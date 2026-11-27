#!/bin/bash

LEPTON_IMAGE_DIR=$(realpath "${LEPTON_DIR}/../images")
source "${LEPTON_DIR}/ndk_auxv/runtime.sh"

PODMAN_CMDLINE=()
function podman_cmdline()
{
    PODMAN_CMDLINE+=("$@")
}
function podman_mount_entry_optional()
{
    local SRC="${1}"
    local DST="${2}"
    local OPT="${3}"
    if [[ -e "${SRC}" ]]; then
        podman_cmdline --mount "type=bind,source=${SRC},destination=${DST},${OPT}"
    fi
}
function podman_mount_entry()
{
    local SRC="${1}"
    local DST="${2}"
    local OPT="${3}"
    podman_cmdline --mount "type=bind,source=${SRC},destination=${DST},${OPT}"
}
function podman_mount_entry_type()
{
    local TYPE="${1}"
    local DST="${2}"
    local OPT="${3}"
    podman_cmdline --mount "type=${TYPE},destination=${DST},${OPT}"
}

BASE_APK=base.apk

function android_sdk_version()
{
    cat "${LEPTON_TEST_ROOTFS:-${LEPTON_DIR}/../images/rootfs}/system/build.prop" | grep ro.build.version.sdk= | sed "s/.*=//g"
}

# Replace only a recognised symlink. A real directory/file is user data.
function safe_storage_link()
{
    local TARGET="$1" LINK="$2"
    if [[ -L "$LINK" ]]; then
        [[ "$(readlink -- "$LINK")" == "$TARGET" ]] && return 0
        println "ERROR: unexpected storage link retained: $LINK; inspect it before changing storage mapping" >&2
        lepton_tell_player_shared "a link in its Android shared storage was not made by this Lepton tool" \
            "Remove the link (only the link, not the folder it points to) and launch again." \
            "$LINK links to $(readlink -- "$LINK"), not $TARGET"
        return 1
    elif [[ -e "$LINK" ]]; then
        println "ERROR: real storage path retained: $LINK; back it up and resolve the mapping manually" >&2
        lepton_tell_player_shared "a file or folder is in the way in its Android shared storage" \
            "Back it up and move it out of the way, then launch again." "$LINK"
        return 1
    fi
    ln -s -- "$TARGET" "$LINK"
}

# Default shared folders, as "<name in /storage/emulated/0>:<XDG user-dir
# key>:<folder in HOME when user-dirs.dirs doesn't say>".
LEPTON_SHARED_FOLDER_DEFAULTS=(Documents:DOCUMENTS:Documents Download:DOWNLOAD:Downloads
                               Movies:VIDEOS:Videos Music:MUSIC:Music Pictures:PICTURES:Pictures)

# Every shared folder is mounted at <this>/<Name> and linked as <Name> in
# shared storage. A path under the container's own /lepton is never hidden by
# Android's /mnt, so folders on /mnt drives work. A link pointing at exactly
# <this>/<its own name> is Lepton's: that is how a folder no longer shared is
# recognised.
LEPTON_SHARED_GUEST_ROOT=/lepton/shared

# Before that, Lepton linked these names to these HOME folders, mounted at
# their host path. Such a link is also Lepton's, and is replaced by the
# current kind when the folder is shared.
LEPTON_SHARED_LEGACY_LINKS=(Documents:Documents Download:Downloads Movies:Videos)

# Shared-storage names that can't be used, lower case: Android's own folder
# (app data, OBB).
LEPTON_SHARED_RESERVED_NAMES=(android)

# Print XDG user directory KEY (DOCUMENTS, MUSIC, ...) from user-dirs.dirs, or
# HOME/FALLBACK when the file doesn't set it. The file is shell syntax written
# by xdg-user-dirs-update; it is parsed here, never sourced, and only
# XDG_<KEY>_DIR="$HOME/..." or "/..." without other $, ` or \ is accepted.
# The last valid line wins, as in a shell.
function lepton_xdg_user_dir()
{
    local KEY="$1" FALLBACK="$2" LINE VALUE RESULT="${HOME}/$2"
    local FILE="${XDG_CONFIG_HOME:-${HOME}/.config}/user-dirs.dirs"
    if [[ -f "${FILE}" && -r "${FILE}" ]]; then
        while IFS= read -r LINE || [[ -n "${LINE}" ]]; do
            [[ "${LINE}" =~ ^[[:space:]]*XDG_${KEY}_DIR=\"(.*)\"[[:space:]]*$ ]] || continue
            VALUE="${BASH_REMATCH[1]}"
            if [[ "${VALUE}" == '$HOME' || "${VALUE}" == '$HOME/'* ]]; then
                VALUE="${HOME}${VALUE:5}"
            elif [[ "${VALUE}" != /* ]]; then
                continue
            fi
            [[ "${VALUE#"${HOME}"}" != *[\$\`\\]* ]] || continue
            RESULT="${VALUE}"
        done < "${FILE}"
    fi
    while [[ "${RESULT}" == ?*/ ]]; do RESULT="${RESULT%/}"; done
    print "${RESULT}"
}

# Parse LEPTON_SHARED_FOLDERS into SHARED_FOLDER_ENTRIES, one per folder to
# share: "NAME<TAB>HOST<TAB>GUEST<TAB>MODE<TAB>STATE<TAB>KIND". HOST is mounted
# at GUEST (MODE rw or ro) and NAME in shared storage links to GUEST. KIND is
# default or custom. STATE is ok; missing for a folder that is not there now
# (a drive not plugged in), which is reported and left alone; or absent, the
# same without a report, for a default folder that wasn't asked for by name.
#
# The option is a comma-separated list. Each item is one of:
#   Documents | Downloads | Videos | Music | Pictures
#                                    the default folders, from the XDG user
#                                    directories (Android names Download and
#                                    Movies too; any case)
#   /abs/path  or  ~/path            any host folder, shown under its final
#                                    name; may contain spaces
#   Name=/abs/path                   the same, shown as Name
#   none                             nothing (also an empty value)
# and may end in :ro (read-only) or :rw. Default folders may also be separated
# by spaces (the original syntax); paths must be separated by commas. A path
# may use a default folder's name (Music=/mnt/Media/Music), in place of it.
# Unset shares the five default folders, read-write.
#
# Everything is checked before anything is changed: returns 1 with every
# problem reported, and SHARED_FOLDER_ENTRIES empty. A default folder that
# wasn't asked for by name and can't be shared is reported and skipped.
function lepton_shared_folder_entries()
{
    SHARED_FOLDER_ENTRIES=()
    local DEFAULTS=() ERRORS=() NAMES=() SOURCES=() CUSTOM_ITEMS=() CUSTOM_BARE=()
    local PROTECTED=() HOME_REAL SELECTED=false
    HOME_REAL="$(realpath -m -- "${HOME}")"
    lepton_shared_protected_paths
    if [[ "${LEPTON_SHARED_FOLDERS:-}" == *[[:cntrl:]]* ]]; then
        ERRORS+=("it contains a control character (such as a line break)")
    elif [[ -v LEPTON_SHARED_FOLDERS ]]; then
        # An empty value is the same as none.
        [[ -n "$(lepton_trim "${LEPTON_SHARED_FOLDERS}")" ]] || SELECTED=true
        local PART PARTS=() WORD WORDS=() MODE KNOWN
        IFS=',' read -ra PARTS <<< "${LEPTON_SHARED_FOLDERS}"
        for PART in "${PARTS[@]}"; do
            PART="$(lepton_trim "${PART}")"
            [[ -n "${PART}" ]] || continue
            if [[ "${PART}" == [/~]* || "${PART}" == *=* ]]; then
                CUSTOM_ITEMS+=("${PART}"); CUSTOM_BARE+=(false)
                continue
            fi
            read -ra WORDS <<< "${PART}"
            # Several words are default folder names separated by spaces (the
            # original syntax) only if every one is; otherwise the item is one
            # folder name with spaces in it, such as My Comics.
            if ((${#WORDS[@]} > 1)); then
                KNOWN=true
                for WORD in "${WORDS[@]}"; do
                    lepton_shared_default_word "${WORD}" > /dev/null || KNOWN=false
                done
                if [[ "${KNOWN}" == false && " ${PART}" == *" "[/~]* ]]; then
                    ERRORS+=("'${PART}': separate folder paths from other items with commas")
                    continue
                fi
                if [[ "${KNOWN}" == false ]]; then
                    CUSTOM_ITEMS+=("${PART}"); CUSTOM_BARE+=(true)
                    continue
                fi
            fi
            for WORD in "${WORDS[@]}"; do
                if [[ "${WORD,,}" == none ]]; then
                    SELECTED=true
                elif [[ "${WORD,,}" == none:r[ow] ]]; then
                    ERRORS+=("'${WORD}': none can't be read-only or read-write")
                elif KNOWN="$(lepton_shared_default_word "${WORD}")"; then
                    SELECTED=true
                    DEFAULTS+=("${KNOWN}:named")
                else
                    # A folder in your home, by its name alone.
                    CUSTOM_ITEMS+=("${WORD}"); CUSTOM_BARE+=(true)
                fi
            done
        done
    fi
    # Naming no default folder (and not none) keeps all five; the folders
    # given are shared as well. A folder given under a default folder's name
    # (Music=/mnt/Music, ~/Music), or the same host folder, replaces it.
    if [[ "${SELECTED}" == false ]]; then
        local PAIR
        for PAIR in "${LEPTON_SHARED_FOLDER_DEFAULTS[@]}"; do
            DEFAULTS+=("${PAIR%%:*}:rw:implicit")
        done
    fi
    local CUSTOM_NAMES=() CUSTOM_REALS=()
    lepton_shared_custom_names
    lepton_shared_check_defaults
    lepton_shared_check_custom

    if ((${#ERRORS[@]})); then
        local ERROR
        for ERROR in "${ERRORS[@]}"; do
            println "ERROR: LEPTON_SHARED_FOLDERS: ${ERROR}" >&2
        done
        lepton_tell_player_shared "its LEPTON_SHARED_FOLDERS launch option has a problem" \
            "Fix the option in the game's Properties > General > Launch Options. Value: ${LEPTON_SHARED_FOLDERS:-}" \
            "${ERRORS[@]}"
        SHARED_FOLDER_ENTRIES=()
        return 1
    fi
}

# Print "Name:mode" for a default folder name (any case, Android names too,
# optional :ro or :rw), or return 1.
function lepton_shared_default_word()
{
    local WORD="$1" MODE=rw
    case "${WORD,,}" in
        *:ro) MODE=ro; WORD="${WORD:0:${#WORD}-3}" ;;
        *:rw) WORD="${WORD:0:${#WORD}-3}" ;;
    esac
    case "${WORD,,}" in
        documents) print "Documents:${MODE}" ;;
        download|downloads) print "Download:${MODE}" ;;
        movies|videos) print "Movies:${MODE}" ;;
        music) print "Music:${MODE}" ;;
        pictures) print "Pictures:${MODE}" ;;
        *) return 1 ;;
    esac
}

# Tell the player (the launch popup) why shared folders stopped the launch:
# SUMMARY, the problems (one per line, at most 6), then ADVICE. The log has
# the same lines.
function lepton_tell_player_shared()
{
    local SUMMARY="$1" ADVICE="$2" GAME LINES=() PROBLEM
    shift 2
    GAME="$(lepton_session_name 2>/dev/null)" || GAME=""
    for PROBLEM in "${@:1:6}"; do LINES+=("• ${PROBLEM}"); done
    (($# <= 6)) || LINES+=("• ... and $(($# - 6)) more (see the log)")
    lepton_tell_player "${GAME:-The game} can't start: ${SUMMARY}. Nothing was changed.
" "${LINES[@]}" "
${ADVICE}"
}

# lepton_shared_folder_entries helper: the shared-storage names (lower case)
# and real host folders of the folder items, so that a default folder they
# replace is left out rather than reported as a clash. Errors in the items
# are left to lepton_shared_check_custom.
function lepton_shared_custom_names()
{
    local I ITEM PATH_GIVEN NAME
    for I in "${!CUSTOM_ITEMS[@]}"; do
        ITEM="${CUSTOM_ITEMS[I]}"
        case "${ITEM,,}" in *:ro|*:rw) ITEM="${ITEM:0:${#ITEM}-3}" ;; esac
        NAME="" PATH_GIVEN="${ITEM}"
        if [[ "${CUSTOM_BARE[I]}" == true ]]; then
            NAME="${ITEM}" PATH_GIVEN="${HOME}/${ITEM}"
        elif [[ "${ITEM}" != [/~]* ]]; then
            NAME="$(lepton_trim "${ITEM%%=*}")"
            PATH_GIVEN="$(lepton_trim "${ITEM#*=}")"
        fi
        [[ "${PATH_GIVEN}" != "~/"* ]] || PATH_GIVEN="${HOME}${PATH_GIVEN:1}"
        while [[ "${PATH_GIVEN}" == ?*/ ]]; do PATH_GIVEN="${PATH_GIVEN%/}"; done
        [[ -n "${NAME}" ]] || NAME="${PATH_GIVEN##*/}"
        CUSTOM_NAMES+=("${NAME,,}")
        [[ ! -e "${PATH_GIVEN}" ]] || CUSTOM_REALS+=("$(realpath -e -- "${PATH_GIVEN}" 2>/dev/null)")
    done
}

function lepton_trim()
{
    local S="$1"
    S="${S#"${S%%[![:space:]]*}"}"
    print "${S%"${S##*[![:space:]]}"}"
}

function lepton_array_has()
{
    local WANT="$1" ITEM
    shift
    for ITEM in "$@"; do [[ "${ITEM}" == "${WANT}" ]] && return 0; done
    return 1
}

# lepton_shared_folder_entries helper: Lepton's own data, which no shared
# folder may hold or be inside. Sets the caller's PROTECTED.
function lepton_shared_protected_paths()
{
    local P
    for P in "${LEPTON_LIBRARY_CONFIGURED:-}" "${LEPTON_LIBRARY_ROOT:-}" "${XDG_CONFIG_HOME:-${HOME}/.config}/lepton-x86_64" "${STEAM_COMPAT_DATA_PATH:-}" "$(get_baked_app_data_dir 2>/dev/null)" \
             "${LEPTON_DIR:+${LEPTON_DIR}/..}" "${LEPTON_DATA_DIR:-}" \
             "${XDG_DATA_HOME:-${HOME}/.local/share}/lepton-compat-data"; do
        [[ -n "${P}" ]] && PROTECTED+=("$(realpath -m -- "${P}")")
    done
}

# lepton_shared_folder_entries helper: resolve the default folders in
# DEFAULTS ("Name:mode:named|implicit") through the XDG user directories, and
# add them to SHARED_FOLDER_ENTRIES. A problem with a folder asked for by name
# is an error; with one that wasn't, a warning, and the folder is not shared.
function lepton_shared_check_defaults()
{
    local DEFAULT NAME MODE HOW PAIR KEY FALLBACK HOST REAL FIRST_ERROR
    for DEFAULT in "${DEFAULTS[@]}"; do
        IFS=: read -r NAME MODE HOW <<< "${DEFAULT}"
        for PAIR in "${LEPTON_SHARED_FOLDER_DEFAULTS[@]}"; do
            [[ "${PAIR%%:*}" == "${NAME}" ]] && IFS=: read -r _ KEY FALLBACK <<< "${PAIR}"
        done
        if lepton_array_has "${NAME,,}" "${NAMES[@]}"; then
            ERRORS+=("${NAME} is listed twice")
            continue
        fi
        HOST="$(lepton_xdg_user_dir "${KEY}" "${FALLBACK}")"
        if [[ "${HOW}" == implicit ]]; then
            # Replaced by a folder given under its name, or by the same folder
            # given under another (~/Downloads is shown as Downloads).
            lepton_array_has "${NAME,,}" "${CUSTOM_NAMES[@]}" && continue
            [[ -e "${HOST}" ]] && lepton_array_has "$(realpath -m -- "${HOST}")" "${CUSTOM_REALS[@]}" && continue
        fi
        NAMES+=("${NAME,,}")
        if [[ ! -e "${HOST}" ]]; then
            # Never created on the host; a relocated one may be on a drive
            # that isn't plugged in. Its link is kept.
            local STATE=absent
            [[ "${HOW}" == implicit ]] || STATE=missing
            SHARED_FOLDER_ENTRIES+=("${NAME}"$'\t'"${HOST}"$'\t'"${LEPTON_SHARED_GUEST_ROOT}/${NAME}"$'\t'"${MODE}"$'\t'"${STATE}"$'\t'default)
            continue
        fi
        FIRST_ERROR=${#ERRORS[@]}
        REAL="$(realpath -m -- "${HOST}")"
        if [[ "${REAL}" == "${HOME_REAL}" ]]; then
            # XDG's way of saying a folder is turned off.
            ERRORS+=("${NAME}: your ${NAME} folder is set to your home folder (XDG_${KEY}_DIR in user-dirs.dirs), which is never shared. Set it to a folder, or give one, as ${NAME}=/path")
        elif lepton_shared_folder_ok "${HOST}" "${NAME}"; then
            if lepton_array_has "${REAL}" "${SOURCES[@]}"; then
                ERRORS+=("${NAME}: ${REAL} is already shared by another item")
            else
                SOURCES+=("${REAL}")
                SHARED_FOLDER_ENTRIES+=("${NAME}"$'\t'"${REAL}"$'\t'"${LEPTON_SHARED_GUEST_ROOT}/${NAME}"$'\t'"${MODE}"$'\t'ok$'\t'default)
            fi
        fi
        if [[ "${HOW}" == implicit ]] && ((${#ERRORS[@]} > FIRST_ERROR)); then
            local ERROR
            for ERROR in "${ERRORS[@]:FIRST_ERROR}"; do
                println "WARNING: shared folder ${ERROR}; not shared" >&2
            done
            ERRORS=("${ERRORS[@]:0:FIRST_ERROR}")
        fi
    done
}

# lepton_shared_folder_entries helper: validate the path items queued in
# CUSTOM_ITEMS ("[Name=]path[:ro]"), after the default folders, and add them
# to SHARED_FOLDER_ENTRIES, or to ERRORS. Uses the caller's NAMES and SOURCES
# (lower-case names and real host folders already taken).
function lepton_shared_check_custom()
{
    local I ITEM PATH_GIVEN NAME MODE REAL
    for I in "${!CUSTOM_ITEMS[@]}"; do
        ITEM="${CUSTOM_ITEMS[I]}"
        NAME="" MODE=rw PATH_GIVEN="${ITEM}"
        case "${PATH_GIVEN,,}" in
            *:ro) MODE=ro; PATH_GIVEN="${PATH_GIVEN:0:${#PATH_GIVEN}-3}" ;;
            *:rw) PATH_GIVEN="${PATH_GIVEN:0:${#PATH_GIVEN}-3}" ;;
        esac
        if [[ "${CUSTOM_BARE[I]}" == true ]]; then
            # A name alone is a folder in your home, which must be there:
            # unlike a path, it is not a drive that may be unplugged, and a
            # misspelt default folder name ends up here.
            NAME="${PATH_GIVEN}"
            if [[ "${NAME}" == */* ]]; then
                ERRORS+=("'${ITEM}': a folder path starts with / or ~/ (~/${NAME} for one in your home folder)")
                continue
            fi
            lepton_shared_name_ok "${NAME}" "${ITEM}" || continue
            if [[ ! -d "${HOME}/${NAME}" ]]; then
                ERRORS+=("'${ITEM}': there is no folder ${NAME} in your home folder (${HOME}/${NAME}). Use Documents, Downloads, Videos, Music, Pictures, a folder in your home such as Books, or a full path such as /run/media/${USER:-deck}/<drive>/${NAME}")
                continue
            fi
            PATH_GIVEN="${HOME}/${NAME}"
        elif [[ "${PATH_GIVEN}" != [/~]* ]]; then
            NAME="$(lepton_trim "${PATH_GIVEN%%=*}")"
            PATH_GIVEN="$(lepton_trim "${PATH_GIVEN#*=}")"
            if [[ "${PATH_GIVEN}" != [/~]* ]]; then
                ERRORS+=("'${ITEM}': after ${NAME}= give a folder path starting with / or ~/")
                continue
            fi
        fi
        if [[ "${PATH_GIVEN}" == "~" || "${PATH_GIVEN}" == "~/"* ]]; then
            PATH_GIVEN="${HOME}${PATH_GIVEN:1}"
        elif [[ "${PATH_GIVEN}" == "~"* ]]; then
            ERRORS+=("'${ITEM}': write ~/ for your home folder, or the full path")
            continue
        fi
        while [[ "${PATH_GIVEN}" == ?*/ ]]; do PATH_GIVEN="${PATH_GIVEN%/}"; done
        if [[ "${PATH_GIVEN}" == / ]]; then
            ERRORS+=("'${ITEM}': share a folder inside /, not the whole of it")
            continue
        fi
        if [[ "/${PATH_GIVEN}/" == *"/./"* || "/${PATH_GIVEN}/" == *"/../"* || "${PATH_GIVEN}" == *//* ]]; then
            ERRORS+=("'${ITEM}': use a plain folder path, without . or .. parts")
            continue
        fi
        if [[ "${PATH_GIVEN}" == *'"'* ]]; then
            ERRORS+=("'${ITEM}': folder paths with \" in them can't be shared")
            continue
        fi
        [[ -n "${NAME}" ]] || NAME="${PATH_GIVEN##*/}"
        lepton_shared_name_ok "${NAME}" "${ITEM}" || continue
        if lepton_array_has "${NAME,,}" "${NAMES[@]}"; then
            ERRORS+=("'${ITEM}': ${NAME} is already used by another item; give one a different name, as Name=/path")
            continue
        fi
        NAMES+=("${NAME,,}")

        if [[ ! -e "${PATH_GIVEN}" ]]; then
            # Not there now (or a link to a drive that is not): not an error,
            # so a game still starts without its drive. Nothing is changed.
            SHARED_FOLDER_ENTRIES+=("${NAME}"$'\t'"${PATH_GIVEN}"$'\t'"${LEPTON_SHARED_GUEST_ROOT}/${NAME}"$'\t'"${MODE}"$'\t'missing$'\t'custom)
            continue
        fi
        lepton_shared_folder_ok "${PATH_GIVEN}" "'${ITEM}'" || continue
        REAL="$(realpath -e -- "${PATH_GIVEN}")"
        if lepton_array_has "${REAL}" "${SOURCES[@]}"; then
            ERRORS+=("'${ITEM}': ${REAL} is already shared by another item")
            continue
        fi
        SOURCES+=("${REAL}")
        SHARED_FOLDER_ENTRIES+=("${NAME}"$'\t'"${REAL}"$'\t'"${LEPTON_SHARED_GUEST_ROOT}/${NAME}"$'\t'"${MODE}"$'\t'ok$'\t'custom)
    done
}

# NAME must be usable as one folder in Android's shared storage, and not one
# Android keeps. Android refuses FAT-invalid characters.
function lepton_shared_name_ok()
{
    local NAME="$1" ITEM="$2"
    if [[ -z "${NAME}" || "${NAME}" == [.\ -]* || "${NAME}" == *' ' ||
          "${NAME}" == *[[:cntrl:]/\\:*?\"\<\>\|,]* || ${#NAME} -gt 64 ]]; then
        ERRORS+=("'${ITEM}': '${NAME}' can't be a shared-storage folder name. Give a plain name, as Name=/path (no / \\ : * ? \" < > |, not starting with . or -, at most 64 characters)")
        return 1
    fi
    if [[ -n "${LEPTON_LIBRARY_CONFIGURED:-}${LEPTON_LIBRARY_ROOT:-}" && "${NAME,,}" == "container storage" ]]; then
        ERRORS+=("'${ITEM}': Container Storage is reserved by the Android Library")
        return 1
    fi
    if lepton_array_has "${NAME,,}" "${LEPTON_SHARED_RESERVED_NAMES[@]}"; then
        ERRORS+=("'${ITEM}': ${NAME} is kept for Android's app data; give it another name, as Books=/path")
        return 1
    fi
}

# HOST (an existing path, which may be a symlink) must be a folder you can
# open whose real location may be shared. LABEL starts each error. Only HOST
# itself is resolved: links inside the folder are not followed or mounted.
# Inside the container they resolve against the container's own files.
function lepton_shared_folder_ok()
{
    local HOST="$1" LABEL="$2" REAL
    if [[ ! -d "${HOST}" ]]; then
        ERRORS+=("${LABEL}: ${HOST} is not a folder")
        return 1
    fi
    if [[ ! -r "${HOST}" || ! -x "${HOST}" ]]; then
        ERRORS+=("${LABEL}: you don't have permission to open ${HOST}")
        return 1
    fi
    REAL="$(realpath -e -- "${HOST}")"
    if [[ "${REAL}" == *[[:cntrl:]\",]* ]]; then
        ERRORS+=("${LABEL}: ${HOST} leads to ${REAL}, whose name can't be shared")
        return 1
    fi
    lepton_shared_host_ok "${REAL}" "${LABEL}"
}

# Real folders that must not be shared: the whole system, home or a drive
# list; system and settings folders; and Lepton's own data. The caller's
# HOME_REAL and PROTECTED are used when set.
function lepton_shared_host_ok()
{
    local REAL="$1" LABEL="$2" TOP="${1#/}" HOME_R="${HOME_REAL:-$(realpath -m -- "${HOME}")}" P
    TOP="/${TOP%%/*}"
    if [[ "${REAL}" == / || "${REAL}" == "${HOME_R}" || "${HOME_R}" == "${REAL}/"* ]]; then
        ERRORS+=("${LABEL}: ${REAL} holds your whole home folder; share a folder inside it")
        return 1
    fi
    case "${REAL}" in
        /mnt|/media|/run/media|/var/mnt|/home|/var/home|/run/media/*)
            if [[ "${REAL}" != /run/media/*/* ]]; then
                ERRORS+=("${LABEL}: ${REAL} lists whole drives or homes; share a folder on one"); return 1
            fi ;;
    esac
    case "${TOP}" in
        /proc|/sys|/dev|/boot|/efi|/etc|/usr|/bin|/sbin|/lib|/lib32|/lib64|/root)
            ERRORS+=("${LABEL}: ${REAL} is a system folder"); return 1 ;;
        /run)
            if [[ "${REAL}" != /run/media/?*/?* ]]; then
                ERRORS+=("${LABEL}: ${REAL} is a system folder; drives are under /run/media/<user>/<drive>"); return 1
            fi ;;
        /var)
            if [[ "${REAL}" != /var/home/?* && "${REAL}" != /var/mnt/?* ]]; then
                ERRORS+=("${LABEL}: ${REAL} is a system folder"); return 1
            fi ;;
    esac
    if [[ "${REAL}" == "${HOME_R}/."* ]]; then
        ERRORS+=("${LABEL}: ${REAL} is inside a hidden folder of your home, which holds settings and keys"); return 1
    fi
    for P in "${PROTECTED[@]}"; do
        if [[ "${REAL}" == "${P}" || "${REAL}" == "${P}/"* || "${P}" == "${REAL}/"* ]]; then
            ERRORS+=("${LABEL}: ${REAL} holds Lepton's own data (${P}); share a folder that doesn't")
            return 1
        fi
    done
}

# Remove DIR if it is an empty folder Android made. MediaProvider's own marker
# (.thumbnails/.database_uuid and nothing else) counts as empty; any other
# content, including real thumbnails, keeps the folder.
function remove_empty_android_folder()
{
    local DIR="$1"
    [[ -d "${DIR}" && ! -L "${DIR}" ]] || return 1
    if [[ -d "${DIR}/.thumbnails" && ! -L "${DIR}/.thumbnails" &&
          -f "${DIR}/.thumbnails/.database_uuid" && ! -L "${DIR}/.thumbnails/.database_uuid" &&
          "$(ls -A -- "${DIR}")" == .thumbnails && "$(ls -A -- "${DIR}/.thumbnails")" == .database_uuid ]]; then
        rm -f -- "${DIR}/.thumbnails/.database_uuid" && rmdir -- "${DIR}/.thumbnails" || return 1
    fi
    rmdir -- "${DIR}" 2>/dev/null
}

# Share HOST as shared-storage folder LINK: mount it at GUEST with MODE and
# point LINK at GUEST. Never moves or deletes user data: only an empty real
# folder, such as one Android created while sharing was off, is replaced by
# the link. A folder with files in it stays private to Android and the launch
# continues.
function share_host_folder()
{
    local HOST="$1" LINK="$2" GUEST="$3" MODE="$4"
    if [[ -d "${LINK}" && ! -L "${LINK}" ]] && ! remove_empty_android_folder "${LINK}"; then
        println "Shared folder ${LINK##*/} not linked to ${HOST}: Android's own ${LINK##*/} folder has files, so it is kept. Move them out to share ${HOST}." >&2
        return 0
    fi
    safe_storage_link "${GUEST}" "${LINK}" || die "Shared storage preserved; launch stopped"
    podman_mount_entry "${HOST}" "${GUEST}" "${MODE}"
}

# Is LINK (in shared storage) a link Lepton made for a shared folder?
function lepton_shared_link_is_ours()
{
    local LINK="$1" NAME="${1##*/}" TARGET PAIR
    [[ -L "${LINK}" ]] || return 1
    TARGET="$(readlink -- "${LINK}")"
    [[ "${TARGET}" == "${LEPTON_SHARED_GUEST_ROOT}/${NAME}" ]] && return 0
    for PAIR in "${LEPTON_SHARED_LEGACY_LINKS[@]}"; do
        [[ "${NAME}" == "${PAIR%%:*}" && "${TARGET}" == "${HOME}/${PAIR#*:}" ]] && return 0
    done
    return 1
}

# Android's init mounts tmpfs over these, hiding host paths mounted there.
LEPTON_SHARED_HIDDEN_ROOTS=(/mnt /tmp)

function lepton_android_hides()
{
    local ROOT
    for ROOT in "${LEPTON_SHARED_HIDDEN_ROOTS[@]}"; do
        [[ "$1" != "$ROOT"/* ]] || return 0
    done
    return 1
}

# Bring shared storage folder TARGET (the profile's /data/media/0) in line
# with LEPTON_SHARED_FOLDERS. Checks the whole option, and every link it would
# change, before changing anything.
function setup_shared_folders()
{
    local TARGET="$1" ENTRY NAME HOST GUEST MODE STATE KIND LINK
    local SHARED_FOLDER_ENTRIES=() ACTIVE=() PROBLEMS=() DEFAULT_NAMES=() PAIR
    lepton_shared_folder_entries || die "Launch stopped: fix the LEPTON_SHARED_FOLDERS launch option. Shared folders unchanged."
    # Container Storage, independent of the optional folders above.
    local LIBRARY_ENTRY
    LIBRARY_ENTRY="$(lepton_library_storage_entry)"
    [[ -z "${LIBRARY_ENTRY}" ]] || SHARED_FOLDER_ENTRIES+=("${LIBRARY_ENTRY}")
    for PAIR in "${LEPTON_SHARED_FOLDER_DEFAULTS[@]}"; do DEFAULT_NAMES+=("${PAIR%%:*}"); done

    # A link that is not Lepton's, where a folder is to be shared, would stop
    # the launch halfway; find all of them first.
    for ENTRY in "${SHARED_FOLDER_ENTRIES[@]}"; do
        IFS=$'\t' read -r NAME HOST GUEST MODE STATE KIND <<< "${ENTRY}"
        ACTIVE+=("${NAME}")
        LINK="${TARGET}/${NAME}"
        if [[ "${STATE}" == ok && -L "${LINK}" ]] && ! lepton_shared_link_is_ours "${LINK}"; then
            PROBLEMS+=("${LINK} links to $(readlink -- "${LINK}"), not ${GUEST}")
        fi
    done
    if ((${#PROBLEMS[@]})); then
        local PROBLEM
        for PROBLEM in "${PROBLEMS[@]}"; do
            println "ERROR: unexpected storage link retained: ${PROBLEM}; inspect it before changing storage mapping" >&2
        done
        lepton_tell_player_shared "a link in its Android shared storage was not made by this Lepton tool" \
            "A newer Lepton tool may have made it: select that tool again, or remove the link (only the link, not the folder it points to) and launch again." \
            "${PROBLEMS[@]}"
        die "Shared storage preserved; launch stopped"
    fi

    # Lepton's links for folders no longer shared.
    for LINK in "${TARGET}"/*; do
        [[ -L "${LINK}" ]] || continue
        NAME="${LINK##*/}"
        lepton_array_has "${NAME}" "${ACTIVE[@]}" && continue
        if lepton_shared_link_is_ours "${LINK}"; then
            rm -f -- "${LINK}"
            println "Shared folder off: ${NAME} is no longer shared"
        elif lepton_array_has "${NAME}" "${DEFAULT_NAMES[@]}"; then
            println "WARNING: shared folder ${NAME} left unchanged: it links to $(readlink -- "${LINK}"), which Lepton did not make" >&2
        fi
    done

    for ENTRY in "${SHARED_FOLDER_ENTRIES[@]}"; do
        IFS=$'\t' read -r NAME HOST GUEST MODE STATE KIND <<< "${ENTRY}"
        LINK="${TARGET}/${NAME}"
        case "${STATE}" in
            absent) continue ;;
            missing)
                println "WARNING: shared folder ${NAME}: ${HOST} is not there (a drive not connected?), so it is not shared this launch. Nothing was changed." >&2
                continue ;;
        esac
        # Default folders shared read-write stay quiet, as they always were.
        if [[ "${KIND}" == custom || "${MODE}" == ro ]]; then
            println "Shared folder ${NAME}: ${HOST} ($([[ "${MODE}" == ro ]] && print read-only || print read-write))"
        fi
        if [[ -L "${LINK}" && "$(readlink -- "${LINK}")" != "${GUEST}" ]]; then
            # Lepton's link from before /lepton/shared (checked above).
            rm -f -- "${LINK}"
            println "Shared folder ${NAME}: link updated to ${GUEST}"
        fi
        share_host_folder "${HOST}" "${LINK}" "${GUEST}" "${MODE}"
    done

    # Android makes its standard folders only when shared storage is first
    # set up, and remakes just the ones its media index writes to (Movies,
    # Music, Pictures). A default folder that is not shared, or no longer is,
    # gets an empty folder of Android's own, as on a phone; share_host_folder
    # replaces it with the link if the folder is shared again.
    for NAME in "${DEFAULT_NAMES[@]}"; do
        LINK="${TARGET}/${NAME}"
        [[ -e "${LINK}" || -L "${LINK}" ]] && continue
        mkdir -m 0700 -- "${LINK}"
    done
}

function setup_mounts()
{
    mkdir -p "$(data_mount_path)"
    mkdir -p "$(data_mount_path)/steam_app"

    local APP_ID="$(get_app_id)"

    BASE_APK=base.apk
    if ! lepton_managed_app && is_app; then
        APP_APK_DIR="$(dirname "$(get_apk_path)")"
        # x86_64 port: an unpacked .apkm already has base.apk; its splits share
        # the package ID, so the rename-to-base.apk search must not run.
        if [[ -n "${APP_APK_DIR}" && -z "${LEPTON_APKM_DIR:-}" ]]; then
            # Annoyingly, we need to rename our `.apk` to `base.apk`, since Appdome expects that.
            # Android always does this, but Android is also totally okay with loading a random
            # `.apk` name.
            mapfile -t APKS < <(compgen -G "${APP_APK_DIR}/*.apk" || true)
            for APK in "${APKS[@]}"; do
                if [[ "$(extract_app_id "${APK}")" == "${APP_ID}" ]]; then
                    BASE_APK="$(lepton_basename "${APK}")"
                fi
            done
        fi
    elif ! lepton_managed_app; then
        APP_APK_DIR="$(get_baked_app_data_dir)/app_lowerdir"
        mkdir -p "${APP_APK_DIR}"
    fi

    if steamos_devmode_enabled; then
        mkdir -p "${HOME}/.cache/debuginfod_client"
        podman_mount_entry "${HOME}/.cache/debuginfod_client" "/debuginfo.cache" rw
    fi

    println "Setting up overlays"

    LEPTON_ROOTFS="${LEPTON_TEST_ROOTFS:-${LEPTON_DIR}/../images/rootfs}"
    LEPTON_OVERLAY="${LEPTON_DIR}"/../images/rootfs_overlay

    # Mount some directories that are overlays over our rootfs
    # However do this using bind mounts because we cannot use multiple
    # lowerdirs with the rootfs
    GUESTOS_OVERLAY="/usr/share/guestos/android"

    for OVERLAY in "${LEPTON_OVERLAY}" "${GUESTOS_OVERLAY}"; do
        [[ -d "${OVERLAY}" ]] || continue
        pushd "${OVERLAY}" >/dev/null || exit
        while IFS= read -r -d '' file; do
            DST="${file#./}"

            # Don't mount in `XrApiLayer_VALVE_fdm_injection.json` unless the FDM layer is enabled
            if [[ "$(lepton_basename "${DST}")" == "XrApiLayer_VALVE_fdm_injection.json" ]] && ! vulkan_layer_enabled "${FDM_INJECTION_LAYER_NAME}" ; then
                continue
            fi

            podman_mount_entry "${OVERLAY}/${DST}" "/${DST}" ro
        done < <(find . -type f -print0)
        popd > /dev/null || exit
    done

    # If we're baked, put our app in the correct location, otherwise just plop it into `/data/steam_app`
    # for future installation.  NOTE: Do not call this `APP_MOUNT_DIR` as then the `local` takes no effect
    # as there's already a global `APP_MOUNT_DIR` and we end up confusing `get_app_mount_dir`.  Sigh.
    local APP_MOUNT_TARGET="data/steam_app"
    if is_app_baked; then
        APP_MOUNT_TARGET="$(get_app_mount_dir)"
    fi

    if is_sysbake; then
        podman_cmdline --mount "type=bind,source="$(data_mount_path)",target=/data"
    else
        local DATA_OVERLAY_UPPERDIR="$(data_mount_path)"
        local DATA_WORKDIR="$(data_workdir)"
        mkdir -p "${DATA_OVERLAY_UPPERDIR}"
        mkdir -p "${DATA_WORKDIR}"
        podman_cmdline -v "${BAKED_SYSTEM_DATA_DIR}:/data:O,upperdir=${DATA_OVERLAY_UPPERDIR},workdir=${DATA_WORKDIR}"

        # We need to mount this dir for dev contexts/*.apk contexts
        mkdir -p "${LEPTON_DATA_DIR}"
        podman_mount_entry "${LEPTON_DATA_DIR}" "${LEPTON_DATA_DIR}" rw

        if [[ -n "${LEPTON_LIBRARY_ROOT:-}" ]]; then
            local ROOT HOST_LIBRARY_PATHS=()
            IFS=: read -ra HOST_LIBRARY_PATHS <<< "${STEAM_COMPAT_LIBRARY_PATHS:-}"
            for ROOT in "${STEAM_COMPAT_CLIENT_INSTALL_PATH:-}" "${HOST_LIBRARY_PATHS[@]}" "${STEAM_COMPAT_DATA_PATH:-}"; do
                [[ -n "$ROOT" ]] || continue
                ROOT="$(realpath -m -- "$ROOT")"
                if [[ "$ROOT" == / || "$ROOT" == "$LEPTON_LIBRARY_ROOT" ||
                      "$ROOT" == "$LEPTON_LIBRARY_ROOT/"* || "$LEPTON_LIBRARY_ROOT" == "$ROOT/"* ]]; then
                    die "Android Library must be outside Steam and Android profile mount paths: $ROOT"
                fi
            done
        fi

        # Also mount the whole STEAM_COMPAT_CLIENT_INSTALL_PATH into the container to avoid having to do path translations
        if [[ -n "${STEAM_COMPAT_CLIENT_INSTALL_PATH:-}" ]]; then
            podman_mount_entry "${STEAM_COMPAT_CLIENT_INSTALL_PATH}" "${STEAM_COMPAT_CLIENT_INSTALL_PATH}" rw
        fi

        # Now mount the apps library paths
        IFS=: read -ra library_paths <<< "${STEAM_COMPAT_LIBRARY_PATHS:-}"
        for library_path in "${library_paths[@]}"; do
            podman_mount_entry "${library_path}" "${library_path}" rw
        done

        # Symlink the /data/media/0 external storage location and mount relevant xdg dirs
        if [[ -d "${STEAM_COMPAT_DATA_PATH:-}" ]]; then
            if [[ -d "${STEAM_COMPAT_DATA_PATH}/media0" ]]; then
                if [[ ! -d "${STEAM_COMPAT_DATA_PATH}/external" ]]; then
                    mv "${STEAM_COMPAT_DATA_PATH}/media0" "${STEAM_COMPAT_DATA_PATH}/external"
                fi
            fi
            mkdir -p "${STEAM_COMPAT_DATA_PATH}/external"
        fi
        # x86_64 port: with kept app data, Android leaves this host-owned upper
        # directory at 0550 after shutdown; make it writable to replace the link.
        if [[ -d "$(data_mount_path)/media" ]]; then
            chmod u+rwx -- "$(data_mount_path)/media"
        fi
        mkdir -p "$(data_mount_path)/media"
        local TARGET_PATH="$(data_mount_path)/media/0"
        if [[ -d "${STEAM_COMPAT_DATA_PATH:-}" ]]; then
            TARGET_PATH="${STEAM_COMPAT_DATA_PATH}/external"
        else
            mkdir -p "${TARGET_PATH}"
        fi
        setup_shared_folders "${TARGET_PATH}"
        if [[ -d "${STEAM_COMPAT_DATA_PATH:-}" ]]; then
            local GUEST_EXTERNAL_PATH="${STEAM_COMPAT_DATA_PATH}/external"
            local EXTERNAL_ALIAS="${LEPTON_PROFILE_EXTERNAL_STORAGE:-}"
            local MEDIA_PATH="$(data_mount_path)/media/0"
            if [[ -z "$EXTERNAL_ALIAS" ]] && {
                [[ -L "$MEDIA_PATH" && "$(readlink -- "$MEDIA_PATH")" == /lepton/profile-external ]] ||
                lepton_android_hides "$GUEST_EXTERNAL_PATH";
            }; then
                # The alias mounts the same directory elsewhere, so existing
                # external files stay in place.
                EXTERNAL_ALIAS=/lepton/profile-external
                if [[ -L "$MEDIA_PATH" && "$(readlink -- "$MEDIA_PATH")" == "$GUEST_EXTERNAL_PATH" ]]; then
                    ln -sfnT -- "$EXTERNAL_ALIAS" "$MEDIA_PATH" || die "Could not update Lepton's external-storage link"
                fi
            fi
            if [[ -n "$EXTERNAL_ALIAS" ]]; then
                [[ "$EXTERNAL_ALIAS" == /lepton/* && "$EXTERNAL_ALIAS" != *'/../'* && "$EXTERNAL_ALIAS" != */.. ]] || die 'Invalid profile external-storage path'
                # Shared folders and library OBBs use their own /lepton paths.
                EXTERNAL_ALIAS="$(realpath -sm -- "$EXTERNAL_ALIAS")"
                [[ "$EXTERNAL_ALIAS" != /lepton && "$EXTERNAL_ALIAS" != /lepton/shared &&
                   "$EXTERNAL_ALIAS" != /lepton/shared/* && "$EXTERNAL_ALIAS" != /lepton/managed-obb &&
                   "$EXTERNAL_ALIAS" != /lepton/managed-obb/* ]] || die "External-storage alias overlaps Lepton's shared-folder mounts"
                GUEST_EXTERNAL_PATH="$EXTERNAL_ALIAS"
                podman_mount_entry "${STEAM_COMPAT_DATA_PATH}/external" "$GUEST_EXTERNAL_PATH" rw
            elif ! host_path_in_container "${GUEST_EXTERNAL_PATH}"; then
                # x86_64 port: profiles outside Steam's folders (lepton-play)
                # are not otherwise mounted, which left /data/media/0 dangling:
                # no shared storage and no OBB link. Mount it at its own path
                # so the existing link stays valid.
                podman_mount_entry "${GUEST_EXTERNAL_PATH}" "${GUEST_EXTERNAL_PATH}" rw
            fi
            safe_storage_link "$GUEST_EXTERNAL_PATH" "$(data_mount_path)/media/0" || die "Shared storage preserved; launch stopped"
        fi
    fi

    if steamos_devmode_enabled; then
        if perfetto_installed; then
            podman_mount_entry_optional /tmp/perfetto-producer /dev/socket/traced_producer rw
        else
            echo "Skipping perfetto setup due to missing tracebox binary ('sudo pacman -S perfetto perfetto-android' if you need it)"
        fi
    fi

    if ! is_sysbake && ! lepton_managed_app; then
        local APP_WORKDIR="$(app_workdir)"
        local APP_OVERLAY_UPPERDIR="$(app_datadir)"
        mkdir -p "${APP_WORKDIR}"
        mkdir -p "${APP_OVERLAY_UPPERDIR}"
        podman_cmdline -v "${APP_APK_DIR}:/${APP_MOUNT_TARGET#/}:O,upperdir=${APP_OVERLAY_UPPERDIR},workdir=${APP_WORKDIR}"
        # A persistent development profile installs through pm rather than the
        # Steam bake path. Restore its code directory before package scanning.
        if [[ -n "${LEPTON_PROFILE_CODE_PATH:-}" ]]; then
            [[ "$LEPTON_PROFILE_CODE_PATH" == /data/app/* && "$LEPTON_PROFILE_CODE_PATH" != *'/../'* && "$LEPTON_PROFILE_CODE_PATH" != */.. ]] || die 'Invalid profile code path'
            podman_mount_entry "$APP_OVERLAY_UPPERDIR" "$LEPTON_PROFILE_CODE_PATH" ro
        fi
    fi

    if lepton_managed_app; then
        lepton_managed_mounts
    elif [[ -n "${LEPTON_MOUNT_OBB_DIR:-}" ]]; then
        podman_mount_entry "${LEPTON_MOUNT_OBB_DIR}" "/${APP_MOUNT_TARGET}/obb" ro
    fi

    podman_mount_entry "${HOME}/.steam/steam.pipe" "/lepton/steam.pipe" rw
}

# Give podman some of its boilerplate information
function setup_podman_base()
{
    # namespaces
    podman_cmdline --security-opt label=disable
    podman_cmdline --pid=private --ipc=private --uts=private

    if [[ "$(android_sdk_version)" != "30" ]]; then
        if [[ -d "/sys/fs/cgroup/lepton-${LEPTON_CONTEXT}" ]]; then
            # On gitlab CI
            podman_cmdline --cgroupns=host
            podman_cmdline --cgroup-parent="/lepton-${LEPTON_CONTEXT}"
            podman_mount_entry "/sys/fs/cgroup/lepton-${LEPTON_CONTEXT}" "/sys/fs/cgroup" rw
        else
            systemctl --user start "lepton-${LEPTON_CONTEXT}.slice"

            podman_cmdline --cgroupns=host
            podman_cmdline --cgroup-parent="lepton-${LEPTON_CONTEXT}".slice
            podman_mount_entry "/sys/fs/cgroup/$(systemctl --user show -P ControlGroup "lepton-${LEPTON_CONTEXT}.slice")" "/sys/fs/cgroup" rw,U
        fi
    else
        podman_cmdline --cgroupns=private
    fi

    # capabilities
    podman_cmdline --cap-drop ALL
    podman_cmdline --cap-add audit_control
    podman_cmdline --cap-add sys_nice
    podman_cmdline --cap-add wake_alarm
    podman_cmdline --cap-add setpcap
    podman_cmdline --cap-add setgid
    podman_cmdline --cap-add setuid
    podman_cmdline --cap-add sys_ptrace
    podman_cmdline --cap-add sys_admin
    podman_cmdline --cap-add block_suspend
    podman_cmdline --cap-add sys_time
    podman_cmdline --cap-add net_admin
    podman_cmdline --cap-add net_raw
    podman_cmdline --cap-add net_bind_service
    podman_cmdline --cap-add kill
    podman_cmdline --cap-add dac_override
    podman_cmdline --cap-add dac_read_search
    podman_cmdline --cap-add fsetid
    podman_cmdline --cap-add mknod
    podman_cmdline --cap-add syslog
    podman_cmdline --cap-add chown
    podman_cmdline --cap-add sys_resource
    podman_cmdline --cap-add fowner
    podman_cmdline --cap-add ipc_lock
    podman_cmdline --cap-add sys_chroot

    # hostname
    podman_cmdline --hostname "lepton-${LEPTON_CONTEXT}"

    # seccomp
    podman_cmdline --security-opt seccomp="${LEPTON_DIR}"/lepton.seccomp.json
}

function podman_extract_rootfs_file()
{
    local FILE="$1"
    local TARGET="$2"
    cp "${LEPTON_TEST_ROOTFS:-${LEPTON_DIR}/../images/rootfs}/${FILE#/}" "${TARGET}"
}

function generate_app_launch_rc()
{
    local APP_LAUNCH_RC="$(prefix "${1:-}")/lepton_app_launch.rc"

    local APP_MOUNT_TARGET="data/steam_app"
    if is_app_baked; then
        APP_MOUNT_TARGET="$(get_app_mount_dir)"
    fi

    if ! lepton_managed_app && ! is_app_baked && [[ "${BASE_APK}" != "base.apk" ]]; then
        println "on early-init" >>"${APP_LAUNCH_RC}"
        println "    exec -- /system/bin/sh -c \"mv \"/${APP_MOUNT_TARGET#/}/${BASE_APK}\" \"/${APP_MOUNT_TARGET#/}/base.apk\"\"" >>"${APP_LAUNCH_RC}"
        println "    exec -- /system/bin/sh -c \"find \"/${APP_MOUNT_TARGET#/}\" -name '*.apk' -a ! -name 'base.apk' -type f -exec rm -f {} +\"" >>"${APP_LAUNCH_RC}"
    fi

    if ! is_app || is_app_baked; then
        println "on property:sys.boot_completed=1" >>"${APP_LAUNCH_RC}"
        println "    exec -- /system/bin/cmd lepton mount_vulkan_layers" >>"${APP_LAUNCH_RC}"
    fi

    # Only do this if we actually have an app we're trying to launch
    if is_app; then
        println "on property:sys.boot_completed=1 && property:ro.lepton.app_baked=1" >>"${APP_LAUNCH_RC}"

        # Make sure the obb symlink is in order.
        local APP_ID="$(get_app_id)"
        if lepton_managed_app; then
            lepton_managed_launch_rc >>"${APP_LAUNCH_RC}"
        else
            println "    exec -- /vendor/bin/fix_obb_symlink.sh \"${APP_ID}\"" >>"${APP_LAUNCH_RC}"
        fi

        # Add install commands for vulkan layers
        local HOST_LAYER_INSTALL_SCRIPT="$(prefix "${1:-}")/vulkan_layer_setup.sh"
        local CONTAINER_LAYER_INSTALL_SCRIPT="/vendor/share/vulkan_layer_setup.sh"
        generate_vulkan_settings_script > "${HOST_LAYER_INSTALL_SCRIPT}"
        chmod 0755 "${HOST_LAYER_INSTALL_SCRIPT}"
        println "    exec -- /system/bin/sh ${CONTAINER_LAYER_INSTALL_SCRIPT}" >>"${APP_LAUNCH_RC}"
        podman_mount_entry "${HOST_LAYER_INSTALL_SCRIPT}" "${CONTAINER_LAYER_INSTALL_SCRIPT}" ro,U

        # Wait for storage to be mounted
        println "    exec -- /system/bin/timeout 10 /system/bin/logcat -e \"End Intent.*android.intent.action.MEDIA_MOUNTED\" -m 1" >>"${APP_LAUNCH_RC}"

        if debugger_wait_enabled || strace_enabled; then
            println "Adding debugger wait to app launch"
            println "    exec -- /system/bin/sh -c \"$(debugger_wait_commands)\"" >>"${APP_LAUNCH_RC}"
        fi

        # Run the actual app
        println "    exec -- /system/bin/sh -c \"$(lepton_launch_commands)\"" >>"${APP_LAUNCH_RC}"

        if debugger_wait_enabled || strace_enabled; then
            if strace_enabled; then
                println "Adding strace to app launch"
                println "on property:ro.lepton.ready_for_debugger=true" >>"${APP_LAUNCH_RC}"
                println "    exec -- /system/bin/sh -c \"$(strace_zygote_commands)\"" >>"${APP_LAUNCH_RC}"
            fi
    fi
        chmod 0644 "${APP_LAUNCH_RC}"
    elif google_play_mode; then
        # x86_64 port: Google Play launcher: no game to install or watch; open
        # the store once Android and its storage are ready. Leaving it (Home,
        # another game) does not end the session; Steam's Stop does.
        println "on property:sys.boot_completed=1 && property:ro.lepton.app_baked=1" >>"${APP_LAUNCH_RC}"
        println "    exec -- /system/bin/timeout 10 /system/bin/logcat -e \"End Intent.*android.intent.action.MEDIA_MOUNTED\" -m 1" >>"${APP_LAUNCH_RC}"
        println "    exec -- /system/bin/sh -c \"$(lepton_launch_commands)\"" >>"${APP_LAUNCH_RC}"
        chmod 0644 "${APP_LAUNCH_RC}"
    fi
    podman_mount_entry "${APP_LAUNCH_RC}" "/vendor/etc/init/$(lepton_basename "${APP_LAUNCH_RC}")" ro,U
}


function generate_zygote_launch_rc()
{
    local TURNIP_VARS=(
        TU_GPU_TRACEPOINT
        _TU_DEBUG
        TU_BREADCRUMBS
        TU_DEBUG_STALE_REGS_RANGE
        TU_DEBUG_STALE_REGS_FLAGS
        FD_DEV_FEATURES
        FD_RD_DUMP
        IR3_SHADER_DEBUG
        IR3_SHADER_OVERRIDE_PATH
        MESA_VK_ABORT_ON_DEVICE_LOSS
        MESA_GPU_TRACES
        MESA_VK_ENABLE_SUBMIT_THREAD
        MESA_VK_TRACE
        MESA_VK_TRACE_TRIGGER
        NIR_DEBUG
        NIR_SKIP
    )
    local ZINK_VARS=(
        MESA_EXTENSION_OVERRIDE
        MESA_GLSL_VERSION_OVERRIDE
        MESA_GLES_VERSION_OVERRIDE
        MESA_SHADER_CACHE_MAX_SIZE
        MESA_DISK_CACHE_SINGLE_FILE
        MESA_DISK_CACHE_READ_ONLY_FOZ_DBS
        ZINK_DEBUG
        ZINK_DESCRIPTORS
        ZINK_RENDERDOC
        GALLIUM_THREAD
        ZINK_HANG_ABORT
    )
    local PASSTHROUGH_VARS=(
        "${TURNIP_VARS[@]}"
        "${ZINK_VARS[@]}"

        # FDM injection layer debug options
        FDM_DEBUG
        FOVE_LEVEL

        # Pass through `SteamAppId` so `steamvr` can get at it in `CVRClient::SendConnectMessage()`
        SteamAppId

        # Pass through debugging variables that vrclient can use
        EnableFrameEndMarkers
        DisableTimelineSemaphoreWait

        # Pass through proxy variables
        HTTP_PROXY
        HTTPS_PROXY
        http_proxy
        https_proxy
        NO_PROXY
        no_proxy
    )
    local ZYGOTE_LAUNCH_RC="$(prefix "${1:-}")/init.zygote64.rc"
    podman_extract_rootfs_file "/system/etc/init/hw/init.zygote64.rc" "${ZYGOTE_LAUNCH_RC}"
    for VAR in ${PASSTHROUGH_VARS[@]}; do
        if [[ -v "${VAR}" ]]; then
            println "    setenv ${VAR} ${!VAR}" >> "${ZYGOTE_LAUNCH_RC}"
        fi
    done

    # User LEPTON_ENV_* passthrough variables.
    for VAR in $(compgen -v); do
        if [[ "${VAR}" == "LEPTON_ENV_"* ]]; then
            VARNAME="${VAR#LEPTON_ENV_}"
            println "    setenv ${VARNAME} ${!VAR}" >> "${ZYGOTE_LAUNCH_RC}"
        fi
    done

    configure_ndk_compat "${ZYGOTE_LAUNCH_RC}"

    # provide a vr config file
    println "    setenv VR_PATHREG_OVERRIDE /vendor/etc/openvrpaths.vrpath" >> "${ZYGOTE_LAUNCH_RC}"
    podman_mount_entry "${LEPTON_DIR}/openvrpaths.vrpath" "/vendor/etc/openvrpaths.vrpath" ro,U

    # tell vrclient where to find our steamvr config/logs
    println "    setenv VR_CONFIG_PATH /data/steamvr/config" >> "${ZYGOTE_LAUNCH_RC}"
    println "    setenv VR_LOG_PATH /data/steamvr/logs" >> "${ZYGOTE_LAUNCH_RC}"

    # Tell Mesa where to slurp up its shaders
    #println "    setenv MESA_SHADER_CACHE_DIR /data/shaders" >> "${ZYGOTE_LAUNCH_RC}"
    println "    setenv Steam3Master $(podman_subnet).1:57343" >> "${ZYGOTE_LAUNCH_RC}"

    chmod 0644 "${ZYGOTE_LAUNCH_RC}"
    podman_mount_entry "${ZYGOTE_LAUNCH_RC}" "/system/etc/init/hw/init.zygote64.rc" ro,U
}

function disable_default_allocator()
{
    println "<manifest version=\"1.0\" type=\"device\"></manifest>" > $(prefix)/allocator.xml
    podman_mount_entry "$(prefix)/allocator.xml" "/vendor/etc/vintf/manifest/android.hardware.graphics.allocator@4.0.xml" rw,U
}

function disable_minigbm()
{
    rm -f $(prefix)/minigbm_msm.rc
    touch $(prefix)/minigbm_msm.rc
    podman_mount_entry "$(prefix)/minigbm_msm.rc" "/vendor/etc/init/allocator.rc" rw,U
    podman_mount_entry "$(prefix)/minigbm_msm.rc" "/vendor/etc/init/android.hardware.graphics.allocator@4.0-service.minigbm_msm.rc" rw,U
    podman_mount_entry "$(prefix)/minigbm_msm.rc" "/vendor/etc/init/android.hardware.graphics.allocator@4.0-service.minigbm.rc" rw,U
}

function disable_qti_display()
{
    println "<manifest version=\"1.0\" type=\"device\"></manifest>" > $(prefix)/qti-display.xml
    rm -f $(prefix)/qti-display.rc
    touch $(prefix)/qti-display.rc
    podman_mount_entry "$(prefix)/qti-display.xml" "/vendor/etc/vintf/manifest/android.hardware.graphics.mapper-impl-qti-display.xml" rw,U
    podman_mount_entry "$(prefix)/qti-display.xml" "/vendor/etc/vintf/manifest/vendor.qti.hardware.display.allocator-service.xml" rw,U
    podman_mount_entry "$(prefix)/qti-display.rc" "/vendor/etc/init/vendor.qti.hardware.display.allocator-service.rc" rw,U
}

# x86_64 port: hardware graphics with Mesa RADV/RadeonSI (AMD) or ANV/Iris
# (Intel). One GPU is chosen per launch, and Android only sees its render node.
# Unusable setups stop early with a clear message instead of an opaque Android
# graphics failure.

# Intel GPUs (PCI device IDs) that ANV does not drive: Gen2 to Gen8. From Mesa
# 26.0.8 include/pci_ids: all of i915_pci_ids.h and crocus_pci_ids.h, plus the
# Broadwell/Cherryview entries of iris_pci_ids.h (ANV needs Gen9, Skylake).
LEPTON_INTEL_PRE_GEN9_IDS="
0x0042 0x0046 0x0102 0x0106 0x010a 0x0112 0x0116 0x0122 0x0126 0x0152 0x0155 0x0156 0x0157
0x015a 0x0162 0x0166 0x016a 0x0402 0x0406 0x040a 0x040b 0x040e 0x0412 0x0416 0x041a 0x041b
0x041e 0x0422 0x0426 0x042a 0x042b 0x042e 0x0a02 0x0a06 0x0a0a 0x0a0b 0x0a0e 0x0a12 0x0a16
0x0a1a 0x0a1b 0x0a1e 0x0a22 0x0a26 0x0a2a 0x0a2b 0x0a2e 0x0c02 0x0c06 0x0c0a 0x0c0b 0x0c0e
0x0c12 0x0c16 0x0c1a 0x0c1b 0x0c1e 0x0c22 0x0c26 0x0c2a 0x0c2b 0x0c2e 0x0d02 0x0d06 0x0d0a
0x0d0b 0x0d0e 0x0d12 0x0d16 0x0d1a 0x0d1b 0x0d1e 0x0d22 0x0d26 0x0d2a 0x0d2b 0x0d2e 0x0f31
0x0f32 0x0f33 0x1602 0x1606 0x160a 0x160b 0x160d 0x160e 0x1612 0x1616 0x161a 0x161b 0x161d
0x161e 0x1622 0x1626 0x162a 0x162b 0x162d 0x162e 0x22b0 0x22b1 0x22b2 0x22b3 0x2582 0x258a
0x2592 0x2772 0x27a2 0x27ae 0x2972 0x2982 0x2992 0x29a2 0x29b2 0x29c2 0x29d2 0x2a02 0x2a12
0x2a42 0x2e02 0x2e12 0x2e22 0x2e32 0x2e42 0x2e92 0xa001 0xa011
"

# The host's render nodes, one "renderDN vendor device" line each, in order.
function lepton_render_nodes()
{
    local dir vendor device
    for dir in "${LEPTON_SYSFS_DRM:-/sys/class/drm}"/renderD*; do
        [[ -r "${dir}/device/vendor" ]] || continue
        vendor="$(<"${dir}/device/vendor")"
        device=unknown
        [[ -r "${dir}/device/device" ]] && device="$(<"${dir}/device/device")"
        echo "${dir##*/} ${vendor,,} ${device,,}"
    done
}

# The GPU family Lepton drives with hardware graphics: "amd" (vendor 0x1002)
# when any AMD render node exists, else "intel" (0x8086), else empty.
function lepton_host_gpu_vendor()
{
    local nodes
    nodes="$(lepton_render_nodes)"
    if grep -q ' 0x1002 ' <<< "${nodes}"; then echo amd
    elif grep -q ' 0x8086 ' <<< "${nodes}"; then echo intel
    fi
}

# Android Vulkan HAL suffix (vendor/lib64/hw/vulkan.<suffix>.so) for this host.
# LEPTON_VULKAN_DRIVER=radeon|intel overrides the detection.
function lepton_vulkan_hal()
{
    case "${LEPTON_VULKAN_DRIVER:-}" in
        radeon|intel) echo "${LEPTON_VULKAN_DRIVER}"; return 0 ;;
    esac
    if [[ "$(lepton_host_gpu_vendor)" == intel ]]; then echo intel; else echo radeon; fi
}

# "renderDN device" of the first render node of the GPU that the selected
# Vulkan driver drives; empty when there is none.
function lepton_selected_gpu()
{
    local vendor=0x1002 name node_vendor device
    [[ "$(lepton_vulkan_hal)" == intel ]] && vendor=0x8086
    while read -r name node_vendor device; do
        [[ "${node_vendor}" == "${vendor}" ]] && { echo "${name} ${device}"; return 0; }
    done < <(lepton_render_nodes)
}

# /dev/dri path of the selected GPU's render node (Android's gralloc and
# Vulkan driver use it, and no other); empty when there is none.
function lepton_gpu_render_node()
{
    local name=""
    read -r name _ < <(lepton_selected_gpu) || true
    [[ -n "${name}" ]] && echo "/dev/dri/${name}"
    return 0
}

function check_host_gpu()
{
    [[ "$(uname -m)" == "x86_64" ]] || return 0
    [[ "${LEPTON_FORCE_SOFTWARE:-}" != "true" && "${LEPTON_SKIP_GPU_CHECK:-false}" != "true" ]] || return 0
    local hal name="" device="" software="Set LEPTON_FORCE_SOFTWARE=true to try slow software rendering instead."
    hal="$(lepton_vulkan_hal)"
    read -r name device < <(lepton_selected_gpu) || true
    if [[ -z "${name}" ]]; then
        [[ -z "$(lepton_host_gpu_vendor)" ]] ||
            die "Lepton x86_64: LEPTON_VULKAN_DRIVER=${hal}, but this computer has no matching GPU." \
                "Unset LEPTON_VULKAN_DRIVER to use the GPU Lepton detects."
        die "Lepton x86_64: no AMD or Intel GPU render node (/dev/dri/renderD*) found." \
            "This build only includes AMD (RADV/radeonsi) and Intel (ANV/Iris) drivers." "${software}"
    fi
    if [[ ! -f "$(lepton_rootfs_dir)/vendor/lib64/hw/vulkan.${hal}.so" ]]; then
        [[ "${hal}" == intel ]] &&
            die "Lepton x86_64: this Lepton tool has no Intel graphics drivers (an AMD-only bundle)." \
                "Install a bundle built with Intel support, or ${software/#Set/set}"
        die "Lepton x86_64: this Lepton tool has no ${hal} Vulkan driver (vendor/lib64/hw/vulkan.${hal}.so)." \
            "Reinstall the Lepton tool. ${software}"
    fi
    if [[ "${hal}" == intel && " ${LEPTON_INTEL_PRE_GEN9_IDS//$'\n'/ } " == *" ${device} "* ]]; then
        die "Lepton x86_64: this Intel GPU (device ${device}) is too old for Lepton's Intel Vulkan driver, which needs Gen9 (Skylake, 2015) or newer." \
            "${software}"
    fi
    return 0
}

function setup_podman_mounts()
{
    local PREFIX="$(prefix)"

    # Tell podman to setup a bunch of dev and bind-mounts for us, mostly dev nodes and whatnot.
    # We obviously can't bake these into the `.img` files, which is why we ask podman to do them at container creation time.

    # Set the rootfs path

    podman_cmdline --env-file /dev/null

    # tmpfs mounts.  `/dev` is special, as it's going to get `dev` devices so it can't be `nodev`.
    local TMPFS_NODES=(tmp var run)
    podman_cmdline --tmpfs /dev:rw,nosuid,noexec,U
    podman_cmdline --tmpfs /dev/socket:rw,nosuid,noexec,U

    for tmpfs in "${TMPFS_NODES[@]}"; do
        podman_cmdline --tmpfs /"${tmpfs}":rw,nosuid,nodev,noexec,U
    done
    podman_cmdline --tmpfs /waydroid/xdg

    local DEV_NODES=(
        zero null full fuse tty char

        # V4L2 video devices (Note: explicitly do not share 99, we use that for screen broadcasting)
        # Update: Elliot is explicitly disabling this for now, until we decide that we _want_
        # to support reading in video in Lepton.
        #video{0..11} video-dec0

        # Shared memory
        shm

        # Sound
        snd

        # Necessary for adb
        uhid

        # Necessary for VPN
        net/tun

        random urandom
    )

    # On gitlab we run via swiftshader.
    if [[ "${LEPTON_FORCE_SOFTWARE:-}" != "true" ]]; then
        if [[ "$(uname -m)" == "x86_64" ]]; then
            # Only the selected GPU's render node: on multi-GPU hosts gralloc
            # would otherwise allocate on whichever node it finds first.
            local render_node
            render_node="$(lepton_gpu_render_node)"
            for dev in /dev/dri/renderD* /dev/dri/card*; do
                [[ -e "${dev}" ]] || continue
                [[ "${dev}" != /dev/dri/renderD* || -z "${render_node}" || "${dev}" == "${render_node}" ]] || continue
                podman_mount_entry "${dev}" "${dev}" rw
            done
        else
            for dev in renderD128 card0; do
                if [[ -e "/dev/dri/${dev}" ]]; then
                    podman_mount_entry "/dev/dri/${dev}" "/dev/dri/${dev}" rw
                fi
            done

            # KGSL blob driver compatibility.
            podman_mount_entry "/dev/dri/renderD128" "/dev/kgsl-3d0" rw
        fi
    fi

    for dev in "${DEV_NODES[@]}"; do
        if [[ -e "/dev/${dev}" ]]; then
            podman_mount_entry "/dev/${dev}" "/dev/${dev}" rw
        fi
    done
    # x86_64 port: older images' media decoders (Codec2) allocate from the
    # DMA-BUF system heap; images with patch 0013 (Intel: 0013 and 0014) use
    # gralloc and need none.
    if [[ "$(lepton_codec2_mode)" == heap ]]; then
        podman_mount_entry "$(lepton_dma_heap_device)" "/dev/dma_heap/system" rw
    fi

    # Bind each Steam Input virtual controller present at container startup.
    # Podman's --device nodes are hidden by Android's /dev tmpfs, so explicit
    # per-device binds are needed. This does not expose unrelated host inputs.
    # Later controller connections still require experimental hotplug opt-in.
    # Passthrough defaults to enabled; set LEPTON_GAMEPAD_PASSTHROUGH=false
    # to opt out.
    if ! is_sysbake && [[ "${LEPTON_GAMEPAD_PASSTHROUGH:-true}" == "true" ]]; then
        local gamepad_event gamepad_sysfs gamepad_name gamepad_vendor gamepad_product
        for gamepad_event in /dev/input/event*; do
            [[ -c "${gamepad_event}" ]] || continue
            gamepad_sysfs="/sys/class/input/${gamepad_event##*/}/device"
            [[ -r "${gamepad_sysfs}/name" &&
               -r "${gamepad_sysfs}/id/vendor" &&
               -r "${gamepad_sysfs}/id/product" ]] || continue

            gamepad_name="$(cat "${gamepad_sysfs}/name")"
            gamepad_vendor="$(cat "${gamepad_sysfs}/id/vendor")"
            gamepad_product="$(cat "${gamepad_sysfs}/id/product")"

            if [[ "${gamepad_name}" == "Microsoft X-Box 360 pad "* &&
                  "${gamepad_vendor}" == "28de" &&
                  "${gamepad_product}" == "11ff" ]]; then
                println "Passing Steam Input controller ${gamepad_event} to Android"
                podman_mount_entry "${gamepad_event}" "${gamepad_event}" rw
            fi
        done
        # One shared keylayout for every matching Steam Input virtual pad.
        podman_mount_entry \
            "${LEPTON_DIR}/Vendor_28de_Product_11ff.kl" \
            "/system/usr/keylayout/Vendor_28de_Product_11ff.kl" ro
    fi

    # Experimental hotplug proof: make host evdev nodes visible at a stable
    # path, separate from Android's own /dev/input FIFOs and input registry.
    # No additional Android devices are registered until a selected symlink
    # is explicitly created under /dev/input. Opt-in because this directory
    # exposes more host input devices to Android than the individual bind.
    if ! is_sysbake &&
       [[ "${LEPTON_GAMEPAD_PASSTHROUGH:-true}" == "true" ]] &&
       [[ "${LEPTON_GAMEPAD_HOTPLUG:-false}" == "true" ]] &&
       [[ -d /dev/input ]]; then
        podman_mount_entry /dev/input /lepton/host-input ro
    fi

    # By default, we do not allow writes to msg
    local KMSG_MOUNT="/dev/null"
    if [[ "${LEPTON_ALLOW_KMSG:-false}" != "false" ]]; then
        KMSG_MOUNT="/dev/kmsg"
    fi
    podman_mount_entry "${KMSG_MOUNT}" /dev/container_kmsg rw
    podman_mount_entry "${KMSG_MOUNT}" /dev/kmsg rw

    # devpts mount
    podman_mount_entry_type "devpts" /dev/pts "mode=644,ptmxmode=666"

    # debugfs mount
    podman_mount_entry "/sys/kernel/debug" "/sys/kernel/debug" rw
    podman_mount_entry "/sys/kernel/tracing" "/sys/kernel/tracing" rw
    podman_cmdline --tmpfs /sys/fs/bpf:rw,mode=700

    podman_mount_entry_optional "${APK_AUTO_INSTALL_DIR}" "/data/auto_install" rw,U

    DATA_OVERLAY="$(data_mount_path)"

    # Generate `ipconfig.txt` for our ethernet device:
    generate_ipconfig_txt > "$(prefix)/ipconfig.txt"
    mkdir -p "${DATA_OVERLAY}/misc/ethernet"
    touch "${DATA_OVERLAY}/misc/ethernet/ipconfig.txt"
    podman_mount_entry "$(prefix)/ipconfig.txt" "/data/misc/ethernet/ipconfig.txt" rw

    # Android 14 prefers the Tethering APEX configuration over the legacy path.
    # Override both with this container's current IP, not an address from sysbake.
    if [[ "$(android_sdk_version)" -ge 34 ]]; then
        local ETHERNET_APEX_CONFIG="misc/apexdata/com.android.tethering/misc/ethernet/ipconfig.txt"
        mkdir -p "${DATA_OVERLAY}/$(dirname "${ETHERNET_APEX_CONFIG}")"
        touch "${DATA_OVERLAY}/${ETHERNET_APEX_CONFIG}"
        podman_mount_entry "$(prefix)/ipconfig.txt" "/data/${ETHERNET_APEX_CONFIG}" rw
    fi

    if ! is_sysbake && command -v steamvr >/dev/null 2>&1; then
        mkdir -p "${DATA_OVERLAY}/steamvr/runtime"
        # Add our steamvr build into `/data/steamvr/runtime` and `/data/steamvr/config`
        podman_mount_entry "$(steamvr path)" "/data/steamvr/runtime" rw

        podman_mount_entry "${STEAM_LOG_PATH}" "/data/steamvr/logs" rw
        podman_mount_entry "$(steamvr configpath)" "/data/steamvr/config" ro
    fi

    # Mount shader cache directory
    if [[ -d "${STEAM_COMPAT_SHADER_PATH:-}" ]]; then
        podman_mount_entry "${STEAM_COMPAT_SHADER_PATH}" "/data/shaders" rw,U
    fi

    # Mount persistent data path
    if [[ -d "${STEAM_COMPAT_DATA_PATH:-}" ]]; then
        PERSISTENT_DATA_PATH="${STEAM_COMPAT_DATA_PATH}/internal/$(get_app_id)"
        if [[ -n "$(get_app_id)" && -d "${STEAM_COMPAT_DATA_PATH}/$(get_app_id)" ]]; then
            if [[ ! -d "${PERSISTENT_DATA_PATH}" ]]; then
                mkdir -p "$(dirname "${PERSISTENT_DATA_PATH}")"
                mv "${STEAM_COMPAT_DATA_PATH}/$(get_app_id)" "${PERSISTENT_DATA_PATH}"
            fi
        fi
        mkdir -p "${PERSISTENT_DATA_PATH}"
        chmod 700 "${PERSISTENT_DATA_PATH}"
    fi

    mkdir -p "${PREFIX}/mounts"
    # Mount steamclient.so directory.  Note that we have to add `libsteamclient` and friends
    # to `/system/etc/public.libraries.txt` so that it's all loadable.
    podman_extract_rootfs_file "/system/etc/public.libraries.txt" "${PREFIX}/mounts/public.libraries.txt"
    if [[ -f "${STEAM_COMPAT_CLIENT_INSTALL_PATH:-}/androidarm64/libsteamclient.so" ]]; then
        for LIBNAME in "${STEAM_COMPAT_CLIENT_INSTALL_PATH}/androidarm64/"*.so; do
            LIBNAME="$(lepton_basename "${LIBNAME}")"
            println "${LIBNAME} nopreload" >>"${PREFIX}/mounts/public.libraries.txt"
            podman_mount_entry "${STEAM_COMPAT_CLIENT_INSTALL_PATH}/androidarm64/${LIBNAME}" "/system/lib64/${LIBNAME}" ro,U
        done
    fi
    podman_mount_entry "${PREFIX}/mounts/public.libraries.txt" "/system/etc/public.libraries.txt" ro,U

    # We need to insert our vulkan loader libraries here so that libopenxr_loader.so can load them.
    # The vulkan loader can load them no problem (sigh) but our plebian libopenxr_loader.so cannot.
    for LIBPATH in "${ENABLED_VULKAN_LAYER_PATHS[@]}"; do
        podman_mount_entry "${LIBPATH}" "/vendor/enabled_vulkan_layers/$(lepton_basename "${LIBPATH}")" ro
    done

    # If we have renderdoc .apk's, mount them in to where we expect them within the container
    if vulkan_layer_enabled "${RENDERDOC_LAYER_NAME}" && [[ -f "/usr/share/renderdoc/plugins/android/${RENDERDOC_APP_ID}.apk" ]]; then
        println "Mounting in renderdoc .apk"
        podman_mount_entry "/usr/share/renderdoc/plugins/android/${RENDERDOC_APP_ID}.apk" "/vendor/apps_to_install/${RENDERDOC_APP_ID}.apk" ro
    fi

    # Mount in our prop file
    podman_mount_entry "$(props_file)" "/vendor/waydroid.prop" ro,U

    # Next, mounts for things like pulse, wayland, etc...
    podman_mount_entry "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" "/waydroid/xdg/wayland-0" rw,U
    if ! is_sysbake; then
        podman_mount_entry "${PULSE_RUNTIME_PATH}/native" "/waydroid/xdg/pulse/native" rw,U
    fi

    # Disable incompatible services depending on the gfx mode.
    if [[ "${LEPTON_FORCE_SOFTWARE:-}" == "true" ]]; then
        if [[ "$(android_sdk_version)" == "30" ]]; then
            disable_default_allocator
        fi
        disable_minigbm
        disable_qti_display

        # x86_64 software mode: the GBM 4.0 HAL is declared in VINTF
        # and may be started lazily even with gralloc=default.
        # Hide these HAL declarations so Android uses software gralloc.
        if [[ "$(uname -m)" == "x86_64" ]]; then
            local empty_manifest="${PREFIX}/gbm-software-vintf.xml"
            printf '%s\n' '<manifest version="1.0" type="device"></manifest>' > "${empty_manifest}"

            local fragment
            for fragment in gbm_mesa.allocator@4.0.xml gbm_mesa.mapper@4.0.xml; do
                if [[ -f "${LEPTON_DIR}/../images/rootfs/vendor/etc/vintf/manifest/${fragment}" ]]; then
                    podman_mount_entry "${empty_manifest}" "/vendor/etc/vintf/manifest/${fragment}" ro,U
                fi
            done
        fi
    else
        if [[ "${LEPTON_USE_QCOM_DRIVER:-false}" == "true" ]]; then
            disable_minigbm
        else
            disable_qti_display
        fi
    fi

    if [[ -n "${DEBUGINFOD_URLS:-}" ]]; then
        # Tell crash dump the debuginfod urls (env does not get inherited from zygote).
        println "${DEBUGINFOD_URLS}" > "$(prefix)/debuginfod_urls.txt"
        podman_mount_entry "$(prefix)/debuginfod_urls.txt" "/vendor/etc/debuginfod_urls.txt" rw,U
    fi
}

function log_moved_dirs()
{
    if [[ -n "${1:-}" ]]; then
        echo "WARNING: lepton moved some files because they had incorrect permissions."
        echo "If you lost something, try looking here: ${1:-}"
    fi
}

MOVED_INACCESSIBLE=""
function ensure_permissions_ok()
{
    local APP_ID="$(get_app_id)"
    if ! is_sysbake && [[ "${LEPTON_CONTEXT:-}" == "steamlaunch-"* ]]; then
        if [[ -n "${STEAM_LOG_PATH}" ]]; then
            # Log files we touch but are not owned by us will cause trouble
            for not_owned_by_us in $(find "${STEAM_LOG_PATH}" ! -uid "$(id -u)" -name "*app_process64*" -type f); do
                # Since the dir is owned by us, we can rm files within it.
                rm -f "${not_owned_by_us}"
            done

            if [[ -n "${APP_ID}" ]]; then
                for not_owned_by_us in $(find "${STEAM_LOG_PATH}" ! -uid "$(id -u)" -name "*${APP_ID}*" -type f); do
                    # Since the dir is owned by us, we can rm files within it.
                    rm -f "${not_owned_by_us}"
                done
            fi
        fi

        # Android-owned profile directories must keep their location and owner.
        # Moving one aside can silently make a subsequent launch look empty.
        if [[ -n "${STEAM_COMPAT_SHADER_PATH:-}" ]]; then
            SHADER_PATH_STAT="$(stat --format "%u:%g" "${STEAM_COMPAT_SHADER_PATH:-}" 2>/dev/null || true)"
            if [[ -n "${SHADER_PATH_STAT}" ]] && [[ "${SHADER_PATH_STAT}" != "$(id -u):$(id -g)" ]]; then
                # If it's a directory it may not be empty, so we can't rm it => move it.
                mv "${STEAM_COMPAT_SHADER_PATH:-}" "${STEAM_COMPAT_SHADER_PATH:-}"-backup
                MOVED_INACCESSIBLE+="${STEAM_COMPAT_SHADER_PATH:-}-backup "
            fi
            for not_owned_by_us in $(find "${STEAM_COMPAT_SHADER_PATH:-}" -maxdepth 1 -type d ! -uid "$(id -u)" 2>/dev/null || true); do
                # If it's a directory it may not be empty, so we can't rm it => move it.
                # Also since we mount the whole dir as is, we cannot just mv
                # the subdirectories since podman wants to lchown the whole dir
                mv "${STEAM_COMPAT_SHADER_PATH:-}" "${STEAM_COMPAT_SHADER_PATH:-}"-backup
                MOVED_INACCESSIBLE+="${STEAM_COMPAT_SHADER_PATH:-}-backup "
                break
            done
        fi
    fi
}

function continue_boot_after_bake()
{
    # Android's package manager owns app-private data. Never replace it with
    # a fresh legacy host directory after installation or repair.
    podman_attach sh -c "setprop ro.lepton.app_baked 1"
}
