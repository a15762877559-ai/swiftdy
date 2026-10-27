use doustudio_rust::{
    auth::{self, Session},
    extractor,
    media::{self, MediaPolicy, TestScope},
    pagination::{Page, Pagination},
    signing,
    storage::Staging,
    Error, MAX_MEDIA_BYTES,
};
use serde_json::{json, Value};
use std::time::{SystemTime, UNIX_EPOCH};

fn work(id: &str) -> Value {
    json!({"aweme_id":id,"desc":"fixture","create_time":1,"video":{"duration":1000,"play_addr":{"url_list":["https://cdn.example/first","https://cdn.example/last"],"width":640,"height":360}}})
}
fn page(ids: &[&str], cursor: u64, more: bool) -> Page {
    Page::parse(&serde_json::to_vec(&json!({"status_code":0,"aweme_list":ids.iter().map(|id|work(id)).collect::<Vec<_>>(),"max_cursor":cursor,"has_more":more})).unwrap()).unwrap()
}

#[test]
fn apache_signing_differential_vectors() {
    let v: Value = serde_json::from_str(include_str!("../fixtures/signing-vectors.json")).unwrap();
    for vector in v["vectors"].as_array().unwrap() {
        let mut state = vector["seed"].as_u64().unwrap() as u32;
        let value = signing::abogus(
            vector["query"].as_str().unwrap(),
            "",
            vector["user_agent"].as_str().unwrap(),
            vector["geometry"].as_str().unwrap(),
            vector["now"].as_u64().unwrap(),
            || {
                state = state.wrapping_mul(1664525).wrapping_add(1013904223);
                state as f64 / 4294967296.0
            },
        )
        .unwrap();
        assert_eq!(value, vector["a_bogus"]);
        let pairs: Vec<(String, String)> =
            serde_json::from_value(vector["web_pairs"].clone()).unwrap();
        assert_eq!(
            signing::websign(&pairs, "synthetic", vector["now"].as_u64().unwrap() / 1000),
            vector["web_query"]
        );
    }
}
#[test]
fn signed_url_cursor_and_identity() {
    let s = Session::new(
        "UIFID_TEMP=synthetic; msToken=synthetic-token".into(),
        signing::USER_AGENT.into(),
    )
    .unwrap();
    let raw = signing::list_url(&s, "fixture", 9123456789012345678).unwrap();
    assert!(auth::signed_request(&raw, "fixture", 9123456789012345678).is_ok());
    assert!(auth::signed_request(&raw, "other", 9123456789012345678).is_err());
    assert!(auth::signed_request(&raw, "fixture", 0).is_err());
    assert!(auth::signed_request(
        &format!("{}&count=18", raw.as_str()),
        "fixture",
        9123456789012345678
    )
    .is_err());
}
#[test]
fn no_fabricated_tokens() {
    for cookie in [
        "x=1",
        "msToken=synthetic",
        "UIFID_TEMP=;msToken=synthetic",
        "uifid=a;uifid=b;msToken=c",
        "UIFID_TEMP=synthetic;msToken=;msToken=",
        "UIFID_TEMP=synthetic;msToken=a;msToken=",
    ] {
        let s = Session::new(cookie.into(), signing::USER_AGENT.into()).unwrap();
        assert_eq!(
            signing::list_url(&s, "fixture", 0).unwrap_err(),
            Error::Credential
        );
    }
    for cookie in ["UIFID_TEMP=synthetic", "UIFID_TEMP=synthetic;msToken="] {
        let s = Session::new(cookie.into(), signing::USER_AGENT.into()).unwrap();
        let raw = signing::list_url(&s, "fixture", 0).unwrap();
        let url = url::Url::parse(&raw).unwrap();
        let tokens: Vec<_> = url
            .query_pairs()
            .filter(|(key, _)| key == "msToken")
            .collect();
        assert_eq!(tokens.len(), 1);
        assert!(tokens[0].1.is_empty());
        assert!(raw.contains("&msToken=&sec_user_id=fixture&"));
        assert!(auth::signed_request(&raw, "fixture", 0).is_ok());
    }
}
#[test]
fn credentials_and_profile_fail_closed() {
    for c in ["", "  ", "x=1\r\nAuthorization: x"] {
        assert!(Session::new(c.into(), "ua".into()).is_err());
    }
    assert_eq!(
        auth::profile_id("https://www.douyin.com/user/fixture_123").unwrap(),
        "fixture_123"
    );
    for p in [
        "http://www.douyin.com/user/x",
        "https://www.douyin.com.evil/user/x",
        "https://www.douyin.com/user/x?a=1",
        "https://www.douyin.com/user/x/y",
        "https://u@www.douyin.com/user/x",
    ] {
        assert!(auth::profile_id(p).is_err());
    }
}
#[test]
fn response_ids_stay_strings_and_urls_are_not_serialized() {
    let w = extractor::extract(&work("9223372036854775807")).unwrap();
    assert_eq!(w.id, "9223372036854775807");
    let serialized = serde_json::to_string(&w).unwrap();
    assert!(!serialized.contains("cdn.example"));
    let mut v = work("1");
    v["aweme_id"] = json!(9223372036854775807u64);
    assert!(extractor::extract(&v).is_err());
}
#[test]
fn bitrate_tuple_then_last_url() {
    let mut v = work("1");
    v["video"]["bit_rate"] = json!([
        {"FPS":120,"bit_rate":9000,"play_addr":{"width":640,"height":360,"data_size":999,"url_list":["small"]}},
        {"FPS":30,"bit_rate":1,"play_addr":{"width":1080,"height":1920,"data_size":1,"url_list":["best-first","best-last"]}}
    ]);
    let w = extractor::extract(&v).unwrap();
    assert_eq!(w.media_url.as_deref(), Some("best-last"));
    assert_eq!(w.height, 1920);
    for field in ["FPS", "bit_rate", "size"] {
        let mut rates = vec![
            json!({"FPS":30,"bit_rate":10,"play_addr":{"width":100,"height":100,"data_size":10,"url_list":["first"]}});
            2
        ];
        rates[1]["play_addr"]["url_list"] = json!(["winner"]);
        if field == "size" {
            rates[1]["play_addr"]["data_size"] = json!(11);
        } else {
            rates[1][field] = json!(99);
        }
        v["video"]["bit_rate"] = json!(rates);
        assert_eq!(
            extractor::extract(&v).unwrap().media_url.as_deref(),
            Some("winner")
        );
    }
}
#[test]
fn fallback_empty_rates_and_unsupported_images() {
    let mut v = work("1");
    assert_eq!(
        extractor::extract(&v).unwrap().media_url.as_deref(),
        Some("https://cdn.example/last")
    );
    v["video"]["bit_rate"] = json!([]);
    assert!(extractor::extract(&v).unwrap().downloadable);
    v["images"] = json!([{}]);
    assert!(!extractor::extract(&v).unwrap().downloadable);
}
#[test]
fn real_cursor_chain_dedup_and_page_limit() {
    let mut p = Pagination::new(3).unwrap();
    assert!(p.advance(page(&["1", "1"], 987, true)).unwrap());
    assert_eq!(p.cursor, 987);
    assert!(p.advance(page(&["1", "2"], 876, true)).unwrap());
    assert!(!p.advance(page(&["3"], 765, true)).unwrap());
    assert_eq!(p.works.len(), 3);
    assert_eq!(p.duplicates, 2);
    assert_eq!(p.stop_reason, "PAGE_LIMIT_REACHED");
    assert!(p.advance(page(&["4"], 654, true)).is_err());
}
#[test]
fn stalled_cyclic_empty_and_duplicate_only_pages_fail() {
    for bad in [page(&[], 9, true), page(&["1"], 0, true)] {
        assert!(Pagination::new(3).unwrap().advance(bad).is_err());
    }
    let mut p = Pagination::new(4).unwrap();
    p.advance(page(&["1"], 9, true)).unwrap();
    p.advance(page(&["2"], 8, true)).unwrap();
    assert!(p.advance(page(&["3"], 9, true)).is_err());
    let mut p = Pagination::new(3).unwrap();
    p.advance(page(&["1"], 9, true)).unwrap();
    assert!(p.advance(page(&["1"], 8, true)).is_err());
}
#[test]
fn empty_account_is_real_empty_state() {
    let mut p = Pagination::new(3).unwrap();
    assert!(!p.advance(page(&[], 0, false)).unwrap());
    assert!(p.works.is_empty());
    assert_eq!(p.stop_reason, "SERVER_EXHAUSTED");
}
#[test]
fn challenge_and_schema_errors() {
    for body in [
        b"<html>captcha</html>".as_slice(),
        br#"{"status_code":0,"has_more":"1","aweme_list":[]}"#,
        br#"{"status_code":8}"#,
        br#"{"status_code":0,"captcha":{},"has_more":false,"aweme_list":[]}"#,
    ] {
        assert!(Page::parse(body).is_err());
    }
}
#[test]
fn exact_host_https_and_public_network_policy() {
    for s in [
        "http://cdn.example/a",
        "https://u:p@cdn.example/a",
        "https://cdn.example:444/a",
        "https://cdn.example/a#x",
        "https://cdn.example/a\n",
    ] {
        assert!(media::strict_https(s).is_err());
    }
    for s in [
        "127.0.0.1",
        "10.0.0.1",
        "100.64.0.1",
        "169.254.169.254",
        "192.168.1.1",
        "198.18.0.1",
        "224.0.0.1",
        "::1",
        "::ffff:8.8.8.8",
        "fc00::1",
        "fe80::1",
        "2001:db8::1",
        "2002:808:808::1",
        "3fff::1",
    ] {
        assert!(!media::public_ip(s.parse().unwrap()), "{s}");
    }
    for s in ["8.8.8.8", "1.1.1.1", "2606:4700:4700::1111"] {
        assert!(media::public_ip(s.parse().unwrap()));
    }
    assert_eq!(
        MediaPolicy::Production
            .check("https://www.douyin.com/a", false)
            .unwrap_err(),
        Error::ProductionDenied
    );
}
#[test]
fn scoped_consent_does_not_approve_production() {
    let scope = || TestScope {
        purpose: "single-video-test".into(),
        entry_host: "www.douyin.com".into(),
        cdn_host: "known.example.com".into(),
        expires_unix: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs()
            + 60,
        max_downloads: 1,
    };
    assert!(MediaPolicy::authorized_test(scope(), false).is_err());
    let p = MediaPolicy::authorized_test(scope(), true).unwrap();
    assert!(p.check("https://known.example.com/a", true).is_ok());
    assert!(p.check("https://evil.known.example.com/a", true).is_err());
    assert!(p.check("https://www.douyin.com/a", true).is_err());
    let mut s = scope();
    s.cdn_host = "*.example.com".into();
    assert!(MediaPolicy::authorized_test(s, true).is_err());
    let mut s = scope();
    s.expires_unix = 1;
    assert!(MediaPolicy::authorized_test(s, true).is_err());
}
#[test]
fn staging_cleanup_and_no_overwrite() {
    let d = tempfile::tempdir().unwrap();
    {
        let mut s = Staging::new(d.path(), "video-1.mp4").unwrap();
        s.write(b"partial").unwrap();
    }
    assert_eq!(std::fs::read_dir(d.path()).unwrap().count(), 0);
    std::fs::write(d.path().join("video-1.mp4"), b"existing").unwrap();
    assert!(matches!(
        Staging::new(d.path(), "video-1.mp4"),
        Err(Error::Exists)
    ));
    assert!(Staging::new(d.path(), "../escape.mp4").is_err());
    assert_eq!(MAX_MEDIA_BYTES, 104857600);
}
