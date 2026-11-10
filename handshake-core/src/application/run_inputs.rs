//! Review notifications share a writer with user input, without submitting an unfinished draft.

use std::collections::VecDeque;

use crate::terminal::{TerminalError, TerminalId, TerminalManager};

use crate::terminal::UserInputDraft as Draft;

#[derive(Default)]
pub(super) struct AgentInput {
    draft: Draft,
    feedback: VecDeque<String>,
    /// A draft keeps the connection boundary under which its first bytes were typed.
    pub(super) routing_revision: Option<u64>,
    /// Captured before queued Swift input waits on older writes or a connection change.
    pub(super) prepared_revision: Option<u64>,
    deferred_handoffs: VecDeque<(RoutingStamp, String)>,
    last_submission: Option<(u64, std::time::Instant)>,
}

#[derive(Clone, Copy, PartialEq)]
pub(super) struct RoutingStamp {
    pub(super) revision: u64,
    pub(super) generation: u64,
}

impl AgentInput {
    pub(super) fn will_submit(&self, bytes: &[u8]) -> bool {
        self.draft.clone().observe(bytes).is_some()
    }

    pub(super) fn notification_will_submit(&self) -> bool {
        !self.draft.pending
    }

    pub(super) fn clear_feedback(&mut self) {
        self.feedback.clear();
        self.deferred_handoffs.clear();
    }

    pub(super) fn take_deferred_handoffs(
        &mut self,
        prompt_started: std::time::Instant,
    ) -> Vec<(RoutingStamp, String)> {
        if self.draft.pending
            || self
                .last_submission
                .is_some_and(|(_, submitted)| prompt_started < submitted)
        {
            return Vec::new();
        }
        self.deferred_handoffs.drain(..).collect()
    }

    /// Attach routing instructions to the next submitted message without starting a turn.
    pub(super) fn defer_notification(&mut self, message: String) {
        if self.feedback.len() == 16 {
            self.feedback.pop_front();
        }
        self.feedback.push_back(message);
    }

    pub(super) fn write(
        &mut self,
        terminals: &TerminalManager,
        terminal: TerminalId,
        bytes: &[u8],
        routing: Option<RoutingStamp>,
    ) -> Result<bool, TerminalError> {
        let routing_revision = routing.map(|stamp| stamp.revision);
        let mut draft = self.draft.clone();
        let boundary = draft.observe(bytes);
        let submits = boundary.is_some();
        let intent = self
            .routing_revision
            .or(self.prepared_revision)
            .or(routing_revision);
        if intent == routing_revision {
            while let Some((stamp, message)) = self.deferred_handoffs.pop_front() {
                if Some(stamp) == routing {
                    self.defer_notification(message);
                }
            }
        }
        let submitted_at = std::time::Instant::now();
        if !self.feedback.is_empty() && submits {
            let feedback = self
                .feedback
                .iter()
                .map(String::as_str)
                .collect::<Vec<_>>()
                .join("\n\n");
            let boundary = boundary.expect("submission has a boundary")
                - usize::from(bytes.ends_with(b"\r\n"));
            let feedback = format!(
                "\x1b[200~\n\nReview feedback received while you were typing:\n{feedback}\n\nContinue with the user's message above.\x1b[201~"
            );
            terminals.enqueue_input_parts(
                terminal,
                &[
                    (&bytes[..boundary], None),
                    (feedback.as_bytes(), routing_revision),
                    (&bytes[boundary..], None),
                ],
                false,
            )?;
        } else {
            terminals.write_input(terminal, bytes)?;
        }
        self.draft = draft;
        self.routing_revision = if self.draft.pending {
            self.routing_revision
                .or(self.prepared_revision.take())
                .or(routing_revision)
        } else {
            self.prepared_revision = None;
            None
        };
        if submits {
            self.feedback.clear();
            self.last_submission = intent.map(|revision| (revision, submitted_at));
        }
        Ok(submits)
    }

    pub(super) fn notify(
        &mut self,
        terminals: &TerminalManager,
        terminal: TerminalId,
        message: &str,
        stamp: RoutingStamp,
        turn_finished: bool,
    ) -> Result<bool, TerminalError> {
        let message: String = message
            .chars()
            .filter(|c| !c.is_control() || matches!(c, '\n' | '\t'))
            .collect();
        if self
            .routing_revision
            .is_some_and(|intent| intent != stamp.revision)
            || (!turn_finished
                && self
                    .last_submission
                    .is_some_and(|(intent, _)| intent != stamp.revision))
        {
            if self.deferred_handoffs.len() == 16 {
                self.deferred_handoffs.pop_front();
            }
            self.deferred_handoffs.push_back((stamp, message));
            Ok(false)
        } else if self.draft.pending {
            // Retain feedback when a subsequent assignment's command update is also deferred.
            self.defer_notification(message);
            Ok(false)
        } else {
            let submitted_at = std::time::Instant::now();
            terminals.enqueue_input(
                terminal,
                format!("\x1b[200~{message}\x1b[201~\r").as_bytes(),
                Some(stamp.revision),
                false,
            )?;
            self.feedback.clear();
            self.last_submission = Some((stamp.revision, submitted_at));
            Ok(true)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agents_disconnected_clears_feedback_without_discarding_the_user_draft() {
        let mut input = AgentInput::default();
        input.draft.observe(b"My unfinished draft");
        input.feedback.push_back("Review feedback".into());
        input.clear_feedback();
        assert!(input.feedback.is_empty());
        assert!(input.draft.pending);
        assert_eq!(input.draft.observe(b"\r"), Some(0));
    }

    #[test]
    fn multiline_paste_and_split_markers_keep_the_draft_pending() {
        let mut draft = Draft::default();
        draft.observe(b"\x1b[20");
        draft.observe(b"0~first\nsecond\n");
        assert!(draft.pending && draft.pasting);
        draft.observe(b"\x1b[201");
        draft.observe(b"~");
        assert!(draft.pending && !draft.pasting);
        draft.observe(b"\r");
        assert!(!draft.pending);
        draft.observe(b"next draft");
        assert!(draft.pending);
        draft.observe(&[3]);
        assert!(!draft.pending);
    }

    #[test]
    fn enhanced_enter_submits_only_unmodified_press_or_repeat() {
        for encoded in [
            b"\x1b[13u".as_slice(),
            b"\x1b[13;1u",
            b"\x1b[13;1:2u",
            b"\x1b[13;65u",
        ] {
            let mut draft = Draft::default();
            draft.observe(b"User draft");
            assert_eq!(draft.observe(encoded), Some(0));
            assert!(!draft.pending);
        }
        for encoded in [b"\x1b[13;2u".as_slice(), b"\x1b[13;1:3u", b"\x1b[13;5u"] {
            let mut draft = Draft::default();
            draft.observe(b"User draft");
            assert_eq!(draft.observe(encoded), None);
            assert!(draft.pending);
        }
        let mut draft = Draft::default();
        draft.observe(b"\x1b[200~");
        assert_eq!(draft.observe(b"\x1b[13u"), None);
        assert!(draft.pending);
    }
}
