# SPDX-License-Identifier: Apache-2.0

-include device/waydroid/waydroid/BoardConfig.mk

# Architecture
TARGET_ARCH := x86_64
TARGET_ARCH_VARIANT := x86_64
TARGET_CPU_ABI := x86_64
TARGET_CPU_ABI2 :=

TARGET_2ND_ARCH :=
TARGET_2ND_ARCH_VARIANT :=
TARGET_2ND_CPU_ABI :=
TARGET_2ND_CPU_ABI2 :=
TARGET_2ND_CPU_VARIANT :=

AUDIOSERVER_MULTILIB := first

# Build Mesa AMD and Intel graphics support for x86_64:
# RadeonSI/Iris for Gallium and RADV/ANV for Vulkan.
BOARD_MESA3D_GALLIUM_DRIVERS := radeonsi iris
BOARD_MESA3D_VULKAN_DRIVERS := amd intel

# Iris and ANV compile OpenCL C shaders at build time. Mesa 26 needs host
# mesa_clc and vtn_bindgen2 for that; build-images-x86_64.sh builds them from
# this checkout's Mesa in the Ubuntu 26 builder and puts them on the PATH.
BOARD_MESA3D_MESON_ARGS += -Dmesa-clc=system
