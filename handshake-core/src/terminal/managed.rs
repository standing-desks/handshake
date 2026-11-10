//! A harness invocation inside a persistent shell, with an explicit exit receipt.
use std::ffi::{OsStr, OsString};
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use super::manager::{ExitCallback, TerminalObservation};
use super::{TerminalExit, TerminalId};

pub(super) struct ManagedProgram {
    directory: tempfile::TempDir,
    callback: ExitCallback,
    delivered: AtomicBool,
    control: Mutex<()>,
    native: Mutex<Option<(libc::pid_t, (u64, u64))>>,
}
impl ManagedProgram {
    pub(super) fn prepare(
        program: &Path,
        arguments: &[OsString],
        path: &OsStr,
        environment: &[(&str, &str)],
        callback: ExitCallback,
    ) -> io::Result<Self> {
        let directory = tempfile::Builder::new()
            .prefix("handshake-invocation-")
            .tempdir()?;
        let mut native = b"#!/bin/sh\nprintf '%s' \"$$\" > ".to_vec();
        quote(&mut native, directory.path().join("native").as_os_str());
        native.extend_from_slice(b"\n_handshake_wait=0\nwhile [ ! -f ");
        quote(&mut native, directory.path().join("ready").as_os_str());
        native.extend_from_slice(b" ] && [ \"$_handshake_wait\" -lt 100 ]; do sleep 0.02; _handshake_wait=$((_handshake_wait + 1)); done\n[ -f ");
        quote(&mut native, directory.path().join("ready").as_os_str());
        native.extend_from_slice(b" ] || exit 125\n(\n");
        for (key, value) in std::iter::once(("PATH", path)).chain(
            environment
                .iter()
                .map(|(key, value)| (*key, OsStr::new(value))),
        ) {
            // Environment keys are supplied by Handshake, never by the model or terminal.
            native.extend_from_slice(format!("export {key}=").as_bytes());
            quote(&mut native, value);
            native.push(b'\n');
        }
        native.extend_from_slice(b"exec ");
        quote(&mut native, program.as_os_str());
        for argument in arguments {
            native.push(b' ');
            quote(&mut native, argument);
        }
        native
            .extend_from_slice(b"\n)\n_handshake_status=$?\nprintf '%s' \"$_handshake_status\" > ");
        quote(
            &mut native,
            directory.path().join("native-exit").as_os_str(),
        );
        native.extend_from_slice(b"\n_handshake_wait=0\nwhile [ ! -f ");
        quote(&mut native, directory.path().join("release").as_os_str());
        native.extend_from_slice(b" ] && [ \"$_handshake_wait\" -lt 100 ]; do sleep 0.02; _handshake_wait=$((_handshake_wait + 1)); done\nexit \"$_handshake_status\"\n");
        let runner = directory.path().join("run");
        std::fs::write(&runner, native)?;
        std::fs::set_permissions(&runner, std::fs::Permissions::from_mode(0o700))?;
        let mut script = b"#!/bin/sh\n_handshake_tty=$(stty -g 2>/dev/null)\n".to_vec();
        quote(&mut script, runner.as_os_str());
        script.extend_from_slice(b"\n_handshake_status=$?\n[ -z \"$_handshake_tty\" ] || stty \"$_handshake_tty\" 2>/dev/null\nprintf '\\033[?1049l\\033[?25h'\nprintf '%s' \"$_handshake_status\" > ");
        quote(&mut script, directory.path().join("exit.tmp").as_os_str());
        script.extend_from_slice(b"\nmv -- ");
        quote(&mut script, directory.path().join("exit.tmp").as_os_str());
        script.push(b' ');
        quote(&mut script, directory.path().join("exit").as_os_str());
        script.extend_from_slice(b"\n_handshake_wait=0\nwhile [ ! -f ");
        quote(&mut script, directory.path().join("retired").as_os_str());
        script.extend_from_slice(b" ] && [ \"$_handshake_wait\" -lt 100 ]; do sleep 0.02; _handshake_wait=$((_handshake_wait + 1)); done\n");
        script.extend_from_slice(b"\nprintf '\\r\\nAgent exited. You can use this shell or resume the conversation.\\r\\n'\n");
        let command = directory.path().join("launch");
        std::fs::write(&command, script)?;
        std::fs::set_permissions(&command, std::fs::Permissions::from_mode(0o700))?;
        Ok(Self {
            directory,
            callback,
            delivered: AtomicBool::new(false),
            control: Mutex::new(()),
            native: Mutex::new(None),
        })
    }
    pub(super) fn command(&self) -> &Path {
        self.directory.path()
    }
    pub(super) fn input_guard(&self) -> super::input::InvocationInputGuard {
        super::input::InvocationInputGuard {
            ended: self.directory.path().join("native-exit"),
            stopping: self.directory.path().join("stopping"),
            ready: self.directory.path().join("ready"),
            bound: self.native.lock().is_ok_and(|native| native.is_some()),
        }
    }
    pub(super) fn ended(&self) -> bool {
        self.delivered.load(Ordering::Acquire) || self.directory.path().join("exit").exists()
    }
    pub(super) fn running(&self) -> bool {
        let stopped_before_start = self.directory.path().join("stopping").exists()
            && self.native.lock().is_ok_and(|native| native.is_none());
        !(self.ended() || stopped_before_start)
    }
    pub(super) fn ready(&self) -> bool {
        self.running()
            && self.directory.path().join("ready").exists()
            && !self.directory.path().join("stopping").exists()
    }
    fn bind_native(&self, shell: libc::pid_t) -> io::Result<bool> {
        let mut native = self
            .native
            .lock()
            .map_err(|_| io::Error::other("harness identity poisoned"))?;
        if native.is_some() {
            return Ok(false);
        }
        let Ok(value) = std::fs::read_to_string(self.directory.path().join("native")) else {
            return Ok(false);
        };
        let Ok(pid) = value.parse::<libc::pid_t>() else {
            return Ok(false);
        };
        let Some(info) = super::process::native_process(pid)? else {
            return Ok(false);
        };
        if pid == shell || unsafe { libc::getsid(pid) } != shell {
            return Err(io::Error::other("native runner belongs to another shell"));
        }
        *native = Some((pid, info.started));
        if !self.directory.path().join("stopping").exists() {
            std::fs::write(self.directory.path().join("ready"), [])?;
        }
        Ok(true)
    }
    fn stop_native(&self, shell: libc::pid_t) -> io::Result<()> {
        if let Some((pid, started)) = *self
            .native
            .lock()
            .map_err(|_| io::Error::other("harness identity poisoned"))?
            && let Err(error) = super::process::force_stop_harness_children(pid, shell, started)
        {
            let _ = std::fs::remove_file(self.directory.path().join("stopping"));
            return Err(error);
        }
        Ok(())
    }
    /// The wrapper restores the same TTY after its pinned native runner is stopped.
    pub(super) fn force_stop(&self, shell_pid: libc::pid_t) -> io::Result<()> {
        let _control = self
            .control
            .lock()
            .map_err(|_| io::Error::other("harness control poisoned"))?;
        if !self.running() {
            return Ok(());
        }
        std::fs::write(self.directory.path().join("stopping"), [])?;
        if self
            .native
            .lock()
            .map_err(|_| io::Error::other("harness identity poisoned"))?
            .is_none()
        {
            // The pending runner cannot execute native work before identity validation.
            return Ok(());
        }
        if self.directory.path().join("native-exit").exists() {
            std::fs::write(self.directory.path().join("release"), [])?;
        } else {
            self.stop_native(shell_pid)?;
        }
        let deadline = Instant::now() + Duration::from_secs(2);
        while self.running() {
            if self.directory.path().join("native-exit").exists() {
                std::fs::write(self.directory.path().join("release"), [])?;
            }
            if Instant::now() >= deadline {
                return Err(io::Error::other("harness did not confirm its stop"));
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        Ok(())
    }
    pub(super) fn service_startup(&self, shell: libc::pid_t) {
        let Ok(_control) = self.control.try_lock() else {
            return;
        };
        self.service_startup_locked(shell);
    }
    fn service_startup_locked(&self, shell: libc::pid_t) {
        if self.delivered.load(Ordering::Acquire) {
            return;
        }
        match self.bind_native(shell) {
            Ok(true) if self.directory.path().join("stopping").exists() => {
                if let Err(error) = self.stop_native(shell) {
                    tracing::warn!(%error, "couldn't stop a pending native runner");
                }
            }
            Err(error) => tracing::warn!(%error, "couldn't bind native runner"),
            _ => {}
        }
        if self.directory.path().join("native-exit").exists() {
            let _ = std::fs::write(self.directory.path().join("release"), []);
        }
    }
    pub(super) fn poll(
        &self,
        terminal: TerminalId,
        shell: libc::pid_t,
        observation: TerminalObservation,
    ) {
        let Ok(_control) = self.control.lock() else {
            return;
        };
        self.service_startup_locked(shell);
        if let Ok(value) = std::fs::read_to_string(self.directory.path().join("exit"))
            && let Ok(exit_code) = value.parse::<u32>()
        {
            self.finish(
                terminal,
                Ok(TerminalExit {
                    exit_code,
                    signal: None,
                }),
                observation,
            );
            let _ = std::fs::write(self.directory.path().join("retired"), []);
        }
    }
    pub(super) fn finish(
        &self,
        terminal: TerminalId,
        result: Result<TerminalExit, String>,
        observation: TerminalObservation,
    ) {
        if !self.delivered.swap(true, Ordering::AcqRel) {
            (self.callback)(terminal, result, observation);
        }
    }
}
fn quote(output: &mut Vec<u8>, value: &OsStr) {
    output.push(b'\'');
    for &byte in value.as_bytes() {
        if byte == b'\'' {
            output.extend_from_slice(b"'\\''");
        } else {
            output.push(byte);
        }
    }
    output.push(b'\'');
}
