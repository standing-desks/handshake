//! Receiver-owned feature flags, persisted through the versioned settings-file editor.
use std::path::Path;

use serde::{Deserialize, Serialize};

use super::{Config, ConfigEditError, ConfigProblem, editing};
use crate::{FileContent, FilePreview, FileSaveOutcome, FileSaveRequest, FileVersion};

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(default)]
pub struct FeatureFlags {
    pub cross_agent_memory_consolidation: bool,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum FeatureFlag {
    CrossAgentMemoryConsolidation,
}

#[derive(Debug, Serialize)]
pub struct FeatureFlagState {
    pub id: FeatureFlag,
    pub title: &'static str,
    pub description: &'static str,
    pub enabled: bool,
}

pub struct FeatureFlagSnapshot {
    pub flags: Vec<FeatureFlagState>,
    pub file: FilePreview,
}

impl FeatureFlag {
    const ALL: [Self; 1] = [Self::CrossAgentMemoryConsolidation];

    fn key(self) -> &'static str {
        match self {
            Self::CrossAgentMemoryConsolidation => "cross_agent_memory_consolidation",
        }
    }

    fn state(self, flags: &FeatureFlags) -> FeatureFlagState {
        match self {
            Self::CrossAgentMemoryConsolidation => FeatureFlagState {
                id: self,
                title: "Cross-agent memory consolidation",
                description: "Automatically share and consolidate project memories between supported agents.",
                enabled: flags.cross_agent_memory_consolidation,
            },
        }
    }
}

/// Reads the flag catalog and effective values, including imported configuration.
/// # Errors
/// Rejects invalid configuration rather than displaying fallback values as saved settings.
pub fn read_feature_flags() -> Result<FeatureFlagSnapshot, ConfigEditError> {
    snapshot(super::read_user_file()?)
}

fn snapshot(file: FilePreview) -> Result<FeatureFlagSnapshot, ConfigEditError> {
    let FileContent::Text(source) = &file.content else {
        return Err(ConfigEditError::FeatureFlags(
            "Open a readable text configuration first.".into(),
        ));
    };
    let loaded = Config::load_source(&file.path, source);
    if let Some(problem) = loaded
        .diagnostics
        .into_iter()
        .find(|d| d.problem != ConfigProblem::UnknownKey)
    {
        return Err(ConfigEditError::InvalidConfig(problem));
    }
    Ok(FeatureFlagSnapshot {
        flags: FeatureFlag::ALL
            .into_iter()
            .map(|flag| flag.state(&loaded.config.feature_flags))
            .collect(),
        file,
    })
}

/// Changes one root setting while preserving other settings, comments and conflict protection.
/// # Errors
/// Returns the settings editor's read, validation or write error. Concurrent edits return a conflict.
pub fn set_feature_flag(
    flag: FeatureFlag,
    enabled: bool,
    expected: FileVersion,
) -> Result<FileSaveOutcome, ConfigEditError> {
    Config::prepare_user()?;
    let path = Config::user_path().ok_or(ConfigEditError::MissingDirectory)?;
    set_at(&path, flag, enabled, expected)
}

fn set_at(
    path: &Path,
    flag: FeatureFlag,
    enabled: bool,
    expected: FileVersion,
) -> Result<FileSaveOutcome, ConfigEditError> {
    let file = editing::read_file(path)?;
    if file.version.as_ref() != Some(&expected) {
        return Ok(FileSaveOutcome::Conflict(file));
    }
    let snapshot = snapshot(file)?;
    let FileContent::Text(source) = &snapshot.file.content else {
        unreachable!("snapshot requires text")
    };
    let mut document = source
        .parse::<toml_edit::DocumentMut>()
        .map_err(|error| ConfigEditError::FeatureFlags(error.to_string()))?;
    let flags = document
        .entry("feature_flags")
        .or_insert(toml_edit::table());
    let mut value = toml_edit::value(enabled);
    if let Some(existing) = flags.get(flag.key()).and_then(toml_edit::Item::as_value)
        && let Some(new) = value.as_value_mut()
    {
        *new.decor_mut() = existing.decor().clone();
    }
    flags[flag.key()] = value;
    let request = FileSaveRequest {
        folder: snapshot
            .file
            .path
            .parent()
            .ok_or(ConfigEditError::InvalidPath)?
            .to_owned(),
        path: snapshot.file.path,
        text: document.to_string(),
        expected_version: expected,
        overwrite: false,
    };
    editing::save_file(path, &request)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn defaults_are_off_and_toggling_preserves_comments_and_other_settings() {
        assert!(
            !Config::default()
                .feature_flags
                .cross_agent_memory_consolidation
        );
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config.toml");
        let original = "# Personal settings\n[terminal]\nfont_size = 17 # keep my size\n[feature_flags]\ncross_agent_memory_consolidation = false # my experiment\n";
        fs::write(&path, original).unwrap();
        let file = editing::read_file(&path).unwrap();
        let result = set_at(
            &path,
            FeatureFlag::CrossAgentMemoryConsolidation,
            true,
            file.version.unwrap(),
        )
        .unwrap();
        assert!(matches!(result, FileSaveOutcome::Saved(_)));
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            original.replace("false #", "true #")
        );
        let saved = snapshot(editing::read_file(&path).unwrap()).unwrap();
        assert!(saved.flags[0].enabled);
        assert_eq!(Config::load(&path).config.terminal.font_size.points(), 17.0);
    }

    #[test]
    fn root_toggle_overrides_imports_and_refuses_a_concurrent_edit() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config.toml");
        fs::write(
            root.path().join("base.toml"),
            "[feature_flags]\ncross_agent_memory_consolidation = true\n",
        )
        .unwrap();
        fs::write(&path, "import = 'base.toml'\n# retained\n").unwrap();
        let read = snapshot(editing::read_file(&path).unwrap()).unwrap();
        assert!(read.flags[0].enabled);
        set_at(
            &path,
            FeatureFlag::CrossAgentMemoryConsolidation,
            false,
            read.file.version.unwrap(),
        )
        .unwrap();
        assert!(!snapshot(editing::read_file(&path).unwrap()).unwrap().flags[0].enabled);
        let old = editing::read_file(&path).unwrap().version.unwrap();
        fs::write(&path, "# external writer\n").unwrap();
        assert!(matches!(
            set_at(&path, FeatureFlag::CrossAgentMemoryConsolidation, true, old).unwrap(),
            FileSaveOutcome::Conflict(_)
        ));
        assert_eq!(fs::read_to_string(&path).unwrap(), "# external writer\n");
    }

    #[test]
    fn inline_and_dotted_flags_stay_valid_and_invalid_settings_are_held() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config.toml");
        for text in [
            "feature_flags = { cross_agent_memory_consolidation = false } # keep\n",
            "feature_flags.cross_agent_memory_consolidation = false\n",
            "[terminal]\nfont_size = 16\n",
        ] {
            fs::write(&path, text).unwrap();
            let file = editing::read_file(&path).unwrap();
            set_at(
                &path,
                FeatureFlag::CrossAgentMemoryConsolidation,
                true,
                file.version.unwrap(),
            )
            .unwrap();
            assert!(snapshot(editing::read_file(&path).unwrap()).unwrap().flags[0].enabled);
        }
        fs::write(&path, "[terminal]\nfont_size = 1000\n").unwrap();
        let file = editing::read_file(&path).unwrap();
        assert!(
            set_at(
                &path,
                FeatureFlag::CrossAgentMemoryConsolidation,
                true,
                file.version.unwrap()
            )
            .is_err()
        );
        assert!(fs::read_to_string(&path).unwrap().contains("1000"));
    }
}
