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
}
impl Status {
    pub fn label(self) -> &'static str {
        match self {
            Self::Present => "PRESENT",
            Self::Missing => "MISSING",
            Self::Empty => "EMPTY",
            Self::Duplicated => "DUPLICATED",
            Self::InvalidFormat => "INVALID_FORMAT",
        }
    }
}

// Same whole-segment trimming and first '=' split as the original signer.
fn segments(raw: &str) -> impl Iterator<Item = &str> {
    raw.split(';').map(str::trim).filter(|s| !s.is_empty())
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
        if !name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&b))
        {
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
) -> (&'static str, Status, Option<&'a str>) {
    let mut selected = None;
    let mut empty = None;
    for &name in names {
        let mut values = segments(raw)
            .filter_map(|s| s.split_once('='))
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
    field(raw, names).2.ok_or(Error::Credential)
}

#[derive(Debug)]
pub struct Diagnostic {
    pub fields: [(&'static str, Status); 2],
    pub structure_valid: bool,
    pub structure_error: Option<&'static str>,
}
impl Diagnostic {
    pub fn passed(&self) -> bool {
        self.structure_valid && self.fields.iter().all(|(_, s)| *s == Status::Present)
    }
    pub fn render(&self) -> String {
        let mut out = String::from("DouStudioKit Offline Credential Check\n\nNetwork access: DISABLED\nSigning: NOT_RUN\nHTTP requests: 0\n\nRequired fields:\n");
        for (name, status) in self.fields {
            out.push_str(&format!("  {name}: {}\n", status.label()));
        }
        out.push_str("UIFID aliases (one required, case-sensitive, priority order):\n  ");
        out.push_str(&UIFID_NAMES.join(" | "));
        let reason = if self.passed() {
            "NONE"
        } else if let Some(error) = self.structure_error {
            error
        } else if self.fields.iter().any(|(_, s)| *s == Status::Duplicated) {
            "REQUIRED_FIELD_DUPLICATED"
        } else if self.fields.iter().any(|(_, s)| *s == Status::Empty) {
            "REQUIRED_FIELD_EMPTY"
        } else {
            "REQUIRED_FIELD_MISSING"
        };
        out.push_str(&format!("\n\nCookie structure: {}\nFailure reason: {reason}\nLOCAL_CREDENTIAL_STRUCTURE = {}\nNo request was sent.\n", if self.passed() { "PASS" } else { "FAIL" }, if self.passed() { "PASS" } else { "FAIL" }));
        out
    }
}
pub fn inspect(raw: &str) -> Diagnostic {
    let structure_error = structure_error(raw);
    let structure_valid = structure_error.is_none();
    let fields = [TOKEN_NAMES, UIFID_NAMES].map(|names| {
        if !structure_valid && !raw.trim().is_empty() {
            (names[0], Status::InvalidFormat)
        } else {
            let (name, status, _) = field(raw, names);
            (name, status)
        }
    });
    Diagnostic {
        fields,
        structure_valid,
        structure_error,
    }
}

pub fn diagnose(secret: Zeroizing<String>) -> Diagnostic {
    let diagnostic = inspect(&secret);
    drop(secret); // zeroize before rendering or returning the safe result
    diagnostic
}

#[derive(clap::Args)]
pub struct Options {
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
    print!("{}", diagnostic.render());
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
        let (name, status, value) = field("uifid=; UIFID_TEMP=a=b==; msToken=t", UIFID_NAMES);
        assert_eq!(
            (name, status, value),
            ("UIFID_TEMP", Status::Present, Some("a=b=="))
        );
        assert_eq!(
            field("msToken=; msToken=t", TOKEN_NAMES).1,
            Status::Duplicated
        );
        assert_eq!(
            field("msToken=;unrelated=x;unrelated=y", TOKEN_NAMES).1,
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
