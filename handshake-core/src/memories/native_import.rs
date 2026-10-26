//! Folder-scoped access to Codex's native Claude memory importer.
//! Handshake stores no memory bodies and never writes Codex's generated memory files.

use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::fd::OwnedFd;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use thiserror::Error;

use super::MemoryRequest;
use super::locations::{Locations, claude_key};
use crate::harness::{HarnessId, LocatedHarness, LoginPath, locate_in};
use crate::process::CommandChild;

const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);
const IMPORT_TIMEOUT: Duration = Duration::from_secs(45);
// This bounds the native protocol, not memory contents or the number of memories.
const MAX_PROTOCOL_BYTES: u64 = 8 * 1024 * 1024;

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NativeImportRequest {
    pub folder: PathBuf,
    pub action: NativeImportAction,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum NativeImportAction {
    Status,
    Import,
    RemoveImported,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeImportSnapshot {
    pub folder: PathBuf,
    pub claude_path: PathBuf,
    pub codex_path: PathBuf,
    pub source_count: usize,
    pub can_import: bool,
    pub status: String,
    pub message: String,
    pub import_id: Option<String>,
}

#[derive(Debug, Error)]
pub enum NativeImportError {
    #[error("Enable cross-agent memory consolidation in Settings > Feature flags first.")]
    Disabled,
    #[error("Native memory import requires an existing absolute folder path.")]
    InvalidFolder,
    #[error("Codex returned an unsupported native memory response.")]
    InvalidResponse,
    #[error(
        "Codex could not complete the native memory request. Its import API may be unavailable."
    )]
    NativeRequest,
    #[error(
        "Codex could not start the native memory importer. The installed CLI must support --enable external_agent_memory_import and app-server."
    )]
    ImporterUnavailable,
    #[error(transparent)]
    Io(#[from] io::Error),
}

/// Inspects native memory or explicitly invokes Codex's own memory importer.
///
/// # Errors
/// Returns an error for invalid folders, protocol failures, or unavailable local files.
pub fn execute(request: &NativeImportRequest) -> Result<NativeImportSnapshot, NativeImportError> {
    if !crate::config::Config::load_user()
        .feature_flags
        .cross_agent_memory_consolidation
    {
        return Err(NativeImportError::Disabled);
    }
    if !request.folder.is_absolute() || !request.folder.is_dir() {
        return Err(NativeImportError::InvalidFolder);
    }
    let folder = request.folder.canonicalize()?;
    let locations = Locations::live(&MemoryRequest {
        folder: Some(folder.clone()),
        ..MemoryRequest::default()
    });
    let mut snapshot = snapshot(&folder, &locations)?;
    if !supported_source(&locations, &mut snapshot)
        || (snapshot.source_count == 0
            && !imported_scope_matches(&snapshot.codex_path, &snapshot.folder)?)
    {
        return Ok(snapshot);
    }
    let shell = std::env::var_os("SHELL").map_or_else(|| PathBuf::from("/bin/zsh"), PathBuf::from);
    let login = LoginPath::spawn(shell).get();
    let located = match locate_in(
        HarnessId::Codex.definition(),
        login.as_deref(),
        std::env::var_os("PATH").as_deref(),
    ) {
        Ok(located) => located,
        Err(error) => {
            snapshot.message = error.to_string();
            return Ok(snapshot);
        }
    };
    execute_located(request.action, snapshot, &located)
}

fn snapshot(
    folder: &Path,
    locations: &Locations,
) -> Result<NativeImportSnapshot, NativeImportError> {
    let key = claude_key(folder);
    let claude_path = locations.claude.join("projects").join(&key).join("memory");
    let source_count = markdown_count(&claude_path)?;
    Ok(NativeImportSnapshot {
        folder: folder.to_owned(),
        claude_path,
        codex_path: locations.codex.join("memories/extensions/external_agent_import/resources").join(key),
        source_count,
        can_import: false,
        status: "unavailable".into(),
        message: "No native Claude memories were found for this folder. Claude's memory system must create them first.".into(),
        import_id: None,
    })
}

fn markdown_count(root: &Path) -> io::Result<usize> {
    match fs::symlink_metadata(root) {
        Ok(metadata) if metadata.file_type().is_dir() => {}
        Ok(_) => return Ok(0),
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(0),
        Err(error) => return Err(error),
    }
    let mut count = 0;
    for entry in fs::read_dir(root)? {
        let entry = entry?;
        let kind = entry.file_type()?;
        if kind.is_dir() {
            count += markdown_count(&entry.path())?;
        } else if kind.is_file()
            && entry
                .path()
                .extension()
                .is_some_and(|extension| extension.eq_ignore_ascii_case("md"))
        {
            count += 1;
        }
    }
    Ok(count)
}

fn supported_source(locations: &Locations, snapshot: &mut NativeImportSnapshot) -> bool {
    let default_claude = locations.home.join(".claude");
    if locations
        .claude
        .canonicalize()
        .unwrap_or_else(|_| locations.claude.clone())
        != default_claude.canonicalize().unwrap_or(default_claude)
        || std::env::var_os("CLAUDE_CODE_PROJECT_DIR_NAME").is_some()
    {
        snapshot.message = "This Codex importer supports only the default Claude project memory location; a Claude directory override is active.".into();
        return false;
    }
    if locations
        .claude_settings
        .get("autoMemoryDirectory")
        .is_some_and(|value| !value.is_null())
    {
        snapshot.message = "Claude has an autoMemoryDirectory override. Codex's native importer does not support that location.".into();
        return false;
    }
    if locations
        .claude_settings
        .get("autoMemoryEnabled")
        .and_then(Value::as_bool)
        == Some(false)
    {
        snapshot.message =
            "Claude auto memory is disabled. Enable its native memory system before importing."
                .into();
        return false;
    }
    true
}

fn execute_located(
    action: NativeImportAction,
    mut snapshot: NativeImportSnapshot,
    located: &LocatedHarness,
) -> Result<NativeImportSnapshot, NativeImportError> {
    let mut client = NativeClient::start(located, &snapshot.folder)?;
    let config = client.request(
        "config/read",
        &json!({"includeLayers": false, "cwd": snapshot.folder}),
    )?;
    let config = config
        .get("config")
        .filter(|value| value.is_object())
        .ok_or(NativeImportError::InvalidResponse)?;
    if !supported_codex(config, &mut snapshot) {
        return Ok(snapshot);
    }
    let detection = client.request(
        "externalAgentConfig/detect",
        &json!({"includeHome": true, "cwds": [snapshot.folder]}),
    )?;
    let key = claude_key(&snapshot.folder);
    let items = detection
        .get("items")
        .and_then(Value::as_array)
        .ok_or(NativeImportError::InvalidResponse)?;
    if !refresh_scope(&mut snapshot)? {
        return Ok(snapshot);
    }
    let selected = items.iter().find(|item| {
        item.get("itemType").and_then(Value::as_str) == Some("MEMORY")
            && item
                .pointer("/details/memory")
                .and_then(Value::as_array)
                .is_some_and(|keys| keys.iter().any(|value| value.as_str() == Some(&key)))
    });
    let Some(selected) = selected else {
        if snapshot.source_count == 0 {
            snapshot.message = "Claude has no memory files here, but Codex still has imported copies and did not offer native cleanup. Refresh native status or inspect Codex's import history.".into();
        } else if imported_scope_matches(&snapshot.codex_path, &snapshot.folder)? {
            snapshot.status = "current".into();
            snapshot.message = "Imported files are up to date. Codex may still be consolidating them or waiting for account capacity. Start a fresh conversation after consolidation finishes.".into();
        } else {
            snapshot.message = "Codex could not identify this native Claude memory project. Open a normal Claude session in this exact folder so the importer can verify its scope.".into();
        }
        return Ok(snapshot);
    };
    snapshot.can_import = true;
    snapshot.status = "ready".into();
    snapshot.message = if snapshot.source_count == 0 {
        "Claude has no memory files here. Codex can remove this folder's imported copies through its native importer; consolidated memory updates afterward."
    } else {
        "Import this folder's Claude memories into Codex. Codex consolidates them during conversations when account capacity allows."
    }.into();
    if action == NativeImportAction::Status {
        return Ok(snapshot);
    }
    if !refresh_scope(&mut snapshot)? {
        return Ok(snapshot);
    }
    if (action == NativeImportAction::RemoveImported) != (snapshot.source_count == 0) {
        snapshot.status = "unavailable".into();
        snapshot.can_import = false;
        snapshot.message =
            "Claude memories changed. Refresh before importing or removing copies.".into();
        return Ok(snapshot);
    }
    // Build a memory-only item from detected metadata. Never forward other migration kinds.
    let item = json!({
        "itemType": "MEMORY", "description": selected.get("description").and_then(Value::as_str).unwrap_or("Import native folder memories"),
        "cwd": null, "details": {"plugins": [], "skills": [], "sessions": [], "mcpServers": [], "hooks": [], "subagents": [], "commands": [], "memory": [key]}
    });
    let accepted = client.request(
        "externalAgentConfig/import",
        &json!({"migrationItems": [item], "source": "twine", "providerId": "claude-code"}),
    )?;
    let id = accepted
        .get("importId")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .ok_or(NativeImportError::InvalidResponse)?
        .to_owned();
    snapshot.import_id = Some(id.clone());
    snapshot.can_import = false;
    let completed = client.import_completion(&id);
    finish_import(snapshot, &key, completed)
}

fn supported_codex(config: &Value, snapshot: &mut NativeImportSnapshot) -> bool {
    if config
        .pointer("/memories/version")
        .and_then(Value::as_str)
        .unwrap_or("v1")
        != "v1"
    {
        snapshot.message = "Codex is using memories v2, but its Claude importer writes v1. Native import is unavailable for this configuration.".into();
        return false;
    }
    if config
        .pointer("/features/memories")
        .and_then(Value::as_bool)
        != Some(true)
        || config
            .pointer("/features/external_agent_memory_import")
            .and_then(Value::as_bool)
            != Some(true)
        || config
            .pointer("/memories/use_memories")
            .and_then(Value::as_bool)
            == Some(false)
    {
        snapshot.message = "Codex native memories or its experimental native importer are disabled for this folder. Enable native memories and use a Codex version supporting external_agent_memory_import.".into();
        return false;
    }
    true
}

fn refresh_scope(snapshot: &mut NativeImportSnapshot) -> io::Result<bool> {
    let before = markdown_count(&snapshot.claude_path)?;
    let matches = if before == 0 {
        imported_scope_matches(&snapshot.codex_path, &snapshot.folder)?
    } else {
        source_scope_matches(&snapshot.claude_path, &snapshot.folder)?
    };
    snapshot.source_count = markdown_count(&snapshot.claude_path)?;
    if (before == 0) != (snapshot.source_count == 0) || !matches {
        snapshot.can_import = false;
        snapshot.status = "unavailable".into();
        snapshot.message = "Native memory changed or its metadata does not establish this exact folder. Refresh before importing or removing copies.".into();
        return Ok(false);
    }
    Ok(true)
}

fn finish_import(
    mut snapshot: NativeImportSnapshot,
    key: &str,
    completed: Result<Value, NativeImportError>,
) -> Result<NativeImportSnapshot, NativeImportError> {
    if let Ok(completed) = completed {
        let results = completed
            .get("itemTypeResults")
            .and_then(Value::as_array)
            .ok_or(NativeImportError::InvalidResponse)?;
        let success = results.iter().any(|result| {
            result.get("itemType").and_then(Value::as_str) == Some("MEMORY")
                && result
                    .get("failures")
                    .and_then(Value::as_array)
                    .is_some_and(Vec::is_empty)
                && result
                    .get("successes")
                    .and_then(Value::as_array)
                    .is_some_and(|values| {
                        values
                            .iter()
                            .any(|value| value.get("source").and_then(Value::as_str) == Some(key))
                    })
        });
        if success {
            snapshot.status = "imported".into();
            snapshot.message = if snapshot.source_count == 0 {
                "Codex removed this folder's imported memory copies. Native consolidation is pending and may wait for account capacity; older information can remain until it finishes."
            } else {
                "Imported into Codex. Native consolidation is pending. It runs during Codex conversations and may pause when account capacity is low. After it finishes, start a fresh conversation."
            }.into();
            if snapshot.source_count == 0
                && !fs::symlink_metadata(&snapshot.codex_path)
                    .is_err_and(|error| error.kind() == io::ErrorKind::NotFound)
            {
                snapshot.status = "unconfirmed".into();
                snapshot.message = "Codex completed a native operation, but removal of the imported copies was not verified. Claude memories may have changed; refresh native status before retrying.".into();
            }
        } else {
            snapshot.status = "unconfirmed".into();
            snapshot.message = "Codex did not confirm successful import of this folder. Inspect its native import history before retrying.".into();
        }
    } else {
        snapshot.status = "unconfirmed".into();
        snapshot.message = "Codex accepted the native import but completion was not confirmed before the connection closed. Refresh native status and inspect Codex's import history before retrying.".into();
    }
    Ok(snapshot)
}

fn source_scope_matches(memory: &Path, folder: &Path) -> io::Result<bool> {
    let Some(project) = memory.parent() else {
        return Ok(false);
    };
    let mut found = false;
    let deadline = Instant::now() + REQUEST_TIMEOUT;
    for entry in fs::read_dir(project)? {
        let entry = entry?;
        if !entry.file_type()?.is_file()
            || entry
                .path()
                .extension()
                .is_none_or(|extension| extension != "jsonl")
        {
            continue;
        }
        let mut reader = BufReader::new(fs::File::open(entry.path())?);
        loop {
            if Instant::now() >= deadline {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "Native Claude scope verification timed out.",
                ));
            }
            let mut line = Vec::new();
            let count = reader
                .by_ref()
                .take(MAX_PROTOCOL_BYTES + 1)
                .read_until(b'\n', &mut line)?;
            if count == 0 {
                break;
            }
            if count as u64 > MAX_PROTOCOL_BYTES {
                return Ok(false);
            }
            let Ok(value) = serde_json::from_slice::<Value>(&line) else {
                continue;
            };
            if let Some(cwd) = value.get("cwd").and_then(Value::as_str) {
                if Path::new(cwd).canonicalize().ok().as_deref() != Some(folder) {
                    return Ok(false);
                }
                found = true;
                // Codex scopes a native session to its first cwd. Later records can
                // legitimately reflect commands run in other directories.
                break;
            }
        }
    }
    Ok(found)
}

fn imported_scope_matches(memory: &Path, folder: &Path) -> io::Result<bool> {
    let scope = memory.join("scope.json");
    match fs::symlink_metadata(&scope) {
        Ok(metadata) if metadata.file_type().is_file() => {}
        Ok(_) => return Ok(false),
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error),
    }
    let mut bytes = Vec::new();
    fs::File::open(scope)?
        .take(MAX_PROTOCOL_BYTES + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_PROTOCOL_BYTES {
        return Ok(false);
    }
    let Ok(value) = serde_json::from_slice::<Value>(&bytes) else {
        return Ok(false);
    };
    Ok(value
        .get("cwd")
        .and_then(Value::as_str)
        .is_some_and(|cwd| Path::new(cwd).canonicalize().ok().as_deref() == Some(folder)))
}

fn read_message(
    reader: &mut BufReader<UnixStream>,
    remaining: &mut u64,
    deadline: Instant,
) -> Result<Value, NativeImportError> {
    let mut bytes = Vec::new();
    loop {
        let timeout = deadline
            .checked_duration_since(Instant::now())
            .filter(|timeout| !timeout.is_zero())
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::TimedOut,
                    "Codex native memory request timed out.",
                )
            })?;
        reader.get_ref().set_read_timeout(Some(timeout))?;
        let buffer = reader.fill_buf()?;
        let newline = buffer.iter().position(|byte| *byte == b'\n');
        let count = newline.map_or(buffer.len(), |index| index + 1);
        if count == 0 || count as u64 > *remaining {
            return Err(NativeImportError::InvalidResponse);
        }
        bytes.extend_from_slice(&buffer[..count]);
        *remaining -= count as u64;
        reader.consume(count);
        if newline.is_some() {
            return serde_json::from_slice(&bytes).map_err(|_| NativeImportError::InvalidResponse);
        }
    }
}

struct NativeClient {
    _child: CommandChild,
    socket: UnixStream,
    reader: BufReader<UnixStream>,
    next_id: u64,
    remaining: u64,
    completions: Vec<Value>,
}

impl NativeClient {
    fn start(located: &LocatedHarness, folder: &Path) -> Result<Self, NativeImportError> {
        let (socket, remote) = UnixStream::pair()?;
        socket.set_write_timeout(Some(REQUEST_TIMEOUT))?;
        let input: OwnedFd = remote.try_clone()?.into();
        let output: OwnedFd = remote.into();
        let mut command = Command::new(&located.program);
        command
            // Opt into Codex's native importer for this child only. Never edit user config.
            .args(["--enable", "external_agent_memory_import"])
            .arg("app-server")
            .current_dir(folder)
            .env("PATH", &located.path)
            .stdin(Stdio::from(input))
            .stdout(Stdio::from(output))
            .stderr(Stdio::null());
        let child = CommandChild::spawn(&mut command)?;
        let mut client = Self {
            _child: child,
            reader: BufReader::new(socket.try_clone()?),
            socket,
            next_id: 1,
            remaining: MAX_PROTOCOL_BYTES,
            completions: Vec::new(),
        };
        client
            .request(
                "initialize",
                &json!({"clientInfo": {"name": "twine", "version": env!("CARGO_PKG_VERSION")}}),
            )
            .map_err(|_| NativeImportError::ImporterUnavailable)?;
        client.send(&json!({"method": "initialized"}))?;
        Ok(client)
    }

    fn send(&mut self, value: &Value) -> io::Result<()> {
        serde_json::to_writer(&mut self.socket, value)?;
        self.socket.write_all(b"\n")
    }

    fn read(&mut self, deadline: Instant) -> Result<Value, NativeImportError> {
        read_message(&mut self.reader, &mut self.remaining, deadline)
    }

    fn request(&mut self, method: &str, params: &Value) -> Result<Value, NativeImportError> {
        let id = self.next_id;
        self.next_id += 1;
        self.send(&json!({"id": id, "method": method, "params": params}))?;
        let deadline = Instant::now() + REQUEST_TIMEOUT;
        loop {
            let value = self.read(deadline)?;
            if value.get("id").and_then(Value::as_u64) == Some(id) {
                return value
                    .get("result")
                    .cloned()
                    .ok_or(NativeImportError::NativeRequest);
            }
            if value.get("method").and_then(Value::as_str)
                == Some("externalAgentConfig/import/completed")
            {
                self.completions.push(
                    value
                        .get("params")
                        .cloned()
                        .ok_or(NativeImportError::InvalidResponse)?,
                );
            }
        }
    }

    fn import_completion(&mut self, id: &str) -> Result<Value, NativeImportError> {
        let deadline = Instant::now() + IMPORT_TIMEOUT;
        loop {
            if let Some(index) = self
                .completions
                .iter()
                .position(|value| value.get("importId").and_then(Value::as_str) == Some(id))
            {
                return Ok(self.completions.swap_remove(index));
            }
            let value = self.read(deadline)?;
            if value.get("method").and_then(Value::as_str)
                == Some("externalAgentConfig/import/completed")
            {
                self.completions.push(
                    value
                        .get("params")
                        .cloned()
                        .ok_or(NativeImportError::InvalidResponse)?,
                );
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsString;
    use std::os::unix::fs::PermissionsExt;

    struct Fixture {
        directory: tempfile::TempDir,
        locations: Locations,
        located: LocatedHarness,
        folder: PathBuf,
        requests: PathBuf,
    }

    impl Fixture {
        fn new(version: &str, detected: bool, completed: bool) -> Self {
            let directory = tempfile::tempdir().unwrap();
            let mut locations = Locations::examples(directory.path());
            fs::create_dir_all(directory.path().join("folder")).unwrap();
            let folder = directory.path().join("folder").canonicalize().unwrap();
            locations.folder = Some(folder.clone());
            let key = claude_key(&folder);
            let project = locations.claude.join("projects").join(&key);
            fs::create_dir_all(project.join("memory/topics")).unwrap();
            fs::write(project.join("memory/MEMORY.md"), "# Project memory\n").unwrap();
            fs::write(project.join("memory/topics/fact.md"), "A folder fact.\n").unwrap();
            fs::write(project.join("session.jsonl"), format!("{}\n", json!({"cwd": folder, "type": "user", "timestamp": "2026-10-24T12:00:00Z", "message": {"role": "user", "content": "A real task"}}))).unwrap();
            let requests = directory.path().join("requests.jsonl");
            let responses = json!({
                "version": version, "key": key, "detected": detected, "completed": completed,
                "requests": requests,
                "memory": project.join("memory"),
                "destination": locations.codex.join("memories/extensions/external_agent_import/resources").join(&key),
            });
            let program = directory.path().join("codex");
            fs::write(&program, format!(r"#!/usr/bin/python3
import json, sys, shutil
from pathlib import Path
assert sys.argv[1:] == ['--enable', 'external_agent_memory_import', 'app-server']
settings = json.loads({settings})
def send(value):
    print(json.dumps(value), flush=True)
for line in sys.stdin:
    request = json.loads(line)
    with open(settings['requests'], 'a') as log:
        log.write(json.dumps(request) + '\n')
    method = request['method']
    if method == 'initialized':
        continue
    result = {{}}
    if method == 'config/read':
        result = {{'config': {{'features': {{'memories': True, 'external_agent_memory_import': True}}, 'memories': {{'version': settings['version']}}}}}}
    elif method == 'externalAgentConfig/detect':
        result = {{'items': [{{'itemType': 'CONFIG', 'description': 'Do not import settings', 'cwd': None, 'details': None}}]}}
        if settings['detected']:
            result['items'].append({{'itemType': 'MEMORY', 'description': 'Native memory', 'cwd': None, 'details': {{'memory': ['another-project', settings['key']]}}}})
    elif method == 'externalAgentConfig/import':
        if settings['completed']:
            if not any(Path(settings['memory']).rglob('*.md')):
                shutil.rmtree(settings['destination'], ignore_errors=True)
            send({{'method': 'externalAgentConfig/import/completed', 'params': {{'importId': 'fixture-import', 'itemTypeResults': [{{'itemType': 'MEMORY', 'successes': [{{'source': settings['key']}}], 'failures': []}}]}}}})
        send({{'id': request['id'], 'result': {{'importId': 'fixture-import'}}}})
        if not settings['completed']:
            sys.exit(0)
        continue
    send({{'id': request['id'], 'result': result}})
", settings=serde_json::to_string(&responses.to_string()).unwrap())).unwrap();
            fs::set_permissions(&program, fs::Permissions::from_mode(0o700)).unwrap();
            let located = LocatedHarness {
                program,
                path: OsString::from("/usr/bin:/bin"),
            };
            Self {
                directory,
                locations,
                located,
                folder,
                requests,
            }
        }

        fn run(&self, action: NativeImportAction) -> NativeImportSnapshot {
            execute_located(
                action,
                snapshot(&self.folder, &self.locations).unwrap(),
                &self.located,
            )
            .unwrap()
        }

        fn commands(&self) -> Vec<Value> {
            fs::read_to_string(&self.requests)
                .unwrap()
                .lines()
                .map(|line| serde_json::from_str(line).unwrap())
                .collect()
        }
    }

    #[test]
    fn status_detects_native_project_without_importing_or_writing_memories() {
        let fixture = Fixture::new("v1", true, true);
        let result = fixture.run(NativeImportAction::Status);
        assert_eq!(result.source_count, 2);
        assert_eq!(result.status, "ready");
        assert!(result.can_import);
        assert!(!result.codex_path.exists());
        assert!(
            fixture
                .commands()
                .iter()
                .all(|command| command["method"] != "externalAgentConfig/import")
        );
    }

    #[test]
    fn explicit_import_selects_only_this_folder_and_waits_for_native_completion() {
        let fixture = Fixture::new("v1", true, true);
        let result = fixture.run(NativeImportAction::Import);
        assert_eq!(result.status, "imported");
        assert!(!result.can_import);
        assert_eq!(result.import_id.as_deref(), Some("fixture-import"));
        assert!(result.message.contains("consolidation is pending"));
        let commands = fixture.commands();
        let import = commands
            .iter()
            .find(|command| command["method"] == "externalAgentConfig/import")
            .unwrap();
        let items = import["params"]["migrationItems"].as_array().unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["itemType"], "MEMORY");
        assert_eq!(
            items[0]["details"]["memory"],
            json!([claude_key(&fixture.folder)])
        );
        assert_eq!(items[0]["details"]["sessions"], json!([]));
        // The fake importer writes nothing: Handshake itself must not publish a substitute store.
        assert!(!result.codex_path.exists());
    }

    #[test]
    fn accepting_an_import_id_does_not_claim_completion() {
        let fixture = Fixture::new("v1", true, false);
        let result = fixture.run(NativeImportAction::Import);
        assert_eq!(result.status, "unconfirmed");
        assert_eq!(result.import_id.as_deref(), Some("fixture-import"));
        assert!(!result.can_import);
    }

    #[test]
    fn unsupported_versions_and_missing_native_detection_never_import() {
        for (version, detected) in [("v2", true), ("v1", false)] {
            let fixture = Fixture::new(version, detected, true);
            let result = fixture.run(NativeImportAction::Import);
            assert_eq!(result.status, "unavailable");
            assert!(!result.can_import);
            assert!(
                fixture
                    .commands()
                    .iter()
                    .all(|command| command["method"] != "externalAgentConfig/import")
            );
        }
    }

    #[test]
    fn another_folders_native_session_blocks_import_even_with_matching_project_key() {
        let fixture = Fixture::new("v1", true, true);
        let source = snapshot(&fixture.folder, &fixture.locations).unwrap();
        fs::write(
            source.claude_path.parent().unwrap().join("session.jsonl"),
            format!("{}\n", json!({"cwd": fixture.directory.path()})),
        )
        .unwrap();
        let result = fixture.run(NativeImportAction::Import);
        assert!(!result.can_import);
        assert_eq!(result.status, "unavailable");
        assert!(
            fixture
                .commands()
                .iter()
                .all(|command| command["method"] != "externalAgentConfig/import")
        );
    }

    #[test]
    fn later_command_directories_do_not_change_native_session_scope() {
        let fixture = Fixture::new("v1", true, true);
        let source = snapshot(&fixture.folder, &fixture.locations).unwrap();
        let session = source.claude_path.parent().unwrap().join("session.jsonl");
        let mut contents = fs::read_to_string(&session).unwrap();
        contents
            .push_str(&json!({"cwd": fixture.directory.path(), "type": "assistant"}).to_string());
        fs::write(session, contents).unwrap();
        assert_eq!(fixture.run(NativeImportAction::Status).status, "ready");
    }

    #[test]
    fn no_pending_import_requires_matching_source_and_persisted_scopes() {
        let fixture = Fixture::new("v1", false, true);
        let source = snapshot(&fixture.folder, &fixture.locations).unwrap();
        fs::create_dir_all(&source.codex_path).unwrap();
        let scope = source.codex_path.join("scope.json");
        fs::write(&scope, json!({"cwd": fixture.directory.path()}).to_string()).unwrap();
        assert_eq!(
            fixture.run(NativeImportAction::Status).status,
            "unavailable"
        );

        fs::write(&scope, json!({"cwd": fixture.folder}).to_string()).unwrap();
        assert_eq!(fixture.run(NativeImportAction::Status).status, "current");

        let session = source.claude_path.parent().unwrap().join("session.jsonl");
        fs::write(
            &session,
            json!({"cwd": fixture.directory.path()}).to_string(),
        )
        .unwrap();
        assert_eq!(
            fixture.run(NativeImportAction::Status).status,
            "unavailable"
        );
        fs::remove_file(session).unwrap();
        assert_eq!(
            fixture.run(NativeImportAction::Status).status,
            "unavailable"
        );
        assert!(
            fixture
                .commands()
                .iter()
                .all(|command| command["method"] != "externalAgentConfig/import")
        );
    }

    #[test]
    fn deleted_source_project_can_use_verified_native_cleanup() {
        let fixture = Fixture::new("v1", true, true);
        let source = snapshot(&fixture.folder, &fixture.locations).unwrap();
        fs::create_dir_all(&source.codex_path).unwrap();
        fs::write(
            source.codex_path.join("scope.json"),
            json!({"cwd": fixture.folder}).to_string(),
        )
        .unwrap();
        fs::remove_dir_all(source.claude_path.parent().unwrap()).unwrap();
        let ready = fixture.run(NativeImportAction::Status);
        assert_eq!(ready.source_count, 0);
        assert_eq!(ready.status, "ready");
        assert!(ready.can_import);
        assert!(
            ready
                .message
                .contains("remove this folder's imported copies")
        );
        let imported = fixture.run(NativeImportAction::RemoveImported);
        assert_eq!(imported.status, "imported");
        assert!(
            imported
                .message
                .contains("removed this folder's imported memory copies")
        );
        assert!(imported.message.contains("consolidation is pending"));
        // The fake native server performs cleanup, and the adapter verifies its result.
        assert!(!source.codex_path.exists());
    }

    #[test]
    fn native_cleanup_requires_matching_scope_and_detected_project() {
        for (detected, matching_scope) in [(true, false), (false, true)] {
            let fixture = Fixture::new("v1", detected, true);
            let source = snapshot(&fixture.folder, &fixture.locations).unwrap();
            fs::create_dir_all(&source.codex_path).unwrap();
            let cwd = if matching_scope {
                &fixture.folder
            } else {
                fixture.directory.path()
            };
            fs::write(
                source.codex_path.join("scope.json"),
                json!({"cwd": cwd}).to_string(),
            )
            .unwrap();
            fs::remove_dir_all(source.claude_path.parent().unwrap()).unwrap();
            let result = fixture.run(NativeImportAction::RemoveImported);
            assert_eq!(result.status, "unavailable");
            assert!(!result.can_import);
            assert!(
                fixture
                    .commands()
                    .iter()
                    .all(|command| command["method"] != "externalAgentConfig/import")
            );
            if matching_scope {
                assert!(result.message.contains("still has imported copies"));
            }
        }
    }

    #[test]
    fn explicit_cleanup_does_not_import_repopulated_source() {
        let fixture = Fixture::new("v1", true, true);
        let result = fixture.run(NativeImportAction::RemoveImported);
        assert_eq!(result.status, "unavailable");
        assert!(!result.can_import);
        assert!(result.message.contains("Claude memories changed"));
        assert!(
            fixture
                .commands()
                .iter()
                .all(|command| command["method"] != "externalAgentConfig/import")
        );
    }

    #[test]
    fn foreign_source_created_during_detection_never_imports() {
        let fixture = Fixture::new("v1", true, true);
        let source = snapshot(&fixture.folder, &fixture.locations).unwrap();
        fs::create_dir_all(&source.codex_path).unwrap();
        fs::write(
            source.codex_path.join("scope.json"),
            json!({"cwd": fixture.folder}).to_string(),
        )
        .unwrap();
        fs::remove_dir_all(source.claude_path.parent().unwrap()).unwrap();
        let memory = serde_json::to_string(&source.claude_path).unwrap();
        let session =
            serde_json::to_string(&json!({"cwd": fixture.directory.path()}).to_string()).unwrap();
        let injection = format!(
            "    elif method == 'externalAgentConfig/detect':\n        memory = Path({memory})\n        memory.mkdir(parents=True, exist_ok=True)\n        (memory / 'new.md').write_text('New fixture memory')\n        (memory.parent / 'session.jsonl').write_text({session})"
        );
        let program = fs::read_to_string(&fixture.located.program).unwrap();
        fs::write(
            &fixture.located.program,
            program.replace(
                "    elif method == 'externalAgentConfig/detect':",
                &injection,
            ),
        )
        .unwrap();
        let result = fixture.run(NativeImportAction::RemoveImported);
        assert_eq!(result.source_count, 1);
        assert_eq!(result.status, "unavailable");
        assert!(!result.can_import);
        assert!(
            fixture
                .commands()
                .iter()
                .all(|command| command["method"] != "externalAgentConfig/import")
        );
    }

    #[test]
    fn fragmented_native_output_cannot_extend_the_absolute_deadline() {
        let (socket, mut remote) = UnixStream::pair().unwrap();
        let writer = std::thread::spawn(move || {
            for _ in 0..48 {
                if remote.write_all(b" ").is_err() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(15));
            }
        });
        let mut reader = BufReader::new(socket);
        let mut remaining = MAX_PROTOCOL_BYTES;
        let started = Instant::now();
        let result = read_message(
            &mut reader,
            &mut remaining,
            started + Duration::from_millis(75),
        );
        assert!(
            matches!(result, Err(NativeImportError::Io(error)) if matches!(error.kind(), io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock))
        );
        assert!(started.elapsed() < Duration::from_millis(400));
        drop(reader);
        writer.join().unwrap();
    }

    #[test]
    fn source_count_skips_symlinks_and_memory_directory_overrides_are_explicit() {
        let mut fixture = Fixture::new("v1", true, true);
        let mut result = snapshot(&fixture.folder, &fixture.locations).unwrap();
        std::os::unix::fs::symlink("topics/fact.md", result.claude_path.join("alias.md")).unwrap();
        assert_eq!(markdown_count(&result.claude_path).unwrap(), 2);
        fixture.locations.claude_settings = json!({"autoMemoryDirectory": "/unsupported"});
        assert!(!supported_source(&fixture.locations, &mut result));
        assert!(result.message.contains("autoMemoryDirectory"));
    }
}
