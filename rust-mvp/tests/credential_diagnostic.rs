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
        ("UIFID_TEMP=a;msToken=b\n", Unknown, Present),
        ("UIFID_TEMP=a;msToken=b\0", Unknown, Present),
        ("UIFID_TEMP=a;msToken=b\u{85}", Unknown, Present),
        ("UIFID_TEMP=a;msToken =b", Unknown, Present),
        ("cookie: UIFID_TEMP=a;msToken=b", Present, Unknown),
        ("douyin.com;UIFID_TEMP=a;msToken=b", Present, Present),
        ("UIFID_TEMP=a;broken;msToken=b", Present, Present),
        ("=a;msToken=b", Present, Unknown),
        ("", Missing, Missing),
        ("   ", Missing, Missing),
        (";;;", Unknown, Unknown),
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

#[test]
fn partial_inspection_preserves_confirmed_fields_and_strict_rejection() {
    use Status::*;
    let cases = [
        ("bad_before", "broken;msToken=t;UIFID=u", Present, Present),
        ("bad_after", "msToken=t;UIFID=u;broken", Present, Present),
        ("bad_between", "msToken=t;broken;UIFID=u", Present, Present),
        ("unobserved_token", "broken;UIFID=u", Unknown, Present),
        ("unobserved_uifid", "broken;msToken=t", Present, Unknown),
        ("empty_token", "broken;msToken=;UIFID=u", Empty, Present),
        ("empty_uifid", "broken;msToken=t;UIFID=", Present, Empty),
        (
            "duplicate_token",
            "broken;msToken=t;msToken=;UIFID=u",
            Duplicated,
            Present,
        ),
        (
            "duplicate_uifid",
            "broken;msToken=t;UIFID=u;UIFID=",
            Present,
            Duplicated,
        ),
        (
            "distinct_aliases",
            "broken;msToken=t;uifid=;UIFID=u",
            Present,
            Present,
        ),
        (
            "unused_alias_duplicate",
            "broken;msToken=t;uifid=u;UIFID=x;UIFID=x",
            Present,
            Duplicated,
        ),
        ("bare_token_candidate", "msToken;UIFID=u", Unknown, Present),
        (
            "token_space_candidate",
            "msToken =t;UIFID=u",
            Unknown,
            Present,
        ),
        (
            "token_invalid_name_candidate",
            "msToken[]=t;UIFID=u",
            Unknown,
            Present,
        ),
        (
            "bare_uifid_candidate",
            "msToken=t;UIFID_TEMP",
            Present,
            MalformedCandidate,
        ),
        (
            "candidate_and_confirmed",
            "msToken=t;msToken;UIFID=u",
            Unknown,
            Present,
        ),
        (
            "duplicate_and_candidate",
            "msToken=t;msToken=t;msToken;UIFID=u",
            Duplicated,
            Present,
        ),
        (
            "different_name_not_candidate",
            "msTokenExtra;UIFID=u",
            Unknown,
            Present,
        ),
        (
            "case_sensitive_candidate",
            "mstoken;UIFID=u",
            Unknown,
            Present,
        ),
        (
            "unrelated_invalid_name",
            "bad[]=x;msToken=t;UIFID=u",
            Present,
            Present,
        ),
        ("empty_name", "=x;msToken=t;UIFID=u", Present, Present),
        (
            "unrelated_control",
            "other=x\0;msToken=t;UIFID=u",
            Present,
            Present,
        ),
        ("required_control", "msToken=t\0;UIFID=u", Unknown, Present),
        (
            "newline_not_split",
            "other=x\nmsToken=t;UIFID=u",
            Unknown,
            Present,
        ),
        (
            "required_newline",
            "msToken=t\nother=x;UIFID=u",
            Unknown,
            Present,
        ),
        (
            "equals_not_truncated",
            "broken;msToken=t==;UIFID=u=v==",
            Present,
            Present,
        ),
        (
            "value_not_reinterpreted",
            "broken;other=msToken=t;UIFID=u",
            Unknown,
            Present,
        ),
        (
            "unrelated_duplicates",
            "broken;other=x;other=y;msToken=t;UIFID=u",
            Present,
            Present,
        ),
    ];
    let mut evidence = Vec::new();
    for (scenario, raw, token, uifid) in cases {
        let d = credentials::inspect(raw);
        assert_eq!(d.fields[0].1, token, "{scenario}");
        assert_eq!(d.fields[1].1, uifid, "{scenario}");
        assert!(!d.structure_valid, "{scenario}");
        assert_eq!(d.inspection_label(), "PARTIAL");
        assert_eq!(d.strict_label(), "REJECT");
        assert!(credentials::resolve(raw, TOKEN_NAMES).is_err());
        assert!(credentials::resolve_ms_token(raw).is_err());
        assert!(credentials::resolve(raw, UIFID_NAMES).is_err());
        assert!(Session::new(raw.into(), "fixture-agent".into()).is_err());
        evidence.push(serde_json::json!({"scenario": scenario, "result": d.json()}));
    }
    // Evidence contains fixed scenario names and sanitized results, never fixture input.
    if let Some(root) = std::env::var_os("DOUSTUDIO_ACCEPTANCE_TEST_EVIDENCE") {
        std::fs::write(
            std::path::PathBuf::from(root).join("synthetic-credential-inspection.json"),
            serde_json::to_vec_pretty(&evidence).unwrap(),
        )
        .unwrap();
    }
}

#[test]
fn observations_and_candidates_remain_distinct_in_safe_json() {
    let d = credentials::inspect("msToken=t;msToken;UIFID=u");
    assert_eq!(d.observed_fields[0].1, Status::Present);
    let json = d.json();
    assert_eq!(json["MSTOKEN_FIELD"], "UNKNOWN");
    assert!(json["MSTOKEN_REQUEST_VALUE"].is_null());
    assert_eq!(
        json["credential_fields"]["msToken"]["parseable_status"],
        "PRESENT"
    );
    assert_eq!(
        json["credential_fields"]["msToken"]["malformed_candidate"],
        true
    );
    assert_eq!(
        json["credential_fields"]["msToken"]["observation"],
        "CONFIRMED_IN_PARSEABLE_SEGMENTS"
    );
    let json = credentials::inspect("broken;UIFID=u").json();
    assert_eq!(json["MSTOKEN_FIELD"], "UNKNOWN");
    assert_eq!(
        json["credential_fields"]["msToken"]["parseable_status"],
        "NOT_OBSERVED"
    );
    assert_eq!(
        json["credential_fields"]["msToken"]["observation"],
        "NOT_OBSERVED_IN_PARSEABLE_SEGMENTS"
    );
    for raw in [
        GOOD,
        "UIFID=u",
        "msToken=t",
        "",
        " ; msToken=t ; UIFID=u ; ; ",
    ] {
        assert_eq!(credentials::inspect(raw).inspection_label(), "COMPLETE");
    }
    let oversized = format!("{GOOD};other={}", "x".repeat(credentials::COOKIE_LIMIT));
    let d = credentials::inspect(&oversized);
    assert_eq!(d.fields[0].1, Status::Unknown);
    assert_eq!(d.fields[1].1, Status::Unknown);
    assert_eq!(d.inspection_label(), "PARTIAL");
    assert_eq!(d.strict_label(), "REJECT");
}

#[test]
fn diagnostic_outputs_do_not_depend_on_credential_values_or_sizes() {
    for suffix in [
        "",
        ";broken",
        ";msToken",
        ";other=unrelated",
        ";other=bad\0",
    ] {
        let a = credentials::inspect(&format!("msToken=a;UIFID_TEMP=b{suffix}"));
        let b = credentials::inspect(&format!(
            "msToken=SYNTHETIC_TOKEN_MARKER==;UIFID_TEMP=SYNTHETIC_UIFID_MARKER{suffix}"
        ));
        assert_eq!(a.json(), b.json());
        assert_eq!(a.render(), b.render());
        assert_eq!(format!("{a:?}"), format!("{b:?}"));
    }
}

#[test]
fn optional_token_policy_keeps_uifid_and_structure_strict() {
    use Status::*;
    for (raw, status, policy, pass) in [
        (GOOD, Present, Some("ORIGINAL"), true),
        ("UIFID=u;msToken=", Empty, Some("EMPTY"), true),
        ("UIFID=u", Missing, Some("EMPTY"), true),
        (
            "UIFID=u;mstoken=case_sensitive",
            Missing,
            Some("EMPTY"),
            true,
        ),
        ("UIFID=u;msToken=;msToken=", Duplicated, None, false),
        ("UIFID=u;msToken=t;msToken=", Duplicated, None, false),
        ("UIFID=u;msToken=t;msToken=v", Duplicated, None, false),
        ("UIFID=u;broken", Unknown, None, false),
        ("UIFID=u;msToken", Unknown, None, false),
        ("UIFID=u;msToken=t\n", Unknown, None, false),
        ("other=x", Missing, Some("EMPTY"), false),
        ("UIFID=", Missing, Some("EMPTY"), false),
        ("UIFID=u;UIFID=", Missing, Some("EMPTY"), false),
        ("uifid=u;UIFID=x;UIFID=y", Missing, Some("EMPTY"), false),
        ("uifid=;UIFID=u", Missing, Some("EMPTY"), true),
    ] {
        let d = credentials::inspect(raw);
        assert_eq!(d.fields[0].1, status);
        assert_eq!(d.ms_token_request_value, policy);
        assert_eq!(d.passed(), pass);
        assert_eq!(d.json()["MSTOKEN_REQUEST_VALUE"], serde_json::json!(policy));
        assert_eq!(credentials::resolve_ms_token(raw).is_ok(), policy.is_some());
        if let Ok(session) = Session::new(raw.into(), "fixture-agent".into()) {
            assert_eq!(session.ms_token_request_value().is_ok(), policy.is_some());
            assert_eq!(
                session.ms_token_request_value().is_ok()
                    && session.cookie_value(UIFID_NAMES).is_ok(),
                pass
            );
        }
    }
    let raw = "UIFID=u;msToken= leading=a+b/==";
    assert_eq!(
        credentials::resolve_ms_token(raw).unwrap(),
        " leading=a+b/=="
    );
}

#[test]
fn json_cli_schema_is_sanitized_and_never_enters_active_operations() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("synthetic.txt");
    for raw in [
        GOOD.to_owned(),
        format!("PRIVATE_UNRELATED_MARKER;{GOOD}"),
        format!("{GOOD};msToken"),
        "PRIVATE_UNRELATED_MARKER;UIFID_TEMP=SYNTHETIC_UIFID_MARKER".into(),
        "UIFID_TEMP=SYNTHETIC_UIFID_MARKER".into(),
        "UIFID_TEMP=SYNTHETIC_UIFID_MARKER;msToken=".into(),
        format!("{GOOD};{GOOD}"),
    ] {
        std::fs::write(&path, &raw).unwrap();
        let output = Command::new(env!("CARGO_BIN_EXE_doustudio"))
            .args(["credential-check", "--json", "--cookie-file"])
            .arg(&path)
            .env("DOUSTUDIO_TEST_FORBID_ACTIVE_OPERATIONS", "1")
            .env("DOUSTUDIO_OFFLINE_ONLY", "1")
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert_safe_output(&output);
        let expected = credentials::inspect(&raw);
        assert_eq!(output.status.success(), expected.passed());
        let json: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(json, expected.json());
        let mut keys: Vec<_> = json
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        keys.sort_unstable();
        let mut allowed = vec![
            "task",
            "mode",
            "COOKIE_STRUCTURE",
            "STRUCTURE_REASON",
            "MSTOKEN_FIELD",
            "MSTOKEN_REQUEST_VALUE",
            "UIFID_FIELD",
            "credential_fields",
            "FIELD_INSPECTION",
            "LOCAL_CREDENTIAL_STRUCTURE",
            "STRICT_SIGNING_VALIDATION",
            "SIGNING_ALLOWED",
            "SIGNING",
            "NETWORK_REQUESTS",
            "DNS_REQUESTS",
            "REAL_HTTP_REQUESTS",
            "REAL_MEDIA_REQUESTS",
        ];
        allowed.sort_unstable();
        assert_eq!(keys, allowed);
        for group in ["msToken", "UIFID"] {
            let field = &json["credential_fields"][group];
            assert_eq!(field.as_object().unwrap().len(), 5);
            let name = field["name"].as_str().unwrap();
            assert!(TOKEN_NAMES.contains(&name) || UIFID_NAMES.contains(&name));
            assert!([
                "PRESENT",
                "MISSING",
                "EMPTY",
                "DUPLICATED",
                "UNKNOWN",
                "MALFORMED_CANDIDATE"
            ]
            .contains(&field["status"].as_str().unwrap()));
        }
        for counter in [
            "NETWORK_REQUESTS",
            "DNS_REQUESTS",
            "REAL_HTTP_REQUESTS",
            "REAL_MEDIA_REQUESTS",
        ] {
            assert_eq!(json[counter], 0);
        }
        assert_eq!(json["SIGNING_ALLOWED"], "NO");
        assert_eq!(json["SIGNING"], "NOT_RUN");
        assert!(
            json["MSTOKEN_REQUEST_VALUE"].is_null()
                || ["ORIGINAL", "EMPTY"].contains(&json["MSTOKEN_REQUEST_VALUE"].as_str().unwrap())
        );
        assert!(!String::from_utf8_lossy(&output.stderr).contains("BOUNDARY_VIOLATION"));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), raw);
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 1);
    }
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
            true,
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
