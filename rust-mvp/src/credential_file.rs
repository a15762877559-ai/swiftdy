//! Local opt-in input. Never logs paths or contents. No network or signing dependencies.
use crate::{credentials::COOKIE_LIMIT, Error, Result};
use std::{
    fs::{File, OpenOptions},
    io::Read,
    path::{Component, Path},
};
use zeroize::Zeroizing;

pub fn input(path: Option<&Path>) -> Result<Zeroizing<String>> {
    match path {
        Some(path) => read(path),
        None => rpassword::prompt_password("Authorized session Cookie (hidden): ")
            .map(Zeroizing::new)
            .map_err(|_| Error::Credential),
    }
}

fn reparse(meta: &std::fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        meta.file_attributes() & 0x400 != 0
    }
    #[cfg(not(windows))]
    {
        meta.file_type().is_symlink()
    }
}

fn open_checked(path: &Path, directory: bool) -> Result<File> {
    let meta = std::fs::symlink_metadata(path).map_err(|_| Error::CredentialFile)?;
    if reparse(&meta) || (directory && !meta.is_dir()) || (!directory && !meta.is_file()) {
        return Err(Error::CredentialFile);
    }
    let mut opts = OpenOptions::new();
    opts.read(true);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        // Do not follow final reparse points. Hold ancestors without FILE_SHARE_DELETE
        // to prevent renaming/replacing the validated path while the file is read.
        opts.custom_flags(0x00200000 | if directory { 0x02000000 } else { 0 });
        opts.share_mode(if directory { 1 | 2 } else { 0 });
    }
    let file = opts.open(path).map_err(|_| Error::CredentialFile)?;
    let actual = file.metadata().map_err(|_| Error::CredentialFile)?;
    if reparse(&actual) || (directory && !actual.is_dir()) || (!directory && !actual.is_file()) {
        return Err(Error::CredentialFile);
    }
    #[cfg(windows)]
    if !directory {
        use std::os::windows::io::AsRawHandle;
        #[repr(C)]
        #[derive(Default)]
        struct FileInformation {
            attributes: u32,
            creation: [u32; 2],
            access: [u32; 2],
            write: [u32; 2],
            volume: u32,
            size_high: u32,
            size_low: u32,
            links: u32,
            index_high: u32,
            index_low: u32,
        }
        #[link(name = "kernel32")]
        unsafe extern "system" {
            fn GetFileInformationByHandle(
                handle: *mut std::ffi::c_void,
                information: *mut FileInformation,
            ) -> i32;
        }
        let mut information = FileInformation::default();
        // A second hard link could put the same secret inside a repository.
        if unsafe { GetFileInformationByHandle(file.as_raw_handle(), &mut information) } == 0
            || information.links != 1
        {
            return Err(Error::CredentialFile);
        }
    }
    Ok(file)
}

fn repository_path(path: &Path) -> bool {
    let compiled_repo = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    // Canonicalize the directory, not the secret file. Compare case-insensitively on Windows.
    let normalize = |p: &Path| {
        let text = p.to_string_lossy().replace('/', "\\");
        #[cfg(windows)]
        {
            text.trim_start_matches("\\\\?\\").to_lowercase()
        }
        #[cfg(not(windows))]
        {
            text
        }
    };
    let candidate = normalize(path);
    let repo = normalize(compiled_repo);
    if candidate == repo || candidate.starts_with(&(repo + "\\")) {
        return true;
    }
    false
}

pub fn read(path: &Path) -> Result<Zeroizing<String>> {
    if !path.is_absolute() || repository_path(path) {
        return Err(Error::CredentialFile);
    }
    // No relative segments, alternate streams, UNC shares, or device/verbatim paths.
    for c in path.components() {
        match c {
            Component::Normal(s) if s.to_string_lossy().contains(':') => {
                return Err(Error::CredentialFile)
            }
            Component::ParentDir | Component::CurDir => return Err(Error::CredentialFile),
            _ => (),
        }
    }
    #[cfg(windows)]
    {
        use std::path::Prefix;
        let Some(Component::Prefix(prefix)) = path.components().next() else {
            return Err(Error::CredentialFile);
        };
        let Prefix::Disk(drive) = prefix.kind() else {
            return Err(Error::CredentialFile);
        };
        #[link(name = "kernel32")]
        unsafe extern "system" {
            fn GetDriveTypeW(root: *const u16) -> u32;
        }
        let root = [drive as u16, b':' as u16, b'\\' as u16, 0];
        // Only local fixed/removable drives; no mapped network drives.
        if !matches!(unsafe { GetDriveTypeW(root.as_ptr()) }, 2 | 3) {
            return Err(Error::CredentialFile);
        }
    }
    let mut ancestors = Vec::new();
    let mut current = std::path::PathBuf::new();
    let components: Vec<_> = path.components().collect();
    for (index, component) in components.iter().enumerate() {
        current.push(component.as_os_str());
        if matches!(component, Component::Prefix(_)) {
            continue;
        }
        if index + 1 < components.len() {
            ancestors.push(open_checked(&current, true)?);
            if std::fs::symlink_metadata(current.join(".git")).is_ok() {
                return Err(Error::CredentialFile);
            }
        }
    }
    let canonical = path
        .parent()
        .ok_or(Error::CredentialFile)?
        .canonicalize()
        .map_err(|_| Error::CredentialFile)?
        .join(path.file_name().ok_or(Error::CredentialFile)?);
    if repository_path(&canonical) {
        return Err(Error::CredentialFile);
    }
    let mut file = open_checked(path, false)?;
    // Fixed allocation: no old credential-bearing Vec allocation left by growth.
    let mut bytes = Zeroizing::new(vec![0u8; COOKIE_LIMIT + 8]);
    let mut used = 0;
    while used < bytes.len() {
        let count = file
            .read(&mut bytes[used..])
            .map_err(|_| Error::CredentialFile)?;
        if count == 0 {
            break;
        }
        used += count;
    }
    let text = std::str::from_utf8(&bytes[..used]).map_err(|_| Error::CredentialFile)?;
    // UTF-8 BOM and one text-editor terminal newline are framing, not Cookie data.
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let text = text
        .strip_suffix("\r\n")
        .or_else(|| text.strip_suffix('\n'))
        .unwrap_or(text);
    if text.len() > COOKIE_LIMIT {
        return Err(Error::CredentialFile);
    }
    Ok(Zeroizing::new(text.to_owned()))
}
