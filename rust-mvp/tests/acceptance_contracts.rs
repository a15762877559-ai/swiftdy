use doustudio_rust::extractor;
use serde_json::json;

#[test]
fn cover_type_and_playback_validation_without_fetching_covers() {
    let mut v = json!({"aweme_id":"123","create_time":1,"aweme_type":0,"video":{"cover":{"url_list":["https://cover.example/a"]},"play_addr":{"url_list":["https://cdn.example/a"]}}});
    let w = extractor::extract(&v).unwrap();
    assert!(
        w.validation.cover_present
            && w.validation.cover_array_valid
            && w.validation.cover_https_hosts_valid
            && w.validation.ordinary_video
            && w.validation.playback_address_valid
    );
    for bad in [
        json!(null),
        json!({}),
        json!({"url_list":[]}),
        json!({"url_list":"https://cover.example/a"}),
        json!({"url_list":[42]}),
        json!({"url_list":["http://cover.example/a"]}),
        json!({"url_list":["https://user@cover.example/a"]}),
        json!({"url_list":["https://127.0.0.1/a"]}),
        json!({"url_list":["https://a..example/a"]}),
        json!({"url_list":["https://-invalid.example/a"]}),
    ] {
        v["video"]["cover"] = bad;
        assert!(
            !extractor::extract(&v)
                .unwrap()
                .validation
                .cover_https_hosts_valid
        );
    }
    v["video"].as_object_mut().unwrap().remove("cover");
    assert!(!extractor::extract(&v).unwrap().validation.cover_present);
    for kind in [json!(null), json!(68), json!(101)] {
        v["aweme_type"] = kind;
        assert!(!extractor::extract(&v).unwrap().validation.ordinary_video);
    }
    v["aweme_type"] = json!(0);
    v["images"] = json!([{}]);
    assert!(!extractor::extract(&v).unwrap().validation.ordinary_video);
    v.as_object_mut().unwrap().remove("images");
    v["images"] = json!("invalid-image-structure");
    assert!(!extractor::extract(&v).unwrap().validation.ordinary_video);
    v.as_object_mut().unwrap().remove("images");
    v["live_room"] = json!({});
    assert!(!extractor::extract(&v).unwrap().validation.ordinary_video);
    v["video"]["play_addr"]["url_list"] = json!(["not-a-url"]);
    assert!(
        !extractor::extract(&v)
            .unwrap()
            .validation
            .playback_address_valid
    );
}

#[cfg(not(feature = "offline-test"))]
#[test]
fn production_acceptance_offline_guard_precedes_all_prompts() {
    let directory = tempfile::tempdir().unwrap();
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_doustudio"))
        .args(["acceptance", "--output"])
        .arg(directory.path())
        .env("DOUSTUDIO_OFFLINE_ONLY", "1")
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    assert!(!output.status.success());
    let report: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(report["list_requests_started"], 0);
    assert_eq!(report["media_download_attempts"], 0);
    assert_eq!(report["authorization_a"], false);
    assert!(!String::from_utf8_lossy(&output.stderr).contains("Cookie"));
    assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 0);
}
