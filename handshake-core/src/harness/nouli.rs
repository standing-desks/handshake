//! One owned, bounded Nouli CLI invocation. Structured stdout never enters a terminal parser.
use std::fs::File;
use std::io::{Read, Seek, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::Value;
use thiserror::Error;

use super::LocatedHarness;
use crate::process::CommandChild;
use crate::workflow_type::DecisionNode;

const MAX_OUTPUT: u64 = 2 * 1024 * 1024;
const TIMEOUT: Duration = Duration::from_secs(600);

#[derive(Debug, Error)]
pub(crate) enum NouliError {
    #[error("Could not run Nouli. Check its installation and provider configuration.")]
    Io(#[from] std::io::Error),
    #[error("Nouli failed. Check its provider configuration before explicitly retrying.")]
    Failed,
    #[error("Nouli exceeded the decision time or output limit.")]
    Limit,
    #[error("Nouli returned an invalid decision report.")]
    Report,
}

pub(crate) struct Invocation {
    child: CommandChild,
    output: File,
    started: Instant,
    completed: Option<Result<Value, String>>,
}

impl Invocation {
    pub(crate) fn start(
        located: &LocatedHarness,
        folder: &Path,
        node: &DecisionNode,
        request: &Value,
    ) -> Result<Self, NouliError> {
        let bytes = serde_json::to_vec(request).map_err(|_| NouliError::Report)?;
        if bytes.len() > 128 * 1024 {
            return Err(NouliError::Limit);
        }
        let mut input = tempfile::tempfile()?;
        input.write_all(&bytes)?;
        input.rewind()?;
        let output = tempfile::tempfile()?;
        let mut command = Command::new(&located.program);
        command
            .current_dir(folder)
            .env("PATH", &located.path)
            .args([
                "--input",
                "-",
                "--input-format",
                "json",
                "--json",
                "--no-session",
            ])
            .stdin(Stdio::from(input))
            .stdout(Stdio::from(output.try_clone()?))
            .stderr(Stdio::null());
        if let Some(provider) = &node.provider {
            command.arg("--provider").arg(provider);
        }
        if let Some(model) = &node.model {
            command.arg("--model").arg(model);
        }
        Ok(Self {
            child: CommandChild::spawn(&mut command)?,
            output,
            started: Instant::now(),
            completed: None,
        })
    }

    pub(crate) fn poll(&mut self) -> Option<Result<Value, String>> {
        if self.completed.is_none() {
            match self.check() {
                Ok(None) => return None,
                Ok(Some(value)) => self.completed = Some(Ok(value)),
                Err(error) => self.completed = Some(Err(error.to_string())),
            }
        }
        self.completed.clone()
    }

    fn check(&mut self) -> Result<Option<Value>, NouliError> {
        if self.started.elapsed() > TIMEOUT || self.output.metadata()?.len() > MAX_OUTPUT {
            return Err(NouliError::Limit);
        }
        if !self.child.has_exited()? {
            return Ok(None);
        }
        if !self.child.finish()?.success() {
            return Err(NouliError::Failed);
        }
        self.output.rewind()?;
        let mut bytes = Vec::new();
        Read::by_ref(&mut self.output)
            .take(MAX_OUTPUT + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() as u64 > MAX_OUTPUT {
            return Err(NouliError::Limit);
        }
        serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|_| NouliError::Report)
    }
}
