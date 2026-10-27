//! Durable receiver bindings, immutable AMIS history, local policy and recoverable native plans.
use super::{Error, Snapshot, Summary, contract as c, native};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashSet};
use std::fmt::Write as FmtWrite;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};

#[derive(Clone)]
pub(super) struct Project {
    pub id: String,
    pub folder: PathBuf,
    pub root: PathBuf,
    pub claude: PathBuf,
    pub codex: PathBuf,
    pub enabled: bool,
}
pub(super) struct Library {
    root: PathBuf,
    db: Connection,
    pub roots: native::Roots,
    _lock: File,
}

impl Library {
    pub fn open(root: &Path) -> Result<Self, Error> {
        Self::with_roots(root, native::Roots::live())
    }
    pub fn with_roots(root: &Path, roots: native::Roots) -> Result<Self, Error> {
        if !root.is_absolute() {
            return Err(Error::InvalidFolder);
        }
        fs::create_dir_all(root)?;
        if fs::symlink_metadata(root)?.file_type().is_symlink() {
            return Err(Error::Conflict);
        }
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(root.join("receiver.lock"))?;
        // SAFETY: flock borrows a live owned file descriptor. All Handshake writers share this lock.
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(Error::Busy);
        }
        let db = Connection::open(root.join("bindings.sqlite"))?;
        let version: i64 = db.pragma_query_value(None, "user_version", |r| r.get(0))?;
        if version > 1 {
            return Err(Error::Contract(
                "Unsupported Handshake memory storage version".into(),
            ));
        }
        if version == 0 {
            db.execute_batch("BEGIN IMMEDIATE;
            CREATE TABLE projects(id TEXT PRIMARY KEY, folder TEXT UNIQUE NOT NULL, enabled INTEGER NOT NULL, last_sync TEXT, error TEXT);
            CREATE TABLE sources(project TEXT NOT NULL, source_key TEXT NOT NULL, memory TEXT NOT NULL, revision TEXT NOT NULL, payload_hash TEXT NOT NULL, provider TEXT NOT NULL, path TEXT NOT NULL, PRIMARY KEY(project,source_key));
            CREATE TABLE views(project TEXT NOT NULL, group_key TEXT NOT NULL, memory TEXT NOT NULL, revision TEXT NOT NULL, active INTEGER NOT NULL, PRIMARY KEY(project,group_key));
            CREATE TABLE projections(project TEXT NOT NULL, path TEXT NOT NULL, record_revision TEXT NOT NULL, source_memory TEXT, output_hash TEXT NOT NULL, provider TEXT NOT NULL, role TEXT NOT NULL, PRIMARY KEY(project,path));
            PRAGMA user_version=1; COMMIT;")?;
        }
        Ok(Self {
            root: root.to_owned(),
            db,
            roots,
            _lock: lock,
        })
    }
    fn project(&self, id: String, folder: PathBuf, enabled: bool) -> Project {
        Project {
            id: id.clone(),
            folder,
            root: self.root.join("projects").join(&id),
            claude: self
                .roots
                .claude
                .join("projects")
                .join(format!("twine-{id}"))
                .join("memory"),
            codex: self.root.join("projects").join(id).join("native/codex"),
            enabled,
        }
    }
    pub fn register(&mut self, folder: &Path) -> Result<Project, Error> {
        if !folder.is_absolute() || !folder.is_dir() {
            return Err(Error::InvalidFolder);
        }
        let folder = folder.canonicalize()?;
        let stored = self
            .db
            .query_row(
                "SELECT id,enabled FROM projects WHERE folder=?",
                [folder.to_string_lossy().as_ref()],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, bool>(1)?)),
            )
            .optional()?;
        let recovered = if stored.is_none() {
            let mut found = None;
            if let Ok(entries) = fs::read_dir(self.root.join("projects")) {
                for entry in entries {
                    let path = entry?.path().join("project.json");
                    if let Some(bytes) = native::read(&path)? {
                        let value = c::parse(bytes.as_bytes())?;
                        if value["folder"].as_str() == Some(folder.to_string_lossy().as_ref()) {
                            let id = value["id"].as_str().ok_or(Error::Conflict)?;
                            if entry_id(&path) != Some(id) {
                                return Err(Error::Conflict);
                            }
                            if found
                                .replace((
                                    id.to_owned(),
                                    value["enabled"].as_bool().ok_or(Error::Conflict)?,
                                ))
                                .is_some()
                            {
                                return Err(Error::Conflict);
                            }
                        }
                    }
                }
            }
            found
        } else {
            None
        };
        let (id, enabled) = stored.or(recovered).unwrap_or_else(|| (c::id(), true));
        self.db.execute(
            "INSERT OR IGNORE INTO projects(id,folder,enabled) VALUES(?,?,?)",
            params![id, folder.to_string_lossy(), enabled],
        )?;
        let project = self.project(id, folder, enabled);
        fs::create_dir_all(&project.root)?;
        if !project.root.starts_with(&self.root) {
            return Err(Error::Conflict);
        }
        write_json(
            &project.root.join("project.json"),
            &json!({"id":project.id,"folder":project.folder,"enabled":enabled}),
        )?;
        native::prepare(&project, &self.roots)?;
        Ok(project)
    }
    pub fn session_lease(&self, project: &Project, provider: &str) -> Result<fs::File, Error> {
        if !project.root.starts_with(&self.root) {
            return Err(Error::Conflict);
        }
        native::lease(project, provider, false)
    }
    pub fn projects(&self) -> Result<Vec<Project>, Error> {
        let mut q = self.db.prepare("SELECT id,folder,enabled FROM projects")?;
        Ok(q.query_map([], |r| {
            Ok((r.get(0)?, PathBuf::from(r.get::<_, String>(1)?), r.get(2)?))
        })?
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .map(|(id, p, e)| self.project(id, p, e))
        .collect())
    }
    fn reserve(
        &self,
        project: &Project,
        kind: &str,
        id: &str,
        binding: &Value,
    ) -> Result<(), Error> {
        if !project.root.starts_with(&self.root) {
            return Err(Error::Conflict);
        }
        write_json(
            &project
                .root
                .join("bindings")
                .join(format!("{kind}-{id}.json")),
            binding,
        )
    }
    fn recover_metadata(&self, project: &Project, bundle: &Value) -> Result<(), Error> {
        // Portable extensions are evidence, never receiver authorization. Only locally reserved
        // identities may reconstruct bindings after a crash or metadata loss.
        let mut identities = HashSet::new();
        for r in bundle["records"].as_array().into_iter().flatten() {
            let id = r["id"].as_str().ok_or(Error::Conflict)?;
            if !identities.insert(id) {
                continue;
            }
            let heads = c::heads(bundle, id);
            if heads.len() != 1 {
                return Err(Error::Contract(
                    "Concurrent AMIS heads require review.".into(),
                ));
            }
            let head = c::find(
                bundle,
                heads[0]["revision_id"].as_str().ok_or(Error::Conflict)?,
            )
            .ok_or(Error::Conflict)?;
            let source = project
                .root
                .join("bindings")
                .join(format!("source-{id}.json"));
            let view = project
                .root
                .join("bindings")
                .join(format!("view-{id}.json"));
            if source.exists() {
                let binding = c::parse(&fs::read(source)?)?;
                let observation = &head["extensions"]["com.twine.observation"];
                for key in ["source_key", "provider", "path"] {
                    if observation[key] != binding[key] {
                        return Err(Error::Conflict);
                    }
                }
                self.db.execute("INSERT INTO sources VALUES(?,?,?,?,?,?,?) ON CONFLICT(project,source_key) DO UPDATE SET revision=excluded.revision,payload_hash=excluded.payload_hash",params![project.id,binding["source_key"].as_str(),id,head["revision"]["id"].as_str(),observation["payload_hash"].as_str(),binding["provider"].as_str(),binding["path"].as_str()])?;
                let edit = &binding["accepted_edit"];
                if let Some(revision) = edit["revision"].as_str()
                    && c::find(bundle, revision).is_some()
                {
                    self.db.execute("UPDATE projections SET output_hash=? WHERE project=? AND path=? AND record_revision=?",params![edit["hash"].as_str(),project.id,edit["path"].as_str(),edit["base"].as_str()])?;
                }
            } else if view.exists() {
                let binding = c::parse(&fs::read(view)?)?;
                if head["extensions"]["com.twine.consolidation"]["group_key"]
                    != binding["group_key"]
                {
                    return Err(Error::Conflict);
                }
                self.db.execute("INSERT INTO views VALUES(?,?,?,?,?) ON CONFLICT(project,group_key) DO UPDATE SET revision=excluded.revision,active=excluded.active",params![project.id,binding["group_key"].as_str(),id,head["revision"]["id"].as_str(),head["status"]=="active"])?;
            } else {
                return Err(Error::Contract(
                    "AMIS identity has no local receiver binding; review is required.".into(),
                ));
            }
        }
        Ok(())
    }
    pub fn set_enabled(&self, project: &Project, enabled: bool) -> Result<(), Error> {
        self.db.execute(
            "UPDATE projects SET enabled=?,error=NULL WHERE id=?",
            params![enabled, project.id],
        )?;
        write_json(
            &project.root.join("project.json"),
            &json!({"id":project.id,"folder":project.folder,"enabled":enabled}),
        )
    }
    fn load(&self, project: &Project) -> Result<Value, Error> {
        let path = project.root.join("library.amis.json");
        let value = match native::read(&path)? {
            Some(text) => c::parse(text.as_bytes())?,
            None => c::bundle()?,
        };
        c::validate_bundle(&value, &project.id)?;
        self.recover_metadata(project, &value)?;
        Ok(value)
    }
    fn save(project: &Project, bundle: &mut Value) -> Result<(), Error> {
        bundle["exported_at"] = json!(c::now());
        c::seal(bundle)?;
        c::validate_bundle(bundle, &project.id)?;
        write_json(&project.root.join("library.amis.json"), bundle)
    }
    pub fn sync(&mut self, project: &Project) -> Result<(), Error> {
        self.sync_cancellable(project, &|| true)
    }
    pub fn sync_cancellable(
        &mut self,
        project: &Project,
        active: &dyn Fn() -> bool,
    ) -> Result<(), Error> {
        let enabled: bool = self.db.query_row(
            "SELECT enabled FROM projects WHERE id=?",
            [&project.id],
            |r| r.get(0),
        )?;
        if !enabled {
            return Ok(());
        }
        let result = self.cycle(project, active);
        self.db.execute(
            "UPDATE projects SET last_sync=?,error=? WHERE id=?",
            params![
                c::now(),
                result.as_ref().err().map(ToString::to_string),
                project.id
            ],
        )?;
        result
    }
    fn cycle(&mut self, project: &Project, active: &dyn Fn() -> bool) -> Result<(), Error> {
        if !active() {
            return Err(Error::Busy);
        }
        native::prepare(project, &self.roots)?;
        let mut bundle = self.load(project)?;
        self.recover(project, &bundle, false)?;
        let candidates = native::capture(project, &self.roots)?;
        let mut changed = false;
        for candidate in candidates {
            if !active() {
                return Err(Error::Busy);
            }
            changed |= self.accept(project, &mut bundle, &candidate)?;
        }
        if changed || !project.root.join("library.amis.json").exists() {
            Self::save(project, &mut bundle)?;
        }
        let records = self.consolidate(project, &mut bundle)?;
        Self::save(project, &mut bundle)?;
        let mut held = deferred(self.recover(project, &bundle, true))?;
        for record in &records {
            if !active() {
                return Err(Error::Busy);
            }
            held |= deferred(self.publish_record(project, &bundle, record))?;
        }
        let mut q = self
            .db
            .prepare("SELECT revision FROM views WHERE project=? AND active=0")?;
        for revision in q.query_map([&project.id], |r| r.get::<_, String>(0))? {
            if !active() {
                return Err(Error::Busy);
            }
            let revision = revision?;
            let record = c::find(&bundle, &revision).ok_or(Error::Conflict)?;
            held |= deferred(self.publish_record(project, &bundle, record))?;
        }
        if let Some(record) = records
            .first()
            .or_else(|| bundle["records"].as_array().and_then(|r| r.last()))
        {
            held |= deferred(self.publish_index(project, &bundle, &records, record))?;
        }
        self.retire_live_projections(project, &bundle)?;
        if held {
            return Err(Error::NativeActive);
        }
        Ok(())
    }
    #[expect(
        clippy::too_many_lines,
        reason = "Accept and durable lineage commit ordering stay together"
    )]
    fn accept(
        &self,
        project: &Project,
        bundle: &mut Value,
        candidate: &native::Candidate,
    ) -> Result<bool, Error> {
        let digest = c::hash(candidate.text.as_bytes());
        let projection=self.db.query_row("SELECT output_hash,record_revision,source_memory,role FROM projections WHERE project=? AND path=?",params![project.id,candidate.path.to_string_lossy()],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,Option<String>>(2)?,r.get::<_,String>(3)?))).optional()?;
        let generated = candidate.key.starts_with("codex-task-group:");
        if !generated
            && projection.is_none()
            && (candidate.text.contains("AMIS memory ") || candidate.text.contains("<!-- twine:"))
        {
            return Err(Error::Contract(
                "An exported native memory has no verified local ownership binding.".into(),
            ));
        }
        let mut text = candidate.text.clone();
        let mut edit_memory = None;
        let mut edit_base = None;
        if let Some((previous, revision, source_memory, role)) = projection {
            if previous == digest {
                return Ok(false);
            }
            if role == "index" {
                return Err(Error::Conflict);
            }
            let base = c::find(bundle, &revision)
                .ok_or_else(|| Error::Contract("Missing delivery base".into()))?;
            if base["status"] != "active" {
                return Err(Error::Conflict);
            }
            let inputs = base["derivation"]["inputs"]
                .as_array()
                .ok_or(Error::Conflict)?;
            if inputs.len() != 1 && role != "source" {
                return Err(Error::Conflict);
            }
            edit_base = Some(c::reference(base));
            edit_memory =
                source_memory.or_else(|| inputs[0]["memory_id"].as_str().map(str::to_owned));
            if role != "source" {
                text = text
                    .split_once("<!-- twine:body -->\n")
                    .ok_or(Error::Conflict)?
                    .1
                    .to_owned();
            }
            let current = self.db.query_row(
                "SELECT revision FROM sources WHERE project=? AND memory=?",
                params![project.id, edit_memory.as_deref()],
                |r| r.get::<_, String>(0),
            )?;
            let input = inputs
                .iter()
                .find(|v| v["memory_id"].as_str() == edit_memory.as_deref())
                .ok_or(Error::Conflict)?;
            if input["revision_id"] != current {
                return Err(Error::Conflict);
            }
        }
        let existing = if let Some(memory) = edit_memory.as_deref() {
            self.db.query_row("SELECT memory,revision,payload_hash,source_key FROM sources WHERE project=? AND memory=?",params![project.id,memory],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,r.get::<_,String>(3)?))).optional()?
        } else {
            self.db.query_row("SELECT memory,revision,payload_hash,source_key FROM sources WHERE project=? AND source_key=?",params![project.id,candidate.key],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,r.get::<_,String>(3)?))).optional()?
        };
        if edit_memory.is_none() && existing.as_ref().is_some_and(|v| v.2 == digest) {
            return Ok(false);
        }
        let parent = existing
            .as_ref()
            .and_then(|v| c::find(bundle, &v.1))
            .cloned();
        if parent.as_ref().is_some_and(|p| p["status"] == "withdrawn") {
            return Err(Error::Contract(
                "A withdrawn identity requires explicit restoration.".into(),
            ));
        }
        let memory = existing.as_ref().map_or_else(c::id, |v| v.0.clone());
        let source_key = existing
            .as_ref()
            .map_or_else(|| candidate.key.clone(), |v| v.3.clone());
        let snapshot = c::snapshot(bundle, &candidate.text);
        let title = title(&text);
        let sources = json!([{"source_id":candidate.key,"provider":candidate.provider,"locator":candidate.path,"snapshot_ref":snapshot,"observed_at":c::now(),"source_created_at":null,"native_kind":"project"}]);
        let derivation_inputs = if let Some(base) = edit_base {
            vec![base]
        } else if generated {
            let mut query=self.db.prepare("SELECT DISTINCT record_revision FROM projections WHERE project=? AND provider='codex' AND role='note'")?;
            query
                .query_map([&project.id], |r| r.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?
                .iter()
                .filter_map(|rev| c::find(bundle, rev))
                .map(c::reference)
                .collect()
        } else {
            Vec::new()
        };
        let mut record = c::record(
            &memory,
            parent.as_ref(),
            &title,
            &text,
            &project.id,
            &sources,
            &derivation_inputs,
            if edit_memory.is_some() || generated {
                "parsed"
            } else {
                "verbatim"
            },
        )?;
        let old_origin = self
            .db
            .query_row(
                "SELECT provider,path FROM sources WHERE project=? AND source_key=?",
                params![project.id, source_key],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
            )
            .optional()?;
        let cache_hash = if edit_memory.is_some() {
            existing
                .as_ref()
                .map_or_else(|| digest.clone(), |v| v.2.clone())
        } else {
            digest.clone()
        };
        record["extensions"]["com.twine.observation"] = json!({"source_key":source_key,"provider":old_origin.as_ref().map_or(candidate.provider,|v|v.0.as_str()),"path":old_origin.as_ref().map_or_else(||candidate.path.to_string_lossy().into_owned(),|v|v.1.clone()),"payload_hash":cache_hash});
        c::seal(&mut record)?;
        let revision = record["revision"]["id"]
            .as_str()
            .expect("Record revision")
            .to_owned();
        let mut binding = record["extensions"]["com.twine.observation"].clone();
        if edit_memory.is_some() {
            let base = self.db.query_row(
                "SELECT record_revision FROM projections WHERE project=? AND path=?",
                params![project.id, candidate.path.to_string_lossy()],
                |r| r.get::<_, String>(0),
            )?;
            binding["accepted_edit"] =
                json!({"revision":revision,"path":candidate.path,"hash":digest,"base":base});
        }
        self.reserve(project, "source", &memory, &binding)?;
        c::append(bundle, record);
        Self::save(project, bundle)?;
        let saved_hash = if edit_memory.is_some() {
            existing
                .as_ref()
                .map_or_else(|| digest.clone(), |v| v.2.clone())
        } else {
            digest.clone()
        };
        self.db.execute("INSERT INTO sources(project,source_key,memory,revision,payload_hash,provider,path) VALUES(?,?,?,?,?,?,?) ON CONFLICT(project,source_key) DO UPDATE SET revision=excluded.revision,payload_hash=excluded.payload_hash",params![project.id,source_key,memory,revision,saved_hash,candidate.provider,candidate.path.to_string_lossy()])?;
        if edit_memory.is_some() {
            self.db.execute(
                "UPDATE projections SET output_hash=? WHERE project=? AND path=?",
                params![digest, project.id, candidate.path.to_string_lossy()],
            )?;
        }
        Ok(true)
    }
    fn consolidate(&self, project: &Project, bundle: &mut Value) -> Result<Vec<Value>, Error> {
        let mut q = self
            .db
            .prepare("SELECT revision FROM sources WHERE project=? ORDER BY source_key")?;
        let revisions = q
            .query_map([&project.id], |r| r.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        let mut groups: BTreeMap<String, Vec<Value>> = BTreeMap::new();
        for revision in revisions {
            let record = c::find(bundle, &revision)
                .ok_or_else(|| Error::Contract("Missing source head".into()))?;
            if record["status"] == "active" {
                ensure_auto_validity(record)?;
                groups
                    .entry(
                        record["body"]["text"]
                            .as_str()
                            .unwrap_or_default()
                            .to_owned(),
                    )
                    .or_default()
                    .push(record.clone());
            }
        }
        let mut active = Vec::new();
        let mut group_keys = Vec::new();
        for (text, inputs) in groups {
            let group = c::hash(text.as_bytes());
            group_keys.push(group.clone());
            let previous = self
                .db
                .query_row(
                    "SELECT memory,revision FROM views WHERE project=? AND group_key=?",
                    params![project.id, group],
                    |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
                )
                .optional()?;
            let parent = previous.as_ref().and_then(|p| c::find(bundle, &p.1));
            let refs: Vec<Value> = inputs.iter().map(c::reference).collect();
            if let Some(p) = parent
                && p["status"] == "active"
                && p["derivation"]["inputs"] == json!(refs)
            {
                active.push(p.clone());
                continue;
            }
            let memory = previous.as_ref().map_or_else(c::id, |p| p.0.clone());
            let sources: Vec<Value> = inputs
                .iter()
                .flat_map(|r| r["sources"].as_array().cloned().unwrap_or_default())
                .collect();
            let mut record = c::record(
                &memory,
                parent,
                &title(&text),
                &text,
                &project.id,
                &json!(sources),
                &refs,
                "parsed",
            )?;
            record["extensions"]["com.twine.consolidation"] = json!({"group_key":group});
            c::seal(&mut record)?;
            let revision = record["revision"]["id"]
                .as_str()
                .expect("View revision")
                .to_owned();
            self.reserve(project, "view", &memory, &json!({"group_key":group}))?;
            c::append(bundle, record.clone());
            Self::save(project, bundle)?;
            self.db.execute("INSERT INTO views VALUES(?,?,?,?,1) ON CONFLICT(project,group_key) DO UPDATE SET revision=excluded.revision,active=1",params![project.id,group,memory,revision])?;
            active.push(record);
        }
        let mut q = self
            .db
            .prepare("SELECT group_key,revision FROM views WHERE project=? AND active=1")?;
        let old = q
            .query_map([&project.id], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        for (group, revision) in old {
            if group_keys.contains(&group) {
                continue;
            }
            let base = c::find(bundle, &revision).ok_or(Error::Conflict)?.clone();
            let withdrawn = withdrawn(&base, "obsolete")?;
            c::append(bundle, withdrawn.clone());
            Self::save(project, bundle)?;
            self.db.execute(
                "UPDATE views SET revision=?,active=0 WHERE project=? AND group_key=?",
                params![withdrawn["revision"]["id"].as_str(), project.id, group],
            )?;
        }
        Ok(active)
    }
    fn publish_record(
        &self,
        project: &Project,
        bundle: &Value,
        record: &Value,
    ) -> Result<(), Error> {
        let id = record["id"].as_str().ok_or(Error::Conflict)?;
        let active = record["status"] == "active";
        let body = projection_body(record, project, "codex")?;
        let claude = projection_body(record, project, "claude_code")?;
        let mut held = deferred(self.publish(
            project,
            bundle,
            record,
            "claude_code",
            &project.claude.join(format!("twine-shared-{id}.md")),
            &claude,
            "topic",
        ))?;
        let codex_generated = record["sources"].as_array().is_some_and(|sources| {
            !sources.is_empty()
                && sources.iter().all(|source| {
                    source["provider"] == "codex"
                        && source["source_id"]
                            .as_str()
                            .is_some_and(|key| key.starts_with("codex-task-group:"))
                })
        });
        if !codex_generated || !active {
            held |= deferred(
                self.publish(
                    project,
                    bundle,
                    record,
                    "codex",
                    &project
                        .codex
                        .join("memories/extensions/ad_hoc/notes")
                        .join(format!("twine-{id}.md")),
                    &body,
                    "note",
                ),
            )?;
        }
        held |= deferred(self.publish_sources(project, bundle, record, &body, active))?;
        if held {
            Err(Error::NativeActive)
        } else {
            Ok(())
        }
    }
    fn publish_sources(
        &self,
        project: &Project,
        bundle: &Value,
        record: &Value,
        body: &str,
        active: bool,
    ) -> Result<(), Error> {
        let mut held = false;
        if let Some(inputs) = record["derivation"]["inputs"].as_array() {
            for input in inputs {
                let source_memory = input["memory_id"].as_str().unwrap_or_default();
                let source = self.db.query_row(
                    "SELECT provider,path FROM sources WHERE project=? AND memory=?",
                    params![project.id, source_memory],
                    |r| {
                        Ok((
                            r.get::<_, String>(0)?,
                            PathBuf::from(r.get::<_, String>(1)?),
                        ))
                    },
                )?;
                if !active {
                    let source_revision = self.db.query_row(
                        "SELECT revision FROM sources WHERE project=? AND memory=?",
                        params![project.id, source_memory],
                        |r| r.get::<_, String>(0),
                    )?;
                    if c::find(bundle, &source_revision).is_none_or(|r| r["status"] != "withdrawn")
                    {
                        continue;
                    }
                }
                if (source.0 == "claude_code" && source.1.starts_with(&project.claude))
                    || (source.0 == "codex"
                        && source
                            .1
                            .starts_with(project.codex.join("memories/extensions/ad_hoc/notes")))
                {
                    held |= deferred(self.publish(
                        project,
                        bundle,
                        record,
                        &source.0,
                        &source.1,
                        if active {
                            record["body"]["text"].as_str().unwrap_or_default()
                        } else {
                            body
                        },
                        "source",
                    ))?;
                }
            }
        }
        if held {
            Err(Error::NativeActive)
        } else {
            Ok(())
        }
    }
    fn publish_index(
        &self,
        project: &Project,
        bundle: &Value,
        records: &[Value],
        basis: &Value,
    ) -> Result<(), Error> {
        let name = format!("twine-index-{}.md", project.id);
        let mut index = format!(
            "# Handshake project memories\n\nProject: {}\n\n",
            project.folder.display()
        );
        for r in records {
            writeln!(
                index,
                "- [{}](twine-shared-{}.md)",
                r["title"]
                    .as_str()
                    .unwrap_or("Memory")
                    .replace(['[', ']', '\n'], " "),
                r["id"].as_str().unwrap_or_default()
            )
            .expect("String write");
        }
        self.publish(
            project,
            bundle,
            basis,
            "claude_code",
            &project.claude.join(&name),
            &index,
            "index",
        )?;
        let target = project.claude.join("MEMORY.md");
        let current = native::read(&target)?.unwrap_or_default();
        let begin = format!("<!-- twine:{}:begin -->", project.id);
        let end = format!("<!-- twine:{}:end -->", project.id);
        let rest = if let Some((before, after)) = current.split_once(&begin) {
            let (_, after) = after.split_once(&end).ok_or(Error::Conflict)?;
            format!("{before}{}", after.trim_start_matches('\n'))
        } else {
            current
        };
        let combined =
            format!("{begin}\n- [Handshake current project memories]({name})\n{end}\n\n{rest}");
        // The native startup pointer can wait until idle: live prompts read the
        // current verified topics directly and must not report stalled sharing.
        match self.publish(
            project,
            bundle,
            basis,
            "claude_code",
            &target,
            &combined,
            "index",
        ) {
            Ok(()) | Err(Error::NativeActive) => Ok(()),
            Err(error) => Err(error),
        }
    }

    /// Once the native writer is idle and stable outputs are current, retire every
    /// immutable live sibling so a native loader cannot resurrect its old claim.
    fn retire_live_projections(&self, project: &Project, bundle: &Value) -> Result<(), Error> {
        let mut query = self.db.prepare("SELECT path,provider,record_revision FROM projections WHERE project=? AND role IN ('topic','note','index') AND path LIKE '%.revision-%'")?;
        let rows = query
            .query_map([&project.id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        for (name, provider, revision) in rows {
            let path = PathBuf::from(&name);
            let stem = path
                .file_stem()
                .and_then(|name| name.to_str())
                .ok_or(Error::Conflict)?;
            let Some((base, _)) = stem.split_once(".revision-") else {
                continue;
            };
            let stable = path.with_file_name(format!("{base}.md"));
            let idle = native::lease(project, &provider, true)
                .and_then(|lease| native::quiescent(project, &provider).map(|()| lease));
            match idle {
                Ok(lease) => drop(lease),
                Err(Error::NativeActive) => continue,
                Err(error) => return Err(error),
            }
            let stable_binding = self.db.query_row("SELECT output_hash,record_revision FROM projections WHERE project=? AND path=?",params![project.id,stable.to_string_lossy()],|row|Ok((row.get::<_,String>(0)?,row.get::<_,String>(1)?))).optional()?;
            let Some((hash, stable_revision)) = stable_binding else {
                continue;
            };
            let original = c::find(bundle, &revision).ok_or(Error::Conflict)?;
            let current = c::find(bundle, &stable_revision).ok_or(Error::Conflict)?;
            if (!base.starts_with("twine-index-") && original["id"] != current["id"])
                || c::heads(bundle, current["id"].as_str().ok_or(Error::Conflict)?)
                    != vec![c::reference(current)]
                || native::read(&stable)?
                    .as_deref()
                    .map(|text| c::hash(text.as_bytes()))
                    .as_deref()
                    != Some(hash.as_str())
            {
                continue;
            }
            let retired = format!(
                "Superseded native memory snapshot. Its previous claim is not current. The current project memory is represented at {}.\n<!-- twine:superseded -->\n",
                stable.display()
            );
            match self.publish(
                project, bundle, current, &provider, &path, &retired, "retired",
            ) {
                Ok(()) | Err(Error::NativeActive) => {}
                Err(error) => return Err(error),
            }
        }
        Ok(())
    }
    #[expect(
        clippy::too_many_arguments,
        reason = "Publication explicitly binds project, record and native target"
    )]
    fn publish(
        &self,
        project: &Project,
        bundle: &Value,
        record: &Value,
        provider: &str,
        path: &Path,
        after: &str,
        role: &str,
    ) -> Result<(), Error> {
        native::safe_path(path)?;
        let before = native::read(path)?;
        let before_hash = before.as_deref().map(|v| c::hash(v.as_bytes()));
        let after_hash = c::hash(after.as_bytes());
        let owned = self
            .db
            .query_row(
                "SELECT output_hash,record_revision FROM projections WHERE project=? AND path=?",
                params![project.id, path.to_string_lossy()],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
            )
            .optional()?;
        if owned.as_ref().is_some_and(|v| {
            Some(v.0.as_str()) == before_hash.as_deref()
                && v.0 == after_hash
                && record["revision"]["id"] == v.1
        }) {
            return Ok(());
        }
        if let Some((hash, _)) = &owned {
            if Some(hash.as_str()) != before_hash.as_deref()
                && !(role == "index"
                    && path.file_name().is_some_and(|name| name == "MEMORY.md")
                    && same_index_slot(project, before.as_deref(), hash)?)
            {
                return Err(Error::Conflict);
            }
        } else if before.is_some() && role != "index" && role != "source" {
            return Err(Error::Conflict);
        }
        if before_hash.as_deref() != Some(after_hash.as_str())
            && (before.is_some() || !native::managed_projection(project, path, role))
        {
            let idle = native::lease(project, provider, true)
                .and_then(|lease| native::quiescent(project, provider).map(|()| lease));
            match idle {
                Ok(lease) => drop(lease),
                Err(Error::NativeActive) if native::managed_projection(project, path, role) => {
                    let stem = path
                        .file_stem()
                        .and_then(|name| name.to_str())
                        .ok_or(Error::Conflict)?;
                    if stem.contains(".revision-") {
                        return Err(Error::Conflict);
                    }
                    let revision = record["revision"]["id"].as_str().ok_or(Error::Conflict)?;
                    let live =
                        path.with_file_name(format!("{stem}.revision-{revision}-{after_hash}.md"));
                    return self.publish(project, bundle, record, provider, &live, after, role);
                }
                Err(error) => return Err(error),
            }
        }
        let record_ref = c::reference(record);
        let binding_digest =
            c::hash(format!("{}:{provider}:{}", project.id, project.folder.display()).as_bytes());
        let resource = c::hash(path.as_os_str().as_encoded_bytes());
        let after_state = json!({"state":"present","sha256":after_hash,"snapshot_ref":after_hash});
        let before_state = before_hash.as_ref().map_or_else(
            || json!({"state":"absent"}),
            |h| json!({"state":"present","sha256":h,"snapshot_ref":h}),
        );
        let capabilities = c::capabilities(
            provider,
            &native::configuration(&self.roots, project, provider)?,
        )?;
        let fidelity:Vec<Value>=record.as_object().ok_or(Error::Conflict)?.keys().map(|key|json!({"pointer":format!("/{key}"),"outcome":if key=="body"&&record["status"]=="active"&&role!="retired"{"verbatim"}else if key=="scope"{"mapped"}else{"sidecar"},"detail":"Native project profile carries body and scope; immutable AMIS history retains every field and source snapshot."})).collect();
        let expiry = c::expiry();
        let mut plan = json!({"format":"amis.plan","version":"0.4.0","id":c::id(),"record":record_ref,"expected_heads":[record_ref],"target":{"provider":provider,"profile":format!("com.twine.{provider}.project-native.v1"),"binding_id":project.id,"binding_digest":binding_digest,"adapter":"com.twine.memories@0.1.0","capabilities_digest":capabilities["integrity"]["digest"]},"created_at":c::now(),"expires_at":expiry,"coordination":"cooperative_lock","mutations":[{"resource_ref":resource,"before":before_state,"after":after_state,"role":role}],"fidelity":fidelity,"blockers":[]});
        c::seal(&mut plan)?;
        c::validate("plan", &plan)?;
        c::validate_bundle(bundle, &project.id)?;
        let journal = project
            .root
            .join("journal")
            .join(format!("{}.json", plan["id"].as_str().unwrap_or_default()));
        let source_memory = record["derivation"]["inputs"]
            .as_array()
            .filter(|v| v.len() == 1)
            .and_then(|v| v[0]["memory_id"].as_str());
        save_projection_blobs(project, before.as_deref(), after)?;
        let source_memory = if role == "source" {
            self.db
                .query_row(
                    "SELECT memory FROM sources WHERE project=? AND path=?",
                    params![project.id, path.to_string_lossy()],
                    |r| r.get::<_, String>(0),
                )
                .optional()?
        } else {
            source_memory.map(str::to_owned)
        };
        let intent = json!({"capabilities":capabilities,"plan":plan,"path":path,"after":after,"provider":provider,"role":role,"sourceMemory":source_memory,"state":"pending","authorization":{"policy":"com.twine.project-auto.v1","plan_digest":plan["integrity"]["digest"],"binding_digest":binding_digest,"decision_at":c::now()}});
        write_json(&journal, &intent)?;
        self.apply_intent(project, bundle, &journal, intent)
    }
    #[expect(
        clippy::too_many_lines,
        reason = "Guarded apply keeps validation, journal recovery and receipt ordering explicit"
    )]
    fn apply_intent(
        &self,
        project: &Project,
        bundle: &Value,
        journal: &Path,
        mut intent: Value,
    ) -> Result<(), Error> {
        let plan = &intent["plan"];
        c::validate("plan", plan)?;
        if intent["authorization"]["plan_digest"] != plan["integrity"]["digest"]
            || intent["authorization"]["binding_digest"] != plan["target"]["binding_digest"]
        {
            return Err(Error::Conflict);
        }
        let provider = intent["provider"].as_str().ok_or(Error::Conflict)?;
        let capabilities = &intent["capabilities"];
        c::validate("capabilities", capabilities)?;
        let id = plan["record"]["memory_id"]
            .as_str()
            .ok_or(Error::Conflict)?;
        let enabled: bool = self.db.query_row(
            "SELECT enabled FROM projects WHERE id=?",
            [&project.id],
            |r| r.get(0),
        )?;
        if !enabled
            || c::expired(&plan["expires_at"])
            || c::expired(&capabilities["expires_at"])
            || c::heads(bundle, id)
                != plan["expected_heads"]
                    .as_array()
                    .cloned()
                    .ok_or(Error::Conflict)?
            || capabilities["configuration_digest"]
                != native::configuration(&self.roots, project, provider)?
        {
            intent["state"] = json!("superseded");
            write_json(journal, &intent)?;
            return Ok(());
        }
        if intent["authorization"]["policy"] != "com.twine.project-auto.v1"
            || plan["target"]["binding_id"] != project.id
            || plan["target"]["provider"] != provider
            || plan["target"]["capabilities_digest"] != capabilities["integrity"]["digest"]
            || plan["target"]["binding_digest"]
                != c::hash(
                    format!("{}:{provider}:{}", project.id, project.folder.display()).as_bytes(),
                )
        {
            return Err(Error::Conflict);
        }
        let record = c::find(
            bundle,
            plan["record"]["revision_id"]
                .as_str()
                .ok_or(Error::Conflict)?,
        )
        .ok_or(Error::Conflict)?;
        if record["status"] == "active" {
            for input in record["derivation"]["inputs"]
                .as_array()
                .into_iter()
                .flatten()
            {
                let id = input["memory_id"].as_str().ok_or(Error::Conflict)?;
                if c::heads(bundle, id) != vec![input.clone()]
                    || c::find(bundle, input["revision_id"].as_str().unwrap_or_default())
                        .is_none_or(|r| r["status"] != "active")
                {
                    intent["state"] = json!("superseded");
                    write_json(journal, &intent)?;
                    return Ok(());
                }
            }
            if !record["validity"]["expires_at"].is_null()
                && c::expired(&record["validity"]["expires_at"])
            {
                return Err(Error::Conflict);
            }
        }
        native::prepare(project, &self.roots)?;
        let path = PathBuf::from(intent["path"].as_str().ok_or(Error::Conflict)?);
        native::safe_path(&path)?;
        if !path.starts_with(&project.claude)
            && !path.starts_with(project.codex.join("memories/extensions/ad_hoc/notes"))
        {
            return Err(Error::Conflict);
        }
        let after = intent["after"].as_str().ok_or(Error::Conflict)?;
        let after_hash = c::hash(after.as_bytes());
        if plan["mutations"].as_array().map_or(0, Vec::len) != 1
            || plan["mutations"][0]["resource_ref"] != c::hash(path.as_os_str().as_encoded_bytes())
            || plan["mutations"][0]["after"]["sha256"] != after_hash
        {
            return Err(Error::Conflict);
        }
        for state in [
            &plan["mutations"][0]["before"],
            &plan["mutations"][0]["after"],
        ] {
            if state["state"] == "present" {
                let hash = state["sha256"].as_str().ok_or(Error::Conflict)?;
                let bytes = fs::read(project.root.join("blobs").join(hash))?;
                if c::hash(&bytes) != hash || state["snapshot_ref"] != hash {
                    return Err(Error::Conflict);
                }
            }
        }
        let actual = native::read(&path)?;
        if actual.as_deref().map(|t| c::hash(t.as_bytes())).as_deref() != Some(after_hash.as_str())
        {
            let _exclusive = if actual.is_some()
                || !native::managed_projection(
                    project,
                    &path,
                    intent["role"].as_str().ok_or(Error::Conflict)?,
                ) {
                let exclusive = native::lease(project, provider, true)?;
                native::quiescent(project, provider)?;
                Some(exclusive)
            } else {
                None
            };
            native::atomic_write(
                &path,
                after.as_bytes(),
                plan["mutations"][0]["before"]["sha256"].as_str(),
            )?;
        }
        let actual = native::read(&path)?.ok_or(Error::Conflict)?;
        if c::hash(actual.as_bytes()) != after_hash {
            return Err(Error::Conflict);
        }
        let reference = plan["record"].clone();
        let mut receipt = json!({"format":"amis.receipt","version":"0.4.0","id":c::id(),"plan_id":plan["id"],"plan_digest":plan["integrity"]["digest"],"record":reference,"target_binding_id":project.id,"observed_at":c::now(),"write_state":"complete","availability":"discoverable","withdrawal":"not_requested","outputs":[{"resource_ref":plan["mutations"][0]["resource_ref"],"state":"present","sha256":after_hash,"role":intent["role"]}],"evidence":[{"kind":"native-bytes","observed_at":c::now(),"output_refs":[after_hash],"detail":"Verified owned native bytes in an isolated bound project profile. Fresh-context loading and later recall remain separate evidence."}]});
        c::seal(&mut receipt)?;
        c::validate("receipt", &receipt)?;
        write_json(
            &project.root.join("receipts").join(format!(
                "{}.json",
                receipt["id"].as_str().unwrap_or_default()
            )),
            &receipt,
        )?;
        self.db.execute("INSERT INTO projections VALUES(?,?,?,?,?,?,?) ON CONFLICT(project,path) DO UPDATE SET record_revision=excluded.record_revision,source_memory=excluded.source_memory,output_hash=excluded.output_hash,provider=excluded.provider,role=excluded.role",params![project.id,path.to_string_lossy(),reference["revision_id"].as_str(),intent["sourceMemory"].as_str(),after_hash,intent["provider"].as_str(),intent["role"].as_str()])?;
        intent["state"] = json!("complete");
        write_json(journal, &intent)
    }
    fn recover(&self, project: &Project, bundle: &Value, pending: bool) -> Result<(), Error> {
        let directory = project.root.join("journal");
        if !directory.exists() {
            return Ok(());
        }
        let mut held = false;
        for entry in fs::read_dir(directory)? {
            let path = entry?.path();
            let intent = c::parse(&fs::read(&path)?)?;
            if !pending && intent["state"] == "complete" {
                let plan = &intent["plan"];
                c::validate("plan", plan)?;
                if intent["authorization"]["plan_digest"] != plan["integrity"]["digest"]
                    || plan["target"]["binding_id"] != project.id
                {
                    return Err(Error::Conflict);
                }
                let target = PathBuf::from(intent["path"].as_str().ok_or(Error::Conflict)?);
                native::safe_path(&target)?;
                let hash = c::hash(intent["after"].as_str().ok_or(Error::Conflict)?.as_bytes());
                if native::read(&target)?
                    .as_deref()
                    .map(|t| c::hash(t.as_bytes()))
                    == Some(hash.clone())
                {
                    self.db.execute(
                        "INSERT OR IGNORE INTO projections VALUES(?,?,?,?,?,?,?)",
                        params![
                            project.id,
                            target.to_string_lossy(),
                            plan["record"]["revision_id"].as_str(),
                            intent["sourceMemory"].as_str(),
                            hash,
                            intent["provider"].as_str(),
                            intent["role"].as_str()
                        ],
                    )?;
                }
            }
            if pending && intent["state"] == "pending" {
                let startup_index = intent["provider"] == "claude_code"
                    && intent["role"] == "index"
                    && intent["path"].as_str() == project.claude.join("MEMORY.md").to_str();
                let result = self.apply_intent(project, bundle, &path, intent);
                held |= match result {
                    Err(Error::NativeActive) if startup_index => false,
                    other => deferred(other)?,
                };
            }
        }
        if held {
            Err(Error::NativeActive)
        } else {
            Ok(())
        }
    }
    pub fn withdraw(&self, project: &Project, id: &str) -> Result<(), Error> {
        let mut bundle = self.load(project)?;
        let row = self
            .db
            .query_row(
                "SELECT group_key,revision FROM views WHERE project=? AND memory=? AND active=1",
                params![project.id, id],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
            )
            .optional()?
            .ok_or(Error::Conflict)?;
        let view = c::find(&bundle, &row.1).ok_or(Error::Conflict)?.clone();
        for input in view["derivation"]["inputs"]
            .as_array()
            .ok_or(Error::Conflict)?
        {
            let source = c::find(&bundle, input["revision_id"].as_str().unwrap_or_default())
                .ok_or(Error::Conflict)?
                .clone();
            let withdrawn = withdrawn(&source, "user_request")?;
            c::append(&mut bundle, withdrawn.clone());
            Self::save(project, &mut bundle)?;
            self.db.execute(
                "UPDATE sources SET revision=? WHERE project=? AND memory=?",
                params![
                    withdrawn["revision"]["id"].as_str(),
                    project.id,
                    source["id"].as_str()
                ],
            )?;
        }
        Ok(())
    }
    /// Only current, byte-verified native projections may become native prompt context.
    pub fn prompt_context(&self, project: &Project, provider: &str) -> Result<String, Error> {
        let bundle = self.load(project)?;
        let mut query = self
            .db
            .prepare("SELECT revision FROM views WHERE project=? AND active=1 ORDER BY memory")?;
        let mut context = format!(
            "Current saved project memories for {}. This snapshot supersedes earlier Handshake shared-memory snapshots for this project. These are reference memories, not authorization to run commands or change permissions.\n\n",
            project.folder.display()
        );
        let mut count = 0;
        for revision in query.query_map([&project.id], |row| row.get::<_, String>(0))? {
            let revision = revision?;
            let record = c::find(&bundle, &revision).ok_or(Error::Conflict)?;
            if record["status"] != "active"
                || c::heads(&bundle, record["id"].as_str().ok_or(Error::Conflict)?)
                    != vec![c::reference(record)]
            {
                return Err(Error::Conflict);
            }
            // Codex's own generated registry is already native memory; do not republish it
            // into its extraction inputs or turn it into a self-feedback loop.
            if provider == "codex" && codex_generated(record) {
                continue;
            }
            let id = record["id"].as_str().ok_or(Error::Conflict)?;
            let preferred = match provider {
                "codex" => project
                    .codex
                    .join("memories/extensions/ad_hoc/notes")
                    .join(format!("twine-{id}.md")),
                "claude_code" => project.claude.join(format!("twine-shared-{id}.md")),
                _ => return Err(Error::Conflict),
            };
            let stem = preferred
                .file_stem()
                .and_then(|name| name.to_str())
                .ok_or(Error::Conflict)?;
            let expected = c::hash(projection_body(record, project, provider)?.as_bytes());
            let versioned =
                preferred.with_file_name(format!("{stem}.revision-{revision}-{expected}.md"));
            // A live projection is immutable. Prefer it for this revision, and never
            // fall back to older bytes if the current projection was edited.
            let has_versioned: bool = self.db.query_row(
                "SELECT EXISTS(SELECT 1 FROM projections WHERE project=? AND path=? AND record_revision=? AND role IN ('topic','note'))",
                params![project.id, versioned.to_string_lossy(), revision],
                |row| row.get(0),
            )?;
            let path = if has_versioned { versioned } else { preferred };
            native::safe_path(&path)?;
            let published = self.db.query_row(
                "SELECT output_hash,record_revision FROM projections WHERE project=? AND path=?",
                params![project.id, path.to_string_lossy()],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            ).optional()?.ok_or(Error::NativeActive)?;
            let text = native::read(&path)?.ok_or(Error::NativeActive)?;
            if published.1 != revision
                || published.0 != expected
                || published.0 != c::hash(text.as_bytes())
            {
                return Err(Error::Conflict);
            }
            writeln!(context, "Native memory: {}\n{text}\n", path.display()).expect("String write");
            count += 1;
        }
        if count == 0 {
            context.push_str("No active imported project memories in this snapshot.\n");
        }
        Ok(context)
    }

    pub fn snapshot(&self, project: &Project) -> Result<Snapshot, Error> {
        let bundle = self.load(project)?;
        let mut q = self
            .db
            .prepare("SELECT revision FROM views WHERE project=? AND active=1 ORDER BY memory")?;
        let mut records = Vec::new();
        for revision in q.query_map([&project.id], |r| r.get::<_, String>(0))? {
            let revision = revision?;
            let r = c::find(&bundle, &revision).ok_or(Error::Conflict)?;
            records.push(Summary {
                id: r["id"].as_str().unwrap_or_default().into(),
                title: r["title"].as_str().unwrap_or_default().into(),
                sources: r["derivation"]["inputs"].as_array().map_or(0, Vec::len),
                preview: r["body"]["text"]
                    .as_str()
                    .unwrap_or_default()
                    .chars()
                    .take(180)
                    .collect(),
            });
        }
        let (enabled, last_sync, error) = self.db.query_row(
            "SELECT enabled,last_sync,error FROM projects WHERE id=?",
            [&project.id],
            |r| {
                Ok((
                    r.get::<_, bool>(0)?,
                    r.get::<_, Option<String>>(1)?,
                    r.get::<_, Option<String>>(2)?,
                ))
            },
        )?;
        let status = if !enabled {
            "paused"
        } else if error.is_some() {
            "held"
        } else if last_sync.is_none() {
            "starting"
        } else {
            "sharing"
        };
        let message=error.unwrap_or_else(||if enabled {"AMIS memories are consolidated locally and delivered to native project profiles. Shared memories refresh at the next prompt in supported agents; native startup generation follows each agent’s schedule and quota.".into()} else {"Automatic sharing is paused.".into()});
        Ok(Snapshot {
            enabled,
            folder: project.folder.clone(),
            store_path: self.root.clone(),
            amis_path: project.root.join("library.amis.json"),
            claude_path: project.claude.clone(),
            codex_path: project.codex.clone(),
            records,
            status: status.into(),
            message,
            last_sync,
            model_calls: 0,
        })
    }
}
fn codex_generated(record: &Value) -> bool {
    record["sources"].as_array().is_some_and(|sources| {
        !sources.is_empty()
            && sources.iter().all(|source| {
                source["provider"] == "codex"
                    && source["source_id"]
                        .as_str()
                        .is_some_and(|key| key.starts_with("codex-task-group:"))
            })
    })
}

fn save_projection_blobs(
    project: &Project,
    before: Option<&str>,
    after: &str,
) -> Result<(), Error> {
    for bytes in before.into_iter().chain(std::iter::once(after)) {
        let blob = project.root.join("blobs").join(c::hash(bytes.as_bytes()));
        if !blob.exists() {
            native::atomic_write(&blob, bytes.as_bytes(), None)?;
        }
    }
    Ok(())
}

fn projection_body(record: &Value, project: &Project, provider: &str) -> Result<String, Error> {
    let id = record["id"].as_str().ok_or(Error::Conflict)?;
    if record["status"] != "active" {
        return Ok(format!(
            "Handshake memory {id} is withdrawn for project {}. Do not retain its previous claim as current.\n<!-- twine:withdrawn -->\n",
            project.folder.display()
        ));
    }
    let body = format!(
        "{}\n<!-- twine:body -->\n{}",
        native::body(
            &json!({"id":record["id"],"revision":record["revision"],"body":{"text":""}}),
            project
        ),
        record["body"]["text"].as_str().unwrap_or_default()
    );
    if provider == "claude_code" {
        Ok(format!(
            "---\nname: {}\ndescription: Shared current project memory from Handshake\ntype: project\n---\n\n{body}",
            serde_json::to_string(&title(record["body"]["text"].as_str().unwrap_or_default()))?
        ))
    } else {
        Ok(body)
    }
}
fn deferred(result: Result<(), Error>) -> Result<bool, Error> {
    match result {
        Ok(()) => Ok(false),
        Err(Error::NativeActive) => Ok(true),
        Err(error) => Err(error),
    }
}
fn ensure_auto_validity(record: &Value) -> Result<(), Error> {
    if !record["validity"]["not_before"].is_null() || !record["validity"]["expires_at"].is_null() {
        return Err(Error::Contract(
            "Time-bounded memory requires policy review before automatic sharing.".into(),
        ));
    }
    Ok(())
}
fn same_index_slot(
    project: &Project,
    current: Option<&str>,
    previous_hash: &str,
) -> Result<bool, Error> {
    let Some(current) = current else {
        return Ok(false);
    };
    let previous = fs::read_to_string(project.root.join("blobs").join(previous_hash))?;
    if c::hash(previous.as_bytes()) != previous_hash {
        return Err(Error::Conflict);
    }
    let begin = format!("<!-- twine:{}:begin -->", project.id);
    let end = format!("<!-- twine:{}:end -->", project.id);
    let slot = |text: &str| {
        text.split_once(&begin)
            .and_then(|(_, after)| after.split_once(&end))
            .map(|(block, _)| block.to_owned())
    };
    Ok(slot(current).is_some() && slot(current) == slot(&previous))
}
fn entry_id(path: &Path) -> Option<&str> {
    path.parent()?.file_name()?.to_str()
}
fn title(text: &str) -> String {
    text.lines()
        .find(|l| !l.trim().is_empty() && l.trim() != "---")
        .unwrap_or("Project memory")
        .trim_start_matches('#')
        .trim()
        .chars()
        .take(90)
        .collect()
}
fn withdrawn(base: &Value, reason: &str) -> Result<Value, Error> {
    let mut record = base.clone();
    record["revision"] = json!({"id":c::id(),"parents":[c::reference(base)],"created_at":c::now()});
    record["status"] = json!("withdrawn");
    record["withdrawal"] = json!({"reason":reason});
    record
        .as_object_mut()
        .expect("Record object")
        .remove("body");
    c::seal(&mut record)?;
    Ok(record)
}
fn write_json(path: &Path, value: &Value) -> Result<(), Error> {
    let parent = path.parent().ok_or(Error::InvalidFolder)?;
    fs::create_dir_all(parent)?;
    let mut file = tempfile::NamedTempFile::new_in(parent)?;
    file.write_all(&serde_json::to_vec_pretty(value)?)?;
    file.as_file().sync_all()?;
    file.persist(path).map_err(|e| e.error)?;
    File::open(parent)?.sync_all()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture {
        _temp: tempfile::TempDir,
        library: Library,
        project: Project,
        input: PathBuf,
    }
    impl Fixture {
        fn new() -> Self {
            let temp = tempfile::tempdir().unwrap();
            let root = temp.path().canonicalize().unwrap();
            let folder = root.join("workspace");
            fs::create_dir(&folder).unwrap();
            let home = root.join("home");
            let roots = native::Roots {
                claude: home.join(".claude"),
                codex: home.join(".codex"),
            };
            let input = roots
                .claude
                .join("projects")
                .join(super::super::super::locations::claude_key(&folder))
                .join("memory/fact.md");
            fs::create_dir_all(input.parent().unwrap()).unwrap();
            fs::write(
                &input,
                "# Demo account\n\nUse maple-417 for this project only.\n",
            )
            .unwrap();
            let mut library = Library::with_roots(&root.join("twine-memory"), roots).unwrap();
            let project = library.register(&folder).unwrap();
            Self {
                _temp: temp,
                library,
                project,
                input,
            }
        }
        fn sync(&mut self) {
            self.library.sync(&self.project).unwrap();
        }
    }
    #[test]
    fn automatic_native_capture_consolidates_valid_amis_and_delivers_both_directions() {
        let mut f = Fixture::new();
        f.sync();
        let snapshot = f.library.snapshot(&f.project).unwrap();
        assert_eq!(snapshot.records.len(), 1);
        assert_eq!(snapshot.model_calls, 0);
        let bundle = f.library.load(&f.project).unwrap();
        assert_eq!(bundle["format"], "amis.bundle");
        assert_eq!(bundle["records"].as_array().unwrap().len(), 2);
        let codex = f
            .project
            .codex
            .join("memories/extensions/ad_hoc/notes/fresh-codex.md");
        fs::write(
            codex,
            "# Deployment\n\nUse the green lane for this project.\n",
        )
        .unwrap();
        f.sync();
        let snapshot = f.library.snapshot(&f.project).unwrap();
        assert_eq!(snapshot.records.len(), 2);
        for r in &snapshot.records {
            assert!(
                f.project
                    .claude
                    .join(format!("twine-shared-{}.md", r.id))
                    .exists()
            );
            assert!(
                f.project
                    .codex
                    .join("memories/extensions/ad_hoc/notes")
                    .join(format!("twine-{}.md", r.id))
                    .exists()
            );
        }
        assert!(
            fs::read_to_string(f.project.claude.join("MEMORY.md"))
                .unwrap()
                .contains("Handshake current project memories")
        );
    }
    #[test]
    fn repeated_cycles_do_not_echo_native_projections_or_create_revisions() {
        let mut f = Fixture::new();
        f.sync();
        let before = f.library.load(&f.project).unwrap()["records"]
            .as_array()
            .unwrap()
            .len();
        for _ in 0..3 {
            f.sync();
        }
        assert_eq!(
            f.library.load(&f.project).unwrap()["records"]
                .as_array()
                .unwrap()
                .len(),
            before
        );
    }
    #[test]
    fn a_native_projection_edit_returns_to_the_original_identity() {
        let mut f = Fixture::new();
        f.sync();
        let snap = f.library.snapshot(&f.project).unwrap();
        let id = &snap.records[0].id;
        let path = f
            .project
            .codex
            .join("memories/extensions/ad_hoc/notes")
            .join(format!("twine-{id}.md"));
        let original = fs::read_to_string(&path).unwrap();
        fs::write(&path, original.replace("maple-417", "maple-418")).unwrap();
        f.sync();
        let snap = f.library.snapshot(&f.project).unwrap();
        assert_eq!(snap.records.len(), 1);
        assert!(snap.records[0].preview.contains("maple-418"));
        let original_source = fs::read_to_string(&f.input).unwrap();
        assert!(original_source.contains("maple-417"));
        f.sync();
        assert_eq!(f.library.snapshot(&f.project).unwrap().records.len(), 1);
    }
    #[test]
    fn missing_source_is_not_a_withdrawal_and_explicit_withdrawal_is_durable() {
        let mut f = Fixture::new();
        f.sync();
        fs::remove_file(&f.input).unwrap();
        f.sync();
        let snap = f.library.snapshot(&f.project).unwrap();
        assert_eq!(snap.records.len(), 1);
        f.library.withdraw(&f.project, &snap.records[0].id).unwrap();
        f.sync();
        assert!(f.library.snapshot(&f.project).unwrap().records.is_empty());
        assert!(
            f.library.load(&f.project).unwrap()["records"]
                .as_array()
                .unwrap()
                .iter()
                .any(|r| r["status"] == "withdrawn")
        );
    }
    #[test]
    fn project_profiles_are_physically_isolated_and_config_is_not_a_memory_prompt() {
        let mut f = Fixture::new();
        f.sync();
        let other = f.project.folder.parent().unwrap().join("other");
        fs::create_dir(&other).unwrap();
        let p = f.library.register(&other).unwrap();
        f.library.sync(&p).unwrap();
        assert_ne!(f.project.codex, p.codex);
        assert_ne!(f.project.claude, p.claude);
        assert!(f.library.snapshot(&p).unwrap().records.is_empty());
        let env = native::environment(&f.project);
        assert!(
            env.iter()
                .any(|(k, v)| k == "CODEX_HOME" && Path::new(v) == f.project.codex)
        );
        assert!(!env.iter().any(|(_, v)| v.contains("catalog")));
    }
    #[test]
    fn concurrent_native_and_canonical_edits_are_held_without_overwriting() {
        let mut f = Fixture::new();
        f.sync();
        let snap = f.library.snapshot(&f.project).unwrap();
        let path = f
            .project
            .codex
            .join("memories/extensions/ad_hoc/notes")
            .join(format!("twine-{}.md", snap.records[0].id));
        let edit = fs::read_to_string(&path)
            .unwrap()
            .replace("maple-417", "native-edit");
        fs::write(&path, &edit).unwrap();
        fs::write(&f.input, "A different concurrent source edit.\n").unwrap();
        assert!(f.library.sync(&f.project).is_err());
        assert_eq!(fs::read_to_string(path).unwrap(), edit);
    }
    #[test]
    fn invalid_integrity_blocks_native_publication() {
        let mut f = Fixture::new();
        f.sync();
        let path = f.project.root.join("library.amis.json");
        let mut bundle: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        bundle["records"][0]["body"]["text"] = json!("tampered");
        write_json(&path, &bundle).unwrap();
        assert!(f.library.sync(&f.project).is_err());
    }
    #[test]
    fn lost_metadata_recovers_from_complete_amis_history() {
        let mut f = Fixture::new();
        f.sync();
        let original = f.library.snapshot(&f.project).unwrap().records[0]
            .id
            .clone();
        f.library.db.execute("DELETE FROM sources", []).unwrap();
        f.library.db.execute("DELETE FROM views", []).unwrap();
        f.sync();
        assert_eq!(
            f.library.snapshot(&f.project).unwrap().records[0].id,
            original
        );
    }
    #[test]
    fn malformed_canonical_bytes_are_preserved() {
        let mut f = Fixture::new();
        f.sync();
        let path = f.project.root.join("library.amis.json");
        fs::write(&path, [0xff, 0xfe]).unwrap();
        fs::write(&f.input, "changed").unwrap();
        assert!(f.library.sync(&f.project).is_err());
        assert_eq!(fs::read(path).unwrap(), [0xff, 0xfe]);
    }
    #[test]
    fn missing_projection_metadata_recovers_without_echo() {
        let mut f = Fixture::new();
        f.sync();
        let count = f.library.load(&f.project).unwrap()["records"]
            .as_array()
            .unwrap()
            .len();
        f.library.db.execute("DELETE FROM projections", []).unwrap();
        f.sync();
        assert_eq!(
            f.library.load(&f.project).unwrap()["records"]
                .as_array()
                .unwrap()
                .len(),
            count
        );
    }
    #[test]
    fn portable_extensions_cannot_grant_receiver_bindings() {
        let mut f = Fixture::new();
        f.sync();
        let binding = f.project.root.join("bindings");
        fs::remove_dir_all(binding).unwrap();
        assert!(f.library.sync(&f.project).is_err());
    }
    #[test]
    fn withdrawal_corrects_original_managed_native_source() {
        let mut f = Fixture::new();
        fs::remove_file(&f.input).unwrap();
        let source = f
            .project
            .codex
            .join("memories/extensions/ad_hoc/notes/original.md");
        fs::write(&source, "Use willow-19.\n").unwrap();
        f.sync();
        let id = f.library.snapshot(&f.project).unwrap().records[0]
            .id
            .clone();
        f.library.withdraw(&f.project, &id).unwrap();
        f.sync();
        let text = fs::read_to_string(source).unwrap();
        assert!(text.contains("withdrawn"));
        assert!(!text.contains("willow-19"));
    }
    #[test]
    fn accepted_native_edit_recovers_after_metadata_update_is_lost() {
        let mut f = Fixture::new();
        f.sync();
        let id = f.library.snapshot(&f.project).unwrap().records[0]
            .id
            .clone();
        let path = f
            .project
            .codex
            .join("memories/extensions/ad_hoc/notes")
            .join(format!("twine-{id}.md"));
        let old = fs::read_to_string(&path).unwrap();
        let edited = old.replace("maple-417", "maple-419");
        fs::write(&path, &edited).unwrap();
        let mut bundle = f.library.load(&f.project).unwrap();
        let candidate = native::Candidate {
            provider: "codex",
            key: path.to_string_lossy().into(),
            path: path.clone(),
            text: edited,
        };
        f.library
            .accept(&f.project, &mut bundle, &candidate)
            .unwrap();
        f.library
            .db
            .execute(
                "UPDATE projections SET output_hash=? WHERE project=? AND path=?",
                params![
                    c::hash(old.as_bytes()),
                    f.project.id,
                    path.to_string_lossy()
                ],
            )
            .unwrap();
        f.sync();
        assert!(
            f.library.snapshot(&f.project).unwrap().records[0]
                .preview
                .contains("maple-419")
        );
    }
    #[test]
    fn symlink_parent_never_receives_native_writes() {
        let mut f = Fixture::new();
        f.sync();
        let notes = f.project.codex.join("memories/extensions/ad_hoc/notes");
        let outside = f.project.folder.join("outside");
        fs::create_dir(&outside).unwrap();
        fs::remove_dir_all(&notes).unwrap();
        std::os::unix::fs::symlink(&outside, &notes).unwrap();
        assert!(f.library.sync(&f.project).is_err());
        assert_eq!(fs::read_dir(outside).unwrap().count(), 0);
    }
    #[test]
    fn session_lease_defers_delivery_then_retries_all_targets_and_withdrawals() {
        let mut f = Fixture::new();
        fs::remove_file(&f.input).unwrap();
        let one = f
            .project
            .codex
            .join("memories/extensions/ad_hoc/notes/one.md");
        let two = f.project.claude.join("two.md");
        for p in [&one, &two] {
            fs::write(p, "Use violet-55.\n").unwrap();
        }
        f.sync();
        let id = f.library.snapshot(&f.project).unwrap().records[0]
            .id
            .clone();
        let lease = f.library.session_lease(&f.project, "claude_code").unwrap();
        f.library.withdraw(&f.project, &id).unwrap();
        assert!(matches!(
            f.library.sync(&f.project),
            Err(Error::NativeActive)
        ));
        assert!(fs::read_to_string(&two).unwrap().contains("violet-55"));
        assert!(fs::read_to_string(&one).unwrap().contains("withdrawn"));
        drop(lease);
        f.sync();
        for path in [one, two] {
            let text = fs::read_to_string(path).unwrap();
            assert!(text.contains("withdrawn"));
            assert!(!text.contains("violet-55"));
        }
    }
    #[test]
    fn independent_claude_index_edits_are_preserved_without_holding_sync() {
        let mut f = Fixture::new();
        f.sync();
        let path = f.project.claude.join("MEMORY.md");
        let mut text = fs::read_to_string(&path).unwrap();
        text.push_str("\n- Claude's independent native link.\n");
        fs::write(&path, &text).unwrap();
        f.sync();
        assert!(
            fs::read_to_string(path)
                .unwrap()
                .contains("Claude's independent native link.")
        );
    }
    #[test]
    fn obsolete_view_never_withdraws_a_current_native_source() {
        let mut f = Fixture::new();
        fs::remove_file(&f.input).unwrap();
        let source = f
            .project
            .codex
            .join("memories/extensions/ad_hoc/notes/original.md");
        fs::write(&source, "Use alpha.\n").unwrap();
        f.sync();
        fs::write(&source, "Use beta.\n").unwrap();
        f.sync();
        assert_eq!(fs::read_to_string(&source).unwrap(), "Use beta.\n");
        f.sync();
        assert_eq!(f.library.snapshot(&f.project).unwrap().records.len(), 1);
    }
    #[test]
    fn native_settings_changes_hold_publication() {
        let mut f = Fixture::new();
        f.sync();
        fs::write(
            f.library.roots.claude.join("settings.json"),
            "{\"autoMemoryEnabled\":false}",
        )
        .unwrap();
        fs::write(&f.input, "A changed fact.\n").unwrap();
        assert!(f.library.sync(&f.project).is_err());
        assert!(
            !f.library.snapshot(&f.project).unwrap().records[0]
                .preview
                .contains("changed")
        );
    }
    #[test]
    fn managed_codex_native_registry_shares_new_knowledge_without_self_feedback() {
        let mut f = Fixture::new();
        f.sync();
        let registry = f.project.codex.join("memories/MEMORY.md");
        fs::write(&registry,"# Task Group: Native learned deployment\n\n## Learnings\n- Use the green deployment lane.\n").unwrap();
        f.sync();
        let snapshot = f.library.snapshot(&f.project).unwrap();
        assert_eq!(snapshot.records.len(), 2);
        let learned = snapshot
            .records
            .iter()
            .find(|r| r.preview.contains("green deployment"))
            .unwrap();
        assert!(
            fs::read_to_string(
                f.project
                    .claude
                    .join(format!("twine-shared-{}.md", learned.id))
            )
            .unwrap()
            .contains("green deployment")
        );
        assert!(
            !f.project
                .codex
                .join("memories/extensions/ad_hoc/notes")
                .join(format!("twine-{}.md", learned.id))
                .exists()
        );
        let n = f.library.load(&f.project).unwrap()["records"]
            .as_array()
            .unwrap()
            .len();
        f.sync();
        assert_eq!(
            f.library.load(&f.project).unwrap()["records"]
                .as_array()
                .unwrap()
                .len(),
            n
        );
    }
    #[test]
    fn grouped_native_source_edits_keep_their_specific_identity() {
        let mut f = Fixture::new();
        fs::remove_file(&f.input).unwrap();
        let one = f
            .project
            .codex
            .join("memories/extensions/ad_hoc/notes/one.md");
        let two = f.project.claude.join("two.md");
        for p in [&one, &two] {
            fs::write(p, "Same original fact.\n").unwrap();
        }
        f.sync();
        fs::write(&one, "New fact from one source.\n").unwrap();
        f.sync();
        assert_eq!(f.library.snapshot(&f.project).unwrap().records.len(), 2);
        assert_eq!(
            fs::read_to_string(one).unwrap(),
            "New fact from one source.\n"
        );
    }
    #[test]
    fn an_active_harness_does_not_block_the_other_native_profile() {
        let mut f = Fixture::new();
        f.sync();
        let lease = f.library.session_lease(&f.project, "claude_code").unwrap();
        let new = f
            .project
            .codex
            .join("memories/extensions/ad_hoc/notes/new.md");
        fs::write(&new, "A new native fact.\n").unwrap();
        f.library.sync(&f.project).unwrap();
        let snapshot = f.library.snapshot(&f.project).unwrap();
        let new = snapshot
            .records
            .iter()
            .find(|r| r.preview.contains("new native fact"))
            .unwrap();
        assert!(
            f.project
                .codex
                .join("memories/extensions/ad_hoc/notes")
                .join(format!("twine-{}.md", new.id))
                .exists()
        );
        assert!(
            fs::read_to_string(f.project.claude.join(format!("twine-shared-{}.md", new.id)))
                .unwrap()
                .contains("new native fact")
        );
        drop(lease);
    }

    #[test]
    fn native_memory_use_opt_out_does_not_confuse_generation_with_loading() {
        let f = Fixture::new();
        let config = f.project.codex.join("config.toml");
        fs::write(
            &config,
            "[memories]\ngenerate_memories = false\nuse_memories = true\n",
        )
        .unwrap();
        assert!(native::memory_use_enabled(&f.project.folder, &config).unwrap());
        fs::write(&config, "[memories]\nuse_memories = false\n").unwrap();
        assert!(!native::memory_use_enabled(&f.project.folder, &config).unwrap());
        fs::write(&config, "[memories]\nuse_memories = true\n").unwrap();
        let local = f.project.folder.join(".codex");
        fs::create_dir(&local).unwrap();
        fs::write(
            local.join("config.toml"),
            "[memories]\nuse_memories = false\n",
        )
        .unwrap();
        assert!(!native::memory_use_enabled(&f.project.folder, &config).unwrap());
        let nested = f.project.folder.join("frontend");
        fs::create_dir(&nested).unwrap();
        assert!(!native::memory_use_enabled(&nested, &config).unwrap());
    }

    #[test]
    fn first_memory_shares_live_while_native_startup_index_waits_until_idle() {
        let mut f = Fixture::new();
        fs::remove_file(&f.input).unwrap();
        f.sync();
        let claude = f.library.session_lease(&f.project, "claude_code").unwrap();
        let codex = f.library.session_lease(&f.project, "codex").unwrap();
        fs::write(
            f.project
                .codex
                .join("memories/extensions/ad_hoc/notes/first.md"),
            "Use the violet receipt check.",
        )
        .unwrap();
        f.library.sync(&f.project).unwrap();
        f.library.sync(&f.project).unwrap();
        assert!(!f.project.claude.join("MEMORY.md").exists());
        assert_eq!(f.library.snapshot(&f.project).unwrap().status, "sharing");
        for provider in ["claude_code", "codex"] {
            assert!(
                f.library
                    .prompt_context(&f.project, provider)
                    .unwrap()
                    .contains("violet receipt")
            );
        }
        drop((claude, codex));
        f.sync();
        assert!(f.project.claude.join("MEMORY.md").exists());
    }

    #[test]
    fn both_live_harnesses_receive_new_memories_without_replacing_existing_native_files() {
        let mut f = Fixture::new();
        f.sync();
        let _claude = f.library.session_lease(&f.project, "claude_code").unwrap();
        let _codex = f.library.session_lease(&f.project, "codex").unwrap();
        let old_index = fs::read(f.project.claude.join("MEMORY.md")).unwrap();
        fs::write(
            f.project.claude.join("nickname.md"),
            "The preferred nickname is river-moth.\n",
        )
        .unwrap();
        f.library.sync(&f.project).unwrap();
        for provider in ["claude_code", "codex"] {
            let context = f.library.prompt_context(&f.project, provider).unwrap();
            assert!(context.contains("river-moth"));
            assert!(context.contains("Native memory:"));
        }
        assert_eq!(
            fs::read(f.project.claude.join("MEMORY.md")).unwrap(),
            old_index
        );
        fs::write(
            f.project
                .codex
                .join("memories/extensions/ad_hoc/notes/format.md"),
            "Use day-first dates.\n",
        )
        .unwrap();
        f.library.sync(&f.project).unwrap();
        assert!(
            f.library
                .prompt_context(&f.project, "claude_code")
                .unwrap()
                .contains("day-first")
        );
    }

    #[test]
    fn live_revision_siblings_preserve_previous_bytes_and_do_not_hide_native_edits() {
        let mut f = Fixture::new();
        f.sync();
        let _codex = f.library.session_lease(&f.project, "codex").unwrap();
        let snapshot = f.library.snapshot(&f.project).unwrap();
        let id = &snapshot.records[0].id;
        let original = f
            .project
            .codex
            .join("memories/extensions/ad_hoc/notes")
            .join(format!("twine-{id}.md"));
        let before = fs::read(&original).unwrap();
        // A second identical source changes the derived revision and its provenance,
        // while retaining the same consolidated memory identity.
        fs::write(
            f.project.claude.join("duplicate.md"),
            fs::read(&f.input).unwrap(),
        )
        .unwrap();
        f.library.sync(&f.project).unwrap();
        assert_eq!(fs::read(&original).unwrap(), before);
        let files: Vec<_> = fs::read_dir(original.parent().unwrap())
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .filter(|p| {
                p.file_name()
                    .unwrap()
                    .to_string_lossy()
                    .contains(".revision-")
            })
            .collect();
        assert_eq!(files.len(), 1);
        let live = &files[0];
        assert!(
            f.library
                .prompt_context(&f.project, "codex")
                .unwrap()
                .contains(live.to_str().unwrap())
        );
        fs::write(live, "An independent native edit.\n").unwrap();
        assert!(matches!(
            f.library.prompt_context(&f.project, "codex"),
            Err(Error::Conflict)
        ));
        assert_eq!(
            fs::read_to_string(live).unwrap(),
            "An independent native edit.\n"
        );
        fs::remove_file(live).unwrap();
        assert!(matches!(
            f.library.prompt_context(&f.project, "codex"),
            Err(Error::NativeActive)
        ));
    }

    #[test]
    fn live_context_excludes_withdrawn_memories_while_source_replacement_waits() {
        let mut f = Fixture::new();
        fs::write(
            f.project.claude.join("source.md"),
            fs::read(&f.input).unwrap(),
        )
        .unwrap();
        fs::remove_file(&f.input).unwrap();
        f.sync();
        let id = f.library.snapshot(&f.project).unwrap().records[0]
            .id
            .clone();
        let _claude = f.library.session_lease(&f.project, "claude_code").unwrap();
        let _codex = f.library.session_lease(&f.project, "codex").unwrap();
        f.library.withdraw(&f.project, &id).unwrap();
        assert!(matches!(
            f.library.sync(&f.project),
            Err(Error::NativeActive)
        ));
        for provider in ["claude_code", "codex"] {
            let context = f.library.prompt_context(&f.project, provider).unwrap();
            assert!(!context.contains("maple-417"));
            assert!(context.contains("No active imported project memories"));
        }
    }

    #[test]
    fn retired_live_siblings_cannot_reintroduce_a_withdrawn_claim_after_sessions_end() {
        let mut f = Fixture::new();
        f.sync();
        let lease = f.library.session_lease(&f.project, "codex").unwrap();
        fs::write(
            f.project.claude.join("duplicate.md"),
            fs::read(&f.input).unwrap(),
        )
        .unwrap();
        f.library.sync(&f.project).unwrap();
        let id = f.library.snapshot(&f.project).unwrap().records[0]
            .id
            .clone();
        f.library.withdraw(&f.project, &id).unwrap();
        f.library.sync(&f.project).unwrap();
        drop(lease);
        f.sync();
        let notes = f.project.codex.join("memories/extensions/ad_hoc/notes");
        for entry in fs::read_dir(notes).unwrap() {
            let path = entry.unwrap().path();
            let text = fs::read_to_string(&path).unwrap();
            assert!(
                !text.contains("maple-417"),
                "stale claim at {}",
                path.display()
            );
        }
        let count = f.library.load(&f.project).unwrap()["records"]
            .as_array()
            .unwrap()
            .len();
        f.sync();
        assert_eq!(
            f.library.load(&f.project).unwrap()["records"]
                .as_array()
                .unwrap()
                .len(),
            count
        );
        assert!(f.library.snapshot(&f.project).unwrap().records.is_empty());
    }
}
