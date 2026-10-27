//! Handshake-owned AMIS memory, background reconciliation and native project profiles.
mod contract;
mod gate;
use gate::operation_gate;
mod native;
mod storage;
mod worker;

pub use worker::Worker;

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum Error {
    #[error("Enable cross-agent memory consolidation in Settings > Feature flags first.")]
    Disabled,
    #[error("Choose an existing absolute project folder.")]
    InvalidFolder,
    #[error("The Handshake memory store is busy. It will retry automatically.")]
    Busy,
    #[error(
        "A native source or startup-file replacement is waiting for an active agent to finish. Current shared memories can still refresh at the next prompt."
    )]
    NativeActive,
    #[error("The AMIS memory document is invalid: {0}")]
    Contract(String),
    #[error("A native memory file changed. Its edit was preserved; reconciliation is held.")]
    Conflict,
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Sql(#[from] rusqlite::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    pub folder: PathBuf,
    #[serde(default)]
    pub data_directory: Option<PathBuf>,
    pub action: Action,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase", deny_unknown_fields)]
pub enum Action {
    Status,
    Sync,
    SetEnabled { enabled: bool },
    Withdraw { id: String },
    ReadArchive { id: String },
    Restore { id: String },
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub enabled: bool,
    pub folder: PathBuf,
    pub store_path: PathBuf,
    pub amis_path: PathBuf,
    pub claude_path: PathBuf,
    pub codex_path: PathBuf,
    pub records: Vec<Summary>,
    pub archived_records: Vec<Summary>,
    pub archive_detail: Option<ArchiveDetail>,
    pub status: String,
    pub message: String,
    pub last_sync: Option<String>,
    pub model_calls: u64,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Summary {
    pub id: String,
    pub title: String,
    pub sources: usize,
    pub preview: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ArchiveDetail {
    pub id: String,
    pub title: String,
    pub text: String,
}

fn override_path(
    current: Option<std::ffi::OsString>,
    legacy: Option<std::ffi::OsString>,
) -> Option<PathBuf> {
    current.or(legacy).map(PathBuf::from)
}

fn memory_override() -> Option<PathBuf> {
    override_path(
        std::env::var_os("HANDSHAKE_MEMORY_DIRECTORY"),
        std::env::var_os("TWINE_MEMORY_DIRECTORY"),
    )
}

fn data_override() -> Option<PathBuf> {
    override_path(
        std::env::var_os("HANDSHAKE_DATA_DIRECTORY"),
        std::env::var_os("TWINE_DATA_DIRECTORY"),
    )
}

fn home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default()
}

fn standard_directory(home: &Path) -> PathBuf {
    let current = home.join("Library/Application Support/Handshake/memories");
    let legacy = home.join("Library/Application Support/Twine/memories");
    // Absolute native bindings and sealed receipts belong to this physical library.
    // Retain an existing legacy library in place; never clone its live databases or native homes.
    if !current.exists() && legacy.join("bindings.sqlite").is_file() {
        legacy
    } else {
        current
    }
}

/// Resolves the standard store; explicit test/app data overrides remain isolated.
#[must_use]
pub fn directory() -> PathBuf {
    memory_override()
        .or_else(|| data_override().map(|p| p.join("memories")))
        .unwrap_or_else(|| standard_directory(&home()))
}

pub(crate) fn store_directory(data: &Path) -> PathBuf {
    memory_override().unwrap_or_else(|| {
        if data_override().is_none() && data == home().join("Library/Application Support/Handshake")
        {
            standard_directory(&home())
        } else {
            data.join("memories")
        }
    })
}

/// Executes an explicit status or policy operation through the same core as the worker.
/// # Errors
/// Rejects unsafe folders, malformed AMIS records and conflicting native edits.
pub fn execute(request: &Request) -> Result<Snapshot, Error> {
    let root = request
        .data_directory
        .as_deref()
        .map_or_else(directory, store_directory);
    execute_guarded(&root, request, || Ok(feature_enabled()))
}

pub(crate) fn feature_enabled() -> bool {
    crate::config::Config::load_user()
        .feature_flags
        .cross_agent_memory_consolidation
}

pub(crate) fn execute_guarded(
    root: &Path,
    request: &Request,
    enabled: impl Fn() -> Result<bool, Error>,
) -> Result<Snapshot, Error> {
    let gate = operation_gate(root);
    let _guard = gate
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if !enabled()? {
        return Err(Error::Disabled);
    }
    let mut library = storage::Library::open(root)?;
    // The receiver lock also serializes other processes; recheck after acquiring it.
    if !enabled()? {
        return Err(Error::Disabled);
    }
    execute_library(&mut library, request)
}

fn execute_library(library: &mut storage::Library, request: &Request) -> Result<Snapshot, Error> {
    let project = library.register_metadata(&request.folder)?;
    match &request.action {
        Action::SetEnabled { enabled } => library.set_enabled(&project, *enabled)?,
        Action::Withdraw { id } => library.withdraw(&project, id)?,
        Action::Restore { id } => library.restore(&project, id)?,
        Action::Status | Action::Sync | Action::ReadArchive { .. } => {}
    }
    if !matches!(request.action, Action::Status | Action::ReadArchive { .. }) {
        match library.sync(&project) {
            Ok(()) | Err(Error::NativeActive) => {}
            Err(error) => return Err(error),
        }
    }
    let mut snapshot = library.snapshot(&project)?;
    if let Action::ReadArchive { id } = &request.action {
        snapshot.archive_detail = Some(library.read_archive(&project, id)?);
    }
    Ok(snapshot)
}

/// Each profile contains only this project's native memory; global credentials/settings are reused.
/// # Errors
/// Returns errors rather than silently starting an unprepared memory profile.
pub(crate) fn launch_environment(
    root: &Path,
    folder: &Path,
    provider: &str,
    enabled: impl Fn() -> bool,
) -> Result<(Vec<(String, String)>, std::fs::File), Error> {
    let gate = operation_gate(root);
    let _guard = gate
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if !enabled() {
        return Err(Error::Disabled);
    }
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    let mut library = loop {
        match storage::Library::open(root) {
            Ok(library) => break library,
            Err(Error::Busy) if std::time::Instant::now() < deadline => {
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            Err(error) => return Err(error),
        }
    };
    if !enabled() {
        return Err(Error::Disabled);
    }
    let project = library.register(folder)?;
    // Pausing synchronization retains physical project isolation and existing native memories.
    if let Err(error) = library.sync(&project) {
        tracing::warn!(%error,"memory reconciliation held before agent start");
    }
    let lease = library.session_lease(&project, provider)?;
    Ok((native::environment(&project), lease))
}

pub(crate) fn contains_session(root: &Path, session: &str) -> bool {
    let Ok(entries) = std::fs::read_dir(root) else {
        return false;
    };
    entries.flatten().any(|entry| {
        entry.file_type().is_ok_and(|kind| {
            if kind.is_dir() {
                contains_session(&entry.path(), session)
            } else {
                kind.is_file() && entry.file_name().to_string_lossy().contains(session)
            }
        })
    })
}

/// Restores only a known saved Codex home while the feature is off. No registration or sync occurs.
pub(crate) fn resume_codex_environment(
    root: &Path,
    folder: &Path,
    session: &str,
) -> Result<Option<(PathBuf, std::fs::File)>, Error> {
    use rusqlite::OptionalExtension;
    use std::os::fd::AsRawFd;
    let database = root.join("bindings.sqlite");
    if !database.is_file() {
        return Ok(None);
    }
    native::safe_path(&database)?;
    let connection = rusqlite::Connection::open_with_flags(
        database,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )?;
    let folder = folder.canonicalize()?;
    let id: Option<String> = connection
        .query_row(
            "SELECT id FROM projects WHERE folder=?",
            [folder.to_string_lossy().as_ref()],
            |r| r.get(0),
        )
        .optional()?;
    let Some(id) = id else {
        return Ok(None);
    };
    uuid::Uuid::parse_str(&id).map_err(|_| Error::Conflict)?;
    let project = root.join("projects").join(id);
    let home = project.join("native/codex");
    native::safe_path(&home.join("sessions"))?;
    native::safe_path(&project.join("native-sessions-codex.lock"))?;
    if !contains_session(&home.join("sessions"), session) {
        return Ok(None);
    }
    let lease = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(project.join("native-sessions-codex.lock"))?;
    // SAFETY: the owned descriptor borrows an existing native-session lock, never a memory body.
    if unsafe { libc::flock(lease.as_raw_fd(), libc::LOCK_SH | libc::LOCK_NB) } != 0 {
        return Err(Error::NativeActive);
    }
    Ok(Some((home, lease)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disabled_core_request_does_not_register_or_create_memory_storage() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("never-created");
        let request = Request {
            folder: temp.path().to_owned(),
            data_directory: None,
            action: Action::Sync,
        };
        assert!(matches!(
            execute_guarded(&root, &request, || Ok(false)),
            Err(Error::Disabled)
        ));
        assert!(!root.exists());
    }

    #[test]
    fn feature_off_resume_uses_only_the_existing_bound_home_and_rejects_symlinks() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let id = uuid::Uuid::new_v4().to_string();
        let session = uuid::Uuid::new_v4().to_string();
        let database = rusqlite::Connection::open(root.join("bindings.sqlite")).unwrap();
        database
            .execute_batch("CREATE TABLE projects(id TEXT, folder TEXT);")
            .unwrap();
        database
            .execute(
                "INSERT INTO projects VALUES(?,?)",
                rusqlite::params![id, root.to_string_lossy()],
            )
            .unwrap();
        drop(database);
        let project = root.join("projects").join(&id);
        let home = project.join("native/codex");
        std::fs::create_dir_all(home.join("sessions/day")).unwrap();
        std::fs::write(
            home.join("sessions/day")
                .join(format!("rollout-{session}.jsonl")),
            "native rollout",
        )
        .unwrap();
        std::fs::write(project.join("native-sessions-codex.lock"), "").unwrap();
        let before = std::fs::read(root.join("bindings.sqlite")).unwrap();
        let resumed = resume_codex_environment(&root, &root, &session)
            .unwrap()
            .unwrap();
        assert_eq!(resumed.0, home);
        drop(resumed);
        assert_eq!(before, std::fs::read(root.join("bindings.sqlite")).unwrap());
        assert!(
            resume_codex_environment(&root, &root, "not-saved")
                .unwrap()
                .is_none()
        );
        let outside = root.join("outside");
        std::fs::rename(&home, &outside).unwrap();
        std::os::unix::fs::symlink(&outside, &home).unwrap();
        assert!(matches!(
            resume_codex_environment(&root, &root, &session),
            Err(Error::Conflict)
        ));
    }

    #[test]
    fn existing_native_bindings_remain_in_their_original_library() {
        let home = tempfile::tempdir().unwrap();
        let current = home
            .path()
            .join("Library/Application Support/Handshake/memories");
        let legacy = home
            .path()
            .join("Library/Application Support/Twine/memories");
        assert_eq!(standard_directory(home.path()), current);
        std::fs::create_dir_all(&legacy).unwrap();
        std::fs::write(legacy.join("bindings.sqlite"), b"existing receiver").unwrap();
        assert_eq!(standard_directory(home.path()), legacy);
        std::fs::create_dir_all(&current).unwrap();
        assert_eq!(
            standard_directory(home.path()),
            current,
            "an established Handshake destination wins"
        );
    }

    #[test]
    fn handshake_memory_override_wins_and_twine_remains_a_fallback() {
        use std::ffi::OsString;
        let old = Some(OsString::from("/legacy/memories"));
        assert_eq!(
            override_path(Some(OsString::from("/current/memories")), old.clone()),
            Some(PathBuf::from("/current/memories"))
        );
        assert_eq!(
            override_path(None, old.clone()),
            Some(PathBuf::from("/legacy/memories"))
        );
        assert_eq!(
            override_path(Some(OsString::new()), old),
            Some(PathBuf::new()),
            "an invalid explicit primary must not silently fall back"
        );
    }
}
