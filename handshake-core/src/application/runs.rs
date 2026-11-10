use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::run_inputs::{AgentInput, RoutingStamp};
use super::workflows::reject;
use super::{Application, ApplicationError, CommandDisposition};
use crate::event::{EventKind, StateEvent};
use crate::harness::{HarnessId, LocatedHarness};
use crate::terminal::{TerminalId, TerminalSize, TerminalStatus};
use crate::workflow::{
    Agent, AgentId, Workflow, WorkflowId, WorkflowKind, WorkflowStatus, timestamp,
};
use crate::workflow_run::completion::{CompletionCommand, CompletionInbox};
use crate::workflow_run::{CompletionSignal, RoleLaunch, RunStatus, WorkflowRun};
use crate::workflow_type::{WorkflowCatalog, WorkflowType, WorkflowTypeRef};

pub(super) struct RunProcesses {
    pub(super) folder: PathBuf,
    pub(super) decisions: super::decisions::PendingDecisions,
    size: TerminalSize,
    pub(super) harnesses: HashMap<HarnessId, LocatedHarness>,
    inboxes: HashMap<AgentId, (u64, CompletionInbox)>,
    completion_commands: HashMap<AgentId, CompletionCommand>,
    completion_routing: HashMap<AgentId, CompletionRouting>,
    graph_submissions: HashMap<AgentId, (u64, Instant)>,
    pub(super) inputs: HashMap<TerminalId, Arc<Mutex<AgentInput>>>,
    /// Accepted helpers keep their receipt until they consume it; their harness remains alive.
    retired_inboxes: std::collections::VecDeque<(Instant, CompletionInbox)>,
    pub(super) resumed_sessions: HashMap<AgentId, String>,
}

const PROMPT_HOOK_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Clone, Copy)]
enum CompletionRouting {
    AwaitingSubmission(u64),
    AwaitingPrompt(u64, Instant),
    Active(u64),
    Private,
}

pub(super) struct WorkflowSubmission {
    workflow: WorkflowId,
    agent: AgentId,
    generation: u64,
    since: Instant,
}

type GraphSubmissions = HashMap<(WorkflowId, AgentId), (u64, Instant)>;

impl CompletionRouting {
    fn generation(&self) -> Option<u64> {
        match self {
            Self::AwaitingSubmission(generation)
            | Self::AwaitingPrompt(generation, _)
            | Self::Active(generation) => Some(*generation),
            Self::Private => None,
        }
    }
}

impl RunProcesses {
    fn disconnect_routes(&mut self) {
        for (agent, (_, inbox)) in std::mem::take(&mut self.inboxes) {
            inbox.disconnect();
            self.retire_inbox(inbox);
            self.completion_routing
                .insert(agent, CompletionRouting::Private);
        }
        self.graph_submissions.clear();
        for command in self.completion_commands.values() {
            command.deactivate();
        }
        for routing in self.completion_routing.values_mut() {
            *routing = CompletionRouting::Private;
        }
    }

    fn finish_assignment(&mut self, agent: AgentId, advance: bool) {
        if let Some(command) = self.completion_commands.get(&agent) {
            command.deactivate();
        }
        if let Some((_, inbox)) = self.inboxes.remove(&agent) {
            inbox.accept();
            self.retire_inbox(inbox);
        }
        if advance {
            for (_, (_, inbox)) in std::mem::take(&mut self.inboxes) {
                inbox.reject(
                    "This assignment ended before completion. Wait for your next assignment.",
                );
                self.retire_inbox(inbox);
            }
            for command in self.completion_commands.values() {
                command.deactivate();
            }
        }
    }

    fn continuation_prompt(
        &mut self,
        run: &WorkflowRun,
        agent: u64,
        inbox: &CompletionInbox,
        user: bool,
        previous_turn_finished: bool,
    ) -> std::io::Result<String> {
        if matches!(
            self.completion_routing.get(&AgentId(agent)),
            Some(CompletionRouting::Private)
        ) {
            // Earlier turns only know the deactivated stable command. Give fresh work its
            // own mailbox instead of ever rebinding that old command after a boundary.
            if user && run.mode_revision > 0 {
                return Ok(format!(
                    "{}\n\nThe user's message above is your current task. Include its full text in task when reporting your result.",
                    run.instructions(agent, &inbox.command())
                ));
            }
            let instructions = if user {
                "Continue with the user's next message.".to_owned()
            } else if run.mode_revision > 0 {
                format!(
                    "{}\n{}",
                    run.instructions(agent, &inbox.command()),
                    run.follow_up_instructions(agent)
                )
            } else {
                run.follow_up_instructions(agent)
            };
            return Ok(format!(
                "Use this completion command for the current assignment: {}\n{instructions}",
                inbox.command()
            ));
        }
        if run.graph.is_some() {
            let command = self.command_for(AgentId(agent), inbox)?;
            self.completion_commands[&AgentId(agent)].deactivate();
            self.completion_routing.insert(
                AgentId(agent),
                CompletionRouting::AwaitingSubmission(run.assignment_generation(agent)),
            );
            if user {
                return Ok(String::new());
            }
            return Ok(format!(
                "Use this completion command for this and later assignments: {command}\n{}",
                run.follow_up_instructions(agent)
            ));
        }
        if let Some(command) = self.completion_commands.get(&AgentId(agent)) {
            // Manual completion can advance while the old turn is still working. A prompt
            // attributed to this assignment activates its helper after older turns finish.
            command.deactivate();
            if previous_turn_finished
                && !matches!(
                    self.completion_routing.get(&AgentId(agent)),
                    Some(CompletionRouting::Private)
                )
            {
                self.completion_routing.insert(
                    AgentId(agent),
                    CompletionRouting::AwaitingSubmission(run.assignment_generation(agent)),
                );
                return Ok(if user {
                    String::new()
                } else {
                    run.follow_up_instructions(agent)
                });
            }
        }
        self.completion_routing
            .insert(AgentId(agent), CompletionRouting::Private);
        Ok(format!(
            "Use this completion command for the current assignment: {}\n{}",
            inbox.command(),
            if user {
                "Continue with the user's next message.".to_owned()
            } else {
                run.follow_up_instructions(agent)
            }
        ))
    }

    fn command_for(&mut self, agent: AgentId, inbox: &CompletionInbox) -> std::io::Result<String> {
        let command = match self.completion_commands.entry(agent) {
            std::collections::hash_map::Entry::Occupied(entry) => entry.into_mut(),
            std::collections::hash_map::Entry::Vacant(entry) => {
                entry.insert(CompletionCommand::new()?)
            }
        };
        command.bind(inbox)?;
        Ok(command.command())
    }

    fn retire_inbox(&mut self, inbox: CompletionInbox) {
        self.reap_inboxes();
        if inbox.receipt_pending() {
            // Normally one receipt per live agent is outstanding. Bound abandoned helpers too.
            if self.retired_inboxes.len() == 64 {
                self.retired_inboxes.pop_front();
            }
            self.retired_inboxes.push_back((Instant::now(), inbox));
        }
    }

    fn reap_inboxes(&mut self) {
        self.retired_inboxes.retain(|(accepted_at, inbox)| {
            inbox.receipt_pending() && accepted_at.elapsed() < Duration::from_secs(15)
        });
    }
}

fn workflow_launch_options(agent: &crate::RunAgent) -> crate::harness::launch::LaunchOptions<'_> {
    crate::harness::launch::validate_options(
        agent.harness,
        agent.model.as_deref(),
        agent.effort.as_deref(),
        agent.yolo,
    )
    .unwrap_or_else(|| {
        // A stored choice that no longer validates starts with the harness's defaults.
        tracing::warn!(
            agent_id = agent.agent_id,
            harness = ?agent.harness,
            "stored model choice no longer validates; starting with the harness defaults"
        );
        crate::harness::launch::LaunchOptions::default()
    })
}

fn final_review_feedback(
    agents: &[Agent],
    run: &WorkflowRun,
    reviewer_id: u64,
) -> Vec<(TerminalId, String)> {
    let ending = if run.work_completed() {
        "The review is complete. Wait for the user's next message."
    } else {
        "The review limit was reached. Discuss this feedback with the user before continuing."
    };
    run.final_review_messages(reviewer_id)
        .into_iter()
        .filter_map(|(target, message)| {
            let terminal = agents
                .iter()
                .find(|agent| agent.agent_id.0 == target)?
                .terminal_id;
            Some((terminal, format!("{message}\n{ending}\n")))
        })
        .collect()
}

struct PreparedAgent {
    agent: crate::RunAgent,
    inbox: CompletionInbox,
    reserved: TerminalId,
    arguments: Vec<std::ffi::OsString>,
    hooks: Option<crate::harness::steps::StepInbox>,
    /// Existing interactive agents receive the next assignment in their terminal.
    continuation: Option<String>,
    memory_environment: Vec<(String, String)>,
    memory_lease: Option<std::fs::File>,
}

impl Application {
    /// Lists built-in and stored custom types for launch forms.
    ///
    /// # Errors
    /// Returns an error when the catalog cannot be read.
    pub fn workflow_types(&self) -> Result<Vec<WorkflowType>, ApplicationError> {
        Ok(WorkflowCatalog::new(self.lock_inner()?.folders.store()).list()?)
    }

    pub(super) fn start_workflow_run(
        &self,
        workflow_id: WorkflowId,
        reference: WorkflowTypeRef,
        prompt: String,
        choices: &[RoleLaunch],
        size: TerminalSize,
    ) -> Result<CommandDisposition, ApplicationError> {
        let folder = match self.draft_folder(workflow_id)? {
            Ok(folder) => folder,
            Err(rejection) => return Ok(rejection),
        };
        let workflow_type =
            match WorkflowCatalog::new(self.lock_inner()?.folders.store()).get(reference) {
                Ok(workflow_type) => workflow_type,
                Err(error) => return Ok(super::rejection("invalidWorkflowType", &error)),
            };
        let mut run = match WorkflowRun::new(workflow_type, prompt, choices) {
            Ok(run) => run,
            Err(error) => return Ok(super::rejection("invalidWorkflowRun", &error)),
        };
        let harnesses = match self.locate_run_harnesses(&run) {
            Ok(harnesses) => harnesses,
            Err(error) => return Ok(super::rejection("harnessNotFound", &error)),
        };
        let placeholder = {
            let mut inner = self.lock_inner()?;
            inner
                .folders
                .store()
                .start_workflow_run(workflow_id, &mut run)?;
            if run.graph.is_some() && !run.prompt.trim().is_empty() {
                run.start_graph_task(run.prompt.clone())
                    .map_err(|_| ApplicationError::Poisoned)?;
            }
            let workflow = inner
                .workflows
                .workflows
                .iter_mut()
                .find(|w| w.workflow_id == workflow_id)
                .expect("draft validated under command lock");
            let placeholder = workflow.terminal_id;
            workflow.kind = WorkflowKind::Agents;
            workflow.restored = false;
            workflow.terminal_history.clear();
            workflow.name.clone_from(&run.workflow_type.definition.name);
            workflow.terminal_id = TerminalId::from_value(0);
            workflow.agents = run
                .agents
                .iter()
                .map(|a| Agent {
                    agent_id: AgentId(a.agent_id),
                    role: a.label.clone(),
                    terminal_id: TerminalId::from_value(0),
                })
                .collect();
            workflow.status = WorkflowStatus::Running;
            workflow.started_at = timestamp();
            workflow.ended_at = None;
            workflow.run = Some(Box::new(run));
            let changed = workflow.clone();
            inner.terminals.remove(&placeholder);
            inner
                .events
                .append(EventKind::State(StateEvent::WorkflowChanged(changed)))?;
            if let Ok(observation) = self.terminals.observe(placeholder)
                && let Err(error) = inner.stop_trace(
                    placeholder,
                    observation,
                    "Shell stopped when its workflow started.",
                )
            {
                tracing::warn!(%error, "couldn't record the placeholder shell ending");
            }
            placeholder
        };
        if placeholder.value() != 0 {
            let _ = self.terminals.close(placeholder);
        }
        self.run_processes
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?
            .insert(
                workflow_id,
                RunProcesses {
                    folder,
                    size,
                    harnesses,
                    decisions: HashMap::new(),
                    inboxes: HashMap::new(),
                    completion_commands: HashMap::new(),
                    completion_routing: HashMap::new(),
                    graph_submissions: HashMap::new(),
                    inputs: HashMap::new(),
                    retired_inboxes: std::collections::VecDeque::new(),
                    resumed_sessions: HashMap::new(),
                },
            );
        self.launch_workflow_stage(workflow_id, false)?;
        Ok(CommandDisposition::Accepted)
    }

    /// Restore exact conversations without replaying assignments or queued coordination.
    #[expect(
        clippy::too_many_lines,
        reason = "conversation restore keeps exact identities and publication together"
    )]
    pub(super) fn resume_workflow_run(
        &self,
        saved: &Workflow,
        folder: &std::path::Path,
    ) -> Result<(), ApplicationError> {
        let Some(saved_run) = &saved.run else {
            return Ok(());
        };
        let mut sessions = HashMap::new();
        {
            let mut inner = self.lock_inner()?;
            for tab in &saved.agents {
                let Some(agent) = saved_run.agents.iter().find(|agent| {
                    agent.agent_id == tab.agent_id.0 && agent.harness != HarnessId::Nouli
                }) else {
                    continue;
                };
                if let Some(session) = Self::recorded_agent_session(
                    inner.folders.store(),
                    saved,
                    Some(tab.agent_id),
                    tab.terminal_id,
                )? && crate::harness::resume::arguments(agent.harness, &session).is_some()
                {
                    sessions.insert(tab.agent_id, session);
                }
            }
        }
        self.retire_completed_harness_hooks(saved)?;
        let mut harnesses = HashMap::new();
        for agent in saved_run
            .agents
            .iter()
            .filter(|agent| agent.harness != HarnessId::Nouli)
        {
            if let std::collections::hash_map::Entry::Vacant(entry) = harnesses.entry(agent.harness)
                && let Ok(located) = self.locate_harness(agent.harness.definition())
            {
                entry.insert(located);
            }
        }
        let mut workflow = saved.clone();
        workflow.archived = false;
        let run = workflow.run.as_mut().expect("saved run");
        run.generation = run
            .generation
            .checked_add(1)
            .ok_or(ApplicationError::Poisoned)?;
        if let Some(outcome) = &mut run.last_outcome {
            outcome.generation = run.generation;
        }
        run.status = if run
            .graph
            .as_ref()
            .is_some_and(|graph| !graph.decision_errors.is_empty())
        {
            RunStatus::Paused
        } else {
            RunStatus::Idle
        };
        let counters = run
            .agents
            .iter()
            .map(|agent| {
                Ok((
                    agent.agent_id,
                    run.assignment_generation(agent.agent_id)
                        .checked_add(1)
                        .ok_or(ApplicationError::Poisoned)?,
                ))
            })
            .collect::<Result<Vec<_>, ApplicationError>>()?;
        if let Some(graph) = &mut run.graph {
            graph.assignment_generations.extend(counters);
            graph.ready.clear();
            graph.assigned.clear();
            graph.queues.clear();
        }
        for agent in &mut run.agents {
            agent.harness_running = false;
        }
        if !sessions.is_empty() {
            run.trace(
                "workflowResumed",
                None,
                None,
                "Conversations restored. No work was replayed.",
            );
        }
        workflow.status = WorkflowStatus::Running;
        workflow.ended_at = None;
        {
            let mut inner = self.lock_inner()?;
            let Some(index) = inner
                .workflows
                .workflows
                .iter()
                .position(|workflow| workflow.workflow_id == saved.workflow_id)
            else {
                return Ok(());
            };
            inner.publish_run(index, workflow)?;
        }
        self.run_processes
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?
            .insert(
                saved.workflow_id,
                RunProcesses {
                    folder: folder.to_owned(),
                    size: super::resume_agents::RESTORED_SIZE,
                    harnesses,
                    decisions: HashMap::new(),
                    inboxes: HashMap::new(),
                    completion_commands: HashMap::new(),
                    completion_routing: HashMap::new(),
                    graph_submissions: HashMap::new(),
                    inputs: HashMap::new(),
                    retired_inboxes: std::collections::VecDeque::new(),
                    resumed_sessions: sessions,
                },
            );
        self.launch_private_conversations(saved.workflow_id)
    }

    #[expect(
        clippy::too_many_lines,
        reason = "terminal reservations and launch failure cleanup stay paired"
    )]
    fn prepare_workflow_stage(
        &self,
        run: &mut WorkflowRun,
        processes: &mut RunProcesses,
        live_terminals: &HashMap<AgentId, TerminalId>,
        user_follow_up: bool,
        conversation_agents: Option<&std::collections::HashSet<AgentId>>,
    ) -> Vec<PreparedAgent> {
        let conversations_only = conversation_agents.is_some();
        let fail = |run: &mut WorkflowRun, message: &str| {
            if conversations_only {
                run.message = Some(message.to_owned());
                run.trace("agentUnavailable", None, None, message);
            } else {
                run.finish(RunStatus::Failed, message);
            }
        };
        let candidates = if conversations_only {
            run.agents.iter().collect()
        } else {
            run.active_agents()
        };
        let active: Vec<_> =
            candidates
                .into_iter()
                .filter(|agent| {
                    agent.harness != HarnessId::Nouli
                        && if conversations_only {
                            processes.harnesses.contains_key(&agent.harness)
                                && live_terminals.get(&AgentId(agent.agent_id)).is_none_or(
                                    |terminal| !self.terminals.is_harness_running(*terminal),
                                )
                                && conversation_agents
                                    .is_some_and(|agents| agents.contains(&AgentId(agent.agent_id)))
                        } else {
                            !run.completions.contains_key(&agent.agent_id)
                                && (run.graph.is_none()
                                    || agent.status == crate::RunAgentStatus::Waiting)
                        }
                })
                .cloned()
                .collect();
        // Reserve every transcript outside application state locks; storage can wait on disk.
        let mut prepared = Vec::new();
        for agent in active {
            processes.graph_submissions.remove(&AgentId(agent.agent_id));
            let Ok(inbox) = CompletionInbox::new() else {
                fail(run, "Couldn't create the completion command.");
                if conversations_only {
                    continue;
                }
                break;
            };
            if let Some(&terminal) = live_terminals
                .get(&AgentId(agent.agent_id))
                .filter(|terminal| self.terminals.is_harness_running(**terminal))
            {
                let finished = self.harness_turn_finished(terminal).unwrap_or(false);
                let Ok(prompt) = processes.continuation_prompt(
                    run,
                    agent.agent_id,
                    &inbox,
                    user_follow_up,
                    finished,
                ) else {
                    fail(run, "Could not prepare the next assignment.");
                    if conversations_only {
                        continue;
                    }
                    break;
                };
                prepared.push(PreparedAgent {
                    agent,
                    inbox,
                    reserved: terminal,
                    arguments: Vec::new(),
                    hooks: None,
                    continuation: Some(prompt),
                    memory_environment: Vec::new(),
                    memory_lease: None,
                });
                continue;
            }
            match live_terminals
                .get(&AgentId(agent.agent_id))
                .copied()
                .map_or_else(|| self.terminals.reserve_terminal(), Ok)
            {
                Ok(reserved) => {
                    let options = workflow_launch_options(&agent);
                    let (mut arguments, hooks) = match self.harness_arguments(
                        agent.harness,
                        reserved,
                        options,
                        "",
                        processes
                            .resumed_sessions
                            .get(&AgentId(agent.agent_id))
                            .map(String::as_str),
                    ) {
                        Ok(prepared) => prepared,
                        Err(error) => {
                            let _ = self.terminals.cancel_reserved_terminal(reserved);
                            fail(run, &format!("Could not prepare the agent: {error}"));
                            if conversations_only {
                                continue;
                            }
                            break;
                        }
                    };
                    let command = if hooks.is_some() || run.graph.is_some() {
                        let Ok(command) = processes.command_for(AgentId(agent.agent_id), &inbox)
                        else {
                            let _ = self.terminals.cancel_reserved_terminal(reserved);
                            fail(run, "Couldn't prepare the agent's completion command.");
                            if conversations_only {
                                continue;
                            }
                            break;
                        };
                        if run.graph.is_some() && run.needs_task() {
                            processes.completion_commands[&AgentId(agent.agent_id)].deactivate();
                            processes.completion_routing.insert(
                                AgentId(agent.agent_id),
                                CompletionRouting::AwaitingSubmission(
                                    run.assignment_generation(agent.agent_id),
                                ),
                            );
                        } else {
                            processes
                                .completion_routing
                                .remove(&AgentId(agent.agent_id));
                        }
                        command
                    } else {
                        processes
                            .completion_commands
                            .remove(&AgentId(agent.agent_id));
                        inbox.command()
                    };
                    let memory_environment =
                        match processes.resumed_sessions.get(&AgentId(agent.agent_id)) {
                            Some(session) => self.resume_memory_environment(
                                agent.harness,
                                &processes.folder,
                                session,
                            ),
                            None => self.memory_environment(agent.harness, &processes.folder),
                        };
                    let (memory_environment, memory_lease) = match memory_environment {
                        Ok(values) => values,
                        Err(error) => {
                            let _ = self.terminals.cancel_reserved_terminal(reserved);
                            fail(run, &format!("Could not prepare native memory: {error}"));
                            if conversations_only {
                                continue;
                            }
                            break;
                        }
                    };
                    if let Err(error) = Self::append_memory_settings(
                        agent.harness,
                        &memory_environment,
                        &mut arguments,
                    )
                    .and_then(|()| {
                        self.append_memory_context(
                            agent.harness,
                            &processes.folder,
                            &memory_environment,
                            &mut arguments,
                            hooks.as_ref(),
                        )
                    })
                    .and_then(|()| {
                        Self::append_agent_instructions(
                            agent.harness,
                            (
                                &if conversations_only {
                                    run.independent_instructions(agent.agent_id)
                                } else {
                                    run.instructions(agent.agent_id, &command)
                                },
                                self.browser_control.is_enabled(),
                            ),
                            &mut arguments,
                            hooks.as_ref(),
                            &processes.harnesses[&agent.harness],
                            &processes.folder,
                        )
                    }) {
                        let _ = self.terminals.cancel_reserved_terminal(reserved);
                        fail(run, &format!("Could not set role instructions: {error}"));
                        if conversations_only {
                            continue;
                        }
                        break;
                    }
                    let session = processes.resumed_sessions.get(&AgentId(agent.agent_id));
                    if let Some(session) = session {
                        arguments.extend(
                            crate::harness::resume::arguments(agent.harness, session)
                                .expect("resume handles validated before restarting a workflow"),
                        );
                    }
                    if conversations_only {
                        if let Some(command) =
                            processes.completion_commands.get(&AgentId(agent.agent_id))
                        {
                            command.deactivate();
                        }
                        processes
                            .completion_routing
                            .insert(AgentId(agent.agent_id), CompletionRouting::Private);
                    }
                    let task = if conversations_only {
                        String::new()
                    } else {
                        run.initial_task(agent.agent_id)
                    };
                    if !task.is_empty() {
                        // Task history may quote another role's command. Like continuations,
                        // initial assignments end with the recipient's current command.
                        let task = format!(
                            "{task}\n\nUse this completion command for your current assignment: {command}"
                        );
                        arguments.extend(agent.harness.definition().arguments(&task));
                    }
                    prepared.push(PreparedAgent {
                        agent,
                        inbox,
                        reserved,
                        arguments,
                        hooks,
                        continuation: None,
                        memory_environment,
                        memory_lease,
                    });
                }
                Err(error) => {
                    fail(run, &format!("Couldn't reserve a terminal: {error}"));
                    if conversations_only {
                        continue;
                    }
                    break;
                }
            }
        }
        prepared
    }

    pub(super) fn launch_private_conversations(
        &self,
        workflow: WorkflowId,
    ) -> Result<(), ApplicationError> {
        self.launch_workflow_agents(workflow, false, true)
    }

    pub(super) fn launch_workflow_stage(
        &self,
        workflow_id: WorkflowId,
        user_follow_up: bool,
    ) -> Result<(), ApplicationError> {
        self.launch_workflow_agents(workflow_id, user_follow_up, false)
    }

    #[expect(
        clippy::too_many_lines,
        reason = "process, session, inbox, and trace cleanup stay paired during launch"
    )]
    fn launch_workflow_agents(
        &self,
        workflow_id: WorkflowId,
        user_follow_up: bool,
        conversations_only: bool,
    ) -> Result<(), ApplicationError> {
        let mut process_guard = self
            .run_processes
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?;
        let Some(processes) = process_guard.get_mut(&workflow_id) else {
            return Ok(());
        };
        let inner = self.lock_inner()?;
        let Some(index) = inner
            .workflows
            .workflows
            .iter()
            .position(|w| w.workflow_id == workflow_id)
        else {
            return Ok(());
        };
        let mut workflow = inner.workflows.workflows[index].clone();
        let mut live_terminals: HashMap<_, _> = workflow
            .agents
            .iter()
            .filter_map(|agent| {
                (inner.terminals.get(&agent.terminal_id) == Some(&TerminalStatus::Running))
                    .then_some((agent.agent_id, agent.terminal_id))
            })
            .collect();
        drop(inner);
        live_terminals.retain(|_, terminal| self.terminals.is_running(*terminal));
        let run = workflow.run.as_mut().expect("execution has a run");
        if !conversations_only && (run.agents_disconnected || run.status != RunStatus::Running) {
            return Ok(());
        }
        if !conversations_only {
            run.trace("stageStarted", None, None, "Stage started");
        }
        let prepared_decisions = if conversations_only {
            Vec::new()
        } else {
            Self::prepare_decisions(run)
        };
        let conversation_agents = workflow
            .agents
            .iter()
            .filter(|agent| {
                (!workflow.restored && agent.terminal_id.value() == 0)
                    || processes.resumed_sessions.contains_key(&agent.agent_id)
            })
            .map(|agent| agent.agent_id)
            .collect();
        let prepared = self.prepare_workflow_stage(
            run,
            processes,
            &live_terminals,
            user_follow_up,
            conversations_only.then_some(&conversation_agents),
        );
        let mut inner = self.lock_inner()?;
        let mut replaced = Vec::new();
        let mut unused = Vec::new();
        let mut step_hooks = Vec::new();
        let mut started = Vec::new();
        let mut continuations = Vec::new();
        for PreparedAgent {
            agent,
            inbox,
            reserved,
            arguments,
            hooks,
            continuation,
            memory_environment,
            memory_lease,
        } in prepared
        {
            if run.status != RunStatus::Running && !conversations_only {
                if continuation.is_none() {
                    unused.push(reserved);
                }
                continue;
            }
            let located = &processes.harnesses[&agent.harness];
            let continued = continuation.is_some();
            let launched = if let Some(prompt) = continuation {
                continuations.push((reserved, prompt));
                Ok(reserved)
            } else {
                self.terminals.start_managed_program(
                    reserved,
                    &processes.folder,
                    &located.program,
                    &arguments,
                    &located.path,
                    &crate::harness::launch::observed_environment(agent.harness, hooks.as_ref())
                        .into_iter()
                        .chain(
                            memory_environment
                                .iter()
                                .filter(|(key, _)| key != "HANDSHAKE_CLAUDE_MEMORY_DIRECTORY")
                                .map(|(k, v)| (k.as_str(), v.as_str())),
                        )
                        .collect::<Vec<_>>(),
                    processes.size,
                    Arc::new(self.memory_exit_callback(memory_lease)),
                    Arc::new(self.exit_callback()),
                )
            };
            match launched {
                Ok(terminal_id) => {
                    if !continued
                        && !live_terminals
                            .values()
                            .any(|existing| *existing == terminal_id)
                    {
                        started.push(terminal_id);
                    }
                    processes.inputs.entry(terminal_id).or_default();
                    self.terminals
                        .set_routing_revision(terminal_id, run.mode_revision);
                    if let Some(current) = run
                        .agents
                        .iter_mut()
                        .find(|current| current.agent_id == agent.agent_id)
                    {
                        current.harness_running = true;
                    }
                    if let Some(hooks) = hooks {
                        step_hooks.push((terminal_id, hooks));
                    }
                    if let Some(previous) = inner.record_agent_launch(
                        &mut workflow.agents,
                        run,
                        agent.agent_id,
                        terminal_id,
                    ) {
                        replaced.push(previous);
                    }
                    if !conversations_only {
                        processes.inboxes.insert(
                            AgentId(agent.agent_id),
                            (run.assignment_generation(agent.agent_id), inbox),
                        );
                        run.graph_agent_launched(agent.agent_id);
                    }
                    run.trace(
                        if conversations_only {
                            "conversationStarted"
                        } else if continued {
                            "agentContinued"
                        } else {
                            "agentStarted"
                        },
                        Some(agent.agent_id),
                        None,
                        if continued {
                            "Assignment continued in the existing harness"
                        } else {
                            "Harness started"
                        },
                    );
                    let observation = self.terminals.observe(terminal_id).ok();
                    run.traces.last_mut().expect("launch was traced").anchor =
                        Some(crate::TraceAnchor {
                            terminal_id,
                            byte_offset: if continued
                                || live_terminals.values().any(|id| *id == terminal_id)
                            {
                                observation.as_ref().map_or(0, |value| value.byte_offset)
                            } else {
                                0
                            },
                            boundary_sizes: observation.and_then(|value| value.boundary_sizes),
                        });
                }
                Err(error) => {
                    let message = format!("Couldn't start {}: {error}", agent.label);
                    if conversations_only {
                        run.message = Some(message.clone());
                        run.trace("agentUnavailable", Some(agent.agent_id), None, &message);
                    } else {
                        run.finish(RunStatus::Failed, &message);
                    }
                }
            }
        }
        workflow.status = workflow_status(run.status);
        if run.status != RunStatus::Running && run.status != RunStatus::Idle {
            workflow.ended_at = Some(timestamp());
            processes.inboxes.clear();
        }
        let resumed: Vec<_> = workflow
            .agents
            .iter()
            .filter_map(|agent| {
                processes
                    .resumed_sessions
                    .get(&agent.agent_id)
                    .map(|session| (agent.terminal_id, session.as_str()))
            })
            .collect();
        let saved = if conversations_only {
            inner.publish_run_with_sessions(index, workflow.clone(), &resumed)
        } else {
            inner.publish_launch(index, &mut workflow, &resumed)
        };
        if conversations_only && saved.is_err() {
            for terminal in &started {
                inner.terminals.remove(terminal);
            }
            processes
                .inputs
                .retain(|terminal, _| !started.contains(terminal));
            // Failed persistence can retire a newly allocated PTY, never the shell we resumed in.
            for tab in &mut workflow.agents {
                if started.contains(&tab.terminal_id) {
                    tab.terminal_id = inner.workflows.workflows[index]
                        .agents
                        .iter()
                        .find(|old| old.agent_id == tab.agent_id)
                        .map_or(TerminalId::from_value(0), |old| old.terminal_id);
                    if let Some(agent) = workflow
                        .run
                        .as_mut()
                        .expect("run")
                        .agents
                        .iter_mut()
                        .find(|agent| agent.agent_id == tab.agent_id.0)
                    {
                        agent.harness_running = false;
                    }
                }
            }
            workflow.run.as_mut().expect("run").message = Some(
                "Couldn't save conversation recovery. Existing terminals remain available.".into(),
            );
            inner.publish_run_best_effort(index, workflow)?;
            step_hooks.retain(|(terminal, _)| !started.contains(terminal));
            drop(inner);
            drop(process_guard);
            self.terminals.close_all(&started)?;
            self.register_stage_steps(workflow_id, step_hooks);
            for terminal in unused {
                let _ = self.terminals.cancel_reserved_terminal(terminal);
            }
            return saved;
        }
        processes.resumed_sessions.clear();
        processes
            .inputs
            .retain(|terminal, _| workflow.terminal_ids().contains(terminal));
        if workflow.status != WorkflowStatus::Running {
            processes.inboxes.clear();
        }
        let failed_terminals = if workflow.status == WorkflowStatus::Failed && !conversations_only {
            workflow.terminal_ids()
        } else {
            Vec::new()
        };
        drop(inner);
        drop(process_guard);
        self.register_stage_steps(workflow_id, step_hooks);
        let _ = failed_terminals;
        for id in unused {
            let _ = self.terminals.cancel_reserved_terminal(id);
        }
        let replaced: Vec<_> = replaced
            .into_iter()
            .filter(|id| {
                !workflow
                    .terminal_history
                    .iter()
                    .any(|entry| entry.terminal_id == *id)
            })
            .collect();
        self.terminals.close_all(&replaced)?;
        saved?;
        if workflow.status == WorkflowStatus::Running && !conversations_only {
            self.start_decisions(workflow_id, prepared_decisions)?;
        }
        // PTY writes can wait for the harness to read. Keep them outside application state locks.
        if workflow.status == WorkflowStatus::Running {
            for (terminal, prompt) in continuations {
                if prompt.is_empty() {
                    continue;
                }
                if user_follow_up && let Some(input) = self.workflow_agent_input(terminal)? {
                    input
                        .lock()
                        .map_err(|_| ApplicationError::Poisoned)?
                        .defer_notification(prompt);
                    continue;
                }
                let run = workflow.run.as_ref().expect("run exists");
                let agent = workflow
                    .agents
                    .iter()
                    .find(|agent| agent.terminal_id == terminal)
                    .expect("agent owns terminal");
                let stamp = RoutingStamp {
                    revision: run.mode_revision,
                    generation: run.assignment_generation(agent.agent_id.0),
                };
                if let Err(error) = self.notify_workflow_agent(terminal, &prompt, stamp) {
                    let mut inner = self.lock_inner()?;
                    let mut workflow = inner.workflows.workflows[index].clone();
                    workflow.run.as_mut().expect("workflow has a run").finish(
                        RunStatus::Failed,
                        "Couldn't send the next assignment to the agent.",
                    );
                    workflow.status = WorkflowStatus::Running;
                    workflow.ended_at = Some(timestamp());
                    let terminals = workflow.terminal_ids();
                    inner.publish_run_best_effort(index, workflow)?;
                    drop(inner);
                    let _ = terminals;
                    return Err(error);
                }
            }
        }
        Ok(())
    }

    pub(super) fn submit_workflow_task(
        &self,
        workflow_id: WorkflowId,
        generation: u64,
        prompt: String,
    ) -> Result<CommandDisposition, ApplicationError> {
        {
            let mut inner = self.lock_inner()?;
            let Some(index) = inner
                .workflows
                .workflows
                .iter()
                .position(|workflow| workflow.workflow_id == workflow_id)
            else {
                return Ok(reject(
                    "workflowNotFound",
                    "The workflow is no longer open.",
                ));
            };
            let mut workflow = inner.workflows.workflows[index].clone();
            let Some(run) = workflow.run.as_mut() else {
                return Ok(reject("notWorkflowRun", "This workflow has no graph."));
            };
            if run.generation != generation {
                return Ok(reject("staleTask", "The workflow changed."));
            }
            if run.status == RunStatus::Idle
                && run.graph.as_ref().is_some_and(|graph| !graph.started)
            {
                run.status = RunStatus::Running;
            }
            if let Err(error) = run.start_graph_task(prompt) {
                return Ok(super::rejection("invalidTask", &error));
            }
            inner.publish_run(index, workflow)?;
        }
        self.launch_workflow_stage(workflow_id, false)?;
        Ok(CommandDisposition::Accepted)
    }

    pub(super) fn choose_workflow_result(
        &self,
        workflow_id: WorkflowId,
        generation: u64,
        agent_id: AgentId,
    ) -> Result<CommandDisposition, ApplicationError> {
        let mut inner = self.lock_inner()?;
        let Some(index) = inner
            .workflows
            .workflows
            .iter()
            .position(|workflow| workflow.workflow_id == workflow_id)
        else {
            return Ok(reject(
                "workflowNotFound",
                "The workflow is no longer open.",
            ));
        };
        let mut workflow = inner.workflows.workflows[index].clone();
        let Some(run) = workflow.run.as_mut() else {
            return Ok(reject("notWorkflowRun", "This workflow has no graph."));
        };
        if let Err(error) = run.choose_graph_result(agent_id.0, generation) {
            return Ok(super::rejection("invalidResult", &error));
        }
        workflow.status = WorkflowStatus::Running;
        workflow.ended_at = None;
        inner.publish_run(index, workflow)?;
        Ok(CommandDisposition::Accepted)
    }

    #[expect(
        clippy::too_many_lines,
        reason = "completion persistence and mailbox receipts stay paired"
    )]
    pub(super) fn complete_workflow_role(
        &self,
        workflow_id: WorkflowId,
        agent_id: AgentId,
        generation: u64,
        signal: CompletionSignal,
    ) -> Result<CommandDisposition, ApplicationError> {
        self.poll_harness_steps()?;
        let piece = signal.decision == crate::Decision::PieceReady;
        let replacement = if piece {
            match CompletionInbox::new() {
                Ok(inbox) => Some(inbox),
                Err(error) => return Ok(super::rejection("completionInboxFailed", &error)),
            }
        } else {
            None
        };
        let (
            advance,
            running,
            feedback,
            generation,
            mode_revision,
            graph_run,
            assignment_generation,
        ) = {
            let mut inner = self.lock_inner()?;
            let Some(index) = inner
                .workflows
                .workflows
                .iter()
                .position(|w| w.workflow_id == workflow_id)
            else {
                return Ok(reject(
                    "workflowNotFound",
                    "The workflow is no longer open.",
                ));
            };
            let mut workflow = inner.workflows.workflows[index].clone();
            let Some(run) = &mut workflow.run else {
                return Ok(reject("notWorkflowRun", "This workflow has no stages."));
            };
            let previous_sequence = run.traces.last().map_or(0, |event| event.sequence);
            let anchor = workflow
                .agents
                .iter()
                .find(|agent| agent.agent_id == agent_id)
                .and_then(|agent| match self.terminals.observe(agent.terminal_id) {
                    Ok(observation) => Some(crate::TraceAnchor {
                        terminal_id: agent.terminal_id,
                        byte_offset: observation.byte_offset,
                        boundary_sizes: observation.boundary_sizes,
                    }),
                    Err(error) => {
                        tracing::warn!(%error, "couldn't observe completion terminal boundary");
                        None
                    }
                });
            let advance = match run.complete(agent_id.0, generation, signal) {
                Ok(advance) => advance,
                Err(error) => return Ok(super::rejection("invalidCompletion", &error)),
            };
            let completion_anchors: HashMap<_, _> = run
                .traces
                .iter()
                .filter(|event| event.generation == generation && event.kind == "roleCompleted")
                .filter_map(|event| Some((event.agent_id?, event.anchor.clone()?)))
                .collect();
            for event in run
                .traces
                .iter_mut()
                .filter(|event| event.sequence > previous_sequence)
            {
                // Parallel senders can finish before this completion advances the stage. Their
                // handoffs retain each sender's own completion boundary, even after it exits.
                event.anchor = match event.agent_id {
                    Some(source) if source != agent_id.0 => {
                        completion_anchors.get(&source).cloned()
                    }
                    _ => anchor.clone(),
                };
            }
            let running = run.status == RunStatus::Running;
            let feedback = if advance && !running && run.is_reviewer(agent_id.0) {
                final_review_feedback(&workflow.agents, run, agent_id.0)
            } else {
                Vec::new()
            };
            let generation = run.generation;
            let mode_revision = run.mode_revision;
            let graph_run = run.graph.is_some();
            let assignment_generation = run.assignment_generation(agent_id.0);
            workflow.status = workflow_status(run.status);
            workflow.ended_at = None;
            if let Err(error) = inner.publish_run(index, workflow) {
                return Ok(super::rejection("completionStoreFailed", &error));
            }
            (
                advance,
                running,
                feedback,
                generation,
                mode_revision,
                graph_run,
                assignment_generation,
            )
        };
        let mut renewal_failed = false;
        {
            let mut processes = self
                .run_processes
                .lock()
                .map_err(|_| ApplicationError::Poisoned)?;
            if let Some(processes) = processes.get_mut(&workflow_id) {
                processes.finish_assignment(agent_id, if graph_run { !running } else { advance });
                if piece && running {
                    let inbox = replacement.expect("piece inbox prepared before persistence");
                    if processes.command_for(agent_id, &inbox).is_err() {
                        inbox.reject(
                            "The workflow stopped because its signal command could not be renewed.",
                        );
                        renewal_failed = true;
                    }
                    if !renewal_failed {
                        processes
                            .inboxes
                            .insert(agent_id, (assignment_generation, inbox));
                    }
                }
            }
        }
        if renewal_failed {
            self.fail_graph_signals(workflow_id)?;
            return Ok(CommandDisposition::Accepted);
        }
        if advance && running {
            self.launch_workflow_stage(workflow_id, false)?;
        }
        self.deliver_review_feedback(workflow_id, generation, mode_revision, feedback);
        Ok(CommandDisposition::Accepted)
    }

    fn fail_graph_signals(&self, workflow_id: WorkflowId) -> Result<(), ApplicationError> {
        let terminals = {
            let mut inner = self.lock_inner()?;
            let Some(index) = inner
                .workflows
                .workflows
                .iter()
                .position(|workflow| workflow.workflow_id == workflow_id)
            else {
                return Ok(());
            };
            let mut workflow = inner.workflows.workflows[index].clone();
            if let Some(run) = workflow.run.as_mut() {
                run.finish(
                    RunStatus::Failed,
                    "Could not renew the agent signal command.",
                );
            }
            workflow.status = WorkflowStatus::Running;
            workflow.ended_at = Some(timestamp());
            let terminals = workflow.terminal_ids();
            inner.publish_run_best_effort(index, workflow)?;
            terminals
        };
        let _ = terminals;
        Ok(())
    }

    fn deliver_review_feedback(
        &self,
        workflow: WorkflowId,
        generation: u64,
        mode_revision: u64,
        feedback: Vec<(TerminalId, String)>,
    ) {
        for (terminal, message) in feedback {
            if self.terminals.is_harness_running(terminal)
                && let Err(error) = self.notify_final_review_feedback(
                    workflow,
                    generation,
                    mode_revision,
                    terminal,
                    &message,
                )
            {
                tracing::warn!(%error, "couldn't deliver the final review feedback");
            }
        }
    }

    fn notify_final_review_feedback(
        &self,
        workflow: WorkflowId,
        generation: u64,
        mode_revision: u64,
        terminal: TerminalId,
        message: &str,
    ) -> Result<(), ApplicationError> {
        let Some(input) = self.workflow_agent_input(terminal)? else {
            return Ok(());
        };
        // A harness can block its writer. Wait without holding application or registry locks,
        // then revalidate the revision while owning the writer used by mode cleanup.
        let mut writer = input.lock().map_err(|_| ApplicationError::Poisoned)?;
        let registry = self
            .run_processes
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?;
        let inner = self.lock_inner()?;
        let current = inner
            .workflows
            .workflows
            .iter()
            .find(|w| w.workflow_id == workflow)
            .and_then(|w| w.run.as_ref());
        if !self.terminals.is_harness_running(terminal)
            || !current.is_some_and(|run| {
                !run.agents_disconnected
                    && run.mode_revision == mode_revision
                    && run.generation == generation
                    && (run.work_completed()
                        || run.last_outcome.as_ref().is_some_and(|outcome| {
                            outcome.kind == crate::WorkOutcomeKind::LimitReached
                        }))
            })
        {
            return Ok(());
        }
        drop(inner);
        drop(registry);
        let finished = self.harness_turn_finished(terminal)?;
        writer.notify(
            &self.terminals,
            terminal,
            message,
            RoutingStamp {
                revision: mode_revision,
                generation,
            },
            finished,
        )?;
        Ok(())
    }

    fn notify_workflow_agent(
        &self,
        terminal: TerminalId,
        message: &str,
        stamp: RoutingStamp,
    ) -> Result<(), ApplicationError> {
        let Some(input) = self.workflow_agent_input(terminal)? else {
            return Ok(());
        };
        let finished = self.harness_turn_finished(terminal)?;
        let mut input = input.lock().map_err(|_| ApplicationError::Poisoned)?;
        let registry = self
            .run_processes
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?;
        let inner = self.lock_inner()?;
        let current = inner.workflows.workflows.iter().find_map(|workflow| {
            let agent = workflow
                .agents
                .iter()
                .find(|agent| agent.terminal_id == terminal)?;
            Some((workflow.run.as_ref()?, agent.agent_id))
        });
        if !current.is_some_and(|(run, agent)| {
            !run.agents_disconnected
                && run.status == RunStatus::Running
                && run.mode_revision == stamp.revision
                && run.assignment_generation(agent.0) == stamp.generation
                && run
                    .active_agents()
                    .iter()
                    .any(|active| active.agent_id == agent.0)
        }) {
            return Ok(());
        }
        drop(inner);
        drop(registry);
        let submission = if input.notification_will_submit() {
            self.note_workflow_submission(terminal)?
        } else {
            None
        };
        if let Err(error) = input.notify(&self.terminals, terminal, message, stamp, finished) {
            self.cancel_workflow_submission(submission)?;
            return Err(error.into());
        }
        Ok(())
    }

    pub(super) fn deliver_deferred_handoffs(
        &self,
        terminal: TerminalId,
        prompt_started: Instant,
    ) -> Result<(), ApplicationError> {
        if !self.harness_turn_finished(terminal)? {
            return Ok(());
        }
        if let Some(input) = self.workflow_agent_input(terminal)? {
            let messages = input
                .lock()
                .map_err(|_| ApplicationError::Poisoned)?
                .take_deferred_handoffs(prompt_started);
            for (stamp, message) in messages {
                self.notify_workflow_agent(terminal, &message, stamp)?;
            }
        }
        Ok(())
    }

    pub(super) fn note_workflow_submission(
        &self,
        terminal: TerminalId,
    ) -> Result<Option<WorkflowSubmission>, ApplicationError> {
        let owner = {
            let inner = self.lock_inner()?;
            inner.workflows.workflows.iter().find_map(|workflow| {
                let run = workflow.run.as_ref()?;
                if run.agents_disconnected || run.status != RunStatus::Running {
                    return None;
                }
                let agent = workflow
                    .agents
                    .iter()
                    .find(|agent| agent.terminal_id == terminal)?;
                Some((
                    workflow.workflow_id,
                    agent.agent_id,
                    run.assignment_generation(agent.agent_id.0),
                    run.graph.is_some() && run.needs_task(),
                ))
            })
        };
        if let Some((workflow, agent, generation, idle_graph)) = owner {
            let mut processes = self
                .run_processes
                .lock()
                .map_err(|_| ApplicationError::Poisoned)?;
            if let Some(processes) = processes.get_mut(&workflow)
                && let Some(routing) = processes.completion_routing.get_mut(&agent)
                && matches!(routing, CompletionRouting::AwaitingSubmission(assigned) if *assigned == generation)
            {
                let since = Instant::now();
                *routing = CompletionRouting::AwaitingPrompt(generation, since);
                if idle_graph {
                    processes
                        .graph_submissions
                        .insert(agent, (generation, since));
                }
                return Ok(Some(WorkflowSubmission {
                    workflow,
                    agent,
                    generation,
                    since,
                }));
            }
        }
        Ok(None)
    }

    pub(super) fn cancel_workflow_submission(
        &self,
        submission: Option<WorkflowSubmission>,
    ) -> Result<(), ApplicationError> {
        let Some(submission) = submission else {
            return Ok(());
        };
        let mut registry = self
            .run_processes
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?;
        if let Some(processes) = registry.get_mut(&submission.workflow) {
            if matches!(processes.completion_routing.get(&submission.agent),
                Some(CompletionRouting::AwaitingPrompt(generation, since))
                    if *generation == submission.generation && *since == submission.since)
            {
                processes.completion_routing.insert(
                    submission.agent,
                    CompletionRouting::AwaitingSubmission(submission.generation),
                );
            }
            if processes.graph_submissions.get(&submission.agent)
                == Some(&(submission.generation, submission.since))
            {
                processes.graph_submissions.remove(&submission.agent);
            }
        }
        Ok(())
    }

    pub(super) fn graph_submissions(&self) -> Result<Option<GraphSubmissions>, ApplicationError> {
        let registry = match self.run_processes.try_lock() {
            Ok(registry) => registry,
            Err(std::sync::TryLockError::WouldBlock) => return Ok(None),
            Err(std::sync::TryLockError::Poisoned(_)) => return Err(ApplicationError::Poisoned),
        };
        Ok(Some(
            registry
                .iter()
                .flat_map(|(&workflow, processes)| {
                    processes
                        .graph_submissions
                        .iter()
                        .map(move |(&agent, &submission)| ((workflow, agent), submission))
                })
                .collect(),
        ))
    }

    pub(super) fn activate_workflow_completion(
        &self,
        workflow: WorkflowId,
        agent: AgentId,
        generation: u64,
        ready: bool,
        received_at: Option<Instant>,
    ) -> Result<(), ApplicationError> {
        let mut processes = self
            .run_processes
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?;
        if let Some(processes) = processes.get_mut(&workflow)
            && let Some((assigned_generation, inbox)) = processes.inboxes.get(&agent)
            && *assigned_generation == generation
            && let Some(routing) = processes.completion_routing.get_mut(&agent)
            && routing.generation() == Some(generation)
            && let Some(command) = processes.completion_commands.get(&agent)
        {
            if matches!(routing, CompletionRouting::AwaitingSubmission(_)) {
                return Ok(());
            }
            if ready
                && !matches!(routing, CompletionRouting::AwaitingPrompt(_, since)
                if received_at.is_none_or(|received| received < *since))
            {
                if let Err(error) = command.bind(inbox) {
                    tracing::warn!(%error, "couldn't activate the new assignment's completion command");
                } else {
                    *routing = CompletionRouting::Active(generation);
                }
            } else {
                command.deactivate();
                if matches!(routing, CompletionRouting::Active(_)) {
                    *routing = CompletionRouting::AwaitingPrompt(generation, Instant::now());
                }
            }
        }
        Ok(())
    }

    pub(super) fn workflow_agent_input(
        &self,
        terminal: TerminalId,
    ) -> Result<Option<Arc<Mutex<AgentInput>>>, ApplicationError> {
        Ok(self
            .run_processes
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?
            .values()
            .find_map(|processes| processes.inputs.get(&terminal).cloned()))
    }

    pub(super) fn continue_workflow_run(
        &self,
        workflow_id: WorkflowId,
        agent_id: AgentId,
        generation: u64,
        mode_revision: u64,
    ) -> Result<CommandDisposition, ApplicationError> {
        let terminal = self
            .lock_inner()?
            .workflows
            .workflows
            .iter()
            .find(|workflow| workflow.workflow_id == workflow_id)
            .and_then(|workflow| {
                workflow
                    .agents
                    .iter()
                    .find(|agent| agent.agent_id == agent_id)
            })
            .map(|agent| agent.terminal_id);
        if let Some(terminal) = terminal
            && let Some(input) = self.workflow_agent_input(terminal)?
        {
            let mut input = input.lock().map_err(|_| ApplicationError::Poisoned)?;
            input.prepared_revision = Some(mode_revision);
            if input
                .routing_revision
                .is_some_and(|revision| revision != mode_revision)
            {
                return Ok(CommandDisposition::Accepted);
            }
        }
        {
            let mut inner = self.lock_inner()?;
            let Some(index) = inner
                .workflows
                .workflows
                .iter()
                .position(|w| w.workflow_id == workflow_id)
            else {
                return Ok(reject(
                    "workflowNotFound",
                    "The workflow is no longer open.",
                ));
            };
            let mut workflow = inner.workflows.workflows[index].clone();
            if !workflow.agents.iter().any(|agent| {
                agent.agent_id == agent_id
                    && inner.terminals.get(&agent.terminal_id) == Some(&TerminalStatus::Running)
            }) {
                return Ok(reject(
                    "agentNotRunning",
                    "This agent's terminal is no longer running.",
                ));
            }
            let Some(run) = workflow.run.as_mut() else {
                return Ok(reject("notWorkflowRun", "This workflow has no stages."));
            };
            match run.continue_with(agent_id.0, generation, mode_revision) {
                Ok(false) => return Ok(CommandDisposition::Accepted),
                Ok(true) => {}
                Err(error) => return Ok(super::rejection("invalidContinuation", &error)),
            }
            workflow.status = WorkflowStatus::Running;
            workflow.ended_at = None;
            inner.publish_run(index, workflow)?;
        }
        self.launch_workflow_stage(workflow_id, true)?;
        Ok(CommandDisposition::Accepted)
    }

    pub(super) fn set_workflow_agents_disconnected(
        &self,
        workflow_id: WorkflowId,
        generation: u64,
        mode_revision: u64,
        agents_disconnected: bool,
    ) -> Result<CommandDisposition, ApplicationError> {
        self.change_workflow_connections(
            workflow_id,
            generation,
            mode_revision,
            agents_disconnected,
            false,
        )
    }

    fn assignment_stop_anchors(
        &self,
        tabs: &[Agent],
        run: &WorkflowRun,
    ) -> Vec<(u64, crate::TraceAnchor)> {
        if run.status != RunStatus::Running {
            return Vec::new();
        }
        run.active_agents()
            .into_iter()
            .filter(|agent| !run.completions.contains_key(&agent.agent_id))
            .filter_map(|agent| {
                let tab = tabs.iter().find(|tab| tab.agent_id.0 == agent.agent_id)?;
                let observation = self.terminals.observe(tab.terminal_id).ok()?;
                Some((
                    agent.agent_id,
                    crate::TraceAnchor {
                        terminal_id: tab.terminal_id,
                        byte_offset: observation.byte_offset,
                        boundary_sizes: observation.boundary_sizes,
                    },
                ))
            })
            .collect()
    }

    fn change_workflow_connections(
        &self,
        workflow_id: WorkflowId,
        generation: u64,
        mode_revision: u64,
        agents_disconnected: bool,
        stop_work: bool,
    ) -> Result<CommandDisposition, ApplicationError> {
        let mut writers = {
            let registry = self
                .run_processes
                .lock()
                .map_err(|_| ApplicationError::Poisoned)?;
            registry
                .get(&workflow_id)
                .map(|processes| {
                    processes
                        .inputs
                        .iter()
                        .map(|(&terminal, input)| (terminal, Arc::clone(input)))
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default()
        };
        writers.sort_by_key(|(terminal, _)| terminal.value());
        // Wait for slow PTY writes without holding application state. Sorting provides a
        // consistent order for concurrent changes; revalidate only after owning the writers.
        let mut inputs = writers
            .iter()
            .map(|(_, input)| input.lock().map_err(|_| ApplicationError::Poisoned))
            .collect::<Result<Vec<_>, _>>()?;
        // Match stage launch's lock order. Hold the registry through persistence and cleanup so
        // a new continuation cannot install routing that this mode change then deactivates.
        let mut registry = self
            .run_processes
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?;
        let mut inner = self.lock_inner()?;
        let Some(index) = inner
            .workflows
            .workflows
            .iter()
            .position(|w| w.workflow_id == workflow_id)
        else {
            return Ok(reject(
                "workflowNotFound",
                "The workflow is no longer open.",
            ));
        };
        let mut workflow = inner.workflows.workflows[index].clone();
        let Some(run) = workflow.run.as_mut() else {
            return Ok(reject("notWorkflowRun", "This workflow has no stages."));
        };
        let stopped = if stop_work {
            self.assignment_stop_anchors(&workflow.agents, run)
        } else {
            Vec::new()
        };
        match if stop_work {
            run.stop_work(generation, mode_revision)
        } else {
            run.set_agents_disconnected(agents_disconnected, generation, mode_revision)
        } {
            Ok(false) => return Ok(CommandDisposition::Accepted),
            Ok(true) => {}
            Err(error) => return Ok(super::rejection("invalidAgentsDisconnected", &error)),
        }
        run.trace_stopped_roles(stopped);
        let revision = run.mode_revision;
        for (terminal, _) in &writers {
            self.terminals.set_routing_revision(*terminal, revision);
        }
        workflow.status = workflow_status(run.status);
        if run.status == RunStatus::Idle {
            workflow.ended_at = None;
        }
        let agents: Vec<_> = run
            .agents
            .iter()
            .map(|agent| AgentId(agent.agent_id))
            .collect();
        // Synchronize with user writes before publishing the new mode. Clearing review feedback
        // preserves any unfinished user draft and prevents old feedback reaching a private turn.
        if stop_work {
            inner.publish_run_best_effort(index, workflow)?;
        } else {
            inner.publish_run(index, workflow)?;
        }
        for input in &mut inputs {
            input.clear_feedback();
        }
        drop(inputs);
        let mut decisions = HashMap::new();
        if let Some(processes) = registry.get_mut(&workflow_id) {
            decisions = std::mem::take(&mut processes.decisions);
            processes.disconnect_routes();
            for agent in agents {
                processes
                    .completion_routing
                    .insert(agent, CompletionRouting::Private);
            }
        }
        drop(inner);
        drop(registry);
        drop(decisions);
        if agents_disconnected
            && !stop_work
            && let Err(error) = self.launch_workflow_agents(workflow_id, false, true)
        {
            tracing::warn!(%error, "connections were detached but some conversations couldn't open");
        }
        Ok(CommandDisposition::Accepted)
    }

    pub(super) fn force_stop_workflow_agents(
        &self,
        workflow_id: WorkflowId,
    ) -> Result<CommandDisposition, ApplicationError> {
        let (generation, revision, disconnected, agents) = {
            let inner = self.lock_inner()?;
            let Some(workflow) = inner
                .workflows
                .workflows
                .iter()
                .find(|workflow| workflow.workflow_id == workflow_id)
            else {
                return Ok(reject(
                    "workflowNotFound",
                    "The workflow is no longer open.",
                ));
            };
            let Some(run) = &workflow.run else {
                return Ok(reject(
                    "notWorkflowRun",
                    "This workflow has no coordination.",
                ));
            };
            (
                run.generation,
                run.mode_revision,
                run.agents_disconnected,
                workflow
                    .agents
                    .iter()
                    .filter_map(|tab| {
                        run.agents
                            .iter()
                            .find(|agent| agent.agent_id == tab.agent_id.0)
                            .map(|agent| (tab.terminal_id, agent.harness))
                    })
                    .collect::<Vec<_>>(),
            )
        };
        self.change_workflow_connections(workflow_id, generation, revision, disconnected, true)?;
        let stopped = agents
            .into_iter()
            .filter(|(terminal, _)| self.terminals.is_harness_running(*terminal))
            .map(|(terminal, _)| terminal)
            .collect::<Vec<_>>();
        let mut failure = None;
        for &terminal in &stopped {
            if let Err(error) = self.force_stop_harness(terminal) {
                failure.get_or_insert(error);
            }
        }
        if let Some(error) = failure {
            return Err(error);
        }
        let saved = self
            .lock_inner()?
            .workflows
            .workflows
            .iter()
            .find(|workflow| workflow.workflow_id == workflow_id)
            .cloned()
            .ok_or(ApplicationError::Poisoned)?;
        self.retire_completed_harness_hooks(&saved)?;
        let mut inner = self.lock_inner()?;
        if let Some(index) = inner
            .workflows
            .workflows
            .iter()
            .position(|workflow| workflow.workflow_id == workflow_id)
        {
            let mut workflow = inner.workflows.workflows[index].clone();
            workflow.run.as_mut().expect("run checked").message = Some("Agents force-stopped. Existing shells remain available; resume their conversations to continue.".into());
            inner.publish_run_best_effort(index, workflow)?;
        }
        Ok(CommandDisposition::Accepted)
    }

    #[cfg(test)]
    pub(super) fn stop_run_terminals(&self, terminals: &[TerminalId], message: &str) {
        for &terminal in terminals {
            if let Ok(observation) = self.terminals.observe(terminal)
                && let Ok(mut inner) = self.lock_inner()
                && let Err(error) = inner.stop_trace(terminal, observation, message)
            {
                tracing::warn!(%error, "couldn't record a workflow agent ending");
            }
            let _ = self.terminals.terminate(terminal);
        }
    }

    /// The bridge polls events off the UI thread. Polling also services bounded completion
    /// mailboxes, so terminal output (including an idle or exited process) cannot starve signals.
    pub(super) fn poll_workflow_signals(&self) -> Result<(), ApplicationError> {
        // Snapshot/event reads must stay available while a lifetime command waits on transcript
        // storage. The next idle poll will service these mailboxes.
        let _guard = match self.commands.try_lock() {
            Ok(guard) => guard,
            Err(std::sync::TryLockError::WouldBlock) => return Ok(()),
            Err(std::sync::TryLockError::Poisoned(_)) => return Err(ApplicationError::Poisoned),
        };
        self.poll_harness_steps()?;
        self.poll_decisions()?;
        self.prune_run_processes()?;
        let ready: Vec<_> = {
            let inner = self.lock_inner()?;
            inner
                .workflows
                .workflows
                .iter()
                .filter(|workflow| {
                    workflow.run.as_ref().is_some_and(|run| {
                        run.status == RunStatus::Running
                            && run
                                .graph
                                .as_ref()
                                .is_some_and(|graph| !graph.ready.is_empty())
                    })
                })
                .map(|workflow| workflow.workflow_id)
                .collect()
        };
        for workflow in ready {
            self.launch_workflow_stage(workflow, false)?;
        }
        let submissions: Vec<_> = {
            let processes = self
                .run_processes
                .lock()
                .map_err(|_| ApplicationError::Poisoned)?;
            processes
                .iter()
                .flat_map(|(&id, processes)| {
                    processes
                        .inboxes
                        .iter()
                        .filter_map(move |(&agent, (generation, inbox))| {
                            inbox.take().map(|signal| (id, agent, *generation, signal))
                        })
                })
                .collect()
        };
        for (workflow, agent, generation, submission) in submissions {
            let disposition = match submission {
                Ok(signal) => self.complete_workflow_role(workflow, agent, generation, signal)?,
                Err(message) => reject("invalidCompletion", &message),
            };
            if let CommandDisposition::Rejected { message, .. } = disposition {
                let processes = self
                    .run_processes
                    .lock()
                    .map_err(|_| ApplicationError::Poisoned)?;
                let Some((current_generation, inbox)) =
                    processes.get(&workflow).and_then(|p| p.inboxes.get(&agent))
                else {
                    continue;
                };
                // A review decision can finish a stage while another participant's submission
                // is already in this batch. Never deliver its stale rejection to a new invocation.
                if *current_generation != generation {
                    continue;
                }
                inbox.reject(&message);
                drop(processes);
                let mut inner = self.lock_inner()?;
                if let Some(index) = inner
                    .workflows
                    .workflows
                    .iter()
                    .position(|w| w.workflow_id == workflow)
                {
                    let mut workflow = inner.workflows.workflows[index].clone();
                    if let Some(run) = &mut workflow.run {
                        run.message = Some(message);
                        run.trace(
                            "completionRejected",
                            Some(agent.0),
                            None,
                            "Result report rejected; correct the submission and retry",
                        );
                    }
                    inner.publish_run_best_effort(index, workflow)?;
                }
            }
        }
        self.recover_completion_routes(Instant::now())?;
        self.terminals.poll_program_exits();
        Ok(())
    }

    #[expect(
        clippy::too_many_lines,
        reason = "route recovery and timeout notification stay paired"
    )]
    fn recover_completion_routes(&self, now: Instant) -> Result<(), ApplicationError> {
        let candidates: Vec<_> = {
            let registry = self
                .run_processes
                .lock()
                .map_err(|_| ApplicationError::Poisoned)?;
            registry
                .iter()
                .flat_map(|(&workflow, processes)| {
                    processes
                        .completion_routing
                        .iter()
                        .filter_map(move |(&agent, routing)| {
                            if let CompletionRouting::AwaitingPrompt(generation, since) = routing
                                && now.saturating_duration_since(*since) >= PROMPT_HOOK_TIMEOUT
                            {
                                Some((workflow, agent, *generation))
                            } else {
                                None
                            }
                        })
                })
                .collect()
        };
        if candidates.is_empty() {
            return Ok(());
        }
        let assignments: Vec<_> = {
            let inner = self.lock_inner()?;
            candidates
                .into_iter()
                .filter_map(|(workflow, agent, generation)| {
                    let saved = inner
                        .workflows
                        .workflows
                        .iter()
                        .find(|w| w.workflow_id == workflow)?;
                    let run = saved.run.as_ref()?;
                    if run.status != RunStatus::Running
                        || run.assignment_generation(agent.0) != generation
                    {
                        return None;
                    }
                    let terminal = saved
                        .agents
                        .iter()
                        .find(|a| a.agent_id == agent)?
                        .terminal_id;
                    Some((
                        workflow,
                        agent,
                        generation,
                        terminal,
                        run.follow_up_instructions(agent.0),
                        run.graph.is_some(),
                        run.mode_revision,
                    ))
                })
                .collect()
        };
        let notifications = {
            let mut registry = self
                .run_processes
                .lock()
                .map_err(|_| ApplicationError::Poisoned)?;
            let mut notifications = Vec::new();
            for (workflow, agent, generation, terminal, instructions, graph, revision) in
                assignments
            {
                let Some(processes) = registry.get_mut(&workflow) else {
                    continue;
                };
                let Some(routing) = processes.completion_routing.get_mut(&agent) else {
                    continue;
                };
                if !matches!(routing, CompletionRouting::AwaitingPrompt(assigned, since)
                    if *assigned == generation && now.saturating_duration_since(*since) >= PROMPT_HOOK_TIMEOUT)
                {
                    continue;
                }
                let Some((assigned, inbox)) = processes.inboxes.get(&agent) else {
                    continue;
                };
                if *assigned != generation {
                    continue;
                }
                // Commit sticky private routing before any late hook can reactivate the wrapper.
                *routing = CompletionRouting::Private;
                let command = if graph {
                    let command = processes
                        .completion_commands
                        .get(&agent)
                        .ok_or(ApplicationError::Poisoned)?;
                    command
                        .bind(inbox)
                        .map_err(ApplicationError::CompletionInbox)?;
                    command.command()
                } else {
                    if let Some(command) = processes.completion_commands.get(&agent) {
                        command.deactivate();
                    }
                    inbox.command()
                };
                notifications.push((terminal, format!("Use this completion command for the current assignment: {command}\n{instructions}"), RoutingStamp { revision, generation }));
            }
            notifications
        };
        for (terminal, message, stamp) in notifications {
            if self.terminals.is_running(terminal) {
                self.notify_workflow_agent(terminal, &message, stamp)?;
            }
        }
        Ok(())
    }

    pub(super) fn prune_run_processes(&self) -> Result<(), ApplicationError> {
        let mut processes = self
            .run_processes
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?;
        let inner = self.lock_inner()?;
        let mut decisions = Vec::new();
        for (id, runtime) in processes.iter_mut() {
            runtime.reap_inboxes();
            if let Some(run) = inner
                .workflows
                .workflows
                .iter()
                .find(|workflow| workflow.workflow_id == *id)
                .and_then(|workflow| workflow.run.as_ref())
                && run.status != RunStatus::Running
            {
                decisions.extend(std::mem::take(&mut runtime.decisions).into_values());
                if matches!(
                    run.status,
                    RunStatus::Paused | RunStatus::Failed | RunStatus::Interrupted
                ) {
                    runtime.disconnect_routes();
                }
            }
        }
        processes.retain(|id, _| {
            inner.workflows.workflows.iter().any(|w| {
                w.workflow_id == *id
                    && w.run.as_ref().is_some_and(|run| {
                        matches!(
                            run.status,
                            RunStatus::Running
                                | RunStatus::Idle
                                | RunStatus::Completed
                                | RunStatus::LimitReached
                        ) || w.terminal_ids().iter().any(|terminal| {
                            inner.terminals.get(terminal) == Some(&TerminalStatus::Running)
                        })
                    })
            })
        });
        drop(processes);
        drop(inner);
        drop(decisions);
        Ok(())
    }
}

impl super::Inner {
    pub(super) fn adopt_graph_prompt(
        &mut self,
        workflow_id: WorkflowId,
        terminal: TerminalId,
        prompt: String,
    ) -> Result<(), ApplicationError> {
        let Some(index) = self
            .workflows
            .workflows
            .iter()
            .position(|w| w.workflow_id == workflow_id)
        else {
            return Ok(());
        };
        let mut workflow = self.workflows.workflows[index].clone();
        let Some(agent) = workflow
            .agents
            .iter()
            .find(|agent| agent.terminal_id == terminal)
        else {
            return Ok(());
        };
        let Some(run) = workflow.run.as_mut() else {
            return Ok(());
        };
        match run.adopt_graph_task(agent.agent_id.0, prompt) {
            Ok(true) => self.publish_run(index, workflow),
            Ok(false) => Ok(()),
            Err(error) => {
                tracing::warn!(%error, "couldn't start the graph from its native prompt");
                Ok(())
            }
        }
    }

    fn record_agent_launch(
        &mut self,
        tabs: &mut [Agent],
        run: &mut WorkflowRun,
        agent_id: u64,
        terminal_id: TerminalId,
    ) -> Option<TerminalId> {
        self.terminals.insert(terminal_id, TerminalStatus::Running);
        let tab = tabs
            .iter_mut()
            .find(|tab| tab.agent_id.0 == agent_id)
            .expect("agent tab exists");
        let previous = (tab.terminal_id.value() != 0 && tab.terminal_id != terminal_id)
            .then_some(tab.terminal_id);
        if let Some(previous) = previous {
            self.terminals.remove(&previous);
        }
        tab.terminal_id = terminal_id;
        run.agents
            .iter_mut()
            .find(|agent| agent.agent_id == agent_id)
            .expect("launched agent belongs to run")
            .status = crate::RunAgentStatus::Running;
        previous
    }

    fn publish_launch(
        &mut self,
        index: usize,
        workflow: &mut Workflow,
        sessions: &[(TerminalId, &str)],
    ) -> Result<(), ApplicationError> {
        match self.publish_run_with_sessions(index, workflow.clone(), sessions) {
            Ok(()) => Ok(()),
            Err(error) => {
                tracing::warn!(%error, "failed to record stage launch; pausing coordination");
                workflow.run.as_mut().expect("run exists").finish(
                    RunStatus::Failed,
                    "Couldn't save the stage launch. Conversations remain available.",
                );
                workflow.status = WorkflowStatus::Running;
                workflow.ended_at = None;
                self.record_run(index, workflow.clone())
            }
        }
    }

    pub(super) fn publish_run(
        &mut self,
        index: usize,
        workflow: Workflow,
    ) -> Result<(), ApplicationError> {
        self.publish_run_with_sessions(index, workflow, &[])
    }

    fn publish_run_with_sessions(
        &mut self,
        index: usize,
        workflow: Workflow,
        sessions: &[(TerminalId, &str)],
    ) -> Result<(), ApplicationError> {
        let spans = self
            .folders
            .store()
            .save_workflow_run_with_sessions(&workflow, sessions)?;
        self.trace_spans.extend(spans);
        self.publish_trace(workflow.workflow_id)?;
        self.record_run(index, workflow)
    }

    pub(super) fn publish_run_best_effort(
        &mut self,
        index: usize,
        workflow: Workflow,
    ) -> Result<(), ApplicationError> {
        match self.folders.store().save_workflow_run(&workflow) {
            Ok(spans) => {
                self.trace_spans.extend(spans);
                self.publish_trace(workflow.workflow_id)?;
            }
            Err(error) => tracing::warn!(%error, "couldn't persist workflow state"),
        }
        self.record_run(index, workflow)
    }

    fn record_run(&mut self, index: usize, workflow: Workflow) -> Result<(), ApplicationError> {
        self.workflows.workflows[index] = workflow.clone();
        self.events
            .append(EventKind::State(StateEvent::WorkflowChanged(workflow)))?;
        Ok(())
    }
}

pub(super) fn workflow_status(status: RunStatus) -> WorkflowStatus {
    match status {
        RunStatus::Running | RunStatus::Idle | RunStatus::Paused => WorkflowStatus::Running,
        RunStatus::Completed => WorkflowStatus::Completed,
        RunStatus::Failed | RunStatus::LimitReached => WorkflowStatus::Failed,
        RunStatus::Cancelled => WorkflowStatus::Cancelled,
        RunStatus::Interrupted => WorkflowStatus::Interrupted,
    }
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;
    use std::os::unix::fs::PermissionsExt;
    use std::path::Path;
    use std::thread;
    use std::time::{Duration, Instant};

    use super::*;
    use crate::config::Config;
    use crate::{BuiltinType, Command, Decision, RequestId};

    const SIZE: TerminalSize = TerminalSize {
        rows: 24,
        columns: 100,
        pixel_width: 800,
        pixel_height: 480,
    };

    fn application(folder: &Path, bin: &Path, script: &str) -> Application {
        let binary = bin.join("pi");
        std::fs::write(&binary, format!("#!/bin/sh\n{script}\n")).unwrap();
        std::fs::set_permissions(binary, std::fs::Permissions::from_mode(0o755)).unwrap();
        let mut app = Application::with_event_capacity(4096).unwrap();
        app.harness_path = Some(OsString::from(format!("{}:/bin:/usr/bin", bin.display())));
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
            app.handle_command(RequestId(1), command)
                .unwrap()
                .disposition,
            CommandDisposition::Accepted
        );
    }

    fn launch_legacy(app: &Application, folder: &Path, builtin: BuiltinType) -> WorkflowId {
        launch_legacy_with_size(app, folder, builtin, SIZE, "Test the workflow")
    }

    fn launch_legacy_with_size(
        app: &Application,
        folder: &Path,
        builtin: BuiltinType,
        run_size: TerminalSize,
        prompt: &str,
    ) -> WorkflowId {
        launch_legacy_with_harness(app, folder, builtin, run_size, prompt, HarnessId::Pi)
    }

    fn launch_legacy_with_harness(
        app: &Application,
        folder: &Path,
        builtin: BuiltinType,
        run_size: TerminalSize,
        prompt: &str,
        harness: HarnessId,
    ) -> WorkflowId {
        accepted(
            app,
            Command::CreateWorkflow {
                folder: folder.to_owned(),
                session_id: None,
                kind: WorkflowKind::Draft,
                roles: vec![],
                size: SIZE,
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
        let definition = builtin.legacy_definition();
        let type_id = match builtin {
            BuiltinType::Adversarial => 1,
            BuiltinType::Coordinator => 2,
        };
        let directory = app
            .lock_inner()
            .unwrap()
            .folders
            .store()
            .workflow_directory
            .clone();
        std::fs::create_dir_all(&directory).unwrap();
        let mut file = toml::Table::new();
        file.insert("schema_version".into(), toml::Value::Integer(1));
        file.insert("id".into(), toml::Value::Integer(type_id));
        file.insert("version".into(), toml::Value::Integer(1));
        file.insert(
            "definition".into(),
            toml::Value::try_from(&definition).unwrap(),
        );
        std::fs::write(
            directory.join(format!("legacy-{type_id}.toml")),
            toml::to_string(&file).unwrap(),
        )
        .unwrap();
        let type_id = u64::try_from(type_id).unwrap();
        let roles = definition
            .roles
            .iter()
            .flat_map(|r| {
                (0..r.instances.min).map(|_| RoleLaunch {
                    model: None,
                    effort: None,
                    yolo: false,
                    role: r.id.0.clone(),
                    harness,
                })
            })
            .collect();
        accepted(
            app,
            Command::StartWorkflowRun {
                workflow_id: id,
                workflow_type: WorkflowTypeRef::User {
                    type_id,
                    version: 1,
                },
                prompt: prompt.into(),
                roles,
                size: run_size,
            },
        );
        id
    }

    fn wait_for(
        app: &Application,
        id: WorkflowId,
        mut check: impl FnMut(&Workflow) -> bool,
    ) -> Workflow {
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            let workflow = app
                .snapshot()
                .unwrap()
                .workflows
                .workflows
                .into_iter()
                .find(|w| w.workflow_id == id)
                .unwrap();
            if check(&workflow) {
                return workflow;
            }
            assert!(
                Instant::now() < deadline,
                "workflow didn't reach expected state: {:?}",
                workflow.run
            );
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn graph_definition(
        edges: &[(&str, &str, crate::GraphEvent)],
        finish: crate::GraphFinish,
    ) -> crate::WorkflowTypeDefinition {
        let mut definition = BuiltinType::Adversarial.definition();
        definition.stages.clear();
        definition.handoffs.clear();
        definition.review_loops.clear();
        definition.graph = Some(crate::AgentGraph {
            decisions: std::collections::BTreeMap::new(),
            edges: edges
                .iter()
                .enumerate()
                .map(|(index, (from, to, event))| crate::GraphEdge {
                    always: false,
                    output: None,
                    id: index.to_string(),
                    from: (*from).into(),
                    to: (*to).into(),
                    event: *event,
                })
                .collect(),
            receive: std::collections::BTreeMap::default(),
            review_agents: std::collections::BTreeSet::default(),
            positions: std::collections::BTreeMap::default(),
            finish,
            max_activations: 32,
        });
        definition
    }

    fn launch_graph(
        app: &Application,
        folder: &Path,
        definition: &crate::WorkflowTypeDefinition,
        prompt: &str,
    ) -> WorkflowId {
        let reference = WorkflowCatalog::new(app.lock_inner().unwrap().folders.store())
            .create(definition)
            .unwrap();
        accepted(
            app,
            Command::CreateWorkflow {
                folder: folder.into(),
                session_id: None,
                kind: WorkflowKind::Draft,
                roles: vec![],
                size: SIZE,
            },
        );
        let id = app.snapshot().unwrap().workflows.workflows[0].workflow_id;
        accepted(
            app,
            Command::StartWorkflowRun {
                workflow_id: id,
                workflow_type: reference,
                prompt: prompt.into(),
                roles: definition
                    .roles
                    .iter()
                    .filter(|role| {
                        !definition
                            .graph
                            .as_ref()
                            .is_some_and(|g| g.decisions.contains_key(&role.id.0))
                    })
                    .map(|role| RoleLaunch {
                        role: role.id.0.clone(),
                        harness: HarnessId::Pi,
                        model: None,
                        effort: None,
                        yolo: false,
                    })
                    .collect(),
                size: SIZE,
            },
        );
        id
    }

    fn recover_graph(app: &Application, folder: &Path, saved: &Workflow) -> Workflow {
        app.stop_run_terminals(&saved.terminal_ids(), "Simulate quit");
        app.run_processes.lock().unwrap().remove(&saved.workflow_id);
        let mut interrupted = saved.clone();
        interrupted.status = WorkflowStatus::Interrupted;
        interrupted.run.as_mut().unwrap().status = RunStatus::Interrupted;
        app.lock_inner()
            .unwrap()
            .publish_run(0, interrupted.clone())
            .unwrap();
        app.resume_workflow_run(&interrupted, folder).unwrap();
        app.snapshot().unwrap().workflows.workflows[0].clone()
    }

    #[test]
    fn an_exited_completed_producer_does_not_pause_its_reviewer() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(
            folder.path(),
            bin.path(),
            "while read line; do echo \"$line\"; done",
        );
        let id = launch_legacy(&app, folder.path(), BuiltinType::Adversarial);
        let initial = app.snapshot().unwrap().workflows.workflows[0].clone();
        finish_active_stage(&app, &initial, Decision::Done, "");
        app.lock_inner().unwrap().record_terminal_exit(
            initial.agents[0].terminal_id,
            Ok(crate::TerminalExit {
                exit_code: 0,
                signal: None,
            }),
        );
        let review = app.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(review.run.as_ref().unwrap().status, RunStatus::Running);
        finish_active_stage(&app, &review, Decision::Approve, "");
        let completed = app.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(completed.workflow_id, id);
        assert!(completed.run.as_ref().unwrap().work_completed());
    }

    #[test]
    fn a_recovered_choose_graph_keeps_both_outputs_and_accepts_result_selection() {
        use crate::{GraphEvent, GraphFinish};
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(
            folder.path(),
            bin.path(),
            "stty -echo; while read line; do :; done",
        );
        let definition = graph_definition(
            &[
                ("task", "implementer", GraphEvent::Task),
                ("task", "reviewer", GraphEvent::Task),
                ("implementer", "finish", GraphEvent::Done),
                ("reviewer", "finish", GraphEvent::Done),
            ],
            GraphFinish::Choose,
        );
        let id = launch_graph(&app, folder.path(), &definition, "The same task");
        let current = app.snapshot().unwrap().workflows.workflows[0].clone();
        for agent in &current.agents {
            accepted(
                &app,
                Command::CompleteWorkflowRole {
                    workflow_id: id,
                    agent_id: agent.agent_id,
                    generation: 1,
                    signal: CompletionSignal {
                        decision: Decision::Done,
                        summary: agent.role.clone(),
                        assignments: vec![],
                        task: String::new(),
                    },
                },
            );
        }
        let saved = app.snapshot().unwrap().workflows.workflows[0].clone();
        assert!(saved.run.as_ref().unwrap().graph_choice_ready());
        let resumed = recover_graph(&app, folder.path(), &saved);
        let run = resumed.run.as_ref().unwrap();
        assert!(run.graph_choice_ready());
        assert_eq!(run.graph.as_ref().unwrap().outputs.len(), 2);
        accepted(
            &app,
            Command::ChooseWorkflowResult {
                workflow_id: id,
                generation: run.generation,
                agent_id: saved.agents[1].agent_id,
            },
        );
        let selected = app.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(selected.status, WorkflowStatus::Running);
        assert_eq!(
            selected
                .run
                .as_ref()
                .unwrap()
                .graph
                .as_ref()
                .unwrap()
                .outputs
                .len(),
            2
        );
    }

    fn submit_completion_command(
        app: &Application,
        id: WorkflowId,
        command: &str,
        signal: &CompletionSignal,
    ) {
        use std::io::Write;
        use std::process::{Command as ProcessCommand, Stdio};
        let mut child = ProcessCommand::new("/bin/sh")
            .args(["-c", command])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(&serde_json::to_vec(signal).unwrap())
            .unwrap();
        wait_for(app, id, |_| {
            app.poll_workflow_signals().unwrap();
            child.try_wait().unwrap().is_some()
        });
        assert!(child.wait().unwrap().success());
    }

    #[test]
    fn an_idle_graph_streams_pieces_with_one_command_and_keeps_its_producer_live() {
        use crate::{GraphEvent, GraphFinish};
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(
            folder.path(),
            bin.path(),
            "stty -echo; while read line; do :; done",
        );
        let definition = graph_definition(
            &[
                ("task", "implementer", GraphEvent::Task),
                ("implementer", "reviewer", GraphEvent::PieceReady),
                ("reviewer", "finish", GraphEvent::Done),
            ],
            GraphFinish::All,
        );
        let id = launch_graph(&app, folder.path(), &definition, "");
        let idle = app.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(idle.terminal_ids().len(), 1);
        assert!(idle.run.as_ref().unwrap().needs_task());
        let resumed = recover_graph(&app, folder.path(), &idle);
        assert_eq!(resumed.run.as_ref().unwrap().status, RunStatus::Idle);
        accepted(
            &app,
            Command::SubmitWorkflowTask {
                workflow_id: id,
                generation: 2,
                prompt: "Process these pieces".into(),
            },
        );
        let running = app.snapshot().unwrap().workflows.workflows[0].clone();
        app.recover_completion_routes(Instant::now() + PROMPT_HOOK_TIMEOUT)
            .unwrap();
        let producer = running.agents[0].agent_id;
        let receiver = running.agents[1].agent_id;
        let producer_terminal = running.agents[0].terminal_id;
        let command =
            app.run_processes.lock().unwrap()[&id].completion_commands[&producer].command();
        for (decision, summary) in [
            (Decision::PieceReady, "Piece one"),
            (Decision::PieceReady, "Piece two"),
            (Decision::Done, "Producer done"),
        ] {
            submit_completion_command(
                &app,
                id,
                &command,
                &CompletionSignal {
                    decision,
                    summary: summary.into(),
                    assignments: vec![],
                    task: String::new(),
                },
            );
            assert!(app.terminals.is_running(producer_terminal));
        }
        let streamed = app.snapshot().unwrap().workflows.workflows[0].clone();
        let run = streamed.run.as_ref().unwrap();
        assert_eq!(
            run.graph.as_ref().unwrap().queues[&receiver.0]
                .values()
                .map(std::collections::VecDeque::len)
                .sum::<usize>(),
            1
        );
        assert!(run.incoming[&receiver.0].contains("Piece one"));
        for result in [1, 2] {
            let generation = app.snapshot().unwrap().workflows.workflows[0]
                .run
                .as_ref()
                .unwrap()
                .assignment_generation(receiver.0);
            accepted(
                &app,
                Command::CompleteWorkflowRole {
                    workflow_id: id,
                    agent_id: receiver,
                    generation,
                    signal: CompletionSignal {
                        decision: Decision::Done,
                        summary: format!("Result {result}"),
                        assignments: vec![],
                        task: String::new(),
                    },
                },
            );
        }
        let completed = app.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(completed.status, WorkflowStatus::Running);
        assert_eq!(completed.agents[0].terminal_id, producer_terminal);
        assert!(app.terminals.is_running(producer_terminal));
        accepted(&app, Command::ForceStopWorkflowAgents { workflow_id: id });
    }

    // A real PTY harness process invokes the same completion helper an installed harness uses.
    const FAKE: &str = r#"
    extension=''
    instructions=''
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
        if [ "$1" = --extension ]; then shift; extension=$1;
        elif [ "$1" = --append-system-prompt ]; then shift; instructions=$1; fi
        shift
    done
    prompt=$2
    command=$(printf '%s\n' "$instructions" | sed -n "s/^'\(.*\/complete\)' <<.*/\1/p")
    socket=$(sed -n 's/.*const socketPath = "\(.*\)";/\1/p' "$extension")
    if [ -n "$prompt" ]; then
      case "$instructions" in 'You are Worker '*|*'Outgoing links:'*) prompt="$instructions
$prompt" ;; esac
    fi
    round=0
    paste_start=$(printf '\033[200~')
    paste_end=$(printf '\033[201~')
    while :; do
    replacement=$(printf '%s\n' "$prompt" | sed -n "s/^Use this completion command for the current assignment: '\(.*\)'/\1/p")
    if [ -n "$replacement" ]; then command=$replacement; fi
    prompt=$(printf '%s\n' "$prompt" | sed '/^Use this completion command for the current assignment:/d')
    round=$((round + 1))
    turn="turn-$$-$round"
    completion=''
    decision=''
    case "$prompt" in
      'You are Implementer '*|'Continue with the Implement stage.'*) echo implement >> order; decision=done ;;
      'You are Reviewer '*|'Continue with the Review stage.'*) echo review >> order; decision=approve
          if [ -f request-changes ]; then decision=requestChanges; fi ;;
      'You are Coordinator in the Split '*|'Continue with the Split stage.'*)
          echo split >> order
          completion='{"decision":"done","summary":"Result or feedback","assignments":[{"role":"worker","instance":1,"task":"First sub-task","files":["first.txt"]},{"role":"worker","instance":2,"task":"Second sub-task","files":["second.txt"]}]}' ;;
      'You are Worker 1 '*) echo worker1 >> order; printf '%s' "$prompt" > worker1-prompt
          while [ ! -f worker2-prompt ]; do sleep 0.01; done; decision=done ;;
      'You are Worker 2 '*) echo worker2 >> order; printf '%s' "$prompt" > worker2-prompt
          while [ ! -f worker1-prompt ]; do sleep 0.01; done; decision=done ;;
      'You are Coordinator in the Gather '*|'Continue with the Gather stage.'*) echo gather >> order; printf '%s' "$prompt" > gather-prompt; decision=done ;;
      *) printf '%s' "$prompt" > "feedback-$$" ;;
    esac
    if [ -n "$completion" ] || [ -n "$decision" ]; then
    curl --silent --unix-socket "$socket" --data-binary "{\"type\":\"prompt\",\"turn_id\":\"$turn\",\"detail\":\"Assignment\"}" http://localhost/
    case "$command" in *handshake-agent-completion-*)
        while [ ! -f "$(dirname "$command")/current" ]; do sleep 0.01; done ;;
    esac
    if [ -z "$completion" ]; then
        completion=$(printf '{"decision":"%s","summary":"Result or feedback"}' "$decision")
    fi
    printf '%s' "$completion" | "$command"
    curl --silent --unix-socket "$socket" --data-binary "{\"type\":\"response\",\"turn_id\":\"$turn\",\"detail\":\"Finished\"}" http://localhost/
    fi
    prompt=''
    while IFS= read -r line; do
        last=false
        case "$line" in *"$paste_end") line=${line%"$paste_end"}; last=true ;; esac
        line=${line#"$paste_start"}
        prompt="$prompt$line
"
        if [ "$last" = true ]; then break; fi
    done
    [ -n "$prompt" ] || exit
    done
    "#;

    #[test]
    fn kiro_run_reopens_immediately_with_its_exact_profile_and_fresh_lease() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(
            folder.path(),
            bin.path(),
            "printf '%s\\n' \"$@\" > kiro-arguments; while [ \"$#\" -gt 0 ]; do if [ \"$1\" = --agent ]; then printf '%s' \"$2\" > kiro-profile; fi; shift; done; while read line; do echo \"$line\"; done",
        );
        std::fs::copy(bin.path().join("pi"), bin.path().join("kiro-cli")).unwrap();
        let id = launch_legacy_with_harness(
            &app,
            folder.path(),
            BuiltinType::Adversarial,
            SIZE,
            "Kiro task; quoted sender command: 'sender-completion'.",
            HarnessId::Kiro,
        );
        let original = wait_for(&app, id, |w| {
            !w.agents.is_empty()
                && std::fs::read_to_string(folder.path().join("kiro-profile"))
                    .is_ok_and(|s| !s.is_empty())
        });
        let old_terminal = original.agents[0].terminal_id;
        let profile = std::fs::read_to_string(folder.path().join("kiro-profile")).unwrap();
        let initial = std::fs::read_to_string(folder.path().join("kiro-arguments")).unwrap();
        let command = app.run_processes.lock().unwrap()[&id].completion_commands
            [&original.agents[0].agent_id]
            .command();
        assert!(initial.contains("quoted sender command: 'sender-completion'"));
        assert!(initial.ends_with(&format!(
            "Use this completion command for your current assignment: {command}\n"
        )));
        assert!(
            !initial.lines().any(|argument| argument == "--"),
            "{initial}"
        );
        app.lock_inner()
            .unwrap()
            .folders
            .store()
            .remember_harness_session(old_terminal, &format!("sess_fixture:{profile}"))
            .unwrap();
        accepted(&app, Command::CloseFolder);
        std::fs::remove_file(folder.path().join("kiro-profile")).unwrap();
        accepted(
            &app,
            Command::OpenFolder {
                path: folder.path().to_owned(),
            },
        );
        let resumed = wait_for(&app, id, |w| {
            w.status == WorkflowStatus::Running
                && w.agents[0].terminal_id != old_terminal
                && std::fs::read_to_string(folder.path().join("kiro-arguments"))
                    .is_ok_and(|args| args.contains("--resume-id\nsess_fixture"))
                && std::fs::read_to_string(folder.path().join("kiro-profile"))
                    .is_ok_and(|value| value == profile)
        });
        assert_eq!(
            std::fs::read_to_string(folder.path().join("kiro-profile")).unwrap(),
            profile
        );
        assert!(
            resumed.run.as_ref().unwrap().generation > original.run.as_ref().unwrap().generation
        );
        let args = std::fs::read_to_string(folder.path().join("kiro-arguments")).unwrap();
        assert!(args.contains("--resume-id\nsess_fixture"), "{args}");
    }

    #[test]
    fn restored_conversations_wait_for_fresh_work_before_accepting_results() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(
            folder.path(),
            bin.path(),
            "while read line; do echo \"$line\"; done",
        );
        let id = launch_legacy(&app, folder.path(), BuiltinType::Adversarial);
        let original = wait_for(&app, id, |w| !w.terminal_ids().is_empty());
        let old_terminal = original.agents[0].terminal_id;
        app.lock_inner()
            .unwrap()
            .folders
            .store()
            .remember_harness_session(old_terminal, "/tmp/implementer.jsonl")
            .unwrap();
        accepted(&app, Command::CloseFolder);
        accepted(
            &app,
            Command::OpenFolder {
                path: folder.path().to_owned(),
            },
        );
        let restored = wait_for(&app, id, |w| w.status == WorkflowStatus::Running);
        let run = restored.run.as_ref().unwrap();
        assert_eq!(run.stage_index, original.run.as_ref().unwrap().stage_index);
        assert!(run.generation > original.run.as_ref().unwrap().generation);
        assert_ne!(restored.agents[0].terminal_id, old_terminal);
        assert!(
            restored
                .terminal_history
                .iter()
                .any(|entry| entry.terminal_id == old_terminal)
        );
        assert_eq!(run.status, RunStatus::Idle);
        assert!(run.completions.is_empty());
        accepted(
            &app,
            Command::ContinueWorkflowRun {
                workflow_id: id,
                agent_id: restored.agents[0].agent_id,
                generation: run.generation,
                mode_revision: run.mode_revision,
            },
        );
        let current = app.snapshot().unwrap().workflows.workflows[0].clone();
        finish_active_stage(&app, &current, Decision::Done, "Fresh task after restore");
        assert_eq!(
            app.snapshot().unwrap().workflows.workflows[0]
                .run
                .as_ref()
                .unwrap()
                .stage_index,
            1
        );
    }

    #[test]
    fn fake_harness_completes_adversarial_and_hits_review_limit() {
        for limited in [false, true] {
            let folder = tempfile::tempdir().unwrap();
            let bin = tempfile::tempdir().unwrap();
            if limited {
                std::fs::write(folder.path().join("request-changes"), "").unwrap();
            }
            let app = application(folder.path(), bin.path(), FAKE);
            let id = launch_legacy(&app, folder.path(), BuiltinType::Adversarial);
            let result = wait_for(&app, id, |w| {
                w.run
                    .as_ref()
                    .is_some_and(|run| run.status != RunStatus::Running)
            });
            assert_eq!(
                result.run.as_ref().unwrap().status,
                if limited {
                    RunStatus::Paused
                } else {
                    RunStatus::Idle
                }
            );
            assert_eq!(
                std::fs::read_to_string(folder.path().join("order")).unwrap(),
                "implement\nreview\n".repeat(if limited { 4 } else { 1 })
            );
            assert_run_trace_history(&app, &result, if limited { 8 } else { 2 });
        }
    }

    fn finish_active_stage(app: &Application, workflow: &Workflow, decision: Decision, task: &str) {
        let run = workflow.run.as_ref().unwrap();
        for agent in run.active_agents() {
            accepted(
                app,
                Command::CompleteWorkflowRole {
                    workflow_id: workflow.workflow_id,
                    agent_id: AgentId(agent.agent_id),
                    generation: run.generation,
                    signal: CompletionSignal {
                        decision: if run.is_reviewer(agent.agent_id) {
                            decision
                        } else {
                            Decision::Done
                        },
                        summary: "Result or feedback".into(),
                        task: task.into(),
                        assignments: run
                            .assignment_targets(agent.agent_id)
                            .iter()
                            .map(|target| crate::Assignment {
                                role: target.role.clone(),
                                instance: target.instance,
                                task: format!("Task {}", target.instance),
                                files: vec![format!("{}.txt", target.instance)],
                            })
                            .collect(),
                    },
                },
            );
        }
    }

    fn finish_remaining_stages(app: &Application, id: WorkflowId) {
        loop {
            let workflow = app.snapshot().unwrap().workflows.workflows[0].clone();
            assert_eq!(workflow.workflow_id, id);
            if workflow
                .run
                .as_ref()
                .is_some_and(|run| run.status != RunStatus::Running)
            {
                break;
            }
            finish_active_stage(app, &workflow, Decision::Approve, "");
        }
    }

    const RECORD_INPUT: &str = r#"
        extension=''
        instructions=''
        while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
            if [ "$1" = --extension ]; then shift; extension=$1;
            elif [ "$1" = --append-system-prompt ]; then shift; instructions=$1; fi
            shift
        done
        prompt=$2
        case "$instructions" in 'You are Implementer '*) role=implement ;; *) role=review ;; esac
        printf '%s' "$prompt" > "$role-launch"
        printf '%s\n' "$instructions" | sed -n "s/^'\(.*\/complete\)' <<.*/\1/p" > "$role-command"
        if [ -n "$extension" ]; then
            sed -n 's/.*const socketPath = "\(.*\)";/\1/p' "$extension" > "$role-socket"
        fi
        stty -echo
        touch "$role-ready"
        while IFS= read -r line; do printf '%s\n' "$line" >> "$role-input"; done
    "#;

    fn send_implementer_hook(app: &Application, folder: &Path, kind: &str, turn: &str) {
        let socket = std::fs::read_to_string(folder.join("implement-socket")).unwrap();
        let payload = serde_json::json!({"type":kind,"turn_id":turn,"detail":"Assignment"});
        assert!(
            std::process::Command::new("/usr/bin/curl")
                .args([
                    "--silent",
                    "--max-time",
                    "1",
                    "--unix-socket",
                    socket.trim(),
                    "--data-binary",
                    &payload.to_string(),
                    "http://localhost/"
                ])
                .output()
                .unwrap()
                .status
                .success()
        );
        app.poll_harness_steps().unwrap();
        if kind == "response" {
            thread::sleep(Duration::from_millis(60));
            app.poll_harness_steps().unwrap();
        }
    }

    #[test]
    fn previous_turn_cannot_complete_a_reused_assignment_after_manual_handoff() {
        use std::io::Write;
        use std::process::{Command as ProcessCommand, Stdio};

        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), RECORD_INPUT);
        let id = launch_legacy(&app, folder.path(), BuiltinType::Adversarial);
        let initial = wait_for(&app, id, |_| folder.path().join("implement-ready").exists());
        let terminal = initial.agents[0].terminal_id;
        let command = std::fs::read_to_string(folder.path().join("implement-command")).unwrap();
        send_implementer_hook(&app, folder.path(), "prompt", "old");
        finish_active_stage(&app, &initial, Decision::Done, "");
        let review = app.snapshot().unwrap().workflows.workflows[0].clone();
        finish_active_stage(&app, &review, Decision::RequestChanges, "");
        let reused = app.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(reused.agents[0].terminal_id, terminal);
        for turn in [None, Some("old"), Some("new")] {
            if let Some(turn) = turn {
                send_implementer_hook(&app, folder.path(), "prompt", turn);
            }
            let output = ProcessCommand::new(command.trim()).output().unwrap();
            assert!(
                !output.status.success(),
                "an old turn must not reach the new inbox"
            );
            assert!(
                app.snapshot().unwrap().workflows.workflows[0]
                    .run
                    .as_ref()
                    .unwrap()
                    .completions
                    .is_empty()
            );
        }
        // The missing old Stop must not stall the new assignment: its private path is safe.
        let fresh = app.run_processes.lock().unwrap()[&id].inboxes[&reused.agents[0].agent_id]
            .1
            .command();
        let mut child = ProcessCommand::new("/bin/sh")
            .args(["-c", &fresh])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(br#"{"decision":"done","summary":"Fresh result"}"#)
            .unwrap();
        let advanced = wait_for(&app, id, |w| {
            w.run.as_ref().unwrap().generation > reused.run.as_ref().unwrap().generation
        });
        assert!(child.wait().unwrap().success());
        assert_eq!(advanced.agents[0].terminal_id, terminal);
        assert!(
            advanced.run.unwrap().incoming[&advanced.agents[1].agent_id.0].contains("Fresh result")
        );
    }

    fn reuse_after_identified_response(
        app: &Application,
        folder: &Path,
        id: WorkflowId,
        draft: bool,
    ) -> Workflow {
        let initial = wait_for(app, id, |_| folder.join("implement-ready").exists());
        send_implementer_hook(app, folder, "prompt", "old");
        send_implementer_hook(app, folder, "response", "old");
        finish_active_stage(app, &initial, Decision::Done, "");
        let review = app.snapshot().unwrap().workflows.workflows[0].clone();
        if draft {
            app.write_terminal_input(initial.agents[0].terminal_id, b"Unfinished user draft")
                .unwrap();
        }
        finish_active_stage(app, &review, Decision::RequestChanges, "");
        app.snapshot().unwrap().workflows.workflows[0].clone()
    }

    fn private_command(app: &Application, workflow: &Workflow) -> String {
        app.run_processes.lock().unwrap()[&workflow.workflow_id].inboxes
            [&workflow.agents[0].agent_id]
            .1
            .command()
    }

    fn submit_private_result(app: &Application, workflow: &Workflow) -> Workflow {
        submit_result(app, workflow, &private_command(app, workflow), "")
    }

    fn submit_result(
        app: &Application,
        workflow: &Workflow,
        command: &str,
        task: &str,
    ) -> Workflow {
        use std::io::Write;
        use std::process::{Command as ProcessCommand, Stdio};
        let mut child = ProcessCommand::new("/bin/sh")
            .args(["-c", command])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(
                &serde_json::to_vec(&CompletionSignal {
                    decision: Decision::Done,
                    summary: "Fresh result".into(),
                    assignments: vec![],
                    task: task.into(),
                })
                .unwrap(),
            )
            .unwrap();
        let advanced = wait_for(app, workflow.workflow_id, |w| {
            w.run.as_ref().unwrap().generation > workflow.run.as_ref().unwrap().generation
        });
        assert!(child.wait().unwrap().success());
        advanced
    }

    #[test]
    fn slow_user_follow_up_waits_for_submission_and_a_prompt_avoids_fallback() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), RECORD_INPUT);
        let id = launch_legacy(&app, folder.path(), BuiltinType::Adversarial);
        let first = wait_for(&app, id, |_| folder.path().join("implement-ready").exists());
        let terminal = first.agents[0].terminal_id;
        let remembered = std::fs::read_to_string(folder.path().join("implement-command")).unwrap();
        send_implementer_hook(&app, folder.path(), "prompt", "old");
        send_implementer_hook(&app, folder.path(), "response", "old");
        finish_active_stage(&app, &first, Decision::Done, "");
        let review = app.snapshot().unwrap().workflows.workflows[0].clone();
        finish_active_stage(&app, &review, Decision::Approve, "");
        let completed = wait_for(&app, id, |_| {
            std::fs::read_to_string(folder.path().join("implement-input")).is_ok_and(|text| {
                text.contains("review is complete") && text.ends_with("\x1b[201~\n")
            })
        });
        let before = std::fs::read_to_string(folder.path().join("implement-input")).unwrap();
        accepted(
            &app,
            Command::ContinueWorkflowRun {
                workflow_id: id,
                agent_id: completed.agents[0].agent_id,
                generation: completed.run.unwrap().generation,
                mode_revision: 0,
            },
        );
        app.write_terminal_input(terminal, b"My next task").unwrap();
        app.recover_completion_routes(Instant::now() + PROMPT_HOOK_TIMEOUT * 10)
            .unwrap();
        assert!(matches!(
            app.run_processes.lock().unwrap()[&id].completion_routing[&first.agents[0].agent_id],
            CompletionRouting::AwaitingSubmission(3)
        ));
        assert_eq!(
            std::fs::read_to_string(folder.path().join("implement-input")).unwrap(),
            before
        );
        app.write_terminal_input(terminal, b"\r").unwrap();
        let continued = app.snapshot().unwrap().workflows.workflows[0].clone();
        send_implementer_hook(&app, folder.path(), "prompt", "new");
        app.recover_completion_routes(Instant::now() + PROMPT_HOOK_TIMEOUT * 10)
            .unwrap();
        assert!(matches!(
            app.run_processes.lock().unwrap()[&id].completion_routing[&first.agents[0].agent_id],
            CompletionRouting::Active(3)
        ));
        let command = format!("'{}'", remembered.trim());
        let review = submit_result(&app, &continued, &command, "My next task");
        assert_eq!(review.run.unwrap().prompt, "My next task");
        assert_eq!(review.agents[0].terminal_id, terminal);
    }

    #[test]
    fn missing_current_prompt_recovers_privately_and_keeps_later_reuse_private() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), RECORD_INPUT);
        let id = launch_legacy(&app, folder.path(), BuiltinType::Adversarial);
        let reused = reuse_after_identified_response(&app, folder.path(), id, false);
        let terminal = reused.agents[0].terminal_id;
        let old = std::fs::read_to_string(folder.path().join("implement-command")).unwrap();
        assert!(matches!(
            app.run_processes.lock().unwrap()[&id].completion_routing[&reused.agents[0].agent_id],
            CompletionRouting::AwaitingPrompt(3, _)
        ));
        let command = private_command(&app, &reused);
        app.recover_completion_routes(Instant::now() + PROMPT_HOOK_TIMEOUT)
            .unwrap();
        wait_for(&app, id, |_| {
            std::fs::read_to_string(folder.path().join("implement-input"))
                .is_ok_and(|text| text.contains(&command))
        });
        send_implementer_hook(&app, folder.path(), "prompt", "late");
        assert!(
            !std::process::Command::new(old.trim())
                .output()
                .unwrap()
                .status
                .success()
        );
        let review = submit_private_result(&app, &reused);
        send_implementer_hook(&app, folder.path(), "response", "late");
        assert!(app.harness_turn_finished(terminal).unwrap());
        finish_active_stage(&app, &review, Decision::RequestChanges, "");
        let next = app.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(next.agents[0].terminal_id, terminal);
        assert!(matches!(
            app.run_processes.lock().unwrap()[&id].completion_routing[&next.agents[0].agent_id],
            CompletionRouting::Private
        ));
        let next_command = private_command(&app, &next);
        assert_ne!(next_command, command);
        wait_for(&app, id, |_| {
            std::fs::read_to_string(folder.path().join("implement-input"))
                .is_ok_and(|text| text.contains(&next_command))
        });
        assert!(
            !std::process::Command::new(old.trim())
                .output()
                .unwrap()
                .status
                .success()
        );
        assert_eq!(
            submit_private_result(&app, &next).run.unwrap().generation,
            6
        );
    }

    #[test]
    fn deferred_stage_message_starts_recovery_only_after_the_user_submits() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), RECORD_INPUT);
        let id = launch_legacy(&app, folder.path(), BuiltinType::Adversarial);
        let reused = reuse_after_identified_response(&app, folder.path(), id, true);
        let terminal = reused.agents[0].terminal_id;
        let command = private_command(&app, &reused);
        app.recover_completion_routes(Instant::now() + PROMPT_HOOK_TIMEOUT * 10)
            .unwrap();
        assert!(matches!(
            app.run_processes.lock().unwrap()[&id].completion_routing[&reused.agents[0].agent_id],
            CompletionRouting::AwaitingSubmission(3)
        ));
        assert!(
            !std::fs::read_to_string(folder.path().join("implement-input"))
                .unwrap_or_default()
                .contains(&command)
        );
        app.write_terminal_input(terminal, b"\r").unwrap();
        assert!(matches!(
            app.run_processes.lock().unwrap()[&id].completion_routing[&reused.agents[0].agent_id],
            CompletionRouting::AwaitingPrompt(3, _)
        ));
        app.recover_completion_routes(Instant::now() + PROMPT_HOOK_TIMEOUT)
            .unwrap();
        wait_for(&app, id, |_| {
            std::fs::read_to_string(folder.path().join("implement-input"))
                .is_ok_and(|text| text.contains(&command))
        });
        let input = std::fs::read_to_string(folder.path().join("implement-input")).unwrap();
        assert!(input.contains("Unfinished user draft"));
        assert!(input.contains("Result or feedback"));
        assert_eq!(
            submit_private_result(&app, &reused).run.unwrap().generation,
            4
        );
    }

    #[test]
    fn recovery_does_not_send_an_obsolete_command_after_completion_or_cancellation() {
        for cancelled in [false, true] {
            let folder = tempfile::tempdir().unwrap();
            let bin = tempfile::tempdir().unwrap();
            let app = application(folder.path(), bin.path(), RECORD_INPUT);
            let id = launch_legacy(&app, folder.path(), BuiltinType::Adversarial);
            let reused = reuse_after_identified_response(&app, folder.path(), id, false);
            let command = private_command(&app, &reused);
            if cancelled {
                accepted(&app, Command::ForceStopWorkflowAgents { workflow_id: id });
            } else {
                finish_active_stage(&app, &reused, Decision::Done, "");
            }
            app.recover_completion_routes(Instant::now() + PROMPT_HOOK_TIMEOUT * 10)
                .unwrap();
            assert!(
                !std::fs::read_to_string(folder.path().join("implement-input"))
                    .unwrap_or_default()
                    .contains(&command)
            );
        }
    }

    #[test]
    fn unavailable_observer_receives_a_new_private_command_without_repeated_setup() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), RECORD_INPUT);
        let wrapper = bin.path().join("opencode");
        std::fs::write(
            &wrapper,
            r#"#!/usr/bin/python3
import json, os, re, sys
config = json.loads(os.environ['OPENCODE_CONFIG_CONTENT'])
plugin = next(path.removeprefix('file://') for path in config['plugin'] if path.endswith('handshake-observer.mjs'))
with open(plugin) as source:
    match = re.search(r'output.system.push\(("(?:\\.|[^"\\])*")\)', source.read())
instructions = json.loads(match.group(1))
prompt = next((arg.removeprefix('--prompt=') for arg in sys.argv if arg.startswith('--prompt=')), '')
os.execvp('pi', ['pi', '--append-system-prompt', instructions, '--', prompt])
"#,
        )
        .unwrap();
        std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o755)).unwrap();
        let id = launch_legacy_with_harness(
            &app,
            folder.path(),
            BuiltinType::Adversarial,
            SIZE,
            "Test",
            HarnessId::Opencode,
        );
        let initial = wait_for(&app, id, |_| folder.path().join("implement-ready").exists());
        let old = std::fs::read_to_string(folder.path().join("implement-command")).unwrap();
        // Exercise fallback when an observer cannot be installed/retained, independently of
        // which built-in harness currently supports observation.
        app.harness_steps
            .lock()
            .unwrap()
            .remove(&initial.agents[0].terminal_id);
        app.run_processes
            .lock()
            .unwrap()
            .get_mut(&id)
            .unwrap()
            .completion_commands
            .remove(&initial.agents[0].agent_id);
        finish_active_stage(&app, &initial, Decision::Done, "");
        let review = app.snapshot().unwrap().workflows.workflows[0].clone();
        finish_active_stage(&app, &review, Decision::RequestChanges, "");
        let reused = wait_for(&app, id, |_| {
            std::fs::read_to_string(folder.path().join("implement-input")).is_ok_and(|text| {
                text.contains("Use this completion command")
                    && text.contains("Continue with the Implement stage.")
            })
        });
        assert_eq!(reused.agents[0].terminal_id, initial.agents[0].terminal_id);
        assert!(std::process::Command::new(old.trim()).output().is_err());
        let text = std::fs::read_to_string(folder.path().join("implement-input")).unwrap();
        assert!(text.contains("Continue with the Implement stage."));
        assert!(!text.contains(old.trim()));
        assert!(!text.contains("You are Implementer"));
        let processes = app.run_processes.lock().unwrap();
        assert!(
            !processes[&id]
                .completion_commands
                .contains_key(&reused.agents[0].agent_id)
        );
        assert!(
            text.contains(
                &processes[&id].inboxes[&reused.agents[0].agent_id]
                    .1
                    .command()
            )
        );
    }

    fn change_agents_disconnected(app: &Application, id: WorkflowId, agents_disconnected: bool) {
        // Read the UI's current state without polling and accepting queued completions first.
        let workflow = app
            .lock_inner()
            .unwrap()
            .workflows
            .workflows
            .iter()
            .find(|workflow| workflow.workflow_id == id)
            .unwrap()
            .clone();
        let run = workflow.run.as_ref().unwrap();
        accepted(
            app,
            Command::SetWorkflowAgentsDisconnected {
                workflow_id: id,
                generation: run.generation,
                mode_revision: run.mode_revision,
                agents_disconnected,
            },
        );
    }

    #[test]
    fn waiting_for_an_agent_writer_does_not_lock_application_state() {
        for changing_mode in [true, false] {
            let folder = tempfile::tempdir().unwrap();
            let bin = tempfile::tempdir().unwrap();
            let app = Arc::new(application(folder.path(), bin.path(), RECORD_INPUT));
            let id = launch_legacy(&app, folder.path(), BuiltinType::Adversarial);
            finish_remaining_stages(&app, id);
            let completed = app.snapshot().unwrap().workflows.workflows[0].clone();
            let generation = completed.run.as_ref().unwrap().generation;
            let terminal = completed.agents[0].terminal_id;
            let input = app.workflow_agent_input(terminal).unwrap().unwrap();
            // A blocked PTY write owns this same mutex. No state lock may be held while waiting.
            let writer = input.lock().unwrap();
            let references = Arc::strong_count(&input);
            let worker = Arc::clone(&app);
            let pending = thread::spawn(move || {
                if changing_mode {
                    worker
                        .set_workflow_agents_disconnected(id, generation, 0, true)
                        .unwrap();
                } else {
                    worker
                        .notify_final_review_feedback(id, generation, 0, terminal, "Final feedback")
                        .unwrap();
                }
            });
            let deadline = Instant::now() + Duration::from_secs(2);
            while Arc::strong_count(&input) == references && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(1));
            }
            let waiting = Arc::strong_count(&input) > references;
            let state_available = app.inner.try_lock().is_ok();
            drop(writer);
            pending.join().unwrap();
            assert!(waiting && state_available);
        }
    }

    fn submit_individual_follow_ups(
        app: &Application,
        folder: &Path,
        id: WorkflowId,
        builtin: BuiltinType,
        completed: &Workflow,
    ) {
        let generation = completed.run.as_ref().unwrap().generation;
        let input = app
            .workflow_agent_input(completed.agents[0].terminal_id)
            .unwrap()
            .unwrap();
        // Final review feedback deferred behind an unfinished draft must not leak into a
        // private turn, including delivery queued just before the mode change.
        app.write_terminal_input(completed.agents[0].terminal_id, b"My draft")
            .unwrap();
        input
            .lock()
            .unwrap()
            .notify(
                &app.terminals,
                completed.agents[0].terminal_id,
                "Initial feedback",
                RoutingStamp {
                    revision: 0,
                    generation,
                },
                true,
            )
            .unwrap();
        change_agents_disconnected(app, id, true);
        app.notify_final_review_feedback(
            id,
            generation,
            0,
            completed.agents[0].terminal_id,
            "Obsolete feedback",
        )
        .unwrap();
        for agent in &completed.agents {
            app.write_terminal_input(agent.terminal_id, b"Private question\r")
                .unwrap();
        }
        accepted(
            app,
            Command::ContinueWorkflowRun {
                workflow_id: id,
                agent_id: completed.agents[0].agent_id,
                generation,
                mode_revision: 1,
            },
        );
        if builtin == BuiltinType::Adversarial {
            wait_for(app, id, |_| {
                std::fs::read_to_string(folder.join("implement-input"))
                    .is_ok_and(|text| text.contains("My draftPrivate question"))
            });
            let private = std::fs::read_to_string(folder.join("implement-input")).unwrap();
            assert!(
                !private.contains("Initial feedback") && !private.contains("Obsolete feedback")
            );
        }
    }

    #[test]
    fn agents_disconnected_keeps_agents_live_and_rejoining_waits_for_fresh_input() {
        for builtin in BuiltinType::ALL {
            let folder = tempfile::tempdir().unwrap();
            let bin = tempfile::tempdir().unwrap();
            let app = application(folder.path(), bin.path(), RECORD_INPUT);
            let id = launch_legacy(&app, folder.path(), builtin);
            finish_remaining_stages(&app, id);
            let completed = app.snapshot().unwrap().workflows.workflows[0].clone();
            let generation = completed.run.as_ref().unwrap().generation;
            let spans = app.workflow_trace(id, None, 100).unwrap().spans.len();
            submit_individual_follow_ups(&app, folder.path(), id, builtin, &completed);
            let individual = app.snapshot().unwrap().workflows.workflows[0].clone();
            let stored = app
                .lock_inner()
                .unwrap()
                .folders
                .store()
                .workflows(folder.path())
                .unwrap();
            assert!(
                stored
                    .iter()
                    .find(|w| w.workflow_id == id)
                    .unwrap()
                    .run
                    .as_ref()
                    .unwrap()
                    .agents_disconnected
            );
            assert_eq!(individual.status, WorkflowStatus::Running);
            assert!(individual.run.as_ref().unwrap().agents_disconnected);
            assert_eq!(
                individual.run.as_ref().unwrap().completions,
                completed.run.as_ref().unwrap().completions
            );
            assert_eq!(individual.terminal_ids(), completed.terminal_ids());
            assert_eq!(
                app.workflow_trace(id, None, 100).unwrap().spans.len(),
                spans
            );
            for terminal in individual.terminal_ids() {
                assert!(app.terminals.is_running(terminal));
            }
            change_agents_disconnected(&app, id, false);
            accepted(
                &app,
                Command::ContinueWorkflowRun {
                    workflow_id: id,
                    agent_id: completed.agents[0].agent_id,
                    generation,
                    mode_revision: 0,
                },
            );
            assert_eq!(
                app.snapshot().unwrap().workflows.workflows[0].status,
                WorkflowStatus::Running
            );
            accepted(
                &app,
                Command::ContinueWorkflowRun {
                    workflow_id: id,
                    agent_id: completed.agents[0].agent_id,
                    generation,
                    mode_revision: 2,
                },
            );
            let continued = app.snapshot().unwrap().workflows.workflows[0].clone();
            assert_eq!(continued.status, WorkflowStatus::Running);
            assert_eq!(continued.terminal_ids(), completed.terminal_ids());
            assert_eq!(continued.run.as_ref().unwrap().generation, generation + 1);
        }
    }

    fn complete_graph_role(
        app: &Application,
        workflow: &Workflow,
        agent: AgentId,
        decision: Decision,
        summary: &str,
        task: &str,
    ) {
        accepted(
            app,
            Command::CompleteWorkflowRole {
                workflow_id: workflow.workflow_id,
                agent_id: agent,
                generation: workflow
                    .run
                    .as_ref()
                    .unwrap()
                    .assignment_generation(agent.0),
                signal: CompletionSignal {
                    decision,
                    summary: summary.into(),
                    assignments: vec![],
                    task: task.into(),
                },
            },
        );
    }

    fn assert_routing_idle(app: &Application, id: WorkflowId) {
        assert_eq!(
            app.snapshot().unwrap().workflows.workflows[0]
                .run
                .as_ref()
                .unwrap()
                .status,
            RunStatus::Idle
        );
        assert!(app.run_processes.lock().unwrap()[&id].inboxes.is_empty());
    }

    #[test]
    fn drafts_keep_their_connection_revision_through_reconnect_and_submission() {
        for queued in [false, true] {
            let folder = tempfile::tempdir().unwrap();
            let bin = tempfile::tempdir().unwrap();
            let app = application(folder.path(), bin.path(), RECORD_INPUT);
            let id = launch_legacy(&app, folder.path(), BuiltinType::Adversarial);
            change_agents_disconnected(&app, id, true);
            let workflow = app.snapshot().unwrap().workflows.workflows[0].clone();
            let agent = &workflow.agents[0];
            wait_for(&app, id, |_| {
                app.terminals.is_harness_ready(agent.terminal_id)
            });
            let generation = workflow.run.as_ref().unwrap().generation;
            let prepare = |revision| {
                accepted(
                    &app,
                    Command::ContinueWorkflowRun {
                        workflow_id: id,
                        agent_id: agent.agent_id,
                        generation,
                        mode_revision: revision,
                    },
                );
            };
            if !queued {
                prepare(1);
                app.write_terminal_input(agent.terminal_id, b"Private draft")
                    .unwrap();
            }
            change_agents_disconnected(&app, id, false);
            if queued {
                prepare(1);
                app.write_terminal_input(agent.terminal_id, b"Private draft")
                    .unwrap();
            }
            prepare(2);
            app.write_terminal_input(agent.terminal_id, b" still private\r")
                .unwrap();
            assert_eq!(
                app.snapshot().unwrap().workflows.workflows[0]
                    .run
                    .as_ref()
                    .unwrap()
                    .status,
                RunStatus::Idle
            );
            assert!(app.run_processes.lock().unwrap()[&id].inboxes.is_empty());
            prepare(2);
            app.write_terminal_input(agent.terminal_id, b"Fresh connected task\r")
                .unwrap();
            assert_eq!(
                app.snapshot().unwrap().workflows.workflows[0]
                    .run
                    .as_ref()
                    .unwrap()
                    .status,
                RunStatus::Running
            );
            assert!(!app.run_processes.lock().unwrap()[&id].inboxes.is_empty());
        }
    }

    #[test]
    fn failed_coordination_keeps_private_conversations_and_can_start_fresh_work() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), RECORD_INPUT);
        let id = launch_graph(
            &app,
            folder.path(),
            &BuiltinType::Adversarial.definition(),
            "Initial task",
        );
        let mut workflow = app.snapshot().unwrap().workflows.workflows[0].clone();
        workflow
            .run
            .as_mut()
            .unwrap()
            .finish(RunStatus::Failed, "Coordination failed");
        workflow.status = WorkflowStatus::Failed;
        app.lock_inner().unwrap().publish_run(0, workflow).unwrap();
        app.snapshot().unwrap();
        change_agents_disconnected(&app, id, true);
        let private = app.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(private.terminal_ids().len(), 2);
        for terminal in private.terminal_ids() {
            assert!(app.terminals.is_running(terminal));
        }
        change_agents_disconnected(&app, id, false);
        accepted(
            &app,
            Command::ContinueWorkflowRun {
                workflow_id: id,
                agent_id: private.agents[0].agent_id,
                generation: private.run.as_ref().unwrap().generation,
                mode_revision: 2,
            },
        );
        let fresh = app.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(fresh.run.as_ref().unwrap().status, RunStatus::Running);
        assert!(!app.run_processes.lock().unwrap()[&id].inboxes.is_empty());
        complete_graph_role(
            &app,
            &fresh,
            fresh.agents[0].agent_id,
            Decision::Done,
            "Fresh work",
            "Fresh task",
        );
        let review = app.snapshot().unwrap().workflows.workflows[0].clone();
        assert!(
            review.run.as_ref().unwrap().incoming[&review.agents[1].agent_id.0]
                .contains("Fresh work")
        );
    }

    #[test]
    fn new_handoffs_do_not_merge_into_a_private_draft_from_before_reconnect() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), RECORD_INPUT);
        let id = launch_graph(
            &app,
            folder.path(),
            &BuiltinType::Adversarial.definition(),
            "Initial task",
        );
        change_agents_disconnected(&app, id, true);
        let private = app.snapshot().unwrap().workflows.workflows[0].clone();
        let reviewer = private.agents[1].agent_id;
        let terminal = private.agents[1].terminal_id;
        wait_for(&app, id, |_| app.terminals.is_harness_ready(terminal));
        app.write_terminal_input(terminal, b"Independent draft")
            .unwrap();
        change_agents_disconnected(&app, id, false);
        accepted(
            &app,
            Command::ContinueWorkflowRun {
                workflow_id: id,
                agent_id: private.agents[0].agent_id,
                generation: private.run.as_ref().unwrap().generation,
                mode_revision: 2,
            },
        );
        let fresh = app.snapshot().unwrap().workflows.workflows[0].clone();
        complete_graph_role(
            &app,
            &fresh,
            fresh.agents[0].agent_id,
            Decision::Done,
            "New handoff",
            "Fresh task",
        );
        let routed = app.snapshot().unwrap().workflows.workflows[0].clone();
        accepted(
            &app,
            Command::ContinueWorkflowRun {
                workflow_id: id,
                agent_id: reviewer,
                generation: routed.run.as_ref().unwrap().generation,
                mode_revision: 2,
            },
        );
        app.write_terminal_input(terminal, b" remains private\r")
            .unwrap();
        wait_for(&app, id, |_| {
            std::fs::read_to_string(folder.path().join("review-input"))
                .is_ok_and(|input| input.contains("Independent draft remains private"))
        });
        let independent = std::fs::read_to_string(folder.path().join("review-input")).unwrap();
        assert!(
            !independent.contains("New handoff") && !independent.contains("completion command")
        );
        // Without native response hooks a fresh user message is the safe explicit boundary.
        accepted(
            &app,
            Command::ContinueWorkflowRun {
                workflow_id: id,
                agent_id: reviewer,
                generation: routed.run.as_ref().unwrap().generation,
                mode_revision: 2,
            },
        );
        app.write_terminal_input(terminal, b"Now review the fresh task\r")
            .unwrap();
        wait_for(&app, id, |_| {
            std::fs::read_to_string(folder.path().join("review-input"))
                .is_ok_and(|input| input.contains("New handoff"))
        });
        complete_graph_role(
            &app,
            &routed,
            reviewer,
            Decision::Approve,
            "Fresh review",
            "",
        );
        assert_eq!(
            app.snapshot().unwrap().workflows.workflows[0]
                .run
                .as_ref()
                .unwrap()
                .status,
            RunStatus::Idle
        );
    }

    #[test]
    fn idle_connections_restore_exact_conversations_without_assignments() {
        for disconnected in [false, true] {
            let folder = tempfile::tempdir().unwrap();
            let bin = tempfile::tempdir().unwrap();
            let app = application(folder.path(), bin.path(), RECORD_INPUT);
            let id = launch_legacy(&app, folder.path(), BuiltinType::Adversarial);
            change_agents_disconnected(&app, id, true);
            if !disconnected {
                change_agents_disconnected(&app, id, false);
            }
            let saved = app.snapshot().unwrap().workflows.workflows[0].clone();
            assert_eq!(
                saved.terminal_ids().len(),
                2,
                "Disconnect opens waiting conversations without starting their assignments"
            );
            for agent in &saved.agents {
                app.lock_inner()
                    .unwrap()
                    .folders
                    .store()
                    .remember_harness_session(
                        agent.terminal_id,
                        folder
                            .path()
                            .join(format!("agent-{}.jsonl", agent.agent_id.0))
                            .to_str()
                            .unwrap(),
                    )
                    .unwrap();
            }
            app.stop_run_terminals(&saved.terminal_ids(), "Simulate quit");
            app.run_processes.lock().unwrap().remove(&id);
            app.resume_workflow_run(&saved, folder.path()).unwrap();
            let restored = app.snapshot().unwrap().workflows.workflows[0].clone();
            assert_eq!(restored.run.as_ref().unwrap().status, RunStatus::Idle);
            assert_eq!(
                restored.run.as_ref().unwrap().agents_disconnected,
                disconnected
            );
            assert!(app.run_processes.lock().unwrap()[&id].inboxes.is_empty());
            for (old, current) in saved.agents.iter().zip(&restored.agents) {
                assert_eq!(old.agent_id, current.agent_id);
                assert_ne!(old.terminal_id, current.terminal_id);
                assert!(app.terminals.is_running(current.terminal_id));
                app.write_terminal_input(current.terminal_id, b"Restored private input\r")
                    .unwrap();
            }
        }
    }

    fn pending_review_helper(
        app: &Application,
        workflow: &Workflow,
        agent: AgentId,
    ) -> std::process::Child {
        use std::io::Write;
        use std::process::{Command as ProcessCommand, Stdio};
        let old_inbox = app.run_processes.lock().unwrap()[&workflow.workflow_id].inboxes[&agent]
            .1
            .command();
        let mut helper = ProcessCommand::new("/bin/sh")
            .args(["-c", &old_inbox])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        helper
            .stdin
            .take()
            .unwrap()
            .write_all(br#"{"decision":"approve","summary":"Obsolete review"}"#)
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        while !app.run_processes.lock().unwrap()[&workflow.workflow_id].inboxes[&agent]
            .1
            .receipt_pending()
        {
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(5));
        }
        helper
    }

    #[test]
    fn active_disconnect_releases_helpers_and_reconnect_keeps_old_commands_private() {
        use std::process::{Command as ProcessCommand, Stdio};

        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), RECORD_INPUT);
        let id = launch_graph(
            &app,
            folder.path(),
            &BuiltinType::Adversarial.definition(),
            "Build checkout",
        );
        let first = app.snapshot().unwrap().workflows.workflows[0].clone();
        let implementer = first.agents[0].agent_id;
        complete_graph_role(
            &app,
            &first,
            implementer,
            Decision::Done,
            "Ready for review",
            "",
        );
        let review = app.snapshot().unwrap().workflows.workflows[0].clone();
        let reviewer = review.agents[1].agent_id;
        let terminals = review.terminal_ids();
        let generation = review.run.as_ref().unwrap().generation;
        let old_commands: Vec<_> = app.run_processes.lock().unwrap()[&id]
            .completion_commands
            .values()
            .map(CompletionCommand::command)
            .collect();
        let mut helper = pending_review_helper(&app, &review, reviewer);
        change_agents_disconnected(&app, id, true);
        assert!(helper.wait().unwrap().success());
        let detached = app.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(detached.run.as_ref().unwrap().status, RunStatus::Idle);
        assert_eq!(
            detached.run.as_ref().unwrap().completions,
            review.run.as_ref().unwrap().completions
        );
        assert_eq!(detached.terminal_ids(), terminals);
        for terminal in &terminals {
            assert!(app.terminals.is_running(*terminal));
            app.write_terminal_input(*terminal, b"Independent question\r")
                .unwrap();
        }
        change_agents_disconnected(&app, id, false);
        assert_routing_idle(&app, id);
        accepted(
            &app,
            Command::ContinueWorkflowRun {
                workflow_id: id,
                agent_id: reviewer,
                generation,
                mode_revision: 2,
            },
        );
        let fresh = app.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(fresh.terminal_ids(), terminals);
        assert_eq!(
            fresh.run.as_ref().unwrap().active_agents()[0].agent_id,
            reviewer.0
        );
        for command in old_commands {
            assert!(
                !ProcessCommand::new("/bin/sh")
                    .args(["-c", &command])
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status()
                    .unwrap()
                    .success()
            );
        }
        app.write_terminal_input(fresh.agents[1].terminal_id, b"Review the current result\r")
            .unwrap();
        complete_graph_role(
            &app,
            &fresh,
            reviewer,
            Decision::RequestChanges,
            "Fresh review feedback",
            "Review the current result",
        );
        let continued = app.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(continued.terminal_ids(), terminals);
        assert!(
            continued.run.as_ref().unwrap().incoming[&implementer.0]
                .contains("Fresh review feedback")
        );
        assert!(
            !continued
                .run
                .as_ref()
                .unwrap()
                .traces
                .iter()
                .any(|event| event.message.contains("Obsolete review"))
        );
    }

    #[test]
    fn graph_agents_disconnected_keeps_terminal_follow_ups_out_of_handoffs() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), RECORD_INPUT);
        let id = launch_graph(
            &app,
            folder.path(),
            &BuiltinType::Adversarial.definition(),
            "Build checkout",
        );
        wait_for(&app, id, |workflow| {
            workflow.agents[0].terminal_id.value() > 0
        });
        let current = app.snapshot().unwrap().workflows.workflows[0].clone();
        complete_graph_role(
            &app,
            &current,
            current.agents[0].agent_id,
            Decision::Done,
            "Checkout ready",
            "",
        );
        wait_for(&app, id, |workflow| {
            workflow.agents[1].terminal_id.value() > 0
        });
        let current = app.snapshot().unwrap().workflows.workflows[0].clone();
        complete_graph_role(
            &app,
            &current,
            current.agents[1].agent_id,
            Decision::Approve,
            "Approved checkout",
            "",
        );
        let completed = app.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(completed.status, WorkflowStatus::Running);
        let generation = completed.run.as_ref().unwrap().generation;
        let graph = completed.run.as_ref().unwrap().graph.clone();
        change_agents_disconnected(&app, id, true);
        for agent in &completed.agents {
            assert!(app.terminals.is_running(agent.terminal_id));
            app.write_terminal_input(agent.terminal_id, b"Private checkout question\r")
                .unwrap();
        }
        accepted(
            &app,
            Command::ContinueWorkflowRun {
                workflow_id: id,
                agent_id: completed.agents[0].agent_id,
                generation,
                mode_revision: 1,
            },
        );
        let individual = app.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(individual.status, WorkflowStatus::Running);
        assert_eq!(
            individual
                .run
                .as_ref()
                .unwrap()
                .graph
                .as_ref()
                .unwrap()
                .outputs,
            graph.as_ref().unwrap().outputs
        );
        assert_eq!(individual.terminal_ids(), completed.terminal_ids());
        change_agents_disconnected(&app, id, false);
        assert_eq!(
            app.snapshot().unwrap().workflows.workflows[0].status,
            WorkflowStatus::Running
        );
        accepted(
            &app,
            Command::ContinueWorkflowRun {
                workflow_id: id,
                agent_id: completed.agents[0].agent_id,
                generation,
                mode_revision: 2,
            },
        );
        let continued = app.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(continued.status, WorkflowStatus::Running);
        assert!(continued.run.as_ref().unwrap().generation > generation);
        assert_eq!(
            continued.agents[0].terminal_id,
            completed.agents[0].terminal_id
        );
    }

    #[test]
    fn final_feedback_preserves_a_user_draft_and_continuation_sends_no_setup_prompt() {
        for limited in [false, true] {
            let folder = tempfile::tempdir().unwrap();
            let bin = tempfile::tempdir().unwrap();
            let app = application(folder.path(), bin.path(), RECORD_INPUT);
            let id = launch_legacy(&app, folder.path(), BuiltinType::Adversarial);
            let initial = wait_for(&app, id, |_| folder.path().join("implement-ready").exists());
            let terminal = initial.agents[0].terminal_id;
            let mut current = initial;
            loop {
                finish_active_stage(&app, &current, Decision::Done, "");
                let review = app.snapshot().unwrap().workflows.workflows[0].clone();
                let run = review.run.as_ref().unwrap();
                let last = !limited
                    || run.rounds.get("review").copied().unwrap_or(0)
                        >= run.workflow_type.definition.review_loops[0].max_rounds;
                if last {
                    app.write_terminal_input(terminal, b"My unfinished")
                        .unwrap();
                }
                finish_active_stage(
                    &app,
                    &review,
                    if limited {
                        Decision::RequestChanges
                    } else {
                        Decision::Approve
                    },
                    "",
                );
                current = app.snapshot().unwrap().workflows.workflows[0].clone();
                if last {
                    break;
                }
            }
            let before = app.workflow_trace(id, None, 100).unwrap().spans.len();
            assert_eq!(
                current.run.as_ref().unwrap().status,
                if limited {
                    RunStatus::Paused
                } else {
                    RunStatus::Idle
                }
            );
            thread::sleep(Duration::from_millis(30));
            let input_path = folder.path().join("implement-input");
            assert!(
                !std::fs::read_to_string(&input_path)
                    .unwrap_or_default()
                    .contains("My unfinished")
            );
            accepted(
                &app,
                Command::ContinueWorkflowRun {
                    workflow_id: id,
                    agent_id: current.agents[0].agent_id,
                    generation: current.run.as_ref().unwrap().generation,
                    mode_revision: 0,
                },
            );
            app.write_terminal_input(terminal, b" message\r").unwrap();
            let continued = wait_for(&app, id, |_| {
                std::fs::read_to_string(&input_path)
                    .is_ok_and(|text| text.contains("Continue with the user's message above."))
            });
            let input = std::fs::read_to_string(&input_path).unwrap();
            assert!(input.contains("My unfinished message"));
            assert!(input.contains("Review feedback received while you were typing:"));
            assert!(input.contains(if limited {
                "review limit was reached"
            } else {
                "review is complete"
            }));
            assert!(
                !input.contains("You are Implementer")
                    && !input.contains("You are part of a Handshake")
            );
            assert_eq!(continued.agents[0].terminal_id, terminal);
            assert_eq!(
                app.workflow_trace(id, None, 100).unwrap().spans.len(),
                before + 1
            );
            assert!(continued.run.as_ref().unwrap().needs_task());
            finish_active_stage(&app, &continued, Decision::Done, "My unfinished message");
            let review = app.snapshot().unwrap().workflows.workflows[0].clone();
            assert_eq!(review.run.as_ref().unwrap().prompt, "My unfinished message");
            assert!(
                review
                    .run
                    .as_ref()
                    .unwrap()
                    .follow_up_instructions(review.agents[1].agent_id.0)
                    .contains("My unfinished message")
            );
        }
    }

    #[test]
    fn agents_stay_interactive_and_keep_their_processes_across_handoffs_and_follow_ups() {
        for builtin in BuiltinType::ALL {
            let folder = tempfile::tempdir().unwrap();
            let bin = tempfile::tempdir().unwrap();
            let app = application(
                folder.path(),
                bin.path(),
                r#"
                stty -echo
                echo $$ >> processes
                while IFS= read -r line; do printf '%s\n' "$line" >> "input-$$"; done
            "#,
            );
            let id = launch_legacy(&app, folder.path(), builtin);
            let first = wait_for(&app, id, |w| !w.terminal_ids().is_empty());
            let first_agent = first.agents[0].agent_id;
            let first_terminal = first.agents[0].terminal_id;
            finish_active_stage(&app, &first, Decision::Approve, "");
            app.write_terminal_input(first_terminal, b"still interactive after handing off\n")
                .unwrap();
            if builtin == BuiltinType::Adversarial {
                let review = app.snapshot().unwrap().workflows.workflows[0].clone();
                finish_active_stage(&app, &review, Decision::RequestChanges, "");
                let implement = app.snapshot().unwrap().workflows.workflows[0].clone();
                assert_eq!(implement.agents[0].terminal_id, first_terminal);
                finish_active_stage(&app, &implement, Decision::Approve, "");
            }
            finish_remaining_stages(&app, id);
            let completed = app.snapshot().unwrap().workflows.workflows[0].clone();
            assert_eq!(completed.status, WorkflowStatus::Running);
            let terminals = completed.terminal_ids();
            assert_eq!(completed.agents[0].terminal_id, first_terminal);
            for terminal in &terminals {
                assert_eq!(
                    app.lock_inner().unwrap().terminals[terminal],
                    TerminalStatus::Running
                );
                app.write_terminal_input(*terminal, b"still interactive after completing\n")
                    .unwrap();
            }
            for _ in 0..2 {
                accepted(
                    &app,
                    Command::ContinueWorkflowRun {
                        workflow_id: id,
                        agent_id: first_agent,
                        generation: completed.run.as_ref().unwrap().generation,
                        mode_revision: 0,
                    },
                );
            }
            let continued = app.snapshot().unwrap().workflows.workflows[0].clone();
            assert!(continued.run.as_ref().unwrap().needs_task());
            assert_eq!(continued.terminal_ids(), terminals);
            app.write_terminal_input(first_terminal, b"The follow-up task\n")
                .unwrap();
            finish_active_stage(&app, &continued, Decision::Approve, "The follow-up task");
            finish_remaining_stages(&app, id);
            let finished = app.snapshot().unwrap().workflows.workflows[0].clone();
            assert_eq!(finished.status, WorkflowStatus::Running);
            assert_eq!(finished.terminal_ids(), terminals);
            assert_eq!(finished.terminal_history, []);
            assert_eq!(finished.run.as_ref().unwrap().prompt, "The follow-up task");
            wait_for(&app, id, |_| {
                std::fs::read_to_string(folder.path().join("processes"))
                    .is_ok_and(|pids| pids.lines().count() == terminals.len())
                    && std::fs::read_dir(folder.path())
                        .unwrap()
                        .filter_map(Result::ok)
                        .filter(|entry| entry.file_name().to_string_lossy().starts_with("input-"))
                        .filter_map(|entry| std::fs::read_to_string(entry.path()).ok())
                        .any(|text| text.contains("The follow-up task"))
            });
            let processes = std::fs::read_to_string(folder.path().join("processes")).unwrap();
            assert_eq!(processes.lines().count(), terminals.len());
            assert_live_assignment_history(
                &app,
                id,
                &terminals,
                if builtin == BuiltinType::Adversarial {
                    6
                } else {
                    8
                },
            );
            accepted(&app, Command::CloseWorkflow { workflow_id: id });
            for terminal in terminals {
                assert!(
                    app.write_terminal_input(terminal, b"after closing\n")
                        .is_err()
                );
            }
        }
    }

    fn assert_live_assignment_history(
        app: &Application,
        id: WorkflowId,
        terminals: &[TerminalId],
        count: usize,
    ) {
        let page = app.workflow_trace(id, None, 200).unwrap();
        let assignments: Vec<_> = page
            .spans
            .iter()
            .filter(|span| span.title != "Shell")
            .collect();
        assert_eq!(assignments.len(), count);
        for span in assignments {
            assert!(terminals.contains(&span.terminal_id.expect("each assignment has a terminal")));
            assert_eq!(span.status, crate::TraceSpanStatus::Completed);
            let events = app.trace_events(span.span_id, None, 200).unwrap().events;
            if let Some(continuation) = events.iter().find(|event| {
                event
                    .message
                    .contains("Assignment continued in the existing harness")
            }) {
                let anchor = continuation
                    .anchor
                    .as_ref()
                    .expect("continuation has a terminal boundary");
                assert_eq!(anchor.terminal_id, span.terminal_id.unwrap());
                assert!(
                    events
                        .iter()
                        .all(|event| event.kind != crate::TraceEventKind::ProcessStarted)
                );
                let completion = events
                    .iter()
                    .find(|event| {
                        event.message.contains("Result reported")
                            || event.message.contains("Approved:")
                    })
                    .unwrap();
                assert!(anchor.byte_offset <= completion.anchor.as_ref().unwrap().byte_offset);
            }
            assert!(
                events
                    .iter()
                    .all(|event| event.kind != crate::TraceEventKind::ProcessStopped)
            );
        }
    }

    #[test]
    fn reaching_the_review_limit_keeps_agents_live_for_a_fresh_cycle_and_force_stop() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(
            folder.path(),
            bin.path(),
            "while read line; do echo \"$line\"; done",
        );
        let id = launch_legacy(&app, folder.path(), BuiltinType::Adversarial);
        loop {
            let workflow = app.snapshot().unwrap().workflows.workflows[0].clone();
            if workflow
                .run
                .as_ref()
                .is_some_and(|run| run.status != RunStatus::Running)
            {
                break;
            }
            finish_active_stage(&app, &workflow, Decision::RequestChanges, "");
        }
        let limited = app.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(limited.run.as_ref().unwrap().status, RunStatus::Paused);
        let terminals = limited.terminal_ids();
        for terminal in &terminals {
            assert!(app.terminals.is_running(*terminal));
        }
        accepted(
            &app,
            Command::ContinueWorkflowRun {
                workflow_id: id,
                agent_id: limited.agents[0].agent_id,
                generation: limited.run.as_ref().unwrap().generation,
                mode_revision: 0,
            },
        );
        let continued = app.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(continued.terminal_ids(), terminals);
        assert!(continued.run.as_ref().unwrap().rounds.is_empty());
        finish_active_stage(
            &app,
            &continued,
            Decision::Approve,
            "A follow-up after the review limit",
        );
        finish_remaining_stages(&app, id);
        assert_eq!(
            app.snapshot().unwrap().workflows.workflows[0].status,
            WorkflowStatus::Running
        );
        accepted(&app, Command::ForceStopWorkflowAgents { workflow_id: id });
        for terminal in terminals {
            assert!(app.terminals.is_running(terminal));
            assert!(!app.terminals.is_harness_running(terminal));
        }
        for terminal in app.snapshot().unwrap().workflows.workflows[0].terminal_ids() {
            assert!(app.terminals.is_running(terminal));
            assert!(!app.terminals.is_harness_running(terminal));
        }
        assert!(
            app.run_processes
                .lock()
                .unwrap()
                .values()
                .all(|processes| processes.inboxes.is_empty() && processes.decisions.is_empty())
        );
    }

    fn assert_run_trace_history(app: &Application, workflow: &Workflow, invocations: u64) {
        let page = app.workflow_trace(workflow.workflow_id, None, 200).unwrap();
        assert_eq!(page.summary.span_count, invocations);
        assert!(page.lanes.iter().all(|lane| lane.is_agent));
        assert_eq!(page.summary.agent_count, 2);
        for span in page.spans.iter().filter(|span| span.title != "Shell") {
            let lane = page
                .lanes
                .iter()
                .find(|lane| lane.lane_id == span.lane_id)
                .unwrap();
            assert_eq!(lane.harness.as_deref(), Some("pi"));
            let events = app.trace_events(span.span_id, None, 200).unwrap().events;
            let events: Vec<_> = events
                .iter()
                .filter(|event| event.kind == crate::TraceEventKind::WorkflowEvent)
                .collect();
            assert!(
                events
                    .iter()
                    .any(|event| event.message.contains("Stage started"))
            );
            assert!(
                events
                    .iter()
                    .any(|event| event.message.contains("Stage completed"))
            );
            let completion = events
                .iter()
                .find(|event| {
                    event.message.contains("Result reported:")
                        || event.message.contains("Approved:")
                        || event.message.contains("Requested changes:")
                })
                .unwrap();
            assert!(completion.message.contains("Result or feedback"));
            assert_eq!(span.status, crate::TraceSpanStatus::Completed);
            assert_eq!(
                span.ended_at,
                Some(completion.timestamp.max(span.started_at))
            );
            assert!(completion.anchor.is_some());
            if let Some(handoff) = events
                .iter()
                .find(|event| event.message.contains("Handoff delivered"))
            {
                assert_eq!(span.started_at, handoff.timestamp);
                assert!(handoff.message.contains("Result or feedback"));
                assert!(handoff.anchor.is_some());
            } else {
                let start = events
                    .iter()
                    .find(|event| event.message.contains("Stage started"))
                    .unwrap();
                assert_eq!(span.started_at, start.timestamp);
            }
        }
        // Native prompts replace fallback stage labels without changing assignment boundaries.
        assert!(page.spans.iter().all(|span| span.title == "Assignment"));
        // Saving the same accepted state again never duplicates events or invocation spans.
        // Hold the store lock so late harness hooks cannot change the revision between reads.
        let mut inner = app.lock_inner().unwrap();
        let store = inner.folders.store();
        let before = store
            .workflow_trace(workflow.workflow_id, None, 200)
            .unwrap()
            .summary
            .revision;
        assert_eq!(store.save_workflow_run(workflow).unwrap(), []);
        assert_eq!(
            store
                .workflow_trace(workflow.workflow_id, None, 200)
                .unwrap()
                .summary
                .revision,
            before
        );
    }

    #[test]
    fn fake_coordinator_sends_worker_tasks_and_files_then_gathers_results() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), FAKE);
        let id = launch_legacy(&app, folder.path(), BuiltinType::Coordinator);
        let result = wait_for(&app, id, |w| {
            w.run.as_ref().is_some_and(|run| run.work_completed())
        });
        let order = std::fs::read_to_string(folder.path().join("order")).unwrap();
        let order: Vec<_> = order.lines().collect();
        assert_eq!(order.first(), Some(&"split"));
        assert_eq!(order.last(), Some(&"gather"));
        assert!(order[1..3].contains(&"worker1") && order[1..3].contains(&"worker2"));
        for (worker, task, file) in [
            (1, "First sub-task", "first.txt"),
            (2, "Second sub-task", "second.txt"),
        ] {
            let prompt =
                std::fs::read_to_string(folder.path().join(format!("worker{worker}-prompt")))
                    .unwrap();
            assert!(prompt.contains(task) && prompt.contains(file));
        }
        let gather = std::fs::read_to_string(folder.path().join("gather-prompt")).unwrap();
        assert!(gather.contains("Worker 1") && gather.contains("Worker 2"));
        let traces = result.run.unwrap().traces;
        assert_eq!(
            traces.iter().filter(|t| t.kind == "stageStarted").count(),
            3
        );
        assert_eq!(traces.iter().filter(|t| t.kind == "handoff").count(), 4);
        let page = app.workflow_trace(id, None, 200).unwrap();
        assert_eq!(page.summary.span_count, 4);
        for (task, label) in [
            ("First sub-task", "Worker 1"),
            ("Second sub-task", "Worker 2"),
        ] {
            let lane = page.lanes.iter().find(|lane| lane.name == label).unwrap();
            let spans: Vec<_> = page
                .spans
                .iter()
                .filter(|span| span.lane_id == lane.lane_id)
                .collect();
            assert_eq!(spans.len(), 1);
            let span = spans[0];
            assert_eq!(span.title, task);
            assert_eq!(span.status, crate::TraceSpanStatus::Completed);
            let events = app.trace_events(span.span_id, None, 200).unwrap().events;
            let handoff = events
                .iter()
                .find(|event| event.message.contains("Handoff delivered"))
                .unwrap();
            assert!(handoff.message.contains(task));
            assert_eq!(span.started_at, handoff.timestamp);
            let completion = events
                .iter()
                .find(|event| {
                    event
                        .message
                        .contains("Result reported: Result or feedback")
                })
                .unwrap();
            assert_eq!(
                span.ended_at,
                Some(completion.timestamp.max(span.started_at))
            );
            assert!(handoff.anchor.is_some() && completion.anchor.is_some());
            assert_eq!(
                completion.anchor.as_ref().unwrap().terminal_id,
                span.terminal_id.unwrap()
            );
            assert!(
                events
                    .iter()
                    .any(|event| event.kind == crate::TraceEventKind::ProcessStarted)
            );
            assert!(app.terminals.is_running(span.terminal_id.unwrap()));
        }
        let handoffs = page
            .spans
            .iter()
            .flat_map(|span| app.trace_events(span.span_id, None, 200).unwrap().events)
            .filter(|event| event.message.contains("Handoff delivered"))
            .count();
        assert_eq!(handoffs, 4);
        assert_gather_anchors(&app, &page);
        accepted(&app, Command::CloseWorkflow { workflow_id: id });
        assert_eq!(
            app.workflow_trace(id, None, 200)
                .unwrap()
                .summary
                .span_count,
            4
        );
    }

    fn assert_gather_anchors(app: &Application, page: &crate::WorkflowTracePage) {
        let lane = page
            .lanes
            .iter()
            .find(|lane| lane.name == "Coordinator")
            .unwrap();
        let gather = page
            .spans
            .iter()
            .find(|span| span.lane_id == lane.lane_id)
            .unwrap();
        let gathered = app.trace_events(gather.span_id, None, 200).unwrap().events;
        for worker in ["Worker 1", "Worker 2"] {
            let lane = page.lanes.iter().find(|lane| lane.name == worker).unwrap();
            let span = page
                .spans
                .iter()
                .find(|span| span.lane_id == lane.lane_id)
                .unwrap();
            let events = app.trace_events(span.span_id, None, 200).unwrap().events;
            let completion = events
                .iter()
                .find(|event| event.message.contains("Result reported:"))
                .unwrap();
            let handoff = gathered
                .iter()
                .find(|event| event.message.contains(&format!("{worker} → Coordinator")))
                .unwrap();
            assert_eq!(handoff.anchor, completion.anchor);
            assert_eq!(
                handoff.anchor.as_ref().unwrap().terminal_id,
                span.terminal_id.unwrap()
            );
        }
    }

    fn launch_coordinator_workers(app: &Application, folder: &Path) -> WorkflowId {
        let id = launch_legacy(app, folder, BuiltinType::Coordinator);
        let workflow = app.snapshot().unwrap().workflows.workflows[0].clone();
        accepted(
            app,
            Command::CompleteWorkflowRole {
                workflow_id: id,
                agent_id: workflow.agents[0].agent_id,
                generation: 1,
                signal: CompletionSignal {
                    task: String::new(),
                    decision: Decision::Done,
                    summary: "Split the task".into(),
                    assignments: (1..=2)
                        .map(|instance| crate::Assignment {
                            role: "worker".into(),
                            instance,
                            task: format!("Task {instance}"),
                            files: vec![],
                        })
                        .collect(),
                },
            },
        );
        id
    }

    fn done_signal(summary: &str) -> CompletionSignal {
        CompletionSignal {
            decision: Decision::Done,
            summary: summary.into(),
            assignments: vec![],
            task: String::new(),
        }
    }

    #[test]
    fn coordinator_assignments_finish_independently_and_cancellation_stops_only_unfinished_work() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), "echo ready; sleep 60");
        let id = launch_coordinator_workers(&app, folder.path());
        let page = app.workflow_trace(id, None, 200).unwrap();
        let workers: Vec<_> = page
            .spans
            .iter()
            .filter(|span| span.title.starts_with("Task "))
            .collect();
        assert_eq!(workers.len(), 2);
        assert!(
            workers
                .iter()
                .all(|span| span.is_live && span.ended_at.is_none())
        );
        let workflow = app.snapshot().unwrap().workflows.workflows[0].clone();
        let first = workers.iter().find(|span| span.title == "Task 1").unwrap();
        let terminal = first.terminal_id.unwrap();
        wait_for(&app, id, |_| {
            app.terminals.observe(terminal).unwrap().byte_offset > 0
        });
        let size = TerminalSize {
            columns: 120,
            ..SIZE
        };
        app.terminals.resize(terminal, size).unwrap();
        let boundary = app.terminals.observe(terminal).unwrap();
        accepted(
            &app,
            Command::CompleteWorkflowRole {
                workflow_id: id,
                agent_id: workflow.agents[1].agent_id,
                generation: 2,
                signal: done_signal("Finished Task 1"),
            },
        );
        let page = app.workflow_trace(id, None, 200).unwrap();
        let finished = page
            .spans
            .iter()
            .find(|span| span.title == "Task 1")
            .unwrap();
        assert_eq!(finished.status, crate::TraceSpanStatus::Completed);
        let events = app
            .trace_events(finished.span_id, None, 200)
            .unwrap()
            .events;
        let completion = events
            .iter()
            .find(|event| event.message.contains("Result reported: Finished Task 1"))
            .unwrap();
        let anchor = completion.anchor.as_ref().unwrap();
        // Observation includes all output accepted before completion and the resize boundary.
        assert_eq!(anchor.byte_offset, boundary.byte_offset);
        assert_eq!(anchor.boundary_sizes, Some(vec![size]));
        assert_eq!(anchor.terminal_id, terminal);
        assert!(
            events
                .iter()
                .all(|event| event.kind != crate::TraceEventKind::ProcessStopped)
        );
        assert!(app.terminals.is_running(terminal));
        let unfinished = page
            .spans
            .iter()
            .find(|span| span.title == "Task 2")
            .unwrap();
        assert!(unfinished.is_live && unfinished.ended_at.is_none());
        let finished = finished.clone();
        accepted(&app, Command::ForceStopWorkflowAgents { workflow_id: id });
        assert!(app.terminals.is_running(terminal));
        let page = app.workflow_trace(id, None, 200).unwrap();
        assert_eq!(
            page.spans
                .iter()
                .find(|span| span.title == "Task 1")
                .unwrap(),
            &finished
        );
        let stopped = page
            .spans
            .iter()
            .find(|span| span.title == "Task 2")
            .unwrap();
        assert_eq!(stopped.status, crate::TraceSpanStatus::Stopped);
        assert!(!stopped.is_live && stopped.ended_at.is_some());
        let events = app.trace_events(stopped.span_id, None, 200).unwrap().events;
        assert!(
            events
                .iter()
                .any(|event| event.message.contains("Assignment stopped")
                    && event.anchor.as_ref().unwrap().terminal_id == stopped.terminal_id.unwrap())
        );
        assert!(
            !events
                .iter()
                .any(|event| event.message.contains("Result reported"))
        );
    }

    #[test]
    fn an_unfinished_process_failure_pauses_routing_without_claiming_success() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), "sleep 60");
        let id = launch_legacy(&app, folder.path(), BuiltinType::Adversarial);
        let workflow = app.snapshot().unwrap().workflows.workflows[0].clone();
        app.lock_inner().unwrap().record_terminal_exit(
            workflow.agents[0].terminal_id,
            Err("Injected process failure".into()),
        );
        let workflow = app.snapshot().unwrap().workflows.workflows[0].clone();
        let run = workflow.run.unwrap();
        assert_eq!(run.status, RunStatus::Paused);
        assert!(!run.work_completed());
        assert_eq!(run.stage_index, 0);
        let span = app.workflow_trace(id, None, 200).unwrap().spans[0].clone();
        assert_eq!(span.status, crate::TraceSpanStatus::Stopped);
        assert!(
            app.trace_events(span.span_id, None, 200)
                .unwrap()
                .events
                .iter()
                .any(|event| event.kind == crate::TraceEventKind::ProcessFailed)
        );
    }

    #[test]
    fn closing_an_exited_agent_stops_its_unfinished_assignment() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), "exit 0");
        let id = launch_legacy(&app, folder.path(), BuiltinType::Adversarial);
        wait_for(&app, id, |workflow| {
            workflow.run.as_ref().unwrap().status == RunStatus::Paused
        });
        let span = app.workflow_trace(id, None, 200).unwrap().spans[0].clone();
        assert_eq!(span.status, crate::TraceSpanStatus::Stopped);
        assert!(!span.is_live && span.ended_at.is_some());
        accepted(&app, Command::CloseWorkflow { workflow_id: id });
        let closed = app.workflow_trace(id, None, 200).unwrap().spans[0].clone();
        assert_eq!(closed.span_id, span.span_id);
        assert_eq!(closed.status, crate::TraceSpanStatus::Stopped);
        let events = app.trace_events(closed.span_id, None, 200).unwrap().events;
        assert!(
            events
                .iter()
                .any(|event| event.kind == crate::TraceEventKind::ProcessExited)
        );
        assert!(
            events
                .iter()
                .any(|event| event.message.contains("Assignment stopped")
                    || event.kind == crate::TraceEventKind::ProcessExited)
        );
    }

    #[test]
    fn harness_exit_returns_to_a_shell_without_completing_or_advancing_work() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(
            folder.path(),
            bin.path(),
            "echo 'done approved requestChanges'; exit 0",
        );
        let id = launch_legacy(&app, folder.path(), BuiltinType::Adversarial);
        let workflow = wait_for(&app, id, |workflow| {
            workflow.run.as_ref().unwrap().status == RunStatus::Paused
        });
        let run = workflow.run.as_ref().unwrap();
        assert!(!run.work_completed());
        assert_eq!(run.stage_index, 0);
        assert_eq!(
            run.last_outcome.as_ref().unwrap().kind,
            crate::WorkOutcomeKind::Interrupted
        );
        let terminal = workflow.agents[0].terminal_id;
        assert!(app.terminals.is_running(terminal));
        assert!(!app.terminals.is_harness_running(terminal));
        app.write_terminal_input(terminal, b"touch shell-usable\r")
            .unwrap();
        wait_for(&app, id, |_| folder.path().join("shell-usable").exists());
        assert_eq!(
            app.snapshot().unwrap().workflows.workflows[0].agents[0].terminal_id,
            terminal
        );
        accepted(&app, Command::ForceStopWorkflowAgents { workflow_id: id });
        assert!(app.terminals.is_running(terminal));
    }

    #[test]
    fn running_workflows_restore_as_interrupted_without_launching_agents() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let data = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), "sleep 60");
        // Use its test harness with a persistent database.
        let mut persistent = Application::with_config(data.path(), Config::default()).unwrap();
        persistent.harness_path.clone_from(&app.harness_path);
        accepted(
            &persistent,
            Command::OpenFolder {
                path: folder.path().to_owned(),
            },
        );
        let id = launch_legacy(&persistent, folder.path(), BuiltinType::Adversarial);
        let marker = persistent.terminals.reserve_terminal().unwrap();
        persistent
            .terminals
            .cancel_reserved_terminal(marker)
            .unwrap();
        drop(persistent);
        let restored = Application::with_config(data.path(), Config::default()).unwrap();
        let workflow = wait_for(&restored, id, |w| w.restored);
        assert_eq!(workflow.status, WorkflowStatus::Running);
        assert!(
            workflow
                .terminal_ids()
                .iter()
                .all(|terminal| restored.terminals.is_running(*terminal))
        );
        assert_eq!(workflow.run.unwrap().status, RunStatus::Idle);
        let next = restored.terminals.reserve_terminal().unwrap();
        restored.terminals.cancel_reserved_terminal(next).unwrap();
        assert!(next.value() > marker.value());
    }

    #[test]
    fn an_incoming_assignment_is_live_while_its_process_launch_waits_on_storage() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = Arc::new(application(folder.path(), bin.path(), "sleep 60"));
        let id = launch_legacy(&app, folder.path(), BuiltinType::Adversarial);
        let workflow = app.snapshot().unwrap().workflows.workflows[0].clone();
        let stalled = app
            .terminal_output
            .stall_recording_worker(workflow.agents[0].terminal_id);
        let completing = Arc::clone(&app);
        let completion = thread::spawn(move || {
            accepted(
                &completing,
                Command::CompleteWorkflowRole {
                    workflow_id: id,
                    agent_id: workflow.agents[0].agent_id,
                    generation: 1,
                    signal: CompletionSignal {
                        task: String::new(),
                        decision: Decision::Done,
                        summary: "Ready for review".into(),
                        assignments: vec![],
                    },
                },
            );
        });
        let deadline = Instant::now() + Duration::from_secs(3);
        while !app.terminal_output.allocation_is_pending() {
            assert!(
                Instant::now() < deadline,
                "review launch did not reach transcript allocation"
            );
            thread::yield_now();
        }
        let (sent, received) = std::sync::mpsc::sync_channel(1);
        let observing = Arc::clone(&app);
        let observer = thread::spawn(move || {
            sent.send(observing.workflow_trace(id, None, 200).unwrap())
                .unwrap();
        });
        let page = received
            .recv_timeout(Duration::from_secs(1))
            .expect("traces remain readable during launch");
        let span = page
            .spans
            .iter()
            .find(|span| span.title == "Review")
            .unwrap();
        assert!(span.is_live && span.terminal_id.is_none() && span.ended_at.is_none());
        let span_id = span.span_id;
        let events = app.trace_events(span_id, None, 200).unwrap().events;
        assert_eq!(span.started_at, events[0].timestamp);
        assert!(events[0].message.contains("Ready for review"));
        drop(stalled);
        observer.join().unwrap();
        completion.join().unwrap();
        let page = app.workflow_trace(id, None, 200).unwrap();
        let span = page
            .spans
            .iter()
            .find(|span| span.span_id == span_id)
            .unwrap();
        assert!(span.is_live && span.terminal_id.is_some());
        accepted(&app, Command::ForceStopWorkflowAgents { workflow_id: id });
    }

    #[test]
    fn stalled_run_launch_keeps_snapshots_available_and_consistent_with_events() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = Arc::new(application(folder.path(), bin.path(), "sleep 60"));
        accepted(
            &app,
            Command::CreateWorkflow {
                folder: folder.path().into(),
                session_id: None,
                kind: WorkflowKind::Draft,
                roles: vec![],
                size: SIZE,
            },
        );
        let before = app.snapshot().unwrap();
        let draft = &before.workflows.workflows[0];
        let id = draft.workflow_id;
        let stalled = app
            .terminal_output
            .stall_recording_worker(draft.terminal_id);
        let starting = Arc::clone(&app);
        let starter = thread::spawn(move || {
            accepted(
                &starting,
                Command::StartWorkflowRun {
                    workflow_id: id,
                    workflow_type: WorkflowTypeRef::Builtin(BuiltinType::Adversarial),
                    prompt: "Test a stalled launch".into(),
                    roles: ["implementer", "reviewer"]
                        .map(|role| RoleLaunch {
                            model: None,
                            effort: None,
                            yolo: false,
                            role: role.into(),
                            harness: HarnessId::Pi,
                        })
                        .into(),
                    size: SIZE,
                },
            );
        });
        let deadline = Instant::now() + Duration::from_secs(3);
        while !app.terminal_output.allocation_is_pending() {
            assert!(
                Instant::now() < deadline,
                "launch did not reach transcript allocation"
            );
            thread::yield_now();
        }
        let (sent, received) = std::sync::mpsc::sync_channel(1);
        let observing = Arc::clone(&app);
        let observer = thread::spawn(move || {
            let snapshot = observing.snapshot().unwrap();
            let events = observing.events_after(before.sequence, 128).unwrap();
            sent.send((snapshot, events)).unwrap();
        });
        let (snapshot, events) = received
            .recv_timeout(Duration::from_secs(1))
            .expect("state must remain available while launch waits on storage");
        let changed = events
            .iter()
            .rev()
            .find_map(|event| match &event.kind {
                EventKind::State(StateEvent::WorkflowChanged(workflow))
                    if workflow.workflow_id == id =>
                {
                    Some(workflow)
                }
                _ => None,
            })
            .expect("the newly visible run must already have an event");
        assert_eq!(changed, &snapshot.workflows.workflows[0]);
        assert!(changed.run.is_some());
        assert_eq!(events.last().unwrap().sequence, snapshot.sequence);
        drop(stalled);
        observer.join().unwrap();
        starter.join().unwrap();
        accepted(&app, Command::ForceStopWorkflowAgents { workflow_id: id });
    }

    fn fail_run_updates(data: &Path) -> rusqlite::Connection {
        let connection = rusqlite::Connection::open(data.join("twine.db")).unwrap();
        connection
            .execute_batch(
                "CREATE TRIGGER reject_run_update BEFORE UPDATE ON workflow_runs
            BEGIN SELECT RAISE(ABORT, 'injected run write failure'); END",
            )
            .unwrap();
        connection
    }

    #[test]
    fn a_failed_first_invocation_keeps_its_failure_in_visible_trace_history() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), "exit 0");
        // A rejected PTY size fails before the launcher can create a process.
        let id = launch_legacy_with_size(
            &app,
            folder.path(),
            BuiltinType::Adversarial,
            TerminalSize { rows: 0, ..SIZE },
            "Test the workflow",
        );
        let workflow = wait_for(&app, id, |w| {
            w.run
                .as_ref()
                .is_some_and(|run| run.status == RunStatus::Paused)
        });
        assert!(
            workflow
                .terminal_ids()
                .iter()
                .all(|terminal| app.terminals.is_running(*terminal))
        );
        let page = app.workflow_trace(id, None, 200).unwrap();
        assert_eq!(page.summary.span_count, 1);
        assert_eq!(page.summary.agent_count, 0);
        let events = app
            .trace_events(page.spans[0].span_id, None, 200)
            .unwrap()
            .events;
        assert!(
            events
                .iter()
                .any(|event| event.message.contains("Couldn't start Implementer"))
        );
        assert_eq!(
            events
                .iter()
                .filter(|event| event.kind == crate::TraceEventKind::ProcessStarted)
                .count(),
            0
        );
        accepted(&app, Command::CloseWorkflow { workflow_id: id });
        assert!(
            app.trace_events(page.spans[0].span_id, None, 200)
                .unwrap()
                .events
                .iter()
                .any(|event| event.message.contains("Couldn't start Implementer"))
        );
    }

    #[test]
    fn failed_launch_publication_stops_and_tracks_every_spawned_terminal() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let data = tempfile::tempdir().unwrap();
        let fixture = application(folder.path(), bin.path(), "sleep 60");
        let mut app = Application::with_config(data.path(), Config::default()).unwrap();
        app.harness_path.clone_from(&fixture.harness_path);
        accepted(
            &app,
            Command::OpenFolder {
                path: folder.path().to_owned(),
            },
        );
        let _failure = fail_run_updates(data.path());
        let id = launch_legacy(&app, folder.path(), BuiltinType::Adversarial);
        let workflow = wait_for(&app, id, |w| {
            w.run
                .as_ref()
                .is_some_and(|run| run.status == RunStatus::Paused)
        });
        assert!(
            !workflow.terminal_ids().is_empty(),
            "healthy terminals remain owned while coordination is paused"
        );
        assert!(
            app.run_processes
                .lock()
                .unwrap()
                .values()
                .all(|processes| processes.inboxes.is_empty() && processes.decisions.is_empty())
        );
        accepted(&app, Command::CloseWorkflow { workflow_id: id });
        for terminal in workflow.terminal_ids() {
            assert!(app.terminals.size(terminal).is_none());
        }
    }

    #[test]
    fn a_run_without_a_prompt_waits_for_input_and_passes_the_reported_task_on() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        // Each agent records its launch prompt, the last argument, in its own file, written whole.
        let app = application(
            folder.path(),
            bin.path(),
            r#"for last; do :; done; printf '%s' "$last" > "p-$$.tmp"; mv "p-$$.tmp" "prompt-$$.txt"; sleep 60"#,
        );
        let id = launch_legacy_with_size(&app, folder.path(), BuiltinType::Adversarial, SIZE, "");
        let prompts = |count: usize| {
            let deadline = Instant::now() + Duration::from_secs(15);
            loop {
                let found: Vec<String> = std::fs::read_dir(folder.path())
                    .unwrap()
                    .filter_map(Result::ok)
                    .filter(|entry| entry.file_name().to_string_lossy().starts_with("prompt-"))
                    .filter_map(|entry| std::fs::read_to_string(entry.path()).ok())
                    .filter(|text| !text.is_empty())
                    .collect();
                if found.len() >= count {
                    return found;
                }
                assert!(Instant::now() < deadline, "agent prompts timed out");
                thread::sleep(Duration::from_millis(10));
            }
        };
        assert!(prompts(1)[0].contains("Wait for the user to give you a task"));

        // A completion without the task goes back to the agent to correct.
        submit_helper(&app, id);
        let run = app.snapshot().unwrap().workflows.workflows[0]
            .run
            .clone()
            .unwrap();
        assert_eq!(run.generation, 1);
        let response = app.run_processes.lock().unwrap()[&id]
            .inboxes
            .values()
            .next()
            .unwrap()
            .1
            .response();
        assert!(response.contains("task"), "{response}");

        submit_signal(
            &app,
            id,
            br#"{"decision":"done","summary":"Done","task":"Add a toggle"}"#,
        );
        wait_for(&app, id, |w| {
            w.run.as_ref().is_some_and(|run| run.generation == 2)
        });
        assert!(
            prompts(2)
                .iter()
                .any(|prompt| prompt.contains("Task:\nAdd a toggle"))
        );
    }

    #[test]
    fn each_role_starts_with_its_chosen_model_and_effort() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        // Each agent records its arguments, written whole, in its own file.
        let app = application(
            folder.path(),
            bin.path(),
            r#"printf '%s ' "$@" > "a-$$.tmp"; mv "a-$$.tmp" "args-$$.txt"; sleep 60"#,
        );
        accepted(
            &app,
            Command::CreateWorkflow {
                folder: folder.path().to_owned(),
                session_id: None,
                kind: WorkflowKind::Draft,
                roles: vec![],
                size: SIZE,
            },
        );
        let id = app.snapshot().unwrap().workflows.workflows[0].workflow_id;
        let role = |role: &str, model: Option<&str>| RoleLaunch {
            role: role.into(),
            harness: HarnessId::Pi,
            model: model.map(str::to_owned),
            effort: model.map(|_| "high".to_owned()),
            yolo: true,
        };
        accepted(
            &app,
            Command::StartWorkflowRun {
                workflow_id: id,
                workflow_type: WorkflowTypeRef::Builtin(BuiltinType::Adversarial),
                prompt: "Task".into(),
                roles: vec![
                    role("implementer", Some("local/m1")),
                    role("reviewer", None),
                ],
                size: SIZE,
            },
        );
        let deadline = Instant::now() + Duration::from_secs(15);
        let arguments = loop {
            let found: Vec<String> = std::fs::read_dir(folder.path())
                .unwrap()
                .filter_map(Result::ok)
                .filter(|entry| entry.file_name().to_string_lossy().starts_with("args-"))
                .filter_map(|entry| std::fs::read_to_string(entry.path()).ok())
                .collect();
            if let Some(found) = found.into_iter().next() {
                break found;
            }
            assert!(Instant::now() < deadline, "the implementer never started");
            thread::sleep(Duration::from_millis(10));
        };
        assert!(
            arguments.contains("--model local/m1 --thinking high "),
            "{arguments}"
        );
    }

    fn submit_helper(app: &Application, id: WorkflowId) {
        submit_signal(app, id, br#"{"decision":"done","summary":"Finished"}"#);
    }

    fn submit_signal(app: &Application, id: WorkflowId, signal: &[u8]) {
        use std::io::Write;
        use std::process::{Command as Process, Stdio};
        let command = app.run_processes.lock().unwrap()[&id]
            .inboxes
            .values()
            .next()
            .unwrap()
            .1
            .command();
        let mut child = Process::new("/bin/sh")
            .args(["-c", &command])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(signal).unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            app.poll_workflow_signals().unwrap();
            let remains = app
                .run_processes
                .lock()
                .unwrap()
                .get(&id)
                .is_some_and(|processes| {
                    processes
                        .inboxes
                        .values()
                        .any(|(_, inbox)| inbox.command() == command)
                });
            if let Some(status) = child.try_wait().unwrap() {
                assert_eq!(status.success(), !remains);
                return;
            }
            assert!(Instant::now() < deadline, "completion wasn't processed");
            thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn a_completion_write_failure_reports_retry_and_cancellation_still_stops_agents() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let data = tempfile::tempdir().unwrap();
        let fixture = application(folder.path(), bin.path(), "sleep 60");
        let mut app = Application::with_config(data.path(), Config::default()).unwrap();
        app.harness_path.clone_from(&fixture.harness_path);
        accepted(
            &app,
            Command::OpenFolder {
                path: folder.path().to_owned(),
            },
        );
        let id = launch_legacy(&app, folder.path(), BuiltinType::Adversarial);
        let failure = fail_run_updates(data.path());
        let before = app.workflow_trace(id, None, 200).unwrap();
        submit_helper(&app, id);
        let snapshot = app.snapshot().unwrap();
        assert_eq!(app.workflow_trace(id, None, 200).unwrap(), before);
        assert_eq!(
            snapshot.workflows.workflows[0]
                .run
                .as_ref()
                .unwrap()
                .generation,
            1
        );
        assert_ne!(
            app.run_processes.lock().unwrap()[&id]
                .inboxes
                .values()
                .next()
                .unwrap()
                .1
                .response(),
            ""
        );
        failure
            .execute_batch("DROP TRIGGER reject_run_update")
            .unwrap();
        submit_helper(&app, id);
        let snapshot = app.snapshot().unwrap();
        let page = app.workflow_trace(id, None, 200).unwrap();
        assert_eq!(page.summary.span_count, before.summary.span_count + 1);
        let first = page
            .spans
            .iter()
            .find(|span| span.span_id == before.spans[0].span_id)
            .unwrap();
        assert_eq!(first.status, crate::TraceSpanStatus::Completed);
        let events = app.trace_events(first.span_id, None, 200).unwrap().events;
        assert_eq!(
            events
                .iter()
                .filter(|event| event.message.contains("Result reported:"))
                .count(),
            1
        );
        assert_eq!(
            snapshot.workflows.workflows[0]
                .run
                .as_ref()
                .unwrap()
                .generation,
            2
        );
        let _failure = fail_run_updates(data.path());
        accepted(&app, Command::ForceStopWorkflowAgents { workflow_id: id });
        let cancelled = app.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(cancelled.run.as_ref().unwrap().status, RunStatus::Idle);
        assert!(
            cancelled
                .terminal_ids()
                .iter()
                .all(|terminal| app.terminals.is_running(*terminal))
        );
    }

    #[test]
    fn a_custom_type_launch_pins_its_version_and_definition() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), FAKE);
        let original = BuiltinType::Adversarial.definition();
        let reference = WorkflowCatalog::new(app.lock_inner().unwrap().folders.store())
            .create(&original)
            .unwrap();
        let WorkflowTypeRef::User { type_id, .. } = reference else {
            panic!("custom reference")
        };
        let mut edited = original.clone();
        edited.name = "Edited type".into();
        WorkflowCatalog::new(app.lock_inner().unwrap().folders.store())
            .edit(type_id, &edited)
            .unwrap();
        accepted(
            &app,
            Command::CreateWorkflow {
                folder: folder.path().to_owned(),
                session_id: None,
                kind: WorkflowKind::Draft,
                roles: vec![],
                size: SIZE,
            },
        );
        let id = app.snapshot().unwrap().workflows.workflows[0].workflow_id;
        accepted(
            &app,
            Command::StartWorkflowRun {
                workflow_id: id,
                workflow_type: reference,
                prompt: "Task".into(),
                roles: original
                    .roles
                    .iter()
                    .map(|role| RoleLaunch {
                        model: None,
                        effort: None,
                        yolo: false,
                        role: role.id.0.clone(),
                        harness: HarnessId::Pi,
                    })
                    .collect(),
                size: SIZE,
            },
        );
        let workflow = wait_for(&app, id, |w| {
            w.run.as_ref().is_some_and(|run| run.work_completed())
        });
        let run = workflow.run.unwrap();
        assert_eq!(run.reference(), reference);
        assert_eq!(run.workflow_type.definition, original);
    }

    /// Opt-in smoke test: uses an authenticated, installed Codex in a disposable folder. The wrapper
    /// selects its noninteractive mode so unattended verification doesn't need a trust-dialog click.
    #[test]
    #[ignore = "requires a real authenticated Codex; set HANDSHAKE_REAL_CODEX to its absolute path"]
    fn real_adversarial_workflow_completes() {
        let codex = std::env::var("HANDSHAKE_REAL_CODEX").expect("set HANDSHAKE_REAL_CODEX");
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let wrapper = bin.path().join("codex");
        let quoted = codex.replace('\'', "'\\''");
        std::fs::write(&wrapper, format!(
            "#!/bin/sh\nexec '{quoted}' exec --ephemeral --skip-git-repo-check --sandbox workspace-write --ignore-user-config \"$@\"\n"
        )).unwrap();
        std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o755)).unwrap();
        let app = application(folder.path(), bin.path(), "exit 1");
        accepted(
            &app,
            Command::CreateWorkflow {
                folder: folder.path().to_owned(),
                session_id: None,
                kind: WorkflowKind::Draft,
                roles: vec![],
                size: SIZE,
            },
        );
        let id = app.snapshot().unwrap().workflows.workflows[0].workflow_id;
        accepted(&app, Command::StartWorkflowRun { workflow_id: id,
            workflow_type: WorkflowTypeRef::Builtin(BuiltinType::Adversarial),
            prompt: "This is a small smoke test. Implementer: create proof.txt containing exactly 'Handshake workflow works' followed by a newline, then submit completion using the supplied command. Reviewer: read proof.txt, approve if correct, and submit the explicit review decision. Do not use git, install tools, or change anything else. Execute the completion command; do not merely describe it.".into(),
            roles: vec![RoleLaunch { role: "implementer".into(), harness: HarnessId::Codex, model: None, effort: None, yolo: false },
                        RoleLaunch { role: "reviewer".into(), harness: HarnessId::Codex, model: None, effort: None, yolo: false }], size: SIZE });
        let deadline = Instant::now() + Duration::from_secs(240);
        let mut terminal_output = Vec::new();
        loop {
            while let Some(chunk) = app.next_terminal_chunk().unwrap() {
                terminal_output.extend(chunk.bytes);
            }
            let snapshot = app.snapshot().unwrap();
            let workflow = &snapshot.workflows.workflows[0];
            if workflow
                .run
                .as_ref()
                .is_some_and(|run| run.work_completed())
            {
                break;
            }
            if Instant::now() >= deadline
                || workflow
                    .run
                    .as_ref()
                    .is_some_and(|run| run.status != RunStatus::Running)
            {
                let log = std::env::temp_dir().join("handshake-real-adversarial-output.txt");
                std::fs::write(&log, terminal_output).unwrap();
                panic!("real run didn't complete; inspect {}", log.display());
            }
            thread::sleep(Duration::from_millis(50));
        }
        assert_eq!(
            std::fs::read_to_string(folder.path().join("proof.txt")).unwrap(),
            "Handshake workflow works\n"
        );
    }
    #[test]
    fn reopened_runs_keep_outcomes_and_reject_delayed_completions_without_processes() {
        for outcome in [RunStatus::Running, RunStatus::Completed, RunStatus::Failed] {
            let folder = tempfile::tempdir().unwrap();
            let bin = tempfile::tempdir().unwrap();
            let app = application(folder.path(), bin.path(), "while :; do sleep 1; done");
            let id = launch_legacy(&app, folder.path(), BuiltinType::Adversarial);
            let original = app.snapshot().unwrap().workflows.workflows[0].clone();
            let run = original.run.as_ref().unwrap();
            let late = Command::CompleteWorkflowRole {
                workflow_id: id,
                agent_id: original.agents[0].agent_id,
                generation: run.generation,
                signal: CompletionSignal {
                    decision: Decision::Done,
                    summary: "Late".into(),
                    assignments: Vec::new(),
                    task: String::new(),
                },
            };
            if outcome != RunStatus::Running {
                let mut inner = app.lock_inner().unwrap();
                let mut workflow = inner.workflows.workflows[0].clone();
                workflow
                    .run
                    .as_mut()
                    .unwrap()
                    .finish(outcome, "Outcome before close");
                workflow.status = workflow_status(outcome);
                inner.publish_run(0, workflow).unwrap();
            }
            accepted(&app, Command::CloseWorkflow { workflow_id: id });
            assert!(app.run_processes.lock().unwrap().get(&id).is_none());
            accepted(&app, Command::ReopenWorkflow { workflow_id: id });
            assert!(
                matches!(app.handle_command(RequestId(2), late).unwrap().disposition,
                CommandDisposition::Rejected { code, .. } if code == "workflowArchived")
            );
            app.poll_workflow_signals().unwrap();
            let snapshot = app.snapshot().unwrap();
            let reopened = &snapshot.workflows.workflows[0];
            let expected = match outcome {
                RunStatus::Completed => RunStatus::Idle,
                _ => RunStatus::Paused,
            };
            assert_eq!(reopened.status, WorkflowStatus::Running);
            assert_eq!(reopened.run.as_ref().unwrap().status, expected);
            assert_eq!(
                reopened.run.as_ref().unwrap().work_completed(),
                outcome == RunStatus::Completed
            );
            assert_eq!(snapshot.terminals, []);
        }
    }
    fn decision_chain_definition() -> crate::WorkflowTypeDefinition {
        let mut definition = graph_definition(&[], crate::GraphFinish::All);
        for id in ["ready", "classify", "scope"] {
            let mut role = definition.roles[0].clone();
            role.id = crate::RoleId(id.into());
            role.name = id.into();
            definition.roles.push(role);
        }
        let node = |kind| crate::DecisionNode {
            question: "Which route matches the evidence?".into(),
            kind,
            options: ["continue", "other", "large"]
                .iter()
                .map(|id| crate::DecisionOption {
                    id: (*id).into(),
                    name: (*id).into(),
                    description: format!("Meaning of {id}"),
                })
                .collect(),
            true_threshold: 8000,
            false_threshold: 2000,
            min_confidence: None,
            score_thresholds: None,
            provider: None,
            model: None,
            include_task: true,
        };
        let graph = definition.graph.as_mut().unwrap();
        graph
            .decisions
            .insert("ready".into(), node(crate::DecisionKind::Noul));
        graph
            .decisions
            .insert("classify".into(), node(crate::DecisionKind::Choice));
        graph
            .decisions
            .insert("scope".into(), node(crate::DecisionKind::Score));
        for (from, output, to) in [
            ("ready", "yes", "classify"),
            ("ready", "no", "reviewer"),
            ("ready", "uncertain", "reviewer"),
            ("classify", "continue", "scope"),
            ("classify", "other", "reviewer"),
            ("classify", "large", "reviewer"),
            ("scope", "continue", "implementer"),
            ("scope", "other", "implementer"),
            ("scope", "large", "implementer"),
        ] {
            graph.edges.push(crate::GraphEdge {
                always: false,
                id: format!("{from}-{output}"),
                from: from.into(),
                to: to.into(),
                event: crate::GraphEvent::Done,
                output: Some(output.into()),
            });
        }
        definition
    }

    #[test]
    fn single_output_decision_chain_forwards_without_nouli_or_decision_results() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(
            folder.path(),
            bin.path(),
            "while read line; do echo \"$line\"; done",
        );
        let mut definition = decision_chain_definition();
        definition.roles.retain(|r| r.id.0 != "reviewer");
        let graph = definition.graph.as_mut().unwrap();
        graph.positions.remove("reviewer");
        graph.edges.retain(|e| {
            matches!(
                (e.from.as_str(), e.output.as_deref()),
                ("ready", Some("yes")) | ("classify" | "scope", Some("continue"))
            )
        });
        graph.edges[0].always = true;
        graph.edges[0].output = None;
        for node in graph.decisions.values_mut() {
            node.options.clear();
            node.question.clear();
            node.model = Some("--unused-invalid-model".into());
        }
        crate::validate(&definition).unwrap();
        let id = launch_graph(
            &app,
            folder.path(),
            &definition,
            "Original evidence for passthrough",
        );
        let workflow = wait_for(&app, id, |w| {
            w.run
                .as_ref()
                .unwrap()
                .agents
                .iter()
                .filter(|a| a.harness == HarnessId::Nouli)
                .all(|a| a.status == crate::RunAgentStatus::Completed)
        });
        let run = workflow.run.as_ref().unwrap();
        let graph = run.graph.as_ref().unwrap();
        assert!(graph.decision_requests.is_empty());
        assert!(graph.decision_results.is_empty());
        assert!(graph.decision_outputs.is_empty());
        assert!(!run.traces.iter().any(|e| e.kind.starts_with("decision")));
        let receiver = run.agents.iter().find(|a| a.role == "implementer").unwrap();
        assert!(run.incoming[&receiver.agent_id].contains("Original evidence for passthrough"));
        assert!(
            !app.run_processes.lock().unwrap()[&id]
                .harnesses
                .contains_key(&HarnessId::Nouli)
        );
        accepted(&app, Command::ForceStopWorkflowAgents { workflow_id: id });
    }

    fn prepare_nouli(
        app: &mut Application,
        home: &Path,
    ) -> crate::harness::nouli::fixture::Provider {
        app.nouli_home = Some(home.to_owned());
        crate::harness::nouli::fixture::Provider::new(home)
    }

    #[test]
    fn nouli_chain_preserves_typed_inputs_traces_and_skips_unselected_results() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let mut app = application(folder.path(), bin.path(), "exec cat");
        let provider = prepare_nouli(&mut app, bin.path());
        assert!(!bin.path().join("nouli").exists());
        let id = launch_graph(
            &app,
            folder.path(),
            &decision_chain_definition(),
            "Original task with acceptance criteria",
        );
        let workflow = wait_for(&app, id, |w| {
            w.run
                .as_ref()
                .unwrap()
                .graph
                .as_ref()
                .unwrap()
                .decision_results
                .len()
                == 3
        });
        assert_eq!(provider.calls(), 3);
        let run = workflow.run.as_ref().unwrap();
        let graph = run.graph.as_ref().unwrap();
        let implementer = run.agents.iter().find(|a| a.role == "implementer").unwrap();
        let reviewer = run.agents.iter().find(|a| a.role == "reviewer").unwrap();
        assert!(!graph.activations.contains_key(&reviewer.agent_id));
        let scope = run.agents.iter().find(|a| a.role == "scope").unwrap();
        assert_eq!(
            graph.decision_results[&scope.agent_id]["result"]["report"]["outcome"]["outcomes"][0]["answer"]
                ["value"],
            1.43
        );
        assert_eq!(
            graph.decision_requests[&scope.agent_id]["state"][0]["data"]["workflow_task"],
            "Original task with acceptance criteria"
        );
        assert!(
            graph.decision_requests[&scope.agent_id]
                .to_string()
                .contains("ready")
        );
        accepted(
            &app,
            Command::CompleteWorkflowRole {
                workflow_id: id,
                agent_id: AgentId(implementer.agent_id),
                generation: run.assignment_generation(implementer.agent_id),
                signal: CompletionSignal {
                    decision: Decision::Done,
                    summary: "Implemented".into(),
                    task: String::new(),
                    assignments: vec![],
                },
            },
        );
        let finished = wait_for(&app, id, |w| w.run.as_ref().unwrap().work_completed());
        assert_eq!(
            finished
                .run
                .as_ref()
                .unwrap()
                .graph
                .as_ref()
                .unwrap()
                .outputs
                .len(),
            1
        );
        let trace = app.workflow_trace(id, None, 200).unwrap();
        assert_eq!(
            trace
                .lanes
                .iter()
                .filter(|lane| lane.harness.as_deref() == Some("Nouli"))
                .count(),
            3
        );
        assert!(trace.spans.iter().any(|span| span.title == "Graph"));
    }

    #[test]
    fn nouli_refusal_needs_explicit_retry_and_keeps_the_frozen_input() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let mut app = application(folder.path(), bin.path(), "exec cat");
        let provider = prepare_nouli(&mut app, bin.path());
        provider
            .refuse
            .store(true, std::sync::atomic::Ordering::Relaxed);
        let id = launch_graph(
            &app,
            folder.path(),
            &decision_chain_definition(),
            "Frozen task",
        );
        let paused = wait_for(&app, id, |w| {
            w.run
                .as_ref()
                .is_some_and(|run| run.status == RunStatus::Paused)
        });
        let run = paused.run.as_ref().unwrap();
        let graph = run.graph.as_ref().unwrap();
        assert_eq!(graph.decision_errors.len(), 1);
        assert_eq!(graph.decision_results.len(), 1);
        assert!(graph.decision_outputs.is_empty());
        let frozen = graph.decision_requests.clone();
        app.resume_workflow_run(&paused, folder.path()).unwrap();
        assert_eq!(
            app.snapshot().unwrap().workflows.workflows[0].status,
            WorkflowStatus::Running
        );
        let generation = app.snapshot().unwrap().workflows.workflows[0]
            .run
            .as_ref()
            .unwrap()
            .generation;
        assert_eq!(
            provider.calls(),
            1,
            "restoring conversations must not retry work"
        );
        provider
            .refuse
            .store(false, std::sync::atomic::Ordering::Relaxed);
        accepted(
            &app,
            Command::RetryDecision {
                workflow_id: id,
                generation,
            },
        );
        let resumed = wait_for(&app, id, |w| {
            w.run
                .as_ref()
                .unwrap()
                .graph
                .as_ref()
                .unwrap()
                .decision_results
                .len()
                == 3
        });
        let resumed_graph = resumed.run.as_ref().unwrap().graph.as_ref().unwrap();
        for (agent, request) in frozen {
            assert_eq!(resumed_graph.decision_requests[&agent], request);
        }
        accepted(&app, Command::ForceStopWorkflowAgents { workflow_id: id });
    }

    #[test]
    fn nouli_completed_response_survives_a_failed_store_update() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let fixture = application(folder.path(), bin.path(), "exec cat");
        let data = tempfile::tempdir().unwrap();
        let mut app = Application::with_config(data.path(), Config::default()).unwrap();
        app.harness_path.clone_from(&fixture.harness_path);
        accepted(
            &app,
            Command::OpenFolder {
                path: folder.path().to_owned(),
            },
        );
        let _provider = prepare_nouli(&mut app, bin.path());
        let id = launch_graph(&app, folder.path(), &decision_chain_definition(), "Task");
        let connection = fail_run_updates(data.path());
        let deadline = Instant::now() + Duration::from_secs(15);
        while app.snapshot().is_ok() {
            assert!(
                Instant::now() < deadline,
                "decision response did not reach persistence"
            );
            thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(app.run_processes.lock().unwrap()[&id].decisions.len(), 1);
        connection
            .execute_batch("DROP TRIGGER reject_run_update")
            .unwrap();
        let workflow = wait_for(&app, id, |w| {
            w.run
                .as_ref()
                .unwrap()
                .graph
                .as_ref()
                .unwrap()
                .decision_results
                .len()
                == 3
        });
        assert_eq!(
            workflow
                .run
                .as_ref()
                .unwrap()
                .traces
                .iter()
                .filter(|e| e.kind == "decisionStarted")
                .count(),
            3
        );
        accepted(&app, Command::ForceStopWorkflowAgents { workflow_id: id });
    }
    #[test]
    fn nouli_launch_waits_for_publication_and_cancel_joins_the_evaluation() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let data = tempfile::tempdir().unwrap();
        let fixture = application(folder.path(), bin.path(), "exec cat");
        let mut app = Application::with_config(data.path(), Config::default()).unwrap();
        app.harness_path.clone_from(&fixture.harness_path);
        accepted(
            &app,
            Command::OpenFolder {
                path: folder.path().to_owned(),
            },
        );
        let provider = prepare_nouli(&mut app, bin.path());
        provider
            .stall
            .store(true, std::sync::atomic::Ordering::Relaxed);
        let definition = decision_chain_definition();
        let reference = WorkflowCatalog::new(app.lock_inner().unwrap().folders.store())
            .create(&definition)
            .unwrap();
        accepted(
            &app,
            Command::CreateWorkflow {
                folder: folder.path().into(),
                session_id: None,
                kind: WorkflowKind::Draft,
                roles: vec![],
                size: SIZE,
            },
        );
        let id = app.snapshot().unwrap().workflows.workflows[0].workflow_id;
        let connection = fail_run_updates(data.path());
        let result = app.handle_command(
            RequestId(9001),
            Command::StartWorkflowRun {
                workflow_id: id,
                workflow_type: reference,
                prompt: "Task".into(),
                roles: definition
                    .roles
                    .iter()
                    .filter(|r| {
                        !definition
                            .graph
                            .as_ref()
                            .unwrap()
                            .decisions
                            .contains_key(&r.id.0)
                    })
                    .map(|r| RoleLaunch {
                        role: r.id.0.clone(),
                        harness: HarnessId::Pi,
                        model: None,
                        effort: None,
                        yolo: false,
                    })
                    .collect(),
                size: SIZE,
            },
        );
        assert!(result.is_ok());
        assert_eq!(provider.calls(), 0);
        assert!(
            app.run_processes
                .lock()
                .unwrap()
                .get(&id)
                .is_none_or(|p| p.decisions.is_empty())
        );
        connection
            .execute_batch("DROP TRIGGER reject_run_update")
            .unwrap();
        assert_eq!(
            app.snapshot().unwrap().workflows.workflows[0].status,
            WorkflowStatus::Running
        );
        let mut app = application(folder.path(), bin.path(), "exec cat");
        app.nouli_home = Some(bin.path().to_owned());
        let id = launch_graph(&app, folder.path(), &definition, "Task");
        wait_for(&app, id, |_| provider.calls() == 1);
        let start = Instant::now();
        accepted(&app, Command::ForceStopWorkflowAgents { workflow_id: id });
        assert!(start.elapsed() < Duration::from_secs(2));
        assert!(
            app.run_processes
                .lock()
                .unwrap()
                .get(&id)
                .is_none_or(|processes| processes.decisions.is_empty())
        );
        provider
            .stall
            .store(false, std::sync::atomic::Ordering::Relaxed);
        thread::sleep(Duration::from_millis(50));
        assert_eq!(
            app.snapshot().unwrap().workflows.workflows[0].status,
            WorkflowStatus::Running
        );
    }
}
