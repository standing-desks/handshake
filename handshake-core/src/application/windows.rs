use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

use super::{Application, ApplicationError, DEFAULT_EVENT_CAPACITY, database_path};
use crate::config::Config;
use crate::folder::Folders;
use crate::store::Store;
use crate::terminal::TranscriptRecorder;

struct WindowStorage {
    recorder: Arc<TranscriptRecorder>,
    windows: usize,
}

/// The registry owns the recorder until the last runtime has stopped its processes. Creation and
/// final shutdown share the lock, so a new window never races the previous recorder's owner lock.
static STORAGE: OnceLock<Mutex<HashMap<PathBuf, WindowStorage>>> = OnceLock::new();

pub(super) struct WindowStorageLease {
    path: PathBuf,
}

impl Drop for WindowStorageLease {
    fn drop(&mut self) {
        let mut storage = STORAGE
            .get_or_init(Mutex::default)
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(entry) = storage.get_mut(&self.path) {
            entry.windows -= 1;
            if entry.windows == 0 {
                entry.recorder.shutdown();
                storage.remove(&self.path);
            }
        }
    }
}

impl Application {
    /// Creates an independent window runtime sharing durable history with the other windows.
    /// Only the first runtime recovers interrupted work and restores a previously open folder.
    ///
    /// # Errors
    /// Returns an error if storage, recovery, or runtime initialization fails.
    pub fn new_window(data_directory: &Path) -> Result<Self, ApplicationError> {
        Config::prepare_user()?;
        std::fs::create_dir_all(data_directory).map_err(|source| {
            crate::store::StoreError::CreateDirectory {
                path: data_directory.into(),
                source,
            }
        })?;
        let path = std::fs::canonicalize(data_directory).map_err(|source| {
            crate::store::StoreError::ResolveDirectory {
                path: data_directory.into(),
                source,
            }
        })?;
        let mut storage = STORAGE
            .get_or_init(Mutex::default)
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?;
        let restore = !storage.contains_key(&path);
        let transcripts = match storage.get(&path) {
            Some(entry) => Arc::clone(&entry.recorder),
            None => Arc::new(TranscriptRecorder::open(&path.join("transcripts"))?),
        };
        let database = database_path(data_directory);
        let reconcile_transcripts = restore && database.try_exists().unwrap_or(false);
        let mut store = Store::open(&database)?;
        if restore {
            store.recover_interrupted_work()?;
            if reconcile_transcripts {
                super::prune_unreferenced_transcripts(&store, &transcripts);
            }
        }
        let folders = Folders::for_window(store, restore)?;
        let config = Config::load_user();
        let mut application = Self::with_folders(
            folders,
            config,
            DEFAULT_EVENT_CAPACITY,
            Arc::clone(&transcripts),
            true,
            Some(data_directory),
        )?;
        storage
            .entry(path.clone())
            .or_insert_with(|| WindowStorage {
                recorder: transcripts,
                windows: 0,
            })
            .windows += 1;
        application.window_storage = Some(WindowStorageLease { path });
        Ok(application)
    }

    /// Returns every folder that should reopen after app shutdown, including unavailable folders.
    ///
    /// # Errors
    /// Returns an error if the database or runtime state cannot be read.
    pub fn restorable_folders(&self) -> Result<Vec<PathBuf>, ApplicationError> {
        Ok(self.lock_inner()?.folders.restorable_paths()?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        Command, CommandDisposition, RequestId, TerminalSize, TerminalStatus, TranscriptRead,
        WorkflowKind,
    };
    use std::thread;

    #[test]
    fn startup_prunes_orphans_but_new_windows_preserve_live_unowned_terminals() {
        let data = tempfile::tempdir().unwrap();
        let folder = tempfile::tempdir().unwrap();
        let recorder = TranscriptRecorder::open(&data.path().join("transcripts")).unwrap();
        let kept = recorder.allocate().unwrap();
        let orphan = recorder.allocate().unwrap();
        let store = Store::open(&database_path(data.path())).unwrap();
        store.execute_test_sql(&format!("INSERT INTO sessions(id,folder,name,started_at) VALUES(1,'/history','History',1);
            INSERT INTO workflows(id,session_id,name,kind,closed_at) VALUES(1,1,'Closed','terminal',100);
            INSERT INTO workflow_terminals(terminal_id,workflow_id) VALUES({},1)", kept.value()));
        drop(store);
        drop(recorder);
        let first = Application::new_window(data.path()).unwrap();
        assert!(matches!(
            first.read_terminal_transcript(kept, 0, 8).unwrap(),
            TranscriptRead::Output(_)
        ));
        assert!(matches!(
            first.read_terminal_transcript(orphan, 0, 8).unwrap(),
            TranscriptRead::Expired { .. }
        ));
        let live = first.terminals.reserve_terminal().unwrap();
        let second = Application::new_window(data.path()).unwrap();
        assert!(matches!(
            second.read_terminal_transcript(live, 0, 8).unwrap(),
            TranscriptRead::Output(_)
        ));
        first.terminals.cancel_reserved_terminal(live).unwrap();
        open(&second, folder.path());
    }

    #[test]
    fn standalone_startup_skips_cleanup_without_an_existing_database() {
        let data = tempfile::tempdir().unwrap();
        let recorder = TranscriptRecorder::open(&data.path().join("transcripts")).unwrap();
        let id = recorder.allocate().unwrap();
        drop(recorder);
        let app = Application::with_config(data.path(), Config::default()).unwrap();
        assert!(matches!(
            app.read_terminal_transcript(id, 0, 8).unwrap(),
            TranscriptRead::Output(_)
        ));
        drop(app);
        let app = Application::with_config(data.path(), Config::default()).unwrap();
        assert!(matches!(
            app.read_terminal_transcript(id, 0, 8).unwrap(),
            TranscriptRead::Expired { .. }
        ));
    }

    #[test]
    fn uncertain_startup_ownership_preserves_recordings() {
        let data = tempfile::tempdir().unwrap();
        let recorder = TranscriptRecorder::open(&data.path().join("transcripts")).unwrap();
        let id = recorder.allocate().unwrap();
        drop(recorder);
        let store = Store::open(&database_path(data.path())).unwrap();
        store.execute_test_sql("INSERT INTO sessions(id,folder,name,started_at) VALUES(1,'/history','History',1);
            INSERT INTO workflows(id,session_id,name,kind,closed_at) VALUES(1,1,'Closed','terminal',100);
            INSERT INTO trace_lanes(id,workflow_id,lane_key,name,is_agent) VALUES(1,1,'terminal','Terminal',0);
            INSERT INTO trace_spans(id,lane_id,title,started_at,status) VALUES(1,1,'Step',1,'exited');
            INSERT INTO trace_activities(span_id,source_id,kind,title,status,input,output,anchor)
            VALUES(1,'tool','tool','Tool','completed','','','unreadable');");
        drop(store);
        let app = Application::with_config(data.path(), Config::default()).unwrap();
        assert!(matches!(
            app.read_terminal_transcript(id, 0, 8).unwrap(),
            TranscriptRead::Output(_)
        ));
    }

    #[test]
    fn failed_transcript_cleanup_does_not_fail_a_committed_session_deletion() {
        let data = tempfile::tempdir().unwrap();
        let folder = tempfile::tempdir().unwrap();
        let app = Application::new_window(data.path()).unwrap();
        open(&app, folder.path());
        app.handle_command(
            RequestId(98),
            Command::CreateSession {
                folder: folder.path().into(),
                name: "Session".into(),
            },
        )
        .unwrap();
        let session_id = app.snapshot().unwrap().workflows.sessions[0].session_id;
        let id = app.terminals.reserve_terminal().unwrap();
        app.terminals.cancel_reserved_terminal(id).unwrap();
        app.lock_inner().unwrap().folders.store().execute_test_sql(&format!(
            "INSERT INTO workflows(id,session_id,name,kind,closed_at) VALUES(100,{},'Closed','terminal',100);
             INSERT INTO workflow_terminals(terminal_id,workflow_id) VALUES({},100)", session_id.0, id.value()));
        let pending = data.path().join("transcripts/metadata.next");
        std::fs::create_dir(&pending).unwrap();
        let receipt = app
            .handle_command(RequestId(99), Command::DeleteSession { session_id })
            .unwrap();
        assert_eq!(receipt.disposition, CommandDisposition::Accepted);
        assert_eq!(app.snapshot().unwrap().workflows.sessions, []);
        drop(app);
        std::fs::remove_dir(pending).unwrap();
        let app = Application::new_window(data.path()).unwrap();
        assert!(matches!(
            app.read_terminal_transcript(id, 0, 8).unwrap(),
            TranscriptRead::Expired { .. }
        ));
    }

    #[test]
    fn deleting_a_session_prunes_closed_and_previous_invocations_without_affecting_other_windows() {
        let data = tempfile::tempdir().unwrap();
        let a = tempfile::tempdir().unwrap();
        let b = tempfile::tempdir().unwrap();
        let first = Application::new_window(data.path()).unwrap();
        open(&first, a.path());
        let historical = terminal(&first, a.path());
        first
            .handle_command(RequestId(3), Command::CloseFolder)
            .unwrap();
        open(&first, a.path());
        let state = first.snapshot().unwrap().workflows;
        let session_id = state.sessions[0].session_id;
        let restored = state.workflows[0].terminal_id;
        first
            .handle_command(
                RequestId(4),
                Command::CloseWorkflow {
                    workflow_id: state.workflows[0].workflow_id,
                },
            )
            .unwrap();
        let current = terminal(&first, a.path());
        let second = Application::new_window(data.path()).unwrap();
        open(&second, b.path());
        let survivor = terminal(&second, b.path());
        first
            .handle_command(RequestId(5), Command::DeleteSession { session_id })
            .unwrap();
        for id in [historical, restored, current] {
            assert!(matches!(
                first.read_terminal_transcript(id, 0, 8).unwrap(),
                TranscriptRead::Expired { .. }
            ));
        }
        assert!(matches!(
            second.read_terminal_transcript(survivor, 0, 8).unwrap(),
            TranscriptRead::Output(_)
        ));
        second
            .write_terminal_input(survivor, b"printf SURVIVES\n")
            .unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            let TranscriptRead::Output(page) =
                second.read_terminal_transcript(survivor, 0, 65536).unwrap()
            else {
                panic!("survivor expired");
            };
            if String::from_utf8_lossy(&page.bytes).contains("SURVIVES") {
                break;
            }
            assert!(std::time::Instant::now() < deadline);
            thread::sleep(std::time::Duration::from_millis(10));
        }
    }
    use std::time::{Duration, Instant};

    #[test]
    fn a_new_window_waits_for_final_recording_shutdown() {
        let data = tempfile::tempdir().unwrap();
        let folder = tempfile::tempdir().unwrap();
        let app = Application::new_window(data.path()).unwrap();
        open(&app, folder.path());
        let id = terminal(&app, folder.path());
        let stalled = app.terminal_output.stall_recording_worker(id);
        let key = std::fs::canonicalize(data.path()).unwrap();
        let recorder = Arc::clone(
            &STORAGE
                .get()
                .unwrap()
                .lock()
                .unwrap()
                .get(&key)
                .unwrap()
                .recorder,
        );
        let dropping = thread::spawn(move || drop(app));
        let deadline = Instant::now() + Duration::from_secs(5);
        while !recorder.is_shutting_down() {
            assert!(
                Instant::now() < deadline,
                "shutdown never acquired storage ownership"
            );
            thread::yield_now();
        }
        let path = data.path().to_owned();
        let (sender, receiver) = std::sync::mpsc::channel();
        let opening = thread::spawn(move || {
            let app = Application::new_window(&path);
            sender
                .send(
                    app.as_ref()
                        .map(|app| app.snapshot().unwrap().folders.open_folder.clone())
                        .map_err(ToString::to_string),
                )
                .unwrap();
        });
        assert!(matches!(
            receiver.recv_timeout(Duration::from_millis(25)),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout)
        ));
        drop(stalled);
        dropping.join().unwrap();
        assert_eq!(
            receiver
                .recv_timeout(Duration::from_secs(5))
                .unwrap()
                .unwrap()
                .as_deref(),
            Some(folder.path())
        );
        opening.join().unwrap();
    }

    #[test]
    fn an_additional_missing_restored_window_owns_and_closes_its_entry() {
        let data = tempfile::tempdir().unwrap();
        let missing = tempfile::tempdir().unwrap();
        let missing_path = missing.path().to_owned();
        let available = tempfile::tempdir().unwrap();
        let first = Application::new_window(data.path()).unwrap();
        open(&first, &missing_path);
        let second = Application::new_window(data.path()).unwrap();
        open(&second, available.path());
        drop(first);
        drop(second);
        drop(missing);
        let primary = Application::new_window(data.path()).unwrap();
        let restored = Application::new_window(data.path()).unwrap();
        assert_eq!(
            restored
                .handle_command(
                    RequestId(1),
                    Command::RestoreFolder {
                        path: missing_path.clone()
                    }
                )
                .unwrap()
                .disposition,
            CommandDisposition::Accepted
        );
        assert_eq!(
            restored
                .snapshot()
                .unwrap()
                .folders
                .unavailable_folder
                .unwrap()
                .path,
            missing_path
        );
        restored
            .handle_command(RequestId(2), Command::CloseFolder)
            .unwrap();
        assert_eq!(primary.restorable_folders().unwrap(), [available.path()]);
    }

    fn open(app: &Application, path: &Path) {
        assert_eq!(
            app.handle_command(RequestId(1), Command::OpenFolder { path: path.into() })
                .unwrap()
                .disposition,
            CommandDisposition::Accepted
        );
    }

    fn terminal(app: &Application, path: &Path) -> crate::TerminalId {
        app.handle_command(
            RequestId(2),
            Command::CreateWorkflow {
                folder: path.into(),
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
        )
        .unwrap();
        app.snapshot()
            .unwrap()
            .workflows
            .workflows
            .last()
            .unwrap()
            .terminal_ids()[0]
    }

    #[test]
    fn windows_share_history_without_recovering_or_stopping_live_work() {
        let data = tempfile::tempdir().unwrap();
        let a = tempfile::tempdir().unwrap();
        let b = tempfile::tempdir().unwrap();
        let first = Application::new_window(data.path()).unwrap();
        open(&first, a.path());
        let first_id = terminal(&first, a.path());
        let first_workflow = first.snapshot().unwrap().workflows.workflows[0].clone();
        let second = Application::new_window(data.path()).unwrap();
        assert!(second.snapshot().unwrap().folders.open_folder.is_none());
        open(&second, b.path());
        let second_id = terminal(&second, b.path());
        assert_ne!(first_id, second_id);
        assert_eq!(
            first.snapshot().unwrap().workflows.workflows[0],
            first_workflow
        );
        assert_eq!(first.restorable_folders().unwrap(), [b.path(), a.path()]);
        assert!(
            first
                .snapshot()
                .unwrap()
                .terminals
                .iter()
                .all(|t| t.status == TerminalStatus::Running)
        );

        second
            .handle_command(RequestId(3), Command::CloseFolder)
            .unwrap();
        drop(second);
        assert_eq!(first.restorable_folders().unwrap(), [a.path()]);
        first
            .write_terminal_input(first_id, b"printf surviving\\n\n")
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let TranscriptRead::Output(page) =
                first.read_terminal_transcript(first_id, 0, 4096).unwrap()
            else {
                panic!("output expected")
            };
            if String::from_utf8_lossy(&page.bytes).contains("surviving") {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "the remaining window stopped recording"
            );
            thread::sleep(Duration::from_millis(10));
        }
        drop(first);
        let relaunched = Application::new_window(data.path()).unwrap();
        assert_eq!(
            relaunched
                .snapshot()
                .unwrap()
                .folders
                .open_folder
                .as_deref(),
            Some(a.path())
        );
        assert_eq!(relaunched.restorable_folders().unwrap(), [a.path()]);
    }

    #[test]
    fn all_open_folders_restore_and_open_folders_survive_the_recent_limit() {
        let data = tempfile::tempdir().unwrap();
        let folders = (0..12)
            .map(|_| tempfile::tempdir().unwrap())
            .collect::<Vec<_>>();
        let mut windows = Vec::new();
        for folder in &folders {
            let app = Application::new_window(data.path()).unwrap();
            open(&app, folder.path());
            windows.push(app);
        }
        assert_eq!(windows[0].restorable_folders().unwrap().len(), 12);
        assert_eq!(
            windows[11].snapshot().unwrap().folders.recent_folders.len(),
            10
        );
        drop(windows);
        let app = Application::new_window(data.path()).unwrap();
        assert_eq!(app.restorable_folders().unwrap().len(), 12);
        assert_eq!(
            app.snapshot().unwrap().folders.open_folder.as_deref(),
            Some(folders[11].path())
        );
    }

    #[test]
    fn forgetting_another_windows_recent_folder_keeps_its_restore_entry() {
        let data = tempfile::tempdir().unwrap();
        let folder = tempfile::tempdir().unwrap();
        let first = Application::new_window(data.path()).unwrap();
        open(&first, folder.path());
        let second = Application::new_window(data.path()).unwrap();
        std::fs::remove_dir_all(folder.path()).unwrap();
        second
            .handle_command(
                RequestId(1),
                Command::RemoveRecentFolder {
                    path: folder.path().into(),
                },
            )
            .unwrap();
        assert_eq!(
            second.snapshot().unwrap().folders.recent_folders,
            Vec::new()
        );
        assert_eq!(second.restorable_folders().unwrap(), [folder.path()]);
        std::fs::create_dir_all(folder.path()).unwrap();
        drop(first);
        drop(second);
        let relaunched = Application::new_window(data.path()).unwrap();
        assert_eq!(
            relaunched
                .snapshot()
                .unwrap()
                .folders
                .open_folder
                .as_deref(),
            Some(folder.path())
        );
    }

    #[test]
    fn replacing_an_unavailable_restored_folder_clears_its_restore_entry() {
        let data = tempfile::tempdir().unwrap();
        let missing = tempfile::tempdir().unwrap();
        let path = missing.path().to_owned();
        let replacement = tempfile::tempdir().unwrap();
        let first = Application::new_window(data.path()).unwrap();
        open(&first, &path);
        drop(first);
        drop(missing);
        let restored = Application::new_window(data.path()).unwrap();
        assert_eq!(
            restored
                .snapshot()
                .unwrap()
                .folders
                .unavailable_folder
                .unwrap()
                .path,
            path
        );
        let rejected_path = data.path().join("also-missing");
        assert!(matches!(
            restored
                .handle_command(
                    RequestId(4),
                    Command::OpenFolder {
                        path: rejected_path
                    }
                )
                .unwrap()
                .disposition,
            CommandDisposition::Rejected { .. }
        ));
        open(&restored, replacement.path());
        assert_eq!(restored.restorable_folders().unwrap(), [replacement.path()]);
    }
}
