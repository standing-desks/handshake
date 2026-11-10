//! Restored conversations get fresh PTYs; recorded output and interrupted traces stay immutable.

use std::path::Path;
use std::sync::Arc;

use super::{Application, ApplicationError};
use crate::event::{CommandResult, EventKind, StateEvent};
use crate::harness::resume;
use crate::{TerminalId, TerminalSize, TerminalStatus, Workflow, WorkflowKind, WorkflowStatus};

pub(super) const RESTORED_SIZE: TerminalSize = TerminalSize {
    rows: 24,
    columns: 80,
    pixel_width: 800,
    pixel_height: 480,
};

impl Application {
    pub(super) fn retire_completed_harness_hooks(
        &self,
        workflow: &Workflow,
    ) -> Result<(), ApplicationError> {
        let mut recordings = self
            .harness_steps
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?;
        for terminal in workflow
            .terminal_history
            .iter()
            .map(|entry| entry.terminal_id)
            .chain(workflow.terminal_ids())
        {
            if !self.terminals.is_harness_running(terminal) {
                recordings.remove(&terminal);
            }
        }
        Ok(())
    }

    pub(super) fn recorded_agent_session(
        store: &crate::store::Store,
        workflow: &Workflow,
        agent: Option<crate::AgentId>,
        terminal: TerminalId,
    ) -> Result<Option<String>, ApplicationError> {
        if let Some(session) = store.harness_session(terminal)? {
            return Ok(Some(session));
        }
        for previous in workflow
            .terminal_history
            .iter()
            .rev()
            .filter(|entry| entry.agent_id == agent)
        {
            if let Some(session) = store.harness_session(previous.terminal_id)? {
                return Ok(Some(session));
            }
        }
        Ok(None)
    }

    #[expect(
        clippy::too_many_lines,
        reason = "recovery validates identity before choosing shell restart or exact resume"
    )]
    pub(super) fn recover_agent(
        &self,
        workflow_id: crate::WorkflowId,
        agent_id: Option<crate::AgentId>,
        requested: Option<&str>,
        shell_only: bool,
    ) -> Result<super::CommandDisposition, ApplicationError> {
        let (saved, folder, previous, harness) = {
            let inner = self.lock_inner()?;
            let Some(workflow) = inner
                .workflows
                .workflows
                .iter()
                .find(|workflow| workflow.workflow_id == workflow_id)
            else {
                return Ok(super::workflows::reject(
                    "workflowNotFound",
                    "The workflow is no longer open.",
                ));
            };
            if workflow.kind == WorkflowKind::Agents && agent_id.is_none() {
                return Ok(super::workflows::reject(
                    "agentRequired",
                    "Choose the agent whose shell or conversation should recover.",
                ));
            }
            let tab =
                agent_id.and_then(|id| workflow.agents.iter().find(|agent| agent.agent_id == id));
            if agent_id.is_some() && tab.is_none() {
                return Ok(super::workflows::reject(
                    "agentNotFound",
                    "The agent is no longer open.",
                ));
            }
            let terminal = tab.map_or(workflow.terminal_id, |agent| agent.terminal_id);
            let harness = agent_id
                .and_then(|id| {
                    workflow
                        .run
                        .as_ref()?
                        .agents
                        .iter()
                        .find(|agent| agent.agent_id == id.0)
                        .map(|agent| agent.harness)
                })
                .or(workflow.harness);
            if harness == Some(crate::HarnessId::Nouli) {
                return Ok(super::workflows::reject(
                    "notInteractive",
                    "Decision roles use their decision controls rather than a terminal.",
                ));
            }
            let folder = inner
                .workflows
                .sessions
                .iter()
                .find(|session| session.session_id == workflow.session_id)
                .ok_or(ApplicationError::Poisoned)?
                .folder
                .clone();
            (workflow.clone(), folder, terminal, harness)
        };
        self.terminals.poll_program_exits();
        if self.terminals.is_harness_running(previous) {
            return Ok(super::workflows::reject(
                "agentAlreadyRunning",
                "This agent is already running.",
            ));
        }
        if shell_only {
            if self.terminals.is_running(previous) {
                return Ok(super::CommandDisposition::Accepted);
            }
            let reserved = self.terminals.reserve_terminal()?;
            let terminal = self.start_terminal(reserved, &folder, RESTORED_SIZE, true)?;
            let mut inner = self.lock_inner()?;
            let index = inner
                .workflows
                .workflows
                .iter()
                .position(|workflow| workflow.workflow_id == workflow_id)
                .ok_or(ApplicationError::Poisoned)?;
            let mut workflow = inner.workflows.workflows[index].clone();
            if let Some(id) = agent_id {
                workflow
                    .agents
                    .iter_mut()
                    .find(|agent| agent.agent_id == id)
                    .expect("validated agent")
                    .terminal_id = terminal;
            } else {
                workflow.terminal_id = terminal;
            }
            if previous.value() != 0 {
                workflow.terminal_history.push(crate::WorkflowTerminal {
                    terminal_id: previous,
                    agent_id,
                });
            }
            if matches!(workflow.kind, WorkflowKind::Terminal | WorkflowKind::Draft)
                || (workflow.kind == WorkflowKind::Agents && workflow.run.is_none())
            {
                workflow.status = WorkflowStatus::Running;
                workflow.ended_at = None;
            }
            workflow.restored = true;
            inner.terminals.insert(terminal, TerminalStatus::Running);
            if workflow.run.is_some() {
                inner.publish_run_best_effort(index, workflow)?;
            } else {
                if let Err(error) = inner.folders.store().remember_terminals(&workflow) {
                    tracing::warn!(%error, "could not persist the recovered shell; keeping its pane usable");
                }
                inner.workflows.workflows[index] = workflow.clone();
                inner
                    .events
                    .append(EventKind::State(StateEvent::WorkflowChanged(workflow)))?;
            }
            return Ok(super::CommandDisposition::Accepted);
        }
        let session = requested
            .filter(|value| !value.trim().is_empty())
            .map(str::to_owned)
            .or(Self::recorded_agent_session(
                self.lock_inner()?.folders.store(),
                &saved,
                agent_id,
                previous,
            )?);
        let Some(session) = session else {
            return Ok(super::workflows::reject(
                "sessionUnavailable",
                "No exact conversation was recorded. Enter its session ID to resume; the shell remains available.",
            ));
        };
        let Some(harness) = harness else {
            return Ok(super::workflows::reject(
                "harnessUnavailable",
                "This pane has no recorded agent harness.",
            ));
        };
        if resume::arguments(harness, &session).is_none() {
            return Ok(super::workflows::reject(
                "invalidSession",
                "Enter a valid exact conversation ID or absolute session file path.",
            ));
        }
        self.harness_steps
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?
            .remove(&previous);
        if let Some(id) = agent_id {
            if !self
                .run_processes
                .lock()
                .map_err(|_| ApplicationError::Poisoned)?
                .contains_key(&workflow_id)
            {
                self.resume_workflow_run(&saved, &folder)?;
            }
            let located = self.locate_harness(harness.definition())?;
            {
                let mut processes = self
                    .run_processes
                    .lock()
                    .map_err(|_| ApplicationError::Poisoned)?;
                let Some(processes) = processes.get_mut(&workflow_id) else {
                    return Ok(super::workflows::reject(
                        "agentResumeUnavailable",
                        "Couldn't prepare this conversation.",
                    ));
                };
                processes.harnesses.insert(harness, located);
                processes.resumed_sessions.insert(id, session);
            }
            self.launch_private_conversations(workflow_id)?;
        } else {
            self.resume_single_agent(&saved, &folder, Some(&session))?;
        }
        Ok(super::CommandDisposition::Accepted)
    }

    pub(super) fn resume_agent(
        &self,
        request_id: super::RequestId,
        workflow_id: crate::WorkflowId,
        session: &str,
    ) -> Result<super::CommandDisposition, ApplicationError> {
        let session = session.trim();
        let (saved, folder) = {
            let inner = self.lock_inner()?;
            let Some(workflow) = inner
                .workflows
                .workflows
                .iter()
                .find(|w| w.workflow_id == workflow_id)
            else {
                return Ok(super::workflows::reject(
                    "workflowNotFound",
                    "The workflow is no longer open.",
                ));
            };
            if workflow.kind != WorkflowKind::SingleAgent
                || self.terminals.is_harness_running(workflow.terminal_id)
            {
                return Ok(super::workflows::reject(
                    "agentNotStopped",
                    "Only a stopped agent can be resumed.",
                ));
            }
            if workflow
                .harness
                .and_then(|h| resume::arguments(h, session))
                .is_none()
            {
                return Ok(super::workflows::reject(
                    "invalidSession",
                    "Enter a valid harness session ID or absolute session file path.",
                ));
            }
            let Some(folder) = inner
                .workflows
                .sessions
                .iter()
                .find(|s| s.session_id == workflow.session_id)
            else {
                return Ok(super::workflows::reject(
                    "workflowNotFound",
                    "The session is no longer open.",
                ));
            };
            (workflow.clone(), folder.folder.clone())
        };
        if let Err(error) = self.resume_single_agent(&saved, &folder, Some(session)) {
            return Ok(super::rejection("agentResumeFailed", &error));
        }
        self.lock_inner()?
            .events
            .append(EventKind::CommandCompleted {
                request_id,
                result: CommandResult::AgentStarted { workflow_id },
            })?;
        Ok(super::CommandDisposition::Accepted)
    }

    pub(super) fn resume_restored_agents(&self, folder: &Path) -> Result<(), ApplicationError> {
        let workflows = self.lock_inner()?.workflows.workflows.clone();
        for workflow in workflows {
            if workflow.archived {
                continue;
            }
            if workflow.run.is_some() {
                if let Err(error) = self.resume_workflow_run(&workflow, folder) {
                    tracing::warn!(%error, "couldn't resume workflow agent sessions");
                }
                continue;
            }
            if workflow.kind != WorkflowKind::SingleAgent
                || !matches!(
                    workflow.status,
                    WorkflowStatus::Interrupted | WorkflowStatus::Exited
                )
            {
                continue;
            }
            if let Err(error) = self.resume_single_agent(&workflow, folder, None) {
                tracing::warn!(%error, workflow_id = workflow.workflow_id.0, "couldn't resume agent session");
            }
        }
        Ok(())
    }

    #[expect(
        clippy::too_many_lines,
        reason = "Resume keeps profile lease and terminal failure cleanup paired"
    )]
    fn resume_single_agent(
        &self,
        saved: &Workflow,
        folder: &Path,
        requested: Option<&str>,
    ) -> Result<(), ApplicationError> {
        let Some(harness) = saved.harness else {
            return Ok(());
        };
        let session = requested
            .map(str::to_owned)
            .or(Self::recorded_agent_session(
                self.lock_inner()?.folders.store(),
                saved,
                None,
                saved.terminal_id,
            )?);
        let Some(session) = session else {
            return Ok(());
        };
        let Some(resume_args) = resume::arguments(harness, &session) else {
            return Ok(());
        };
        self.retire_completed_harness_hooks(saved)?;
        let located = self.locate_harness(harness.definition())?;
        let history = self
            .lock_inner()?
            .folders
            .store()
            .terminal_history(saved.workflow_id)?;
        let reserved = if self.terminals.is_running(saved.terminal_id) {
            saved.terminal_id
        } else {
            self.terminals.reserve_terminal()?
        };
        if harness == crate::HarnessId::Kiro && !self.terminals.is_running(saved.terminal_id) {
            self.harness_steps
                .lock()
                .map_err(|_| ApplicationError::Poisoned)?
                .remove(&saved.terminal_id);
        }
        let saved_options = self
            .lock_inner()?
            .folders
            .store()
            .agent_options(saved.workflow_id)?;
        let options = saved_options
            .as_ref()
            .and_then(|options| {
                crate::harness::launch::validate_options(
                    harness,
                    options.model.as_deref(),
                    options.effort.as_deref(),
                    options.yolo,
                )
            })
            .unwrap_or_default();
        let (mut arguments, hooks) =
            match self.harness_arguments(harness, reserved, options, "", Some(&session)) {
                Ok(prepared) => prepared,
                Err(error) => {
                    let _ = self.terminals.cancel_reserved_terminal(reserved);
                    return Err(crate::StoreError::TracePayload(error).into());
                }
            };
        let (memory_environment, memory_lease) =
            match self.resume_memory_environment(harness, folder, &session) {
                Ok(values) => values,
                Err(error) => {
                    let _ = self.terminals.cancel_reserved_terminal(reserved);
                    return Err(crate::StoreError::TracePayload(error).into());
                }
            };
        if let Err(error) =
            Self::append_memory_settings(harness, &memory_environment, &mut arguments)
                .and_then(|()| {
                    self.append_memory_context(
                        harness,
                        folder,
                        &memory_environment,
                        &mut arguments,
                        hooks.as_ref(),
                    )
                })
                .and_then(|()| {
                    Self::append_agent_instructions(
                        harness,
                        ("", self.browser_control.is_enabled()),
                        &mut arguments,
                        hooks.as_ref(),
                        &located,
                        folder,
                    )
                })
        {
            let _ = self.terminals.cancel_reserved_terminal(reserved);
            return Err(crate::StoreError::TracePayload(error).into());
        }
        arguments.extend(resume_args);
        let mut inner = self.lock_inner()?;
        let id = self.terminals.start_managed_program(
            reserved,
            folder,
            &located.program,
            &arguments,
            &located.path,
            &crate::harness::launch::observed_environment(harness, hooks.as_ref())
                .into_iter()
                .chain(
                    memory_environment
                        .iter()
                        .filter(|(key, _)| key != "HANDSHAKE_CLAUDE_MEMORY_DIRECTORY")
                        .map(|(k, v)| (k.as_str(), v.as_str())),
                )
                .collect::<Vec<_>>(),
            RESTORED_SIZE,
            Arc::new(self.memory_exit_callback(memory_lease)),
            Arc::new(self.exit_callback()),
        )?;
        let mut workflow = saved.clone();
        workflow.restored = true;
        workflow.archived = false;
        workflow.terminal_history = history
            .into_iter()
            .filter(|entry| entry.terminal_id != id)
            .collect();
        workflow.terminal_id = id;
        workflow.status = WorkflowStatus::Running;
        workflow.started_at = crate::workflow::timestamp();
        workflow.ended_at = None;
        let recorded = inner.start_agent_trace(
            &workflow,
            harness,
            TerminalId::from_value(0),
            None,
            Some(&session),
        );
        if let Err(error) = recorded {
            drop(inner);
            if id != saved.terminal_id {
                let _ = self.terminals.close(id);
            }
            return Err(error);
        }
        let retire_previous =
            id != saved.terminal_id && inner.terminals.remove(&saved.terminal_id).is_some();
        inner.terminals.insert(id, TerminalStatus::Running);
        if let Some(current) = inner
            .workflows
            .workflows
            .iter_mut()
            .find(|w| w.workflow_id == workflow.workflow_id)
        {
            *current = workflow.clone();
        }
        inner
            .events
            .append(EventKind::State(StateEvent::WorkflowChanged(workflow)))?;
        drop(inner);
        if retire_previous {
            let _ = self.terminals.close_in_background(saved.terminal_id);
        }
        if let Some(hooks) = hooks
            && let Err(error) = self.register_harness_steps(id, saved.workflow_id, true, hooks)
        {
            tracing::warn!(%error, "couldn't register resumed harness hooks");
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;
    use std::time::{Duration, Instant};

    use super::*;
    use crate::{Command, CommandDisposition, HarnessId, RequestId, WorkflowId};

    fn accepted(app: &Application, command: Command) {
        assert_eq!(
            app.handle_command(RequestId(1), command)
                .unwrap()
                .disposition,
            CommandDisposition::Accepted
        );
    }

    fn fixture(folder: &Path, bin: &Path) -> Application {
        for harness in [
            HarnessId::Codex,
            HarnessId::ClaudeCode,
            HarnessId::Pi,
            HarnessId::Antigravity,
            HarnessId::Omp,
            HarnessId::Opencode,
        ] {
            let path = bin.join(harness.definition().binary);
            std::fs::write(&path, r#"#!/bin/sh
if [ "$1" = app-server ]; then
  read -r line
  printf '%s\n' '{"id":1,"result":{}}'
  read -r line
  read -r line
  printf '%s\n' '{"id":2,"result":{"config":{"developer_instructions":"Existing resume instruction"}}}'
  exit
fi
printf 'ARG:%s\n' "$@"
printf 'READY\n'
while IFS= read -r line; do printf 'INPUT:%s\n' "$line"; done
"#).unwrap();
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let mut app = Application::with_event_capacity(4096).unwrap();
        app.browser_control.set_enabled(true);
        app.harness_path = Some(bin.as_os_str().to_owned());
        accepted(
            &app,
            Command::OpenFolder {
                path: folder.to_owned(),
            },
        );
        app
    }

    fn workflow(app: &Application, id: WorkflowId) -> Workflow {
        app.snapshot()
            .unwrap()
            .workflows
            .workflows
            .into_iter()
            .find(|w| w.workflow_id == id)
            .unwrap()
    }

    fn start(app: &Application, folder: &Path, harness: HarnessId) -> Workflow {
        accepted(
            app,
            Command::CreateWorkflow {
                folder: folder.to_owned(),
                session_id: None,
                kind: WorkflowKind::Draft,
                roles: vec![],
                size: RESTORED_SIZE,
            },
        );
        let id = app
            .snapshot()
            .unwrap()
            .workflows
            .workflows
            .last()
            .unwrap()
            .workflow_id;
        accepted(
            app,
            Command::StartAgent {
                workflow_id: id,
                harness,
                model: None,
                effort: None,
                yolo: false,
                prompt: "Original task".into(),
                size: RESTORED_SIZE,
            },
        );
        workflow(app, id)
    }

    fn output(app: &Application, terminal: TerminalId, needle: &str) -> String {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let crate::TranscriptRead::Output(page) =
                app.read_terminal_transcript(terminal, 0, 65536).unwrap()
            else {
                panic!("transcript should remain readable")
            };
            let text = String::from_utf8_lossy(&page.bytes).into_owned();
            if text.contains(needle) {
                return text;
            }
            assert!(Instant::now() < deadline, "missing {needle:?} in {text:?}");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn explicit_resume_updates_the_exact_handle_in_a_reused_shell_without_hooks() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = fixture(folder.path(), bin.path());
        let original = start(&app, folder.path(), HarnessId::Codex);
        output(&app, original.terminal_id, "READY");
        app.lock_inner()
            .unwrap()
            .folders
            .store()
            .remember_harness_session(original.terminal_id, "conversation-a")
            .unwrap();
        for (round, requested) in [Some("conversation-b".to_owned()), None]
            .into_iter()
            .enumerate()
        {
            accepted(
                &app,
                Command::ForceStopAgent {
                    workflow_id: original.workflow_id,
                },
            );
            accepted(
                &app,
                Command::RecoverAgent {
                    workflow_id: original.workflow_id,
                    agent_id: None,
                    session: requested,
                    shell_only: false,
                },
            );
            assert_eq!(
                workflow(&app, original.workflow_id).terminal_id,
                original.terminal_id
            );
            let marker = format!("ready-for-next-round-{round}");
            app.write_terminal_input(original.terminal_id, format!("{marker}\r").as_bytes())
                .unwrap();
            output(&app, original.terminal_id, &format!("INPUT:{marker}"));
            assert_eq!(
                app.lock_inner()
                    .unwrap()
                    .folders
                    .store()
                    .harness_session(original.terminal_id)
                    .unwrap()
                    .as_deref(),
                Some("conversation-b")
            );
        }
        app.write_terminal_input(original.terminal_id, b"still interactive\r")
            .unwrap();
        output(&app, original.terminal_id, "INPUT:still interactive");
    }

    #[test]
    fn restart_shell_then_resume_uses_the_recorded_conversation_in_the_same_pane() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = fixture(folder.path(), bin.path());
        let original = start(&app, folder.path(), HarnessId::Codex);
        app.lock_inner()
            .unwrap()
            .folders
            .store()
            .remember_harness_session(original.terminal_id, "exact-conversation")
            .unwrap();
        app.terminals.terminate(original.terminal_id).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while workflow(&app, original.workflow_id).status == WorkflowStatus::Running {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        }
        accepted(
            &app,
            Command::RecoverAgent {
                workflow_id: original.workflow_id,
                agent_id: None,
                session: None,
                shell_only: true,
            },
        );
        let shell = workflow(&app, original.workflow_id).terminal_id;
        assert_ne!(shell, original.terminal_id);
        accepted(
            &app,
            Command::RecoverAgent {
                workflow_id: original.workflow_id,
                agent_id: None,
                session: None,
                shell_only: false,
            },
        );
        assert_eq!(workflow(&app, original.workflow_id).terminal_id, shell);
        let text = output(&app, shell, "READY");
        assert!(text.contains("exact-conversation"), "{text}");
    }

    #[test]
    fn failed_resume_keeps_the_old_handle_and_success_retires_the_previous_terminal() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = fixture(folder.path(), bin.path());
        let original = start(&app, folder.path(), HarnessId::Codex);
        app.terminals.terminate(original.terminal_id).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while workflow(&app, original.workflow_id).status == WorkflowStatus::Running {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        }
        let old_history = app
            .lock_inner()
            .unwrap()
            .folders
            .store()
            .terminal_history(original.workflow_id)
            .unwrap();
        app.lock_inner().unwrap().folders.store().execute_test_sql(
            "CREATE TRIGGER fail_resume BEFORE INSERT ON workflow_terminals WHEN NEW.harness_session IS NOT NULL BEGIN SELECT RAISE(FAIL, 'session save failed'); END");
        let rejected = app
            .handle_command(
                RequestId(3),
                Command::ResumeAgent {
                    workflow_id: original.workflow_id,
                    session: "exact-session".into(),
                },
            )
            .unwrap();
        assert!(matches!(
            rejected.disposition,
            CommandDisposition::Rejected { .. }
        ));
        assert_eq!(
            workflow(&app, original.workflow_id).status,
            WorkflowStatus::Interrupted
        );
        assert_eq!(
            app.lock_inner()
                .unwrap()
                .folders
                .store()
                .terminal_history(original.workflow_id)
                .unwrap(),
            old_history
        );
        app.lock_inner()
            .unwrap()
            .folders
            .store()
            .execute_test_sql("DROP TRIGGER fail_resume");
        accepted(
            &app,
            Command::ResumeAgent {
                workflow_id: original.workflow_id,
                session: "exact-session".into(),
            },
        );
        let resumed = workflow(&app, original.workflow_id);
        assert_ne!(resumed.terminal_id, original.terminal_id);
        let deadline = Instant::now() + Duration::from_secs(5);
        while app.terminals.size(original.terminal_id).is_some() {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(
            !app.lock_inner()
                .unwrap()
                .terminals
                .contains_key(&original.terminal_id)
        );
    }

    #[test]
    fn restored_harnesses_resume_exact_conversations_and_keep_terminal_history() {
        for harness in [
            HarnessId::Codex,
            HarnessId::ClaudeCode,
            HarnessId::Pi,
            HarnessId::Antigravity,
            HarnessId::Omp,
            HarnessId::Opencode,
        ] {
            let folder = tempfile::tempdir().unwrap();
            let bin = tempfile::tempdir().unwrap();
            let app = fixture(folder.path(), bin.path());
            let original = start(&app, folder.path(), harness);
            output(&app, original.terminal_id, "READY");
            let session = if matches!(harness, HarnessId::Pi | HarnessId::Omp) {
                "/tmp/agent session.jsonl"
            } else {
                "exact-session-1"
            };
            app.lock_inner()
                .unwrap()
                .folders
                .store()
                .remember_harness_session(original.terminal_id, session)
                .unwrap();
            accepted(&app, Command::CloseFolder);
            accepted(
                &app,
                Command::OpenFolder {
                    path: folder.path().to_owned(),
                },
            );
            let resumed = workflow(&app, original.workflow_id);
            assert_eq!(resumed.status, WorkflowStatus::Running);
            assert!(resumed.restored);
            assert_ne!(resumed.terminal_id, original.terminal_id);
            assert_eq!(resumed.terminal_ids(), [resumed.terminal_id]);
            assert!(
                resumed
                    .terminal_history
                    .iter()
                    .any(|entry| entry.terminal_id == original.terminal_id)
            );
            let text = output(&app, resumed.terminal_id, "READY");
            assert!(text.contains(&format!("ARG:{session}")), "{text}");
            assert!(!text.contains("Original task"));
            app.write_terminal_input(resumed.terminal_id, b"follow-up\n")
                .unwrap();
            output(&app, resumed.terminal_id, "INPUT:follow-up");
            accepted(
                &app,
                Command::CloseWorkflow {
                    workflow_id: resumed.workflow_id,
                },
            );
            assert_eq!(app.snapshot().unwrap().workflows.workflows, []);
            assert!(app.terminals.size(resumed.terminal_id).is_none());
        }
    }

    #[test]
    fn missing_handles_remain_archived_until_an_exact_session_is_supplied() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = fixture(folder.path(), bin.path());
        let original = start(&app, folder.path(), HarnessId::Antigravity);
        accepted(&app, Command::CloseFolder);
        accepted(
            &app,
            Command::OpenFolder {
                path: folder.path().to_owned(),
            },
        );
        assert!(
            app.terminals
                .is_running(workflow(&app, original.workflow_id).terminal_id)
        );
        let invalid = app
            .handle_command(
                RequestId(2),
                Command::ResumeAgent {
                    workflow_id: original.workflow_id,
                    session: "--continue".into(),
                },
            )
            .unwrap();
        assert!(matches!(
            invalid.disposition,
            CommandDisposition::Rejected { .. }
        ));
        accepted(
            &app,
            Command::ResumeAgent {
                workflow_id: original.workflow_id,
                session: "chosen-session".into(),
            },
        );
        let resumed = workflow(&app, original.workflow_id);
        let text = output(&app, resumed.terminal_id, "READY");
        assert!(
            text.contains("ARG:--conversation\r\nARG:chosen-session"),
            "{text}"
        );
        assert_ne!(resumed.terminal_id, original.terminal_id);
        let again = app
            .handle_command(
                RequestId(3),
                Command::ResumeAgent {
                    workflow_id: original.workflow_id,
                    session: "another-session".into(),
                },
            )
            .unwrap();
        assert!(matches!(
            again.disposition,
            CommandDisposition::Rejected { .. }
        ));
    }
}
