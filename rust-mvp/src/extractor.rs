use crate::{Error, Result};
use serde::Serialize;
use serde_json::Value;

#[derive(Clone, Serialize)]
pub struct Work {
    pub id: String,
    pub description: String,
    pub created_at: i64,
    pub duration_ms: u64,
    pub width: i64,
    pub height: i64,
    pub fps: i64,
    pub bitrate: i64,
    pub declared_media_bytes: i64,
    pub downloadable: bool,
    #[serde(skip)]
    pub media_url: Option<String>,
    #[serde(skip)]
    pub validation: FieldValidation,
}
#[derive(Clone, Default, Serialize)]
pub struct FieldValidation {
    pub cover_present: bool,
    pub cover_array_valid: bool,
    pub cover_https_hosts_valid: bool,
    pub ordinary_video: bool,
    pub playback_address_valid: bool,
}
fn https_host(raw: &str) -> bool {
    crate::media::strict_https(raw).is_ok_and(
        |u| matches!(u.host(), Some(url::Host::Domain(d)) if d.contains('.') && d.len()<=253 && d.split('.').all(|label| !label.is_empty() && label.len()<=63 && !label.starts_with('-') && !label.ends_with('-') && label.bytes().all(|b|b.is_ascii_alphanumeric()||b==b'-'))),
    )
}
fn urls_valid(value: &Value) -> bool {
    value.as_array().is_some_and(|a| {
        !a.is_empty() && a.iter().all(|u| u.as_str().is_some_and(|s| !s.is_empty()))
    })
}
fn number(v: &Value, key: &str) -> i64 {
    v.get(key).and_then(Value::as_i64).unwrap_or(0)
}

pub fn extract(v: &Value) -> Result<Work> {
    let id = v["aweme_id"]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 64 && s.bytes().all(|b| b.is_ascii_digit()))
        .ok_or(Error::Schema)?
        .to_owned();
    let video = &v["video"];
    let rates = match video.get("bit_rate") {
        None | Some(Value::Null) => &[][..],
        Some(Value::Array(a)) => a.as_slice(),
        _ => return Err(Error::Schema),
    };
    // Stable last maximum matches the observed tuple and final-address behavior.
    let best = rates.iter().max_by_key(|r| {
        let a = &r["play_addr"];
        (
            number(a, "height").max(number(a, "width")),
            number(r, "FPS"),
            number(r, "bit_rate"),
            number(a, "data_size"),
        )
    });
    let address = best.map(|r| &r["play_addr"]).unwrap_or(&video["play_addr"]);
    let url = address["url_list"]
        .as_array()
        .and_then(|a| a.last())
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_owned);
    let ordinary = v["images"].as_array().is_none_or(Vec::is_empty) && v["is_ads"] != true;
    let covers = &video["cover"]["url_list"];
    let cover_array_valid = urls_valid(covers);
    let validation = FieldValidation {
        cover_present: video.get("cover").is_some_and(|c| !c.is_null()),
        cover_array_valid,
        cover_https_hosts_valid: cover_array_valid
            && covers
                .as_array()
                .unwrap()
                .iter()
                .all(|u| https_host(u.as_str().unwrap())),
        // Acceptance fails closed on missing/unknown types; legacy selection is unchanged.
        ordinary_video: ordinary
            && v.get("images")
                .is_none_or(|x| x.is_null() || x.as_array().is_some_and(Vec::is_empty))
            && matches!(v["aweme_type"].as_u64(), Some(0 | 4))
            && v.get("live_room").is_none_or(Value::is_null)
            && v.get("room_id")
                .is_none_or(|x| x.is_null() || x == 0 || x == "0"),
        playback_address_valid: urls_valid(&address["url_list"])
            && url.as_deref().is_some_and(https_host),
    };
    Ok(Work {
        id,
        description: v["desc"].as_str().unwrap_or("").into(),
        created_at: v["create_time"].as_i64().ok_or(Error::Schema)?,
        duration_ms: video["duration"].as_u64().unwrap_or(0),
        width: number(address, "width"),
        height: number(address, "height"),
        fps: best.map(|r| number(r, "FPS")).unwrap_or(0),
        bitrate: best.map(|r| number(r, "bit_rate")).unwrap_or(0),
        declared_media_bytes: best.map(|_| number(address, "data_size")).unwrap_or(0),
        downloadable: ordinary && url.is_some(),
        media_url: if ordinary { url } else { None },
        validation,
    })
}
