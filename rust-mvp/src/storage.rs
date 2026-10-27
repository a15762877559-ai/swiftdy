use crate::{Error, Result};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
};
use tempfile::NamedTempFile;

pub fn safe_path(path: &Path) -> Result<()> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().map_err(|_| Error::Io)?.join(path)
    };
    for parent in absolute.ancestors() {
        let m = fs::symlink_metadata(parent).map_err(|_| Error::Io)?;
        if m.file_type().is_symlink() {
            return Err(Error::Io);
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::MetadataExt;
            if m.file_attributes() & 0x400 != 0 {
                return Err(Error::Io);
            }
        }
    }
    Ok(())
}
pub struct Staging {
    file: NamedTempFile,
    final_path: PathBuf,
    pub written: u64,
}
impl Staging {
    pub fn new(directory: &Path, name: &str) -> Result<Self> {
        if !name.ends_with(".mp4")
            || name.len() > 128
            || name
                .bytes()
                .any(|b| !b.is_ascii_alphanumeric() && !b"-_.".contains(&b))
            || name.starts_with('.')
        {
            return Err(Error::Io);
        }
        // Require an existing user-selected directory; never recursively create through reparse points.
        safe_path(directory)?;
        let root = fs::canonicalize(directory).map_err(|_| Error::Io)?;
        if !root.is_dir() {
            return Err(Error::Io);
        }
        let final_path = root.join(name);
        if fs::symlink_metadata(&final_path).is_ok() {
            return Err(Error::Exists);
        }
        let file = tempfile::Builder::new()
            .prefix(".doustudio-")
            .suffix(".part")
            .tempfile_in(root)
            .map_err(|_| Error::Io)?;
        Ok(Self {
            file,
            final_path,
            written: 0,
        })
    }
    pub fn write(&mut self, bytes: &[u8]) -> Result<()> {
        if self.written + bytes.len() as u64 > crate::MAX_MEDIA_BYTES {
            return Err(Error::Budget);
        }
        self.file.write_all(bytes).map_err(|_| Error::Io)?;
        self.written += bytes.len() as u64;
        Ok(())
    }
    pub fn path(&self) -> &Path {
        self.file.path()
    }
    pub fn flush(&mut self) -> Result<()> {
        self.file
            .flush()
            .and_then(|_| self.file.as_file().sync_all())
            .map_err(|_| Error::Io)
    }
    pub fn commit(self) -> Result<PathBuf> {
        self.file.persist_noclobber(&self.final_path).map_err(|e| {
            if e.error.kind() == std::io::ErrorKind::AlreadyExists {
                Error::Exists
            } else {
                Error::Io
            }
        })?;
        Ok(self.final_path)
    }
}
