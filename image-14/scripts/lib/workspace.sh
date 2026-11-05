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
