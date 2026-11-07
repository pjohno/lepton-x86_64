# SPDX-License-Identifier: Apache-2.0

# Inherit from those products. Most specific first.
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit_only.mk)

# Inherit from waydroid device
$(call inherit-product, $(LOCAL_PATH)/../device.mk)

PRODUCT_BRAND := Linux-PC
PRODUCT_DEVICE := lepton_x86_64
PRODUCT_MANUFACTURER := Lepton
PRODUCT_NAME := lineage_lepton_x86_64
PRODUCT_MODEL := Lepton x86_64 Device
