use super::storage::Library;
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

/// Owns a quota-free worker; dropping the app wakes it and joins before shutdown.
pub struct Worker {
    root: PathBuf,
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
    pub fn start(root: PathBuf) -> Self {
        let stop = Arc::new((Mutex::new(false), Condvar::new()));
        let flag = Arc::clone(&stop);
        let store_root = root.clone();
        let pending = Arc::new(Mutex::new(Vec::<PathBuf>::new()));
        let pending_work = Arc::clone(&pending);
        let thread = std::thread::Builder::new()
            .name("handshake-memories".into())
            .spawn(move || {
                loop {
                    if let Ok(mut library) = Library::open(&root) {
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
