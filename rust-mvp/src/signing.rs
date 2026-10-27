// Rust adaptation of the Apache-2.0 implementation at
// Evil0ctal/Douyin_TikTok_Download_API@3d540dbf3783449e638403b65d81c882c4a99575
// src/dtk/signing/native/{abogus,websign}.py. See THIRD_PARTY_NOTICES.md.
// Changed: Rust data layout, RustCrypto SM3, caller RNG, bounded GET-only pipeline.
// No Swift source is incorporated. No token minting or challenge bypass is performed.
use crate::{auth::Session, Error, Result};
use sha2::Digest;
use sm3::Sm3;
use zeroize::Zeroizing;

const S3: &[u8; 64] = b"ckdp1h4ZKsUB80/Mfvw36XIgR25+WQAlEi7NLboqYTOPuzmFjJnryx9HVGDaStCe";
const S4: &[u8; 64] = b"Dkdpgh2ZmsQB80/MfvV36XI1R45-WUAlEixNLwoqYTOPuzKFjJnry79HbGcaStCe";
const ORDER: [usize; 50] = [
    34, 44, 56, 61, 73, 29, 70, 45, 35, 49, 38, 66, 51, 68, 28, 48, 64, 47, 30, 71, 26, 55, 31, 69,
    59, 40, 62, 63, 27, 72, 41, 74, 57, 52, 42, 39, 33, 67, 53, 43, 65, 46, 36, 24, 60, 32, 79, 80,
    84, 85,
];
pub const BROWSER_INFO: &str = "1920|947|1920|1032|1920|1032|1920|1080|Win32";
pub const USER_AGENT: &str="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36";

pub fn escape(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"*-._~".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}
pub fn encode(pairs: &[(String, String)]) -> String {
    pairs
        .iter()
        .map(|(k, v)| format!("{}={}", escape(k), escape(v)))
        .collect::<Vec<_>>()
        .join("&")
}
fn js_bytes(s: &str) -> Vec<u8> {
    s.encode_utf16()
        .flat_map(|v| {
            if v > 255 {
                vec![(v >> 8) as u8, v as u8]
            } else {
                vec![v as u8]
            }
        })
        .collect()
}
fn cipher(key: &[u8], data: &[u8]) -> Vec<u8> {
    let mut s: Vec<usize> = (0..256).rev().collect();
    let mut j = 0;
    for i in 0..256 {
        j = (j * s[i] + j + key[i % key.len()] as usize) % 256;
        s.swap(i, j);
    }
    let (mut i, mut j) = (0, 0);
    data.iter()
        .map(|b| {
            i = (i + 1) % 256;
            j = (j + s[i]) % 256;
            s.swap(i, j);
            b ^ (s[(s[i] + s[j]) % 256] as u8)
        })
        .collect()
}
fn b64(data: &[u8], table: &[u8; 64]) -> String {
    let mut result = String::new();
    for chunk in data.chunks(3) {
        let n = ((chunk[0] as u32) << 16)
            | ((chunk.get(1).copied().unwrap_or(0) as u32) << 8)
            | chunk.get(2).copied().unwrap_or(0) as u32;
        for shift in [18, 12, 6, 0].into_iter().take(chunk.len() + 1) {
            result.push(table[((n >> shift) & 63) as usize] as char);
        }
    }
    while !result.len().is_multiple_of(4) {
        result.push('=');
    }
    result
}
fn hash2(s: &str) -> Vec<u8> {
    Sm3::digest(Sm3::digest(format!("{s}dhzx").as_bytes())).to_vec()
}
fn pair(a: u8, b: u8, noise: u16, low: Option<u8>, high: Option<u8>) -> [u8; 4] {
    let l = low.unwrap_or(noise as u8);
    let h = high.unwrap_or((noise >> 8) as u8);
    [
        (l & 0xaa) | (a & 0x55),
        (l & 0x55) | (a & 0xaa),
        (h & 0xaa) | (b & 0x55),
        (h & 0x55) | (b & 0xaa),
    ]
}
pub fn abogus(
    query: &str,
    body: &str,
    ua: &str,
    geometry: &str,
    now: u64,
    mut random: impl FnMut() -> f64,
) -> Result<String> {
    if now < 1_721_836_800_000
        || (now - 1_721_836_800_000) / 1_209_600_000 > 255
        || geometry.len() > 1024
        || query.len() > 16000
    {
        return Err(Error::Scope);
    }
    let mut f = [0u8; 86];
    let info = js_bytes(geometry);
    let tail = format!("{},", (now + 3) & 255).into_bytes();
    for (i, v) in [
        (24, 41),
        (26, ((now - 1_721_836_800_000) / 1_209_600_000) as u8),
        (27, 6),
        (28, 3),
        (35, 1),
        (38, 0x21),
        (66, 3),
    ] {
        f[i] = v;
    }
    for (offset, n, count) in [
        (29, now, 6),
        (60, now - 1, 6),
        (44, 14, 4),
        (67, 6241, 4),
        (71, 6383, 4),
        (79, info.len() as u64, 2),
        (84, tail.len() as u64, 2),
    ] {
        f[offset..offset + count].copy_from_slice(&n.to_le_bytes()[..count]);
    }
    let ua_hash =
        Sm3::digest(b64(&cipher(&[0, 1, 14], &js_bytes(ua.trim())), S3).as_bytes()).to_vec();
    for (digest, slots, positions, canary) in [
        (hash2(query), [48, 49, 51], [9, 18], (3, 11, 12)),
        (hash2(body), [52, 53, 55], [10, 19], (4, 8, 9)),
        (ua_hash, [56, 57, 59], [11, 21], (5, 12, 13)),
    ] {
        f[slots[0]] = digest[positions[0]];
        f[slots[1]] = digest[positions[1]];
        f[slots[2]] = digest[canary.0..]
            .iter()
            .copied()
            .find(|v| *v != canary.1)
            .unwrap_or(canary.2);
    }
    let mut version = pair(1, 0, (random() * 65535.0) as u16, None, None).to_vec();
    let probe = (random() * 240.0) as u8;
    let probe = if probe > 109 {
        probe + probe % 2 + 1
    } else {
        probe
    };
    let trip = ((random() * 255.0) as u8 & 0x4d) | 0xb2;
    version.extend(pair(
        1,
        0,
        (random() * 65535.0) as u16,
        Some(probe),
        Some(trip),
    ));
    let check = version
        .iter()
        .copied()
        .chain(ORDER.iter().map(|i| f[*i]))
        .fold(0, |a, b| a ^ b);
    let mut body: Vec<u8> = ORDER.iter().map(|i| f[*i]).collect();
    body.extend(info);
    body.extend(tail);
    body.push(check);
    let lower = ua.to_ascii_lowercase();
    let base = if lower.contains("edg") {
        125
    } else if lower.contains("huawei") {
        170
    } else if lower.contains("firefox") {
        40
    } else if lower.contains("chrome") {
        0
    } else if lower.contains("safari") {
        81
    } else {
        210
    };
    let high = base + (random() * 40.0) as u8;
    let header = pair(3, 82, (random() * 65535.0) as u16, None, Some(high));
    for chunk in body.chunks(3) {
        if chunk.len() < 3 {
            version.push(chunk[0]);
            if chunk.len() == 2 && chunk[1] != 0 {
                version.push(chunk[1]);
            }
            continue;
        }
        let r = (random() * 1000.0) as u16 as u8;
        version.extend([
            (r & 0x91) | (chunk[0] & 0x6e),
            (r & 0x42) | (chunk[1] & 0xbd),
            (r & 0x2c) | (chunk[2] & 0xd3),
            (chunk[0] & 0x91) | (chunk[1] & 0x42) | (chunk[2] & 0x2c),
        ]);
    }
    let mut sealed = header.to_vec();
    sealed.extend(cipher(&[0xd3], &version));
    Ok(b64(&sealed, S4))
}
pub fn websign(pairs: &[(String, String)], uifid: &str, timestamp: u64) -> String {
    let mut p = pairs.to_vec();
    if !p.iter().any(|(k, _)| k == "uifid") {
        p.push(("uifid".into(), uifid.into()));
    }
    p.push(("timestamp".into(), timestamp.to_string()));
    let q = encode(&p);
    let sig = md5::compute(format!(
        "{uifid}_{timestamp}_A96D855A08C0A9707F8BEF0D9A527E4E_{q}"
    ));
    format!("{q}&x-secsdk-web-signature={sig:x}")
}

pub fn list_url(session: &Session, user: &str, cursor: u64) -> Result<Zeroizing<String>> {
    let uifid = session.cookie_value(&[
        "uifid",
        "uifid_temp",
        "uifidtemp",
        "UIFID",
        "UIFID_TEMP",
        "UIFIDTEMP",
    ])?;
    let token = session.cookie_value(&["msToken"])?;
    let mut p: Vec<(String, String)> = [
        ("device_platform", "webapp"),
        ("aid", "6383"),
        ("channel", "channel_pc_web"),
        ("update_version_code", "170400"),
        ("pc_client_type", "1"),
        ("pc_libra_divert", "Windows"),
        ("support_h265", "1"),
        ("support_dash", "1"),
        ("version_code", "290100"),
        ("version_name", "29.1.0"),
        ("cookie_enabled", "true"),
        ("screen_width", "1920"),
        ("screen_height", "1080"),
        ("browser_language", "zh-CN"),
        ("browser_platform", "Win32"),
        ("browser_name", "Chrome"),
        ("browser_version", "146.0.0.0"),
        ("browser_online", "true"),
        ("engine_name", "Blink"),
        ("engine_version", "146.0.0.0"),
        ("os_name", "Windows"),
        ("os_version", "10"),
        ("cpu_core_num", "8"),
        ("device_memory", "8"),
        ("platform", "PC"),
        ("downlink", "10"),
        ("effective_type", "4g"),
        ("round_trip_time", "200"),
        ("uifid", &uifid),
        ("msToken", &token),
        ("sec_user_id", user),
        ("max_cursor", &cursor.to_string()),
        ("locate_query", "false"),
        ("show_live_replay_strategy", "1"),
        ("need_time_list", "1"),
        ("time_list_query", "0"),
        ("whale_cut_token", ""),
        ("cut_version", "1"),
        ("count", "18"),
        ("publish_video_strategy_type", "2"),
        ("from_user_page", "1"),
    ]
    .into_iter()
    .map(|(k, v)| (k.into(), v.into()))
    .collect();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| Error::Scope)?
        .as_millis() as u64;
    let q = Zeroizing::new(encode(&p));
    let bogus = abogus(
        &q,
        "",
        &session.user_agent,
        BROWSER_INFO,
        now,
        rand::random::<f64>,
    )?;
    p.push(("a_bogus".into(), bogus));
    let signed = websign(&p, &uifid, now / 1000);
    Ok(Zeroizing::new(format!(
        "https://www.douyin.com/aweme/v1/web/aweme/post/?{signed}"
    )))
}
