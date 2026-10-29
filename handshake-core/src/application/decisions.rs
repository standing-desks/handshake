//! Decision activations use bundled Nouli workers and the graph's assignment generations.
use std::collections::HashMap;

use super::{Application, ApplicationError, CommandDisposition};
use crate::harness::nouli::Invocation;
use crate::workflow::{AgentId, WorkflowId, timestamp};
use crate::{CompletionSignal, Decision, RunAgentStatus, RunStatus, WorkflowRun};

pub(super) enum DecisionCall {
    Running(Invocation),
    Finished(Result<serde_json::Value, String>),
}
impl DecisionCall {
    fn poll(&mut self) -> Option<Result<serde_json::Value, String>> {
        match self {
            Self::Running(call) => call.poll(),
            Self::Finished(result) => Some(result.clone()),
        }
    }
}
pub(super) type PendingDecisions = HashMap<AgentId, (u64, DecisionCall)>;
pub(super) struct PreparedDecision {
    agent: AgentId,
    generation: u64,
    node: crate::DecisionNode,
    request: serde_json::Value,
}

impl Application {
    pub(super) fn locate_run_harnesses(
        &self,
        run: &WorkflowRun,
    ) -> Result<
        HashMap<crate::HarnessId, crate::harness::LocatedHarness>,
        crate::harness::HarnessError,
    > {
        let mut harnesses = HashMap::new();
        let graph = run.workflow_type.definition.graph.as_ref();
        for agent in run
            .agents
            .iter()
            .filter(|agent| agent.harness != crate::HarnessId::Nouli)
            .filter(|agent| graph.is_none_or(|graph| graph.passthrough_edge(&agent.role).is_none()))
        {
            if let std::collections::hash_map::Entry::Vacant(entry) = harnesses.entry(agent.harness)
            {
                entry.insert(self.locate_harness(agent.harness.definition())?);
            }
        }
        Ok(harnesses)
    }

    pub(super) fn prepare_decisions(run: &mut WorkflowRun) -> Vec<PreparedDecision> {
        let mut prepared = Vec::new();
        if run.graph.as_ref().is_none_or(|g| !g.started) {
            return prepared;
        }
        if let Err(error) = run.forward_graph_passthroughs() {
            run.finish(
                RunStatus::Failed,
                &format!("Could not forward work: {error}"),
            );
            return prepared;
        }
        let agents: Vec<_> = run
            .active_agents()
            .into_iter()
            .filter(|a| a.harness == crate::HarnessId::Nouli && a.status == RunAgentStatus::Waiting)
            .cloned()
            .collect();
        for agent in agents {
            let node = run
                .workflow_type
                .definition
                .graph
                .as_ref()
                .expect("graph")
                .decisions[&agent.role]
                .clone();
            let request = run
                .graph
                .as_mut()
                .expect("graph")
                .decision_requests
                .entry(agent.agent_id)
                .or_insert_with(|| {
                    node.request(
                        &run.prompt,
                        run.incoming.get(&agent.agent_id).map_or("", String::as_str),
                    )
                })
                .clone();
            run.graph_agent_launched(agent.agent_id);
            run.agents
                .iter_mut()
                .find(|a| a.agent_id == agent.agent_id)
                .expect("agent")
                .status = RunAgentStatus::Running;
            run.trace(
                "decisionStarted",
                Some(agent.agent_id),
                None,
                "Nouli is evaluating the captured inputs.",
            );
            run.trace(
                "decisionInput",
                Some(agent.agent_id),
                None,
                &request.to_string(),
            );
            prepared.push(PreparedDecision {
                agent: AgentId(agent.agent_id),
                generation: run.assignment_generation(agent.agent_id),
                node,
                request,
            });
        }
        prepared
    }

    // Called only after the captured request and assigned status have committed.
    pub(super) fn start_decisions(
        &self,
        workflow_id: WorkflowId,
        prepared: Vec<PreparedDecision>,
    ) -> Result<(), ApplicationError> {
        let mut registry = self
            .run_processes
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?;
        let Some(processes) = registry.get_mut(&workflow_id) else {
            return Ok(());
        };
        for call in prepared {
            if processes.decisions.contains_key(&call.agent) {
                continue;
            }
            #[cfg(test)]
            let home = self.nouli_home.clone();
            #[cfg(not(test))]
            let home = None;
            let result = Invocation::start(
                &processes.folder,
                &call.node,
                &call.request,
                home,
                std::sync::Arc::clone(&self.login_path),
            );
            let call_state = match result {
                Ok(invocation) => DecisionCall::Running(invocation),
                Err(error) => DecisionCall::Finished(Err(error.to_string())),
            };
            processes
                .decisions
                .insert(call.agent, (call.generation, call_state));
        }
        Ok(())
    }

    pub(super) fn poll_decisions(&self) -> Result<(), ApplicationError> {
        let mut completed = Vec::new();
        {
            let mut registry = self
                .run_processes
                .lock()
                .map_err(|_| ApplicationError::Poisoned)?;
            for (workflow, processes) in registry.iter_mut() {
                let ready: Vec<_> = processes
                    .decisions
                    .iter_mut()
                    .filter_map(|(agent, (generation, call))| {
                        call.poll().map(|result| (*agent, *generation, result))
                    })
                    .collect();
                for (agent, generation, result) in ready {
                    completed.push((*workflow, agent, generation, result));
                }
            }
        }
        for (workflow, agent, generation, result) in completed {
            self.accept_decision(workflow, agent, generation, result)?;
            let mut registry = self
                .run_processes
                .lock()
                .map_err(|_| ApplicationError::Poisoned)?;
            if let Some(processes) = registry.get_mut(&workflow)
                && processes
                    .decisions
                    .get(&agent)
                    .is_some_and(|(current, _)| *current == generation)
            {
                processes.decisions.remove(&agent);
            }
        }
        Ok(())
    }

    fn accept_decision(
        &self,
        workflow_id: WorkflowId,
        agent: AgentId,
        generation: u64,
        result: Result<serde_json::Value, String>,
    ) -> Result<(), ApplicationError> {
        let mut inner = self.lock_inner()?;
        let Some(index) = inner
            .workflows
            .workflows
            .iter()
            .position(|w| w.workflow_id == workflow_id)
        else {
            return Ok(());
        };
        let mut workflow = inner.workflows.workflows[index].clone();
        let Some(run) = workflow.run.as_mut() else {
            return Ok(());
        };
        if run.status != RunStatus::Running
            || run.assignment_generation(agent.0) != generation
            || !run.active_agents().iter().any(|a| a.agent_id == agent.0)
        {
            return Ok(());
        }
        let role = run
            .agents
            .iter()
            .find(|a| a.agent_id == agent.0)
            .expect("active")
            .role
            .clone();
        let node = run
            .workflow_type
            .definition
            .graph
            .as_ref()
            .expect("graph")
            .decisions[&role]
            .clone();
        let routed = result.and_then(|report| match node.route(&report) {
            Ok(output) => Ok((report, output)),
            Err(error) => {
                if error != crate::DecisionResultError::Invalid {
                    run.graph
                        .as_mut()
                        .expect("graph")
                        .decision_results
                        .insert(agent.0, report.clone());
                    run.trace("decisionOutcome", Some(agent.0), None, &report.to_string());
                }
                Err(error.to_string())
            }
        });
        match routed {
            Ok((report, output)) => {
                // Preserve the original typed response and ancestry in the handoff, never a rounded scalar.
                let evidence = serde_json::json!({"decision":role,"output":output,"report":report,"incoming":run.incoming.get(&agent.0)});
                let summary =
                    serde_json::to_string(&evidence).map_err(|_| ApplicationError::Poisoned)?;
                if summary.len() > 128 * 1024 {
                    pause(
                        run,
                        agent.0,
                        "The decision handoff exceeded its size limit.",
                    );
                } else {
                    let mut next = run.as_ref().clone();
                    let graph = next.graph.as_mut().expect("graph");
                    graph.decision_results.insert(agent.0, report);
                    graph.decision_outputs.insert(agent.0, output.clone());
                    next.trace("decisionAnswered", Some(agent.0), None, &summary);
                    match next.complete_graph(
                        agent.0,
                        generation,
                        &CompletionSignal {
                            decision: Decision::Done,
                            summary,
                            assignments: vec![],
                            task: String::new(),
                        },
                    ) {
                        Ok(_) => {
                            **run = next;
                        }
                        Err(error) => {
                            pause(run, agent.0, &format!("Decision delivery paused: {error}"));
                        }
                    }
                }
            }
            Err(message) => pause(run, agent.0, &message),
        }
        workflow.status = super::runs::workflow_status(run.status);
        if run.status != RunStatus::Running {
            workflow.ended_at = Some(timestamp());
        }
        let stopped = run.status == RunStatus::Interrupted;
        let terminals = workflow.terminal_ids();
        inner.publish_run(index, workflow)?;
        drop(inner);
        if stopped {
            self.stop_run_terminals(&terminals, "Decision paused; workflow agents stopped.");
        }
        Ok(())
    }

    pub(super) fn retry_decision(
        &self,
        workflow_id: WorkflowId,
        generation: u64,
    ) -> Result<CommandDisposition, ApplicationError> {
        let (mut workflow, folder) = {
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
            let Some(run) = workflow.run.as_ref() else {
                return Ok(super::workflows::reject(
                    "notDecision",
                    "This workflow has no decision.",
                ));
            };
            if run.generation != generation
                || run.status != RunStatus::Interrupted
                || run
                    .graph
                    .as_ref()
                    .is_none_or(|g| g.decision_errors.is_empty())
            {
                return Ok(super::workflows::reject(
                    "staleDecision",
                    "The decision is not awaiting a retry.",
                ));
            }
            (
                workflow.clone(),
                inner
                    .folders
                    .state()
                    .open_folder
                    .clone()
                    .ok_or(ApplicationError::Poisoned)?,
            )
        };
        workflow
            .run
            .as_mut()
            .expect("checked")
            .graph
            .as_mut()
            .expect("checked")
            .decision_errors
            .clear();
        self.resume_workflow_run(&workflow, &folder)?;
        Ok(CommandDisposition::Accepted)
    }
}

fn pause(run: &mut WorkflowRun, agent: u64, message: &str) {
    run.graph
        .as_mut()
        .expect("graph")
        .decision_errors
        .insert(agent, message.to_owned());
    run.trace("decisionPaused", Some(agent), None, message);
    run.finish(RunStatus::Interrupted, message);
}
