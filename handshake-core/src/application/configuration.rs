//! Configuration reloads publish state without changing any workflows or terminal processes.

use std::path::Path;

use super::{Application, ApplicationError, CommandDisposition};
use crate::config::{Config, ConfigProblem};
use crate::event::{EventKind, StateEvent};

impl Application {
    pub(super) fn reload_config(&self) -> Result<CommandDisposition, ApplicationError> {
        let Some(path) = Config::user_path() else {
            return Ok(CommandDisposition::Rejected {
                code: "invalidConfig".into(),
                message: "Cannot find the user config directory.".into(),
            });
        };
        self.reload_config_from(&path)
    }

    fn reload_config_from(&self, path: &Path) -> Result<CommandDisposition, ApplicationError> {
        if let Err(error) = Config::migrate_experimental(path) {
            return Ok(CommandDisposition::Rejected {
                code: "invalidConfig".into(),
                message: format!("Cannot apply settings: {error}"),
            });
        }
        let loaded = Config::load(path);
        for diagnostic in &loaded.diagnostics {
            if diagnostic.problem == ConfigProblem::UnknownKey {
                tracing::warn!(%diagnostic, "configuration warning");
            } else {
                return Ok(CommandDisposition::Rejected {
                    code: "invalidConfig".into(),
                    message: format!("Cannot apply settings: {diagnostic}"),
                });
            }
        }
        let mut inner = self.lock_inner()?;
        let enabled = loaded.config.experimental.cross_agent_memory_consolidation;
        let memory_changed = inner.config.experimental.cross_agent_memory_consolidation != enabled;
        if inner.config != loaded.config {
            inner
                .folders
                .store()
                .configure_trace_storage(&loaded.config.traces)?;
            inner
                .events
                .append(EventKind::State(StateEvent::ConfigChanged(Box::new(
                    loaded.config.clone(),
                ))))?;
            self.browser_control
                .set_enabled(loaded.config.experimental.browser_control);
            if !loaded.config.experimental.workflow_assistant {
                self.workflow_assistant.cancel_all();
            }
            inner.config = loaded.config;
        }
        drop(inner);
        if let Some(worker) = &self.memory_worker {
            worker.set_enabled(enabled)?;
            if enabled && memory_changed {
                for folder in self.restorable_folders()? {
                    self.register_memory_project(&folder);
                }
            }
        }
        Ok(CommandDisposition::Accepted)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disabling_workflow_assistant_cancels_active_generation() {
        use std::sync::atomic::Ordering;
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        let app = Application::with_event_capacity(32).unwrap();
        app.lock_inner()
            .unwrap()
            .config
            .experimental
            .workflow_assistant = true;
        let (started, ready) = std::sync::mpsc::channel();
        let (finished, done) = std::sync::mpsc::channel();
        app.workflow_assistant
            .start("active".into(), move |cancelled| {
                started.send(()).unwrap();
                let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
                while !cancelled.load(Ordering::Acquire) && std::time::Instant::now() < deadline {
                    std::thread::sleep(std::time::Duration::from_millis(10));
                }
                finished.send(cancelled.load(Ordering::Acquire)).unwrap();
            })
            .unwrap();
        ready
            .recv_timeout(std::time::Duration::from_secs(2))
            .unwrap();
        std::fs::write(&path, "[experimental]\nworkflow_assistant = false\n").unwrap();
        assert_eq!(
            app.reload_config_from(&path).unwrap(),
            CommandDisposition::Accepted
        );
        assert!(
            done.recv_timeout(std::time::Duration::from_secs(2))
                .unwrap()
        );
    }

    #[test]
    fn reload_applies_browser_flag_and_invalid_config_cannot_reenable_it() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        let app = Application::with_event_capacity(64).unwrap();
        assert!(!app.browser_control.is_enabled());
        for enabled in [true, false] {
            std::fs::write(
                &path,
                format!("[experimental]\nbrowser_control = {enabled}\n"),
            )
            .unwrap();
            assert_eq!(
                app.reload_config_from(&path).unwrap(),
                CommandDisposition::Accepted
            );
            assert_eq!(app.browser_control.is_enabled(), enabled);
        }
        std::fs::write(&path, "[experimental]\nbrowser_control = 'invalid'\n").unwrap();
        assert!(matches!(
            app.reload_config_from(&path).unwrap(),
            CommandDisposition::Rejected { .. }
        ));
        assert!(!app.browser_control.is_enabled());
    }

    #[test]
    fn reload_migrates_legacy_sections_and_newly_added_imports_before_publishing() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        let imported = directory.path().join("legacy.toml");
        let app = Application::with_event_capacity(64).unwrap();
        for source in [
            "[feature_flags]\ncross_agent_memory_consolidation = true\n",
            "import = 'legacy.toml'\n",
        ] {
            std::fs::write(&path, source).unwrap();
            std::fs::write(
                &imported,
                "[feature_flags]\ncross_agent_memory_consolidation = true\n",
            )
            .unwrap();
            assert_eq!(
                app.reload_config_from(&path).unwrap(),
                CommandDisposition::Accepted
            );
            assert!(
                app.snapshot()
                    .unwrap()
                    .config
                    .experimental
                    .cross_agent_memory_consolidation
            );
            assert!(
                !std::fs::read_to_string(&path)
                    .unwrap()
                    .contains("[feature_flags]")
            );
            if source.starts_with("import") {
                assert!(
                    std::fs::read_to_string(&imported)
                        .unwrap()
                        .contains("[experimental]")
                );
            }
        }
    }

    #[test]
    fn reload_publishes_atomic_config_changes_and_rejects_invalid_settings() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        let app = Application::with_event_capacity(64).unwrap();
        app.handle_command(
            super::super::RequestId(1),
            super::super::Command::StartTerminal {
                working_directory: directory.path().to_owned(),
                size: crate::TerminalSize {
                    rows: 24,
                    columns: 80,
                    pixel_width: 800,
                    pixel_height: 480,
                },
            },
        )
        .unwrap();
        let before = app.snapshot().unwrap();
        std::fs::write(
            &path,
            "[terminal]\nfont_size = 18\n[terminal.colors]\nblue = '#123456'\n",
        )
        .unwrap();
        assert_eq!(
            app.reload_config_from(&path).unwrap(),
            CommandDisposition::Accepted
        );
        let updated = app.snapshot().unwrap();
        assert_eq!(updated.config.terminal.font_size.points(), 18.0);
        assert_eq!(
            updated.config.terminal.palettes.dark.ansi[4].as_str(),
            "#123456"
        );
        assert_eq!(updated.workflows, before.workflows);
        assert_eq!(updated.terminals, before.terminals);
        assert_eq!(updated.terminals.len(), 1);
        let events = app.events_after(before.sequence, 64).unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].sequence, updated.sequence);
        assert_eq!(
            events[0].kind,
            EventKind::State(StateEvent::ConfigChanged(Box::new(updated.config.clone())))
        );
        assert_eq!(
            app.reload_config_from(&path).unwrap(),
            CommandDisposition::Accepted
        );
        assert_eq!(app.snapshot().unwrap().sequence, updated.sequence);
        for source in [
            "terminal.font_size = 100\n",
            "import = 'missing.toml'\n",
            "invalid = @\n",
        ] {
            std::fs::write(&path, source).unwrap();
            assert!(matches!(
                app.reload_config_from(&path).unwrap(),
                CommandDisposition::Rejected { .. }
            ));
            assert_eq!(app.snapshot().unwrap(), updated);
        }
    }
}
