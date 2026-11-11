#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# One transaction used by both compilation and packaging-only recovery.
lepton_package_images() (
    set -Eeuo pipefail
    local product="$TARGET/out/target/product/lepton_x86_64" part entries
    local images_work root_work images_new root_new images_backup root_backup
    local promotion_started=false committed=false
    local hwc="$product/vendor/lib64/hw/hwcomposer.waydroid.so"
    python3 "$ROOT/image-14/scripts/internal/validate-android-images.py" "$product/system.img" "$product/vendor.img"
    if [[ "$ISOLATED" == true ]]; then
        [[ -s "$hwc" ]] && grep -aFq 'Lepton local configure:' "$hwc" ||
            { echo '[FAIL] Compiled hwcomposer is missing/stale; no outputs replaced' >&2; exit 1; }
    fi
    lepton_output_path "$LEPTON_IMAGES_DIR" >/dev/null
    lepton_output_path "$LEPTON_ROOTFS_DIR" >/dev/null
    for part in "$LEPTON_IMAGES_DIR" "$LEPTON_ROOTFS_DIR"; do
        if [[ -e "$part" || -L "$part" ]]; then
            [[ "$ISOLATED" == false && -d "$part" && ! -L "$part" && -O "$part" ]] ||
                { echo "[FAIL] Unsafe or newly appeared output: $part" >&2; exit 1; }
            # Refuse unrelated nonempty directories even when owned by this
            # user. Empty output directories from an earlier attempt are safe.
            entries="$(find "$part" -mindepth 1 -maxdepth 1 -print -quit)" ||
                { echo "[FAIL] Cannot safely inspect existing output directory: $part" >&2; exit 1; }
            if [[ -n "$entries" ]]; then
                if [[ "$part" == "$LEPTON_IMAGES_DIR" ]]; then
                    [[ -s "$part/system.img" && -s "$part/vendor.img" && -f "$part/SHA256SUMS" ]] ||
                        { echo "[FAIL] Existing image directory is not a recognized packaged output: $part" >&2; exit 1; }
                else
                    [[ -s "$part/system/build.prop" && -f "$part/vendor/lib64/hw/vulkan.radeon.so" ]] ||
                        { echo "[FAIL] Existing rootfs directory is not a recognized packaged output: $part" >&2; exit 1; }
                fi
            fi
        fi
    done
    # Never garbage-collect another invocation's tree: it may contain a mount
    # or the only previous valid outputs after SIGKILL/power loss.
    for part in "$(dirname -- "$LEPTON_IMAGES_DIR")"/.lepton-image-package.* "$(dirname -- "$LEPTON_ROOTFS_DIR")"/.lepton-rootfs-package.*; do
        [[ ! -d "$part" ]] || info "[WARN] Prior packaging directory retained for inspection: $part"
    done
    mkdir -p -- "$(dirname -- "$LEPTON_IMAGES_DIR")" "$(dirname -- "$LEPTON_ROOTFS_DIR")"
    images_work="$(mktemp -d "$(dirname -- "$LEPTON_IMAGES_DIR")/.lepton-image-package.XXXXXXXX")"
    root_work=''
    cleanup_image_package() {
        local status=$?
        trap - EXIT
        if [[ "$committed" != true && "$promotion_started" == true ]]; then
            # Infer rename completion from directory existence, so a signal
            # between mv and the next shell statement cannot skip rollback.
            if [[ ! -e "$images_new" && -e "$LEPTON_IMAGES_DIR" ]]; then mv -T -- "$LEPTON_IMAGES_DIR" "$images_new" || status=1; fi
            if [[ -e "$images_backup" ]]; then mv -T -- "$images_backup" "$LEPTON_IMAGES_DIR" || status=1; fi
            if [[ ! -e "$root_new" && -e "$LEPTON_ROOTFS_DIR" ]]; then mv -T -- "$LEPTON_ROOTFS_DIR" "$root_new" || status=1; fi
            if [[ -e "$root_backup" ]]; then mv -T -- "$root_backup" "$LEPTON_ROOTFS_DIR" || status=1; fi
        fi
        # A failed rollback leaves backups for manual recovery, never deletes them.
        if [[ -e "${images_backup:-/nonexistent}" || -e "${root_backup:-/nonexistent}" ]] && [[ "$committed" != true ]]; then
            echo "[FAIL] Rollback incomplete; backups retained: $images_work $root_work" >&2
            exit 1
        fi
        # Completed outputs remain valid even if obsolete backup cleanup fails.
        lepton_remove_packaging_tree "$images_work" || echo "[WARN] Temporary images retained: $images_work" >&2
        [[ -z "$root_work" ]] || lepton_remove_packaging_tree "$root_work" || echo "[WARN] Temporary rootfs retained: $root_work" >&2
        exit "$status"
    }
    trap cleanup_image_package EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    root_work="$(mktemp -d "$(dirname -- "$LEPTON_ROOTFS_DIR")/.lepton-rootfs-package.XXXXXXXX")"
    images_new="$images_work/images"; root_new="$root_work/rootfs"
    images_backup="$images_work/previous-images"; root_backup="$root_work/previous-rootfs"
    printf 'Outputs: %s and %s\nPrevious outputs, if present: previous-images / previous-rootfs in the respective temporary trees.\n' "$LEPTON_IMAGES_DIR" "$LEPTON_ROOTFS_DIR" > "$images_work/RECOVERY.txt"
    cp -- "$images_work/RECOVERY.txt" "$root_work/RECOVERY.txt"
    mkdir "$images_new"
    (cd "$product" && sha256sum system.img vendor.img) > "$images_work/source.sha256"
    for part in system vendor; do
        cp --sparse=always -- "$product/$part.img" "$images_new/.$part.img.new"
        mv -- "$images_new/.$part.img.new" "$images_new/$part.img"
    done
    (cd "$images_new" && sha256sum --check "$images_work/source.sha256")
    cp -- "$images_work/source.sha256" "$images_new/SHA256SUMS"
    info "[START] Packaging rootfs into $root_new (previous outputs preserved)"
    bash "$ROOT/image-14/scripts/internal/package-repro-rootfs.sh" "$TARGET" "$root_new"
    # Detect an out-of-band compiler modifying the source images while packaging.
    (cd "$product" && sha256sum --check "$images_work/source.sha256")
    if [[ "$ISOLATED" == true ]]; then
        cmp -s "$hwc" "$root_new/vendor/lib64/hw/hwcomposer.waydroid.so" ||
            { echo '[FAIL] Vendor image hwcomposer differs from compiled artifact' >&2; exit 1; }
    fi
    source "$ROOT/image-14/scripts/lib/image-provenance.sh"
    image_provenance_write "$ROOT" "$TARGET" "$root_new" "$images_new/BUILD-INFO.txt"
    for part in system vendor; do
        printf '%s image SHA256: %s\n' "$part" "$(sha256sum "$images_new/$part.img" | cut -d' ' -f1)" >> "$images_new/BUILD-INFO.txt"
    done
    cp -- "$images_new/BUILD-INFO.txt" "$root_new/.lepton-image-provenance"
    # Both complete directories are promoted by rename on their own filesystem.
    # Two destinations cannot be swapped in one atomic operation; backups plus
    # the trap provide rollback for failures/signals between these renames.
    lepton_output_path "$LEPTON_IMAGES_DIR" >/dev/null
    lepton_output_path "$LEPTON_ROOTFS_DIR" >/dev/null
    for part in "$LEPTON_IMAGES_DIR" "$LEPTON_ROOTFS_DIR"; do
        if [[ -e "$part" || -L "$part" ]]; then
            [[ "$ISOLATED" == false && -d "$part" && ! -L "$part" && -O "$part" ]] ||
                { echo "[FAIL] Output changed during packaging: $part" >&2; exit 1; }
        fi
    done
    promotion_started=true
    if [[ -e "$LEPTON_ROOTFS_DIR" ]]; then mv -T -- "$LEPTON_ROOTFS_DIR" "$root_backup"; fi
    mv -T -- "$root_new" "$LEPTON_ROOTFS_DIR"
    if [[ -e "$LEPTON_IMAGES_DIR" ]]; then mv -T -- "$LEPTON_IMAGES_DIR" "$images_backup"; fi
    mv -T -- "$images_new" "$LEPTON_IMAGES_DIR"
    committed=true
    sed 's/^/[INFO]   /' "$LEPTON_IMAGES_DIR/BUILD-INFO.txt"
)
