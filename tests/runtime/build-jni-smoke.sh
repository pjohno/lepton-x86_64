#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build a minimal JNI smoke-test APK using an existing Android 14 AOSP checkout.
# No AOSP rebuild; no rootfs or Lepton stage modifications.
set -Eeuo pipefail

usage() {
    cat <<'USAGE'
Usage: bash tests/runtime/build-jni-smoke.sh --aosp /absolute/aosp-checkout \
       --abi x86_64|arm64-v8a --output /absolute/new-test.apk

Produces an APK with Java Activity and exactly one architecture's JNI library.
Logs LEPTON_JNI_SMOKE_PASS value=42 or LEPTON_JNI_SMOKE_FAIL.
Add --media-smoke to also enumerate codecs, decode generated H.264/Vorbis clips,
and loop a video surface test. This additionally requires host ffmpeg with
libx264 and libvorbis; no downloads or external media are used.
Requires the Android 14 AOSP checkout's JDK17, aapt2, d8, Clang, signapk,
and test keys, plus host zip/unzip/readelf.
Never installs or launches the APK. Refuses to overwrite output.
If the APK is placed inside the AOSP checkout, its output must be under
native-bridge-research/, not inside source or compiled output trees.
USAGE
}
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
AOSP='' ABI='' OUTPUT='' MEDIA_SMOKE=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
while (($#)); do
    case "$1" in
        --media-smoke) MEDIA_SMOKE=true; shift ;;
        --aosp) (($# >= 2)) || fail 'missing --aosp value'; AOSP="$2"; shift 2 ;;
        --abi) (($# >= 2)) || fail 'missing --abi value'; ABI="$2"; shift 2 ;;
        --output) (($# >= 2)) || fail 'missing --output value'; OUTPUT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "unknown option: $1" ;;
    esac
done
[[ "$ABI" == x86_64 || "$ABI" == arm64-v8a ]] || fail 'ABI must be x86_64 or arm64-v8a'
[[ -n "$AOSP" && -n "$OUTPUT" ]] || { usage >&2; exit 2; }
[[ "$AOSP" == /* && "$OUTPUT" == /* ]] || fail 'Both paths must be absolute'
[[ -d "$AOSP" ]] || fail "AOSP directory missing: $AOSP"
AOSP="$(realpath -e -- "$AOSP")"
OUTPUT="$(realpath -m -- "$OUTPUT")"
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || fail "Refusing to overwrite $OUTPUT"
[[ -d "$(dirname "$OUTPUT")" ]] || fail 'Output parent directory does not exist'
# The project's disposable research directory deliberately lives inside the
# AOSP checkout. Permit artifacts there, but protect all AOSP source/build
# paths from accidental outputs. realpath -m above resolves path components.
case "$OUTPUT" in
    "$AOSP"/native-bridge-research/*)
        [[ -d "$AOSP/native-bridge-research" && ! -L "$AOSP/native-bridge-research" ]] ||
            fail 'Research directory must be a real directory'
        ;;
    "$AOSP"/*) fail 'Output inside AOSP must be under native-bridge-research/' ;;
esac
for tool in zip unzip readelf mktemp; do command -v "$tool" >/dev/null || fail "Missing host tool: $tool"; done
JDK="$AOSP/prebuilts/jdk/jdk17/linux-x86"
AAPT2="$AOSP/out/host/linux-x86/bin/aapt2"
D8="$AOSP/out/host/linux-x86/bin/d8"
ZIPALIGN="$AOSP/out/host/linux-x86/bin/zipalign"
SIGNAPK="$AOSP/out/host/linux-x86/framework/signapk.jar"
ANDROIDJAR="$AOSP/prebuilts/sdk/34/public/android.jar"
KEYS="$AOSP/build/target/product/security"
# signapk.jar uses a native Conscrypt JNI library built for the Linux host.
# This is separate from the Android JNI library being tested.
SIGNAPK_NATIVE_DIR="$AOSP/out/host/linux-x86/lib64"
if [[ ! -f "$SIGNAPK_NATIVE_DIR/libconscrypt_openjdk_jni.so" ]]; then
    alt="$AOSP/out/soong/host/linux-x86/lib64"
    if [[ -f "$alt/libconscrypt_openjdk_jni.so" ]]; then
        SIGNAPK_NATIVE_DIR="$alt"
    else
        fail "AOSP host signing library missing: libconscrypt_openjdk_jni.so (checked $SIGNAPK_NATIVE_DIR and $alt)"
    fi
fi
CLANG="$AOSP/prebuilts/clang/host/linux-x86/clang-r510928/bin/clang"
for f in "$JDK/bin/java" "$JDK/bin/javac" "$AAPT2" "$D8" "$ZIPALIGN" "$SIGNAPK" "$ANDROIDJAR" "$KEYS/testkey.x509.pem" "$KEYS/testkey.pk8" "$CLANG"; do
    [[ -f "$f" ]] || fail "Missing AOSP tool: $f"
done
[[ -x "$JDK/bin/javac" && -x "$CLANG" ]] || fail 'JDK / Clang not executable'
case "$ABI" in
    x86_64) TRIPLE=x86_64-linux-android34; MACHINE='Advanced Micro Devices X86-64' ;;
    arm64-v8a) TRIPLE=aarch64-linux-android34; MACHINE='AArch64' ;;
esac
TMP="$(mktemp -d "$(dirname "$OUTPUT")/.jni-smoke.XXXXXXXX")"
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/assets" "$TMP/src/org/lepton/smoke" "$TMP/classes" "$TMP/dex" "$TMP/apk/lib/$ABI"
cat > "$TMP/AndroidManifest.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="org.lepton.smoke">
    <uses-sdk android:minSdkVersion="26" android:targetSdkVersion="28" />
    <application android:label="Lepton JNI Smoke" android:hasCode="true"
        android:theme="@android:style/Theme.Material.Light.NoActionBar">
        <activity android:name=".MainActivity" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
XML
cat > "$TMP/src/org/lepton/smoke/MainActivity.java" <<'JAVA'
package org.lepton.smoke;

import android.app.Activity;
import android.os.Bundle;
import android.os.Build;
import android.util.Log;
import android.widget.TextView;
import java.util.Arrays;

public final class MainActivity extends Activity {
    private static final String TAG = "LeptonJniSmoke";
    private static native int nativeCompute();

    @Override public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        String result;
        try {
            Log.i(TAG, "Supported ABIs: " + Arrays.toString(Build.SUPPORTED_ABIS));
            System.loadLibrary("leptonjni");
            int value = nativeCompute();
            result = value == 42 ? "LEPTON_JNI_SMOKE_PASS value=42" :
                "LEPTON_JNI_SMOKE_FAIL wrong_value=" + value;
        } catch (Throwable t) {
            result = "LEPTON_JNI_SMOKE_FAIL " + t.toString();
            Log.e(TAG, result, t);
        }
        Log.i(TAG, result);
        TextView view = new TextView(this);
        view.setTextSize(23);
        view.setText(result + "\nSupported ABIs: " + Arrays.toString(Build.SUPPORTED_ABIS));
        setContentView(view);
    }
}
JAVA
cat > "$TMP/jni.c" <<'C'
/* JNI ABI: JNIEnv*, jclass are opaque pointers, return type jint is int. */
__attribute__((visibility("default")))
int Java_org_lepton_smoke_MainActivity_nativeCompute(void *env, void *clazz)
{
    (void)env;
    (void)clazz;
    volatile int factor = 6;  /* Stop the compiler precomputing the result. */
    int result = 0;
    for (int i = 0; i < 7; i++) result += factor;
    return result;
}
C
export JAVA_HOME="$JDK"
export PATH="$JDK/bin:$PATH"
echo "[INFO] Compiling JNI for $ABI ($TRIPLE)"
"$CLANG" --target="$TRIPLE" -fPIC -shared -nostdlib -fvisibility=hidden \
    -Wl,-soname,libleptonjni.so -o "$TMP/apk/lib/$ABI/libleptonjni.so" "$TMP/jni.c"
readelf -h "$TMP/apk/lib/$ABI/libleptonjni.so" | grep -Fq "$MACHINE" || fail 'Unexpected JNI architecture'
if [[ "$MEDIA_SMOKE" == true ]]; then
    command -v ffmpeg >/dev/null || fail 'Media probe requires ffmpeg'
    mkdir -p "$TMP/assets"
    ffmpeg -v error -f lavfi -i testsrc2=size=160x120:rate=15 -t 2 \
        -c:v libx264 -pix_fmt yuv420p -an "$TMP/assets/probe.mp4"
    ffmpeg -v error -f lavfi -i sine=frequency=440:sample_rate=44100 -t 1 \
        -c:a libvorbis "$TMP/assets/probe.ogg"
    cp "$SCRIPT_DIR/media-smoke/MediaProbe.java" "$TMP/src/org/lepton/smoke/"
    sed -i '/        setContentView(view);/a\        MediaProbe.start(this);' \
        "$TMP/src/org/lepton/smoke/MainActivity.java"
fi
echo '[INFO] Compiling Java and classes.dex'
"$JDK/bin/javac" -source 8 -target 8 -encoding UTF-8 -classpath "$ANDROIDJAR" \
    -d "$TMP/classes" "$TMP/src/org/lepton/smoke/"*.java
"$D8" --release --min-api 26 --lib "$ANDROIDJAR" --output "$TMP/dex" \
    "$TMP/classes/org/lepton/smoke/"*.class
[[ -s "$TMP/dex/classes.dex" ]] || fail 'D8 failed to produce classes.dex'
echo '[INFO] Linking, aligning and signing APK'
"$AAPT2" link -o "$TMP/apk/unsigned.apk" -I "$ANDROIDJAR" \
    --manifest "$TMP/AndroidManifest.xml" -A "$TMP/assets" --min-sdk-version 26 --target-sdk-version 28
(
    cd "$TMP/apk"
    zip -q -j unsigned.apk "$TMP/dex/classes.dex"
    zip -q -0 unsigned.apk "lib/$ABI/libleptonjni.so"
    if [[ "$MEDIA_SMOKE" == true ]]; then
        # AssetFileDescriptor requires uncompressed sample assets.
        cp -a "$TMP/assets" .
        zip -q -0 unsigned.apk assets/probe.mp4 assets/probe.ogg
    fi
)
"$ZIPALIGN" -f 4 "$TMP/apk/unsigned.apk" "$TMP/apk/aligned.apk"
# The caller's Fedora LD_LIBRARY_PATH/JAVA_TOOL_OPTIONS may contain unrelated
# libraries. Use only AOSP's matching host JNI directory for signing.
env -u LD_PRELOAD -u JAVA_TOOL_OPTIONS -u _JAVA_OPTIONS -u JDK_JAVA_OPTIONS \
    -u CLASSPATH LD_LIBRARY_PATH="$SIGNAPK_NATIVE_DIR" \
    "$JDK/bin/java" -Djava.library.path="$SIGNAPK_NATIVE_DIR" \
    -jar "$SIGNAPK" "$KEYS/testkey.x509.pem" "$KEYS/testkey.pk8" \
    "$TMP/apk/aligned.apk" "$TMP/signed.apk"
[[ -s "$TMP/signed.apk" ]] || fail 'Signed APK missing'
# Capture complete ZIP listings BEFORE testing entries. With `set -o pipefail`,
# `unzip -Z1 ... | grep -q` can incorrectly fail if grep closes its pipe
# early (SIGPIPE). Retain the listings long enough to diagnose real omissions.
for phase in unsigned aligned signed; do
    if [[ "$phase" == signed ]]; then
        apk="$TMP/signed.apk"
    else
        apk="$TMP/apk/${phase}.apk"
    fi
    unzip -tqq "$apk" || fail "Invalid $phase APK ZIP archive"
done
unzip -Z1 "$TMP/apk/unsigned.apk" > "$TMP/unsigned-entries.txt"
unzip -Z1 "$TMP/apk/aligned.apk" > "$TMP/aligned-entries.txt"
unzip -Z1 "$TMP/signed.apk" > "$TMP/signed-entries.txt"
for phase in unsigned aligned signed; do
    if [[ "$phase" == signed ]]; then
        entries="$TMP/signed-entries.txt"
    else
        entries="$TMP/${phase}-entries.txt"
    fi
    if ! grep -Fxq -- "lib/$ABI/libleptonjni.so" "$entries"; then
        printf '[ERROR] %s APK entries:\n' "$phase" >&2
        cat "$entries" >&2
        fail "JNI library missing in $phase APK"
    fi
    if ! grep -Fxq -- 'classes.dex' "$entries"; then
        printf '[ERROR] %s APK entries:\n' "$phase" >&2
        cat "$entries" >&2
        fail "Dex missing in $phase APK"
    fi
done
cp -- "$TMP/signed.apk" "$OUTPUT"
echo "[PASS] $ABI JNI test APK: $OUTPUT"
if [[ "$MEDIA_SMOKE" == true ]]; then
    echo '[INFO] Also requires LEPTON_MEDIA_SMOKE_PASS and LEPTON_MEDIA_VIDEO_RENDERING_START; run with --media-smoke --codec2'
fi
echo '[INFO] Package: org.lepton.smoke; launch: org.lepton.smoke/.MainActivity'
echo '[INFO] Logcat tag: LeptonJniSmoke; expected: LEPTON_JNI_SMOKE_PASS value=42'
