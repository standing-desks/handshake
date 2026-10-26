use crate::harness::{HarnessId, LocatedHarness, steps::StepInbox};
use crate::memories::handshake::contains_session as contains;
use std::ffi::OsString;
use std::io;
use std::path::Path;

type MemoryEnvironment = (Vec<(String, String)>, Option<std::fs::File>);
impl super::Application {
    pub(super) fn memory_environment(
        &self,
        harness: HarnessId,
        folder: &Path,
    ) -> io::Result<MemoryEnvironment> {
        let Some(worker) = &self.memory_worker else {
            return Ok((Vec::new(), None));
        };
        if !worker.is_enabled() || !matches!(harness, HarnessId::Codex | HarnessId::ClaudeCode) {
            return Ok((Vec::new(), None));
        }
        let result = crate::memories::handshake::launch_environment(
            worker.directory(),
            folder,
            if harness == HarnessId::Codex {
                "codex"
            } else {
                "claude_code"
            },
            || worker.is_enabled() && crate::memories::handshake::feature_enabled(),
        );
        let (values, lease) = match result {
            Ok(values) => values,
            Err(crate::memories::handshake::Error::Disabled) => return Ok((Vec::new(), None)),
            Err(error) => return Err(io::Error::other(error)),
        };
        Ok((
            values
                .into_iter()
                .filter(|(key, _)| match harness {
                    HarnessId::Codex => key == "CODEX_HOME",
                    HarnessId::ClaudeCode => key == "HANDSHAKE_CLAUDE_MEMORY_DIRECTORY",
                    _ => false,
                })
                .collect(),
            Some(lease),
        ))
    }
    /// Legacy Codex sessions retain the native home containing their saved rollout.
    /// Claude's invocation-only memory setting does not relocate its session history or auth.
    pub(super) fn resume_memory_environment(
        &self,
        harness: HarnessId,
        folder: &Path,
        session: &str,
    ) -> io::Result<MemoryEnvironment> {
        let (environment, lease) = self.memory_environment(harness, folder)?;
        if harness != HarnessId::Codex {
            return Ok((environment, lease));
        }
        let Some((_, home)) = environment.iter().find(|(key, _)| key == "CODEX_HOME") else {
            if let Some(worker) = &self.memory_worker {
                return crate::memories::handshake::resume_codex_environment(
                    worker.directory(),
                    folder,
                    session,
                )
                .map(|result| {
                    result.map_or_else(
                        || (Vec::new(), None),
                        |(home, lease)| {
                            (
                                vec![("CODEX_HOME".into(), home.to_string_lossy().into_owned())],
                                Some(lease),
                            )
                        },
                    )
                })
                .map_err(io::Error::other);
            }
            return Ok((environment, lease));
        };
        if contains(&std::path::PathBuf::from(home).join("sessions"), session) {
            Ok((environment, lease))
        } else {
            tracing::warn!(
                "Legacy Codex session retains its original memory profile; start a fresh session for automatic Handshake memory."
            );
            Ok((Vec::new(), None))
        }
    }
    /// Merge the documented native directory setting with Handshake's existing observer hooks.
    pub(super) fn append_memory_settings(
        harness: HarnessId,
        environment: &[(String, String)],
        arguments: &mut Vec<OsString>,
    ) -> io::Result<()> {
        if harness != HarnessId::ClaudeCode {
            return Ok(());
        }
        let Some((_, memory)) = environment
            .iter()
            .find(|(key, _)| key == "HANDSHAKE_CLAUDE_MEMORY_DIRECTORY")
        else {
            return Ok(());
        };
        if let Some(index) = arguments.iter().position(|value| value == "--settings") {
            let original = arguments
                .get(index + 1)
                .ok_or_else(|| io::Error::other("Missing native Claude settings"))?
                .to_string_lossy();
            let bytes = if original.trim_start().starts_with('{') {
                original.as_bytes().to_vec()
            } else {
                std::fs::read(original.as_ref())?
            };
            let mut settings: serde_json::Value =
                serde_json::from_slice(&bytes).map_err(io::Error::other)?;
            settings
                .as_object_mut()
                .ok_or_else(|| io::Error::other("Invalid native Claude settings"))?
                .insert("autoMemoryDirectory".into(), serde_json::json!(memory));
            arguments[index + 1] = OsString::from(settings.to_string());
        } else {
            arguments.extend([
                OsString::from("--settings"),
                OsString::from(serde_json::json!({"autoMemoryDirectory":memory}).to_string()),
            ]);
        }
        Ok(())
    }
    /// Preserve workflow roles while leaving memory loading to each native harness.
    pub(super) fn append_agent_instructions(
        harness: HarnessId,
        role: &str,
        arguments: &mut Vec<OsString>,
        hooks: Option<&StepInbox>,
        located: &LocatedHarness,
        folder: &Path,
    ) -> io::Result<()> {
        if !role.is_empty() {
            crate::harness::instructions::append(harness, role, arguments, hooks, located, folder)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn native_memory_loading_does_not_add_catalog_paths_or_override_roles() {
        let temp = tempfile::tempdir().unwrap();
        let program = temp.path().join("codex");
        std::fs::write(&program, "#!/bin/sh\nread -r line\nprintf '%s\\n' '{\"id\":1,\"result\":{}}'\nread -r line\nread -r line\nprintf '%s\\n' '{\"id\":2,\"result\":{\"config\":{\"developer_instructions\":\"Existing user instruction\"}}}'\n").unwrap();
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
        let located = LocatedHarness {
            program,
            path: OsString::from("/usr/bin:/bin"),
        };
        for harness in [HarnessId::Codex, HarnessId::ClaudeCode] {
            let mut arguments = Vec::new();
            crate::Application::append_agent_instructions(
                harness,
                "",
                &mut arguments,
                None,
                &located,
                temp.path(),
            )
            .unwrap();
            assert_eq!(arguments, Vec::<OsString>::new());
            crate::Application::append_agent_instructions(
                harness,
                "Role instructions",
                &mut arguments,
                None,
                &located,
                temp.path(),
            )
            .unwrap();
            assert_eq!(arguments.len(), 2);
            assert!(!arguments.iter().any(|value| value == "--add-dir"));
            let text = arguments.last().unwrap().to_string_lossy();
            assert!(text.contains("Role instructions"));
            assert!(!text.contains("catalog"));
            if harness == HarnessId::Codex {
                assert!(text.contains("Existing user instruction"));
            }
        }
    }
    #[test]
    fn claude_memory_uses_native_settings_without_relocating_authentication() {
        let env = vec![(
            "HANDSHAKE_CLAUDE_MEMORY_DIRECTORY".into(),
            "/tmp/projects/twine-project/memory".into(),
        )];
        let mut args = Vec::new();
        crate::Application::append_memory_settings(HarnessId::ClaudeCode, &env, &mut args).unwrap();
        assert_eq!(args[0], "--settings");
        let settings: serde_json::Value = serde_json::from_str(&args[1].to_string_lossy()).unwrap();
        assert!(
            settings["autoMemoryDirectory"]
                .as_str()
                .unwrap()
                .ends_with("projects/twine-project/memory")
        );
        assert!(settings.get("autoMemoryEnabled").is_none());
    }
    #[test]
    fn native_memory_settings_preserve_observer_hooks() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("settings.json");
        let hooks = serde_json::json!({"hooks":{"Stop":[{"hooks":[{"type":"command","command":"twine-observe"}]}]}});
        std::fs::write(&path, hooks.to_string()).unwrap();
        let mut arguments = vec![OsString::from("--settings"), path.into_os_string()];
        let env = vec![(
            "HANDSHAKE_CLAUDE_MEMORY_DIRECTORY".into(),
            "/tmp/projects/twine-project/memory".into(),
        )];
        crate::Application::append_memory_settings(HarnessId::ClaudeCode, &env, &mut arguments)
            .unwrap();
        assert_eq!(arguments.len(), 2);
        let settings: serde_json::Value =
            serde_json::from_str(&arguments[1].to_string_lossy()).unwrap();
        assert_eq!(settings["hooks"], hooks["hooks"]);
        assert!(settings["autoMemoryDirectory"].is_string());
    }
}
