#[cfg(not(feature = "offline-test"))]
use crate::{auth::profile_id, media::TestScope};
use crate::{
    auth::Session, client, media::MediaPolicy, pagination::Pagination, signing, transport, verify,
    Error, Result,
};
use clap::{Args, Parser, Subcommand};
use std::{
    path::PathBuf,
    time::{Duration, Instant},
};
use tokio_util::sync::CancellationToken;

#[derive(Parser)]
#[command(
    name = "doustudio",
    version,
    about = "Windows Rust authorized worklist and bounded MP4 download"
)]
pub struct Cli {
    #[command(subcommand)]
    command: Commands,
}
#[derive(Subcommand)]
enum Commands {
    /// Entirely local Cookie structure diagnostic. No signing, DNS, or HTTP.
    CredentialCheck(crate::credentials::Options),
    /// Interactive, separately authorized acceptance with a single in-memory selection.
    Acceptance(crate::acceptance::Options),
    List(ListArgs),
    Download {
        #[command(flatten)]
        list: ListArgs,
        #[arg(long)]
        index: usize,
        #[arg(long)]
        output: PathBuf,
        #[arg(long)]
        test_scope: Option<PathBuf>,
        #[arg(long)]
        authorize_test_download: bool,
    },
    Verify {
        file: PathBuf,
    },
}
#[derive(Args)]
struct ListArgs {
    #[arg(long)]
    profile: Option<String>,
    #[arg(long, default_value_t = 1)]
    pages: usize,
    #[arg(long)]
    authorized_session: bool,
    #[cfg(feature = "offline-test")]
    #[arg(long)]
    fixture_url: Option<String>,
}

async fn collect(args: &ListArgs, cancel: &CancellationToken) -> Result<Pagination> {
    let mut pager = Pagination::new(args.pages)?;
    #[cfg(feature = "offline-test")]
    {
        // A fixture-enabled CLI can never make real account requests.
        let raw = args.fixture_url.as_ref().ok_or(Error::Scope)?;
        let mut url = url::Url::parse(raw).map_err(|_| Error::Scope)?;
        if url.scheme() != "http" || url.host_str() != Some("127.0.0.1") || url.port().is_none() {
            return Err(Error::Scope);
        }
        let s = Session::new("fixture=synthetic".into(), signing::USER_AGENT.into())?;
        loop {
            url.set_query(Some(&format!(
                "max_cursor={}&count=18&sec_user_id=fixture",
                pager.cursor
            )));
            let page = tokio::select! {_ = cancel.cancelled()=>return Err(Error::Cancelled),r=client::request_page(url.clone(),&s,true)=>r?};
            if !pager.advance(page)? {
                break;
            }
        }
        Ok(pager)
    }
    #[cfg(not(feature = "offline-test"))]
    {
        if !args.authorized_session || std::env::var_os("DOUSTUDIO_OFFLINE_ONLY").is_some() {
            return Err(Error::Authorization);
        }
        let user = profile_id(args.profile.as_deref().ok_or(Error::Scope)?)?;
        let session = Session::prompt(signing::USER_AGENT.into())?;
        loop {
            let page = tokio::select! {_ = cancel.cancelled()=>return Err(Error::Cancelled),r=client::fetch_page(&session,&user,pager.cursor)=>r?};
            if !pager.advance(page)? {
                break;
            }
            tokio::select! {_ = cancel.cancelled()=>return Err(Error::Cancelled),_ = tokio::time::sleep(Duration::from_secs(1))=>()};
        }
        Ok(pager)
    }
}

pub fn run() -> Result<()> {
    let cli = Cli::parse();
    if let Commands::CredentialCheck(options) = cli.command {
        return crate::credentials::run(options);
    }
    tokio::runtime::Runtime::new()
        .map_err(|_| Error::Io)?
        .block_on(run_async(cli))
}
async fn run_async(cli: Cli) -> Result<()> {
    #[cfg(feature = "offline-test")]
    crate::assert_active_operations_allowed();
    let cancel = CancellationToken::new();
    let signal = cancel.clone();
    tokio::spawn(async move {
        if tokio::signal::ctrl_c().await.is_ok() {
            signal.cancel();
        }
    });
    match cli.command {
        Commands::CredentialCheck(_) => {
            unreachable!("offline command exits before runtime construction")
        }
        Commands::Acceptance(options) => crate::acceptance::cli(options, &cancel).await?,
        Commands::List(args) => {
            let p = collect(&args, &cancel).await?;
            for (i, w) in p.works.iter().enumerate() {
                // JSON escapes terminal control sequences in untrusted titles.
                println!(
                    "{} {}",
                    i + 1,
                    serde_json::to_string(w).map_err(|_| Error::Schema)?
                );
            }
            eprintln!(
                "pages={} unique={} duplicates={} stop={}",
                p.pages,
                p.works.len(),
                p.duplicates,
                p.stop_reason
            );
        }
        Commands::Download {
            list,
            index,
            output,
            test_scope,
            authorize_test_download,
        } => {
            #[cfg(feature = "offline-test")]
            let policy = {
                if test_scope.is_some() || authorize_test_download {
                    return Err(Error::Scope);
                }
                let u = url::Url::parse(list.fixture_url.as_deref().ok_or(Error::Scope)?)
                    .map_err(|_| Error::Scope)?;
                MediaPolicy::Loopback {
                    port: u.port().ok_or(Error::Scope)?,
                }
            };
            #[cfg(not(feature = "offline-test"))]
            let policy = if let Some(file) = test_scope {
                use std::io::Read;
                let mut bytes = Vec::new();
                std::fs::File::open(file)
                    .map_err(|_| Error::TestScope)?
                    .take(4097)
                    .read_to_end(&mut bytes)
                    .map_err(|_| Error::TestScope)?;
                if bytes.len() > 4096 {
                    return Err(Error::TestScope);
                }
                let scope: TestScope =
                    serde_json::from_slice(&bytes).map_err(|_| Error::TestScope)?;
                MediaPolicy::authorized_test(scope, authorize_test_download)?
            } else {
                MediaPolicy::Production
            };
            // Empty production policy blocks before reading credentials or making list requests.
            if matches!(policy, MediaPolicy::Production) {
                return Err(Error::ProductionDenied);
            }
            if index == 0 {
                return Err(Error::Selection);
            }
            let p = collect(&list, &cancel).await?;
            let work = p
                .works
                .get(index - 1)
                .filter(|w| w.downloadable)
                .ok_or(Error::Selection)?;
            eprintln!(
                "selected_index={} {}",
                index,
                serde_json::to_string(work).map_err(|_| Error::Schema)?
            );
            let url = work.media_url.as_deref().ok_or(Error::Selection)?;
            let mut last = Instant::now() - Duration::from_secs(1);
            let result=transport::download(url,policy,&output,&format!("video-{index}.mp4"),&cancel,|p|{
                if last.elapsed()>=Duration::from_millis(200) || p.total==Some(p.received) {
                    eprintln!("received_bytes={} total_bytes={} speed_bytes_per_second={:.0} transport_delivered_bytes={} state=DOWNLOADING",p.received,p.total.map(|n|n.to_string()).unwrap_or_else(||"UNKNOWN".into()),p.bytes_per_second,p.transport_delivered_bytes);
                    last=Instant::now();
                }
            }).await?;
            println!(
                "{}",
                serde_json::to_string(&result.proof).map_err(|_| Error::Schema)?
            );
            eprintln!("state=COMPLETED application_accepted_bytes={} written_bytes={} transport_delivered_bytes={}",result.proof.file_bytes,result.proof.file_bytes,result.transport_delivered_bytes);
        }
        Commands::Verify { file } => {
            let proof = verify::verify(&file, None, &cancel).await?;
            println!(
                "{}",
                serde_json::to_string(&proof).map_err(|_| Error::Schema)?
            );
        }
    }
    Ok(())
}
