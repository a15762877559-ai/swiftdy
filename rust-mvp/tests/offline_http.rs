#![cfg(feature = "offline-test")]
use doustudio_rust::{
    auth::Session, client, media::MediaPolicy, pagination::Pagination, transport, verify, Error,
    MAX_MEDIA_BYTES,
};
use std::{
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
};
use tokio_util::sync::CancellationToken;

struct Server {
    port: u16,
    requests: Arc<Mutex<Vec<String>>>,
    task: tokio::task::JoinHandle<()>,
}

#[tokio::test]
async fn default_tls_rejects_self_signed_server() {
    use tokio_rustls::{rustls, TlsAcceptor};
    let cert =
        rcgen::generate_simple_self_signed(vec!["localhost".into(), "127.0.0.1".into()]).unwrap();
    let key = rustls::pki_types::PrivatePkcs8KeyDer::from(cert.key_pair.serialize_der());
    let config = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![cert.cert.der().clone()], key.into())
        .unwrap();
    let acceptor = TlsAcceptor::from(Arc::new(config));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(async move {
        let (socket, _) = listener.accept().await.unwrap();
        assert!(acceptor.accept(socket).await.is_err());
    });
    let url = url::Url::parse(&format!("https://127.0.0.1:{port}/")).unwrap();
    let client = doustudio_rust::media::pinned_client(&url, true)
        .await
        .unwrap();
    assert!(client.get(url).send().await.is_err());
    server.await.unwrap();
}

#[tokio::test]
async fn actual_cli_list_download_verify() {
    let server = Server::new().await;
    let dir = tempfile::tempdir().unwrap();
    let binary = env!("CARGO_BIN_EXE_doustudio");
    let result = tokio::process::Command::new(binary)
        .args([
            "list",
            "--fixture-url",
            &server.url("/list"),
            "--pages",
            "3",
        ])
        .output()
        .await
        .unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    let out = String::from_utf8(result.stdout).unwrap();
    assert!(out.contains("9223372036854775807"));
    assert_eq!(server.count(), 2);
    let result = tokio::process::Command::new(binary)
        .args([
            "download",
            "--fixture-url",
            &server.url("/list"),
            "--index",
            "1",
            "--output",
        ])
        .arg(dir.path())
        .output()
        .await
        .unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    assert!(String::from_utf8_lossy(&result.stderr).contains("received_bytes="));
    assert_eq!(server.count(), 4);
    let result = tokio::process::Command::new(binary)
        .arg("verify")
        .arg(dir.path().join("video-1.mp4"))
        .output()
        .await
        .unwrap();
    assert!(result.status.success());
    assert!(String::from_utf8_lossy(&result.stdout).contains("\"decoded_frames\":30"));
    let result = tokio::process::Command::new(binary)
        .args([
            "list",
            "--profile",
            "https://www.douyin.com/user/fixture",
            "--authorized-session",
        ])
        .output()
        .await
        .unwrap();
    assert!(!result.status.success());
    assert_eq!(server.count(), 4);
}
impl Drop for Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl Server {
    async fn new() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let requests = Arc::new(Mutex::new(vec![]));
        let r = requests.clone();
        let task = tokio::spawn(async move {
            while let Ok((s, _)) = listener.accept().await {
                let r = r.clone();
                tokio::spawn(async move {
                    let _ = serve(s, port, r).await;
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
    fn policy(&self) -> MediaPolicy {
        MediaPolicy::Loopback { port: self.port }
    }
    fn count(&self) -> usize {
        self.requests.lock().unwrap().len()
    }
    fn assert_media_clean(&self) {
        for r in self.requests.lock().unwrap().iter() {
            let h = r.to_lowercase();
            for name in ["cookie:", "authorization:", "range:", "referer:"] {
                assert!(!h.contains(name), "{name}");
            }
        }
    }
}
fn fixture() -> Vec<u8> {
    std::fs::read(
        std::env::var_os("DOUSTUDIO_FIXTURE_MP4")
            .expect("Run scripts/offline-acceptance.ps1 to create the synthetic MP4"),
    )
    .unwrap()
}
async fn serve(
    mut s: TcpStream,
    port: u16,
    requests: Arc<Mutex<Vec<String>>>,
) -> std::io::Result<()> {
    let mut input = vec![];
    let mut one = [0u8; 1];
    while input.len() < 32768 && !input.ends_with(b"\r\n\r\n") {
        if s.read(&mut one).await? == 0 {
            return Ok(());
        }
        input.push(one[0]);
    }
    let req = String::from_utf8_lossy(&input).to_string();
    let path = req.split_whitespace().nth(1).unwrap_or("/").to_owned();
    requests.lock().unwrap().push(req);
    if path.starts_with("/status/") {
        let status = path.trim_start_matches("/status/");
        s.write_all(
            format!("HTTP/1.1 {status} Denied\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                .as_bytes(),
        )
        .await?;
        return Ok(());
    }
    if path.starts_with("/list") {
        let second = path.contains("max_cursor=987654321012345678");
        let body=serde_json::to_vec(&serde_json::json!({"status_code":0,"has_more":!second,"max_cursor":if second {0}else{987654321012345678u64},"aweme_list":[{"aweme_id":if second {"9223372036854775807"}else{"1234567890123456789"},"create_time":1,"desc":"fixture","video":{"duration":1000,"play_addr":{"url_list":[format!("http://127.0.0.1:{port}/ok")]}}}]})).unwrap();
        s.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",body.len()).as_bytes()).await?;
        s.write_all(&body).await?;
        return Ok(());
    }
    if path == "/redirect" || path == "/forbidden-redirect" || path == "/loop" {
        let target = if path == "/forbidden-redirect" {
            "http://127.0.0.2:1/ok".into()
        } else {
            format!(
                "http://127.0.0.1:{port}/{}",
                if path == "/loop" { "loop" } else { "ok" }
            )
        };
        s.write_all(
            format!("HTTP/1.1 302 Found\r\nLocation: {target}\r\nContent-Length: 0\r\n\r\n")
                .as_bytes(),
        )
        .await?;
        return Ok(());
    }
    if path == "/declared-over" {
        s.write_all(
            format!(
                "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: {}\r\n\r\n",
                MAX_MEDIA_BYTES + 1
            )
            .as_bytes(),
        )
        .await?;
        return Ok(());
    }
    if path == "/partial" {
        s.write_all(b"HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Length: 1\r\nContent-Range: bytes 0-0/999\r\n\r\nx").await?;
        return Ok(());
    }
    if path == "/html" {
        s.write_all(
            b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 5\r\n\r\nhello",
        )
        .await?;
        return Ok(());
    }
    if path == "/encoded" {
        s.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Encoding: gzip\r\nContent-Length: 5\r\n\r\nhello").await?;
        return Ok(());
    }
    if path == "/empty" {
        s.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: 0\r\n\r\n")
            .await?;
        return Ok(());
    }
    if path == "/slow" {
        s.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nConnection: close\r\n\r\n")
            .await?;
        for _ in 0..100 {
            s.write_all(&[0u8; 1024]).await?;
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        return Ok(());
    }
    let mut body = fixture();
    if path == "/corrupt" {
        if let Some(p) = body.windows(4).position(|s| s == b"mdat") {
            body[p + 4..].fill(0);
        }
    }
    if path == "/container" {
        body.truncate(24);
    }
    let huge = path == "/exact-cap" || path == "/unknown-over";
    let total = if huge {
        MAX_MEDIA_BYTES
    } else {
        body.len() as u64
    };
    let chunked = path == "/chunked";
    let unknown = path == "/unknown-over" || path == "/unknown";
    let mut headers = if path == "/full206" {
        format!(
            "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-{}/{}\r\n",
            total - 1,
            total
        )
    } else {
        "HTTP/1.1 200 OK\r\n".into()
    };
    headers.push_str("Content-Type: video/mp4\r\nConnection: close\r\n");
    if chunked {
        headers.push_str("Transfer-Encoding: chunked\r\n");
    } else if !unknown {
        headers.push_str(&format!("Content-Length: {total}\r\n"));
    }
    headers.push_str("\r\n");
    s.write_all(headers.as_bytes()).await?;
    if path == "/disconnect" {
        s.write_all(&body[..body.len() / 2]).await?;
        return Ok(());
    }
    if chunked {
        for c in body.chunks(71) {
            s.write_all(format!("{:X}\r\n", c.len()).as_bytes()).await?;
            s.write_all(c).await?;
            s.write_all(b"\r\n").await?;
        }
        s.write_all(b"0\r\n\r\n").await?;
        return Ok(());
    }
    s.write_all(&body).await?;
    if huge {
        let free = total - body.len() as u64;
        s.write_all(&(free as u32).to_be_bytes()).await?;
        s.write_all(b"free").await?;
        let mut remaining = free - 8 + if unknown { 1 } else { 0 };
        let zeros = [0u8; 65536];
        while remaining > 0 {
            let n = (remaining as usize).min(zeros.len());
            s.write_all(&zeros[..n]).await?;
            remaining -= n as u64;
        }
    }
    Ok(())
}

async fn success(path: &str, requests: usize) {
    let server = Server::new().await;
    let dir = tempfile::tempdir().unwrap();
    let cancel = CancellationToken::new();
    let mut progress = vec![];
    let d = transport::download(
        &server.url(path),
        server.policy(),
        dir.path(),
        "video.mp4",
        &cancel,
        |p| progress.push(p.received),
    )
    .await
    .unwrap();
    assert!(d.proof.full_video_decode);
    assert_eq!(d.proof.decoded_frames, 30);
    assert_eq!(d.proof.no_watermark, "NOT_VERIFIED");
    assert_eq!(
        std::fs::metadata(&d.path).unwrap().len(),
        *progress.last().unwrap()
    );
    assert!(progress.windows(2).all(|p| p[0] <= p[1]));
    assert!(progress.iter().all(|n| *n <= MAX_MEDIA_BYTES));
    assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 1);
    assert_eq!(server.count(), requests);
    server.assert_media_clean();
    if path == "/exact-cap" {
        assert_eq!(d.proof.file_bytes, MAX_MEDIA_BYTES);
    }
}
#[tokio::test]
async fn full_200_mp4_actual_decode() {
    success("/ok", 1).await;
}
#[tokio::test]
async fn full_206_mp4_actual_decode() {
    success("/full206", 1).await;
}
#[tokio::test]
async fn unknown_length_complete_mp4() {
    success("/unknown", 1).await;
}
#[tokio::test]
async fn chunked_mp4_actual_decode() {
    success("/chunked", 1).await;
}
#[tokio::test]
async fn approved_single_redirect() {
    success("/redirect", 2).await;
}
#[tokio::test]
async fn exact_100_mib_file_and_decode() {
    success("/exact-cap", 1).await;
}

#[tokio::test]
async fn rejected_responses_never_commit_and_never_retry() {
    for (path, expected) in [
        ("/declared-over", Error::Budget),
        ("/partial", Error::Headers),
        ("/html", Error::Headers),
        ("/encoded", Error::Headers),
        ("/empty", Error::Length),
        ("/disconnect", Error::Network),
        ("/container", Error::Container),
        ("/corrupt", Error::Decode),
        ("/forbidden-redirect", Error::Redirect),
        ("/loop", Error::Redirect),
    ] {
        let server = Server::new().await;
        let dir = tempfile::tempdir().unwrap();
        let r = transport::download(
            &server.url(path),
            server.policy(),
            dir.path(),
            "video.mp4",
            &CancellationToken::new(),
            |_| {},
        )
        .await;
        assert_eq!(r.err(), Some(expected), "{path}");
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0, "{path}");
        assert_eq!(server.count(), if path == "/loop" { 2 } else { 1 });
        server.assert_media_clean();
    }
}
#[tokio::test]
async fn unknown_over_budget_accepts_at_most_cap_and_cleans() {
    let server = Server::new().await;
    let dir = tempfile::tempdir().unwrap();
    let mut peak = 0;
    let r = transport::download(
        &server.url("/unknown-over"),
        server.policy(),
        dir.path(),
        "video.mp4",
        &CancellationToken::new(),
        |p| {
            peak = peak.max(p.received);
            assert!(p.received <= MAX_MEDIA_BYTES);
        },
    )
    .await;
    assert_eq!(r.err(), Some(Error::Budget));
    assert_eq!(peak, MAX_MEDIA_BYTES);
    assert_eq!(server.count(), 1);
    assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
}
#[tokio::test]
async fn midstream_cancel_reaps_and_cleans() {
    let server = Server::new().await;
    let dir = tempfile::tempdir().unwrap();
    let cancel = CancellationToken::new();
    let token = cancel.clone();
    let r = transport::download(
        &server.url("/slow"),
        server.policy(),
        dir.path(),
        "video.mp4",
        &cancel,
        |p| {
            if p.received >= 1024 {
                token.cancel()
            }
        },
    )
    .await;
    assert_eq!(r.err(), Some(Error::Cancelled));
    assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
    assert_eq!(server.count(), 1);
}
#[tokio::test]
async fn already_cancelled_zero_requests() {
    let server = Server::new().await;
    let dir = tempfile::tempdir().unwrap();
    let cancel = CancellationToken::new();
    cancel.cancel();
    let r = transport::download(
        &server.url("/ok"),
        server.policy(),
        dir.path(),
        "video.mp4",
        &cancel,
        |_| {},
    )
    .await;
    assert_eq!(r.err(), Some(Error::Cancelled));
    assert_eq!(server.count(), 0);
    assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
}
#[tokio::test]
async fn actual_http_cursor_chain() {
    let server = Server::new().await;
    let session = Session::new("fixture=synthetic".into(), "synthetic".into()).unwrap();
    let mut pager = Pagination::new(3).unwrap();
    loop {
        let url =
            url::Url::parse(&server.url(&format!("/list?max_cursor={}", pager.cursor))).unwrap();
        let page = client::request_page(url, &session, true).await.unwrap();
        if !pager.advance(page).unwrap() {
            break;
        }
    }
    assert_eq!(pager.works.len(), 2);
    assert_eq!(pager.stop_reason, "SERVER_EXHAUSTED");
    assert_eq!(server.count(), 2);
    assert!(server.requests.lock().unwrap()[1].contains("max_cursor=987654321012345678"));
}
#[tokio::test]
async fn standalone_verify_and_truncation() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("test.mp4");
    let body = fixture();
    std::fs::write(&path, &body).unwrap();
    assert_eq!(
        verify::verify(&path, Some(body.len() as u64), &CancellationToken::new())
            .await
            .unwrap()
            .decoded_frames,
        30
    );
    std::fs::write(&path, &body[..body.len() / 2]).unwrap();
    assert!(verify::verify(&path, None, &CancellationToken::new())
        .await
        .is_err());
}

#[tokio::test]
async fn list_restrictions_and_challenge_do_not_retry() {
    let server = Server::new().await;
    let session = Session::new("fixture=synthetic".into(), "synthetic".into()).unwrap();
    for (path, expected) in [
        ("/status/403", Error::Access),
        ("/status/401", Error::Access),
        ("/status/429", Error::RateLimited),
        ("/html", Error::Challenge),
        ("/redirect", Error::Redirect),
    ] {
        let before = server.count();
        let r =
            client::request_page(url::Url::parse(&server.url(path)).unwrap(), &session, true).await;
        assert_eq!(r.err(), Some(expected));
        assert_eq!(server.count(), before + 1);
    }
}

#[tokio::test]
async fn cancellation_during_verification_allows_windows_cleanup() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("test.mp4");
    std::fs::write(&path, fixture()).unwrap();
    let cancel = CancellationToken::new();
    let token = cancel.clone();
    let timer = tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(5)).await;
        token.cancel();
    });
    assert_eq!(
        verify::verify(&path, None, &cancel).await.err(),
        Some(Error::Cancelled)
    );
    timer.await.unwrap();
    std::fs::remove_file(&path).unwrap();
    assert!(!path.exists());
}

#[tokio::test]
async fn output_conflict_is_blocked_before_network() {
    let server = Server::new().await;
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("video.mp4");
    std::fs::write(&file, b"keep").unwrap();
    let r = transport::download(
        &server.url("/ok"),
        server.policy(),
        dir.path(),
        "video.mp4",
        &CancellationToken::new(),
        |_| {},
    )
    .await;
    assert_eq!(r.err(), Some(Error::Exists));
    assert_eq!(server.count(), 0);
    assert_eq!(std::fs::read(file).unwrap(), b"keep");
}
