#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# The Lepton workspace layout. Source after .build-env; LEPTON_OUTPUT_DIR is
# the workspace root, and deleting it removes everything the build made:
#   aosp/          Android checkout (with its standard out/)
#   images/        system.img + vendor.img from the latest build
#   rootfs/        packaged rootfs from the latest build
#   stages/<id>/   one per bundle
#   bundles/       finished bundles (.tar.gz, .sha256, .install.sh)
#   logs/          build logs
#   google-inputs/ optional GApps/NDK/Widevine inputs from your Google zip
# Each location can be overridden in .build-env (LEPTON_AOSP_DIR, ...).
lepton_workspace() {
    : "${LEPTON_OUTPUT_DIR:?Set LEPTON_OUTPUT_DIR (the workspace folder) in .build-env}"
    LEPTON_WORKSPACE="$(realpath -m -- "$LEPTON_OUTPUT_DIR")"
    LEPTON_AOSP_DIR="$(realpath -m -- "${LEPTON_AOSP_DIR:-$LEPTON_WORKSPACE/aosp}")"
    LEPTON_LOG_DIR="$(realpath -m -- "${LEPTON_LOG_DIR:-$LEPTON_WORKSPACE/logs}")"
    LEPTON_IMAGES_DIR="$(realpath -m -- "${LEPTON_IMAGES_DIR:-$LEPTON_WORKSPACE/images}")"
    LEPTON_ROOTFS_DIR="$(realpath -m -- "${LEPTON_ROOTFS_DIR:-$LEPTON_WORKSPACE/rootfs}")"
    LEPTON_STAGES_DIR="$(realpath -m -- "${LEPTON_STAGES_DIR:-$LEPTON_WORKSPACE/stages}")"
    LEPTON_DECK_BUNDLE_DIR="$(realpath -m -- "${LEPTON_DECK_BUNDLE_DIR:-$LEPTON_WORKSPACE/bundles}")"
    # Optional Google inputs (prepare-google-inputs.sh writes them here).
    LEPTON_GOOGLE_INPUTS_DIR="$(realpath -m -- "${LEPTON_GOOGLE_INPUTS_DIR:-$LEPTON_WORKSPACE/google-inputs}")"
    if [[ -z "${LEPTON_GOOGLE_IMAGES:-}" && -d "$LEPTON_GOOGLE_INPUTS_DIR/logical-partitions" ]]; then
        LEPTON_GOOGLE_IMAGES="$LEPTON_GOOGLE_INPUTS_DIR/logical-partitions"
    fi
    if [[ -z "${LEPTON_NDK_PAYLOAD:-}" && -d "$LEPTON_GOOGLE_INPUTS_DIR/ndk-translation/payload" ]]; then
        LEPTON_NDK_PAYLOAD="$LEPTON_GOOGLE_INPUTS_DIR/ndk-translation/payload"
    fi
}

# Create the workspace owned by the user's own group and without an inherited
# setgid bit. On a shared folder whose setgid group is not mapped into
# rootless Podman, files with that group make container overlays fail
# ("value too large for defined data type").
lepton_create_workspace() {
    local dir="$1"
    [[ -d "$dir" ]] || mkdir -p -- "$dir" || return 1
    chgrp "$(id -g)" "$dir" && chmod g-s "$dir"
}

# Canonical output path without hiding symlinks in any existing ancestor.
lepton_output_path() {
    local lexical resolved
    lexical="$(realpath -ms -- "$1")" || return 1
    resolved="$(realpath -m -- "$1")" || return 1
    [[ "$lexical" == "$resolved" && ! -L "$lexical" ]] || {
        echo "Output path contains a symlink: $1" >&2; return 1;
    }
    case "$resolved" in
        /|/tmp|/mnt|/media|/home|/opt|/srv|/etc|/etc/*|/usr|/usr/*|/var|/var/*|/run|/run/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/boot|/boot/*)
            echo "Unsafe output path: $resolved" >&2; return 1 ;;
    esac
    [[ "$resolved" != "$HOME" && "$HOME" != "$resolved/"* ]] || {
        echo "Unsafe output path: $resolved" >&2; return 1;
    }
    printf '%s\n' "$resolved"
}
lepton_paths_overlap() {
    [[ "$1" == "$2" || "$1" == "$2/"* || "$2" == "$1/"* ]]
}
lepton_output_outside() {
    local output="$1" protected; shift
    for protected in "$@"; do
        if lepton_paths_overlap "$output" "$protected"; then
            echo "Output overlaps protected path: $output ($protected)" >&2; return 1
        fi
    done
}
