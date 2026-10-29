//! Receiver-owned experimental features, persisted through the versioned settings-file editor.
use std::path::Path;

use serde::{Deserialize, Serialize};

use super::{Config, ConfigEditError, ConfigProblem, editing};
use crate::{FileContent, FilePreview, FileSaveOutcome, FileSaveRequest, FileVersion};

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(default)]
pub struct ExperimentalConfig {
    pub cross_agent_memory_consolidation: bool,
    pub browser_control: bool,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ExperimentalFeature {
    CrossAgentMemoryConsolidation,
    BrowserControl,
}

#[derive(Debug, Serialize)]
pub struct ExperimentalFeatureState {
    pub id: ExperimentalFeature,
    pub title: &'static str,
    pub description: &'static str,
    pub enabled: bool,
}

pub struct ExperimentalSnapshot {
    pub features: Vec<ExperimentalFeatureState>,
    pub file: FilePreview,
}

impl ExperimentalFeature {
    const ALL: [Self; 2] = [Self::CrossAgentMemoryConsolidation, Self::BrowserControl];

    fn key(self) -> &'static str {
        match self {
            Self::CrossAgentMemoryConsolidation => "cross_agent_memory_consolidation",
            Self::BrowserControl => "browser_control",
        }
    }

    fn state(self, features: &ExperimentalConfig) -> ExperimentalFeatureState {
        match self {
            Self::BrowserControl => ExperimentalFeatureState {
                id: self,
                title: "Agent browser control",
                description: "Let agents use the embedded browser. Start a new agent or terminal after enabling. Turning this off immediately revokes browser control and keeps pages open.",
                enabled: features.browser_control,
            },
            Self::CrossAgentMemoryConsolidation => ExperimentalFeatureState {
                id: self,
                title: "Cross-agent memory consolidation",
                description: "Automatically share and consolidate project memories between supported agents.",
                enabled: features.cross_agent_memory_consolidation,
            },
        }
    }
}

/// Reads the experimental feature catalog and effective values, including imported configuration.
/// # Errors
/// Rejects invalid configuration rather than displaying fallback values as saved settings.
pub fn read_experimental() -> Result<ExperimentalSnapshot, ConfigEditError> {
    snapshot(super::read_user_file()?)
}

fn snapshot(file: FilePreview) -> Result<ExperimentalSnapshot, ConfigEditError> {
    let FileContent::Text(source) = &file.content else {
        return Err(ConfigEditError::Experimental(
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
    Ok(ExperimentalSnapshot {
        features: ExperimentalFeature::ALL
            .into_iter()
            .map(|feature| feature.state(&loaded.config.experimental))
            .collect(),
        file,
    })
}

/// Changes one root setting while preserving other settings, comments and conflict protection.
/// # Errors
/// Returns the settings editor's read, validation or write error. Concurrent edits return a conflict.
pub fn set_experimental_feature(
    feature: ExperimentalFeature,
    enabled: bool,
    expected: FileVersion,
) -> Result<FileSaveOutcome, ConfigEditError> {
    Config::prepare_user()?;
    let path = Config::user_path().ok_or(ConfigEditError::MissingDirectory)?;
    set_at(&path, feature, enabled, expected)
}

fn set_at(
    path: &Path,
    feature: ExperimentalFeature,
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
        .map_err(|error| ConfigEditError::Experimental(error.to_string()))?;
    let features = document.entry("experimental").or_insert(toml_edit::table());
    let mut value = toml_edit::value(enabled);
    if let Some(existing) = features
        .get(feature.key())
        .and_then(toml_edit::Item::as_value)
        && let Some(new) = value.as_value_mut()
    {
        *new.decor_mut() = existing.decor().clone();
    }
    features[feature.key()] = value;
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
    fn retired_tab_settings_are_ignored_and_memory_remains_opt_in() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config.toml");
        for retired in [false, true] {
            for memory in [None, Some(false), Some(true)] {
                let source = format!(
                    "[experimental]\ntab_management = {retired}\n{}",
                    memory.map_or_else(String::new, |enabled| format!(
                        "cross_agent_memory_consolidation = {enabled}\n"
                    ))
                );
                let loaded = Config::load_source(&path, &source);
                assert_eq!(loaded.diagnostics, []);
                assert_eq!(
                    loaded.config.experimental.cross_agent_memory_consolidation,
                    memory.unwrap_or(false)
                );
                let features = ExperimentalFeature::ALL
                    .map(|feature| feature.state(&loaded.config.experimental));
                assert_eq!(features.len(), 2);
                assert_eq!(features[1].id, ExperimentalFeature::BrowserControl);
                assert!(!features[1].enabled);
                assert_eq!(
                    features[0].id,
                    ExperimentalFeature::CrossAgentMemoryConsolidation
                );
                assert_eq!(features[0].enabled, memory.unwrap_or(false));
            }
        }
    }

    #[test]
    fn defaults_are_off_and_toggling_preserves_comments_and_other_settings() {
        assert!(
            !Config::default()
                .experimental
                .cross_agent_memory_consolidation
        );
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config.toml");
        let original = "# Personal settings\n[terminal]\nfont_size = 17 # keep my size\n[experimental]\ncross_agent_memory_consolidation = false # my experiment\n";
        fs::write(&path, original).unwrap();
        let file = editing::read_file(&path).unwrap();
        let result = set_at(
            &path,
            ExperimentalFeature::CrossAgentMemoryConsolidation,
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
        assert!(saved.features[0].enabled);
        assert_eq!(Config::load(&path).config.terminal.font_size.points(), 17.0);
    }

    #[test]
    fn root_toggle_overrides_imports_and_refuses_a_concurrent_edit() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config.toml");
        fs::write(
            root.path().join("base.toml"),
            "[experimental]\ncross_agent_memory_consolidation = true\n",
        )
        .unwrap();
        fs::write(&path, "import = 'base.toml'\n# retained\n").unwrap();
        let read = snapshot(editing::read_file(&path).unwrap()).unwrap();
        assert!(read.features[0].enabled);
        set_at(
            &path,
            ExperimentalFeature::CrossAgentMemoryConsolidation,
            false,
            read.file.version.unwrap(),
        )
        .unwrap();
        assert!(
            !snapshot(editing::read_file(&path).unwrap())
                .unwrap()
                .features[0]
                .enabled
        );
        let old = editing::read_file(&path).unwrap().version.unwrap();
        fs::write(&path, "# external writer\n").unwrap();
        assert!(matches!(
            set_at(
                &path,
                ExperimentalFeature::CrossAgentMemoryConsolidation,
                true,
                old
            )
            .unwrap(),
            FileSaveOutcome::Conflict(_)
        ));
        assert_eq!(fs::read_to_string(&path).unwrap(), "# external writer\n");
    }

    #[test]
    fn inline_and_dotted_features_stay_valid_and_invalid_settings_are_held() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config.toml");
        for text in [
            "experimental = { cross_agent_memory_consolidation = false } # keep\n",
            "experimental.cross_agent_memory_consolidation = false\n",
            "[terminal]\nfont_size = 16\n",
        ] {
            fs::write(&path, text).unwrap();
            let file = editing::read_file(&path).unwrap();
            set_at(
                &path,
                ExperimentalFeature::CrossAgentMemoryConsolidation,
                true,
                file.version.unwrap(),
            )
            .unwrap();
            assert!(
                snapshot(editing::read_file(&path).unwrap())
                    .unwrap()
                    .features[0]
                    .enabled
            );
        }
        fs::write(&path, "[terminal]\nfont_size = 1000\n").unwrap();
        let file = editing::read_file(&path).unwrap();
        assert!(
            set_at(
                &path,
                ExperimentalFeature::CrossAgentMemoryConsolidation,
                true,
                file.version.unwrap()
            )
            .is_err()
        );
        assert!(fs::read_to_string(&path).unwrap().contains("1000"));
    }
}
