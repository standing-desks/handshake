//! Bounded Nouli auth.toml command credentials, using core's owned process cleanup.
use std::ffi::OsStr;
use std::io::{Read, Seek};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use tokio_util::sync::CancellationToken;

use crate::process::CommandChild;

const MAX_BYTES: u64 = 64 * 1024;
const TIMEOUT: Duration = Duration::from_secs(10);

pub(super) fn command(
    argv: &[String],
    folder: &Path,
    home: &Path,
    path: Option<&OsStr>,
    cancel: &CancellationToken,
) -> Option<String> {
    let (program, arguments) = argv.split_first()?;
    if cancel.is_cancelled() {
        return None;
    }
    let mut output = tempfile::tempfile().ok()?;
    let mut command = Command::new(program);
    command
        .args(arguments)
        .current_dir(folder)
        .env_clear()
        .env("HOME", home)
        .stdin(Stdio::null())
        .stdout(output.try_clone().ok()?)
        .stderr(Stdio::null());
    if let Some(path) = path {
        command.env("PATH", path);
    }
    let mut child = CommandChild::spawn(&mut command).ok()?;
    let deadline = Instant::now() + TIMEOUT;
    loop {
        if cancel.is_cancelled()
            || Instant::now() >= deadline
            || output.metadata().ok()?.len() > MAX_BYTES
        {
            return None;
        }
        if child.has_exited().ok()? {
            if !child.finish().ok()?.success() {
                return None;
            }
            break;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    output.rewind().ok()?;
    let mut bytes = Vec::new();
    output.take(MAX_BYTES + 1).read_to_end(&mut bytes).ok()?;
    if bytes.len() as u64 > MAX_BYTES {
        return None;
    }
    let text = String::from_utf8(bytes).ok()?;
    let key = text.trim();
    (!key.is_empty()).then(|| key.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cancelling_a_credential_command_stops_its_owned_process_tree() {
        let folder = tempfile::tempdir().unwrap();
        let argv = vec![
            "/bin/sh".into(),
            "-c".into(),
            "echo $$ > parent; sleep 60 & echo $! > descendant; wait".into(),
        ];
        let cancel = CancellationToken::new();
        let token = cancel.clone();
        let directory = folder.path().to_owned();
        let worker = std::thread::spawn(move || {
            command(
                &argv,
                &directory,
                &directory,
                Some(OsStr::new("/bin:/usr/bin")),
                &token,
            )
        });
        let deadline = Instant::now() + Duration::from_secs(5);
        while !folder.path().join("descendant").exists() {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(5));
        }
        let parent = crate::process::tests::FixtureProcess::read(&folder.path().join("parent"));
        let descendant =
            crate::process::tests::FixtureProcess::read(&folder.path().join("descendant"));
        cancel.cancel();
        assert!(worker.join().unwrap().is_none());
        parent.assert_stopped();
        descendant.assert_stopped();
    }
}
