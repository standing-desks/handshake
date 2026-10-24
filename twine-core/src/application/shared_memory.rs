use std::ffi::OsString;
use std::io;
use std::path::Path;

use crate::harness::{HarnessId, LocatedHarness, steps::StepInbox};

impl super::Application {
    /// Add folder discovery without submitting a turn or changing native memory configuration.
    pub(super) fn append_agent_instructions(
        &self,
        harness: HarnessId,
        role: &str,
        arguments: &mut Vec<OsString>,
        hooks: Option<&StepInbox>,
        located: &LocatedHarness,
        folder: &Path,
    ) -> io::Result<()> {
        let shared = if matches!(harness, HarnessId::Codex | HarnessId::ClaudeCode) {
            self.shared_memory_directory
                .as_ref()
                .map(|data| {
                    crate::memories::shared::context(data, folder).map_err(io::Error::other)
                })
                .transpose()?
                .flatten()
        } else {
            None
        };
        let instructions = if let Some((context, exchange)) = shared {
            arguments.extend([OsString::from("--add-dir"), exchange.into_os_string()]);
            if role.is_empty() {
                context
            } else {
                format!("{role}\n\n{context}")
            }
        } else {
            role.into()
        };
        if !instructions.is_empty() {
            crate::harness::instructions::append(
                harness,
                &instructions,
                arguments,
                hooks,
                located,
                folder,
            )?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::memories::shared::{SharedOperation, SharedRequest, execute};
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn both_harnesses_get_the_same_folder_library_and_preserve_native_instructions() {
        let temp = tempfile::tempdir().unwrap();
        let folder = temp.path().join("folder");
        std::fs::create_dir(&folder).unwrap();
        let data = temp.path().join("data");
        execute(&SharedRequest {
            data_directory: data.clone(),
            folder: folder.clone(),
            action: SharedOperation::SetEnabled { enabled: true },
        })
        .unwrap();
        let program = temp.path().join("codex");
        std::fs::write(&program, "#!/bin/sh\nread -r line\nprintf '%s\\n' '{\"id\":1,\"result\":{}}'\nread -r line\nread -r line\nprintf '%s\\n' '{\"id\":2,\"result\":{\"config\":{\"developer_instructions\":\"Existing user instruction\"}}}'\n").unwrap();
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
        let located = LocatedHarness {
            program,
            path: OsString::from("/usr/bin:/bin"),
        };
        let mut application = crate::Application::with_event_capacity(128).unwrap();
        application.shared_memory_directory = Some(data);
        for harness in [HarnessId::Codex, HarnessId::ClaudeCode] {
            let mut arguments = Vec::new();
            application
                .append_agent_instructions(
                    harness,
                    "Role instructions",
                    &mut arguments,
                    None,
                    &located,
                    &folder,
                )
                .unwrap();
            assert_eq!(arguments[0], "--add-dir");
            let text = arguments.last().unwrap().to_string_lossy();
            assert!(text.contains("Role instructions"));
            assert!(text.contains("Twine shared folder memory"));
            if harness == HarnessId::Codex {
                assert!(text.contains("Existing user instruction"));
            }
            let mut other = Vec::new();
            application
                .append_agent_instructions(harness, "", &mut other, None, &located, temp.path())
                .unwrap();
            assert_eq!(other, Vec::<OsString>::new());
        }
    }
}
