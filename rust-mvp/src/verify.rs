use crate::{storage::safe_path, Error, Result, BUFFER_BYTES, MAX_MEDIA_BYTES};
use serde::Serialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    fs::File,
    io::{Read, Seek, SeekFrom},
    path::Path,
    process::Stdio,
    time::Duration,
};
use tokio::{io::AsyncReadExt, process::Command};
use tokio_util::sync::CancellationToken;

#[derive(Debug, Serialize)]
pub struct Verification {
    pub file_bytes: u64,
    pub sha256: String,
    pub width: u64,
    pub height: u64,
    pub duration_seconds: f64,
    pub codec: String,
    pub decoded_frames: u64,
    pub container_complete: bool,
    pub full_video_decode: bool,
    pub audio_decode: &'static str,
    pub no_watermark: &'static str,
    pub sha256_match: bool,
    pub frame_rate: f64,
    pub first_frame_covered: bool,
    pub middle_interval_covered: bool,
    pub end_interval_covered: bool,
    pub full_decode_ended: bool,
    pub decode_errors_observed: bool,
}

#[derive(Default)]
struct Coverage {
    frames: u64,
    first: Option<f64>,
    middle: bool,
    end: bool,
}
impl Coverage {
    fn line(&mut self, line: &[u8], duration: f64, fps: f64) -> Result<()> {
        let text = std::str::from_utf8(line).map_err(|_| Error::Decode)?;
        if !text.contains("Parsed_showinfo_")
            || !text.contains(" n:")
            || !text.contains(" pts_time:")
        {
            return Ok(());
        }
        let n = text
            .split_once(" n:")
            .and_then(|(_, s)| s.split_whitespace().next())
            .and_then(|s| s.parse::<u64>().ok())
            .ok_or(Error::Decode)?;
        let pts = text
            .split_once(" pts_time:")
            .and_then(|(_, s)| s.split_whitespace().next())
            .and_then(|s| s.parse::<f64>().ok())
            .filter(|n| n.is_finite())
            .ok_or(Error::Decode)?;
        if n != self.frames || self.frames >= 250000 {
            return Err(Error::Decode);
        }
        let first = *self.first.get_or_insert(pts);
        let t = pts - first;
        self.frames += 1;
        let tolerance = (2.0 / fps).max(duration * 0.025);
        self.middle |= (t - duration / 2.0).abs() <= tolerance;
        self.end |= t >= (duration - 2.0 / fps).max(duration * 0.95);
        Ok(())
    }
}
async fn coverage_output(
    mut command: Command,
    cancel: &CancellationToken,
    duration: f64,
    fps: f64,
) -> Result<(Vec<u8>, Coverage)> {
    command.env_clear();
    for key in ["SystemRoot", "WINDIR", "PATH", "TEMP", "TMP"] {
        if let Some(v) = std::env::var_os(key) {
            command.env(key, v);
        }
    }
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    #[cfg(windows)]
    command.creation_flags(0x08000000);
    let mut child = command.spawn().map_err(|_| Error::VerifierMissing)?;
    let mut stdout = child.stdout.take().ok_or(Error::Decode)?.take(65537);
    let mut stderr = child.stderr.take().ok_or(Error::Decode)?;
    let result = tokio::select! {
        biased;
        _=cancel.cancelled()=>Err(Error::Cancelled),
        _=tokio::time::sleep(Duration::from_secs(180))=>Err(Error::Timeout),
        r=async {
            let output=async {let mut bytes=Vec::new();stdout.read_to_end(&mut bytes).await.map_err(|_|Error::Decode)?;if bytes.len()>65536{return Err(Error::Decode);}Ok(bytes)};
            let observe=async {
                let mut coverage=Coverage::default();let mut chunk=vec![0u8;8192];let mut line=Vec::new();
                loop {let n=stderr.read(&mut chunk).await.map_err(|_|Error::Decode)?;if n==0{break;}
                    for b in &chunk[..n] {if *b==b'\n' {coverage.line(&line,duration,fps)?;line.clear();}else{if line.len()>=8192{return Err(Error::Decode);}line.push(*b);}}
                }
                if !line.is_empty(){coverage.line(&line,duration,fps)?;}Ok(coverage)
            };
            let (output,coverage)=tokio::try_join!(output,observe)?;
            if !child.wait().await.map_err(|_|Error::Decode)?.success(){return Err(Error::Decode);}
            Ok((output,coverage))
        }=>r
    };
    if result.is_err() {
        let _ = child.kill().await;
        let _ = child.wait().await;
    }
    result
}

pub fn hash_and_boxes(path: &Path, expected: Option<u64>) -> Result<(u64, String)> {
    safe_path(path)?;
    let mut f = File::open(path).map_err(|_| Error::Io)?;
    let meta = f.metadata().map_err(|_| Error::Io)?;
    let len = meta.len();
    if !meta.is_file() || len == 0 || len > MAX_MEDIA_BYTES || expected.is_some_and(|v| v != len) {
        return Err(Error::Length);
    }
    let mut offset = 0u64;
    let (mut ftyp, mut moov, mut mdat) = (false, false, false);
    while offset < len {
        if len - offset < 8 {
            return Err(Error::Container);
        }
        let mut h = [0u8; 8];
        f.read_exact(&mut h).map_err(|_| Error::Container)?;
        let short = u32::from_be_bytes(h[..4].try_into().unwrap()) as u64;
        let (size, header) = if short == 1 {
            let mut large = [0u8; 8];
            f.read_exact(&mut large).map_err(|_| Error::Container)?;
            (u64::from_be_bytes(large), 16)
        } else if short == 0 {
            (len - offset, 8)
        } else {
            (short, 8)
        };
        if size < header || size > len - offset {
            return Err(Error::Container);
        }
        match &h[4..] {
            b"ftyp" => {
                if offset != 0 || size < 16 {
                    return Err(Error::Container);
                }
                ftyp = true;
            }
            b"moov" => {
                if moov || size <= header {
                    return Err(Error::Container);
                }
                moov = true;
            }
            b"mdat" => {
                if size <= header {
                    return Err(Error::Container);
                }
                mdat = true;
            }
            _ => (),
        }
        offset += size;
        f.seek(SeekFrom::Start(offset)).map_err(|_| Error::Io)?;
    }
    if !(ftyp && moov && mdat) {
        return Err(Error::Container);
    }
    f.rewind().map_err(|_| Error::Io)?;
    let mut sha = Sha256::new();
    let mut buffer = vec![0u8; BUFFER_BYTES];
    loop {
        let n = f.read(&mut buffer).map_err(|_| Error::Io)?;
        if n == 0 {
            break;
        }
        sha.update(&buffer[..n]);
    }
    Ok((len, format!("{:x}", sha.finalize())))
}

async fn child_output(mut command: Command, cancel: &CancellationToken) -> Result<Vec<u8>> {
    // Do not hand session-related or reporting/proxy environment variables to media tools.
    command.env_clear();
    for key in ["SystemRoot", "WINDIR", "PATH", "TEMP", "TMP"] {
        if let Some(value) = std::env::var_os(key) {
            command.env(key, value);
        }
    }
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    #[cfg(windows)]
    command.creation_flags(0x08000000);
    let mut child = command.spawn().map_err(|_| Error::VerifierMissing)?;
    let stdout = child.stdout.take().ok_or(Error::Decode)?;
    let result = tokio::select! {
        biased;
        _ = cancel.cancelled() => Err(Error::Cancelled),
        _ = tokio::time::sleep(Duration::from_secs(180)) => Err(Error::Timeout),
        r = async {
            let mut output = Vec::new();
            stdout.take(65537).read_to_end(&mut output).await.map_err(|_|Error::Decode)?;
            if output.len() > 65536 {return Err(Error::Decode);}
            if !child.wait().await.map_err(|_|Error::Decode)?.success() {return Err(Error::Decode);}
            Ok(output)
        } => r,
    };
    if result.is_err() {
        let _ = child.kill().await;
        let _ = child.wait().await;
    }
    result
}

pub async fn verify(
    path: &Path,
    expected: Option<u64>,
    cancel: &CancellationToken,
) -> Result<Verification> {
    let (len, sha) = hash_and_boxes(path, expected)?;
    let path = std::fs::canonicalize(path).map_err(|_| Error::Io)?;
    let mut probe = Command::new("ffprobe");
    probe.args(["-v","error","-protocol_whitelist","file","-enable_drefs","0","-use_absolute_path","0","-show_entries","stream=codec_type,codec_name,width,height,duration,avg_frame_rate,nb_frames:format=duration","-of","json"]).arg(&path);
    let output = child_output(probe, cancel).await?;
    let v: Value = serde_json::from_slice(&output).map_err(|_| Error::Decode)?;
    let videos: Vec<_> = v["streams"]
        .as_array()
        .ok_or(Error::Decode)?
        .iter()
        .filter(|s| s["codec_type"] == "video")
        .collect();
    if videos.len() != 1 {
        return Err(Error::Decode);
    }
    let s = videos[0];
    let width = s["width"].as_u64().ok_or(Error::Decode)?;
    let height = s["height"].as_u64().ok_or(Error::Decode)?;
    let duration = s["duration"]
        .as_str()
        .or(v["format"]["duration"].as_str())
        .and_then(|s| s.parse::<f64>().ok())
        .ok_or(Error::Decode)?;
    let (a, b) = s["avg_frame_rate"]
        .as_str()
        .and_then(|s| s.split_once('/'))
        .ok_or(Error::Decode)?;
    let fps = a.parse::<f64>().unwrap_or(0.0) / b.parse::<f64>().unwrap_or(0.0);
    if width == 0
        || height == 0
        || width > 8192
        || height > 8192
        || !duration.is_finite()
        || duration <= 0.0
        || duration > 7200.0
        || !fps.is_finite()
        || fps <= 0.0
        || fps > 240.0
    {
        return Err(Error::Decode);
    }
    let mut decode = Command::new("ffmpeg");
    decode
        .args([
            "-v",
            "info",
            "-nostdin",
            "-xerror",
            "-err_detect",
            "explode",
            "-protocol_whitelist",
            "file",
            "-enable_drefs",
            "0",
            "-use_absolute_path",
            "0",
            "-threads",
            "2",
            "-i",
        ])
        .arg(&path)
        .args([
            "-map",
            "0:v:0",
            "-vf",
            "showinfo",
            "-an",
            "-sn",
            "-dn",
            "-fps_mode",
            "passthrough",
            "-stats_period",
            "3600",
            "-progress",
            "pipe:1",
            "-nostats",
            "-f",
            "null",
            "-",
        ]);
    // One full decode. Consume frame timestamps as bounded streaming diagnostics;
    // never retain stderr (which can include local paths/metadata).
    let (decoded, coverage) = coverage_output(decode, cancel, duration, fps).await?;
    let text = std::str::from_utf8(&decoded).map_err(|_| Error::Decode)?;
    let field = |key: &str| text.lines().filter_map(|l| l.strip_prefix(key)).next_back();
    let frames = field("frame=")
        .and_then(|v| v.trim().parse::<u64>().ok())
        .ok_or(Error::Decode)?;
    let end = field("out_time_us=")
        .and_then(|v| v.parse::<f64>().ok())
        .unwrap_or(0.0)
        / 1_000_000.0;
    if field("progress=") != Some("end")
        || frames == 0
        || frames > 250000
        || coverage.frames != frames
        || coverage.first.is_none()
        || !coverage.middle
        || !coverage.end
        || end < (duration - 2.0 / fps).max(duration * 0.95)
        || s["nb_frames"]
            .as_str()
            .and_then(|v| v.parse::<u64>().ok())
            .is_some_and(|n| n != frames)
    {
        return Err(Error::Decode);
    }
    let (len2, sha2) = hash_and_boxes(&path, expected)?;
    if len != len2 || sha != sha2 {
        return Err(Error::Decode);
    }
    Ok(Verification {
        file_bytes: len,
        sha256: sha,
        width,
        height,
        duration_seconds: duration,
        codec: s["codec_name"].as_str().unwrap_or("unknown").into(),
        decoded_frames: frames,
        container_complete: true,
        full_video_decode: true,
        audio_decode: "NOT_RUN",
        no_watermark: "NOT_VERIFIED",
        sha256_match: true,
        frame_rate: fps,
        first_frame_covered: coverage.first.is_some(),
        middle_interval_covered: coverage.middle,
        end_interval_covered: coverage.end,
        full_decode_ended: true,
        decode_errors_observed: false,
    })
}
