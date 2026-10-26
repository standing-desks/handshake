//! Handshake-owned shell hooks and their bounded OSC 133 decoder. No terminal text is interpreted.

use std::path::Path;

use portable_pty::CommandBuilder;

use super::TerminalError;

const MAX_MARK_BYTES: usize = 128 * 1024;

pub(super) struct ShellIntegration {
    _directory: tempfile::TempDir,
    pub token: String,
}

impl ShellIntegration {
    pub fn prepare(
        shell: &Path,
        command: &mut CommandBuilder,
    ) -> Result<Option<Self>, TerminalError> {
        let Some(name @ ("zsh" | "bash" | "fish")) =
            shell.file_name().and_then(|name| name.to_str())
        else {
            return Ok(None);
        };
        let directory = tempfile::Builder::new()
            .prefix("handshake-shell-")
            .tempdir()
            .map_err(integration_error)?;
        let token = directory
            .path()
            .file_name()
            .unwrap()
            .to_string_lossy()
            .into_owned();
        let script = match name {
            "zsh" => include_str!("shell/zsh"),
            "bash" => include_str!("shell/bash"),
            _ => include_str!("shell/fish"),
        }
        .replace("@TOKEN@", &token);
        std::fs::write(directory.path().join("integration"), script).map_err(integration_error)?;
        match name {
            "zsh" => {
                // Restore the user's ZDOTDIR while sourcing their files; redirect only the next
                // startup file. Nested shells see the user's original environment.
                for (file, next) in [
                    (".zshenv", true),
                    (".zprofile", true),
                    (".zshrc", true),
                    (".zlogin", false),
                ] {
                    let wrapper = format!(
                        "ZDOTDIR=$HANDSHAKE_USER_ZDOTDIR\n[[ -r $ZDOTDIR/{file} ]] && source $ZDOTDIR/{file}\nHANDSHAKE_USER_ZDOTDIR=${{ZDOTDIR:-$HOME}}\n{}\n",
                        if next {
                            "ZDOTDIR=$HANDSHAKE_INTEGRATION_DIR"
                        } else {
                            "source $HANDSHAKE_INTEGRATION_DIR/integration\nunset HANDSHAKE_USER_ZDOTDIR HANDSHAKE_INTEGRATION_DIR"
                        }
                    );
                    std::fs::write(directory.path().join(file), wrapper)
                        .map_err(integration_error)?;
                }
                command.env(
                    "HANDSHAKE_USER_ZDOTDIR",
                    std::env::var_os("ZDOTDIR")
                        .unwrap_or_else(|| std::env::var_os("HOME").unwrap_or_default()),
                );
                command.env("HANDSHAKE_INTEGRATION_DIR", directory.path());
                command.env("ZDOTDIR", directory.path());
                command.arg("-il");
            }
            "bash" => {
                // Bash 3.2 ignores ENV unless invoked as sh, and login shells ignore --rcfile.
                // A temporary login profile restores HOME before reading the user's profile.
                let profile = format!(
                    "if [[ $HISTFILE == $HOME/.bash_history ]]; then HISTFILE=$HANDSHAKE_USER_HOME/.bash_history; fi\nHOME=$HANDSHAKE_USER_HOME\nunset HANDSHAKE_USER_HOME\nsource '{}'\n",
                    directory.path().join("integration").display()
                );
                std::fs::write(directory.path().join(".bash_profile"), profile)
                    .map_err(integration_error)?;
                command.env(
                    "HANDSHAKE_USER_HOME",
                    std::env::var_os("HOME").unwrap_or_default(),
                );
                command.env("HOME", directory.path());
                command.arg("-il");
            }
            _ => {
                command.arg("-il");
                command.arg("--init-command");
                command.arg(format!(
                    "source '{}'",
                    directory.path().join("integration").display()
                ));
            }
        }
        Ok(Some(Self {
            _directory: directory,
            token,
        }))
    }
}

#[expect(
    clippy::needless_pass_by_value,
    reason = "map_err consumes the I/O error"
)]
fn integration_error(error: std::io::Error) -> TerminalError {
    TerminalError::Pty {
        operation: "prepare shell integration",
        message: error.to_string(),
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum ShellMark {
    Prompt,
    CommandStart(String),
    CommandEnd(u32),
    Lost,
    Stopped(String),
}

pub(super) struct ShellDecoder {
    token: String,
    buffer: Vec<u8>,
    state: u8,
}

impl ShellDecoder {
    pub fn new(token: String) -> Self {
        Self {
            token,
            buffer: Vec::new(),
            state: 0,
        }
    }

    pub fn feed(&mut self, bytes: &[u8], offset: u64) -> Vec<(ShellMark, u64)> {
        let mut marks = Vec::new();
        for (index, &byte) in bytes.iter().enumerate() {
            match (self.state, byte) {
                (1, b']') => {
                    self.state = 2;
                    self.buffer.clear();
                }
                (2, 7) | (3, b'\\') => {
                    if let Some(mark) = self.decode() {
                        marks.push((mark, offset + index as u64 + 1));
                    }
                    self.state = 0;
                    self.buffer.clear();
                }
                (2, 0x1b) => self.state = 3,
                (2, _) if self.buffer.len() < MAX_MARK_BYTES => self.buffer.push(byte),
                (2, _) => {
                    self.state = 0;
                    self.buffer.clear();
                }
                (_, 0x1b) => self.state = 1,
                _ => self.state = 0,
            }
        }
        marks
    }

    fn decode(&self) -> Option<ShellMark> {
        let text = std::str::from_utf8(&self.buffer).ok()?;
        let mut parts = text.strip_prefix("133;")?.split(';');
        let kind = parts.next()?;
        if parts.next()? != format!("handshake={}", self.token) {
            return None;
        }
        match kind {
            "A" if parts.next().is_none() => Some(ShellMark::Prompt),
            "L" if parts.next().is_none() => Some(ShellMark::Lost),
            "C" => {
                let hex = parts.next()?.strip_prefix("command=")?;
                if hex.is_empty() || hex.len() % 2 != 0 || parts.next().is_some() {
                    return None;
                }
                let bytes = (0..hex.len())
                    .step_by(2)
                    .map(|i| u8::from_str_radix(hex.get(i..i + 2)?, 16).ok())
                    .collect::<Option<Vec<_>>>()?;
                String::from_utf8(bytes).ok().map(ShellMark::CommandStart)
            }
            "D" => {
                let status = parts.next()?.parse().ok()?;
                parts
                    .next()
                    .is_none()
                    .then_some(ShellMark::CommandEnd(status))
            }
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_our_marks_decode_at_every_chunk_boundary() {
        let bytes = b"text\x1b]133;A;twine=test\x07\x1b]133;C;twine=test;command=66616c7365\x07\x1b]133;D;twine=test;1\x07\x1b]133;C\x07\x1b]133;A;handshake=other\x07\x1b]133;C;handshake=test;command=6563686f20e29883\x1b\\output\x1b]133;D;handshake=test;7\x07";
        for split in 0..=bytes.len() {
            let mut decoder = ShellDecoder::new("test".into());
            let mut marks = decoder.feed(&bytes[..split], 0);
            marks.extend(decoder.feed(&bytes[split..], split as u64));
            assert_eq!(marks.len(), 2);
            assert_eq!(marks[0].0, ShellMark::CommandStart("echo ☃".into()));
            assert_eq!(
                &bytes[usize::try_from(marks[0].1).unwrap()..][..6],
                b"output"
            );
            assert_eq!(marks[1], (ShellMark::CommandEnd(7), bytes.len() as u64));
        }
    }

    #[test]
    fn malformed_and_oversized_marks_are_ignored_and_decoder_recovers() {
        let mut decoder = ShellDecoder::new("test".into());
        assert_eq!(
            decoder.feed(
                b"\x1b]133;C;handshake=test;command=gg\x07\x1b]133;D;handshake=test;x\x07",
                0
            ),
            []
        );
        let mut bytes = b"\x1b]".to_vec();
        bytes.extend(vec![b'x'; MAX_MARK_BYTES + 1]);
        bytes.extend(b"\x07\x1b]133;A;handshake=test\x07");
        assert_eq!(
            decoder.feed(&bytes, 0),
            vec![(ShellMark::Prompt, bytes.len() as u64)]
        );
    }
}
