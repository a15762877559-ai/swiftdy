use crate::{
    media::{pinned_client, MediaPolicy},
    storage::Staging,
    verify::{verify, Verification},
    Error, Result, BUFFER_BYTES, MAX_MEDIA_BYTES,
};
use futures_util::TryStreamExt;
use reqwest::{
    header::{CONTENT_ENCODING, CONTENT_LENGTH, CONTENT_RANGE, CONTENT_TYPE, LOCATION},
    Response,
};
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc,
};
use std::{
    path::{Path, PathBuf},
    time::Instant,
};
use tokio::io::AsyncReadExt;
use tokio_util::{io::StreamReader, sync::CancellationToken};

#[derive(Debug)]
pub struct Progress {
    pub received: u64,
    pub total: Option<u64>,
    pub bytes_per_second: f64,
    pub transport_delivered_bytes: u64,
}
pub struct Download {
    pub path: PathBuf,
    pub proof: Verification,
    pub transport_delivered_bytes: u64,
}

pub fn declared_length(response: &Response) -> Result<Option<u64>> {
    let h = response.headers();
    if h.get(CONTENT_ENCODING).is_some_and(|v| v != "identity") {
        return Err(Error::Headers);
    }
    let mime = h
        .get(CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .split(';')
        .next()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    if !["video/mp4", "video/quicktime", "application/octet-stream"].contains(&mime.as_str()) {
        return Err(Error::Headers);
    }
    let length = h
        .get(CONTENT_LENGTH)
        .map(|v| {
            v.to_str()
                .ok()
                .and_then(|s| s.parse::<u64>().ok())
                .ok_or(Error::Headers)
        })
        .transpose()?;
    if length.is_some_and(|n| n > MAX_MEDIA_BYTES) {
        return Err(Error::Budget);
    }
    if length == Some(0) {
        return Err(Error::Length);
    }
    match response.status().as_u16() {
        200 if !h.contains_key(CONTENT_RANGE) => (),
        206 => {
            let n = length.ok_or(Error::Headers)?;
            let expected = format!("bytes 0-{}/{}", n - 1, n);
            if h.get(CONTENT_RANGE).and_then(|v| v.to_str().ok()) != Some(expected.as_str()) {
                return Err(Error::Headers);
            }
        }
        _ => return Err(Error::Headers),
    }
    Ok(length)
}

pub async fn download(
    raw: &str,
    policy: MediaPolicy,
    directory: &Path,
    name: &str,
    cancel: &CancellationToken,
    mut progress: impl FnMut(Progress),
) -> Result<Download> {
    // Scope is consumed per invocation; there is no persisted production approval.
    let mut u = policy.check(raw, false)?;
    let mut stage = Staging::new(directory, name)?;
    let delivered = Arc::new(AtomicU64::new(0));
    let received = tokio::select! {
        biased;
        _ = cancel.cancelled() => Err(Error::Cancelled),
        result = async {
            let mut redirects = 0;
            let response = loop {
                let client = pinned_client(&u,policy.loopback()).await?;
                let response = client.get(u.clone()).header("Accept-Encoding","identity").send().await.map_err(|_|Error::Network)?;
                if response.status().is_redirection() {
                    if redirects != 0 || response.status().as_u16() != 302 {return Err(Error::Redirect);}
                    if let MediaPolicy::AuthorizedTest(scope) = &policy {
                        if u.host_str() != Some(scope.entry_host.as_str()) {return Err(Error::Redirect);}
                    }
                    let target = response.headers().get(LOCATION).and_then(|v|v.to_str().ok()).ok_or(Error::Redirect)?;
                    u = policy.check(target,true).map_err(|_|Error::Redirect)?;
                    redirects += 1;
                    // Drop without reading the redirect body; next connection has fresh DNS/TLS checks.
                } else {break response;}
            };
            let total = declared_length(&response)?;
            let counter = delivered.clone();
            let stream = response.bytes_stream().inspect_ok(move |bytes| { counter.fetch_add(bytes.len() as u64, Ordering::Relaxed); }).map_err(|_|std::io::Error::other("HTTP_STREAM"));
            let mut reader = StreamReader::new(stream);
            let mut buffer = vec![0u8;BUFFER_BYTES];
            let start = Instant::now();
            progress(Progress { received:0,total,bytes_per_second:0.0,transport_delivered_bytes:0 });
            loop {
                let remaining = MAX_MEDIA_BYTES - stage.written;
                if remaining == 0 {
                    // An unknown-length stream at the exact ceiling is conservatively rejected.
                    // Do not accept an extra sentinel byte to discover EOF.
                    if total == Some(MAX_MEDIA_BYTES) {break;}
                    return Err(Error::Budget);
                }
                let allowed = buffer.len().min(remaining as usize);
                let n = reader.read(&mut buffer[..allowed]).await.map_err(|_|Error::Network)?;
                if n == 0 {break;}
                stage.write(&buffer[..n])?;
                progress(Progress {received:stage.written,total,bytes_per_second:stage.written as f64/start.elapsed().as_secs_f64().max(0.001),transport_delivered_bytes:delivered.load(Ordering::Relaxed)});
            }
            if stage.written == 0 || total.is_some_and(|n|n != stage.written) {return Err(Error::Length);}
            Ok(stage.written)
        } => result,
    }?;
    stage.flush()?;
    // Verification owns cancellation until its child is reaped. Do not drop staging
    // while a Windows decoder still has the file open.
    let proof = verify(stage.path(), Some(received), cancel).await?;
    if cancel.is_cancelled() {
        return Err(Error::Cancelled);
    }
    let path = stage.commit()?;
    Ok(Download {
        path,
        proof,
        transport_delivered_bytes: delivered.load(Ordering::Relaxed),
    })
}
