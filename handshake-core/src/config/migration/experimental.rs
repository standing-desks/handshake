//! Rename legacy experimental sections once, without maintaining a loader alias.

use std::collections::HashSet;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use toml_edit::{Decor, DocumentMut, Item, Key, Table, TableLike};

use super::ConfigMigrationError;
use crate::config::imports::{MAX_DEPTH, MAX_DOCUMENTS, import_path};
use crate::files::{self, FileContent, FileSaveOutcome, FileSaveRequest};

static MIGRATION: Mutex<()> = Mutex::new(());

pub(in crate::config) fn rename_experimental(path: &Path) -> Result<(), ConfigMigrationError> {
    let _guard = MIGRATION
        .lock()
        .map_err(|_| failure(path, io::Error::other("migration lock poisoned")))?;
    let mut migration = Migration::default();
    // Missing roots are created by the regular loader. Invalid import graphs and TOML
    // remain untouched so normal diagnostics and the raw settings editor still work.
    if !path.exists() || !migration.visit(path)? {
        return Ok(());
    }
    migration.save()
}

#[derive(Default)]
struct Migration {
    active: Vec<PathBuf>,
    documents: usize,
    planned: HashSet<PathBuf>,
    saves: Vec<FileSaveRequest>,
}

impl Migration {
    fn visit(&mut self, path: &Path) -> Result<bool, ConfigMigrationError> {
        if self.active.len() >= MAX_DEPTH || self.documents >= MAX_DOCUMENTS {
            return Ok(false);
        }
        let canonical = match fs::canonicalize(path) {
            Ok(path) => path,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
            Err(error) => return Err(failure(path, error)),
        };
        if self.active.contains(&canonical) {
            return Ok(false);
        }
        self.documents += 1;
        let parent = canonical
            .parent()
            .ok_or_else(|| failure(path, io::ErrorKind::InvalidInput.into()))?;
        let file = files::read_preview(parent, &canonical);
        let source = match file.content {
            FileContent::Text(source) => source,
            FileContent::TooLarge => {
                fs::read_to_string(&canonical).map_err(|error| failure(path, error))?
            }
            _ => {
                // Preserve the loader/editor's existing handling of inaccessible
                // or non-text sources instead of making startup fail here.
                return Ok(false);
            }
        };
        let Ok(document) = toml::de::DeTable::parse(&source) else {
            return Ok(false);
        };
        let imports = match document.get_ref().get("import").map(toml::Spanned::get_ref) {
            None => Vec::new(),
            Some(toml::de::DeValue::String(value)) => vec![value.as_ref()],
            Some(toml::de::DeValue::Array(array)) => {
                let Some(paths) = array
                    .iter()
                    .map(|value| value.get_ref().as_str())
                    .collect::<Option<Vec<_>>>()
                else {
                    return Ok(false);
                };
                paths
            }
            Some(_) => return Ok(false),
        };
        self.active.push(canonical.clone());
        for import in imports {
            let Some(imported) = import_path(
                path.parent().unwrap_or(Path::new(".")),
                Path::new(import),
                std::env::home_dir().as_deref(),
            ) else {
                return Ok(false);
            };
            if !self.visit(&imported)? {
                return Ok(false);
            }
        }
        self.active.pop();
        if self.planned.insert(canonical.clone())
            && document.get_ref().contains_key("feature_flags")
        {
            // Use the reader's parser for discovery: toml_edit cannot represent
            // every supported unknown value, even in otherwise canonical files.
            let mut document = source.parse::<DocumentMut>().map_err(|_| failure(path, io::Error::other("legacy section cannot be safely migrated automatically; rename feature_flags to experimental manually")))?;
            rename_section(&mut document).map_err(|error| failure(path, error))?;
            let text = document.to_string();
            // toml_edit normalizes CRLF while parsing; preserve the source convention.
            let text = if source.contains("\r\n") && !source.replace("\r\n", "").contains('\n') {
                text.replace("\r\n", "\n").replace('\n', "\r\n")
            } else {
                text
            };
            if toml::de::DeTable::parse(&text).is_err() {
                return Err(failure(
                    path,
                    io::Error::other("renamed configuration is invalid; source was retained"),
                ));
            }
            self.saves.push(FileSaveRequest {
                folder: parent.to_owned(),
                path: canonical,
                text,
                expected_version: file.version.ok_or_else(|| {
                    failure(path, io::Error::other("configuration exceeds automatic migration size limit; rename feature_flags to experimental manually"))
                })?,
                overwrite: false,
            });
        }
        Ok(true)
    }

    fn save(self) -> Result<(), ConfigMigrationError> {
        // Each replacement is atomic. If a later save fails, a retry skips completed
        // files and finishes the remainder without needing a separate version marker.
        for request in self.saves {
            match files::save(&request)
                .map_err(|error| failure(&request.path, io::Error::other(error)))?
            {
                FileSaveOutcome::Saved(_) => {}
                FileSaveOutcome::Conflict(_) => {
                    return Err(failure(
                        &request.path,
                        io::Error::other("configuration changed during migration; retry"),
                    ));
                }
            }
        }
        Ok(())
    }
}

fn rename_section(document: &mut DocumentMut) -> io::Result<bool> {
    let Some((old_key, old)) = document.as_table_mut().remove_entry("feature_flags") else {
        return Ok(false);
    };
    let old_table = old
        .as_table_like()
        .ok_or_else(|| io::Error::other("feature_flags must be a table"))?;
    if let Some(existing) = document.get_mut("experimental") {
        // A regular table can retain trailing line comments from either source.
        // Inserting those directly into an inline table can comment out its brace.
        let mut new_table = regular_table(std::mem::take(existing))?;
        merge_missing(&mut new_table, old_table)?;
        prepend_comments(&mut new_table, &old_key, &old);
        new_table.set_dotted(false);
        new_table.set_implicit(false);
        *existing = Item::Table(new_table);
    } else {
        let new_key = Key::new("experimental")
            .with_leaf_decor(old_key.leaf_decor().clone())
            .with_dotted_decor(old_key.dotted_decor().clone());
        document.as_table_mut().insert_formatted(&new_key, old);
    }
    Ok(true)
}

fn merge_missing(target: &mut Table, source: &dyn TableLike) -> io::Result<()> {
    for (name, value) in source.iter() {
        if let Some(existing) = target.get_mut(name) {
            if existing.is_table_like()
                && let Some(incoming) = value.as_table_like()
            {
                let mut table = regular_table(std::mem::take(existing))?;
                merge_missing(&mut table, incoming)?;
                if let Some(key) = source.key(name) {
                    prepend_comments(&mut table, key, value);
                }
                *existing = Item::Table(table);
            } else if let Some(key) = source.key(name) {
                let mut prefix = comments(key.leaf_decor());
                prefix.push_str(&item_comments(value));
                if let Some(mut key) = target.key_mut(name) {
                    prefix.push_str(
                        key.leaf_decor()
                            .prefix()
                            .and_then(|raw| raw.as_str())
                            .unwrap_or(""),
                    );
                    key.leaf_decor_mut().set_prefix(prefix);
                }
            }
        } else if let Some(key) = source.key(name) {
            target.entry_format(key).or_insert(value.clone());
        }
    }
    Ok(())
}

fn regular_table(item: Item) -> io::Result<Table> {
    match item {
        Item::Table(table) => Ok(table),
        Item::Value(toml_edit::Value::InlineTable(inline)) => {
            let mut table = Table::new();
            *table.decor_mut() = inline.decor().clone();
            for (key, value) in &inline {
                if let Some(formatted) = inline.key(key) {
                    table.insert_formatted(formatted, Item::Value(value.clone()));
                }
            }
            Ok(table)
        }
        _ => Err(io::Error::other("experimental must be a table")),
    }
}

fn item_comments(item: &Item) -> String {
    if let Some(table) = item.as_table() {
        comments(table.decor())
    } else if let Some(value) = item.as_value() {
        comments(value.decor())
    } else {
        String::new()
    }
}

fn prepend_comments(table: &mut Table, key: &Key, source: &Item) {
    let mut prefix = comments(key.leaf_decor());
    prefix.push_str(&item_comments(source));
    prefix.push_str(
        table
            .decor()
            .prefix()
            .and_then(|raw| raw.as_str())
            .unwrap_or(""),
    );
    table.decor_mut().set_prefix(prefix);
}

fn comments(decor: &Decor) -> String {
    let mut result = String::new();
    for raw in [decor.prefix(), decor.suffix()].into_iter().flatten() {
        if let Some(text) = raw.as_str().filter(|text| text.contains('#')) {
            result.push_str(text);
            if !text.ends_with('\n') {
                result.push('\n');
            }
        }
    }
    result
}

fn failure(path: &Path, source: io::Error) -> ConfigMigrationError {
    ConfigMigrationError::Experimental {
        path: path.to_owned(),
        source,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn preserves_values_comments_syntax_and_second_run_identity() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        for enabled in [false, true] {
            for source in [
                format!(
                    "# feature_flags stays in comments\n[terminal]\nfont_size = 17 # keep\n[feature_flags] # experiment\ncross_agent_memory_consolidation = {enabled} # choice\n"
                ),
                format!(
                    "feature_flags = {{ cross_agent_memory_consolidation = {enabled} }} # keep\n"
                ),
                format!("feature_flags.cross_agent_memory_consolidation = {enabled}\n"),
            ] {
                fs::write(&path, &source).unwrap();
                rename_experimental(&path).unwrap();
                let result = fs::read_to_string(&path).unwrap();
                assert_eq!(
                    result,
                    source
                        .replace("[feature_flags]", "[experimental]")
                        .replace("feature_flags =", "experimental =")
                        .replace("feature_flags.", "experimental.")
                );
                assert_eq!(
                    Config::load(&path)
                        .config
                        .experimental
                        .cross_agent_memory_consolidation,
                    enabled
                );
                let before = fs::metadata(&path).unwrap().modified().unwrap();
                rename_experimental(&path).unwrap();
                assert_eq!(fs::read_to_string(&path).unwrap(), result);
                assert_eq!(fs::metadata(&path).unwrap().modified().unwrap(), before);
            }
        }
    }

    #[test]
    fn merges_sections_with_canonical_values_winning() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        for (old, new) in [
            (
                "[feature_flags]\ncross_agent_memory_consolidation = true\nretired = false # keep\n",
                "[experimental]\ncross_agent_memory_consolidation = false # canonical\n",
            ),
            (
                "feature_flags = { cross_agent_memory_consolidation = true, retired = false }\n",
                "experimental = { cross_agent_memory_consolidation = false }\n",
            ),
        ] {
            fs::write(&path, format!("{old}{new}")).unwrap();
            rename_experimental(&path).unwrap();
            let source = fs::read_to_string(&path).unwrap();
            let document: DocumentMut = source.parse().unwrap();
            assert!(document.get("feature_flags").is_none());
            assert_eq!(document["experimental"]["retired"].as_bool(), Some(false));
            assert!(
                !Config::load(&path)
                    .config
                    .experimental
                    .cross_agent_memory_consolidation
            );
        }
    }

    #[test]
    fn mixed_section_forms_and_header_comments_produce_valid_toml() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        for source in [
            "experimental = {} # canonical\n# old header\n[feature_flags] # old suffix\ncross_agent_memory_consolidation = true # choice\n",
            "# old header\nfeature_flags = { cross_agent_memory_consolidation = true } # old suffix\n[experimental] # canonical\n",
            "# canonical header\nexperimental = { nested = {} } # canonical\n[feature_flags] # old suffix\ncross_agent_memory_consolidation = true # choice\n# nested old header\n[feature_flags.nested] # nested old suffix\nitem = true # nested\n",
        ] {
            fs::write(&path, source).unwrap();
            rename_experimental(&path).unwrap();
            let migrated = fs::read_to_string(&path).unwrap();
            assert!(toml::de::DeTable::parse(&migrated).is_ok(), "{migrated}");
            assert!(migrated.contains("# canonical"), "{migrated}");
            assert!(migrated.contains("# old suffix"), "{migrated}");
            if source.contains("# old header") {
                assert!(migrated.contains("# old header"), "{migrated}");
            }
            if source.contains("# nested old header") {
                assert!(migrated.contains("# nested old header"), "{migrated}");
                assert!(migrated.contains("# nested old suffix"), "{migrated}");
            }
            assert!(
                Config::load(&path)
                    .config
                    .experimental
                    .cross_agent_memory_consolidation
            );
        }
    }

    #[test]
    fn crlf_multiline_strings_are_preserved_without_doubling_carriage_returns() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        let source = "extra = '''\r\nhello feature_flags\r\n'''\r\n[feature_flags]\r\ncross_agent_memory_consolidation = true\r\n";
        fs::write(&path, source).unwrap();
        rename_experimental(&path).unwrap();
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            source.replace("[feature_flags]", "[experimental]")
        );
        assert!(
            Config::load(&path)
                .config
                .experimental
                .cross_agent_memory_consolidation
        );
    }

    #[test]
    fn unrepresentable_or_oversized_legacy_sources_report_failure_without_losing_opt_in() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        for source in [
            "extra = 9223372036854775808\n[feature_flags]\ncross_agent_memory_consolidation = true\n".to_owned(),
            format!("[feature_flags]\ncross_agent_memory_consolidation = true\n#{}", "x".repeat(usize::try_from(files::TEXT_LIMIT).unwrap())),
        ] {
            fs::write(&path, &source).unwrap();
            assert!(rename_experimental(&path).unwrap_err().to_string().contains("rename feature_flags to experimental manually"));
            assert_eq!(fs::read_to_string(&path).unwrap(), source);
        }
    }

    #[test]
    fn unrepresentable_unknown_values_do_not_block_discovery_of_legacy_imports() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        let imported = directory.path().join("legacy.toml");
        let root = "extra = 9223372036854775808\nimport = 'legacy.toml'\n";
        fs::write(&path, root).unwrap();
        fs::write(
            &imported,
            "[feature_flags]\ncross_agent_memory_consolidation = true\n",
        )
        .unwrap();
        rename_experimental(&path).unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), root);
        assert!(
            Config::load(&path)
                .config
                .experimental
                .cross_agent_memory_consolidation
        );
    }

    #[test]
    fn migrates_nested_shared_and_symlinked_imports_preserving_precedence() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        let shared = directory.path().join("shared.toml");
        let alias = directory.path().join("alias.toml");
        fs::write(
            &shared,
            "[feature_flags]\ncross_agent_memory_consolidation = true\n",
        )
        .unwrap();
        std::os::unix::fs::symlink(&shared, &alias).unwrap();
        fs::create_dir(directory.path().join("nested")).unwrap();
        fs::write(
            directory.path().join("nested/settings.toml"),
            "import = '../alias.toml'\n[experimental]\ncross_agent_memory_consolidation = false\n",
        )
        .unwrap();
        fs::write(&path, "import = ['shared.toml', 'nested/settings.toml']\n").unwrap();
        rename_experimental(&path).unwrap();
        assert!(fs::symlink_metadata(&alias).unwrap().is_symlink());
        assert!(
            fs::read_to_string(&shared)
                .unwrap()
                .contains("[experimental]")
        );
        assert!(
            !Config::load(&path)
                .config
                .experimental
                .cross_agent_memory_consolidation
        );
        fs::write(&path, "import = ['nested/settings.toml', 'shared.toml']\n").unwrap();
        assert!(
            Config::load(&path)
                .config
                .experimental
                .cross_agent_memory_consolidation
        );
        fs::write(
            &path,
            "import = 'shared.toml'\n[feature_flags]\ncross_agent_memory_consolidation = false\n",
        )
        .unwrap();
        rename_experimental(&path).unwrap();
        assert!(
            !Config::load(&path)
                .config
                .experimental
                .cross_agent_memory_consolidation
        );
    }

    #[test]
    fn malformed_graphs_do_not_partially_migrate() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        let shared = directory.path().join("shared.toml");
        let original = "[feature_flags]\ncross_agent_memory_consolidation = true\n";
        for invalid in [
            "import = ['shared.toml', 'missing.toml']\n",
            "import = ['shared.toml', 'config.toml']\n",
            "import = ['shared.toml', 4]\n",
            "import = [\n",
        ] {
            fs::write(&shared, original).unwrap();
            fs::write(&path, invalid).unwrap();
            rename_experimental(&path).unwrap();
            assert_eq!(fs::read_to_string(&shared).unwrap(), original);
            assert_eq!(fs::read_to_string(&path).unwrap(), invalid);
            assert_ne!(Config::load(&path).diagnostics, []);
        }
    }

    #[test]
    fn import_limits_leave_the_entire_graph_untouched() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        let shared = directory.path().join("shared.toml");
        let original = "[feature_flags]\ncross_agent_memory_consolidation = true\n";
        fs::write(&shared, original).unwrap();
        let imports = vec!["'shared.toml'"; MAX_DOCUMENTS].join(",");
        fs::write(&path, format!("import = [{imports}]\n")).unwrap();
        rename_experimental(&path).unwrap();
        assert_eq!(fs::read_to_string(&shared).unwrap(), original);
        for index in 0..=MAX_DEPTH {
            fs::write(
                directory.path().join(format!("{index}.toml")),
                format!("import = '{}.toml'\n{original}", index + 1),
            )
            .unwrap();
        }
        fs::write(&path, "import = '0.toml'\n").unwrap();
        rename_experimental(&path).unwrap();
        assert!(
            fs::read_to_string(directory.path().join("0.toml"))
                .unwrap()
                .contains("[feature_flags]")
        );
    }

    #[test]
    fn absent_and_canonical_sections_are_not_rewritten_and_retired_keys_stay_ignored() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        rename_experimental(&path).unwrap();
        assert!(!path.exists());
        for source in [
            "[terminal]\nfont_size = 17\n",
            "[experimental]\ntab_management = false\n",
        ] {
            fs::write(&path, source).unwrap();
            let before = fs::metadata(&path).unwrap().modified().unwrap();
            rename_experimental(&path).unwrap();
            assert_eq!(fs::read_to_string(&path).unwrap(), source);
            assert_eq!(fs::metadata(&path).unwrap().modified().unwrap(), before);
            let loaded = Config::load(&path);
            assert_eq!(loaded.diagnostics, []);
            assert!(!loaded.config.experimental.cross_agent_memory_consolidation);
        }
    }

    #[test]
    fn saves_preserve_permissions_bom_and_crlf_and_conflicts_preserve_external_edits() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        fs::write(
            &path,
            "\u{feff}[feature_flags]\r\ncross_agent_memory_consolidation = true\r\n",
        )
        .unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();
        rename_experimental(&path).unwrap();
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            "\u{feff}[experimental]\r\ncross_agent_memory_consolidation = true\r\n"
        );
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o640
        );
        fs::write(
            &path,
            "[feature_flags]\ncross_agent_memory_consolidation = false\n",
        )
        .unwrap();
        let mut migration = Migration::default();
        assert!(migration.visit(&path).unwrap());
        fs::write(&path, "# external edit\n").unwrap();
        assert!(migration.save().is_err());
        assert_eq!(fs::read_to_string(&path).unwrap(), "# external edit\n");
    }

    #[test]
    fn retry_finishes_after_a_read_only_import_interrupts_migration() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        let first = directory.path().join("first.toml");
        let second = directory.path().join("second.toml");
        let source = "[feature_flags]\ncross_agent_memory_consolidation = true\n";
        fs::write(&first, source).unwrap();
        fs::write(&second, source).unwrap();
        fs::write(&path, "import = ['first.toml', 'second.toml']\n").unwrap();
        fs::set_permissions(&second, fs::Permissions::from_mode(0o444)).unwrap();
        let error = rename_experimental(&path).unwrap_err();
        assert!(error.to_string().contains("second.toml"));
        let completed = fs::metadata(&first).unwrap().modified().unwrap();
        assert!(
            fs::read_to_string(&first)
                .unwrap()
                .contains("[experimental]")
        );
        assert_eq!(fs::read_to_string(&second).unwrap(), source);
        fs::set_permissions(&second, fs::Permissions::from_mode(0o644)).unwrap();
        rename_experimental(&path).unwrap();
        assert_eq!(fs::metadata(&first).unwrap().modified().unwrap(), completed);
        assert!(
            Config::load(&path)
                .config
                .experimental
                .cross_agent_memory_consolidation
        );
    }
}
