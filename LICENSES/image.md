The Lepton AOSP image uses source code from the following opensource projects with their own licenses:

* Android Opensource Project: https://source.android.com/docs/setup/about/licenses
* Waydroid device and hardware configurations:
    - https://github.com/waydroid/android_vendor_waydroid/tree/lineage-18.1/LICENSES
    - https://github.com/waydroid/android_hardware_waydroid http://www.apache.org/licenses/LICENSE-2.0
    - https://github.com/waydroid/android_device_waydroid_waydroid/tree/lineage-18.1 http://www.apache.org/licenses/LICENSE-2.0
    - Lepton includes patches from Waydroid which originate from the Anbox, Halium or Hybris projects.
* Boringdroid: https://github.com/boringdroid/boringdroid/blob/master/LICENSE
* LineageOS: Licenses can be found in the individual repositories under: https://github.com/LineageOS
* Hardware video decoding (Android 14 x86_64 image; sources pinned in
  `image-14/manifests-34/20-video-vaapi.xml` and `21-video-intel-ihd.xml`, Lepton's changes in
  `image-14/patches/0017`–`0030`):
    - FFmpeg (`external/ffmpeg`, shared libraries built with `CONFIG_GPL`, `CONFIG_NONFREE` and
      `CONFIG_VERSION3` off): LGPL-2.1-or-later, https://ffmpeg.org/legal.html. Its source, as
      built, is the pinned project plus patch 0017.
    - Codec2 FFmpeg service (`external/stagefright-plugins`, Michael Goffioul, the Android-x86
      project and BlissLabs): Apache-2.0
    - libva (`external/libva`): MIT
    - Intel i965 VA driver (`external/intel-vaapi-driver`): MIT
    - Intel Media Driver (`external/intel-media-driver`, free kernels only) and gmmlib
      (`external/gmmlib`): MIT
    - Mesa's VA-API frontend (part of `external/mesa`, already in the image): MIT

The AOSP image, as a product of the combination of these opensource projects, is released under a GPL-3.0 license.
The GPL-3.0 license text can be read here: https://www.gnu.org/licenses/gpl-3.0.html