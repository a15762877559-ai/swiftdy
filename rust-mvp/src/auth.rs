use crate::{Error, Result};
use reqwest::header::HeaderValue;
use url::Url;
use zeroize::Zeroizing;

pub struct Session {
    cookie: Zeroizing<String>,
    pub user_agent: String,
}
impl Session {
    pub fn cookie_value(&self, names: &[&str]) -> Result<Zeroizing<String>> {
        for name in names {
            let values: Vec<_> = self
                .cookie
                .split(';')
                .filter_map(|s| s.trim().split_once('='))
                .filter(|(k, v)| k == name && !v.is_empty())
                .map(|(_, v)| v)
                .collect();
            if values.len() > 1 {
                return Err(Error::Credential);
            }
            if let Some(v) = values.first() {
                return Ok(Zeroizing::new((*v).into()));
            }
        }
        Err(Error::Credential)
    }
    pub fn new(cookie: String, user_agent: String) -> Result<Self> {
        let cookie = Zeroizing::new(cookie);
        if cookie.trim().is_empty()
            || cookie.len() > 32768
            || cookie.chars().any(char::is_control)
            || user_agent.is_empty()
            || user_agent.len() > 1024
            || user_agent.chars().any(char::is_control)
        {
            return Err(Error::Credential);
        }
        HeaderValue::from_str(&cookie).map_err(|_| Error::Credential)?;
        HeaderValue::from_str(&user_agent).map_err(|_| Error::Credential)?;
        Ok(Self { cookie, user_agent })
    }
    pub fn cookie_header(&self) -> Result<HeaderValue> {
        let mut value = HeaderValue::from_str(&self.cookie).map_err(|_| Error::Credential)?;
        value.set_sensitive(true);
        Ok(value)
    }
    pub fn prompt(user_agent: String) -> Result<Self> {
        // Console-only hidden entry; no command-line or on-disk credentials.
        let cookie = rpassword::prompt_password("Authorized session Cookie (hidden): ")
            .map_err(|_| Error::Credential)?;
        Self::new(cookie, user_agent)
    }
}

pub fn profile_id(raw: &str) -> Result<String> {
    let u = crate::media::strict_https(raw).map_err(|_| Error::Scope)?;
    if u.host_str() != Some("www.douyin.com") || u.query().is_some() {
        return Err(Error::Scope);
    }
    let id = u.path().strip_prefix("/user/").ok_or(Error::Scope)?;
    if id.is_empty()
        || id.len() > 256
        || !id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    {
        return Err(Error::Scope);
    }
    Ok(id.into())
}

// A freshly authorized browser/session request is an independent credential interface.
// Preserve signed query bytes. Never edit a signature or invent playback URLs.
pub fn signed_request(raw: &str, user: &str, cursor: u64) -> Result<Url> {
    let u = crate::media::strict_https(raw).map_err(|_| Error::Scope)?;
    if u.host_str() != Some("www.douyin.com") || u.path() != "/aweme/v1/web/aweme/post/" {
        return Err(Error::Scope);
    }
    let pairs: Vec<_> = u.query_pairs().collect();
    let one = |key: &str| -> Result<String> {
        let v: Vec<_> = pairs.iter().filter(|(k, _)| k == key).collect();
        if v.len() != 1 {
            return Err(Error::Scope);
        }
        Ok(v[0].1.to_string())
    };
    if one("sec_user_id")? != user
        || one("max_cursor")? != cursor.to_string()
        || one("count")? != "18"
        || one("a_bogus")?.is_empty()
        || one("x-secsdk-web-signature")?.is_empty()
        || one("uifid")?.is_empty()
    {
        return Err(Error::Scope);
    }
    Ok(u)
}
