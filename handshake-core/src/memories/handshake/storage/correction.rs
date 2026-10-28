//! Explicit replacement decisions retain history without deriving truth from a withdrawn claim.
use super::{Library, Project, c, save_projection_blobs, title};
use crate::memories::handshake::Error;
use rusqlite::{OptionalExtension, params};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::fmt::Write;

const CORRECTION: &str = "com.handshake.correction";

impl Library {
    pub fn correct(
        &self,
        project: &Project,
        id: &str,
        revision: &str,
        text: &str,
    ) -> Result<(), Error> {
        let text = text.trim();
        if !project.enabled {
            return Err(Error::Contract(
                "Enable project sharing before correcting a memory.".into(),
            ));
        }
        if text.is_empty() || text.len() > 2_000 {
            return Err(Error::Contract(
                "Write a correction between 1 and 2,000 UTF-8 bytes.".into(),
            ));
        }
        let mut bundle = self.load(project)?;
        let head = self.view_head(project, &bundle, id)?;
        if head["status"] != "active" || head["revision"]["id"] != revision {
            return Err(Error::Conflict);
        }
        if head["body"]["text"]
            .as_str()
            .is_some_and(|body| body.trim() == text)
        {
            return Err(Error::Contract(
                "The correction must replace the previous claim.".into(),
            ));
        }
        Self::append_archive(&mut bundle, &head)?;
        // Check the proposed state too: the replacement may itself derive from the old claim.
        let previous = self
            .db
            .query_row(
                "SELECT revision FROM views WHERE project=? AND group_key=?",
                params![project.id, c::hash(text.as_bytes())],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        if let Some(previous) = previous {
            let target = c::find(&bundle, &previous).ok_or(Error::Conflict)?;
            if super::withheld_lineage(&bundle, target)? {
                return Err(Error::Contract("This replacement is archived or depends on the old claim. Restore it explicitly or write a new correction.".into()));
            }
        }
        let source_id = c::id();
        let key = format!("correction:{source_id}");
        let snapshot = c::snapshot(&mut bundle, text);
        let path = project.root.join("blobs").join(c::hash(text.as_bytes()));
        save_projection_blobs(project, None, text)?;
        let sources = json!([{"source_id":key,"provider":"handshake","locator":path,"snapshot_ref":snapshot,"observed_at":c::now(),"source_created_at":null,"native_kind":"project"}]);
        let mut source = c::record(
            &source_id,
            None,
            &title(text),
            text,
            &project.id,
            &sources,
            &[],
            "verbatim",
        )?;
        let binding = json!({"source_key":key,"provider":"handshake","path":path,"payload_hash":c::hash(text.as_bytes())});
        source["extensions"]["com.twine.observation"] = binding.clone();
        // This is a replacement relationship, not a derivation from the old assertion.
        source["extensions"][CORRECTION] = json!({"replaces":c::reference(&head)});
        c::seal(&mut source)?;
        self.reserve(project, "source", &source_id, &binding)?;
        c::append(&mut bundle, source);
        // Both decisions become durable together before native publication. Metadata is rebuilt
        // from the sealed bundle on restart if a crash interrupts the following sync.
        Self::save(project, &mut bundle)?;
        self.recover_metadata(project, &bundle)
    }
}

pub(super) fn replacements<'a>(
    bundle: &'a Value,
    record: &'a Value,
) -> Result<Vec<&'a Value>, Error> {
    let mut pending = vec![record];
    let mut seen = HashSet::new();
    let mut targets = Vec::new();
    while let Some(record) = pending.pop() {
        if !seen.insert(record["revision"]["id"].as_str().ok_or(Error::Conflict)?) {
            continue;
        }
        let replacement = &record["extensions"][CORRECTION]["replaces"];
        if let Some(revision) = replacement["revision_id"].as_str() {
            let target = c::find(bundle, revision).ok_or(Error::Conflict)?;
            if c::reference(target) != *replacement {
                return Err(Error::Conflict);
            }
            targets.push(target);
            pending.push(target);
        }
        for input in record["derivation"]["inputs"]
            .as_array()
            .ok_or(Error::Conflict)?
        {
            pending.push(
                c::find(
                    bundle,
                    input["revision_id"].as_str().ok_or(Error::Conflict)?,
                )
                .ok_or(Error::Conflict)?,
            );
        }
    }
    targets.sort_by_key(|target| target["id"].as_str());
    targets.dedup_by_key(|target| target["id"].as_str());
    Ok(targets)
}

pub(super) fn startup_corrections(bundle: &Value, records: &[Value]) -> Result<String, Error> {
    let mut output = String::new();
    for record in records {
        let targets = replacements(bundle, record)?;
        if targets.is_empty() {
            continue;
        }
        let text = record["body"]["text"].as_str().ok_or(Error::Conflict)?;
        let entry = format!(
            "\nCurrent correction (replaces earlier startup guidance for {}):\n{text}\n",
            targets
                .iter()
                .map(|target| target["title"]
                    .as_str()
                    .unwrap_or_default()
                    .chars()
                    .take(120)
                    .collect::<String>())
                .collect::<Vec<_>>()
                .join(", ")
        );
        if output.len() + entry.len() > 6_000 {
            writeln!(output, "Additional corrections are in the current project memory index; check it before relying on older entries.").expect("String write");
            break;
        }
        output.push_str(&entry);
    }
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::memories::handshake::storage::tests::Fixture;
    use std::fs;

    #[test]
    fn correction_reaches_bounded_context_and_suppresses_old_claim_and_summary_across_restart() {
        let mut f = Fixture::new();
        fs::write(
            &f.input,
            "# Harness plan\nOrion CLI support is not planned.\n",
        )
        .unwrap();
        for index in 0..24 {
            fs::write(
                f.input.with_file_name(format!("noise-{index}.md")),
                format!("# Unrelated {index}\n{}", "Background note. ".repeat(140)),
            )
            .unwrap();
        }
        f.sync();
        let original = f
            .library
            .snapshot(&f.project)
            .unwrap()
            .records
            .into_iter()
            .find(|record| record.title == "Harness plan")
            .unwrap();
        fs::write(
            f.project.codex.join("memories/MEMORY.md"),
            "# Task Group: Old plan summary\nOrion CLI support is not planned.\n",
        )
        .unwrap();
        f.sync();
        let startup = f.project.claude.join("MEMORY.md");
        let old_startup = fs::read_to_string(&startup).unwrap()
            + "\n- [No Orion support](plan.md) — Orion CLI is not planned.\nPersonal formatting preference.\n";
        fs::write(&startup, &old_startup).unwrap();
        let claude = f.library.session_lease(&f.project, "claude_code").unwrap();
        let codex = f.library.session_lease(&f.project, "codex").unwrap();
        let replacement =
            "# Harness plan\nOrion CLI support is planned. The old assertion is incorrect.";
        f.library
            .correct(&f.project, &original.id, &original.revision, replacement)
            .unwrap();
        let result = f.library.sync(&f.project);
        assert!(
            matches!(result, Ok(()) | Err(Error::NativeActive)),
            "{result:?}"
        );
        assert_eq!(fs::read_to_string(&startup).unwrap(), old_startup);
        for provider in ["claude_code", "codex"] {
            let context = f
                .library
                .prompt_context_for(&f.project, provider, "Is Orion CLI support planned?")
                .unwrap();
            assert!(context.len() <= 8_192);
            assert!(context.contains(replacement));
            assert!(context.contains("Current correction replaces"));
            assert!(!context.contains("Orion CLI support is not planned"));
            assert!(context.contains("omitted"));
        }
        drop((claude, codex));
        f.sync();
        let updated = fs::read_to_string(&startup).unwrap();
        assert!(updated.contains("Current correction"));
        assert!(updated.find(replacement).unwrap() < updated.find("No Orion support").unwrap());
        assert!(updated.contains("Personal formatting preference."));
        let roots = f.library.roots.clone();
        let root = f
            .project
            .root
            .parent()
            .unwrap()
            .parent()
            .unwrap()
            .to_owned();
        drop(f.library);
        let mut reopened = Library::with_roots(&root, roots).unwrap();
        reopened.sync(&f.project).unwrap();
        reopened.sync(&f.project).unwrap();
        let snapshot = reopened.snapshot(&f.project).unwrap();
        assert!(
            snapshot
                .records
                .iter()
                .all(|record| !record.preview.contains("not planned"))
        );
        assert_eq!(snapshot.archived_records.len(), 1);
        assert!(
            reopened
                .read_archive(&f.project, &original.id)
                .unwrap()
                .text
                .contains("not planned")
        );
        assert!(
            reopened
                .prompt_context_for(&f.project, "claude_code", "Orion CLI")
                .unwrap()
                .contains(replacement)
        );
    }

    #[test]
    fn correction_does_not_implicitly_restore_an_archived_replacement() {
        let mut f = Fixture::new();
        let replacement = "# Replacement\nUse a new account.";
        fs::write(f.input.with_file_name("replacement.md"), replacement).unwrap();
        f.sync();
        let records = f.library.snapshot(&f.project).unwrap().records;
        let original = records.iter().find(|r| r.title == "Demo account").unwrap();
        let other = records.iter().find(|r| r.title == "Replacement").unwrap();
        f.library.withdraw(&f.project, &other.id).unwrap();
        f.sync();
        let before = fs::read(f.project.root.join("library.amis.json")).unwrap();
        assert!(
            f.library
                .correct(&f.project, &original.id, &original.revision, replacement)
                .is_err()
        );
        assert_eq!(
            fs::read(f.project.root.join("library.amis.json")).unwrap(),
            before
        );
        assert!(
            f.library
                .snapshot(&f.project)
                .unwrap()
                .records
                .iter()
                .any(|r| r.id == original.id)
        );
        f.library.restore(&f.project, &other.id).unwrap();
        f.sync();
        f.library
            .correct(&f.project, &original.id, &original.revision, replacement)
            .unwrap();
        f.sync();
        let context = f.library.prompt_context(&f.project, "claude_code").unwrap();
        assert!(context.contains(replacement));
        assert!(!context.contains("maple-417"));
    }

    #[test]
    fn native_edit_invalidates_the_selected_revision_before_correction() {
        let mut f = Fixture::new();
        f.sync();
        let original = &f.library.snapshot(&f.project).unwrap().records[0];
        fs::write(&f.input, "# Demo account\nA newer native change.\n").unwrap();
        f.sync();
        assert!(matches!(
            f.library.correct(
                &f.project,
                &original.id,
                &original.revision,
                "New correction"
            ),
            Err(Error::Conflict)
        ));
        assert!(
            f.library
                .prompt_context(&f.project, "claude_code")
                .unwrap()
                .contains("A newer native change.")
        );
    }

    #[test]
    fn correction_rejects_stale_empty_oversized_and_paused_requests_without_archiving() {
        let mut f = Fixture::new();
        f.sync();
        let original = &f.library.snapshot(&f.project).unwrap().records[0];
        for (revision, text) in [
            ("old", "A new fact"),
            (original.revision.as_str(), "  "),
            (original.revision.as_str(), &"é".repeat(1_001)),
        ] {
            assert!(
                f.library
                    .correct(&f.project, &original.id, revision, text)
                    .is_err()
            );
        }
        f.project.enabled = false;
        assert!(
            f.library
                .correct(&f.project, &original.id, &original.revision, "A new fact")
                .is_err()
        );
        assert!(
            f.library
                .snapshot(&f.project)
                .unwrap()
                .archived_records
                .is_empty()
        );
    }
}
