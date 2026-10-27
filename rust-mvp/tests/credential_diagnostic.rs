use doustudio_rust::{
    auth::Session,
    credential_file,
    credentials::{self, Status, TOKEN_NAMES, UIFID_NAMES},
};
#[cfg(feature = "offline-test")]
use std::io::Write;
use std::process::{Command, Stdio};

const GOOD: &str = "UIFID_TEMP=SYNTHETIC_UIFID_MARKER; msToken=SYNTHETIC_TOKEN_MARKER";

#[test]
fn precise_format_reasons_do_not_disclose_rejected_input() {
    for (raw, expected) in [
        ("", "COOKIE_INPUT_EMPTY"),
        (";;;", "COOKIE_NO_FIELDS"),
        ("PRIVATE_UNRELATED_MARKER", "COOKIE_SEGMENT_MISSING_EQUALS"),
        (
            "Cookie: msToken=PRIVATE_UNRELATED_MARKER",
            "COOKIE_HEADER_LABEL_PRESENT",
        ),
        ("=PRIVATE_UNRELATED_MARKER", "COOKIE_FIELD_NAME_EMPTY"),
        (
            "msToken =PRIVATE_UNRELATED_MARKER",
            "COOKIE_FIELD_NAME_WHITESPACE",
        ),
        ("PRIVATE_UNRELATED_MARKER[]=x", "COOKIE_FIELD_NAME_INVALID"),
        (
            "msToken=PRIVATE_UNRELATED_MARKER\r\n",
            "COOKIE_EMBEDDED_LINE_BREAK",
        ),
        (
            "msToken=PRIVATE_UNRELATED_MARKER\t",
            "COOKIE_CONTROL_CHARACTER",
        ),
    ] {
        let diagnostic = credentials::inspect(raw);
        assert_eq!(diagnostic.structure_error, Some(expected));
        assert!(!diagnostic.passed());
        assert!(Session::new(raw.into(), "fixture-agent".into()).is_err());
        let output = diagnostic.render();
        assert!(output.contains(expected));
        assert!(!output.contains("PRIVATE_UNRELATED_MARKER"));
    }
    assert_eq!(
        credentials::inspect(&"x".repeat(credentials::COOKIE_LIMIT + 1)).structure_error,
        Some("COOKIE_INPUT_LIMIT_EXCEEDED")
    );
}

#[test]
fn required_field_matrix_shared_with_signing_session() {
    use Status::*;
    let cases = [
        (GOOD, Present, Present),
        ("UIFID_TEMP=a", Missing, Present),
        ("UIFID_TEMP=a;msToken=", Empty, Present),
        ("UIFID_TEMP=a;msToken=b;msToken=c", Duplicated, Present),
        ("UIFID_TEMP=a;msToken=;msToken=b", Duplicated, Present),
        ("msToken=b", Present, Missing),
        ("UIFID_TEMP=;msToken=b", Present, Empty),
        ("UIFID_TEMP=a;UIFID_TEMP=c;msToken=b", Present, Duplicated),
        (
            "UIFID_TEMP=a;msToken=b;UIFID_TEMP=a;msToken=b",
            Duplicated,
            Duplicated,
        ),
        (" ; UIFID_TEMP=a ; ; msToken=b ; ", Present, Present),
        ("UIFID_TEMP=a==;msToken=b=c==", Present, Present),
        (
            "UIFID_TEMP=a;msToken=b;unrelated=c;unrelated=d",
            Present,
            Present,
        ),
        ("UIFID_TEMP=a;mstoken=b", Missing, Present),
        ("Uifid_temp=a;msToken=b", Present, Missing),
        ("UIFID_TEMP=a;msToken=b\n", InvalidFormat, InvalidFormat),
        ("UIFID_TEMP=a;msToken=b\0", InvalidFormat, InvalidFormat),
        ("UIFID_TEMP=a;msToken=b\u{85}", InvalidFormat, InvalidFormat),
        ("UIFID_TEMP=a;msToken =b", InvalidFormat, InvalidFormat),
        (
            "cookie: UIFID_TEMP=a;msToken=b",
            InvalidFormat,
            InvalidFormat,
        ),
        (
            "douyin.com;UIFID_TEMP=a;msToken=b",
            InvalidFormat,
            InvalidFormat,
        ),
        (
            "UIFID_TEMP=a;broken;msToken=b",
            InvalidFormat,
            InvalidFormat,
        ),
        ("=a;msToken=b", InvalidFormat, InvalidFormat),
        ("", Missing, Missing),
        ("   ", Missing, Missing),
        (";;;", InvalidFormat, InvalidFormat),
    ];
    for (raw, token, uifid) in cases {
        let d = credentials::inspect(raw);
        assert_eq!(d.fields[0].1, token);
        assert_eq!(d.fields[1].1, uifid);
        let session = Session::new(raw.into(), "fixture-agent".into());
        if d.structure_valid {
            let s = session.unwrap();
            assert_eq!(s.cookie_value(TOKEN_NAMES).is_ok(), token == Present);
            assert_eq!(s.cookie_value(UIFID_NAMES).is_ok(), uifid == Present);
        } else {
            assert!(session.is_err());
        }
    }
}

#[test]
fn alias_priority_case_rules_and_equals_are_preserved() {
    for alias in UIFID_NAMES {
        let raw = format!("{alias}=a=b==;msToken=token=tail==");
        let d = credentials::inspect(&raw);
        assert!(d.passed());
        assert_eq!(d.fields[1].0, *alias);
        let s = Session::new(raw, "fixture-agent".into()).unwrap();
        assert_eq!(s.cookie_value(UIFID_NAMES).unwrap().as_str(), "a=b==");
        assert_eq!(
            s.cookie_value(TOKEN_NAMES).unwrap().as_str(),
            "token=tail=="
        );
    }
    let raw = "uifid=first;UIFID_TEMP=second;msToken=t";
    assert!(credentials::inspect(raw).passed());
    let s = Session::new(raw.into(), "fixture-agent".into()).unwrap();
    assert_eq!(s.cookie_value(UIFID_NAMES).unwrap().as_str(), "first");
    assert!(credentials::inspect("uifid=;UIFID_TEMP=second;msToken=t").passed());
    assert_eq!(
        credentials::inspect("uifid=first;UIFID_TEMP=a;UIFID_TEMP=;msToken=t").fields[1].1,
        Status::Duplicated
    );
    let s = Session::new(
        " uifid= leading ; msToken=t ".into(),
        "fixture-agent".into(),
    )
    .unwrap();
    assert_eq!(s.cookie_value(UIFID_NAMES).unwrap().as_str(), " leading");
}

fn assert_safe_output(output: &std::process::Output) {
    for text in [&output.stdout, &output.stderr] {
        let text = String::from_utf8_lossy(text);
        for forbidden in [
            "SYNTHETIC_UIFID_MARKER",
            "SYNTHETIC_TOKEN_MARKER",
            "PRIVATE_UNRELATED_MARKER",
            "REAL_LOGIN",
            "sha256",
            "length",
            "UIFID_TEMP=",
            "msToken=",
        ] {
            assert!(!text.contains(forbidden), "sensitive or misleading output");
        }
    }
}

#[test]
fn production_and_fixture_cli_file_input_redacts_and_does_not_write() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("input.txt");
    for (raw, success, status) in [
        (GOOD.to_owned(), true, "LOCAL_CREDENTIAL_STRUCTURE = PASS"),
        (
            "UIFID_TEMP=SYNTHETIC_UIFID_MARKER".into(),
            false,
            "msToken: MISSING",
        ),
        (format!("{GOOD};{GOOD}"), false, "msToken: DUPLICATED"),
        (
            format!("\u{feff}{GOOD}\r\n"),
            true,
            "LOCAL_CREDENTIAL_STRUCTURE = PASS",
        ),
        (format!("{GOOD}\n\n"), false, "COOKIE_EMBEDDED_LINE_BREAK"),
        (
            format!("Cookie: {GOOD}"),
            false,
            "COOKIE_HEADER_LABEL_PRESENT",
        ),
        (
            format!("{GOOD};PRIVATE_UNRELATED_MARKER"),
            false,
            "COOKIE_SEGMENT_MISSING_EQUALS",
        ),
    ] {
        std::fs::write(&path, &raw).unwrap();
        let output = Command::new(env!("CARGO_BIN_EXE_doustudio"))
            .args(["credential-check", "--cookie-file"])
            .arg(&path)
            .env("DOUSTUDIO_TEST_FORBID_ACTIVE_OPERATIONS", "1")
            .env("DOUSTUDIO_OFFLINE_ONLY", "1")
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert_eq!(output.status.success(), success);
        assert!(String::from_utf8_lossy(&output.stdout).contains(status));
        assert!(String::from_utf8_lossy(&output.stdout).contains("HTTP requests: 0"));
        assert_safe_output(&output);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), raw);
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 1);
    }
}

#[cfg(feature = "offline-test")]
#[test]
fn synthetic_stdin_cli_never_enters_runtime_signing_dns_or_http() {
    for raw in [
        GOOD.to_owned(),
        format!("{GOOD};{GOOD}"),
        "".into(),
        "UIFID_TEMP=SYNTHETIC_UIFID_MARKER;msToken=\r\nPRIVATE_UNRELATED_MARKER".into(),
    ] {
        let mut child = Command::new(env!("CARGO_BIN_EXE_doustudio"))
            .args(["credential-check", "--synthetic-stdin"])
            .env("DOUSTUDIO_TEST_FORBID_ACTIVE_OPERATIONS", "1")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(raw.as_bytes())
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert_eq!(output.status.success(), credentials::inspect(&raw).passed());
        assert!(String::from_utf8_lossy(&output.stdout).contains("Signing: NOT_RUN"));
        assert!(!String::from_utf8_lossy(&output.stderr).contains("BOUNDARY_VIOLATION"));
        assert_safe_output(&output);
    }
}

#[test]
fn files_reject_invalid_paths_formats_and_repository_locations() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("input.txt");
    assert!(credential_file::read(std::path::Path::new("relative.txt")).is_err());
    assert!(credential_file::read(&path).is_err());
    assert!(credential_file::read(dir.path()).is_err());
    assert!(credential_file::read(
        &std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("Cargo.toml")
    )
    .is_err());
    std::fs::write(&path, [0xff, 0xfe, 0x01]).unwrap();
    assert!(credential_file::read(&path).is_err());
    std::fs::write(&path, "x".repeat(credentials::COOKIE_LIMIT + 1)).unwrap();
    assert!(credential_file::read(&path).is_err());
    std::fs::write(&path, format!("{GOOD}\n\n")).unwrap();
    assert!(!credentials::inspect(&credential_file::read(&path).unwrap()).passed());
    std::fs::create_dir(dir.path().join(".git")).unwrap();
    assert!(credential_file::read(&path).is_err());
}

#[cfg(windows)]
#[test]
fn windows_reparse_points_network_paths_and_read_denial_are_rejected() {
    use std::os::windows::fs::{symlink_dir, symlink_file, OpenOptionsExt};
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("input.txt");
    std::fs::write(&path, GOOD).unwrap();
    let link = dir.path().join("file-link.txt");
    symlink_file(&path, &link).expect("Windows symlink test requires privilege or Developer Mode");
    assert!(credential_file::read(&link).is_err());
    let child = dir.path().join("child");
    std::fs::create_dir(&child).unwrap();
    std::fs::write(child.join("input.txt"), GOOD).unwrap();
    let directory_link = dir.path().join("directory-link");
    symlink_dir(&child, &directory_link).unwrap();
    assert!(credential_file::read(&directory_link.join("input.txt")).is_err());
    for bad in [
        r"\\example.invalid\share\input.txt",
        r"\\?\C:\input.txt",
        r"\\.\pipe\input",
        r"C:\input.txt:stream",
    ] {
        assert!(credential_file::read(std::path::Path::new(bad)).is_err());
    }
    let _locked = std::fs::OpenOptions::new()
        .read(true)
        .share_mode(0)
        .open(&path)
        .unwrap();
    assert!(credential_file::read(&path).is_err());
    drop(_locked);
    let hardlink = dir.path().join("hard-link.txt");
    std::fs::hard_link(&path, &hardlink).unwrap();
    assert!(credential_file::read(&hardlink).is_err());
    assert!(credential_file::read(&path).is_err());
}

#[test]
fn output_is_only_static_names_and_states_even_for_hostile_input() {
    for raw in [
        GOOD.to_owned(),
        format!("{GOOD};PRIVATE_UNRELATED_MARKER=value"),
        format!("{GOOD}\nPRIVATE_UNRELATED_MARKER"),
        "x".repeat(credentials::COOKIE_LIMIT + 1),
    ] {
        let d = credentials::diagnose(zeroize::Zeroizing::new(raw));
        let out = format!("{d:?}\n{}", d.render());
        for marker in [
            "SYNTHETIC_UIFID_MARKER",
            "SYNTHETIC_TOKEN_MARKER",
            "PRIVATE_UNRELATED_MARKER",
        ] {
            assert!(!out.contains(marker));
        }
    }
}

#[cfg(not(feature = "offline-test"))]
#[test]
fn production_has_no_stdin_fixture_switch_and_acceptance_stays_guarded() {
    let output = Command::new(env!("CARGO_BIN_EXE_doustudio"))
        .args(["credential-check", "--synthetic-stdin"])
        .output()
        .unwrap();
    assert!(!output.status.success());
    let dir = tempfile::tempdir().unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_doustudio"))
        .args([
            "acceptance",
            "--first-page-only",
            "--cookie-file",
            "not-read.txt",
            "--output",
        ])
        .arg(dir.path())
        .env("DOUSTUDIO_OFFLINE_ONLY", "1")
        .output()
        .unwrap();
    let r: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(r["list_requests_started"], 0);
    assert_eq!(r["error_category"], "AUTHORIZATION_REQUIRED");
}

#[cfg(feature = "offline-test")]
#[test]
fn active_boundary_probe() {
    let Ok(probe) = std::env::var("DOUSTUDIO_TEST_BOUNDARY_PROBE") else {
        return;
    };
    match probe.as_str() {
        "abogus" => {
            let _ = doustudio_rust::signing::abogus("", "", "", "", 0, || 0.0);
        }
        "websign" => {
            let _ = doustudio_rust::signing::websign(&[], "", 0);
        }
        "list_url" => {
            let s = Session::new(GOOD.into(), "fixture-agent".into()).unwrap();
            let _ = doustudio_rust::signing::list_url(&s, "fixture", 0);
        }
        "network" => {
            tokio::runtime::Runtime::new().unwrap().block_on(async {
                let _ = doustudio_rust::media::pinned_client(
                    &url::Url::parse("https://example.invalid/").unwrap(),
                    false,
                )
                .await;
            });
        }
        _ => panic!("unknown probe"),
    }
}

#[cfg(feature = "offline-test")]
#[test]
fn boundary_sentinels_are_live_and_fail_before_active_operations() {
    for boundary in ["abogus", "websign", "list_url", "network"] {
        let output = Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "active_boundary_probe", "--nocapture"])
            .env("DOUSTUDIO_TEST_BOUNDARY_PROBE", boundary)
            .env("DOUSTUDIO_TEST_FORBID_ACTIVE_OPERATIONS", "1")
            .output()
            .unwrap();
        assert!(!output.status.success());
        assert!(String::from_utf8_lossy(&output.stderr)
            .contains("OFFLINE_DIAGNOSTIC_BOUNDARY_VIOLATION"));
    }
}
