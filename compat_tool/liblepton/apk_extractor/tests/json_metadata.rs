use std::process::Command;

// Fixtures are binary AXML compiled from the matching test/*.manifest with
// aapt2 link -I android.jar (API 34), then extracted from the APK.
fn json(name: &str) -> String {
    let output = Command::new(env!("CARGO_BIN_EXE_apk-info-extractor"))
        .arg("--json")
        .arg(format!("{}/test/{}", env!("CARGO_MANIFEST_DIR"), name))
        .output()
        .unwrap();
    assert!(output.status.success(), "{:?}", output);
    String::from_utf8(output.stdout).unwrap()
}

#[test]
fn long_version_code_follows_android_composition() {
    // versionCode="-1" is the unsigned low word; versionCodeMajor is signed.
    let top = json("VersionNegative.xml");
    assert!(top.contains("\"version_code\": 4294967295,"), "{}", top);
    assert!(top.contains("\"version_code_major\": 2147483647,"), "{}", top);
    assert!(top.contains("\"long_version_code\": 9223372036854775807,"), "{}", top);
    // aapt2 stores "0x10" as TYPE_INT_HEX; a negative major gives a negative
    // long version code, as PackageInfo.composeLongVersionCode() does.
    let hex = json("VersionHex.xml");
    assert!(hex.contains("\"version_code\": 16,"), "{}", hex);
    assert!(hex.contains("\"version_code_major\": -1,"), "{}", hex);
    assert!(hex.contains("\"long_version_code\": -4294967280,"), "{}", hex);
    assert!(hex.contains("\"version_name\": \"v \\\"VersionHex\\\"\","), "{}", hex);
    assert!(hex.contains("\"label\": \"Boundary \\\\ Test\","), "{}", hex);
    assert!(hex.contains("\"min_sdk\": 24,"), "{}", hex);
}

#[test]
fn configuration_split_without_application_metadata() {
    let split = json("SplitConfig.xml");
    assert!(split.contains("\"split\": \"config.arm64_v8a\","), "{}", split);
    assert!(split.contains("\"min_sdk\": null,"), "{}", split);
    assert!(split.contains("\"launchable_activity\": null,"), "{}", split);
    assert!(split.contains("\"label\": null,"), "{}", split);
}

#[test]
fn resource_label_is_unknown_and_launcher_is_reported() {
    let app = json("LauncherAlias.xml");
    assert!(app.contains("\"launchable_activity\": \".Launcher\","), "{}", app);
    assert!(app.contains("\"split\": null,"), "{}", app);
}

#[test]
fn json_is_exclusive_with_print_options() {
    let output = Command::new(env!("CARGO_BIN_EXE_apk-info-extractor"))
        .args(["--json", "--print-app-id"])
        .arg(concat!(env!("CARGO_MANIFEST_DIR"), "/test/LauncherAlias.xml"))
        .output()
        .unwrap();
    assert!(!output.status.success());
}
