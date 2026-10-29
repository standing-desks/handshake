//! Recording ownership includes closed workflows and every durable trace anchor.
use std::collections::HashSet;

use rusqlite::{Connection, params};

use super::{Store, StoreError, sql_integer, unsigned_column};
use crate::{SessionId, TerminalId, TraceAnchor};

impl Store {
    pub(crate) fn referenced_transcripts(&self) -> Result<HashSet<TerminalId>, StoreError> {
        let transaction = self.connection.unchecked_transaction()?;
        let ids = transcript_ids(&transaction, None)?;
        transaction.commit()?;
        Ok(ids)
    }
}

pub(super) fn transcript_ids(
    connection: &Connection,
    session: Option<SessionId>,
) -> Result<HashSet<TerminalId>, StoreError> {
    let session = session.map(|id| sql_integer(id.0)).transpose()?;
    let mut statement = connection.prepare(
        "WITH owners AS (
            SELECT w.id FROM workflows w JOIN sessions s ON s.id = w.session_id
            WHERE (?1 IS NULL OR s.id = ?1)
        )
        SELECT terminal_id FROM workflow_terminals WHERE workflow_id IN owners
        UNION SELECT terminal_id FROM trace_spans
            WHERE lane_id IN (SELECT id FROM trace_lanes WHERE workflow_id IN owners)
        UNION SELECT terminal_id FROM trace_events WHERE workflow_id IN owners",
    )?;
    let mut ids = HashSet::new();
    for id in statement.query_map(params![session], |row| {
        row.get::<_, Option<i64>>(0)?
            .map(|_| unsigned_column(row, 0))
            .transpose()
    })? {
        if let Some(id) = id?
            && id > 0
        {
            ids.insert(TerminalId::from_value(id));
        }
    }
    let mut statement = connection.prepare(
        "SELECT a.anchor FROM trace_activities a
         JOIN trace_spans t ON t.id = a.span_id JOIN trace_lanes l ON l.id = t.lane_id
         JOIN workflows w ON w.id = l.workflow_id JOIN sessions s ON s.id = w.session_id
         WHERE a.anchor IS NOT NULL AND (?1 IS NULL OR s.id = ?1)",
    )?;
    for anchor in statement.query_map(params![session], |row| row.get::<_, String>(0))? {
        // An unreadable anchor makes ownership uncertain; callers must skip pruning.
        let anchor: TraceAnchor =
            serde_json::from_str(&anchor?).map_err(|_| StoreError::InvalidIdentifier)?;
        if anchor.terminal_id.value() > 0 {
            ids.insert(anchor.terminal_id);
        }
    }
    Ok(ids)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ownership_includes_closed_workflows_other_folders_and_all_anchor_sources() {
        let mut store = Store::open_in_memory().unwrap();
        store.execute_test_sql("INSERT INTO sessions(id,folder,name,started_at) VALUES
            (1,'/first','First',1),(2,'/other','Other',1);
            INSERT INTO workflows(id,session_id,name,kind,closed_at,archived) VALUES
            (1,1,'Closed','terminal',100,1),(2,2,'Other','terminal',NULL,0);
            INSERT INTO workflow_terminals(terminal_id,workflow_id) VALUES(1,1),(2,2);
            INSERT INTO trace_lanes(id,workflow_id,lane_key,name,is_agent) VALUES(1,1,'terminal','Terminal',0);
            INSERT INTO trace_spans(id,lane_id,title,started_at,status,terminal_id) VALUES(1,1,'Step',1,'exited',3);
            INSERT INTO trace_events(workflow_id,span_id,timestamp,kind,message,terminal_id,byte_offset)
            VALUES(1,1,1,'processExited','Exited',4,0);
            INSERT INTO trace_activities(span_id,source_id,kind,title,status,input,output,anchor)
            VALUES(1,'tool','tool','Tool','completed','','','{\"terminal_id\":5,\"byte_offset\":0,\"boundary_sizes\":null}');");
        let ids = |values: &[u64]| {
            values
                .iter()
                .copied()
                .map(TerminalId::from_value)
                .collect::<HashSet<_>>()
        };
        assert_eq!(
            store.referenced_transcripts().unwrap(),
            ids(&[1, 2, 3, 4, 5])
        );
        let removed = store
            .delete_session(std::path::Path::new("/first"), SessionId(1), None)
            .unwrap();
        assert_eq!(removed, ids(&[1, 3, 4, 5]));
        assert_eq!(store.referenced_transcripts().unwrap(), ids(&[2]));
    }

    #[test]
    fn an_unreadable_anchor_prevents_cleanup_but_not_session_deletion() {
        let mut store = Store::open_in_memory().unwrap();
        store.execute_test_sql("INSERT INTO sessions(id,folder,name,started_at) VALUES(1,'/folder','Session',1);
            INSERT INTO workflows(id,session_id,name,kind) VALUES(1,1,'Terminal','terminal');
            INSERT INTO trace_lanes(id,workflow_id,lane_key,name,is_agent) VALUES(1,1,'terminal','Terminal',0);
            INSERT INTO trace_spans(id,lane_id,title,started_at,status,terminal_id) VALUES(1,1,'Step',1,'exited',1);
            INSERT INTO trace_activities(span_id,source_id,kind,title,status,input,output,anchor)
            VALUES(1,'tool','tool','Tool','completed','','','unreadable');");
        assert!(store.referenced_transcripts().is_err());
        assert!(
            store
                .delete_session(std::path::Path::new("/folder"), SessionId(1), None)
                .unwrap()
                .is_empty()
        );
        assert!(store.referenced_transcripts().unwrap().is_empty());
    }
}
