//! Native project profiles. Publication never edits a harness-generated consolidated index.
use super::{Error, contract, storage::Project};
use serde_json::{Value, json};
use std::fs;
use std::io::Write;
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};

#[derive(Clone)]
pub(super) struct Roots {
    pub claude: PathBuf,
    pub codex: PathBuf,
}
impl Roots {
    pub fn live() -> Self {
        let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
        Self {
            claude: std::env::var_os("CLAUDE_CONFIG_DIR")
                .map_or_else(|| home.join(".claude"), PathBuf::from),
            codex: std::env::var_os("CODEX_HOME")
                .map_or_else(|| home.join(".codex"), PathBuf::from),
        }
    }
}
pub(super) struct Candidate {
    pub provider: &'static str,
    pub key: String,
    pub path: PathBuf,
    pub text: String,
}

// The Handshake-prefixed value is consumed by the launcher as a native --settings value;
// it is never exported as a child environment variable or used to relocate Claude auth/history.
pub(super) fn environment(project: &Project) -> Vec<(String, String)> {
    vec![
        (
            "CODEX_HOME".into(),
            project.codex.to_string_lossy().into_owned(),
        ),
        (
            "HANDSHAKE_CLAUDE_MEMORY_DIRECTORY".into(),
            project.claude.to_string_lossy().into_owned(),
        ),
    ]
}
pub(super) fn prepare(project: &Project, roots: &Roots) -> Result<(), Error> {
    safe_path(&project.claude)?;
    safe_path(&project.codex)?;
    if project.root.join("library.amis.json").exists()
        && (!project.claude.is_dir()
            || !project
                .codex
                .join("memories/extensions/ad_hoc/notes")
                .is_dir())
    {
        return Err(Error::Contract("A native memory profile is missing. Restore its directory before reconciling; its memories have not been archived.".into()));
    }
    fs::create_dir_all(&project.claude)?;
    fs::create_dir_all(project.codex.join("memories/extensions/ad_hoc/notes"))?;
    for name in [
        "config.toml",
        "auth.json",
        "AGENTS.md",
        "skills",
        "rules",
        "plugins",
    ] {
        let source = roots.codex.join(name);
        let target = project.codex.join(name);
        if source.exists() && fs::symlink_metadata(&target).is_err() {
            std::os::unix::fs::symlink(source.canonicalize()?, target)?;
        }
    }
    let config = project.codex.join("config.toml");
    if !config.exists() {
        fs::write(config, "[features]\nmemories = true\n")?;
    }
    // Custom Claude memory roots bypass project aliases; hold instead of weakening the binding.
    if let Ok(bytes) = fs::read(roots.claude.join("settings.json")) {
        let settings: Value = serde_json::from_slice(&bytes)?;
        if settings
            .get("autoMemoryDirectory")
            .is_some_and(|v| !v.is_null())
            || settings.get("autoMemoryEnabled") == Some(&json!(false))
        {
            return Err(Error::Contract(
                "Claude auto-memory settings do not allow an isolated project profile.".into(),
            ));
        }
    }
    let config = fs::read_to_string(project.codex.join("config.toml"))?;
    let config: toml::Value =
        toml::from_str(&config).map_err(|e| Error::Contract(e.to_string()))?;
    if config.get("sqlite_home").is_some() || std::env::var_os("CODEX_SQLITE_HOME").is_some() {
        return Err(Error::Contract(
            "A custom Codex SQLite home bypasses project isolation.".into(),
        ));
    }
    if config
        .get("features")
        .and_then(|f| f.get("memories"))
        .and_then(toml::Value::as_bool)
        == Some(false)
        || config
            .get("memories")
            .and_then(|m| m.get("use_memories"))
            .and_then(toml::Value::as_bool)
            == Some(false)
    {
        return Err(Error::Contract(
            "Codex native memory loading is disabled in your settings.".into(),
        ));
    }
    Ok(())
}
fn text(path: &Path) -> Result<Option<String>, Error> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(value) => value,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e.into()),
    };
    if !metadata.is_file() {
        return Err(Error::Conflict);
    }
    let before = metadata.modified()?;
    let bytes = fs::read(path)?;
    let after = fs::symlink_metadata(path)?;
    if metadata.len() != after.len() || before != after.modified()? {
        return Err(Error::Conflict);
    }
    String::from_utf8(bytes).map(Some).map_err(|_| {
        Error::Contract("Native memory must be UTF-8; existing bytes were preserved.".into())
    })
}
fn markdown(root: &Path, provider: &'static str, output: &mut Vec<Candidate>) -> Result<(), Error> {
    if !root.exists() {
        return Ok(());
    }
    if fs::symlink_metadata(root)?.file_type().is_symlink() {
        return Err(Error::Conflict);
    }
    for entry in fs::read_dir(root)? {
        let entry = entry?;
        let kind = entry.file_type()?;
        let path = entry.path();
        if kind.is_dir() {
            markdown(&path, provider, output)?;
        } else if kind.is_file()
            && path
                .extension()
                .is_some_and(|e| e.eq_ignore_ascii_case("md"))
        {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name == "MEMORY.md" || name.starts_with("twine-index") {
                continue;
            }
            if let Some(body) = text(&path)?
                && !body.trim().is_empty()
            {
                output.push(Candidate {
                    provider,
                    key: path.to_string_lossy().into_owned(),
                    path,
                    text: body,
                });
            }
        }
    }
    Ok(())
}
pub(super) fn capture(project: &Project, roots: &Roots) -> Result<Vec<Candidate>, Error> {
    let mut candidates = Vec::new();
    markdown(
        &roots
            .claude
            .join("projects")
            .join(super::super::locations::claude_key(&project.folder))
            .join("memory"),
        "claude_code",
        &mut candidates,
    )?;
    markdown(&project.claude, "claude_code", &mut candidates)?;
    markdown(
        &project.codex.join("memories/extensions/ad_hoc/notes"),
        "codex",
        &mut candidates,
    )?;
    // Global entries require an exact native cwd. The managed home is physically project-scoped.
    for codex in [&roots.codex, &project.codex] {
        if let Some(memory) = text(&codex.join("memories/MEMORY.md"))? {
            let managed = codex == &project.codex;
            let sections: Vec<_> = if memory.contains("# Task Group:") {
                memory
                    .split("# Task Group:")
                    .skip(1)
                    .map(|s| format!("# Task Group:{s}"))
                    .collect()
            } else if managed && !memory.trim().is_empty() {
                vec![memory]
            } else {
                Vec::new()
            };
            for section in sections {
                let cwd = section
                    .lines()
                    .find_map(|line| line.strip_prefix("applies_to: cwd="))
                    .and_then(|line| line.split(';').next());
                if managed
                    || cwd
                        .and_then(|p| Path::new(p.trim()).canonicalize().ok())
                        .as_ref()
                        == Some(&project.folder)
                {
                    candidates.push(Candidate {
                        provider: "codex",
                        key: format!(
                            "codex-task-group:{}:{}:{}",
                            project.id,
                            codex.display(),
                            section.lines().next().unwrap_or_default()
                        ),
                        path: codex.join("memories/MEMORY.md"),
                        text: section,
                    });
                }
            }
        }
    }
    Ok(candidates)
}
pub(super) fn body(record: &Value, project: &Project) -> String {
    format!(
        "For this project only: {}\nAMIS memory {} / revision {}\n\n{}",
        project.folder.display(),
        record["id"].as_str().unwrap_or_default(),
        record["revision"]["id"].as_str().unwrap_or_default(),
        record["body"]["text"].as_str().unwrap_or_default()
    )
}
/// A preimage check protects user edits; all writes use a sealed intent and private blob.
pub(super) fn atomic_write(path: &Path, bytes: &[u8], expected: Option<&str>) -> Result<(), Error> {
    safe_path(path)?;
    let current = text(path)?;
    if current
        .as_deref()
        .map(|t| contract::hash(t.as_bytes()))
        .as_deref()
        != expected
    {
        return Err(Error::Conflict);
    }
    let parent = path.parent().ok_or(Error::InvalidFolder)?;
    fs::create_dir_all(parent)?;
    let mut temporary = tempfile::NamedTempFile::new_in(parent)?;
    temporary.write_all(bytes)?;
    temporary.as_file().sync_all()?;
    if text(path)?
        .as_deref()
        .map(|t| contract::hash(t.as_bytes()))
        .as_deref()
        != expected
    {
        return Err(Error::Conflict);
    }
    if expected.is_none() {
        temporary.persist_noclobber(path).map_err(|e| e.error)?;
    } else {
        temporary.persist(path).map_err(|e| e.error)?;
    }
    std::fs::File::open(parent)?.sync_all()?;
    Ok(())
}
pub(super) fn read(path: &Path) -> Result<Option<String>, Error> {
    text(path)
}

/// Reject symlink ancestors and path traversal at every native publication boundary.
pub(super) fn safe_path(path: &Path) -> Result<(), Error> {
    if !path.is_absolute() {
        return Err(Error::Conflict);
    }
    let mut current = PathBuf::new();
    for part in path.components() {
        if matches!(
            part,
            std::path::Component::ParentDir | std::path::Component::CurDir
        ) {
            return Err(Error::Conflict);
        }
        current.push(part);
        match fs::symlink_metadata(&current) {
            Ok(meta) if meta.file_type().is_symlink() => return Err(Error::Conflict),
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}
/// Only new managed files are safe to publish beside a live native writer.
pub(super) fn managed_projection(project: &Project, path: &Path, role: &str) -> bool {
    matches!(role, "topic" | "note" | "index") && path != project.claude.join("MEMORY.md")
}

/// Codex's Use memories setting is independent of generation eligibility.
/// The native /memories UI persists it to config; `threads.memory_mode` only controls
/// generation, so a use-only conversation must still receive saved context.
pub(super) fn memory_use_enabled(folder: &Path, config: &Path) -> Result<bool, Error> {
    let layers = std::iter::once(config.to_owned()).chain(
        folder
            .ancestors()
            .map(|parent| parent.join(".codex/config.toml")),
    );
    // Preserve explicit opt-outs conservatively, including ancestor project layers.
    for path in layers {
        let source = match fs::read_to_string(path) {
            Ok(source) => source,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error.into()),
        };
        let settings: toml::Value =
            toml::from_str(&source).map_err(|e| Error::Contract(e.to_string()))?;
        if !codex_scope_use_enabled(&settings) {
            return Ok(false);
        }
    }
    Ok(true)
}

fn codex_scope_use_enabled(settings: &toml::Value) -> bool {
    for (section, key) in [("features", "memories"), ("memories", "use_memories")] {
        if settings
            .get(section)
            .and_then(|v| v.get(key))
            .and_then(toml::Value::as_bool)
            == Some(false)
        {
            return false;
        }
    }
    true
}

/// Unsupported native layouts must be reported during sync, without blocking
/// status inspection or the user's ability to pause sharing.
pub(super) fn ensure_codex_memory_layout(folder: &Path, config: &Path) -> Result<(), Error> {
    for path in std::iter::once(config.to_owned()).chain(
        folder
            .ancestors()
            .map(|parent| parent.join(".codex/config.toml")),
    ) {
        let source = match fs::read_to_string(path) {
            Ok(source) => source,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error.into()),
        };
        let settings: toml::Value =
            toml::from_str(&source).map_err(|e| Error::Contract(e.to_string()))?;
        let version = settings
            .get("memories")
            .and_then(|v| v.get("version"))
            .and_then(toml::Value::as_str);
        if version.is_some_and(|version| version != "v1") {
            return Err(Error::Contract("Cross-agent memory currently supports the Codex v1 memory layout. The selected native memory version is unsupported; automatic sharing is held.".into()));
        }
    }
    Ok(())
}

/// Honor native user/project/local opt-outs before supplying additional context.
pub(super) fn claude_memory_use_enabled(
    folder: &Path,
    root: &Path,
    disabled: Option<&std::ffi::OsStr>,
) -> Result<bool, Error> {
    if disabled
        .and_then(std::ffi::OsStr::to_str)
        .is_some_and(|value| value == "1" || value.eq_ignore_ascii_case("true"))
    {
        return Ok(false);
    }
    let layers =
        std::iter::once(root.join("settings.json")).chain(folder.ancestors().flat_map(|parent| {
            [
                parent.join(".claude/settings.json"),
                parent.join(".claude/settings.local.json"),
            ]
        }));
    for path in layers {
        let bytes = match fs::read(path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error.into()),
        };
        let settings: Value = serde_json::from_slice(&bytes)?;
        let disabled = settings
            .get("env")
            .and_then(|env| env.get("CLAUDE_CODE_DISABLE_AUTO_MEMORY"))
            .and_then(Value::as_str)
            .is_some_and(|value| value == "1" || value.eq_ignore_ascii_case("true"));
        if settings.get("autoMemoryEnabled") == Some(&json!(false)) || disabled {
            return Ok(false);
        }
    }
    Ok(true)
}

/// Refuse native-owned file replacement while the process could be writing it.
/// Process inspection failure holds delivery. Handshake's receiver lock alone is insufficient.
pub(super) fn quiescent(project: &Project, provider: &str) -> Result<(), Error> {
    let output = std::process::Command::new("/bin/ps")
        .args(["-axo", "pid=,comm="])
        .output()?;
    if !output.status.success() {
        return Err(Error::NativeActive);
    }
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        let line = line.trim();
        let Some((pid, command)) = line.split_once(char::is_whitespace) else {
            continue;
        };
        let name = Path::new(command.trim())
            .file_name()
            .unwrap_or_default()
            .to_string_lossy();
        let relevant = if provider == "codex" {
            name == "codex"
        } else {
            name == "claude"
        };
        if !relevant {
            continue;
        }
        let cwd = std::process::Command::new("/usr/sbin/lsof")
            .args(["-a", "-p", pid, "-d", "cwd", "-Fn"])
            .output()?;
        if !cwd.status.success() {
            return Err(Error::NativeActive);
        }
        if String::from_utf8_lossy(&cwd.stdout)
            .lines()
            .filter_map(|l| l.strip_prefix('n'))
            .any(|path| Path::new(path).canonicalize().ok().as_ref() == Some(&project.folder))
        {
            return Err(Error::NativeActive);
        }
    }
    Ok(())
}

/// Shared lifetime lease for Handshake-launched native processes; an exclusive lease protects apply.
pub(super) fn lease(project: &Project, provider: &str, writer: bool) -> Result<fs::File, Error> {
    let file = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(
            project
                .root
                .join(format!("native-sessions-{provider}.lock")),
        )?;
    let mode = if writer { libc::LOCK_EX } else { libc::LOCK_SH };
    // SAFETY: flock operates on the live, owned descriptor; dropping the file releases the lease.
    if unsafe { libc::flock(file.as_raw_fd(), mode | libc::LOCK_NB) } != 0 {
        return Err(Error::NativeActive);
    }
    Ok(file)
}
pub(super) fn configuration(
    roots: &Roots,
    project: &Project,
    provider: &str,
) -> Result<String, Error> {
    let path = if provider == "codex" {
        project.codex.join("config.toml")
    } else {
        roots.claude.join("settings.json")
    };
    let bytes = fs::read(path).or_else(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            Ok(Vec::new())
        } else {
            Err(error)
        }
    })?;
    Ok(contract::hash(
        &[
            contract::configuration(&project.id, provider).as_bytes(),
            &bytes,
        ]
        .concat(),
    ))
}
