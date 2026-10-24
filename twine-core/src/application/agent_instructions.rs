use std::ffi::OsString;
use std::io;
use std::path::Path;

use crate::harness::{HarnessId, LocatedHarness, steps::StepInbox};

impl super::Application {
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
}
