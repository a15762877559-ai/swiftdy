//! Single-process acceptance: typed diagnostics only, no persisted credentials or selection cache.
use crate::{
    auth::{self, Session},
    client::{self, RequestDiagnostic},
    extractor::Work,
    media::MediaPolicy,
    pagination::Pagination,
    signing, transport,
    verify::Verification,
    Error, Result,
};
use serde::Serialize;
use std::{
    collections::HashSet,
    io::{Read, Write},
    path::{Path, PathBuf},
    time::Instant,
};
use tokio_util::sync::CancellationToken;
#[cfg(not(feature = "offline-test"))]
use {crate::media::TestScope, std::io::IsTerminal};

#[derive(clap::Args)]
pub struct Options {
    /// Existing local directory for the single approved video. No video is put in evidence.
    #[arg(long)]
    pub output: PathBuf,
    /// New JSON file containing only sanitized diagnostics (never overwrites).
    #[arg(long)]
    pub evidence: Option<PathBuf>,
    /// Previously reviewed exact-host scope; read only after authorization B.
    #[arg(long)]
    pub test_scope: Option<PathBuf>,
    #[cfg(feature = "offline-test")]
    #[arg(long)]
    pub fixture_url: Option<String>,
}

pub trait Interaction {
    fn answer(&mut self, prompt: &str) -> Result<String>;
    fn session(&mut self) -> Result<Session>;
    fn show(&mut self, event: serde_json::Value);
}
pub struct Console;
impl Interaction for Console {
    fn answer(&mut self, prompt: &str) -> Result<String> {
        #[cfg(not(feature = "offline-test"))]
        if !std::io::stdin().is_terminal() {
            return Err(Error::Authorization);
        }
        eprint!("{prompt}: ");
        std::io::stderr().flush().map_err(|_| Error::Io)?;
        let mut line = String::new();
        std::io::stdin()
            .lock()
            .take(4097)
            .read_line_bounded(&mut line)?;
        Ok(line.trim().to_owned())
    }
    fn session(&mut self) -> Result<Session> {
        #[cfg(feature = "offline-test")]
        {
            Session::new(
                "UIFID_TEMP=synthetic; msToken=synthetic".into(),
                signing::USER_AGENT.into(),
            )
        }
        #[cfg(not(feature = "offline-test"))]
        {
            Session::prompt(signing::USER_AGENT.into())
        }
    }
    fn show(&mut self, event: serde_json::Value) {
        eprintln!("{event}");
    }
}
// Limit console input without accepting truncated confirmation/profile text.
trait BoundedLine: Read {
    fn read_line_bounded(&mut self, value: &mut String) -> Result<()> {
        let mut bytes = Vec::new();
        let mut b = [0];
        while self.read(&mut b).map_err(|_| Error::Io)? != 0 {
            if b[0] == b'\n' {
                break;
            }
            bytes.push(b[0]);
            if bytes.len() > 4096 {
                return Err(Error::Scope);
            }
        }
        *value = String::from_utf8(bytes).map_err(|_| Error::Scope)?;
        Ok(())
    }
}
impl<T: Read> BoundedLine for T {}

#[derive(Serialize)]
pub struct PageDiagnostic {
    pub page: usize,
    #[serde(flatten)]
    pub request: RequestDiagnostic,
    pub returned: usize,
    pub unique_in_page: usize,
    pub new_unique: usize,
    pub cumulative_unique: usize,
    pub duplicates: usize,
    pub has_more: Option<bool>,
    pub cursor_advanced: Option<bool>,
    pub cover_present: usize,
    pub cover_array_valid: usize,
    pub cover_https_hosts_valid: usize,
    pub ordinary_video: usize,
    pub playback_address_valid: usize,
    pub stop_reason: String,
    pub error_category: Option<String>,
}
impl PageDiagnostic {
    fn new(page: usize) -> Self {
        Self {
            page,
            request: RequestDiagnostic::default(),
            returned: 0,
            unique_in_page: 0,
            new_unique: 0,
            cumulative_unique: 0,
            duplicates: 0,
            has_more: None,
            cursor_advanced: None,
            cover_present: 0,
            cover_array_valid: 0,
            cover_https_hosts_valid: 0,
            ordinary_video: 0,
            playback_address_valid: 0,
            stop_reason: "NOT_RUN".into(),
            error_category: None,
        }
    }
}
#[derive(Serialize)]
pub struct ChoiceSummary {
    pub index: usize,
    pub created_at: i64,
    pub duration_ms: u64,
    pub width: i64,
    pub height: i64,
    pub bitrate: i64,
    pub selectable: bool,
}
fn selectable(w: &Work, loopback: bool) -> bool {
    w.downloadable
        && w.validation.ordinary_video
        && (w.validation.playback_address_valid
            || (loopback
                && w.media_url.as_deref().is_some_and(|s| {
                    url::Url::parse(s).is_ok_and(|u| {
                        u.scheme() == "http"
                            && u.host_str() == Some("127.0.0.1")
                            && u.port().is_some()
                    })
                })))
}
fn summary(w: &Work, index: usize, loopback: bool) -> ChoiceSummary {
    ChoiceSummary {
        index,
        created_at: w.created_at,
        duration_ms: w.duration_ms,
        width: w.width,
        height: w.height,
        bitrate: w.bitrate,
        selectable: selectable(w, loopback),
    }
}
// Neither Serialize nor Deserialize: immutable snapshot, consumed once at download.
pub struct LockedWork {
    work: Work,
}
pub fn lock(works: &[Work], index: usize, loopback: bool) -> Result<LockedWork> {
    #[cfg(not(feature = "offline-test"))]
    if loopback {
        return Err(Error::Scope);
    }
    let work = index
        .checked_sub(1)
        .and_then(|i| works.get(i))
        .filter(|w| selectable(w, loopback))
        .ok_or(Error::Selection)?
        .clone();
    Ok(LockedWork { work })
}
pub async fn download_locked(
    locked: LockedWork,
    authorized: bool,
    policy: MediaPolicy,
    output: &Path,
    cancel: &CancellationToken,
    progress: impl FnMut(transport::Progress),
) -> Result<transport::Download> {
    if !authorized {
        return Err(Error::Authorization);
    }
    if cancel.is_cancelled() {
        return Err(Error::Cancelled);
    }
    // No client/list calls here. An expired URL fails; no refresh or alternative selection exists.
    transport::download(
        locked.work.media_url.as_deref().ok_or(Error::Selection)?,
        policy,
        output,
        "accepted-video.mp4",
        cancel,
        progress,
    )
    .await
}

#[derive(Serialize)]
pub struct Report {
    pub task: &'static str,
    pub mode: &'static str,
    pub authorization_a: bool,
    pub pagination_confirmation: bool,
    pub authorization_b: bool,
    pub pages: Vec<PageDiagnostic>,
    pub choices: Vec<ChoiceSummary>,
    pub selected_index: Option<usize>,
    pub list_requests_started: usize,
    pub media_download_attempts: usize,
    pub application_accepted_bytes: u64,
    pub written_bytes: u64,
    pub operation_seconds: f64,
    pub final_file_committed: bool,
    pub temporary_file_cleanup: &'static str,
    pub verification: Option<Verification>,
    pub stop_reason: String,
    pub error_category: Option<String>,
    pub production_allowlist: &'static str,
    pub no_watermark: &'static str,
}
impl Default for Report {
    fn default() -> Self {
        Self {
            task: "DOUSTUDIOKIT_WINDOWS_RUST_ACCEPTANCE_ENTRY_02",
            mode: if cfg!(feature = "offline-test") {
                "LOOPBACK"
            } else {
                "LIVE_REQUIRES_LOCAL_CONSENT"
            },
            authorization_a: false,
            pagination_confirmation: false,
            authorization_b: false,
            pages: vec![],
            choices: vec![],
            selected_index: None,
            list_requests_started: 0,
            media_download_attempts: 0,
            application_accepted_bytes: 0,
            written_bytes: 0,
            operation_seconds: 0.0,
            final_file_committed: false,
            temporary_file_cleanup: "NOT_RUN",
            verification: None,
            stop_reason: "NOT_RUN".into(),
            error_category: None,
            production_allowlist: "EMPTY",
            no_watermark: "NOT_VERIFIED",
        }
    }
}
fn parts(path: &Path) -> Option<HashSet<PathBuf>> {
    std::fs::read_dir(path)
        .ok()?
        .map(|e| e.ok().map(|e| e.path()))
        .collect::<Option<Vec<_>>>()
        .map(|v| {
            v.into_iter()
                .filter(|p| p.extension().is_some_and(|e| e == "part"))
                .collect()
        })
}
fn policy(options: &Options) -> Result<MediaPolicy> {
    #[cfg(feature = "offline-test")]
    {
        if options.test_scope.is_some() {
            return Err(Error::Scope);
        }
        let u = fixture(options)?;
        Ok(MediaPolicy::Loopback {
            port: u.port().ok_or(Error::Scope)?,
        })
    }
    #[cfg(not(feature = "offline-test"))]
    {
        let file = options.test_scope.as_ref().ok_or(Error::ProductionDenied)?;
        let mut bytes = vec![];
        std::fs::File::open(file)
            .map_err(|_| Error::TestScope)?
            .take(4097)
            .read_to_end(&mut bytes)
            .map_err(|_| Error::TestScope)?;
        if bytes.len() > 4096 {
            return Err(Error::TestScope);
        }
        let scope: TestScope = serde_json::from_slice(&bytes).map_err(|_| Error::TestScope)?;
        MediaPolicy::authorized_test(scope, true)
    }
}
#[cfg(feature = "offline-test")]
fn fixture(options: &Options) -> Result<url::Url> {
    let u = url::Url::parse(options.fixture_url.as_deref().ok_or(Error::Scope)?)
        .map_err(|_| Error::Scope)?;
    if u.scheme() != "http"
        || u.host_str() != Some("127.0.0.1")
        || u.port().is_none()
        || !u.username().is_empty()
        || u.password().is_some()
        || u.fragment().is_some()
        || u.query().is_some()
    {
        return Err(Error::Scope);
    }
    Ok(u)
}
pub async fn run(
    options: &Options,
    io: &mut impl Interaction,
    cancel: &CancellationToken,
) -> Report {
    let mut report = Report::default();
    if let Err(e) = run_inner(options, io, cancel, &mut report).await {
        if report.error_category.is_none() {
            report.error_category = Some(e.to_string());
        }
        report.stop_reason = if e == Error::Cancelled {
            "CANCELLED"
        } else {
            "FAILED"
        }
        .into();
    }
    report
}
async fn run_inner(
    options: &Options,
    io: &mut impl Interaction,
    cancel: &CancellationToken,
    r: &mut Report,
) -> Result<()> {
    #[cfg(not(feature = "offline-test"))]
    if std::env::var_os("DOUSTUDIO_OFFLINE_ONLY").is_some() {
        return Err(Error::Authorization);
    }
    #[cfg(feature = "offline-test")]
    let fixture_url = fixture(options)?;
    if io.answer(
        "Authorization A: owned/authorized profile only. Type AUTHORIZE LIST (otherwise stop)",
    )? != "AUTHORIZE LIST"
    {
        r.stop_reason = "AUTHORIZATION_A_DECLINED".into();
        return Ok(());
    }
    r.authorization_a = true;
    #[cfg(not(feature = "offline-test"))]
    let user = auth::profile_id(&io.answer("Authorized HTTPS profile (local input only)")?)?;
    #[cfg(feature = "offline-test")]
    let user = "synthetic-profile".to_owned();
    let session = io.session()?;
    let mut pager = Pagination::new(3)?;
    loop {
        let mut d = PageDiagnostic::new(pager.pages + 1);
        #[cfg(not(feature = "offline-test"))]
        let request = client::fetch_page_observed(&session, &user, pager.cursor, &mut d.request);
        #[cfg(feature = "offline-test")]
        let request = async {
            // Exercise the same native signer per page; only the destination is replaced in this test-only build.
            let signed = signing::list_url(&session, &user, pager.cursor)?;
            let checked = auth::signed_request(&signed, &user, pager.cursor)?;
            d.request.signing_completed = true;
            let mut u = fixture_url.clone();
            u.set_query(checked.query());
            client::request_page_observed(u, &session, true, &mut d.request).await
        };
        let result = tokio::select! {biased; _=cancel.cancelled()=>Err(Error::Cancelled),result=request=>result};
        r.list_requests_started += usize::from(d.request.request_started);
        let page = match result {
            Ok(p) => p,
            Err(e) => {
                let category = d.request.error_category(&e);
                d.error_category = Some(category.clone());
                d.stop_reason = "FAILED".into();
                r.error_category = Some(category);
                io.show(serde_json::to_value(&d).map_err(|_| Error::Schema)?);
                r.pages.push(d);
                return Err(e);
            }
        };
        d.returned = page.works.len();
        d.unique_in_page = page
            .works
            .iter()
            .map(|w| w.id.as_str())
            .collect::<HashSet<_>>()
            .len();
        d.has_more = Some(page.more);
        d.cursor_advanced = page
            .more
            .then_some(page.cursor.is_some_and(|c| c != 0 && c != pager.cursor));
        for w in &page.works {
            d.cover_present += usize::from(w.validation.cover_present);
            d.cover_array_valid += usize::from(w.validation.cover_array_valid);
            d.cover_https_hosts_valid += usize::from(w.validation.cover_https_hosts_valid);
            d.ordinary_video += usize::from(w.validation.ordinary_video);
            d.playback_address_valid += usize::from(w.validation.playback_address_valid);
        }
        let before = pager.works.len();
        let advance = pager.advance(page);
        d.new_unique = pager.works.len() - before;
        d.cumulative_unique = pager.works.len();
        d.duplicates = d.returned - d.new_unique;
        d.stop_reason = pager.stop_reason.into();
        if let Err(e) = &advance {
            d.error_category = Some(e.to_string());
            d.stop_reason = "FAILED".into();
            if *e == Error::Cursor && d.has_more == Some(true) {
                d.cursor_advanced = Some(false);
            }
        }
        io.show(serde_json::to_value(&d).map_err(|_| Error::Schema)?);
        r.pages.push(d);
        if !advance? {
            break;
        }
        if pager.pages == 1 {
            if io.answer("First page passed. Type CONTINUE PAGES for at most three pages total")?
                != "CONTINUE PAGES"
            {
                r.stop_reason = "PAGINATION_DECLINED".into();
                return Ok(());
            }
            r.pagination_confirmation = true;
        }
        tokio::select! {biased; _=cancel.cancelled()=>return Err(Error::Cancelled),_=tokio::time::sleep(std::time::Duration::from_secs(1))=>()}
    }
    // Credential owner is dropped before selection/download; media has its own client.
    drop(session);
    r.choices = pager
        .works
        .iter()
        .enumerate()
        .map(|(i, w)| summary(w, i + 1, cfg!(feature = "offline-test")))
        .collect();
    io.show(serde_json::to_value(&r.choices).map_err(|_| Error::Schema)?);
    if pager.works.is_empty() {
        r.stop_reason = "EMPTY_WORKLIST".into();
        return Ok(());
    }
    let selection = io.answer("Select this run's index (0 or empty cancels)")?;
    if selection.is_empty() || selection == "0" {
        r.stop_reason = "SELECTION_CANCELLED".into();
        return Ok(());
    }
    let index = selection.parse::<usize>().map_err(|_| Error::Selection)?;
    let locked = lock(&pager.works, index, cfg!(feature = "offline-test"))?;
    r.selected_index = Some(index);
    io.show(serde_json::json!({"locked":summary(&locked.work,index,cfg!(feature="offline-test")),"refetch":false}));
    if io.answer(&format!("Authorization B: complete download of locked index {index}, at most 100 MiB. Type DOWNLOAD {index}"))?!=format!("DOWNLOAD {index}") {r.stop_reason="AUTHORIZATION_B_DECLINED".into();return Ok(());}
    r.authorization_b = true;
    if cancel.is_cancelled() {
        return Err(Error::Cancelled);
    }
    let policy = policy(options)?;
    policy.check(
        locked.work.media_url.as_deref().ok_or(Error::Selection)?,
        false,
    )?;
    let before = parts(&options.output).ok_or(Error::Io)?;
    r.media_download_attempts = 1;
    let start = Instant::now();
    let mut last = Instant::now() - std::time::Duration::from_secs(1);
    let result=download_locked(locked,true,policy,&options.output,cancel,|p|{
        r.application_accepted_bytes=p.received;r.written_bytes=p.received;
        if last.elapsed().as_millis()>=200 || p.total==Some(p.received) {io.show(serde_json::json!({"state":"DOWNLOADING","received_bytes":p.received,"written_bytes":p.received,"total_bytes":p.total,"speed_bytes_per_second":p.bytes_per_second,"transport_delivered_bytes":p.transport_delivered_bytes}));last=Instant::now();}
    }).await;
    r.operation_seconds = start.elapsed().as_secs_f64();
    r.temporary_file_cleanup = if parts(&options.output).is_some_and(|after| after == before) {
        "PASS"
    } else {
        "FAIL"
    };
    let downloaded = result?;
    r.final_file_committed = true;
    r.verification = Some(downloaded.proof);
    r.stop_reason = "COMPLETED".into();
    Ok(())
}

pub async fn cli(options: Options, cancel: &CancellationToken) -> Result<()> {
    // Reserve a new evidence file before any request. No accidental overwrite after a download.
    let mut evidence = options
        .evidence
        .as_ref()
        .map(|p| {
            std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(p)
                .map_err(|_| Error::Io)
        })
        .transpose()?;
    let report = run(&options, &mut Console, cancel).await;
    let json = serde_json::to_string_pretty(&report).map_err(|_| Error::Schema)?;
    if let Some(f) = evidence.as_mut() {
        f.write_all(json.as_bytes()).map_err(|_| Error::Io)?;
        f.sync_all().map_err(|_| Error::Io)?;
    }
    println!("{json}");
    if report.stop_reason == "CANCELLED" {
        return Err(Error::Cancelled);
    }
    if report.error_category.is_some() {
        return Err(Error::Acceptance);
    }
    Ok(())
}
