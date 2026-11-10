//! Durable, harness-independent steps. Adapters normalize activity before it reaches storage.

use rusqlite::{OptionalExtension, params};

use super::traces::{insert_event, insert_span_record};
use super::{NewTraceSpan, Store, StoreError, TraceEnding, sql_integer};
use crate::harness::steps::{HarnessStep, StepKind};
use crate::{TerminalId, TraceAnchor, TraceEventKind, TraceSpanId, TraceSpanStatus, WorkflowId};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[expect(
        clippy::too_many_lines,
        reason = "compare two complete native invocation lifetimes and their saved events"
    )]
    fn resuming_in_the_same_terminal_preserves_prior_turns_and_process_endings() {
        let directory = tempfile::tempdir().unwrap();
        let mut store = Store::open(&directory.path().join("traces.db")).unwrap();
        let session = store
            .create_session(std::path::Path::new("/folder"), "Work", 1)
            .unwrap();
        let workflow = store
            .create_workflow(session, "Agent", crate::WorkflowKind::Terminal, &[])
            .unwrap()
            .0;
        store.execute_test_sql(&format!(
            "INSERT INTO workflow_terminals(terminal_id,workflow_id) VALUES(1,{})",
            workflow.0
        ));
        let anchor = TraceAnchor {
            terminal_id: TerminalId::from_value(1),
            byte_offset: 0,
            boundary_sizes: None,
        };
        let mut previous: Option<(crate::TraceSpan, Vec<crate::TraceEvent>)> = None;
        for (time, title) in [(10, "First task"), (20, "Resumed task")] {
            let fallback = store
                .start_trace_span(&NewTraceSpan {
                    workflow_id: workflow,
                    lane_key: "agent",
                    lane_name: "Agent",
                    is_agent: true,
                    role: Some("agent"),
                    harness: Some("Pi"),
                    title: "Pi",
                    started_at: time,
                    anchor: Some(anchor.clone()),
                })
                .unwrap();
            store
                .bind_harness_session(anchor.terminal_id, title, Some(fallback))
                .unwrap();
            let context = HarnessStepContext {
                workflow_id: workflow,
                single_agent: true,
                invocation_span: Some(fallback),
                activate: true,
                span: None,
            };
            let mut step = HarnessStep {
                activity: None,
                session_id: None,
                kind: StepKind::Prompt,
                turn_id: Some("native-turn".into()),
                tool_call_id: None,
                title: title.into(),
                detail: title.into(),
            };
            assert_eq!(
                store
                    .record_harness_step(context, &step, time + 1, &anchor)
                    .unwrap(),
                Some(fallback)
            );
            let page = store.workflow_trace(workflow, None, 20).unwrap();
            let current = page
                .spans
                .iter()
                .find(|span| span.span_id == fallback)
                .unwrap();
            assert_eq!(current.title, title);
            assert_eq!(current.status, TraceSpanStatus::Running);
            if let Some((ref prior, ref events)) = previous {
                assert_eq!(
                    store
                        .history_request(prior.span_id)
                        .unwrap()
                        .unwrap()
                        .session,
                    "First task"
                );

                assert_eq!(
                    page.spans.iter().find(|span| span.span_id == prior.span_id),
                    Some(prior)
                );
                assert_eq!(
                    &store.trace_events(prior.span_id, None, 20).unwrap().events,
                    events
                );
            }
            step.kind = StepKind::Responded;
            store
                .record_harness_step(
                    HarnessStepContext {
                        activate: false,
                        ..context
                    },
                    &step,
                    time + 2,
                    &anchor,
                )
                .unwrap();
            store
                .record_harness_process_ending(
                    workflow,
                    anchor.terminal_id,
                    &TraceEnding {
                        observed_at: time + 3,
                        status: TraceSpanStatus::Exited,
                        kind: TraceEventKind::ProcessExited,
                        message: "Harness exited",
                        anchor: Some(anchor.clone()),
                    },
                )
                .unwrap();
            let page = store.workflow_trace(workflow, None, 20).unwrap();
            previous = Some((
                page.spans
                    .iter()
                    .find(|span| span.span_id == fallback)
                    .unwrap()
                    .clone(),
                store.trace_events(fallback, None, 20).unwrap().events,
            ));
        }
    }

    #[test]
    fn assignment_titles_keep_the_first_prompt_across_retries_and_reopen() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("traces.db");
        let mut store = Store::open(&path).unwrap();
        let session = store
            .create_session(std::path::Path::new("/folder"), "Work", 100)
            .unwrap();
        let workflow = store
            .create_workflow(session, "Graph", crate::WorkflowKind::Terminal, &[])
            .unwrap()
            .0;
        let anchor = TraceAnchor {
            terminal_id: TerminalId::from_value(1),
            byte_offset: 0,
            boundary_sizes: None,
        };
        let mut spans = Vec::new();
        // The same terminal can receive multiple assignments without native turn IDs.
        for title in ["Explain the parser", "Add Unicode support"] {
            let span = store
                .start_trace_span(&NewTraceSpan {
                    workflow_id: workflow,
                    lane_key: "agent:1",
                    lane_name: "Implementer",
                    is_agent: true,
                    role: Some("implementer"),
                    harness: Some("Codex"),
                    title: "Graph",
                    started_at: 100,
                    anchor: Some(anchor.clone()),
                })
                .unwrap();
            let context = HarnessStepContext {
                invocation_span: None,
                workflow_id: workflow,
                single_agent: false,
                activate: false,
                span: Some(span),
            };
            let mut step = HarnessStep {
                activity: None,
                session_id: None,
                kind: StepKind::Prompt,
                turn_id: None,
                tool_call_id: None,
                title: title.into(),
                detail: title.into(),
            };
            store
                .record_harness_step(context, &step, 101, &anchor)
                .unwrap();
            store
                .record_harness_step(context, &step, 101, &anchor)
                .unwrap();
            step.title = "Follow up".into();
            store
                .record_harness_step(context, &step, 102, &anchor)
                .unwrap();
            step.kind = StepKind::ToolStarted;
            step.title = "Read source file".into();
            store
                .record_harness_step(context, &step, 103, &anchor)
                .unwrap();
            spans.push((span, title));
        }
        drop(store);
        let store = Store::open(&path).unwrap();
        let page = store.workflow_trace(workflow, None, 10).unwrap();
        for (id, title) in spans {
            let span = page.spans.iter().find(|span| span.span_id == id).unwrap();
            assert_eq!(span.title, title);
            assert_eq!(span.status, TraceSpanStatus::Running);
        }
    }
}

#[derive(Clone, Copy)]
pub(crate) struct HarnessStepContext {
    pub workflow_id: WorkflowId,
    pub single_agent: bool,
    pub invocation_span: Option<TraceSpanId>,
    pub activate: bool,
    pub span: Option<TraceSpanId>,
}

impl Store {
    pub(crate) fn has_harness_workflow(&self, workflow_id: WorkflowId) -> Result<bool, StoreError> {
        Ok(self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM workflows WHERE id = ?1)",
            [sql_integer(workflow_id.0)?],
            |row| row.get(0),
        )?)
    }
    pub(crate) fn harness_span_is_running(&self, span: TraceSpanId) -> Result<bool, StoreError> {
        Ok(self.connection.query_row(
            "SELECT status = 'running' FROM trace_spans WHERE id = ?1",
            [sql_integer(span.0)?],
            |row| row.get(0),
        )?)
    }
    pub(crate) fn has_harness_turn(
        &self,
        terminal_id: TerminalId,
        turn_id: Option<&str>,
        invocation_span: Option<TraceSpanId>,
    ) -> Result<bool, StoreError> {
        Ok(self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM trace_spans WHERE terminal_id = ?1 AND (?2 IS NULL OR harness_turn_id = ?2) AND (?3 IS NULL OR id >= ?3))",
            params![sql_integer(terminal_id.value())?, turn_id, invocation_span.map(|id| sql_integer(id.0)).transpose()?], |row| row.get(0))?)
    }

    #[expect(
        clippy::too_many_lines,
        reason = "native prompt adoption and causal activity recording commit atomically"
    )]
    pub(crate) fn record_harness_step(
        &mut self,
        context: HarnessStepContext,
        step: &HarnessStep,
        observed_at: u64,
        anchor: &TraceAnchor,
    ) -> Result<Option<TraceSpanId>, StoreError> {
        let HarnessStepContext {
            workflow_id,
            single_agent,
            invocation_span,
            activate,
            span: assigned_span,
        } = context;
        let transaction = self
            .connection
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let correlated = super::activities::activity_span(&transaction, anchor.terminal_id, step)?
            .filter(|span| invocation_span.is_none_or(|start| span.0 >= start.0));
        let current: Option<TraceSpanId> = transaction
            .query_row(
                "SELECT s.id FROM trace_spans s JOIN trace_lanes l ON l.id = s.lane_id
             WHERE l.workflow_id = ?1 AND s.terminal_id = ?2
             AND (?3 IS NULL OR s.harness_turn_id = ?3)
             AND (?4 IS NULL OR s.id = ?4)
             AND (?5 OR s.started_at <= ?6) AND (?7 IS NULL OR s.id >= ?7) ORDER BY s.id DESC LIMIT 1",
                params![
                    sql_integer(workflow_id.0)?,
                    sql_integer(anchor.terminal_id.value())?,
                    if single_agent && correlated.is_none() {
                        step.turn_id.as_deref()
                    } else {
                        None
                    },
                    correlated
                        .or(assigned_span)
                        .map(|span| sql_integer(span.0))
                        .transpose()?,
                    single_agent || assigned_span.is_some(),
                    sql_integer(observed_at)?,
                    invocation_span.map(|span| sql_integer(span.0)).transpose()?,
                ],
                |row| Ok(TraceSpanId(super::unsigned_column(row, 0)?)),
            )
            .optional()?;
        let message = step.message();
        let span = if let Some(span) =
            invocation_span.filter(|_| activate && single_agent && step.kind == StepKind::Prompt)
        {
            transaction.execute(
                "UPDATE trace_spans SET title=?2, started_at=?3, harness_turn_id=?4, invocation_span=?1,
                    ended_at=CASE WHEN ended_at IS NULL THEN NULL ELSE MAX(ended_at,?3) END WHERE id=?1",
                params![
                    sql_integer(span.0)?,
                    step.title,
                    sql_integer(observed_at)?,
                    step.turn_id
                ],
            )?;
            span
        } else if single_agent
            && step.kind == StepKind::Prompt
            && current.as_ref().is_none_or(|_| step.turn_id.is_none())
        {
            start_prompt_span(
                &transaction,
                workflow_id,
                step,
                observed_at,
                anchor,
                invocation_span,
            )?
        } else if let Some(current) = current {
            current
        } else {
            // A missing prompt hook must not manufacture a successful response or process span.
            // Recording can recover at the next explicit prompt.
            return Ok(None);
        };
        transaction.execute(
            "UPDATE trace_spans SET invocation_span=COALESCE(invocation_span,?2),
                harness_session=COALESCE(harness_session,(SELECT harness_session FROM workflow_terminals WHERE terminal_id=?3)) WHERE id=?1",
            params![
                sql_integer(span.0)?,
                invocation_span.map(|id| sql_integer(id.0)).transpose()?,
                sql_integer(anchor.terminal_id.value())?
            ],
        )?;
        if !single_agent && step.kind == StepKind::Prompt && !step.title.trim().is_empty() {
            // An assignment retains its first native prompt as its title. Replayed hooks
            // and follow-up prompts must not rename the work already shown in history.
            transaction.execute(
                "UPDATE trace_spans SET title = ?2, title_from_prompt = 1
                 WHERE id = ?1 AND title_from_prompt = 0",
                params![sql_integer(span.0)?, step.title],
            )?;
        }
        if single_agent && step.kind == StepKind::Responded {
            // An async Stop can arrive after process exit. Its explicit completion distinguishes
            // a response from a process ending; cancellation remains stopped.
            transaction.execute(
                "UPDATE trace_spans SET status = 'exited', work_span = 1, ended_at = MAX(started_at, ?2)
                 WHERE id = ?1 AND (status IN ('running', 'exited') OR (status = 'stopped'
                 AND NOT EXISTS(SELECT 1 FROM trace_events WHERE terminal_id = ?3 AND kind = 'processStopped' AND (?4 IS NULL OR span_id >= ?4))))",
                params![sql_integer(span.0)?, sql_integer(observed_at)?, sql_integer(anchor.terminal_id.value())?, invocation_span.map(|span| sql_integer(span.0)).transpose()?],
            )?;
        }
        if single_agent && step.kind == StepKind::ToolStarted {
            // Another user's Stop hook may have requested continuation. Subsequent tool work
            // resumes that same prompt's response rather than creating a new unit of work.
            transaction.execute(
                "UPDATE trace_spans SET status = 'running', ended_at = NULL, work_span = 0
                 WHERE id = ?1 AND status = 'exited' AND work_span = 1
                 AND id = (SELECT id FROM trace_spans WHERE terminal_id = ?2 ORDER BY id DESC LIMIT 1)
                 AND NOT EXISTS(SELECT 1 FROM trace_events WHERE terminal_id = ?2
                    AND kind IN ('processStopped', 'processExited', 'processFailed') AND (?3 IS NULL OR span_id >= ?3))",
                params![sql_integer(span.0)?, sql_integer(anchor.terminal_id.value())?, invocation_span.map(|span| sql_integer(span.0)).transpose()?],
            )?;
        }
        super::activities::record_activity(
            &transaction,
            &self.payloads,
            span,
            step,
            observed_at,
            anchor,
        )?;
        insert_event(
            &transaction,
            workflow_id,
            span,
            observed_at,
            TraceEventKind::WorkflowEvent,
            &message,
            Some(anchor),
        )?;
        transaction.commit()?;
        Ok(Some(span))
    }

    /// Process lifecycle remains observable between turns and after explicit response completion.
    pub(crate) fn record_harness_process_ending(
        &mut self,
        workflow_id: WorkflowId,
        terminal_id: TerminalId,
        ending: &TraceEnding<'_>,
    ) -> Result<(), StoreError> {
        let transaction = self
            .connection
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        insert_process_ending(&transaction, workflow_id, terminal_id, ending)?;
        transaction.commit()?;
        Ok(())
    }
}

fn start_prompt_span(
    transaction: &rusqlite::Transaction<'_>,
    workflow_id: WorkflowId,
    step: &HarnessStep,
    observed_at: u64,
    anchor: &TraceAnchor,
    invocation_span: Option<TraceSpanId>,
) -> Result<TraceSpanId, StoreError> {
    let prior: Option<TraceSpanId> = transaction.query_row(
        "SELECT id FROM trace_spans WHERE terminal_id = ?1 AND status = 'running' ORDER BY id DESC LIMIT 1",
        [sql_integer(anchor.terminal_id.value())?], |row| Ok(TraceSpanId(super::unsigned_column(row, 0)?))).optional()?;
    if let Some(prior) = prior {
        // A second prompt can interrupt a response. Preserve the unfinished turn.
        super::traces::finish_span(
            transaction,
            prior,
            &TraceEnding {
                observed_at,
                status: TraceSpanStatus::Stopped,
                kind: TraceEventKind::WorkflowEvent,
                message: "Response interrupted by the next prompt.",
                anchor: Some(anchor.clone()),
            },
        )?;
    }
    let span = insert_span_record(
        transaction,
        &NewTraceSpan {
            workflow_id,
            lane_key: "agent",
            lane_name: "Agent",
            is_agent: true,
            role: Some("agent"),
            // The lane was created at launch with the selected harness's metadata.
            harness: None,
            title: &step.title,
            started_at: observed_at,
            anchor: Some(anchor.clone()),
        },
    )?;
    transaction.execute(
        "UPDATE trace_spans SET harness_turn_id = ?2, invocation_span=?3 WHERE id = ?1",
        params![
            sql_integer(span.0)?,
            step.turn_id,
            invocation_span.map(|id| sql_integer(id.0)).transpose()?
        ],
    )?;
    // A prompt hook can arrive after cancellation, exit, or workflow close. Replay the
    // authoritative process ending instead of leaving an impossible active response.
    transaction.execute(
        "UPDATE trace_spans SET ended_at = started_at, status = CASE
            WHEN EXISTS(SELECT 1 FROM trace_events WHERE terminal_id = ?2 AND kind = 'processStopped' AND (?3 IS NULL OR span_id >= ?3)) THEN 'stopped'
            WHEN EXISTS(SELECT 1 FROM trace_events WHERE terminal_id = ?2 AND kind = 'processFailed' AND (?3 IS NULL OR span_id >= ?3)) THEN 'failed'
            ELSE 'exited' END
         WHERE id = ?1 AND EXISTS(SELECT 1 FROM trace_events WHERE terminal_id = ?2
            AND kind IN ('processStopped', 'processExited', 'processFailed') AND (?3 IS NULL OR span_id >= ?3))",
        params![sql_integer(span.0)?, sql_integer(anchor.terminal_id.value())?, invocation_span.map(|span| sql_integer(span.0)).transpose()?],
    )?;
    Ok(span)
}

pub(super) fn insert_process_ending(
    transaction: &rusqlite::Transaction<'_>,
    workflow_id: WorkflowId,
    terminal_id: TerminalId,
    ending: &TraceEnding<'_>,
) -> Result<(), StoreError> {
    transaction.execute(
        "UPDATE trace_spans SET status=CASE WHEN work_span=1 AND ?2='exited' THEN 'stopped' ELSE ?2 END, ended_at=MAX(started_at,?3)
         WHERE terminal_id=?1 AND status='running'",
        params![
            sql_integer(terminal_id.value())?,
            super::traces::status_name(ending.status),
            sql_integer(ending.observed_at)?
        ],
    )?;
    transaction.execute(
        "UPDATE trace_activities SET status = 'interrupted' WHERE status = 'running'
         AND span_id IN (SELECT id FROM trace_spans WHERE terminal_id = ?1)",
        [sql_integer(terminal_id.value())?],
    )?;
    transaction.execute(
            "INSERT INTO trace_events (workflow_id, span_id, timestamp, kind, message, terminal_id, byte_offset, boundary_sizes)
             VALUES (?1, (SELECT s.id FROM trace_spans s JOIN trace_lanes l ON l.id = s.lane_id
             WHERE l.workflow_id = ?1 AND s.terminal_id = ?5 ORDER BY s.id DESC LIMIT 1), ?2, ?3, ?4, ?5, ?6, ?7)",
            params![sql_integer(workflow_id.0)?, sql_integer(ending.observed_at)?,
                super::traces::kind_name(ending.kind), ending.message, sql_integer(terminal_id.value())?,
                ending.anchor.as_ref().map(|a| sql_integer(a.byte_offset)).transpose()?,
                super::traces::encode_boundary_sizes(ending.anchor.as_ref())],
        )?;
    Ok(())
}
