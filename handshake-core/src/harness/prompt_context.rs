//! Native prompt context has its own transport, independent of trace observation.
use std::io::{self, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::Duration;

pub(super) type Reader = Arc<dyn Fn(&AtomicBool, &str) -> io::Result<Option<String>> + Send + Sync>;

pub(super) struct Inbox {
    cancelled: Arc<AtomicBool>,
    wake: UnixStream,
    worker: Option<JoinHandle<()>>,
}

impl Inbox {
    pub(super) fn new(path: &Path, reader: Reader) -> io::Result<Self> {
        let listener = UnixListener::bind(path)?;
        listener.set_nonblocking(true)?;
        let (wake, cancelled_read) = UnixStream::pair()?;
        let cancelled = Arc::new(AtomicBool::new(false));
        let stop = Arc::clone(&cancelled);
        let worker = crate::blocking_worker::spawn("native-memory-prompt".into(), move || {
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
                // SAFETY: both descriptors remain owned by this thread throughout poll.
                if unsafe { libc::poll(descriptors.as_mut_ptr(), 2, -1) } < 0 {
                    if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                        continue;
                    }
                    break;
                }
                if stop.load(Ordering::Acquire) {
                    break;
                }
                let Ok((mut stream, _)) = listener.accept() else {
                    continue;
                };
                let request = super::steps::read_request(&mut stream)
                    .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok());
                let Some(request) =
                    request.filter(|value| value["handshake_memory_context"] == true)
                else {
                    continue;
                };
                let session = request["session_id"].as_str().unwrap_or_default();
                if session.len() > 160
                    || !session
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_'))
                {
                    continue;
                }
                let result = reader(&stop, session);
                let response = match result {
                    Ok(Some(context)) => serde_json::json!({"hookSpecificOutput":{
                        "hookEventName":"UserPromptSubmit", "additionalContext":context
                    }}),
                    Ok(None) => serde_json::json!({}),
                    Err(error) => {
                        tracing::warn!(%error,"couldn't refresh native project memories before prompt");
                        serde_json::json!({"systemMessage":"Handshake could not refresh shared project memories for this prompt. Check Memory settings for pending reconciliation."})
                    }
                };
                let bytes = response.to_string();
                let _ = stream.set_nonblocking(false);
                let _ = stream.set_write_timeout(Some(Duration::from_secs(1)));
                let _ = write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    bytes.len(),
                    bytes
                );
            }
        })?;
        Ok(Self {
            cancelled,
            wake,
            worker: Some(worker),
        })
    }
}

impl Drop for Inbox {
    fn drop(&mut self) {
        self.cancelled.store(true, Ordering::Release);
        let _ = self.wake.write_all(b"stop");
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
