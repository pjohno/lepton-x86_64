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

# Build Mesa AMD graphics support for x86_64:
# radeonsi for Gallium and RADV for Vulkan.
BOARD_MESA3D_GALLIUM_DRIVERS := radeonsi
BOARD_MESA3D_VULKAN_DRIVERS := amd
