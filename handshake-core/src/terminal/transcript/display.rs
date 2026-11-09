//! Disposable, bounded display pages. Raw transcripts remain authoritative.
use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use super::TranscriptError;

pub const MAX_DISPLAY_PAGE_BYTES: usize = 1024 * 1024;
const TERMINAL_LIMIT: u64 = 64 * 1024 * 1024;
const TOTAL_LIMIT: u64 = 256 * 1024 * 1024;
const FILE_LIMIT: usize = 16_384;

pub(super) struct DisplayCache {
    directory: PathBuf,
    entries: HashMap<(u64, u64), (u64, u64)>,
    clock: u64,
}

impl DisplayCache {
    pub(super) fn open(directory: &Path) -> Result<Self, TranscriptError> {
        fs::create_dir_all(directory)?;
        let mut cache = Self {
            directory: directory.into(),
            entries: HashMap::new(),
            clock: 0,
        };
        for entry in fs::read_dir(directory)? {
            let entry = entry?;
            let name = entry.file_name();
            let Some((terminal, key)) = name
                .to_str()
                .and_then(|name| name.strip_suffix(".page"))
                .and_then(|name| name.split_once('-'))
            else {
                if entry.file_type()?.is_file() {
                    fs::remove_file(entry.path())?;
                }
                continue;
            };
            let (Ok(terminal), Ok(key)) = (terminal.parse(), key.parse()) else {
                continue;
            };
            let length = entry.metadata()?.len();
            if length <= MAX_DISPLAY_PAGE_BYTES as u64 + 8 {
                cache.clock += 1;
                cache.entries.insert((terminal, key), (length, cache.clock));
            } else {
                fs::remove_file(entry.path())?;
            }
        }
        cache.trim(None)?;
        Ok(cache)
    }

    fn path(&self, terminal: u64, key: u64) -> PathBuf {
        self.directory.join(format!("{terminal}-{key}.page"))
    }

    pub(super) fn read(
        &mut self,
        terminal: u64,
        key: u64,
        end: u64,
    ) -> Result<Option<Vec<u8>>, TranscriptError> {
        let Some(entry) = self.entries.get_mut(&(terminal, key)) else {
            return Ok(None);
        };
        self.clock += 1;
        entry.1 = self.clock;
        let data = fs::read(self.path(terminal, key))?;
        if data.len() < 8 || u64::from_le_bytes(data[..8].try_into().unwrap()) > end {
            return Ok(None);
        }
        Ok(Some(data[8..].to_vec()))
    }

    pub(super) fn write(
        &mut self,
        terminal: u64,
        key: u64,
        source_offset: u64,
        bytes: &[u8],
    ) -> Result<(), TranscriptError> {
        if bytes.len() > MAX_DISPLAY_PAGE_BYTES {
            return Err(TranscriptError::InvalidDisplayPage);
        }
        let temporary = self.directory.join("page.next");
        let mut file = super::storage::private_file()
            .write(true)
            .create(true)
            .truncate(true)
            .open(&temporary)?;
        file.write_all(&source_offset.to_le_bytes())?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(temporary, self.path(terminal, key))?;
        self.clock += 1;
        self.entries
            .insert((terminal, key), ((bytes.len() + 8) as u64, self.clock));
        self.trim(Some(terminal))
    }

    pub(super) fn retain(
        &mut self,
        terminals: &std::collections::HashSet<u64>,
    ) -> Result<(), TranscriptError> {
        let remove: Vec<_> = self
            .entries
            .keys()
            .copied()
            .filter(|(id, _)| !terminals.contains(id))
            .collect();
        for entry in remove {
            self.remove(entry)?;
        }
        Ok(())
    }

    fn remove(&mut self, entry: (u64, u64)) -> Result<(), TranscriptError> {
        match fs::remove_file(self.path(entry.0, entry.1)) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        self.entries.remove(&entry);
        Ok(())
    }

    fn trim(&mut self, terminal: Option<u64>) -> Result<(), TranscriptError> {
        loop {
            let total: u64 = self.entries.values().map(|entry| entry.0).sum();
            let local: u64 = self
                .entries
                .iter()
                .filter(|((id, _), _)| Some(*id) == terminal)
                .map(|(_, entry)| entry.0)
                .sum();
            let local_over = local > TERMINAL_LIMIT;
            if total <= TOTAL_LIMIT && !local_over && self.entries.len() <= FILE_LIMIT {
                return Ok(());
            }
            let oldest = self
                .entries
                .iter()
                .filter(|((id, _), _)| !local_over || Some(*id) == terminal)
                .min_by_key(|(_, entry)| entry.1)
                .map(|(key, _)| *key);
            let Some(oldest) = oldest else {
                return Ok(());
            };
            self.remove(oldest)?;
        }
    }
}

// Optional cache I/O cannot stall the canonical recorder or PTY delivery. The bounded queue
// admits at most eight 1 MiB pages, and a busy cache asks callers to retry asynchronously.
use std::collections::HashSet;
use std::sync::{Arc, Mutex, mpsc};
use std::thread::JoinHandle;

use super::{DisplayCacheOperation, DisplayCacheRequest};
use crate::terminal::TerminalId;

enum CacheJob {
    Page {
        terminal: TerminalId,
        operation: DisplayCacheOperation,
        reply: mpsc::SyncSender<Result<Option<Vec<u8>>, TranscriptError>>,
    },
    #[cfg(test)]
    Stall {
        ready: mpsc::SyncSender<()>,
        resume: mpsc::Receiver<()>,
    },
}

pub(super) struct DisplayCacheWorker {
    sender: Mutex<Option<mpsc::SyncSender<Option<CacheJob>>>>,
    worker: Mutex<Option<JoinHandle<()>>>,
    allowed: Arc<Mutex<HashSet<u64>>>,
}

impl DisplayCacheWorker {
    pub(super) fn start(directory: PathBuf, retained: HashSet<TerminalId>) -> Self {
        let (sender, receiver) = mpsc::sync_channel::<Option<CacheJob>>(8);
        let allowed = Arc::new(Mutex::new(
            retained.iter().map(|id| id.value()).collect::<HashSet<_>>(),
        ));
        let worker_allowed = Arc::clone(&allowed);
        let worker = crate::blocking_worker::spawn("terminal-display-cache".into(), move || {
            let mut cache = DisplayCache::open(&directory).ok();
            if let Some(cache) = &mut cache {
                let _ = cache.retain(&retained.iter().map(|id| id.value()).collect());
            }
            while let Ok(job) = receiver.recv() {
                let allowed = worker_allowed
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .clone();
                if let Some(cache) = &mut cache {
                    let _ = cache.retain(&allowed);
                }
                let Some(job) = job else {
                    continue;
                };
                let (terminal, operation, reply) = match job {
                    #[cfg(test)]
                    CacheJob::Stall { ready, resume } => {
                        let _ = ready.send(());
                        let _ = resume.recv();
                        continue;
                    }
                    CacheJob::Page {
                        terminal,
                        operation,
                        reply,
                    } => (terminal, operation, reply),
                };
                let result = if !allowed.contains(&terminal.value()) {
                    Ok(None)
                } else if let Some(cache) = &mut cache {
                    match operation {
                        DisplayCacheOperation::Read { key } => {
                            cache.read(terminal.value(), key, u64::MAX)
                        }
                        DisplayCacheOperation::Write {
                            key,
                            source_offset,
                            bytes,
                        } => cache
                            .write(terminal.value(), key, source_offset, &bytes)
                            .map(|()| None),
                    }
                } else {
                    Ok(None)
                };
                // Failed cache reads/writes are misses. They cannot poison the raw recorder.
                let _ = reply.send(Ok(result.unwrap_or(None)));
            }
        })
        .ok();
        Self {
            sender: Mutex::new(worker.as_ref().map(|_| sender)),
            worker: Mutex::new(worker),
            allowed,
        }
    }

    pub(super) fn request(
        &self,
        terminal: TerminalId,
        operation: DisplayCacheOperation,
    ) -> Result<Option<DisplayCacheRequest>, TranscriptError> {
        if let DisplayCacheOperation::Write { bytes, .. } = &operation
            && bytes.len() > MAX_DISPLAY_PAGE_BYTES
        {
            return Err(TranscriptError::InvalidDisplayPage);
        }
        let sender = self
            .sender
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let (reply, result) = mpsc::sync_channel(1);
        if let Some(sender) = sender.as_ref() {
            match sender.try_send(Some(CacheJob::Page {
                terminal,
                operation,
                reply,
            })) {
                Ok(()) => {}
                Err(mpsc::TrySendError::Full(_)) => return Ok(None),
                Err(mpsc::TrySendError::Disconnected(_)) => return Err(TranscriptError::Cancelled),
            }
        } else {
            let _ = reply.send(Ok(None));
        }
        Ok(Some(DisplayCacheRequest(result)))
    }

    #[cfg(test)]
    pub(super) fn stall(&self) -> (mpsc::Receiver<()>, mpsc::SyncSender<()>) {
        let (ready, started) = mpsc::sync_channel(1);
        let (resume, release) = mpsc::sync_channel(1);
        self.sender
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .send(Some(CacheJob::Stall {
                ready,
                resume: release,
            }))
            .unwrap();
        (started, resume)
    }

    pub(super) fn allow(&self, terminal: TerminalId) {
        let mut allowed = self
            .allowed
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        allowed.insert(terminal.value());
        if allowed.len() > 1024
            && let Some(oldest) = allowed.iter().copied().min()
        {
            allowed.remove(&oldest);
        }
    }

    pub(super) fn prune(&self, ids: HashSet<TerminalId>) {
        let mut allowed = self
            .allowed
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        for id in ids {
            allowed.remove(&id.value());
        }
        drop(allowed);
        if let Some(sender) = self
            .sender
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
        {
            let _ = sender.try_send(None);
        }
    }

    pub(super) fn shutdown(&self) {
        self.sender
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
        if let Some(worker) = self
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take()
        {
            let _ = worker.join();
        }
    }
}

impl Drop for DisplayCacheWorker {
    fn drop(&mut self) {
        self.shutdown();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn current_ownership_is_bounded_and_rejects_deleted_terminal_writes() {
        let directory = tempfile::tempdir().unwrap();
        let worker = DisplayCacheWorker::start(directory.path().into(), HashSet::new());
        for id in 1..5000 {
            worker.allow(TerminalId::from_value(id));
        }
        assert!(worker.allowed.lock().unwrap().len() <= 1024);
        let removed = TerminalId::from_value(4999);
        worker.prune(HashSet::from([removed]));
        let write = worker
            .request(
                removed,
                DisplayCacheOperation::Write {
                    key: 3,
                    source_offset: 0,
                    bytes: b"deleted".to_vec(),
                },
            )
            .unwrap()
            .unwrap();
        loop {
            if write.poll().unwrap().is_some() {
                break;
            }
            std::thread::yield_now();
        }
        worker.shutdown();
        assert!(!directory.path().join("4999-3.page").exists());
    }

    #[test]
    fn pages_are_atomic_bounded_validated_and_pruned() {
        let directory = tempfile::tempdir().unwrap();
        let mut cache = DisplayCache::open(directory.path()).unwrap();
        cache.write(7, 9, 20, b"styled rows").unwrap();
        assert_eq!(cache.read(7, 9, 19).unwrap(), None);
        assert_eq!(cache.read(7, 9, 20).unwrap(), Some(b"styled rows".to_vec()));
        assert!(
            cache
                .write(7, 10, 20, &vec![0; MAX_DISPLAY_PAGE_BYTES + 1])
                .is_err()
        );
        drop(cache);
        let mut cache = DisplayCache::open(directory.path()).unwrap();
        assert_eq!(cache.read(7, 9, 20).unwrap(), Some(b"styled rows".to_vec()));
        cache.retain(&std::collections::HashSet::new()).unwrap();
        assert_eq!(cache.read(7, 9, 20).unwrap(), None);
    }
}
