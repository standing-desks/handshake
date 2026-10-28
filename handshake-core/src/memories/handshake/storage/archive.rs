//! Project-wide archival retains immutable AMIS content and requires explicit restoration.
use super::save_projection_blobs;
use super::{Library, Project, c, native, withdrawn, withheld_lineage, write_json};
use crate::memories::handshake::ArchiveDetail;
use crate::memories::handshake::{Error, Summary};
use rusqlite::{OptionalExtension, params};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

impl Library {
    fn is_user_archive(bundle: &Value, head: &Value) -> Result<bool, Error> {
        if head["status"] != "withdrawn" {
            return Ok(false);
        }
        if head["withdrawal"]["reason"] == "user_request" {
            return Ok(true);
        }
        // Earlier versions placed the explicit decision on the view's direct source heads.
        for input in head["derivation"]["inputs"]
            .as_array()
            .ok_or(Error::Conflict)?
        {
            for reference in c::heads(bundle, input["memory_id"].as_str().ok_or(Error::Conflict)?) {
                let source = c::find(
                    bundle,
                    reference["revision_id"].as_str().ok_or(Error::Conflict)?,
                )
                .ok_or(Error::Conflict)?;
                if source["status"] == "withdrawn"
                    && source["withdrawal"]["reason"] == "user_request"
                {
                    return Ok(true);
                }
            }
        }
        Ok(false)
    }

    pub(super) fn retire_relocated_sources(
        &self,
        project: &Project,
        bundle: &mut Value,
        candidates: &[native::Candidate],
    ) -> Result<bool, Error> {
        let mut query = self
            .db
            .prepare("SELECT revision FROM sources WHERE project=?")?;
        let revisions = query
            .query_map([&project.id], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        let mut changed = false;
        for candidate in candidates {
            if candidate.key.starts_with("codex-task-group:")
                || candidate.text.contains("<!-- twine:")
                || candidate.text.contains("AMIS memory ")
            {
                continue;
            }
            let known: bool = self.db.query_row(
                "SELECT EXISTS(SELECT 1 FROM sources WHERE project=? AND source_key=?)",
                params![project.id, candidate.key],
                |row| row.get(0),
            )?;
            if known {
                continue;
            }
            for revision in &revisions {
                let source = c::find(bundle, revision).ok_or(Error::Conflict)?.clone();
                if source["status"] != "active"
                    || c::heads(bundle, source["id"].as_str().ok_or(Error::Conflict)?)
                        != vec![c::reference(&source)]
                {
                    continue;
                }
                let observation = &source["extensions"]["com.twine.observation"];
                let path = Path::new(observation["path"].as_str().ok_or(Error::Conflict)?);
                if observation["provider"] == candidate.provider
                    && source["body"]["text"] == candidate.text
                    && path != candidate.path
                    && path.parent().is_some_and(Path::is_dir)
                    && native::read(path)?.is_none()
                {
                    c::append(bundle, withdrawn(&source, "obsolete")?);
                    changed = true;
                }
            }
        }
        if changed {
            Self::save(project, bundle)?;
            self.recover_metadata(project, bundle)?;
        }
        Ok(changed)
    }

    pub fn withdraw(&self, project: &Project, id: &str) -> Result<(), Error> {
        let mut bundle = self.load(project)?;
        self.archive_record(project, &mut bundle, id)
    }

    fn archive_record(&self, project: &Project, bundle: &mut Value, id: &str) -> Result<(), Error> {
        let head = self.view_head(project, bundle, id)?;
        if head["status"] == "withdrawn" && head["withdrawal"]["reason"] == "user_request" {
            return Ok(());
        }
        if head["status"] != "active" {
            return Err(Error::Conflict);
        }
        Self::append_archive(bundle, &head)?;
        Self::save(project, bundle)?;
        self.recover_metadata(project, bundle)
    }

    pub(super) fn append_archive(bundle: &mut Value, head: &Value) -> Result<(), Error> {
        // The view carries the explicit suppression decision. Its source observations become
        // obsolete, allowing a filename to hold genuinely new content without restoring this view.
        for input in head["derivation"]["inputs"]
            .as_array()
            .ok_or(Error::Conflict)?
        {
            let source = c::find(
                bundle,
                input["revision_id"].as_str().ok_or(Error::Conflict)?,
            )
            .ok_or(Error::Conflict)?
            .clone();
            if c::heads(bundle, source["id"].as_str().ok_or(Error::Conflict)?)
                == vec![input.clone()]
            {
                c::append(bundle, withdrawn(&source, "obsolete")?);
            }
        }
        let mut archived = withdrawn(head, "user_request")?;
        archived["extensions"]["com.twine.archive"] = json!({"content":c::reference(head)});
        c::seal(&mut archived)?;
        c::append(bundle, archived);
        Ok(())
    }

    pub(super) fn view_head(
        &self,
        project: &Project,
        bundle: &Value,
        id: &str,
    ) -> Result<Value, Error> {
        let revision = self
            .db
            .query_row(
                "SELECT revision FROM views WHERE project=? AND memory=?",
                params![project.id, id],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .ok_or(Error::Conflict)?;
        Ok(c::find(bundle, &revision).ok_or(Error::Conflict)?.clone())
    }

    fn archived_body(bundle: &Value, head: &Value) -> Result<Value, Error> {
        if head["status"] != "withdrawn" || !withheld_lineage(bundle, head)? {
            return Err(Error::Conflict);
        }
        // Older withdrawals did not have the archive extension. Walk this identity's revision
        // parents, never unrelated derivation inputs, to retrieve its retained full content.
        let mut record = head;
        loop {
            if record["status"] == "active" {
                return Ok(record.clone());
            }
            let parents = record["revision"]["parents"]
                .as_array()
                .ok_or(Error::Conflict)?;
            if parents.len() != 1 {
                return Err(Error::Conflict);
            }
            record = c::find(
                bundle,
                parents[0]["revision_id"].as_str().ok_or(Error::Conflict)?,
            )
            .ok_or(Error::Conflict)?;
            if record["id"] != head["id"] {
                return Err(Error::Conflict);
            }
        }
    }

    pub fn read_archive(&self, project: &Project, id: &str) -> Result<ArchiveDetail, Error> {
        let bundle = self.load(project)?;
        let head = self.view_head(project, &bundle, id)?;
        let original = Self::archived_body(&bundle, &head)?;
        Ok(ArchiveDetail {
            id: id.into(),
            title: original["title"].as_str().unwrap_or_default().into(),
            text: original["body"]["text"]
                .as_str()
                .ok_or(Error::Conflict)?
                .into(),
        })
    }

    pub(super) fn archived_summaries(
        &self,
        project: &Project,
        bundle: &Value,
    ) -> Result<Vec<Summary>, Error> {
        let mut query = self
            .db
            .prepare("SELECT revision FROM views WHERE project=? AND active=0 ORDER BY memory")?;
        let mut records = Vec::new();
        for revision in query.query_map([&project.id], |row| row.get::<_, String>(0))? {
            let revision = revision?;
            let head = c::find(bundle, &revision).ok_or(Error::Conflict)?;
            // Derived views are suppressed with their originating archive, not separate restore
            // choices that could accidentally bypass the user's project-wide decision.
            if !Self::is_user_archive(bundle, head)? {
                continue;
            }
            let original = Self::archived_body(bundle, head)?;
            records.push(Summary {
                revision: head["revision"]["id"]
                    .as_str()
                    .ok_or(Error::Conflict)?
                    .into(),
                id: head["id"].as_str().ok_or(Error::Conflict)?.into(),
                title: original["title"].as_str().unwrap_or_default().into(),
                sources: original["derivation"]["inputs"]
                    .as_array()
                    .map_or(0, Vec::len),
                preview: original["body"]["text"]
                    .as_str()
                    .unwrap_or_default()
                    .chars()
                    .take(180)
                    .collect(),
            });
        }
        Ok(records)
    }

    pub fn restore(&self, project: &Project, id: &str) -> Result<(), Error> {
        if !project.enabled {
            return Err(Error::Contract(
                "Enable project sharing before restoring a memory.".into(),
            ));
        }
        let mut bundle = self.load(project)?;
        let head = self.view_head(project, &bundle, id)?;
        if !Self::is_user_archive(&bundle, &head)? {
            return Err(Error::Conflict);
        }
        let original = Self::archived_body(&bundle, &head)?;
        // Explicit restore also retires the older source-level suppression representation.
        // The immutable user_request revisions remain in history; nothing is rewritten.
        for input in original["derivation"]["inputs"]
            .as_array()
            .ok_or(Error::Conflict)?
        {
            for reference in c::heads(&bundle, input["memory_id"].as_str().ok_or(Error::Conflict)?)
            {
                let source = c::find(
                    &bundle,
                    reference["revision_id"].as_str().ok_or(Error::Conflict)?,
                )
                .ok_or(Error::Conflict)?
                .clone();
                if source["status"] == "withdrawn"
                    && source["withdrawal"]["reason"] == "user_request"
                {
                    c::append(&mut bundle, withdrawn(&source, "obsolete")?);
                }
            }
        }
        native::prepare(project, &self.roots)?;
        native::ensure_codex_memory_layout(&project.folder, &project.codex.join("config.toml"))?;
        // Commit the explicit decision in AMIS before exposing any native bytes. The retained
        // body becomes a canonical restoration source, with normal journaled publication below.
        let text = original["body"]["text"]
            .as_str()
            .ok_or(Error::Conflict)?
            .to_owned();
        let source_id = c::id();
        let key = format!("restore:{source_id}");
        let snapshot = c::snapshot(&mut bundle, &text);
        let path = project.root.join("blobs").join(c::hash(text.as_bytes()));
        save_projection_blobs(project, None, &text)?;
        let sources = json!([{"source_id":key,"provider":"handshake","locator":path,"snapshot_ref":snapshot,"observed_at":c::now(),"source_created_at":null,"native_kind":"project"}]);
        let mut source = c::record(
            &source_id,
            None,
            original["title"].as_str().unwrap_or_default(),
            &text,
            &project.id,
            &sources,
            &[c::reference(&original)],
            "parsed",
        )?;
        let binding = json!({"source_key":key,"provider":"handshake","path":path,"payload_hash":c::hash(text.as_bytes())});
        source["extensions"]["com.twine.observation"] = binding.clone();
        c::seal(&mut source)?;
        self.reserve(project, "source", &source_id, &binding)?;
        let mut restored = c::record(
            id,
            Some(&head),
            original["title"].as_str().unwrap_or_default(),
            &text,
            &project.id,
            &source["sources"],
            &[c::reference(&source)],
            "parsed",
        )?;
        restored["extensions"]["com.twine.consolidation"] =
            head["extensions"]["com.twine.consolidation"].clone();
        restored["extensions"]["com.twine.restoration"] = json!({"archive":c::reference(&head)});
        c::seal(&mut restored)?;
        c::append(&mut bundle, source);
        c::append(&mut bundle, restored.clone());
        if withheld_lineage(&bundle, &restored)? {
            return Err(Error::Contract("Restore this memory's archived source memories first. This memory remains in the archive.".into()));
        }
        Self::save(project, &mut bundle)?;
        self.recover_metadata(project, &bundle)?;
        self.recover_restoration(project, &bundle)
    }

    pub(super) fn recover_restoration(
        &self,
        project: &Project,
        bundle: &Value,
    ) -> Result<(), Error> {
        // Missing projections were intentionally removed. Explicit restore may create them again.
        let mut query = self
            .db
            .prepare("SELECT path,record_revision FROM projections WHERE project=? AND role IN ('topic','note')")?;
        let rows = query
            .query_map([&project.id], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        for (path, revision) in rows {
            if native::read(Path::new(&path))?.is_some() {
                continue;
            }
            let base = c::find(bundle, &revision).ok_or(Error::Conflict)?;
            let id = base["id"].as_str().ok_or(Error::Conflict)?;
            let mut current = self.view_head(project, bundle, id)?;
            let mut restored = false;
            while current["revision"]["id"] != revision && current["status"] == "active" {
                if !current["extensions"]["com.twine.restoration"].is_null() {
                    restored = true;
                    break;
                }
                let parents = current["revision"]["parents"]
                    .as_array()
                    .ok_or(Error::Conflict)?;
                if parents.len() != 1 {
                    break;
                }
                current = c::find(
                    bundle,
                    parents[0]["revision_id"].as_str().ok_or(Error::Conflict)?,
                )
                .ok_or(Error::Conflict)?
                .clone();
            }
            if restored {
                self.db.execute(
                    "DELETE FROM projections WHERE project=? AND path=?",
                    params![project.id, path],
                )?;
            }
        }
        Ok(())
    }

    pub(super) fn archive_missing(
        &self,
        project: &Project,
        bundle: &mut Value,
        records: &[Value],
        now: Duration,
    ) -> Result<bool, Error> {
        let state_path = project.root.join("native-absence.json");
        let previous = native::read(&state_path)?
            .map(|text| c::parse(text.as_bytes()))
            .transpose()?
            .unwrap_or_else(|| json!({}));
        let mut observed = json!({});
        let mut confirmed = HashSet::new();
        let mut pending = false;
        let now = u64::try_from(now.as_millis()).map_err(|_| Error::Conflict)?;
        for record in records {
            let id = record["id"].as_str().ok_or(Error::Conflict)?;
            let mut paths = Vec::new();
            for input in record["derivation"]["inputs"]
                .as_array()
                .ok_or(Error::Conflict)?
            {
                let source = c::find(
                    bundle,
                    input["revision_id"].as_str().ok_or(Error::Conflict)?,
                )
                .ok_or(Error::Conflict)?;
                let observation = &source["extensions"]["com.twine.observation"];
                if observation["provider"] == "handshake" {
                    continue;
                }
                let path = PathBuf::from(observation["path"].as_str().ok_or(Error::Conflict)?);
                paths.push(path);
            }
            let mut query = self.db.prepare("SELECT path,record_revision FROM projections WHERE project=? AND role IN ('topic','note')")?;
            for row in query.query_map([&project.id], |row| {
                Ok((
                    PathBuf::from(row.get::<_, String>(0)?),
                    row.get::<_, String>(1)?,
                ))
            })? {
                let (path, revision) = row?;
                let sibling = path
                    .file_stem()
                    .and_then(|name| name.to_str())
                    .is_some_and(|stem| stem.contains(".revision-"));
                if c::find(bundle, &revision).is_some_and(|base| base["id"] == id)
                    && (!sibling || record["revision"]["id"] == revision)
                {
                    paths.push(path);
                }
            }
            for path in paths {
                native::safe_path(&path)?;
                match fs::symlink_metadata(&path) {
                    Ok(_) => continue,
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                    Err(error) => return Err(error.into()),
                }
                // Loss of a whole profile or directory is not evidence of a forget request.
                if !path.parent().is_some_and(Path::is_dir) {
                    continue;
                }
                let key = c::hash(format!("{id}:{}", path.display()).as_bytes());
                let first = previous[&key].as_u64().unwrap_or(now);
                observed[&key] = json!(first);
                // Two observations separated by two seconds distinguish routine atomic file
                // replacement from a stable deletion. This is a filesystem guard, not a quota cap.
                if now.saturating_sub(first) >= 2000 {
                    confirmed.insert(id.to_owned());
                } else {
                    pending = true;
                }
            }
        }
        write_json(&state_path, &observed)?;
        let changed = !confirmed.is_empty();
        for id in confirmed {
            self.archive_record(project, bundle, &id)?;
        }
        if pending && !changed {
            return Err(Error::Contract("A native memory disappeared. Confirming removal before archiving it across the project.".into()));
        }
        Ok(changed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixture {
        _temp: tempfile::TempDir,
        library: Library,
        project: Project,
        source: PathBuf,
        text: String,
    }
    impl Fixture {
        fn new(provider: &str) -> Self {
            let temp = tempfile::tempdir().unwrap();
            let root = temp.path().canonicalize().unwrap();
            let folder = root.join("shop");
            fs::create_dir(&folder).unwrap();
            let roots = native::Roots {
                claude: root.join("claude"),
                codex: root.join("codex"),
            };
            let mut library =
                Library::with_roots(&root.join("memories.revision-test"), roots).unwrap();
            let project = library.register(&folder).unwrap();
            let source = if provider == "claude_code" {
                project.claude.join("checkout.md")
            } else {
                project
                    .codex
                    .join("memories/extensions/ad_hoc/notes/checkout.md")
            };
            let text = format!(
                "# Checkout rule\n\n{}\nUse idempotency key retail-193 for checkout.\n",
                "Full retained content. ".repeat(30)
            );
            fs::write(&source, &text).unwrap();
            library.sync(&project).unwrap();
            Self {
                _temp: temp,
                library,
                project,
                source,
                text,
            }
        }
        fn id(&self) -> String {
            self.library.snapshot(&self.project).unwrap().records[0]
                .id
                .clone()
        }
        fn confirm_missing(&mut self) {
            assert!(
                matches!(self.library.sync(&self.project), Err(Error::Contract(message)) if message.contains("Confirming removal"))
            );
            let mut bundle = self.library.load(&self.project).unwrap();
            let records = self
                .library
                .snapshot(&self.project)
                .unwrap()
                .records
                .into_iter()
                .map(|summary| {
                    self.library
                        .view_head(&self.project, &bundle, &summary.id)
                        .unwrap()
                })
                .collect::<Vec<_>>();
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                + Duration::from_secs(3);
            assert!(
                self.library
                    .archive_missing(&self.project, &mut bundle, &records, now)
                    .unwrap()
            );
            match self.library.sync(&self.project) {
                Ok(()) | Err(Error::NativeActive) => {}
                result => panic!("{result:?}"),
            }
        }
    }

    #[test]
    fn native_deletion_archives_project_wide_and_restore_retains_full_history() {
        for provider in ["claude_code", "codex"] {
            let mut f = Fixture::new(provider);
            let id = f.id();
            let before = f.library.load(&f.project).unwrap()["records"]
                .as_array()
                .unwrap()
                .clone();
            let claude_lease = f.library.session_lease(&f.project, "claude_code").unwrap();
            let codex_lease = f.library.session_lease(&f.project, "codex").unwrap();
            fs::remove_file(&f.source).unwrap();
            f.confirm_missing();
            assert!(!f.source.exists());
            let snapshot = f.library.snapshot(&f.project).unwrap();
            assert!(snapshot.records.is_empty());
            assert_eq!(snapshot.archived_records.len(), 1);
            assert_eq!(
                f.library.read_archive(&f.project, &id).unwrap().text,
                f.text
            );
            for provider in ["claude_code", "codex"] {
                assert!(
                    !f.library
                        .prompt_context(&f.project, provider)
                        .unwrap()
                        .contains("retail-193")
                );
            }
            f.library.db.execute("DELETE FROM views", []).unwrap();
            f.library.db.execute("DELETE FROM sources", []).unwrap();
            assert_eq!(
                f.library.snapshot(&f.project).unwrap().archived_records[0].id,
                id
            );
            f.library.restore(&f.project, &id).unwrap();
            assert!(matches!(
                f.library.sync(&f.project),
                Ok(()) | Err(Error::NativeActive)
            ));
            for provider in ["claude_code", "codex"] {
                assert!(
                    f.library
                        .prompt_context(&f.project, provider)
                        .unwrap()
                        .contains("retail-193")
                );
            }
            assert!(
                f.library
                    .snapshot(&f.project)
                    .unwrap()
                    .archived_records
                    .is_empty()
            );
            let after = f.library.load(&f.project).unwrap();
            for original in before {
                assert!(after["records"].as_array().unwrap().contains(&original));
            }
            drop((claude_lease, codex_lease));
            f.library.sync(&f.project).unwrap();
        }
    }

    #[test]
    fn removal_of_delivered_copy_archives_but_index_removal_does_not() {
        let mut f = Fixture::new("claude_code");
        let id = f.id();
        let delivered = f
            .project
            .codex
            .join(format!("memories/extensions/ad_hoc/notes/twine-{id}.md"));
        fs::remove_file(delivered).unwrap();
        f.confirm_missing();
        assert!(f.library.snapshot(&f.project).unwrap().records.is_empty());
        assert!(
            !fs::read_to_string(&f.source)
                .unwrap()
                .contains("retail-193")
        );
        assert_eq!(
            f.library.read_archive(&f.project, &id).unwrap().text,
            f.text
        );
    }

    #[test]
    fn temporary_absence_and_raw_file_rename_do_not_archive() {
        let mut f = Fixture::new("claude_code");
        fs::remove_file(&f.source).unwrap();
        assert!(f.library.sync(&f.project).is_err());
        fs::write(&f.source, &f.text).unwrap();
        f.library.sync(&f.project).unwrap();
        fs::rename(&f.source, f.source.with_file_name("renamed.md")).unwrap();
        f.library.sync(&f.project).unwrap();
        f.library.sync(&f.project).unwrap();
        assert!(!f.source.exists());
        assert!(
            f.library
                .snapshot(&f.project)
                .unwrap()
                .archived_records
                .is_empty()
        );
        assert_eq!(f.library.snapshot(&f.project).unwrap().records.len(), 1);
    }

    #[test]
    fn deleting_one_known_duplicate_archives_the_shared_claim() {
        let mut f = Fixture::new("claude_code");
        let duplicate = f.source.with_file_name("duplicate.md");
        fs::write(&duplicate, &f.text).unwrap();
        f.library.sync(&f.project).unwrap();
        assert_eq!(
            f.library.snapshot(&f.project).unwrap().records[0].sources,
            2
        );
        fs::remove_file(&f.source).unwrap();
        f.confirm_missing();
        assert!(f.library.snapshot(&f.project).unwrap().records.is_empty());
        assert!(
            !fs::read_to_string(duplicate)
                .unwrap()
                .contains("retail-193")
        );
    }

    #[test]
    fn deleting_stable_export_during_live_revision_archives_and_retires_siblings() {
        let mut f = Fixture::new("claude_code");
        let id = f.id();
        let notes = f.project.codex.join("memories/extensions/ad_hoc/notes");
        let stable = notes.join(format!("twine-{id}.md"));
        let old = fs::read(&stable).unwrap();
        let lease = f.library.session_lease(&f.project, "codex").unwrap();
        fs::write(f.source.with_file_name("second-source.md"), &f.text).unwrap();
        f.library.sync(&f.project).unwrap();
        assert_eq!(fs::read(&stable).unwrap(), old);
        assert!(fs::read_dir(&notes).unwrap().any(|entry| {
            entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .contains(".revision-")
        }));
        fs::remove_file(stable).unwrap();
        f.confirm_missing();
        assert!(f.library.snapshot(&f.project).unwrap().records.is_empty());
        assert!(
            !f.library
                .prompt_context(&f.project, "codex")
                .unwrap()
                .contains("retail-193")
        );
        drop(lease);
        f.library.sync(&f.project).unwrap();
        for entry in fs::read_dir(notes).unwrap() {
            assert!(
                !fs::read_to_string(entry.unwrap().path())
                    .unwrap()
                    .contains("retail-193")
            );
        }
    }

    #[test]
    fn filename_reuse_and_restore_preserve_unrelated_new_content() {
        let mut f = Fixture::new("codex");
        let id = f.id();
        f.library.withdraw(&f.project, &id).unwrap();
        f.library.sync(&f.project).unwrap();
        fs::write(
            &f.source,
            "# New checkout rule\nUse a separate shipping queue.\n",
        )
        .unwrap();
        f.library.sync(&f.project).unwrap();
        assert_eq!(f.library.snapshot(&f.project).unwrap().records.len(), 1);
        f.library.restore(&f.project, &id).unwrap();
        f.library.sync(&f.project).unwrap();
        assert_eq!(f.library.snapshot(&f.project).unwrap().records.len(), 2);
        assert!(
            fs::read_to_string(&f.source)
                .unwrap()
                .contains("separate shipping queue")
        );
        assert!(
            f.library
                .prompt_context(&f.project, "codex")
                .unwrap()
                .contains("retail-193")
        );
    }

    #[test]
    fn repurposed_managed_export_preserves_unrelated_bytes_and_holds_sharing() {
        let mut f = Fixture::new("claude_code");
        let id = f.id();
        f.library.withdraw(&f.project, &id).unwrap();
        f.library.sync(&f.project).unwrap();
        let path = f
            .project
            .codex
            .join(format!("memories/extensions/ad_hoc/notes/twine-{id}.md"));
        fs::write(&path, "Unrelated shipping memory must not be overwritten.").unwrap();
        for _ in 0..2 {
            assert!(matches!(f.library.sync(&f.project), Err(Error::Conflict)));
            assert_eq!(
                fs::read_to_string(&path).unwrap(),
                "Unrelated shipping memory must not be overwritten."
            );
        }
    }

    #[test]
    fn missing_profile_holds_sharing_without_archiving_its_contents() {
        let mut f = Fixture::new("claude_code");
        fs::remove_dir_all(&f.project.claude).unwrap();
        assert!(f.library.register(&f.project.folder).is_err());
        assert!(
            matches!(f.library.sync(&f.project), Err(Error::Contract(message)) if message.contains("profile is missing"))
        );
        assert!(!f.project.claude.exists());
        assert_eq!(f.library.snapshot(&f.project).unwrap().records.len(), 1);
        assert!(
            f.library
                .snapshot(&f.project)
                .unwrap()
                .archived_records
                .is_empty()
        );
    }

    #[test]
    fn restoration_is_committed_before_native_delivery_and_recovers_stale_bindings() {
        let mut f = Fixture::new("claude_code");
        let id = f.id();
        let target = f
            .project
            .codex
            .join(format!("memories/extensions/ad_hoc/notes/twine-{id}.md"));
        let old: (String,Option<String>,String) = f.library.db.query_row(
            "SELECT record_revision,source_memory,output_hash FROM projections WHERE project=? AND path=?",
            params![f.project.id,target.to_string_lossy()], |row| Ok((row.get(0)?,row.get(1)?,row.get(2)?))).unwrap();
        fs::remove_file(&target).unwrap();
        f.confirm_missing();
        f.library.restore(&f.project, &id).unwrap();
        assert!(
            !target.exists(),
            "Restore commits AMIS before ordinary publication delivers bytes"
        );
        // Model a crash after the canonical commit but before its SQLite cleanup.
        f.library
            .db
            .execute(
                "INSERT OR REPLACE INTO projections VALUES(?,?,?,?,?,?,?)",
                params![
                    f.project.id,
                    target.to_string_lossy(),
                    old.0,
                    old.1,
                    old.2,
                    "codex",
                    "note"
                ],
            )
            .unwrap();
        f.library.db.execute("DELETE FROM views", []).unwrap();
        f.library.db.execute("DELETE FROM sources", []).unwrap();
        f.library.sync(&f.project).unwrap();
        assert!(fs::read_to_string(target).unwrap().contains("retail-193"));
        assert!(
            f.library
                .snapshot(&f.project)
                .unwrap()
                .archived_records
                .is_empty()
        );
    }

    #[test]
    fn generated_marker_text_and_legacy_withdrawals_can_be_restored() {
        let mut f = Fixture::new("codex");
        let recap = f.project.codex.join("memories/MEMORY.md");
        fs::write(&recap, "# Task Group: Delivery recap\nAMIS memory reference\n<!-- twine:example -->\nRemember the violet lane.").unwrap();
        f.library.sync(&f.project).unwrap();
        let id = f
            .library
            .snapshot(&f.project)
            .unwrap()
            .records
            .into_iter()
            .find(|record| record.preview.contains("Delivery recap"))
            .unwrap()
            .id;
        let mut bundle = f.library.load(&f.project).unwrap();
        let view = f.library.view_head(&f.project, &bundle, &id).unwrap();
        for input in view["derivation"]["inputs"].as_array().unwrap() {
            let source = c::find(&bundle, input["revision_id"].as_str().unwrap())
                .unwrap()
                .clone();
            c::append(&mut bundle, withdrawn(&source, "user_request").unwrap());
        }
        Library::save(&f.project, &mut bundle).unwrap();
        f.library.sync(&f.project).unwrap();
        assert!(
            f.library
                .snapshot(&f.project)
                .unwrap()
                .archived_records
                .iter()
                .any(|record| record.id == id)
        );
        assert!(
            f.library
                .read_archive(&f.project, &id)
                .unwrap()
                .text
                .contains("<!-- twine:example -->")
        );
        f.library.restore(&f.project, &id).unwrap();
        f.library.sync(&f.project).unwrap();
        assert!(
            f.library
                .prompt_context(&f.project, "claude_code")
                .unwrap()
                .contains("violet lane")
        );
        assert!(
            f.library
                .prompt_context(&f.project, "codex")
                .unwrap()
                .contains("violet lane")
        );
    }

    #[test]
    fn restoring_a_derived_archive_with_an_archived_ancestor_preserves_both_archives() {
        let mut f = Fixture::new("claude_code");
        let ancestor = f.id();
        fs::write(
            f.project.codex.join("memories/MEMORY.md"),
            "# Task Group: Recap\nCheckout uses retail-193.",
        )
        .unwrap();
        f.library.sync(&f.project).unwrap();
        let derived = f
            .library
            .snapshot(&f.project)
            .unwrap()
            .records
            .into_iter()
            .find(|record| record.id != ancestor)
            .unwrap()
            .id;
        f.library.withdraw(&f.project, &derived).unwrap();
        f.library.withdraw(&f.project, &ancestor).unwrap();
        f.library.sync(&f.project).unwrap();
        let before = fs::read(f.project.root.join("library.amis.json")).unwrap();
        assert!(
            matches!(f.library.restore(&f.project, &derived), Err(Error::Contract(message)) if message.contains("archived source memories first"))
        );
        assert_eq!(
            fs::read(f.project.root.join("library.amis.json")).unwrap(),
            before
        );
        assert_eq!(
            f.library
                .snapshot(&f.project)
                .unwrap()
                .archived_records
                .len(),
            2
        );
        f.library.restore(&f.project, &ancestor).unwrap();
        f.library.sync(&f.project).unwrap();
        f.library.restore(&f.project, &derived).unwrap();
        f.library.sync(&f.project).unwrap();
        assert!(
            f.library
                .snapshot(&f.project)
                .unwrap()
                .archived_records
                .is_empty()
        );
        assert!(
            f.library
                .prompt_context(&f.project, "claude_code")
                .unwrap()
                .contains("Recap")
        );
    }
}
