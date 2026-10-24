//! Descriptor-relative access keeps an agent's inbox changes from redirecting core I/O.
use std::fs::File;
use std::io::{self, Read, Write};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};

use rustix::fs::{AtFlags, Dir, Mode, OFlags, mkdirat, open, openat, renameat, unlinkat};

pub(super) struct Exchange {
    directory: File,
    pub inbox: File,
    pub records: File,
}

impl Exchange {
    pub fn open(root: &Path) -> io::Result<Self> {
        let root = File::from(open(
            root,
            OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
        )?);
        let directory = child_directory(&root, "exchange")?;
        Ok(Self {
            inbox: child_directory(&directory, "inbox")?,
            records: child_directory(&directory, "records")?,
            directory,
        })
    }

    pub fn write_record(&self, name: &str, bytes: &[u8]) -> io::Result<()> {
        atomic_write(&self.records, name, bytes)
    }

    pub fn write_catalog(&self, bytes: &[u8]) -> io::Result<()> {
        atomic_write(&self.directory, "catalog.md", bytes)
    }

    pub fn remove_record(&self, name: &str) -> io::Result<()> {
        unlinkat(&self.records, name, AtFlags::empty()).map_err(io::Error::from)
    }
}

fn child_directory(parent: &File, name: &str) -> io::Result<File> {
    match mkdirat(parent, name, Mode::RUSR | Mode::WUSR | Mode::XUSR) {
        Ok(()) | Err(rustix::io::Errno::EXIST) => {}
        Err(error) => return Err(error.into()),
    }
    Ok(File::from(openat(
        parent,
        name,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    )?))
}

pub(super) fn names(directory: &File) -> io::Result<Vec<String>> {
    let mut names = Vec::new();
    for entry in Dir::read_from(directory)? {
        let entry = entry?;
        let name = entry
            .file_name()
            .to_str()
            .map_err(|_| io::ErrorKind::InvalidData)?;
        if !matches!(name, "." | "..") {
            names.push(name.to_owned());
        }
    }
    names.sort();
    Ok(names)
}

pub(super) fn read_note(inbox: &File, name: &str) -> io::Result<String> {
    let mut file = File::from(openat(
        inbox,
        name,
        OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW | OFlags::NONBLOCK,
        Mode::empty(),
    )?);
    if !file.metadata()?.is_file() {
        return Err(io::ErrorKind::Unsupported.into());
    }
    let mut text = String::new();
    file.read_to_string(&mut text)?;
    Ok(text)
}

fn atomic_write(directory: &File, name: &str, bytes: &[u8]) -> io::Result<()> {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    if let Ok(fd) = openat(
        directory,
        name,
        OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW | OFlags::NONBLOCK,
        Mode::empty(),
    ) {
        let file = File::from(fd);
        if file.metadata()?.is_file() {
            let mut existing = Vec::new();
            file.take(bytes.len() as u64 + 1)
                .read_to_end(&mut existing)?;
            if existing == bytes {
                return Ok(());
            }
        }
    }
    for _ in 0..100 {
        let temporary = format!(
            ".twine-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        );
        let fd = match openat(
            directory,
            temporary.as_str(),
            OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::CLOEXEC,
            Mode::RUSR | Mode::WUSR,
        ) {
            Ok(fd) => fd,
            Err(rustix::io::Errno::EXIST) => continue,
            Err(error) => return Err(error.into()),
        };
        let mut file = File::from(fd);
        let result = (|| {
            file.write_all(bytes)?;
            file.sync_all()?;
            renameat(directory, temporary.as_str(), directory, name)?;
            directory.sync_all()
        })();
        if result.is_err() {
            let _ = unlinkat(directory, temporary.as_str(), AtFlags::empty());
        }
        return result;
    }
    Err(io::Error::other("Could not stage shared memory output."))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replacing_exchange_directories_cannot_redirect_reads_or_writes() {
        let root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        std::fs::write(outside.path().join("secret.md"), "private").unwrap();
        let exchange = Exchange::open(root.path()).unwrap();
        let inbox = root.path().join("exchange/inbox");
        std::fs::rename(&inbox, root.path().join("original-inbox")).unwrap();
        std::os::unix::fs::symlink(outside.path(), &inbox).unwrap();
        assert!(read_note(&exchange.inbox, "secret.md").is_err());
        let records = root.path().join("exchange/records");
        std::fs::rename(&records, root.path().join("original-records")).unwrap();
        std::os::unix::fs::symlink(outside.path(), &records).unwrap();
        exchange.write_record("secret.md", b"projection").unwrap();
        assert_eq!(
            std::fs::read_to_string(outside.path().join("secret.md")).unwrap(),
            "private"
        );
        assert!(Exchange::open(root.path()).is_err());
    }
}
