//! Shared, allocation-free Cookie parsing. Diagnostics contain static names and enums only.
use crate::{Error, Result};
use zeroize::Zeroizing;

pub const UIFID_NAMES: &[&str] = &[
    "uifid",
    "uifid_temp",
    "uifidtemp",
    "UIFID",
    "UIFID_TEMP",
    "UIFIDTEMP",
];
pub const TOKEN_NAMES: &[&str] = &["msToken"];
pub const COOKIE_LIMIT: usize = 32768;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    Present,
    Missing,
    Empty,
    Duplicated,
    InvalidFormat,
    Unknown,
    MalformedCandidate,
}
impl Status {
    pub fn label(self) -> &'static str {
        match self {
            Self::Present => "PRESENT",
            Self::Missing => "MISSING",
            Self::Empty => "EMPTY",
            Self::Duplicated => "DUPLICATED",
            Self::InvalidFormat => "INVALID_FORMAT",
            Self::Unknown => "UNKNOWN",
            Self::MalformedCandidate => "MALFORMED_CANDIDATE",
        }
    }
}

// Same whole-segment trimming and first '=' split as the original signer.
fn raw_segments(raw: &str) -> impl Iterator<Item = &str> {
    raw.split(';').filter(|s| !s.trim().is_empty())
}
fn segments(raw: &str) -> impl Iterator<Item = &str> {
    raw_segments(raw).map(str::trim)
}

#[derive(Clone, Copy)]
enum ScanMode {
    StrictValidation,
    DiagnosticInspection,
}

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&b))
}

// Both modes use the same trim, first '=' split and exact key comparison.
// Diagnostic mode skips an entire unreliable segment; it never repairs or splits on newline.
fn parsed_segment(segment: &str, mode: ScanMode) -> Option<(&str, &str)> {
    let pair = segment.trim().split_once('=')?;
    if matches!(mode, ScanMode::DiagnosticInspection)
        && (segment.chars().any(char::is_control) || !valid_name(pair.0))
    {
        return None;
    }
    Some(pair)
}

fn malformed_candidate(raw: &str, names: &[&str]) -> bool {
    raw_segments(raw)
        .filter(|segment| parsed_segment(segment, ScanMode::DiagnosticInspection).is_none())
        .any(|segment| {
            let text = segment.trim();
            names.iter().any(|name| {
                text.strip_prefix(name).is_some_and(|tail| {
                    tail.is_empty()
                        || tail.starts_with(|c: char| {
                            c == '=' || !c.is_ascii_alphanumeric() && c != '_'
                        })
                })
            })
        })
}
pub fn valid_structure(raw: &str) -> bool {
    structure_error(raw).is_none()
}

// Fixed categories only: never retain the rejected field name/value, offset, or size.
// These are the existing checks, now explained rather than collapsed to a bool.
fn structure_error(raw: &str) -> Option<&'static str> {
    if raw.trim().is_empty() {
        return Some("COOKIE_INPUT_EMPTY");
    }
    if raw.len() > COOKIE_LIMIT {
        return Some("COOKIE_INPUT_LIMIT_EXCEEDED");
    }
    if raw.contains(['\r', '\n']) {
        return Some("COOKIE_EMBEDDED_LINE_BREAK");
    }
    if raw.chars().any(char::is_control) {
        return Some("COOKIE_CONTROL_CHARACTER");
    }
    if !raw.bytes().all(|b| b >= 32 && b != 127) {
        return Some("COOKIE_HEADER_BYTES_INVALID");
    }
    if raw
        .trim_start()
        .get(..7)
        .is_some_and(|prefix| prefix.eq_ignore_ascii_case("cookie:"))
    {
        return Some("COOKIE_HEADER_LABEL_PRESENT");
    }
    for segment in segments(raw) {
        let Some((name, _)) = segment.split_once('=') else {
            return Some("COOKIE_SEGMENT_MISSING_EQUALS");
        };
        if name.is_empty() {
            return Some("COOKIE_FIELD_NAME_EMPTY");
        }
        if name.chars().any(char::is_whitespace) {
            return Some("COOKIE_FIELD_NAME_WHITESPACE");
        }
        if !valid_name(name) {
            return Some("COOKIE_FIELD_NAME_INVALID");
        }
    }
    if segments(raw).next().is_none() {
        return Some("COOKIE_NO_FIELDS");
    }
    None
}

// No owned credential copies, Debug, or serialization. Different aliases are not duplicates.
// All occurrences of each accepted name count, including empty values.
fn field<'a>(
    raw: &'a str,
    names: &'static [&'static str],
    mode: ScanMode,
) -> (&'static str, Status, Option<&'a str>) {
    let mut selected = None;
    let mut empty = None;
    for &name in names {
        let mut values = raw_segments(raw)
            .filter_map(|s| parsed_segment(s, mode))
            .filter(|(key, _)| *key == name)
            .map(|(_, value)| value);
        if let Some(value) = values.next() {
            if values.next().is_some() {
                return (name, Status::Duplicated, None);
            }
            if value.is_empty() {
                empty.get_or_insert(name);
            } else if selected.is_none() {
                selected = Some((name, value));
            }
        }
    }
    if let Some((name, value)) = selected {
        (name, Status::Present, Some(value))
    } else if let Some(name) = empty {
        (name, Status::Empty, None)
    } else {
        (names[0], Status::Missing, None)
    }
}

pub fn resolve<'a>(raw: &'a str, names: &'static [&'static str]) -> Result<&'a str> {
    if !valid_structure(raw) {
        return Err(Error::Credential);
    }
    field(raw, names, ScanMode::StrictValidation)
        .2
        .ok_or(Error::Credential)
}

/// Request parameter policy for msToken only. Structural errors and duplicates
/// remain errors; an absent or empty field supplies the literal empty value.
pub fn resolve_ms_token(raw: &str) -> Result<&str> {
    if !valid_structure(raw) {
        return Err(Error::Credential);
    }
    match field(raw, TOKEN_NAMES, ScanMode::StrictValidation) {
        (_, Status::Present, Some(value)) => Ok(value),
        (_, Status::Missing | Status::Empty, _) => Ok(""),
        _ => Err(Error::Credential),
    }
}

#[derive(Debug)]
pub struct Diagnostic {
    pub fields: [(&'static str, Status); 2],
    pub structure_valid: bool,
    pub structure_error: Option<&'static str>,
    /// Status restricted to reliably parseable segments; Missing means not observed there.
    pub observed_fields: [(&'static str, Status); 2],
    pub inspection_complete: bool,
    pub malformed_candidates: [bool; 2],
    /// None means the parameter could not be resolved safely, not an empty value.
    pub ms_token_request_value: Option<&'static str>,
    strict_validation_passed: bool,
}
impl Diagnostic {
    pub fn passed(&self) -> bool {
        self.strict_validation_passed
    }
    pub fn inspection_label(&self) -> &'static str {
        if self.inspection_complete {
            "COMPLETE"
        } else {
            "PARTIAL"
        }
    }
    pub fn strict_label(&self) -> &'static str {
        if self.passed() {
            "PASS"
        } else {
            "REJECT"
        }
    }
    fn observation_label(&self, index: usize) -> &'static str {
        if self.observed_fields[index].1 == Status::Missing {
            "NOT_OBSERVED_IN_PARSEABLE_SEGMENTS"
        } else {
            "CONFIRMED_IN_PARSEABLE_SEGMENTS"
        }
    }
    fn parseable_label(&self, index: usize) -> &'static str {
        if self.observed_fields[index].1 == Status::Missing {
            "NOT_OBSERVED"
        } else {
            self.observed_fields[index].1.label()
        }
    }
    pub fn json(&self) -> serde_json::Value {
        let fields = [0, 1].map(|i| {
            serde_json::json!({
                "name": self.fields[i].0,
                "status": self.fields[i].1.label(),
                "observation": self.observation_label(i),
                "parseable_status": self.parseable_label(i),
                "malformed_candidate": self.malformed_candidates[i],
            })
        });
        serde_json::json!({
            "task": "DOUSTUDIOKIT_WINDOWS_MSTOKEN_COMPAT_04",
            "mode": "DiagnosticInspection",
            "COOKIE_STRUCTURE": if self.structure_valid { "PASS" } else { "FAIL" },
            "STRUCTURE_REASON": self.structure_error.unwrap_or("NONE"),
            "MSTOKEN_FIELD": self.fields[0].1.label(),
            "MSTOKEN_REQUEST_VALUE": self.ms_token_request_value,
            "UIFID_FIELD": self.fields[1].1.label(),
            "credential_fields": { "msToken": fields[0], "UIFID": fields[1] },
            "FIELD_INSPECTION": self.inspection_label(),
            "LOCAL_CREDENTIAL_STRUCTURE": if self.passed() { "PASS" } else { "FAIL" },
            "STRICT_SIGNING_VALIDATION": self.strict_label(),
            "SIGNING_ALLOWED": "NO",
            "SIGNING": "NOT_RUN",
            "NETWORK_REQUESTS": 0,
            "DNS_REQUESTS": 0,
            "REAL_HTTP_REQUESTS": 0,
            "REAL_MEDIA_REQUESTS": 0,
        })
    }
    pub fn render(&self) -> String {
        let mut out = String::from("DouStudioKit Offline Credential Check\n\nNetwork access: DISABLED\nSigning: NOT_RUN\nHTTP requests: 0\n\nCredential fields (UIFID required; msToken optional, duplicates rejected):\n");
        for (index, (name, status)) in self.fields.iter().enumerate() {
            out.push_str(&format!(
                "  {name}: {} [{}; parseable_status={}]\n",
                status.label(),
                self.observation_label(index),
                self.parseable_label(index)
            ));
        }
        out.push_str("UIFID aliases (one required, case-sensitive, priority order):\n  ");
        out.push_str(&UIFID_NAMES.join(" | "));
        out.push_str(&format!("\nMSTOKEN_FIELD = {}\n", self.fields[0].1.label()));
        if let Some(value) = self.ms_token_request_value {
            out.push_str(&format!("MSTOKEN_REQUEST_VALUE = {value}\n"));
        } else {
            out.push_str(
                "MSTOKEN_REQUEST_VALUE unavailable: structure invalid or msToken duplicated.\n",
            );
        }
        let reason = if self.passed() {
            "NONE"
        } else if let Some(error) = self.structure_error {
            error
        } else if self.fields.iter().any(|(_, s)| *s == Status::Duplicated) {
            "CREDENTIAL_FIELD_DUPLICATED"
        } else if self.fields[1].1 == Status::Empty {
            "REQUIRED_FIELD_EMPTY"
        } else {
            "REQUIRED_FIELD_MISSING"
        };
        out.push_str(&format!("\n\nCOOKIE_STRUCTURE = {}\nSTRUCTURE_REASON = {}\nFailure reason: {reason}\nFIELD_INSPECTION = {}\nLOCAL_CREDENTIAL_STRUCTURE = {}\nSTRICT_SIGNING_VALIDATION = {}\nSIGNING_ALLOWED = NO\nNETWORK_REQUESTS = 0\nNo request was sent.\n", if self.structure_valid { "PASS" } else { "FAIL" }, self.structure_error.unwrap_or("NONE"), self.inspection_label(), if self.passed() { "PASS" } else { "FAIL" }, self.strict_label()));
        if !self.inspection_complete {
            out.push_str("PARTIAL: field states describe parseable segments only; unobserved fields are UNKNOWN, not proven absent.\n");
        }
        out
    }
}
pub fn inspect(raw: &str) -> Diagnostic {
    let structure_error = structure_error(raw);
    let structure_valid = structure_error.is_none();
    let inspection_complete = structure_valid || raw.trim().is_empty();
    // Never process an over-limit input as a complete scan.
    let within_limit = raw.len() <= COOKIE_LIMIT;
    let observed_fields = [TOKEN_NAMES, UIFID_NAMES].map(|names| {
        let (name, status, _) = if within_limit {
            field(raw, names, ScanMode::DiagnosticInspection)
        } else {
            (names[0], Status::Missing, None)
        };
        (name, status)
    });
    let malformed_candidates =
        [TOKEN_NAMES, UIFID_NAMES].map(|names| within_limit && malformed_candidate(raw, names));
    let fields = [0, 1].map(|i| {
        let (name, observed) = observed_fields[i];
        let status = if observed == Status::Duplicated {
            observed
        } else if malformed_candidates[i] && i == 0 {
            Status::Unknown
        } else if malformed_candidates[i] {
            Status::MalformedCandidate
        } else if observed == Status::Missing && !inspection_complete {
            Status::Unknown
        } else {
            observed
        };
        (name, status)
    });
    // Calls strict credential resolution only, never a signer or client.
    let token = resolve_ms_token(raw);
    let ms_token_request_value = token.as_ref().ok().map(|value| {
        if value.is_empty() {
            "EMPTY"
        } else {
            "ORIGINAL"
        }
    });
    let strict_validation_passed = token.is_ok() && resolve(raw, UIFID_NAMES).is_ok();
    Diagnostic {
        fields,
        structure_valid,
        structure_error,
        observed_fields,
        inspection_complete,
        malformed_candidates,
        ms_token_request_value,
        strict_validation_passed,
    }
}

pub fn diagnose(secret: Zeroizing<String>) -> Diagnostic {
    let diagnostic = inspect(&secret);
    drop(secret); // zeroize before rendering or returning the safe result
    diagnostic
}

#[derive(clap::Args)]
pub struct Options {
    /// Print only the sanitized diagnostic JSON to stdout.
    #[arg(long)]
    pub json: bool,
    /// Read an explicitly selected local UTF-8 TXT outside the repository.
    #[arg(long)]
    pub cookie_file: Option<std::path::PathBuf>,
    /// Synthetic fixtures only; absent from production builds.
    #[cfg(feature = "offline-test")]
    #[arg(long, conflicts_with = "cookie_file")]
    pub synthetic_stdin: bool,
}
pub fn run(options: Options) -> Result<()> {
    #[cfg(feature = "offline-test")]
    let secret = if options.synthetic_stdin {
        use std::io::Read;
        let mut secret = Zeroizing::new(String::new());
        std::io::stdin()
            .take((COOKIE_LIMIT + 1) as u64)
            .read_to_string(&mut secret)
            .map_err(|_| Error::Credential)?;
        secret
    } else {
        crate::credential_file::input(options.cookie_file.as_deref())?
    };
    #[cfg(not(feature = "offline-test"))]
    let secret = crate::credential_file::input(options.cookie_file.as_deref())?;
    let diagnostic = diagnose(secret);
    if options.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&diagnostic.json()).map_err(|_| Error::Schema)?
        );
    } else {
        print!("{}", diagnostic.render());
    }
    if diagnostic.passed() {
        Ok(())
    } else {
        Err(Error::Credential)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn borrowed_parser_retains_value_bytes_and_alias_priority() {
        let (name, status, value) = field(
            "uifid=; UIFID_TEMP=a=b==; msToken=t",
            UIFID_NAMES,
            ScanMode::StrictValidation,
        );
        assert_eq!(
            (name, status, value),
            ("UIFID_TEMP", Status::Present, Some("a=b=="))
        );
        assert_eq!(
            field(
                "msToken=; msToken=t",
                TOKEN_NAMES,
                ScanMode::StrictValidation
            )
            .1,
            Status::Duplicated
        );
        assert_eq!(
            field(
                "msToken=;unrelated=x;unrelated=y",
                TOKEN_NAMES,
                ScanMode::StrictValidation
            )
            .1,
            Status::Empty
        );
    }

    #[test]
    fn accepted_text_is_always_accepted_by_existing_header_validator() {
        for value in [
            "ascii", "a=b==", " leading", "é", "\u{85}", "\u{7f}", "\r", "\t",
        ] {
            let raw = format!("msToken={value};UIFID_TEMP=synthetic");
            if valid_structure(&raw) {
                assert!(reqwest::header::HeaderValue::from_str(&raw).is_ok());
            }
        }
    }
}
