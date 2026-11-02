use std::process::Command;

#[test]
fn resolves_enabled_launcher_alias_instead_of_target_or_disabled_alias() {
    // LauncherAlias.xml is binary AXML compiled from LauncherAlias.manifest
    // using aapt2 link, then extracting AndroidManifest.xml from the APK.
    let output = Command::new(env!("CARGO_BIN_EXE_apk-info-extractor"))
        .arg("--print-activity-name")
        .arg(concat!(env!("CARGO_MANIFEST_DIR"), "/test/LauncherAlias.xml"))
        .output()
        .unwrap();
    assert!(output.status.success(), "{:?}", output);
    assert_eq!(String::from_utf8(output.stdout).unwrap(), ".Launcher\n");
}
