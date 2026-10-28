//! Bounded structured activity from harness adapters, independent of terminal text.

use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::atomic::AtomicU64;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, sync_channel};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crate::terminal::{ReplayPosition, TerminalObservation};
use serde::Deserialize as _;

pub(crate) const MAX_DETAIL_BYTES: usize = 2048;
const MAX_REQUEST_BYTES: usize = 4 * 1024 * 1024;
const MAX_HEADER_BYTES: usize = 4096;
const REQUEST_TIMEOUT: Duration = Duration::from_millis(200);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum StepKind {
    SessionStarted,
    Prompt,
    ToolStarted,
    ToolFinished,
    Responded,
    /// Native child activity never drives the parent turn or workflow.
    Activity,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ActivityKind {
    Tool,
    Subagent,
    Model,
    Note,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ActivityPhase {
    Started,
    Finished,
}

#[derive(Clone, Debug)]
pub(crate) struct HarnessActivity {
    pub id: String,
    pub parent_id: Option<String>,
    pub kind: ActivityKind,
    pub phase: ActivityPhase,
    pub failed: bool,
    pub metadata: serde_json::Value,
    pub detail_path: Option<std::path::PathBuf>,
}

#[derive(Clone, Debug)]
pub(crate) struct HarnessStep {
    pub activity: Option<HarnessActivity>,
    pub session_id: Option<String>,
    pub kind: StepKind,
    pub turn_id: Option<String>,
    pub tool_call_id: Option<String>,
    pub title: String,
    pub detail: String,
}

impl HarnessStep {
    pub(crate) fn session_started(value: &serde_json::Value) -> Option<Self> {
        Some(Self {
            activity: None,
            session_id: Some(super::resume::session_handle(value)?),
            kind: StepKind::SessionStarted,
            turn_id: None,
            tool_call_id: None,
            title: String::new(),
            detail: String::new(),
        })
    }

    /// Read the exact native prompt, not its bounded trace preview.
    pub(crate) fn workflow_prompt(&self) -> io::Result<Option<String>> {
        if self.kind != StepKind::Prompt {
            return Ok(None);
        }
        let limit = crate::workflow_run::MAX_TASK_BYTES;
        let prompt = if let Some(activity) = &self.activity
            && let Some(path) = &activity.detail_path
        {
            // A native record above the transport limit cannot be a supported workflow task.
            if activity.metadata.get("recordFormat").is_some() {
                return Ok(None);
            }
            let mut text = String::new();
            std::fs::File::open(path)?
                .take((limit + 1) as u64)
                .read_to_string(&mut text)?;
            text
        } else {
            self.detail.clone()
        };
        Ok((!prompt.trim().is_empty() && prompt.len() <= limit).then_some(prompt))
    }

    pub(crate) fn message(&self) -> String {
        if self.detail.is_empty() {
            self.title.clone()
        } else {
            format!(
                "{}\n{}",
                self.title,
                truncate(&self.detail, MAX_DETAIL_BYTES)
            )
        }
    }
}

pub(crate) fn truncate(value: &str, limit: usize) -> String {
    if value.len() <= limit {
        return value.to_owned();
    }
    let mut end = limit.saturating_sub("… [truncated]".len());
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}… [truncated]", &value[..end])
}

pub(crate) fn observation_id(input: &serde_json::Value) -> String {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    input["_handshake_observation_id"].as_str().map_or_else(
        || {
            let time = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos();
            format!("{time:x}-{}", NEXT.fetch_add(1, Ordering::Relaxed))
        },
        str::to_owned,
    )
}

pub(crate) struct ObservedStep {
    pub step: HarnessStep,
    pub observation: TerminalObservation,
    pub received_at: Instant,
}

/// A private local HTTP endpoint. Hooks never wait on application state or SQLite. If its bounded
/// queue is full, recording is best effort and the harness continues without backpressure.
pub(crate) struct StepInbox {
    pub directory: tempfile::TempDir,
    pub socket_path: std::path::PathBuf,
    pub environment: Vec<(String, String)>,
    received: Receiver<ObservedStep>,
    cancelled: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
    wake: UnixStream,
    prompt_context: Mutex<Option<super::prompt_context::Inbox>>,
}

impl StepInbox {
    #[expect(
        clippy::too_many_lines,
        reason = "receiver ownership and bounded transport setup form one lifetime"
    )]
    pub(crate) fn new(
        position: Arc<ReplayPosition>,
        adapter: fn(&[u8]) -> Option<HarnessStep>,
    ) -> io::Result<Self> {
        // macOS limits Unix socket paths to 104 bytes; its usual temporary directory is too long.
        let directory = tempfile::Builder::new()
            .prefix("handshake-steps-")
            .tempdir_in("/tmp")?;
        let socket_path = directory.path().join("events.sock");
        let listener = UnixListener::bind(&socket_path)?;
        listener.set_nonblocking(true)?;
        let (wake, cancelled_read) = UnixStream::pair()?;
        wake.set_nonblocking(true)?;
        let detail_directory = directory.path().to_owned();
        let (sent, received) = sync_channel(256);
        let cancelled = Arc::new(AtomicBool::new(false));
        let stop = Arc::clone(&cancelled);
        let worker = crate::blocking_worker::spawn("harness-steps".into(), move || {
            while !stop.load(Ordering::Acquire) {
                let mut descriptors = [
                    libc::pollfd {
                        fd: listener.as_raw_fd(),
                        events: libc::POLLIN,
                        revents: 0,
                    },
                    libc::pollfd {
                        fd: cancelled_read.as_raw_fd(),
                        events: libc::POLLIN,
                        revents: 0,
                    },
                ];
                // SAFETY: Both borrowed descriptors remain open for this worker; the array is
                // writable and poll observes exactly its two initialized elements.
                if unsafe { libc::poll(descriptors.as_mut_ptr(), 2, -1) } < 0 {
                    if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                        continue;
                    }
                    break;
                }
                if stop.load(Ordering::Acquire) {
                    break;
                }
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        if stop.load(Ordering::Acquire) {
                            break;
                        }
                        if let Some(body) = read_request(&mut stream)
                            && let Some((bytes, raw_file)) =
                                resolve_body(body, &detail_directory, &stop)
                            && let Some(mut step) = adapter(&bytes)
                            && let Ok(observation) = position.observe()
                        {
                            if step.detail.len() > MAX_DETAIL_BYTES && step.activity.is_none() {
                                step.activity = Some(HarnessActivity {
                                    id: format!(
                                        "detail:{:?}:{}",
                                        step.kind,
                                        step.turn_id.as_deref().unwrap_or("unidentified")
                                    ),
                                    parent_id: None,
                                    kind: ActivityKind::Note,
                                    phase: if step.kind == StepKind::Prompt {
                                        ActivityPhase::Started
                                    } else {
                                        ActivityPhase::Finished
                                    },
                                    failed: false,
                                    metadata: serde_json::json!({"source":"Observer"}),
                                    detail_path: None,
                                });
                            }
                            if raw_file.is_some() && step.activity.is_none() {
                                step.activity = Some(HarnessActivity {
                                    id: format!(
                                        "detail:{:?}:{}",
                                        step.kind,
                                        step.turn_id.as_deref().unwrap_or("unidentified")
                                    ),
                                    parent_id: None,
                                    kind: ActivityKind::Note,
                                    phase: if step.kind == StepKind::Prompt {
                                        ActivityPhase::Started
                                    } else {
                                        ActivityPhase::Finished
                                    },
                                    failed: false,
                                    metadata: serde_json::json!({"source":"Observer"}),
                                    detail_path: None,
                                });
                            }
                            if let Some(path) = raw_file
                                && let Some(activity) = &mut step.activity
                            {
                                activity.detail_path = Some(path);
                                activity.metadata["recordFormat"] = "Native JSON record".into();
                            }
                            if step.detail.len() > MAX_DETAIL_BYTES
                                && step
                                    .activity
                                    .as_ref()
                                    .is_none_or(|a| a.detail_path.is_none())
                                && let Some(activity) = &mut step.activity
                                && let Ok(mut file) =
                                    tempfile::NamedTempFile::new_in(&detail_directory)
                                && file.write_all(step.detail.as_bytes()).is_ok()
                                && let Ok((_, path)) = file.keep()
                            {
                                activity.detail_path = Some(path);
                                step.detail = truncate(&step.detail, MAX_DETAIL_BYTES);
                            }
                            let _ = sent.try_send(ObservedStep {
                                step,
                                observation,
                                received_at: Instant::now(),
                            });
                        }
                        // Empty output cannot inject context or control a harness decision.
                        let _ = stream.write_all(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                    }
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                    Err(_) => break,
                }
            }
        })?;
        Ok(Self {
            directory,
            socket_path,
            environment: Vec::new(),
            received,
            cancelled,
            worker: Some(worker),
            wake,
            prompt_context: Mutex::new(None),
        })
    }

    pub(crate) fn take(&self, limit: usize) -> Vec<ObservedStep> {
        self.received.try_iter().take(limit).collect()
    }

    /// Explicit native prompt context is independent of the observation-only trace hooks.
    pub(crate) fn set_prompt_context(
        &self,
        reader: super::prompt_context::Reader,
    ) -> io::Result<()> {
        let inbox = super::prompt_context::Inbox::new(
            &self.socket_path.with_file_name("memory.sock"),
            reader,
        )?;
        *self
            .prompt_context
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(inbox);
        Ok(())
    }

    pub(crate) fn prompt_context_command(&self) -> String {
        format!(
            "handshake_reply=$(/usr/bin/mktemp '{}/memory-response.XXXXXXXX') || exit 0; trap '/bin/rm -f \"$handshake_reply\"' EXIT; if /usr/bin/curl --silent --fail --max-time 5 --header 'Expect:' --unix-socket '{}' --output \"$handshake_reply\" --data-binary @- http://localhost/ && /bin/cat \"$handshake_reply\" 2>/dev/null; then :; else /usr/bin/printf '%s\\n' '{{\"systemMessage\":\"Handshake shared-memory refresh is unavailable for this prompt. Check Memory settings before relying on new shared memories.\"}}'; fi",
            self.directory
                .path()
                .to_string_lossy()
                .replace('\'', "'\\''"),
            self.socket_path
                .with_file_name("memory.sock")
                .to_string_lossy()
                .replace('\'', "'\\''")
        )
    }

    /// Hooks are observers only: bounded input and runtime, no output, and no failure status.
    pub(crate) fn hook_command(&self) -> String {
        format!(
            "{{ handshake_body=$(/usr/bin/mktemp '{}/record.XXXXXXXX'); /bin/cat >\"$handshake_body\"; /usr/bin/printf '{{\"payload_file\":\"%s\"}}' \"$handshake_body\" | /usr/bin/curl --silent --max-time 1 --output /dev/null --header 'Expect:' --unix-socket '{}' --data-binary @- http://localhost/; }} >/dev/null 2>&1 || true",
            self.directory
                .path()
                .to_string_lossy()
                .replace('\'', "'\\''"),
            self.socket_path.to_string_lossy().replace('\'', "'\\''")
        )
    }
}

#[derive(serde::Deserialize, serde::Serialize)]
struct RecordHeader {
    hook_event_name: Option<String>,
    #[serde(default, deserialize_with = "prompt_preview")]
    prompt: Option<String>,
    session_id: Option<String>,
    turn_id: Option<String>,
    prompt_id: Option<String>,
    tool_use_id: Option<String>,
    tool_name: Option<String>,
    agent_id: Option<String>,
    agent_type: Option<String>,
    tool_call_id: Option<String>,
    parent_agent_id: Option<String>,
    parent_tool_call_id: Option<String>,
    agent_name: Option<String>,
    title: Option<String>,
    #[serde(rename = "conversationId")]
    conversation_id: Option<String>,
    #[serde(rename = "invocationNum")]
    invocation_num: Option<u64>,
    #[serde(rename = "transcriptPath")]
    transcript_path: Option<String>,
    #[serde(rename = "stepIdx")]
    step_idx: Option<u64>,
    #[serde(rename = "modelName")]
    model_name: Option<String>,
    #[serde(rename = "toolCall")]
    tool_call: Option<RecordTool>,
    #[serde(rename = "type")]
    kind: Option<String>,
    activity_id: Option<String>,
    is_error: Option<bool>,
    #[serde(default)]
    metadata: serde_json::Value,
}

fn prompt_preview<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<String>, D::Error> {
    let value = Option::<String>::deserialize(deserializer)?;
    Ok(value.map(|text| truncate(&text, 160)))
}

#[derive(serde::Deserialize, serde::Serialize)]
struct RecordTool {
    name: String,
}

fn resolve_body(
    body: Vec<u8>,
    directory: &std::path::Path,
    cancelled: &AtomicBool,
) -> Option<(Vec<u8>, Option<std::path::PathBuf>)> {
    let mut value: serde_json::Value = serde_json::from_slice(&body).ok()?;
    let event = value.get("event").cloned();
    let turn = value.get("turn").cloned();
    let Some(path) = value["payload_file"].as_str().map(std::path::PathBuf::from) else {
        return Some((body, None));
    };
    let path = path.canonicalize().ok()?;
    if path.parent()? != directory.canonicalize().ok()? {
        return None;
    }
    let file = std::fs::File::open(&path).ok()?;
    let size = file.metadata().ok()?.len();
    let file = std::io::BufReader::with_capacity(
        64 * 1024,
        CancellableReader {
            reader: file,
            cancelled,
        },
    );
    let raw = if size > MAX_REQUEST_BYTES as u64 {
        // The streaming decoder skips large body fields. The full original JSON remains a
        // pageable payload rather than disappearing or entering the in-memory event queue.
        value =
            serde_json::to_value(serde_json::from_reader::<_, RecordHeader>(file).ok()?).ok()?;
        value["detail"] = "View the complete native record".into();
        Some(path.clone())
    } else {
        value = serde_json::from_reader(file).ok()?;
        let _ = std::fs::remove_file(&path);
        None
    };
    value["_handshake_observation_id"] = path.file_name()?.to_string_lossy().into_owned().into();
    if let Some(event) = event {
        value = serde_json::json!({"event":event,"turn":turn,"payload":value,"_handshake_observation_id":path.file_name()?.to_string_lossy()});
    }
    Some((serde_json::to_vec(&value).ok()?, raw))
}

pub(super) struct CancellableReader<'a, R> {
    pub reader: R,
    pub cancelled: &'a AtomicBool,
}

impl<R: Read> Read for CancellableReader<'_, R> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if self.cancelled.load(Ordering::Acquire) {
            return Err(io::Error::new(
                io::ErrorKind::ConnectionAborted,
                "observer stopped",
            ));
        }
        self.reader.read(buffer)
    }
}

impl Drop for StepInbox {
    fn drop(&mut self) {
        self.prompt_context
            .get_mut()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
        self.cancelled.store(true, Ordering::Release);
        // Wake the blocking accept instead of polling and adding a delay to every event.
        let _ = self.wake.write_all(b"stop");
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

pub(super) fn read_request(stream: &mut UnixStream) -> Option<Vec<u8>> {
    stream.set_nonblocking(true).ok()?;
    let deadline = Instant::now() + REQUEST_TIMEOUT;
    let mut bytes = Vec::new();
    let mut body = None;
    let mut buffer = [0; 8192];
    while Instant::now() < deadline {
        match stream.read(&mut buffer) {
            Ok(0) => return None,
            Ok(count) => bytes.extend_from_slice(&buffer[..count]),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                let mut descriptor = libc::pollfd {
                    fd: stream.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                };
                let timeout = i32::try_from(
                    deadline
                        .saturating_duration_since(Instant::now())
                        .as_millis(),
                )
                .unwrap_or(200);
                // SAFETY: The stream owns an open descriptor and the single pollfd is writable.
                if unsafe { libc::poll(&raw mut descriptor, 1, timeout) } < 0
                    && io::Error::last_os_error().kind() != io::ErrorKind::Interrupted
                {
                    return None;
                }
                continue;
            }
            Err(_) => return None,
        }
        if body.is_none() {
            if let Some(end) = bytes.windows(4).position(|part| part == b"\r\n\r\n") {
                if end > MAX_HEADER_BYTES {
                    return None;
                }
                let headers = std::str::from_utf8(&bytes[..end]).ok()?;
                let length = headers.lines().find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().ok())
                        .flatten()
                })?;
                if length > MAX_REQUEST_BYTES {
                    return None;
                }
                body = Some((end + 4, length));
            } else if bytes.len() > MAX_HEADER_BYTES {
                return None;
            }
        }
        if let Some((start, length)) = body
            && bytes.len() >= start + length
        {
            return Some(bytes[start..start + length].to_vec());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompt_context_drains_large_inputs_and_refreshes_without_observing_prompt_text() {
        use std::process::{Command, Stdio};
        let inbox = StepInbox::new(
            Arc::new(ReplayPosition::default()),
            super::super::claude::parse,
        )
        .unwrap();
        let current = Arc::new(Mutex::new(String::from("First saved preference.")));
        let reader = Arc::clone(&current);
        inbox
            .set_prompt_context(Arc::new(move |_, _, prompt| {
                assert_eq!(prompt.len(), 16_384);
                Ok(Some(reader.lock().unwrap().clone()))
            }))
            .unwrap();
        for expected in ["First saved preference.", "Updated saved preference."] {
            *current.lock().unwrap() = expected.to_owned();
            let mut child = Command::new("/bin/sh")
                .args(["-c", &inbox.prompt_context_command()])
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .spawn()
                .unwrap();
            let payload = serde_json::json!({"hook_event_name":"UserPromptSubmit","prompt":"x".repeat(1024*1024)}).to_string();
            child
                .stdin
                .take()
                .unwrap()
                .write_all(payload.as_bytes())
                .unwrap();
            let output = child.wait_with_output().unwrap();
            assert!(output.status.success());
            let value: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
            assert_eq!(value["hookSpecificOutput"]["additionalContext"], expected);
        }
        assert!(
            inbox.take(10).is_empty(),
            "Memory refresh does not become a fake user trace"
        );
    }

    #[test]
    fn slow_prompt_context_does_not_starve_observers_and_cancels_on_drop() {
        use std::process::{Command, Stdio};
        let inbox = StepInbox::new(
            Arc::new(ReplayPosition::default()),
            super::super::claude::parse,
        )
        .unwrap();
        let entered = Arc::new(AtomicBool::new(false));
        let signal = Arc::clone(&entered);
        inbox
            .set_prompt_context(Arc::new(move |cancelled, _, _| {
                signal.store(true, Ordering::Release);
                while !cancelled.load(Ordering::Acquire) {
                    std::thread::sleep(Duration::from_millis(5));
                }
                Ok(None)
            }))
            .unwrap();
        let mut child = Command::new("/bin/sh")
            .args(["-c", &inbox.prompt_context_command()])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(br#"{"hook_event_name":"UserPromptSubmit"}"#)
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        while !entered.load(Ordering::Acquire) {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(5));
        }
        let body = br#"{"hook_event_name":"UserPromptSubmit","session_id":"example","prompt_id":"turn","prompt":"hello"}"#;
        let mut connection = UnixStream::connect(&inbox.socket_path).unwrap();
        write!(
            connection,
            "POST / HTTP/1.1\r\nContent-Length: {}\r\n\r\n",
            body.len()
        )
        .unwrap();
        connection.write_all(body).unwrap();
        let deadline = Instant::now() + Duration::from_secs(1);
        loop {
            if !inbox.take(1).is_empty() {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "Trace observation was blocked by memory refresh"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
        let start = Instant::now();
        drop(inbox);
        assert!(start.elapsed() < Duration::from_secs(1));
        assert!(child.wait().unwrap().success());
    }

    #[test]
    fn full_prompt_files_keep_the_turn_and_content_above_both_preview_and_transport_limits() {
        for bytes in [9000, 5 * 1024 * 1024] {
            let inbox = StepInbox::new(
                Arc::new(ReplayPosition::default()),
                super::super::claude::parse,
            )
            .unwrap();
            let prompt = "☃".repeat(bytes / 3);
            let payload = serde_json::to_vec(&serde_json::json!({"hook_event_name":"UserPromptSubmit","session_id":"session","prompt_id":"turn","prompt":prompt})).unwrap();
            let path = inbox.directory.path().join("record-fixture.json");
            std::fs::write(&path, &payload).unwrap();
            let body = serde_json::to_vec(&serde_json::json!({"payload_file":path})).unwrap();
            let mut connection = UnixStream::connect(&inbox.socket_path).unwrap();
            write!(
                connection,
                "POST / HTTP/1.1\r\nContent-Length: {}\r\n\r\n",
                body.len()
            )
            .unwrap();
            connection.write_all(&body).unwrap();
            let until = Instant::now() + Duration::from_secs(5);
            let event = loop {
                if let Some(event) = inbox.take(1).pop() {
                    break event;
                }
                assert!(Instant::now() < until, "prompt was dropped");
                std::thread::sleep(Duration::from_millis(5));
            };
            assert_eq!(event.step.kind, StepKind::Prompt);
            assert_eq!(event.step.turn_id.as_deref(), Some("turn"));
            let activity = event.step.activity.unwrap();
            assert_eq!(activity.phase, ActivityPhase::Started);
            let saved = std::fs::read(activity.detail_path.unwrap()).unwrap();
            assert_eq!(
                saved,
                if bytes > MAX_REQUEST_BYTES {
                    payload
                } else {
                    prompt.into_bytes()
                }
            );
        }
    }

    #[test]
    fn unlinking_the_socket_and_cancelled_large_reads_cannot_block_shutdown() {
        let inbox = StepInbox::new(
            Arc::new(ReplayPosition::default()),
            super::super::claude::parse,
        )
        .unwrap();
        std::fs::remove_file(&inbox.socket_path).unwrap();
        let started = Instant::now();
        drop(inbox);
        assert!(started.elapsed() < Duration::from_secs(1));
        let cancelled = AtomicBool::new(true);
        let mut reader = CancellableReader {
            reader: std::io::Cursor::new(vec![1; 4096]),
            cancelled: &cancelled,
        };
        assert_eq!(
            reader.read(&mut [0; 4]).unwrap_err().kind(),
            io::ErrorKind::ConnectionAborted
        );
    }

    #[test]
    fn truncation_preserves_utf8_and_marks_omitted_details() {
        let text = "☃".repeat(3000);
        let clipped = truncate(&text, MAX_DETAIL_BYTES);
        assert!(clipped.len() <= MAX_DETAIL_BYTES);
        assert!(clipped.ends_with("… [truncated]"));
        assert_eq!(truncate("small", MAX_DETAIL_BYTES), "small");
    }

    #[test]
    fn a_stalled_or_oversized_sender_cannot_hold_the_receiver() {
        let (mut client, mut server) = UnixStream::pair().unwrap();
        client
            .write_all(b"POST / HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n")
            .unwrap();
        assert!(read_request(&mut server).is_none());
        let (mut client, mut server) = UnixStream::pair().unwrap();
        client
            .write_all(b"POST / HTTP/1.1\r\nContent-Length: 100\r\n\r\nx")
            .unwrap();
        let started = Instant::now();
        assert!(read_request(&mut server).is_none());
        assert!(started.elapsed() < Duration::from_secs(1));
    }
}
