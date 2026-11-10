use rusqlite::{OptionalExtension, params};

use super::{Store, StoreError, sql_integer};
use crate::TerminalId;

impl Store {
    pub(crate) fn remember_agent_options(
        &self,
        workflow: crate::WorkflowId,
        options: &crate::RoleLaunch,
    ) -> Result<(), StoreError> {
        let json = serde_json::to_string(options)
            .map_err(|error| StoreError::TracePayload(std::io::Error::other(error)))?;
        self.connection.execute(
            "UPDATE workflows SET agent_options=?2 WHERE id=?1",
            params![sql_integer(workflow.0)?, json],
        )?;
        Ok(())
    }
    pub(crate) fn agent_options(
        &self,
        workflow: crate::WorkflowId,
    ) -> Result<Option<crate::RoleLaunch>, StoreError> {
        let value: Option<String> = self
            .connection
            .query_row(
                "SELECT agent_options FROM workflows WHERE id=?1",
                [sql_integer(workflow.0)?],
                |row| row.get(0),
            )
            .optional()?
            .flatten();
        value
            .map(|json| {
                serde_json::from_str(&json)
                    .map_err(|error| StoreError::TracePayload(std::io::Error::other(error)))
            })
            .transpose()
    }

    pub(crate) fn remember_harness_session(
        &self,
        terminal: TerminalId,
        session: &str,
    ) -> Result<(), StoreError> {
        self.connection.execute(
            "UPDATE workflow_terminals SET harness_session = ?2 WHERE terminal_id = ?1",
            params![sql_integer(terminal.value())?, session],
        )?;
        Ok(())
    }

    pub(crate) fn bind_harness_session(
        &self,
        terminal: TerminalId,
        session: &str,
        invocation: Option<crate::TraceSpanId>,
    ) -> Result<(), StoreError> {
        self.remember_harness_session(terminal, session)?;
        if let Some(invocation) = invocation {
            self.connection.execute(
                "UPDATE trace_spans SET harness_session=COALESCE(harness_session,?2)
                WHERE terminal_id=?1 AND id>=?3",
                params![
                    sql_integer(terminal.value())?,
                    session,
                    sql_integer(invocation.0)?
                ],
            )?;
        }
        Ok(())
    }

    pub(crate) fn harness_session(
        &self,
        terminal: TerminalId,
    ) -> Result<Option<String>, StoreError> {
        Ok(self
            .connection
            .query_row(
                "SELECT harness_session FROM workflow_terminals WHERE terminal_id = ?1",
                [sql_integer(terminal.value())?],
                |row| row.get::<_, Option<String>>(0),
            )
            .optional()?
            .flatten())
    }
}
