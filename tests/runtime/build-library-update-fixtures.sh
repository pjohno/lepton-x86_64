#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build disposable, signed APK and APKM pairs for PENDING_TESTS.md.
set -euo pipefail
if [[ $# != 2 ]]; then
    echo "Usage: $0 SDK_PLATFORM/android.jar NEW_OUTPUT_DIRECTORY" >&2
    exit 2
fi
sdk="${LEPTON_ANDROID_BUILD_TOOLS:?Set LEPTON_ANDROID_BUILD_TOOLS to Android SDK Build Tools}"
android_jar="$(realpath -e -- "$1")"
out="$(realpath -m -- "$2")"
mkdir -- "$out"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
package=org.lepton.updatefixture

cat > "$work/Probe.java" <<'JAVA'
package org.lepton.updatefixture;

import android.app.Activity;
import android.os.Bundle;
import android.content.SharedPreferences;
import android.util.Log;
import android.widget.TextView;

public final class Probe extends Activity {
    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        SharedPreferences settings = getSharedPreferences("probe", MODE_PRIVATE);
        int count = settings.getInt("launches", 0) + 1;
        if (!settings.edit().putInt("launches", count).commit()) {
            throw new IllegalStateException("Could not save launch count");
        }
        String message = "Version " + BuildVersion.NUMBER + ", launch count " + count;
        Log.i("LeptonUpdateFixture", message);
        TextView text = new TextView(this);
        text.setTextSize(24);
        text.setText(message);
        setContentView(text);
    }
}
JAVA
for key in fixture other; do
    keytool -genkeypair -keystore "$work/$key.jks" -storepass test-only -keypass test-only \
        -alias "$key" -dname "CN=Lepton library fixture $key" -keyalg RSA -keysize 2048 -validity 3650 >/dev/null 2>&1
done
sign() {
    "$sdk/apksigner" sign --ks "$work/$1.jks" --ks-pass pass:test-only --key-pass pass:test-only \
        --out "$3" "$2"
}

for version in 1 2; do
    build="$work/$version"
    mkdir -p "$build/classes" "$build/dex" "$build/apkm"
    printf 'package %s; final class BuildVersion { static final int NUMBER = %s; }\n' \
        "$package" "$version" > "$build/BuildVersion.java"
    javac --release 8 -classpath "$android_jar" -d "$build/classes" "$work/Probe.java" "$build/BuildVersion.java"
    "$sdk/d8" --lib "$android_jar" --output "$build/dex" "$build/classes/org/lepton/updatefixture/"*.class
    cat > "$build/AndroidManifest.xml" <<XML
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
          package="$package" android:versionCode="$version" android:versionName="$version">
    <uses-sdk android:minSdkVersion="23" android:targetSdkVersion="32" />
    <application android:label="Lepton Update Fixture">
        <activity android:name=".Probe" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
XML
    "$sdk/aapt2" link -I "$android_jar" --manifest "$build/AndroidManifest.xml" -o "$build/unsigned.apk"
    (cd "$build/dex"; zip -q -u "$build/unsigned.apk" classes.dex)
    sign fixture "$build/unsigned.apk" "$out/v$version.apk"
    cp "$out/v$version.apk" "$build/apkm/base.apk"
    sed -n '1,3p' "$build/AndroidManifest.xml" | sed 's/package=/split="feature" android:isFeatureSplit="true" package=/' > "$build/Split.xml"
    printf '    <application android:hasCode="false" />\n</manifest>\n' >> "$build/Split.xml"
    "$sdk/aapt2" link -I "$android_jar" --manifest "$build/Split.xml" -o "$build/split.apk"
    sign fixture "$build/split.apk" "$build/apkm/split_feature.apk"
    (cd "$build/apkm"; zip -q "$out/v$version.apkm" base.apk split_feature.apk)
done
sign other "$work/2/unsigned.apk" "$out/wrong-key.apk"
sed -e 's/versionCode="2"/versionCode="3"/' -e 's/minSdkVersion="23"/minSdkVersion="35"/' \
    -e 's/targetSdkVersion="32"/targetSdkVersion="35"/' "$work/2/AndroidManifest.xml" > "$work/TooNew.xml"
"$sdk/aapt2" link -I "$android_jar" --manifest "$work/TooNew.xml" -o "$work/too-new.apk"
(cd "$work/2/dex"; zip -q -u "$work/too-new.apk" classes.dex)
sign fixture "$work/too-new.apk" "$out/too-new.apk"
"$sdk/apksigner" rotate --out "$work/lineage" \
    --old-signer --ks "$work/fixture.jks" --ks-pass pass:test-only \
    --new-signer --ks "$work/other.jks" --ks-pass pass:test-only
"$sdk/apksigner" sign --lineage "$work/lineage" --rotation-min-sdk-version 33 \
    --ks "$work/fixture.jks" --ks-pass pass:test-only --next-signer \
    --ks "$work/other.jks" --ks-pass pass:test-only --out "$out/rotated-v2.apk" "$work/2/unsigned.apk"
printf 'Created signed APK, APKM, wrong-key, rotation and newer-SDK fixtures in %s\n' "$out"
