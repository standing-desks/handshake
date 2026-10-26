//! Handshake-owned AMIS memory, background reconciliation and native project profiles.
mod contract;
mod native;
mod storage;
mod worker;

pub use worker::Worker;

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum Error {
    #[error("Choose an existing absolute project folder.")]
    InvalidFolder,
    #[error("The Handshake memory store is busy. It will retry automatically.")]
    Busy,
    #[error("Native memory delivery is waiting for the active agent session to finish.")]
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
    execute_at(&root, request)
}

pub(crate) fn execute_at(root: &Path, request: &Request) -> Result<Snapshot, Error> {
    let mut library = storage::Library::open(root)?;
    let project = library.register(&request.folder)?;
    match &request.action {
        Action::SetEnabled { enabled } => library.set_enabled(&project, *enabled)?,
        Action::Withdraw { id } => library.withdraw(&project, id)?,
        Action::Status | Action::Sync => {}
    }
    if !matches!(request.action, Action::Status) {
        match library.sync(&project) {
            Ok(()) | Err(Error::NativeActive) => {}
            Err(error) => return Err(error),
        }
    }
    library.snapshot(&project)
}

/// Each profile contains only this project's native memory; global credentials/settings are reused.
/// # Errors
/// Returns errors rather than silently starting an unprepared memory profile.
pub(crate) fn launch_environment(
    root: &Path,
    folder: &Path,
    provider: &str,
) -> Result<(Vec<(String, String)>, std::fs::File), Error> {
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
    let project = library.register(folder)?;
    // Pausing synchronization retains physical project isolation and existing native memories.
    if let Err(error) = library.sync(&project) {
        tracing::warn!(%error,"memory reconciliation held before agent start");
    }
    let lease = library.session_lease(&project, provider)?;
    Ok((native::environment(&project), lease))
}

#[cfg(test)]
mod tests {
    use super::*;

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
