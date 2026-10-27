use crate::{
    auth::{self, Session},
    media::pinned_client,
    pagination::Page,
    Error, Result, BUFFER_BYTES,
};
use futures_util::TryStreamExt;
use tokio::io::AsyncReadExt;
use tokio_util::io::StreamReader;
use url::Url;

#[derive(Default, serde::Serialize)]
pub struct RequestDiagnostic {
    pub http_status: Option<u16>,
    pub signing_completed: bool,
    pub request_started: bool,
}
impl RequestDiagnostic {
    pub fn error_category(&self, error: &Error) -> String {
        match self.http_status {
            Some(401) => "HTTP_401_UNAUTHORIZED".into(),
            Some(403) => "HTTP_403_FORBIDDEN".into(),
            Some(429) => "HTTP_429_RATE_LIMITED".into(),
            _ => error.to_string(),
        }
    }
}

pub async fn fetch_page(session: &Session, user: &str, cursor: u64) -> Result<Page> {
    fetch_page_observed(session, user, cursor, &mut RequestDiagnostic::default()).await
}
pub async fn fetch_page_observed(
    session: &Session,
    user: &str,
    cursor: u64,
    diagnostic: &mut RequestDiagnostic,
) -> Result<Page> {
    let signed = crate::signing::list_url(session, user, cursor)?;
    diagnostic.signing_completed = true;
    let url = auth::signed_request(&signed, user, cursor)?;
    request_page_observed(url, session, false, diagnostic).await
}
pub async fn request_page(url: Url, session: &Session, loopback: bool) -> Result<Page> {
    request_page_observed(url, session, loopback, &mut RequestDiagnostic::default()).await
}
pub async fn request_page_observed(
    url: Url,
    session: &Session,
    loopback: bool,
    diagnostic: &mut RequestDiagnostic,
) -> Result<Page> {
    #[cfg(not(feature = "offline-test"))]
    if loopback {
        return Err(Error::Scope);
    }
    if !loopback
        && (url.host_str() != Some("www.douyin.com") || url.path() != "/aweme/v1/web/aweme/post/")
    {
        return Err(Error::Scope);
    }
    let client = pinned_client(&url, loopback).await?;
    diagnostic.request_started = true;
    let response = client
        .get(url)
        .header("Cookie", session.cookie_header()?)
        .header("User-Agent", &session.user_agent)
        .header("Accept", "application/json")
        .header("Accept-Encoding", "identity")
        .header("Referer", "https://www.douyin.com/?recommend=1")
        .send()
        .await
        .map_err(|_| Error::Network)?;
    diagnostic.http_status = Some(response.status().as_u16());
    match response.status().as_u16() {
        200 => (),
        401 | 403 => return Err(Error::Access),
        429 => return Err(Error::RateLimited),
        300..=399 => return Err(Error::Redirect),
        _ => return Err(Error::Network),
    }
    if response
        .headers()
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .is_none_or(|s| !s.to_ascii_lowercase().starts_with("application/json"))
    {
        return Err(Error::Challenge);
    }
    if response.headers().contains_key("content-encoding") {
        return Err(Error::Headers);
    }
    const CAP: usize = 4 * 1024 * 1024;
    if response.content_length().is_some_and(|n| n > CAP as u64) {
        return Err(Error::Budget);
    }
    let mut reader = StreamReader::new(
        response
            .bytes_stream()
            .map_err(|_| std::io::Error::other("HTTP_STREAM")),
    );
    let mut body = Vec::new();
    let mut buf = vec![0u8; BUFFER_BYTES];
    loop {
        let n = reader.read(&mut buf).await.map_err(|_| Error::Network)?;
        if n == 0 {
            break;
        }
        if body.len() + n > CAP {
            return Err(Error::Budget);
        }
        body.extend_from_slice(&buf[..n]);
    }
    Page::parse(&body)
}
