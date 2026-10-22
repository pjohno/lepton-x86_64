use clap::{Arg, ArgAction, Command};
use signal_hook::{consts::{SIGINT, SIGTERM}, iterator::Signals};
use std::collections::HashMap;
use std::process::ExitCode;

fn parse_txt_record(raw: &str) -> Result<(String, Vec<u8>), String> {
    match raw.split_once('=') {
        Some((key, value)) => Ok((key.to_string(), value.as_bytes().to_vec())),
        None => Err(format!("TXT record '{}' is not in 'key=value' form", raw)),
    }
}

/// Builds the D-Bus object path systemd-resolved uses for a registered service id, escaping it
/// the same way as sd_bus_path_encode(): [A-Za-z0-9] verbatim, every other byte as "_xx".
fn service_object_path(id: &str) -> String {
    let mut path = String::from("/org/freedesktop/resolve1/dnssd/");
    if id.is_empty() {
        path.push('_');
    }
    for b in id.bytes() {
        if b.is_ascii_alphanumeric() {
            path.push(b as char);
        } else {
            path.push_str(&format!("_{:02x}", b));
        }
    }
    path
}

fn main() -> ExitCode {
    let matches = Command::new("lepton-mdns-publish")
        .version("1.0")
        .about("Publishes or unpublishes a DNS-SD/mDNS service via systemd-resolved")
        .arg(
            Arg::new("name")
                .help("The DNS-SD service instance name, e.g. 'lepton-foo'")
                .required(true)
                .index(1),
        )
        .arg(
            Arg::new("type")
                .help("The DNS-SD service type, e.g. '_adb._tcp'")
                .required(true)
                .index(2),
        )
        .arg(
            Arg::new("port")
                .help("The TCP/UDP port the service is reachable on")
                .required(true)
                .index(3),
        )
        .arg(
            Arg::new("txt")
                .help("A 'key=value' TXT record to attach to the service; may be given multiple times")
                .action(ArgAction::Append)
                .index(4),
        )
        .get_matches();

    let mut signals = match Signals::new([SIGINT, SIGTERM]) {
        Ok(signals) => signals,
        Err(err) => {
            eprintln!("Failed to register signal handlers: {err}");
            return ExitCode::FAILURE;
        }
    };

    let name = matches.get_one::<String>("name").unwrap();

    let connection = match zbus::blocking::Connection::system() {
        Ok(connection) => connection,
        Err(e) => {
            eprintln!("Failed to connect to the D-Bus system bus: {}", e);
            return ExitCode::FAILURE;
        }
    };

    let service_type = matches.get_one::<String>("type").unwrap();
    let port: u16 = match matches.get_one::<String>("port").unwrap().parse() {
        Ok(port) => port,
        Err(e) => {
            eprintln!("Invalid port: {}", e);
            return ExitCode::FAILURE;
        }
    };

    let mut txt_record = HashMap::new();
    for raw in matches.get_many::<String>("txt").unwrap_or_default() {
        match parse_txt_record(raw) {
            Ok((key, value)) => {
                txt_record.insert(key, value);
            }
            Err(e) => {
                eprintln!("{}", e);
                return ExitCode::FAILURE;
            }
        }
    }

    // RegisterService(id, name_template, type, port, priority, weight, txt_datas) -> service_path
    // See org.freedesktop.resolve1(5).
    let body = (
        name.as_str(),
        name.as_str(),
        service_type.as_str(),
        port,
        0u16,
        0u16,
        vec![txt_record],
    );

    if let Err(e) = connection.call_method(
        Some("org.freedesktop.resolve1"),
        "/org/freedesktop/resolve1",
        Some("org.freedesktop.resolve1.Manager"),
        "RegisterService",
        &body,
    ) {
        eprintln!("Failed to register '{}' with systemd-resolved: {}", name, e);
        return ExitCode::FAILURE;
    }

    for sig in signals.forever() {
        eprintln!("Received signal {:?}", sig);
        break;
    }

    // The service was registered with id = name; see RegisterService below.
    let path = match zbus::zvariant::ObjectPath::try_from(service_object_path(name)) {
        Ok(path) => path,
        Err(e) => {
            eprintln!("Invalid service name '{}': {}", name, e);
            return ExitCode::FAILURE;
        }
    };
    let body = (
        path,
    );
    if let Err(e) = connection.call_method(
        Some("org.freedesktop.resolve1"),
        "/org/freedesktop/resolve1",
        Some("org.freedesktop.resolve1.Manager"),
        "UnregisterService",
        &body,
    ) {
        eprintln!("Failed to unregister '{}' from systemd-resolved: {}", name, e);
    }

    return ExitCode::SUCCESS
}

