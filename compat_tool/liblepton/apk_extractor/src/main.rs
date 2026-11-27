use std::fs::File;
use std::io::Read;
use zip::result::ZipError;
use zip::ZipArchive;
use axmldecoder::{Element, Node};
use clap::{Arg, Command};

fn peel_element(n: &Node) -> Result<&Element, String> {
    match n {
        Node::Element(n) => return Ok(n),
        Node::Cdata(n) => Err(format!("Expected Element, found Cdata in {:?}", n)),
    }
}

fn filter_children<'a>(node: &'a Node, name: &'a str) -> Result<impl Iterator<Item = &'a Node>, String> {
    let node = peel_element(node)?;
    return Ok(node.get_children()
                  .iter()
                  .filter(move |n| match n {
                      Node::Element(e) => e.get_tag() == name,
                      Node::Cdata(_) => false,
                  }))
}

fn only_child<'a>(node: &'a Node, name: &'a str) -> Result<&'a Node, String> {
    let mut iter = filter_children(node, name)?;
    match (iter.next(), iter.next()) {
        (Some(first), None) => Ok(first),
        (None, _) => Err(format!("Expected one <{}> child, found none", name)),
        (Some(_), Some(_)) => Err(format!("Expected one <{}> child, found multiple", name)),
    }
}

fn read_xml(file_path: &str, abis: &mut Vec<String>) -> Result<Vec<u8>, ZipError> {
    let file = File::open(file_path)?;
    let mut manifest_data = Vec::new();
    // First, try to load it as a `.zip`
    match ZipArchive::new(file) {
        Ok(mut zip) => {
            // Native libraries are lib/<abi>/<name>.so entries.
            for name in zip.file_names() {
                let parts: Vec<&str> = name.split('/').collect();
                if parts.len() == 3 && parts[0] == "lib" && !parts[1].is_empty() && parts[2].ends_with(".so")
                        && !abis.iter().any(|abi| abi == parts[1]) {
                    abis.push(parts[1].to_string());
                }
            }
            abis.sort();
            let mut manifest_file = zip.by_name("AndroidManifest.xml")?;
            manifest_file.read_to_end(&mut manifest_data)?;
        }
        Err(e) => {
            // If it's not a `.zip` file, if the filename ends in `.xml`, just read it in:
            if !file_path.ends_with(".xml") {
                return Err(e.into());
            }
            let mut file = File::open(file_path)?;
            file.read_to_end(&mut manifest_data)?;
        }
    };
    return Ok(manifest_data);
}

// axmldecoder 0.5 renders TYPE_INT_DEC as the unsigned 32-bit value and
// TYPE_INT_HEX as "0x" followed by the *decimal* digits of the same value.
// Both carry the raw 32-bit word, so read either form as that word.
fn int_word(value: &str) -> Option<u32> {
    value.strip_prefix("0x").unwrap_or(value).parse::<u32>().ok()
}

// A literal string attribute. Resource references and other typed values are
// rendered as "ResourceValueType::<kind>/<data>" and resolving them would need
// resources.arsc, so they are reported as unknown.
fn literal(value: Option<&String>) -> Option<&str> {
    value.map(String::as_str).filter(|v| !v.starts_with("ResourceValueType::"))
}

fn json_string(value: Option<&str>) -> String {
    let value = match value {
        Some(value) => value,
        None => return "null".to_string(),
    };
    let mut out = String::from("\"");
    for c in value.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn json_number<T: std::fmt::Display>(value: Option<T>) -> String {
    value.map_or("null".to_string(), |v| v.to_string())
}

fn json_bool(value: Option<&String>) -> String {
    match value.map(String::as_str) {
        Some("true") => "true".to_string(),
        Some("false") => "false".to_string(),
        _ => "null".to_string(),
    }
}

fn vprint(msg: String, verbose: bool) {
    if verbose {
        println!("{}", msg);
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Define the CLI
    let matches = Command::new("apk-info-extractor")
        .version("1.0")
        .about("Extracts information from the AndroidManifest.xml in .apk files")
        .arg(
            Arg::new("apk")
                .help("Path to the APK file")
                .required(true)
                .index(1),
        )
        .arg(
            Arg::new("print-app-id")
                 .long("print-app-id")
                 .help("Print the app id")
                 .action(clap::ArgAction::SetTrue),
        )
        .arg(
            Arg::new("print-activity-name")
                 .long("print-activity-name")
                 .help("Print the activity name")
                 .action(clap::ArgAction::SetTrue)
        )
        .arg(
            Arg::new("print-app-version")
                 .long("print-app-version")
                 .help("Print the app version")
                 .action(clap::ArgAction::SetTrue)
        )
        .arg(
            Arg::new("print-min-sdk-version")
                 .long("print-min-sdk-version")
                 .help("Print the minimum sdk version")
                 .action(clap::ArgAction::SetTrue)
        )
        .arg(
            Arg::new("json")
                 .long("json")
                 .help("Print package metadata as one JSON object (also for split APKs)")
                 .action(clap::ArgAction::SetTrue)
        )
        .arg(
            Arg::new("verbose")
                .short('v')
                .long("verbose")
                .help("Enable verbose output")
                .action(clap::ArgAction::SetTrue)
        )
        .get_matches();

    let apk_path = matches.get_one::<String>("apk").unwrap();
    let print_app_id = matches.get_flag("print-app-id");
    let print_activity_name = matches.get_flag("print-activity-name");
    let print_app_version = matches.get_flag("print-app-version");
    let print_min_sdk_version = matches.get_flag("print-min-sdk-version");
    let verbose = matches.get_flag("verbose");
    let json = matches.get_flag("json");

    if json && (print_activity_name || print_app_id || print_app_version || print_min_sdk_version) {
        return Err("--json cannot be combined with the --print options".into())
    }
    if !json && !print_activity_name && !print_app_id && !print_app_version && !print_min_sdk_version {
        return Err("Must provide one of --print-app-id, --print-activity-name, --print-app-version --print-min-sdk-version!".into())
    }

    // Support running on either an `.apk` or a `.xml` file directly
    let mut abis = Vec::new();
    let manifest_data = read_xml(apk_path, &mut abis)?;

    // Use `axmldecoder` to parse the input binary XML file
    let xml = axmldecoder::parse(&manifest_data)?;
    let manifest = xml.get_root().as_ref().ok_or("AndroidManifest.xml has no root element")?;
    if json {
        return print_json(manifest, &abis);
    }

    // Get package name from top-level manifest element
    let package_name = &peel_element(manifest)?.get_attributes()["package"];
    if print_app_id {
        println!("{}", package_name);
    }

    // Get versionCode from top-level manifest element
    let app_version = peel_element(manifest)?.get_attributes().get("android:versionCode").map(|s| s.as_str());
    if print_app_version {
        println!("{}", app_version.unwrap_or("none"));
    }

    // Search for launchable activity
    let application = only_child(manifest, "application")?;
    let uses_sdk = only_child(manifest, "uses-sdk")?;

    // Get the minimum sdk version from the uses-sdk element
    let min_sdk_version = peel_element(uses_sdk)?.get_attributes().get("android:minSdkVersion").map(|s| s.as_str());
    if print_min_sdk_version {
        println!("{}", min_sdk_version.unwrap_or("none"));
    }

    if print_activity_name {
        if let Some(name) = launcher_activity(application, verbose)? {
            println!("{}", name);
        }
    }
    return Ok(());
}

// The first enabled activity or alias with a MAIN/LAUNCHER intent filter.
fn launcher_activity(application: &Node, verbose: bool) -> Result<Option<String>, String> {
    // Launcher intent filters may live on an alias rather than its target.
    let activities = filter_children(application, "activity")?
        .chain(filter_children(application, "activity-alias")?);
    for activity in activities {
        // Ignore aliases/activities disabled by default. Apps can expose
        // alternative launcher icons without making each one launchable.
        if matches!(peel_element(activity)?.get_attributes()
            .get("android:enabled").map(String::as_str), Some("false") | Some("0")) {
            continue;
        }
        // If we can't find an activity name, continue
        let activity_name = match peel_element(activity)?.get_attributes().get("android:name") {
            Some(name) => name,
            None => {
                vprint(format!("Skipping activity {:?} due to no 'android:name'", peel_element(activity)?), verbose);
                continue
            },
        };

        // Iterate over all `intent-filter` tags
        let intent_filters = match filter_children(activity, "intent-filter") {
            Ok(intent_filters) => intent_filters,
            Err(e) => {
                vprint(format!("Skipping activity {:?} due to no 'intent-filter' child: {}", activity_name, e), verbose);
                continue
            },
        };
        for intent_filter in intent_filters {
            // Find `action` and `catgeory` tags:
            let actions = match filter_children(intent_filter, "action") {
                Ok(actions) => actions,
                Err(e) => {
                    vprint(format!("Skipping intent_filter {:?} in activity {:?} due to no 'action' children for intent-filter: {}", intent_filter, activity_name, e), verbose);
                    continue
                },
            };
            let categories = match filter_children(intent_filter, "category") {
                Ok(categories) => categories,
                Err(e) => {
                    vprint(format!("Skipping intent_filter {:?} activity {:?} due to no 'category' children for intent-filter: {}", intent_filter, activity_name, e), verbose);
                    continue
                },
            };

            fn get_any_matching_attribute<'a>(nodes: impl Iterator<Item = &'a Node>, key: &str, val: &str) -> Result<bool, String> {
                for node in nodes {
                    match peel_element(node)?.get_attributes().get(key) {
                        Some(key_val) => {
                            if key_val == val {
                                return Ok(true);
                            }
                        }
                        None => continue,
                    }
                }
                return Ok(false);
            }

            if !get_any_matching_attribute(actions, "android:name", "android.intent.action.MAIN")? {
                vprint(format!("Skipping intent_filter {:?} in activity {:?} due to no 'android.intent.action.MAIN' action", intent_filter, activity_name), verbose);
                continue;
            }

            if !get_any_matching_attribute(categories, "android:name", "android.intent.category.LAUNCHER")? {
                vprint(format!("Skipping intent_filter {:?} in activity {:?} due to no 'android.intent.category.LAUNCHER' category", intent_filter, activity_name), verbose);
                continue;
            }
        
            // Otherwise, report this activity name
            return Ok(Some(activity_name.clone()));
        }
    }
    Ok(None)
}

// Structured metadata for the Android Library. Unlike the --print options this
// accepts split APKs, which may have no <uses-sdk>, launcher or full
// <application> element. Unknown or non-literal values are null.
fn print_json(manifest: &Node, abis: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    let attributes = peel_element(manifest)?.get_attributes();
    let package = literal(attributes.get("package")).ok_or("Manifest has no literal package attribute")?;
    let code = match attributes.get("android:versionCode") {
        Some(value) => Some(int_word(value).ok_or_else(|| format!("Cannot read android:versionCode {:?}", value))?),
        None => None,
    };
    // versionCodeMajor is a signed int; versionCode supplies the low 32 bits
    // of the long version code (PackageInfo.getLongVersionCode()).
    let major = match attributes.get("android:versionCodeMajor") {
        Some(value) => int_word(value).ok_or_else(|| format!("Cannot read android:versionCodeMajor {:?}", value))? as i32,
        None => 0,
    };
    let long_code = ((major as i64) << 32) | code.unwrap_or(0) as i64;
    let sdk = filter_children(manifest, "uses-sdk")?.next().map(peel_element).transpose()?;
    let sdk_value = |name: &str| sdk.and_then(|e| e.get_attributes().get(name));
    let min_sdk = sdk_value("android:minSdkVersion");
    let target_sdk = sdk_value("android:targetSdkVersion");
    let application = filter_children(manifest, "application")?.next();
    let application_attribute = |name: &str| -> Result<Option<&String>, String> {
        Ok(match application {
            Some(node) => peel_element(node)?.get_attributes().get(name),
            None => None,
        })
    };
    let launcher = match application {
        Some(node) => launcher_activity(node, false)?,
        None => None,
    };
    let abi_list: Vec<String> = abis.iter().map(|abi| json_string(Some(abi))).collect();
    let fields = [
        ("package", json_string(Some(package))),
        ("split", json_string(literal(attributes.get("split")))),
        ("config_for_split", json_string(literal(attributes.get("configForSplit")))),
        ("is_feature_split", json_bool(attributes.get("android:isFeatureSplit").or(attributes.get("isFeatureSplit")))),
        ("version_code", json_number(code)),
        ("version_code_major", major.to_string()),
        ("long_version_code", long_code.to_string()),
        ("version_name", json_string(literal(attributes.get("android:versionName")))),
        ("min_sdk", json_number(min_sdk.and_then(|v| int_word(v)))),
        ("min_sdk_codename", json_string(literal(min_sdk).filter(|v| int_word(v).is_none()))),
        ("target_sdk", json_number(target_sdk.and_then(|v| int_word(v)))),
        ("label", json_string(literal(application_attribute("android:label")?))),
        ("launchable_activity", json_string(launcher.as_deref())),
        ("extract_native_libs", json_bool(application_attribute("android:extractNativeLibs")?)),
        ("abis", format!("[{}]", abi_list.join(", "))),
    ];
    let body: Vec<String> = fields.iter().map(|(key, value)| format!("\"{}\": {}", key, value)).collect();
    println!("{{{}}}", body.join(", "));
    Ok(())
}
