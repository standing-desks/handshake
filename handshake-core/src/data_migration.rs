//! Explicit migration of application data. Platform paths come from the caller; ordinary
//! development/test constructors never search for or adopt another data directory.

use std::fs::{self, File, OpenOptions, TryLockError};
use std::io::{self, Read};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Component, Path, PathBuf};

use rusqlite::{
    Connection, OpenFlags,
    backup::{Backup, StepResult},
};
use sha2::{Digest, Sha256};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum DataMigrationError {
    #[error("Could not {operation} at {path}: {source}. The original data has been retained.")]
    Io {
        operation: &'static str,
        path: PathBuf,
        source: io::Error,
    },
    #[error(
        "Could not migrate database {path}: {source}. Close the old app and retry; original data is retained."
    )]
    Database {
        path: PathBuf,
        source: rusqlite::Error,
    },
    #[error("Could not verify migrated storage at {path}: {source}. Original data is retained.")]
    Store {
        path: PathBuf,
        source: crate::StoreError,
    },
    #[error(
        "Could not verify migrated transcripts from {path}: {source}. Original data is retained."
    )]
    Transcript {
        path: PathBuf,
        source: crate::TranscriptError,
    },
    #[error("Data at {0} is in use. Close the other app and retry.")]
    InUse(PathBuf),
    #[error("Cannot migrate {path}: {reason}. Original data is retained.")]
    Invalid { path: PathBuf, reason: &'static str },
}

fn io_at<T>(
    path: &Path,
    operation: &'static str,
    result: io::Result<T>,
) -> Result<T, DataMigrationError> {
    result.map_err(|source| DataMigrationError::Io {
        operation,
        path: path.into(),
        source,
    })
}

struct Ownership(File);
impl Drop for Ownership {
    fn drop(&mut self) {
        if let Err(error) = self.0.unlock() {
            tracing::warn!(%error, "could not release data migration ownership");
        }
    }
}

fn lock(path: &Path) -> Result<Ownership, DataMigrationError> {
    let file = io_at(
        path,
        "open ownership lock",
        OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path),
    )?;
    file.try_lock().map_err(|error| match error {
        TryLockError::WouldBlock => DataMigrationError::InUse(path.into()),
        TryLockError::Error(source) => DataMigrationError::Io {
            operation: "lock data",
            path: path.into(),
            source,
        },
    })?;
    Ok(Ownership(file))
}

fn directory_exists(path: &Path) -> Result<bool, DataMigrationError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_dir() => Ok(true),
        Ok(_) => Err(DataMigrationError::Invalid {
            path: path.into(),
            reason: "expected a directory, not a symlink or file",
        }),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => io_at(path, "inspect directory", Err(error)),
    }
}

/// Prepares `destination` from legacy application data, retaining the original directory.
/// An existing destination wins without merging. Copies are verified privately and published
/// atomically; an interrupted copy is never treated as an established destination.
/// Call this only for production paths, before opening a runtime. Explicit overrides, tests,
/// development builds and previews must continue using their own directories directly.
///
/// # Errors
/// Returns an actionable error for live writers, unavailable paths, unsupported file types,
/// corrupt databases, or failed copy/verification/publication. No existing destination is replaced.
pub fn migrate_data_directory(legacy: &Path, destination: &Path) -> Result<(), DataMigrationError> {
    for path in [legacy, destination] {
        if !path.is_absolute() || path.components().any(|c| matches!(c, Component::ParentDir)) {
            return Err(DataMigrationError::Invalid {
                path: path.into(),
                reason: "use an absolute path without parent traversal",
            });
        }
    }
    if directory_exists(destination)? {
        return Ok(());
    }
    let parent = destination
        .parent()
        .ok_or_else(|| DataMigrationError::Invalid {
            path: destination.into(),
            reason: "destination needs a parent directory",
        })?;
    io_at(
        parent,
        "create destination parent",
        fs::create_dir_all(parent),
    )?;
    let _migration = lock(&parent.join(".handshake-migration.lock"))?;
    if directory_exists(destination)? {
        return Ok(());
    }
    let exists = directory_exists(legacy)?;
    if exists {
        let source = io_at(legacy, "resolve source", legacy.canonicalize())?;
        let target = io_at(parent, "resolve destination parent", parent.canonicalize())?;
        if target.starts_with(&source) {
            return Err(DataMigrationError::Invalid {
                path: destination.into(),
                reason: "destination must be outside the legacy directory",
            });
        }
    }
    let staging = io_at(
        parent,
        "create private migration copy",
        tempfile::Builder::new()
            .prefix(".handshake-migration-")
            .tempdir_in(parent),
    )?;
    let mut _source_ownership = None;
    let mut _database_ownership = None;
    if exists {
        let transcripts = legacy.join("transcripts");
        if !directory_exists(&transcripts)? {
            io_at(
                &transcripts,
                "create transcript ownership directory",
                fs::create_dir(&transcripts),
            )?;
        }
        _source_ownership = Some(lock(&transcripts.join("owner.lock"))?);
        let database = legacy.join("twine.db");
        // Hold a write reservation on a separate connection while the backup reader snapshots
        // committed main/WAL pages. No SQLite sidecar is copied as an ordinary file.
        _database_ownership = match fs::symlink_metadata(&database) {
            Ok(_) => Some(snapshot_database(
                &database,
                &staging.path().join("handshake.db"),
            )?),
            Err(error) if error.kind() == io::ErrorKind::NotFound => None,
            Err(error) => return io_at(&database, "inspect database", Err(error)),
        };
        copy_directory(legacy, staging.path(), true)?;
    }
    // Validate the schema too, and create a fresh database for an empty/fresh installation.
    crate::store::Store::open(&staging.path().join("handshake.db"))
        .and_then(|store| store.verify_schema())
        .map_err(|source| DataMigrationError::Store {
            path: legacy.into(),
            source,
        })?;
    let transcripts = crate::terminal::TranscriptRecorder::open(
        &staging.path().join("transcripts"),
    )
    .map_err(|source| DataMigrationError::Transcript {
        path: legacy.into(),
        source,
    })?;
    transcripts.shutdown();
    sync_tree(staging.path())?;
    match rustix::fs::renameat_with(
        rustix::fs::CWD,
        staging.path(),
        rustix::fs::CWD,
        destination,
        rustix::fs::RenameFlags::NOREPLACE,
    ) {
        Ok(()) => {
            let _published = staging.keep();
        }
        Err(rustix::io::Errno::EXIST) if directory_exists(destination)? => return Ok(()),
        Err(error) => return io_at(destination, "publish verified migration", Err(error.into())),
    }
    io_at(
        parent,
        "sync migration publication",
        File::open(parent).and_then(|f| f.sync_all()),
    )
}

fn snapshot_database(source: &Path, destination: &Path) -> Result<Connection, DataMigrationError> {
    if !io_at(
        source,
        "inspect legacy database",
        fs::symlink_metadata(source),
    )?
    .is_file()
    {
        return Err(DataMigrationError::Invalid {
            path: source.into(),
            reason: "database must be a regular file",
        });
    }
    let resolved = io_at(source, "resolve database", source.canonicalize())?;
    let snapshot = || -> rusqlite::Result<Connection> {
        let writer = Connection::open_with_flags(
            &resolved,
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )?;
        writer.busy_timeout(std::time::Duration::ZERO)?;
        writer.execute_batch("BEGIN IMMEDIATE")?;
        let reader = Connection::open_with_flags(
            &resolved,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )?;
        let mut output = Connection::open(destination)?;
        let result = Backup::new(&reader, &mut output)?.step(-1)?;
        if result != StepResult::Done {
            return Err(rusqlite::Error::SqliteFailure(
                rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_BUSY),
                None,
            ));
        }
        let check: String = output.query_row("PRAGMA quick_check", [], |row| row.get(0))?;
        if check != "ok" {
            return Err(rusqlite::Error::InvalidQuery);
        }
        Ok(writer)
    };
    snapshot().map_err(|source_error| DataMigrationError::Database {
        path: source.into(),
        source: source_error,
    })
}

fn copy_directory(source: &Path, destination: &Path, root: bool) -> Result<(), DataMigrationError> {
    for entry in io_at(source, "read data directory", fs::read_dir(source))? {
        let entry = io_at(source, "read directory entry", entry)?;
        let name = entry.file_name();
        if root
            && [
                "twine.db",
                "twine.db-wal",
                "twine.db-shm",
                "twine.db-journal",
            ]
            .iter()
            .any(|n| name == *n)
        {
            continue;
        }
        let target = destination.join(if root && name == "twine.trace-details" {
            std::ffi::OsStr::new("handshake.trace-details")
        } else {
            &name
        });
        let kind = io_at(&entry.path(), "inspect data entry", entry.file_type())?;
        if kind.is_dir() {
            io_at(&target, "create copied directory", fs::create_dir(&target))?;
            copy_directory(&entry.path(), &target, false)?;
        } else if kind.is_file() {
            if target.exists() {
                return Err(DataMigrationError::Invalid {
                    path: entry.path(),
                    reason: "conflicting migration filenames",
                });
            }
            io_at(&target, "copy data file", fs::copy(entry.path(), &target))?;
            if digest(&entry.path())? != digest(&target)? {
                return Err(DataMigrationError::Invalid {
                    path: target,
                    reason: "copied bytes did not verify",
                });
            }
        } else {
            return Err(DataMigrationError::Invalid {
                path: entry.path(),
                reason: "symlinks and special files require manual migration",
            });
        }
    }
    Ok(())
}

fn digest(path: &Path) -> Result<Vec<u8>, DataMigrationError> {
    let mut input = io_at(path, "verify copied bytes", File::open(path))?;
    let mut hash = Sha256::new();
    let mut buffer = [0; 8192];
    loop {
        let count = io_at(path, "verify copied bytes", input.read(&mut buffer))?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
    }
    Ok(hash.finalize().to_vec())
}

fn sync_tree(path: &Path) -> Result<(), DataMigrationError> {
    for entry in io_at(path, "sync copied directory", fs::read_dir(path))? {
        let entry = io_at(path, "sync directory entry", entry)?;
        if entry
            .file_type()
            .map_err(|source| DataMigrationError::Io {
                operation: "inspect copied entry",
                path: entry.path(),
                source,
            })?
            .is_dir()
        {
            sync_tree(&entry.path())?;
        } else {
            io_at(
                &entry.path(),
                "sync copied file",
                File::open(entry.path()).and_then(|f| f.sync_all()),
            )?;
        }
    }
    io_at(
        path,
        "sync copied directory",
        File::open(path).and_then(|f| f.sync_all()),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;
    use crate::{
        Application, Command, CommandDisposition, RequestId, TerminalSize, TraceActivityId,
        TranscriptRead, WorkflowKind,
    };
    use std::fmt::Write as _;
    use std::time::{Duration, Instant};

    fn command(app: &Application, command: Command) {
        assert_eq!(
            app.handle_command(RequestId(1), command)
                .unwrap()
                .disposition,
            CommandDisposition::Accepted
        );
    }

    fn recorded_legacy(source: &Path, folder: &Path) -> (crate::TerminalId, TranscriptRead) {
        let app = Application::with_config(source, Config::default()).unwrap();
        command(
            &app,
            Command::OpenFolder {
                path: folder.into(),
            },
        );
        command(
            &app,
            Command::CreateWorkflow {
                folder: folder.into(),
                session_id: None,
                kind: WorkflowKind::Terminal,
                roles: vec![],
                size: TerminalSize {
                    rows: 24,
                    columns: 80,
                    pixel_width: 800,
                    pixel_height: 480,
                },
            },
        );
        let id = app
            .snapshot()
            .unwrap()
            .workflows
            .workflows
            .last()
            .unwrap()
            .terminal_ids()[0];
        app.write_terminal_input(id, b"printf 'migration-output\\n'; exit\n")
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let page = app.read_terminal_transcript(id, 0, 65536).unwrap();
            if let TranscriptRead::Output(ref output) = page
                && String::from_utf8_lossy(&output.bytes).contains("migration-output\r\n")
            {
                drop(app);
                let recorder =
                    crate::terminal::TranscriptRecorder::open(&source.join("transcripts")).unwrap();
                return (id, recorder.read(id, 0, 65536).unwrap());
            }
            assert!(Instant::now() < deadline, "shell output did not arrive");
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn migrates_wal_sessions_transcripts_details_and_presentation_without_losing_the_source() {
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("Twine");
        let destination = root.path().join("Handshake");
        let folder = tempfile::tempdir().unwrap();
        let (terminal, bytes) = recorded_legacy(&source, folder.path());
        let database = Connection::open(source.join("twine.db")).unwrap();
        database
            .execute_batch("PRAGMA wal_autocheckpoint=0; UPDATE sessions SET name='WAL session';")
            .unwrap();
        let detail = "native trace output ☃";
        let mut key = String::new();
        for byte in Sha256::digest(detail.as_bytes()) {
            write!(&mut key, "{byte:02x}").unwrap();
        }
        fs::write(source.join("twine.trace-details").join(&key), detail).unwrap();
        database.execute("INSERT INTO trace_activities(id,span_id,source_id,kind,title,status,input,output,output_key,output_bytes)
            VALUES(4242,(SELECT id FROM trace_spans LIMIT 1),'migration','tool','Saved tool','completed','','preview',?1,?2)",
            rusqlite::params![key, i64::try_from(detail.len()).unwrap()]).unwrap();
        assert!(source.join("twine.db-wal").metadata().unwrap().len() > 0);
        fs::write(source.join("workflow-layouts.json"), b"presentation state").unwrap();
        migrate_data_directory(&source, &destination).unwrap();
        assert!(source.join("twine.db").exists());
        assert!(source.join("twine.trace-details").join(&key).exists());
        assert!(!destination.join("twine.db").exists());
        assert_eq!(
            fs::read(destination.join("workflow-layouts.json")).unwrap(),
            b"presentation state"
        );
        let app = Application::with_config(&destination, Config::default()).unwrap();
        assert!(
            app.snapshot()
                .unwrap()
                .workflows
                .sessions
                .iter()
                .any(|session| session.name == "WAL session")
        );
        assert_eq!(
            app.read_terminal_transcript(terminal, 0, 65536).unwrap(),
            bytes
        );
        assert_eq!(
            app.trace_detail(TraceActivityId(4242), true, 0, 65536)
                .unwrap()
                .text,
            detail
        );
        assert_ne!(
            app.workflow_trace(crate::WorkflowId(1), None, 10)
                .unwrap()
                .spans
                .len(),
            0
        );
        drop(app);
        migrate_data_directory(&source, &destination).unwrap();
        let reopened = Application::with_config(&destination, Config::default()).unwrap();
        assert_eq!(
            reopened
                .read_terminal_transcript(terminal, 0, 65536)
                .unwrap(),
            bytes
        );
        assert_eq!(
            reopened
                .trace_detail(TraceActivityId(4242), true, 0, 65536)
                .unwrap()
                .text,
            detail
        );
    }

    #[test]
    fn fresh_install_is_isolated_and_an_established_destination_wins() {
        let root = tempfile::tempdir().unwrap();
        let legacy = root.path().join("missing-legacy");
        let destination = root.path().join("Handshake");
        migrate_data_directory(&legacy, &destination).unwrap();
        assert!(!legacy.exists());
        assert!(destination.join("handshake.db").is_file());
        let database = fs::read(destination.join("handshake.db")).unwrap();
        fs::write(&legacy, b"unavailable source").unwrap();
        migrate_data_directory(&legacy, &destination).unwrap();
        assert_eq!(
            fs::read(destination.join("handshake.db")).unwrap(),
            database
        );
        let isolated = root.path().join("debug");
        drop(Application::with_config(&isolated, Config::default()).unwrap());
        assert!(!isolated.join("handshake.db").exists());
    }

    #[test]
    fn refuses_live_cores_and_sqlite_writers() {
        let root = tempfile::tempdir().unwrap();
        let legacy = root.path().join("Twine");
        let destination = root.path().join("Handshake");
        let app = Application::with_config(&legacy, Config::default()).unwrap();
        assert!(matches!(
            migrate_data_directory(&legacy, &destination),
            Err(DataMigrationError::InUse(_))
        ));
        assert!(!destination.exists());
        drop(app);
        let writer = Connection::open(legacy.join("twine.db")).unwrap();
        writer.execute_batch("BEGIN IMMEDIATE").unwrap();
        assert!(matches!(
            migrate_data_directory(&legacy, &destination),
            Err(DataMigrationError::Database { .. })
        ));
        assert!(!destination.exists());
        drop(writer);
        migrate_data_directory(&legacy, &destination).unwrap();
    }

    #[test]
    fn interrupted_staging_and_failed_copies_retry_without_overwriting_data() {
        let root = tempfile::tempdir().unwrap();
        let legacy = root.path().join("Twine");
        let destination = root.path().join("Handshake");
        drop(Application::with_config(&legacy, Config::default()).unwrap());
        let interrupted = root.path().join(".handshake-migration-interrupted");
        fs::create_dir(&interrupted).unwrap();
        fs::write(interrupted.join("handshake.db"), b"partial").unwrap();
        std::os::unix::fs::symlink("/missing", legacy.join("unavailable")).unwrap();
        assert!(migrate_data_directory(&legacy, &destination).is_err());
        assert!(!destination.exists());
        assert!(legacy.join("twine.db").exists());
        fs::remove_file(legacy.join("unavailable")).unwrap();
        migrate_data_directory(&legacy, &destination).unwrap();
        assert!(Application::with_config(&destination, Config::default()).is_ok());
    }

    #[test]
    fn corrupt_domain_schema_is_rejected_before_publication_and_can_be_repaired() {
        let root = tempfile::tempdir().unwrap();
        let legacy = root.path().join("Twine");
        let destination = root.path().join("Handshake");
        drop(Application::with_config(&legacy, Config::default()).unwrap());
        let path = legacy.join("twine.db");
        let original = fs::read(&path).unwrap();
        let database = Connection::open(&path).unwrap();
        database.execute_batch("DROP TABLE sessions").unwrap();
        assert_eq!(
            database
                .query_row("PRAGMA quick_check", [], |row| row.get::<_, String>(0))
                .unwrap(),
            "ok"
        );
        drop(database);
        assert!(migrate_data_directory(&legacy, &destination).is_err());
        assert!(!destination.exists());
        fs::write(&path, original).unwrap();
        migrate_data_directory(&legacy, &destination).unwrap();
        assert!(Application::with_config(&destination, Config::default()).is_ok());
    }

    #[test]
    fn corrupt_transcript_metadata_is_not_published_and_repair_can_retry() {
        let root = tempfile::tempdir().unwrap();
        let legacy = root.path().join("Twine");
        let destination = root.path().join("Handshake");
        drop(Application::with_config(&legacy, Config::default()).unwrap());
        let metadata = legacy.join("transcripts/metadata");
        let original = fs::read(&metadata).unwrap();
        fs::write(&metadata, "corrupt").unwrap();
        assert!(matches!(
            migrate_data_directory(&legacy, &destination),
            Err(DataMigrationError::Transcript { .. })
        ));
        assert!(!destination.exists());
        assert_eq!(fs::read(&metadata).unwrap(), b"corrupt");
        fs::write(&metadata, original).unwrap();
        migrate_data_directory(&legacy, &destination).unwrap();
        assert!(Application::with_config(&destination, Config::default()).is_ok());
    }

    #[test]
    fn a_dangling_database_link_is_not_treated_as_a_fresh_install() {
        let root = tempfile::tempdir().unwrap();
        let legacy = root.path().join("Twine");
        let destination = root.path().join("Handshake");
        fs::create_dir(&legacy).unwrap();
        std::os::unix::fs::symlink("/missing", legacy.join("twine.db")).unwrap();
        assert!(matches!(
            migrate_data_directory(&legacy, &destination),
            Err(DataMigrationError::Invalid { .. })
        ));
        assert!(!destination.exists());
        assert!(legacy.join("twine.db").is_symlink());
    }

    #[test]
    fn invalid_source_destination_and_corrupt_database_are_actionable() {
        let root = tempfile::tempdir().unwrap();
        let legacy = root.path().join("Twine");
        let destination = root.path().join("Handshake");
        fs::write(&legacy, "not a directory").unwrap();
        assert!(migrate_data_directory(&legacy, &destination).is_err());
        fs::remove_file(&legacy).unwrap();
        fs::create_dir(&legacy).unwrap();
        fs::write(legacy.join("twine.db"), b"invalid sqlite").unwrap();
        let error = migrate_data_directory(&legacy, &destination).unwrap_err();
        assert!(error.to_string().contains("retained"));
        assert!(!destination.exists());
        fs::write(&destination, "occupied").unwrap();
        assert!(migrate_data_directory(&legacy, &destination).is_err());
        assert_eq!(fs::read(&destination).unwrap(), b"occupied");
        assert!(migrate_data_directory(&legacy, &legacy.join("nested")).is_err());
        assert!(migrate_data_directory(Path::new("relative"), &destination).is_err());
    }
}
