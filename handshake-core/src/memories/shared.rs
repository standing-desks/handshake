//! Experimental folder-bound shared memory. Policy and history stay outside the agent inbox.
//! This is a local serving implementation, not an AMIS wire format or conformance claim.
mod exchange;
mod storage;

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum SharedMemoryError {
    #[error("Enable cross-agent memory consolidation in Settings > Experimental first.")]
    FeatureDisabled,
    #[error("Choose an existing absolute folder path.")]
    InvalidFolder,
    #[error("Enable automatic sharing for this folder first.")]
    Disabled,
    #[error("Use nonempty memory text without unsupported control characters.")]
    InvalidText,
    #[error("Only a Codex or Claude Code durable memory belonging to this folder can be imported.")]
    InvalidSource,
    #[error("This memory is no longer available. Refresh the shared library.")]
    Missing,
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Database(#[from] rusqlite::Error),
    #[error(transparent)]
    Memory(#[from] super::MemoryError),
}

#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "operation", rename_all = "camelCase", deny_unknown_fields)]
pub enum SharedOperation {
    Refresh,
    SetEnabled { enabled: bool },
    Add { text: String },
    Import { source_id: String },
    Withdraw { id: String },
    Read { id: String },
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SharedRequest {
    pub data_directory: PathBuf,
    pub folder: PathBuf,
    pub action: SharedOperation,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SharedSnapshot {
    pub enabled: bool,
    pub delivery_ready: bool,
    pub folder: PathBuf,
    pub inbox: PathBuf,
    pub catalog_path: PathBuf,
    pub notes: Vec<SharedNote>,
    pub detail: Option<SharedNoteDetail>,
    pub diagnostics: Vec<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SharedNote {
    pub id: String,
    pub title: String,
    pub source: String,
    pub digest: String,
    pub status: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SharedNoteDetail {
    pub id: String,
    pub digest: String,
    pub text: String,
}

/// Applies receiver policy, accepts new inbox files, and rebuilds the serving view.
///
/// # Errors
/// Rejects invalid paths, unsupported sources, disabled writes and unavailable storage.
pub fn execute(request: &SharedRequest) -> Result<SharedSnapshot, SharedMemoryError> {
    if !crate::config::Config::load_user()
        .experimental
        .cross_agent_memory_consolidation
    {
        return Err(SharedMemoryError::FeatureDisabled);
    }
    if !request.folder.is_absolute() || !request.folder.is_dir() {
        return Err(SharedMemoryError::InvalidFolder);
    }
    let folder = request.folder.canonicalize()?;
    let root = library_root(&request.data_directory, &folder)?;
    storage::execute(&root, &folder, &request.action)
}

fn library_root(data: &Path, folder: &Path) -> Result<PathBuf, SharedMemoryError> {
    if !data.is_absolute() {
        return Err(SharedMemoryError::InvalidFolder);
    }
    Ok(data
        .join("shared-memory")
        .join(digest(folder.as_os_str().as_encoded_bytes())))
}

fn digest(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    Sha256::digest(bytes)
        .iter()
        .fold(String::with_capacity(64), |mut hex, byte| {
            let _ = write!(hex, "{byte:02x}");
            hex
        })
}

fn import_text(folder: &Path, source_id: &str) -> Result<(String, String), SharedMemoryError> {
    let memory = super::read(&super::MemoryRequest {
        folder: Some(folder.into()),
        source_id: Some(source_id.into()),
        examples_root: None,
    })?;
    let default_claude_group = format!(
        "Claude folder: {}",
        super::locations::claude_key(&super::locations::repository_root(folder))
    );
    if memory.source.group.starts_with("Claude folder: ")
        && memory.source.group != default_claude_group
    {
        return Err(SharedMemoryError::InvalidSource);
    }
    if memory.source.scope != super::MemoryScope::Folder
        || memory.source.group == "Claude configured memory directory"
        || !matches!(
            memory.source.harness,
            super::MemoryHarness::Codex | super::MemoryHarness::ClaudeCode
        )
        || !matches!(
            memory.source.kind,
            super::MemoryKind::Durable | super::MemoryKind::AgentMemory
        )
        || memory.source.example
    {
        return Err(SharedMemoryError::InvalidSource);
    }
    Ok((
        memory.text.ok_or(SharedMemoryError::InvalidSource)?,
        memory.source.location,
    ))
}
