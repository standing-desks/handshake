//! Twine-owned AMIS memory, background reconciliation and native project profiles.
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
    #[error("The Twine memory store is busy. It will retry automatically.")]
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

/// Resolves the standard store; explicit test/app data overrides remain isolated.
#[must_use]
pub fn directory() -> PathBuf {
    if let Some(path) = std::env::var_os("TWINE_MEMORY_DIRECTORY") {
        return path.into();
    }
    if let Some(path) = std::env::var_os("TWINE_DATA_DIRECTORY") {
        return PathBuf::from(path).join("memories");
    }
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default();
    home.join("Library/Application Support/Twine/memories")
}

/// Executes an explicit status or policy operation through the same core as the worker.
/// # Errors
/// Rejects unsafe folders, malformed AMIS records and conflicting native edits.
pub fn execute(request: &Request) -> Result<Snapshot, Error> {
    let root = std::env::var_os("TWINE_MEMORY_DIRECTORY")
        .map(PathBuf::from)
        .or_else(|| request.data_directory.as_ref().map(|p| p.join("memories")))
        .unwrap_or_else(directory);
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
