//! User titles and explicit reopening of closed workflow history.
use super::{Application, ApplicationError, CommandDisposition, RequestId};
use crate::TerminalId;
use crate::event::{CommandResult, EventKind, StateEvent};
use crate::store::workflows::StoredWorkflow;
use crate::workflow::{Agent, Workflow, WorkflowId, WorkflowStatus, timestamp, valid_name};

impl Application {
    pub(super) fn archived_command_rejection(
        &self,
        command: &super::Command,
    ) -> Result<Option<CommandDisposition>, ApplicationError> {
        use super::Command;
        let id = match command {
            Command::ActivateWorkflow { workflow_id }
            | Command::NameDraftWorkflow { workflow_id, .. }
            | Command::StartAgent { workflow_id, .. }
            | Command::CancelAgent { workflow_id }
            | Command::StartWorkflowRun { workflow_id, .. }
            | Command::CompleteWorkflowRole { workflow_id, .. }
            | Command::ContinueWorkflowRun { workflow_id, .. }
            | Command::SetWorkflowIndividualMode { workflow_id, .. }
            | Command::SubmitWorkflowTask { workflow_id, .. }
            | Command::ChooseWorkflowResult { workflow_id, .. }
            | Command::CancelWorkflowRun { workflow_id } => *workflow_id,
            _ => return Ok(None),
        };
        Ok(self
            .lock_inner()?
            .workflows
            .workflows
            .iter()
            .any(|workflow| workflow.workflow_id == id && workflow.archived)
            .then(|| {
                super::workflows::reject(
                    "workflowArchived",
                    "This tab shows saved history. Start new work or explicitly resume its agent.",
                )
            }))
    }

    pub(super) fn rename_workflow(
        &self,
        id: WorkflowId,
        name: Option<&str>,
    ) -> Result<CommandDisposition, ApplicationError> {
        let mut inner = self.lock_inner()?;
        let name = name.map(str::trim);
        if name.is_some_and(|name| !valid_name(name)) {
            return Ok(super::workflows::reject(
                "invalidWorkflowName",
                "Use a name of 1–200 characters on one line.",
            ));
        }
        let Some(index) = inner
            .workflows
            .workflows
            .iter()
            .position(|w| w.workflow_id == id)
        else {
            return Ok(super::workflows::reject(
                "workflowNotFound",
                "The workflow is no longer open.",
            ));
        };
        inner.folders.store().rename_workflow(id, name)?;
        inner.workflows.workflows[index].custom_name = name.map(str::to_owned);
        let workflow = inner.workflows.workflows[index].clone();
        inner
            .events
            .append(EventKind::State(StateEvent::WorkflowChanged(workflow)))?;
        Ok(CommandDisposition::Accepted)
    }

    pub(super) fn reopen_workflow(
        &self,
        request_id: RequestId,
        id: WorkflowId,
    ) -> Result<CommandDisposition, ApplicationError> {
        let mut inner = self.lock_inner()?;
        let Some(folder) = inner.folders.state().open_folder.clone() else {
            return Ok(super::workflows::reject(
                "folderChanged",
                "Open the workflow's folder first.",
            ));
        };
        let Some(stored) = inner
            .folders
            .store()
            .load_workflows(&folder, Some(id))?
            .pop()
        else {
            return Ok(super::workflows::reject(
                "workflowNotFound",
                "This closed workflow is no longer available.",
            ));
        };
        let history = inner.folders.store().terminal_history(id)?;
        let workflow = archived_workflow(stored, history);
        let summary = inner.folders.store().trace_summary(id)?;
        inner.folders.store().reopen_workflow(id)?;
        inner.workflows.workflows.push(workflow.clone());
        inner
            .events
            .append(EventKind::State(StateEvent::WorkflowChanged(workflow)))?;
        inner
            .events
            .append(EventKind::State(StateEvent::TraceChanged(summary)))?;
        inner.events.append(EventKind::CommandCompleted {
            request_id,
            result: CommandResult::WorkflowReopened { workflow_id: id },
        })?;
        Ok(CommandDisposition::Accepted)
    }
}

pub(super) fn archived_workflow(
    mut stored: StoredWorkflow,
    history: Vec<crate::WorkflowTerminal>,
) -> Workflow {
    if let Some(run) = &mut stored.run
        && run.status == crate::RunStatus::Running
    {
        run.finish(
            crate::RunStatus::Interrupted,
            "Processes stopped when this workflow was closed.",
        );
    }
    let status = stored
        .run
        .as_ref()
        .map(|run| super::runs::workflow_status(run.status))
        .or(stored
            .agent_status
            .filter(|status| *status != WorkflowStatus::Running))
        .unwrap_or(WorkflowStatus::Interrupted);
    Workflow {
        workflow_id: stored.workflow_id,
        session_id: stored.session_id,
        name: stored.name,
        custom_name: stored.custom_name,
        archived: true,
        kind: stored.kind,
        harness: stored.harness,
        terminal_id: history
            .last()
            .map_or(TerminalId::from_value(0), |entry| entry.terminal_id),
        agents: stored
            .agents
            .into_iter()
            .map(|agent| Agent {
                agent_id: agent.agent_id,
                role: agent.role,
                terminal_id: history
                    .iter()
                    .rev()
                    .find(|entry| entry.agent_id == Some(agent.agent_id))
                    .map_or(TerminalId::from_value(0), |entry| entry.terminal_id),
            })
            .collect(),
        status,
        started_at: timestamp(),
        ended_at: Some(timestamp()),
        restored: true,
        terminal_history: history,
        run: stored.run,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;
    use crate::{Command, TerminalSize, WorkflowKind};
    use std::path::Path;

    fn open(data: &Path, folder: &Path) -> Application {
        let mut app = Application::with_config(data, Config::default()).unwrap();
        app.terminals.set_test_shell("/bin/sh".into());
        accepted(
            &app,
            Command::OpenFolder {
                path: folder.to_owned(),
            },
        );
        app
    }

    fn accepted(app: &Application, command: Command) {
        assert_eq!(
            app.handle_command(RequestId(100), command)
                .unwrap()
                .disposition,
            CommandDisposition::Accepted
        );
    }

    fn create(app: &Application, folder: &Path) -> WorkflowId {
        accepted(
            app,
            Command::CreateWorkflow {
                folder: folder.to_owned(),
                session_id: None,
                kind: WorkflowKind::Draft,
                roles: Vec::new(),
                size: TerminalSize {
                    rows: 24,
                    columns: 80,
                    pixel_width: 800,
                    pixel_height: 480,
                },
            },
        );
        app.snapshot()
            .unwrap()
            .workflows
            .workflows
            .last()
            .unwrap()
            .workflow_id
    }

    #[test]
    fn user_titles_survive_activation_restore_and_reset_without_changing_terminals() {
        let root = tempfile::tempdir().unwrap();
        let folder = tempfile::tempdir().unwrap();
        let app = open(root.path(), folder.path());
        let id = create(&app, folder.path());
        let terminal = app.snapshot().unwrap().workflows.workflows[0].terminal_id;
        accepted(
            &app,
            Command::RenameWorkflow {
                workflow_id: id,
                name: Some("  Fix café 🦀  ".into()),
            },
        );
        accepted(&app, Command::ActivateWorkflow { workflow_id: id });
        let workflow = app.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(workflow.name, "Terminal");
        assert_eq!(workflow.custom_name.as_deref(), Some("Fix café 🦀"));
        assert_eq!(workflow.terminal_id, terminal);
        for name in [" ".to_owned(), "bad\nname".into(), "x".repeat(201)] {
            assert!(matches!(
                app.handle_command(
                    RequestId(101),
                    Command::RenameWorkflow {
                        workflow_id: id,
                        name: Some(name)
                    }
                )
                .unwrap()
                .disposition,
                CommandDisposition::Rejected { .. }
            ));
        }
        drop(app);
        let app = open(root.path(), folder.path());
        assert_eq!(
            app.snapshot().unwrap().workflows.workflows[0]
                .custom_name
                .as_deref(),
            Some("Fix café 🦀")
        );
        accepted(
            &app,
            Command::RenameWorkflow {
                workflow_id: id,
                name: None,
            },
        );
        assert_eq!(
            app.snapshot().unwrap().workflows.workflows[0].custom_name,
            None
        );
    }

    #[test]
    fn reopening_is_history_only_even_after_relaunch_with_default_settings() {
        let root = tempfile::tempdir().unwrap();
        let folder = tempfile::tempdir().unwrap();
        let app = open(root.path(), folder.path());
        let id = create(&app, folder.path());
        accepted(&app, Command::ActivateWorkflow { workflow_id: id });
        let terminal = app.snapshot().unwrap().workflows.workflows[0].terminal_id;
        accepted(&app, Command::CloseWorkflow { workflow_id: id });
        accepted(&app, Command::ReopenWorkflow { workflow_id: id });
        let snapshot = app.snapshot().unwrap();
        assert_eq!(snapshot.terminals, []);
        let workflow = &snapshot.workflows.workflows[0];
        assert!(workflow.archived && workflow.terminal_ids().is_empty());
        assert!(
            workflow
                .terminal_history
                .iter()
                .any(|entry| entry.terminal_id == terminal)
        );
        assert!(matches!(
            app.handle_command(RequestId(101), Command::ReopenWorkflow { workflow_id: id })
                .unwrap()
                .disposition,
            CommandDisposition::Rejected { .. }
        ));
        drop(app);
        let app = open(root.path(), folder.path());
        let snapshot = app.snapshot().unwrap();
        assert_eq!(snapshot.terminals, []);
        assert!(snapshot.workflows.workflows[0].archived);
        accepted(&app, Command::CloseWorkflow { workflow_id: id });
        for command in [
            Command::ReopenWorkflow { workflow_id: id },
            Command::RenameWorkflow {
                workflow_id: id,
                name: Some("Title".into()),
            },
        ] {
            accepted(&app, command);
        }
    }

    #[test]
    fn reopening_rejects_another_folders_workflow_and_deleted_sessions() {
        let root = tempfile::tempdir().unwrap();
        let folder = tempfile::tempdir().unwrap();
        let other = tempfile::tempdir().unwrap();
        let app = open(root.path(), folder.path());
        let id = create(&app, folder.path());
        let session = app
            .snapshot()
            .unwrap()
            .workflows
            .session
            .unwrap()
            .session_id;
        accepted(&app, Command::CloseWorkflow { workflow_id: id });
        accepted(
            &app,
            Command::OpenFolder {
                path: other.path().to_owned(),
            },
        );
        assert!(matches!(
            app.handle_command(RequestId(101), Command::ReopenWorkflow { workflow_id: id })
                .unwrap()
                .disposition,
            CommandDisposition::Rejected { .. }
        ));
        accepted(
            &app,
            Command::OpenFolder {
                path: folder.path().to_owned(),
            },
        );
        accepted(
            &app,
            Command::DeleteSession {
                session_id: session,
            },
        );
        assert!(matches!(
            app.handle_command(RequestId(101), Command::ReopenWorkflow { workflow_id: id })
                .unwrap()
                .disposition,
            CommandDisposition::Rejected { .. }
        ));
    }
}
