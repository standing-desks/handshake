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

    /// Refresh before each native prompt, even when other agents hold session leases.
    /// The callback is bound by the launcher, never by a hook's untrusted cwd or input.
    pub(crate) fn prompt_context(
        &self,
        folder: PathBuf,
        provider: &'static str,
        native_config: Option<PathBuf>,
    ) -> impl Fn(&AtomicBool, &str) -> Result<Option<String>, super::Error> + Send + Sync + 'static
    {
        let root = self.root.clone();
        let enabled = Arc::clone(&self.enabled);
        let stopping = Arc::clone(&self.stop);
        move |cancelled, _session| {
            let deadline = std::time::Instant::now() + Duration::from_secs(4);
            let active = || {
                !cancelled.load(Ordering::Acquire)
                    && enabled.load(Ordering::SeqCst)
                    && !*stopping
                        .0
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                    && super::feature_enabled()
            };
            if !active() {
                return Ok(None);
            }
            let gate = super::operation_gate(&root);
            let _guard = loop {
                if !active() {
                    return Ok(None);
                }
                if std::time::Instant::now() >= deadline {
                    return Err(super::Error::Busy);
                }
                match gate.try_lock() {
                    Ok(guard) => break guard,
                    Err(std::sync::TryLockError::Poisoned(error)) => break error.into_inner(),
                    Err(std::sync::TryLockError::WouldBlock) => {
                        std::thread::sleep(Duration::from_millis(10));
                    }
                }
            };
            if provider == "codex"
                && !super::native::memory_use_enabled(
                    &folder,
                    native_config.as_deref().ok_or(super::Error::Conflict)?,
                )?
            {
                return Ok(None);
            }
            let mut library = Library::open(&root)?;
            if !active() {
                return Ok(None);
            }
            let project = library.register(&folder)?;
            if !project.enabled {
                return Ok(None);
            }
            let within_deadline = || active() && std::time::Instant::now() < deadline;
            match library.sync_cancellable(&project, &within_deadline) {
                Ok(()) | Err(super::Error::NativeActive) => {}
                Err(error) => return Err(error),
            }
            let context = library.prompt_context(&project, provider)?;
            if std::time::Instant::now() >= deadline {
                return Err(super::Error::Busy);
            }
            Ok(active().then_some(context))
        }
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
    /// Opt-in transport driver for real, persistent native conversations. No model is
    /// invoked by this test; the caller owns native processes, prompts and quota.
    #[test]
    #[ignore = "requires an external native CLI driver and explicit quota authorization"]
    fn native_live_memory_driver() {
        use crate::harness::{claude, codex};
        use crate::terminal::ReplayPosition;
        use std::fs;
        let ready =
            PathBuf::from(std::env::var_os("HANDSHAKE_NATIVE_LIVE_READY").expect("ready path"));
        let stop =
            PathBuf::from(std::env::var_os("HANDSHAKE_NATIVE_LIVE_STOP").expect("stop path"));
        let isolated =
            PathBuf::from(std::env::var_os("XDG_CONFIG_HOME").expect("run via make test-lib"));
        assert!(
            isolated
                .file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("handshake-config-tests.")
        );
        let config = crate::config::Config::user_path().unwrap();
        assert!(config.starts_with(isolated));
        fs::create_dir_all(config.parent().unwrap()).unwrap();
        fs::write(
            config,
            "[feature_flags]\ncross_agent_memory_consolidation = true\n",
        )
        .unwrap();
        let fixture = tempfile::tempdir().unwrap();
        let fixture_root = fixture.path().canonicalize().unwrap();
        let folder = fixture_root.join("project");
        fs::create_dir(&folder).unwrap();
        let root = fixture_root.join("memories");
        let mut library = Library::open(&root).unwrap();
        let project = library.register(&folder).unwrap();
        library.sync(&project).unwrap();
        let codex_lease = library.session_lease(&project, "codex").unwrap();
        let claude_lease = library.session_lease(&project, "claude_code").unwrap();
        drop(library);
        let worker = Worker::start(root, true);
        let (codex_inbox, mut codex_args) =
            codex::prepare(Arc::new(ReplayPosition::default())).unwrap();
        let read = worker.prompt_context(
            folder.clone(),
            "codex",
            Some(project.codex.join("config.toml")),
        );
        codex_inbox
            .set_prompt_context(Arc::new(move |cancel, session| {
                read(cancel, session).map_err(std::io::Error::other)
            }))
            .unwrap();
        codex::append_prompt_context(&mut codex_args, &codex_inbox.prompt_context_command())
            .unwrap();
        let (claude_inbox, mut claude_args) =
            claude::prepare(Arc::new(ReplayPosition::default())).unwrap();
        let read = worker.prompt_context(folder.clone(), "claude_code", None);
        claude_inbox
            .set_prompt_context(Arc::new(move |cancel, session| {
                read(cancel, session).map_err(std::io::Error::other)
            }))
            .unwrap();
        claude::append_prompt_context(&mut claude_args, &claude_inbox.prompt_context_command())
            .unwrap();
        let mut settings: serde_json::Value =
            serde_json::from_str(&claude_args[1].to_string_lossy()).unwrap();
        settings["autoMemoryDirectory"] = serde_json::json!(project.claude);
        claude_args[1] = settings.to_string().into();
        let strings = |args: Vec<std::ffi::OsString>| {
            args.into_iter()
                .map(|s| s.into_string().unwrap())
                .collect::<Vec<_>>()
        };
        fs::write(&ready, serde_json::to_vec_pretty(&serde_json::json!({
            "folder":folder, "project":project.root, "codex_home":project.codex,
            "claude_memory":project.claude, "codex_args":strings(codex_args),
            "claude_args":strings(claude_args), "codex_hook":codex_inbox.prompt_context_command()
        })).unwrap()).unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(600);
        while !stop.exists() {
            assert!(
                std::time::Instant::now() < deadline,
                "native driver timed out"
            );
            std::thread::sleep(Duration::from_millis(100));
        }
        drop((codex_inbox, claude_inbox, worker, codex_lease, claude_lease));
        fs::remove_dir_all(&project.claude).unwrap();
    }
}
