use crate::{Error, Result};
use serde::Deserialize;
use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use url::Url;

pub fn strict_https(raw: &str) -> Result<Url> {
    if raw.len() > 16384
        || raw
            .chars()
            .any(|c| c.is_control() || c.is_whitespace() || c == '\\')
    {
        return Err(Error::NetworkTarget);
    }
    let u = Url::parse(raw).map_err(|_| Error::NetworkTarget)?;
    if u.scheme() != "https"
        || !u.username().is_empty()
        || u.password().is_some()
        || u.fragment().is_some()
        || u.port_or_known_default() != Some(443)
        || u.host_str().is_none()
    {
        return Err(Error::NetworkTarget);
    }
    Ok(u)
}

pub fn public_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v) => {
            let [a, b, c, _] = v.octets();
            !(a == 0
                || a == 10
                || a == 127
                || a >= 224
                || (a == 100 && (64..=127).contains(&b))
                || (a == 169 && b == 254)
                || (a == 172 && (16..=31).contains(&b))
                || (a == 192 && (b == 168 || b == 0 || (b == 88 && c == 99)))
                || (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100)))
                || (a == 203 && b == 0 && c == 113))
        }
        IpAddr::V6(v) => {
            let s = v.segments();
            // Conservative globally routed unicast only; reject transition/documentation/special ranges.
            (s[0] & 0xe000) == 0x2000
                && !(s[0] == 0x2001 && (s[1] < 0x200 || s[1] == 0xdb8))
                && s[0] != 0x2002
                && !(s[0] == 0x3fff && s[1] < 0x1000)
        }
    }
}

pub async fn pinned_client(u: &Url, loopback: bool) -> Result<reqwest::Client> {
    #[cfg(feature = "offline-test")]
    crate::assert_active_operations_allowed();
    let host = u.host_str().ok_or(Error::NetworkTarget)?;
    let port = u.port_or_known_default().ok_or(Error::NetworkTarget)?;
    let addresses: Vec<SocketAddr> = if loopback {
        if host != "127.0.0.1" || !["http", "https"].contains(&u.scheme()) {
            return Err(Error::NetworkTarget);
        }
        vec![SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port)]
    } else {
        strict_https(u.as_str())?;
        let all: Vec<_> = tokio::time::timeout(
            Duration::from_secs(10),
            tokio::net::lookup_host((host, port)),
        )
        .await
        .map_err(|_| Error::Timeout)?
        .map_err(|_| Error::Network)?
        .collect();
        if all.is_empty() || all.iter().any(|a| !public_ip(a.ip())) {
            return Err(Error::NetworkTarget);
        }
        all
    };
    // Only one vetted numerical address is provided to the connector. Original host stays for SNI/TLS.
    reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .retry(reqwest::retry::never())
        .http1_only()
        .pool_max_idle_per_host(0)
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(180))
        .resolve(host, addresses[0])
        .build()
        .map_err(|_| Error::Network)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TestScope {
    pub purpose: String,
    pub entry_host: String,
    pub cdn_host: String,
    pub expires_unix: u64,
    pub max_downloads: u8,
}
pub enum MediaPolicy {
    Production,
    AuthorizedTest(TestScope),
    #[cfg(feature = "offline-test")]
    Loopback {
        port: u16,
    },
}
impl MediaPolicy {
    pub fn authorized_test(scope: TestScope, consent: bool) -> Result<Self> {
        if !consent {
            return Err(Error::Authorization);
        }
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| Error::TestScope)?
            .as_secs();
        if scope.purpose != "single-video-test"
            || scope.entry_host != "www.douyin.com"
            || scope.max_downloads != 1
            || scope.expires_unix <= now
            || scope.expires_unix > now + 3600
        {
            return Err(Error::TestScope);
        }
        let host = &scope.cdn_host;
        if host.len() > 253
            || !host.contains('.')
            || host
                .bytes()
                .any(|c| !c.is_ascii_lowercase() && !c.is_ascii_digit() && c != b'.' && c != b'-')
            || host.ends_with('.')
            || host.parse::<IpAddr>().is_ok()
            || host == &scope.entry_host
        {
            return Err(Error::TestScope);
        }
        Ok(Self::AuthorizedTest(scope))
    }
    pub fn check(&self, raw: &str, redirect: bool) -> Result<Url> {
        match self {
            Self::Production => Err(Error::ProductionDenied),
            Self::AuthorizedTest(s) => {
                let now = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map_err(|_| Error::TestScope)?
                    .as_secs();
                if now >= s.expires_unix {
                    return Err(Error::TestScope);
                }
                let u = strict_https(raw)?;
                if u.host_str() != Some(s.cdn_host.as_str())
                    && (redirect || u.host_str() != Some(s.entry_host.as_str()))
                {
                    return Err(Error::NetworkTarget);
                }
                Ok(u)
            }
            #[cfg(feature = "offline-test")]
            Self::Loopback { port } => {
                let u = Url::parse(raw).map_err(|_| Error::NetworkTarget)?;
                if u.scheme() != "http"
                    || u.host_str() != Some("127.0.0.1")
                    || u.port() != Some(*port)
                    || !u.username().is_empty()
                    || u.password().is_some()
                    || u.fragment().is_some()
                {
                    return Err(Error::NetworkTarget);
                }
                Ok(u)
            }
        }
    }
    pub fn loopback(&self) -> bool {
        #[cfg(feature = "offline-test")]
        if matches!(self, Self::Loopback { .. }) {
            return true;
        }
        false
    }
}

// Keep these imports exercised on both Windows and Unix builds.
const _: Ipv6Addr = Ipv6Addr::LOCALHOST;
