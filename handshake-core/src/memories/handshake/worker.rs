use super::storage::Library;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

/// Owns a quota-free worker; dropping the app wakes it and joins before shutdown.
pub struct Worker {
    root: PathBuf,
    enabled: Arc<AtomicBool>,
    apply: Arc<Mutex<()>>,
    pending: Arc<Mutex<Vec<PathBuf>>>,
    stop: Arc<(Mutex<bool>, Condvar)>,
    thread: Option<JoinHandle<()>>,
}
impl Worker {
    #[must_use]
    pub fn directory(&self) -> &std::path::Path {
        &self.root
    }
    /// Queues folder discovery without blocking app commands on the memory store lock.
    pub fn register(&self, folder: &std::path::Path) {
        if !self.is_enabled() {
            return;
        }
        let mut queue = self
            .pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if !queue.iter().any(|path| path == folder) {
            queue.push(folder.to_owned());
        }
        self.stop.1.notify_all();
    }
    #[must_use]
    pub fn is_enabled(&self) -> bool {
        self.enabled.load(Ordering::SeqCst)
    }

    /// Disabling waits for active consolidation to finish before acknowledging the change.
    /// # Errors
    /// Fails closed if the receiver lock cannot be opened or drained.
    pub fn set_enabled(&self, enabled: bool) -> Result<(), super::Error> {
        self.enabled.store(enabled, Ordering::SeqCst);
        if !enabled {
            let _apply = self
                .apply
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let lock = self.root.join("receiver.lock");
            let file = match std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .open(lock)
            {
                Ok(file) => Some(file),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
                Err(error) => return Err(error.into()),
            };
            if let Some(file) = file {
                use std::os::fd::AsRawFd;
                // SAFETY: holding the existing receiver lock drains any in-flight process too.
                if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
                    return Err(std::io::Error::last_os_error().into());
                }
            }
            self.pending
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .clear();
        }
        self.stop.1.notify_all();
        Ok(())
    }

    #[must_use]
    pub fn start(root: PathBuf, enabled: bool) -> Self {
        let enabled = Arc::new(AtomicBool::new(enabled));
        let active = Arc::clone(&enabled);
        let apply = super::operation_gate(&root);
        let applying = Arc::clone(&apply);
        let stop = Arc::new((Mutex::new(false), Condvar::new()));
        let flag = Arc::clone(&stop);
        let store_root = root.clone();
        let pending = Arc::new(Mutex::new(Vec::<PathBuf>::new()));
        let pending_work = Arc::clone(&pending);
        let thread = std::thread::Builder::new()
            .name("handshake-memories".into())
            .spawn(move || {
                loop {
                    {
                        let _apply = applying
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner);
                        if active.load(Ordering::SeqCst)
                            && super::feature_enabled()
                            && let Ok(mut library) = Library::open(&root)
                            && active.load(Ordering::SeqCst)
                            && super::feature_enabled()
                        {
                            let folders = std::mem::take(
                                &mut *pending_work
                                    .lock()
                                    .unwrap_or_else(std::sync::PoisonError::into_inner),
                            );
                            for folder in folders {
                                if let Err(error) = library.register(&folder) {
                                    tracing::warn!(%error,"memory registration deferred");
                                }
                            }
                            if let Ok(projects) = library.projects() {
                                for project in projects {
                                    if project.enabled && project.folder.is_dir() {
                                        let _ = library.sync(&project);
                                    }
                                }
                            }
                        }
                    }
                    let (lock, wake) = &*flag;
                    let guard = lock
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    if *guard {
                        break;
                    }
                    let (guard, _) = wake
                        .wait_timeout(guard, Duration::from_secs(5))
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    if *guard {
                        break;
                    }
                }
            })
            .ok();
        Self {
            root: store_root,
            enabled,
            apply,
            pending,
            stop,
            thread,
        }
    }
}
impl Drop for Worker {
    fn drop(&mut self) {
        let (lock, wake) = &*self.stop;
        *lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = true;
        wake.notify_all();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn disable_waits_for_explicit_operations_using_the_same_physical_store_gate() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().join("memories");
        let worker = Arc::new(Worker::start(root.clone(), false));
        let gate = super::super::operation_gate(&root);
        assert!(Arc::ptr_eq(&gate, &worker.apply));
        let in_flight = gate.lock().unwrap();
        let (done, completed) = std::sync::mpsc::channel();
        let other = Arc::clone(&worker);
        let task = std::thread::spawn(move || {
            other.set_enabled(false).unwrap();
            done.send(()).unwrap();
        });
        assert!(completed.recv_timeout(Duration::from_millis(30)).is_err());
        drop(in_flight);
        completed.recv_timeout(Duration::from_secs(10)).unwrap();
        task.join().unwrap();
        drop(worker);
        assert!(!root.exists());
    }

    #[test]
    fn disabled_worker_creates_no_store_or_native_profiles() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().join("memories");
        let worker = Worker::start(root.clone(), false);
        worker.register(directory.path());
        assert!(!worker.is_enabled());
        assert!(worker.pending.lock().unwrap().is_empty());
        worker.set_enabled(false).unwrap();
        drop(worker);
        assert!(!root.exists());
    }
}
