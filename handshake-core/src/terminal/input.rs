//! Bounded per-terminal writers. No application or routing lock waits for a PTY to drain.
use std::collections::VecDeque;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;

use super::TerminalError;

const CAPACITY: usize = 1024 * 1024;

#[derive(Clone)]
pub(super) struct InvocationInputGuard {
    pub(super) ended: std::path::PathBuf,
    pub(super) stopping: std::path::PathBuf,
    pub(super) ready: std::path::PathBuf,
    pub(super) bound: bool,
}
impl InvocationInputGuard {
    fn closed(&self) -> bool {
        self.ended.exists()
            || self.stopping.exists()
            || self
                .ended
                .parent()
                .is_none_or(|directory| !directory.exists())
    }
}

struct Pending {
    bytes: Vec<u8>,
    offset: usize,
    revision: Option<u64>,
    invocation_exit: Option<InvocationInputGuard>,
}
#[derive(Default)]
struct State {
    pending: VecDeque<Pending>,
    bytes: usize,
    revision: u64,
    stopped: bool,
    failed: bool,
}
#[derive(Default)]
struct Shared {
    state: Mutex<State>,
    changed: Condvar,
}
pub(super) struct TerminalInput {
    shared: Arc<Shared>,
    worker: Option<JoinHandle<()>>,
}
impl TerminalInput {
    pub(super) fn new(descriptor: libc::c_int) -> Result<Self, TerminalError> {
        // SAFETY: dup creates an independently owned descriptor while the master is alive.
        let descriptor = unsafe { libc::dup(descriptor) };
        if descriptor < 0 {
            return Err(input_error(io::Error::last_os_error()));
        }
        // SAFETY: the successful dup transfers ownership to OwnedFd.
        let descriptor = unsafe { OwnedFd::from_raw_fd(descriptor) };
        // SAFETY: fcntl operates on our live descriptor. PTY reads already poll readiness.
        let flags = unsafe { libc::fcntl(descriptor.as_raw_fd(), libc::F_GETFL) };
        if flags < 0
            || unsafe {
                libc::fcntl(
                    descriptor.as_raw_fd(),
                    libc::F_SETFL,
                    flags | libc::O_NONBLOCK,
                )
            } < 0
        {
            return Err(input_error(io::Error::last_os_error()));
        }
        let shared = Arc::new(Shared::default());
        let state = Arc::clone(&shared);
        let worker = crate::blocking_worker::spawn("terminal-input".into(), move || {
            run(&descriptor, &state);
        })
        .map_err(input_error)?;
        Ok(Self {
            shared,
            worker: Some(worker),
        })
    }
    /// User bytes and revocable feedback are committed to the queue together, in submission order.
    pub(super) fn enqueue_parts(
        &self,
        parts: &[(&[u8], Option<u64>)],
        priority: bool,
        invocation_exit: Option<&InvocationInputGuard>,
    ) -> Result<(), TerminalError> {
        let mut state = self
            .shared
            .state
            .lock()
            .map_err(|_| TerminalError::Poisoned)?;
        if state.stopped || state.failed {
            return Err(TerminalError::InputClosed);
        }
        let length = parts
            .iter()
            .try_fold(0usize, |length, (bytes, _)| length.checked_add(bytes.len()))
            .ok_or(TerminalError::InputBackpressure)?;
        if length > CAPACITY.saturating_sub(state.bytes) {
            return Err(TerminalError::InputBackpressure);
        }
        state.bytes += length;
        let pending = parts
            .iter()
            .filter(|(bytes, _)| !bytes.is_empty())
            .map(|(bytes, revision)| Pending {
                bytes: bytes.to_vec(),
                offset: 0,
                revision: *revision,
                invocation_exit: invocation_exit
                    .filter(|guard| guard.bound || revision.is_some())
                    .cloned(),
            })
            .collect::<Vec<_>>();
        if priority {
            for item in pending.into_iter().rev() {
                state.pending.push_front(item);
            }
        } else {
            state.pending.extend(pending);
        }
        self.shared.changed.notify_one();
        Ok(())
    }
    /// Serialized with individual nonblocking writes: no stale routed byte follows this boundary.
    pub(super) fn set_revision(&self, revision: u64) {
        if let Ok(mut state) = self.shared.state.lock() {
            state.revision = revision;
            let mut removed = 0;
            state.pending.retain(|item| {
                let keep = item.revision.is_none_or(|value| value == revision);
                if !keep {
                    removed += item.bytes.len() - item.offset;
                }
                keep
            });
            state.bytes -= removed;
        }
    }
}
impl Drop for TerminalInput {
    fn drop(&mut self) {
        if let Ok(mut state) = self.shared.state.lock() {
            state.stopped = true;
        }
        self.shared.changed.notify_one();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
fn run(descriptor: &OwnedFd, shared: &Shared) {
    loop {
        let Ok(mut state) = shared.state.lock() else {
            return;
        };
        while state.pending.is_empty() && !state.stopped {
            let Ok(next) = shared.changed.wait(state) else {
                return;
            };
            state = next;
        }
        if state.stopped {
            return;
        }
        let revision = state.revision;
        // Routed input waits for the native runner; raw startup replies can pass it.
        let available = state.pending.iter().position(|item| {
            item.revision.is_some_and(|value| value != revision)
                || item
                    .invocation_exit
                    .as_ref()
                    .is_some_and(InvocationInputGuard::closed)
                || item.revision.is_none()
                || item
                    .invocation_exit
                    .as_ref()
                    .is_none_or(|guard| guard.ready.exists())
        });
        let Some(index) = available else {
            let _ = shared
                .changed
                .wait_timeout(state, std::time::Duration::from_millis(20));
            continue;
        };
        if index > 0 {
            let item = state.pending.remove(index).expect("available input");
            state.pending.push_front(item);
        }
        let item = state.pending.front_mut().expect("pending input");
        if item.revision.is_some_and(|value| value != revision)
            || item
                .invocation_exit
                .as_ref()
                .is_some_and(InvocationInputGuard::closed)
        {
            let removed = item.bytes.len() - item.offset;
            state.pending.pop_front();
            state.bytes -= removed;
            continue;
        }
        let bytes = &item.bytes[item.offset..];
        // SAFETY: the slice and descriptor remain valid; O_NONBLOCK prevents this locked write waiting.
        let count =
            unsafe { libc::write(descriptor.as_raw_fd(), bytes.as_ptr().cast(), bytes.len()) };
        if count > 0 {
            let count = usize::try_from(count).expect("positive write length");
            item.offset += count;
            if item.offset == item.bytes.len() {
                state.pending.pop_front();
            }
            state.bytes -= count;
        } else if count < 0 {
            let error = io::Error::last_os_error();
            if !matches!(
                error.kind(),
                io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
            ) {
                state.failed = true;
                state.pending.clear();
                state.bytes = 0;
                return;
            }
            drop(state);
            let mut poll = libc::pollfd {
                fd: descriptor.as_raw_fd(),
                events: libc::POLLOUT,
                revents: 0,
            };
            // SAFETY: poll points to one live entry. The timeout also bounds shutdown latency.
            unsafe {
                libc::poll(&raw mut poll, 1, 20);
            }
        }
    }
}
#[expect(
    clippy::needless_pass_by_value,
    reason = "used directly as an IO error mapper"
)]
fn input_error(error: io::Error) -> TerminalError {
    TerminalError::Pty {
        operation: "start terminal input worker",
        message: error.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    use std::os::fd::AsRawFd;
    use std::time::{Duration, Instant};

    fn pipe() -> (std::fs::File, OwnedFd) {
        let mut descriptors = [0; 2];
        // SAFETY: pipe initializes the two entries; each is immediately given one owner.
        assert_eq!(unsafe { libc::pipe(descriptors.as_mut_ptr()) }, 0);
        unsafe {
            (
                std::fs::File::from_raw_fd(descriptors[0]),
                OwnedFd::from_raw_fd(descriptors[1]),
            )
        }
    }
    fn read_until(reader: &mut std::fs::File, suffix: &[u8]) -> Vec<u8> {
        let deadline = Instant::now() + Duration::from_secs(3);
        let mut bytes = Vec::new();
        while !bytes.ends_with(suffix) {
            assert!(Instant::now() < deadline, "input did not drain");
            let mut poll = libc::pollfd {
                fd: reader.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            };
            // SAFETY: one live poll entry and owned descriptor.
            if unsafe { libc::poll(&raw mut poll, 1, 20) } > 0 {
                let mut buffer = [0; 4096];
                let count = reader.read(&mut buffer).unwrap();
                bytes.extend_from_slice(&buffer[..count]);
            }
        }
        bytes
    }
    #[test]
    fn a_blocked_writer_does_not_block_boundaries_or_other_terminals() {
        let (mut reader, writer) = pipe();
        let input = TerminalInput::new(writer.as_raw_fd()).unwrap();
        input
            .enqueue_parts(&[(&vec![b'z'; CAPACITY], Some(0))], false, None)
            .unwrap();
        assert!(matches!(
            input.enqueue_parts(&[(&vec![0; CAPACITY + 1], None)], false, None),
            Err(TerminalError::InputBackpressure)
        ));
        let start = Instant::now();
        input.set_revision(1);
        assert!(start.elapsed() < Duration::from_millis(100));
        let (mut other_reader, other_writer) = pipe();
        let other = TerminalInput::new(other_writer.as_raw_fd()).unwrap();
        other
            .enqueue_parts(&[(b"other", None)], false, None)
            .unwrap();
        assert_eq!(read_until(&mut other_reader, b"other"), b"other");
        input
            .enqueue_parts(&[(b"fresh", None)], false, None)
            .unwrap();
        let bytes = read_until(&mut reader, b"fresh");
        assert!(bytes[..bytes.len() - 5].iter().all(|byte| *byte == b'z'));
    }
    #[test]
    fn feedback_is_revocable_without_discarding_the_users_message() {
        let (mut reader, writer) = pipe();
        let input = TerminalInput::new(writer.as_raw_fd()).unwrap();
        // Saturate the pipe before queueing the submission so no feedback can race the boundary.
        let filler = [b'z'; 4096];
        loop {
            // SAFETY: the owned write descriptor is nonblocking; filler covers its declared length.
            let count =
                unsafe { libc::write(writer.as_raw_fd(), filler.as_ptr().cast(), filler.len()) };
            if count < 0 {
                assert_eq!(io::Error::last_os_error().kind(), io::ErrorKind::WouldBlock);
                break;
            }
        }
        input
            .enqueue_parts(
                &[
                    (b"user", None),
                    (b"PRIVATE_FEEDBACK", Some(0)),
                    (b"\r", None),
                ],
                false,
                None,
            )
            .unwrap();
        input.set_revision(1);
        let bytes = read_until(&mut reader, b"user\r");
        assert!(!bytes.windows(8).any(|bytes| bytes == b"FEEDBACK"));
    }
    #[test]
    fn ended_or_removed_invocations_discard_old_packets_and_release_capacity() {
        for removed in [false, true] {
            let (mut reader, writer) = pipe();
            let input = TerminalInput::new(writer.as_raw_fd()).unwrap();
            let directory = tempfile::tempdir().unwrap();
            let guard = InvocationInputGuard {
                ended: directory.path().join("exit"),
                stopping: directory.path().join("stopping"),
                ready: directory.path().join("ready"),
                bound: true,
            };
            if !removed {
                std::fs::write(&guard.ended, b"0").unwrap();
            }
            input
                .enqueue_parts(&[(b"old handoff\r", Some(0))], false, Some(&guard))
                .unwrap();
            if removed {
                directory.close().unwrap();
            }
            input
                .enqueue_parts(&[(b"shell command\r", None)], false, None)
                .unwrap();
            assert_eq!(
                read_until(&mut reader, b"shell command\r"),
                b"shell command\r"
            );
            let state = input.shared.state.lock().unwrap();
            assert!(state.pending.is_empty());
            assert_eq!(state.bytes, 0);
        }
    }
}
