#!/bin/bash

CI_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="${CI_DIR}/../"

"${PROJECT_DIR}/image-14/.buildscripts/package_rootfs.sh"

mkdir -p install-rootfs/images/rootfs
cp -ra "${PROJECT_DIR}"/compat_tool/images/rootfs/* install-rootfs/images/rootfs

# Lepton x86_64: ensure Binder devices exist before Android services start.
# Leave other architectures unchanged.
if grep -Eq '^ro.product.cpu.abi=x86_64$|^ro.product.cpu.abilist=x86_64([,]|$)'     install-rootfs/images/rootfs/system/build.prop; then
    "${PROJECT_DIR}/image-14/scripts/internal/patch-binderfs-init.sh"         install-rootfs/images/rootfs
fi
cp -ra "${PROJECT_DIR}"/compat_tool/images/NOTICE.txt install-rootfs/images
cp -ra "${PROJECT_DIR}"/image-14/version.txt install-rootfs/images

tar --zstd -cf "${PROJECT_DIR}"/rootfs.tar.zst -C install-rootfs .
