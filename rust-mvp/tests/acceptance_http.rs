#![cfg(feature = "offline-test")]
use doustudio_rust::{
    acceptance::{self, Interaction, Options},
    auth::Session,
    extractor,
    media::{MediaPolicy, TestScope},
    signing, Error, Result,
};
use serde_json::{json, Value};
use std::{
    collections::VecDeque,
    path::Path,
    process::Stdio,
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
};
use tokio_util::sync::CancellationToken;

struct Server {
    port: u16,
    requests: Arc<Mutex<Vec<String>>>,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}
fn work(id: &str, port: u16, path: &str) -> Value {
    json!({"aweme_id":id,"create_time":1700000000,"aweme_type":0,"desc":"SENSITIVE_TITLE_MARKER","video":{"duration":1000,"cover":{"url_list":["https://cover.example/SENSITIVE_COVER_MARKER"]},"play_addr":{"url_list":[format!("http://127.0.0.1:{port}/{path}")],"width":64,"height":64}}})
}
impl Server {
    async fn new() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let requests = Arc::new(Mutex::new(vec![]));
        let history = requests.clone();
        let task = tokio::spawn(async move {
            while let Ok((mut socket, _)) = listener.accept().await {
                let history = history.clone();
                tokio::spawn(async move {
                    let mut bytes = Vec::new();
                    let mut b = [0];
                    while bytes.len() < 32768 && !bytes.ends_with(b"\r\n\r\n") {
                        if socket.read(&mut b).await.unwrap_or(0) == 0 {
                            return;
                        }
                        bytes.push(b[0]);
                    }
                    let request = String::from_utf8(bytes).unwrap();
                    let path = request.split_whitespace().nth(1).unwrap().to_owned();
                    history.lock().unwrap().push(request);
                    let u = url::Url::parse(&format!("http://127.0.0.1:{port}{path}")).unwrap();
                    if u.path().starts_with("/status/") {
                        let status = u.path().trim_start_matches("/status/");
                        let _=socket.write_all(format!("HTTP/1.1 {status} Denied\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").as_bytes()).await;
                        return;
                    }
                    if u.path().starts_with("/list") {
                        let cursor = u
                            .query_pairs()
                            .find(|(k, _)| k == "max_cursor")
                            .unwrap()
                            .1
                            .to_string();
                        let single = u.path() != "/list";
                        let slow = u.path() == "/list-slow";
                        let (ids, next, more) = if single {
                            (vec!["910000000000000001"], 0, false)
                        } else {
                            match cursor.as_str() {
                                "0" => (
                                    vec![
                                        "910000000000000001",
                                        "910000000000000001",
                                        "910000000000000002",
                                    ],
                                    111,
                                    true,
                                ),
                                "111" => {
                                    (vec!["910000000000000002", "910000000000000003"], 222, true)
                                }
                                "222" => (vec!["910000000000000004"], 0, false),
                                _ => panic!("invented cursor"),
                            }
                        };
                        let body=serde_json::to_vec(&json!({"status_code":0,"aweme_list":ids.iter().map(|id|work(id,port,if slow{"slow"}else{"original"})).collect::<Vec<_>>(),"has_more":more,"max_cursor":next})).unwrap();
                        socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",body.len()).as_bytes()).await.unwrap();
                        socket.write_all(&body).await.unwrap();
                        return;
                    }
                    if u.path() == "/slow" {
                        let _=socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nConnection: close\r\n\r\n").await;
                        for _ in 0..100 {
                            if socket.write_all(&[0u8; 1024]).await.is_err() {
                                break;
                            }
                            tokio::time::sleep(Duration::from_millis(20)).await;
                        }
                        return;
                    }
                    let body = std::fs::read(
                        std::env::var_os("DOUSTUDIO_FIXTURE_MP4").expect("offline script fixture"),
                    )
                    .unwrap();
                    let _=socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",body.len()).as_bytes()).await;
                    let _ = socket.write_all(&body).await;
                });
            }
        });
        Self {
            port,
            requests,
            task,
        }
    }
    fn url(&self, path: &str) -> String {
        format!("http://127.0.0.1:{}{path}", self.port)
    }
    fn options(&self, path: &str, output: &Path) -> Options {
        Options {
            first_page_only: false,
            cookie_file: None,
            output: output.into(),
            evidence: None,
            test_scope: None,
            fixture_url: Some(self.url(path)),
        }
    }
    fn counts(&self) -> (usize, usize) {
        let r = self.requests.lock().unwrap();
        let lists = r
            .iter()
            .filter(|s| s.starts_with("GET /list") || s.starts_with("GET /status"))
            .count();
        (lists, r.len() - lists)
    }
}
struct Ui {
    answers: VecDeque<String>,
    events: Vec<Value>,
    sessions: usize,
    cancel: Option<CancellationToken>,
}
impl Ui {
    fn new(answers: &[&str]) -> Self {
        Self {
            answers: answers.iter().map(|s| s.to_string()).collect(),
            events: vec![],
            sessions: 0,
            cancel: None,
        }
    }
}
impl Interaction for Ui {
    fn answer(&mut self, _: &str) -> Result<String> {
        self.answers.pop_front().ok_or(Error::Authorization)
    }
    fn session(&mut self, _cookie_file: Option<&std::path::Path>) -> Result<Session> {
        self.sessions += 1;
        Session::new(
            "UIFID_TEMP=SENSITIVE_COOKIE_MARKER; msToken=SENSITIVE_TOKEN_MARKER".into(),
            signing::USER_AGENT.into(),
        )
    }
    fn show(&mut self, event: Value) {
        if event["received_bytes"].as_u64().is_some_and(|n| n >= 1024) {
            if let Some(c) = &self.cancel {
                c.cancel();
            }
        }
        self.events.push(event);
    }
}
fn assert_redacted(text: &str) {
    for secret in [
        "910000000000000001",
        "910000000000000002",
        "SENSITIVE_TITLE_MARKER",
        "SENSITIVE_COVER_MARKER",
        "SENSITIVE_COOKIE_MARKER",
        "SENSITIVE_TOKEN_MARKER",
        "a_bogus",
        "x-secsdk-web-signature",
        "max_cursor",
        "http://",
        "https://",
    ] {
        assert!(!text.contains(secret), "leak: {secret}");
    }
}

#[tokio::test]
async fn first_page_only_cli_ignores_pagination_and_download_answers() {
    for path in ["/list", "/list-single"] {
        let server = Server::new().await;
        let dir = tempfile::tempdir().unwrap();
        let mut child = tokio::process::Command::new(env!("CARGO_BIN_EXE_doustudio"))
            .args([
                "acceptance",
                "--first-page-only",
                "--fixture-url",
                &server.url(path),
                "--output",
            ])
            .arg(dir.path())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"AUTHORIZE LIST\nCONTINUE PAGES\n1\nDOWNLOAD 1\n")
            .await
            .unwrap();
        let output = child.wait_with_output().await.unwrap();
        assert!(output.status.success());
        let report: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(report["stop_reason"], "FIRST_PAGE_ONLY_COMPLETE");
        assert_eq!(report["list_requests_started"], 1);
        assert_eq!(report["media_download_attempts"], 0);
        assert_eq!(report["pagination_confirmation"], false);
        assert_eq!(report["authorization_b"], false);
        assert!(report["choices"].as_array().unwrap().is_empty());
        assert_eq!(server.counts(), (1, 0));
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
        assert_redacted(&String::from_utf8_lossy(&output.stdout));
        assert_redacted(&String::from_utf8_lossy(&output.stderr));
    }
}

#[tokio::test]
async fn first_page_only_external_cookie_file_uses_shared_validation() {
    for valid in [true, false] {
        let server = Server::new().await;
        let dir = tempfile::tempdir().unwrap();
        let cookie_file = dir.path().join("synthetic-input.txt");
        let cookie = if valid {
            "UIFID_TEMP=SENSITIVE_COOKIE_MARKER;msToken=SENSITIVE_TOKEN_MARKER"
        } else {
            "UIFID_TEMP=SENSITIVE_COOKIE_MARKER"
        };
        std::fs::write(&cookie_file, cookie).unwrap();
        let mut child = tokio::process::Command::new(env!("CARGO_BIN_EXE_doustudio"))
            .args([
                "acceptance",
                "--first-page-only",
                "--fixture-url",
                &server.url("/list"),
                "--cookie-file",
            ])
            .arg(&cookie_file)
            .arg("--output")
            .arg(dir.path())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"AUTHORIZE LIST\n")
            .await
            .unwrap();
        let output = child.wait_with_output().await.unwrap();
        assert_eq!(output.status.success(), valid);
        let report: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(report["list_requests_started"], usize::from(valid));
        assert_eq!(report["media_download_attempts"], 0);
        assert_eq!(report["pagination_confirmation"], false);
        assert_eq!(server.counts(), (usize::from(valid), 0));
        assert_eq!(std::fs::read_to_string(cookie_file).unwrap(), cookie);
        assert_redacted(&String::from_utf8_lossy(&output.stdout));
        assert_redacted(&String::from_utf8_lossy(&output.stderr));
    }
}

#[tokio::test]
async fn three_pages_diagnostics_native_signing_and_dedup() {
    let server = Server::new().await;
    let dir = tempfile::tempdir().unwrap();
    let mut ui = Ui::new(&["AUTHORIZE LIST", "CONTINUE PAGES", "0"]);
    let report = acceptance::run(
        &server.options("/list", dir.path()),
        &mut ui,
        &CancellationToken::new(),
    )
    .await;
    assert_eq!(report.stop_reason, "SELECTION_CANCELLED");
    assert_eq!(server.counts(), (3, 0));
    assert_eq!(
        report
            .pages
            .iter()
            .map(|d| (
                d.returned,
                d.unique_in_page,
                d.new_unique,
                d.cumulative_unique,
                d.duplicates
            ))
            .collect::<Vec<_>>(),
        vec![(3, 2, 2, 2, 1), (2, 2, 1, 3, 1), (1, 1, 1, 4, 0)]
    );
    assert!(report
        .pages
        .iter()
        .all(|d| d.request.http_status == Some(200)
            && d.request.signing_completed
            && d.cover_https_hosts_valid == d.returned));
    assert_eq!(report.pages[0].cursor_advanced, Some(true));
    assert_eq!(report.pages[2].stop_reason, "SERVER_EXHAUSTED");
    let requests = server.requests.lock().unwrap();
    for (request, cursor) in requests.iter().zip(["0", "111", "222"]) {
        let path = request.split_whitespace().nth(1).unwrap();
        let u = url::Url::parse(&format!("http://localhost{path}")).unwrap();
        let q = u.query_pairs().collect::<std::collections::HashMap<_, _>>();
        assert_eq!(q["max_cursor"], cursor);
        assert!(!q["a_bogus"].is_empty());
        assert!(!q["x-secsdk-web-signature"].is_empty());
    }
    assert_redacted(&serde_json::to_string(&report).unwrap());
    assert_redacted(&serde_json::to_string(&ui.events).unwrap());
}
#[tokio::test]
async fn exact_http_statuses_stop_without_retry() {
    for code in [401, 403, 429] {
        let server = Server::new().await;
        let dir = tempfile::tempdir().unwrap();
        let mut ui = Ui::new(&["AUTHORIZE LIST"]);
        let r = acceptance::run(
            &server.options(&format!("/status/{code}"), dir.path()),
            &mut ui,
            &CancellationToken::new(),
        )
        .await;
        assert_eq!(r.pages[0].request.http_status, Some(code));
        assert!(r
            .error_category
            .as_ref()
            .unwrap()
            .contains(&code.to_string()));
        assert_eq!(server.counts(), (1, 0));
        assert_redacted(&serde_json::to_string(&r).unwrap());
    }
}
#[tokio::test]
async fn no_authorization_a_zero_requests_and_no_credentials() {
    let server = Server::new().await;
    let dir = tempfile::tempdir().unwrap();
    let mut ui = Ui::new(&[""]);
    let r = acceptance::run(
        &server.options("/list", dir.path()),
        &mut ui,
        &CancellationToken::new(),
    )
    .await;
    assert_eq!(server.counts(), (0, 0));
    assert_eq!(ui.sessions, 0);
    assert!(!r.authorization_a);
}
#[tokio::test]
async fn pagination_decline_stops_after_first_page() {
    let server = Server::new().await;
    let dir = tempfile::tempdir().unwrap();
    let mut ui = Ui::new(&["AUTHORIZE LIST", "no"]);
    let r = acceptance::run(
        &server.options("/list", dir.path()),
        &mut ui,
        &CancellationToken::new(),
    )
    .await;
    assert_eq!(server.counts(), (1, 0));
    assert_eq!(r.stop_reason, "PAGINATION_DECLINED");
}
#[tokio::test]
async fn no_authorization_b_zero_media_requests() {
    let server = Server::new().await;
    let dir = tempfile::tempdir().unwrap();
    let mut ui = Ui::new(&["AUTHORIZE LIST", "1", ""]);
    let r = acceptance::run(
        &server.options("/list-single", dir.path()),
        &mut ui,
        &CancellationToken::new(),
    )
    .await;
    assert_eq!(server.counts(), (1, 0));
    assert_eq!(r.stop_reason, "AUTHORIZATION_B_DECLINED");
    assert_eq!(r.selected_index, Some(1));
    assert!(!r.authorization_b);
}
#[tokio::test]
async fn cancelled_selection_zero_media_requests() {
    let server = Server::new().await;
    let dir = tempfile::tempdir().unwrap();
    let mut ui = Ui::new(&["AUTHORIZE LIST", "0"]);
    let r = acceptance::run(
        &server.options("/list-single", dir.path()),
        &mut ui,
        &CancellationToken::new(),
    )
    .await;
    assert_eq!(server.counts(), (1, 0));
    assert_eq!(r.stop_reason, "SELECTION_CANCELLED");
}
#[tokio::test]
async fn locked_snapshot_survives_reordering_without_refetch() {
    let server = Server::new().await;
    let dir = tempfile::tempdir().unwrap();
    let mut works = vec![
        extractor::extract(&work("910000000000000001", server.port, "original")).unwrap(),
        extractor::extract(&work("910000000000000002", server.port, "replacement")).unwrap(),
    ];
    let locked = acceptance::lock(&works, 1, true).unwrap();
    works.reverse();
    works[1].media_url = Some(server.url("/expired-new-list"));
    let d = acceptance::download_locked(
        locked,
        true,
        MediaPolicy::Loopback { port: server.port },
        dir.path(),
        &CancellationToken::new(),
        |_| {},
    )
    .await
    .unwrap();
    assert_eq!(server.counts(), (0, 1));
    assert!(server.requests.lock().unwrap()[0].starts_with("GET /original "));
    assert!(
        d.proof.sha256_match
            && d.proof.first_frame_covered
            && d.proof.middle_interval_covered
            && d.proof.end_interval_covered
            && d.proof.full_decode_ended
    );
    assert_eq!(d.proof.decoded_frames, 30);
    assert_eq!(d.proof.frame_rate, 30.0);
    assert!(!d.proof.decode_errors_observed);
}
#[tokio::test]
async fn locked_download_gate_and_exact_scope_reject_before_network() {
    let server = Server::new().await;
    let dir = tempfile::tempdir().unwrap();
    let mut w = extractor::extract(&work("1", server.port, "original")).unwrap();
    let locked = acceptance::lock(&[w.clone()], 1, true).unwrap();
    assert_eq!(
        acceptance::download_locked(
            locked,
            false,
            MediaPolicy::Loopback { port: server.port },
            dir.path(),
            &CancellationToken::new(),
            |_| {}
        )
        .await
        .err(),
        Some(Error::Authorization)
    );
    w.media_url = Some("https://outside.example/video".into());
    w.validation.playback_address_valid = true;
    let policy = MediaPolicy::authorized_test(
        TestScope {
            purpose: "single-video-test".into(),
            entry_host: "www.douyin.com".into(),
            cdn_host: "reviewed.example".into(),
            expires_unix: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_secs()
                + 60,
            max_downloads: 1,
        },
        true,
    )
    .unwrap();
    assert_eq!(
        acceptance::download_locked(
            acceptance::lock(&[w], 1, false).unwrap(),
            true,
            policy,
            dir.path(),
            &CancellationToken::new(),
            |_| {}
        )
        .await
        .err(),
        Some(Error::NetworkTarget)
    );
    assert_eq!(server.counts(), (0, 0));
    assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
}
#[tokio::test]
async fn cancellation_uses_shared_signal_token_and_cleans_part() {
    let server = Server::new().await;
    let dir = tempfile::tempdir().unwrap();
    let token = CancellationToken::new();
    let mut ui = Ui::new(&["AUTHORIZE LIST", "1", "DOWNLOAD 1"]);
    ui.cancel = Some(token.clone());
    let r = acceptance::run(&server.options("/list-slow", dir.path()), &mut ui, &token).await;
    assert_eq!(r.stop_reason, "CANCELLED");
    assert_eq!(r.temporary_file_cleanup, "PASS");
    assert!(!r.final_file_committed);
    assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
    assert_eq!(server.counts(), (1, 1));
}
#[tokio::test]
async fn actual_cli_acceptance_and_sanitized_json() {
    let server = Server::new().await;
    let dir = tempfile::tempdir().unwrap();
    let evidence = dir.path().join("evidence.json");
    let mut child = tokio::process::Command::new(env!("CARGO_BIN_EXE_doustudio"))
        .args([
            "acceptance",
            "--fixture-url",
            &server.url("/list"),
            "--output",
        ])
        .arg(dir.path())
        .arg("--evidence")
        .arg(&evidence)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"AUTHORIZE LIST\nCONTINUE PAGES\n1\nDOWNLOAD 1\n")
        .await
        .unwrap();
    let out = child.wait_with_output().await.unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let saved = std::fs::read_to_string(&evidence).unwrap();
    let r: Value = serde_json::from_str(&saved).unwrap();
    assert_eq!(r["stop_reason"], "COMPLETED");
    assert_eq!(r["verification"]["decoded_frames"], 30);
    assert_eq!(r["temporary_file_cleanup"], "PASS");
    assert_eq!(r["application_accepted_bytes"], r["written_bytes"]);
    assert_eq!(r["final_file_committed"], true);
    assert_eq!(server.counts(), (3, 1));
    assert_redacted(&saved);
    assert_redacted(&String::from_utf8_lossy(&out.stdout));
    assert_redacted(&String::from_utf8_lossy(&out.stderr));
    for request in server
        .requests
        .lock()
        .unwrap()
        .iter()
        .filter(|r| !r.starts_with("GET /list"))
    {
        let lower = request.to_lowercase();
        for forbidden in ["cookie:", "authorization:", "referer:", "range:"] {
            assert!(!lower.contains(forbidden));
        }
    }
    // Optional fixture-only evidence export; never enabled in a real acceptance run.
    if let Some(root) = std::env::var_os("DOUSTUDIO_ACCEPTANCE_TEST_EVIDENCE") {
        let root = std::path::PathBuf::from(root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("synthetic-cli-acceptance.json"), saved).unwrap();
        std::fs::write(root.join("synthetic-cli-console.log"), out.stderr).unwrap();
    }
}
