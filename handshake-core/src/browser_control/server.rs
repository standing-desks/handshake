use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, Ordering},
};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use super::{REQUEST_LIMIT, RESPONSE_LIMIT, Request, State, TIMEOUT, failure};

pub(super) struct Server {
    directory: tempfile::TempDir,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl Server {
    pub(super) fn start(state: Arc<Mutex<State>>) -> std::io::Result<Self> {
        let directory = tempfile::Builder::new()
            .prefix("handshake-browser-")
            .tempdir_in("/tmp")?;
        let listener = UnixListener::bind(directory.path().join("control.sock"))?;
        listener.set_nonblocking(true)?;
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = Arc::clone(&stop);
        let thread = thread::Builder::new()
            .name("browser-control".into())
            .spawn(move || {
                let mut workers: Vec<JoinHandle<()>> = Vec::new();
                while !stopped.load(Ordering::Acquire) {
                    let mut index = 0;
                    while index < workers.len() {
                        if workers[index].is_finished() {
                            let _ = workers.swap_remove(index).join();
                        } else {
                            index += 1;
                        }
                    }
                    match listener.accept() {
                        Ok((stream, _)) if workers.len() < 16 => {
                            let state = Arc::clone(&state);
                            let stopped = Arc::clone(&stopped);
                            if let Ok(worker) = thread::Builder::new()
                                .name("browser-request".into())
                                .spawn(move || serve(stream, &state, &stopped))
                            {
                                workers.push(worker);
                            }
                        }
                        Ok(_) => {}
                        Err(_) => thread::sleep(Duration::from_millis(10)),
                    }
                }
                for worker in workers {
                    let _ = worker.join();
                }
            })?;
        Ok(Self {
            directory,
            stop,
            thread: Some(thread),
        })
    }

    pub(super) fn path(&self) -> std::path::PathBuf {
        self.directory.path().join("control.sock")
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn serve(mut stream: UnixStream, state: &Mutex<State>, stopped: &AtomicBool) {
    let _ = stream.set_nonblocking(true);
    let result = (|| {
        let bytes = read_frame(&mut stream, REQUEST_LIMIT, Duration::from_secs(1), stopped).ok()?;
        let request: Request = match serde_json::from_slice(&bytes) {
            Ok(request) => request,
            Err(_) => return Some(failure("invalid", "Malformed browser request.")),
        };
        let receiver = match state.lock().ok()?.submit(request) {
            Ok(receiver) => receiver,
            Err(error) => return Some(error),
        };
        let deadline = std::time::Instant::now() + TIMEOUT;
        while !stopped.load(Ordering::Acquire) && std::time::Instant::now() < deadline {
            match receiver.recv_timeout(Duration::from_millis(50)) {
                Ok(result) => return Some(result),
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            }
        }
        Some(failure(
            "cancelled",
            "Browser control stopped or timed out.",
        ))
    })()
    .unwrap_or_else(|| failure("unavailable", "Browser control is unavailable."));
    if let Ok(mut bytes) = serde_json::to_vec(&result) {
        if bytes.len() > RESPONSE_LIMIT {
            bytes = serde_json::to_vec(&failure(
                "too_large",
                "Browser result exceeds the size limit.",
            ))
            .unwrap_or_default();
        }
        bytes.push(b'\n');
        let _ = write_frame(&mut stream, &bytes, stopped);
    }
}

/// Sends one request to the native app from its CLI.
/// # Errors
/// Returns connection, framing, timeout or JSON errors.
pub fn request(path: &Path, request: &Request) -> std::io::Result<serde_json::Value> {
    let mut stream = UnixStream::connect(path)?;
    stream.set_nonblocking(true)?;
    let mut bytes = serde_json::to_vec(request)?;
    if bytes.len() >= REQUEST_LIMIT {
        return Err(std::io::Error::other("Browser request is too large."));
    }
    bytes.push(b'\n');
    let stopped = AtomicBool::new(false);
    write_frame(&mut stream, &bytes, &stopped)?;
    let result = read_frame(
        &mut stream,
        RESPONSE_LIMIT,
        TIMEOUT + Duration::from_secs(2),
        &stopped,
    )?;
    Ok(serde_json::from_slice(&result)?)
}

fn read_frame(
    stream: &mut UnixStream,
    limit: usize,
    timeout: Duration,
    stopped: &AtomicBool,
) -> std::io::Result<Vec<u8>> {
    let deadline = std::time::Instant::now() + timeout;
    let mut bytes = Vec::new();
    let mut buffer = [0; 4096];
    loop {
        check_deadline(deadline, stopped)?;
        match stream.read(&mut buffer) {
            Ok(0) => return Err(std::io::Error::other("Browser connection closed.")),
            Ok(count) => {
                bytes.extend_from_slice(&buffer[..count]);
                if bytes.len() > limit {
                    return Err(std::io::Error::other("Browser message is too large."));
                }
                if buffer[..count].contains(&b'\n') {
                    return Ok(bytes);
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(5));
            }
            Err(error) => return Err(error),
        }
    }
}

fn write_frame(stream: &mut UnixStream, bytes: &[u8], stopped: &AtomicBool) -> std::io::Result<()> {
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    let mut offset = 0;
    while offset < bytes.len() {
        check_deadline(deadline, stopped)?;
        match stream.write(&bytes[offset..]) {
            Ok(0) => return Err(std::io::Error::other("Browser connection closed.")),
            Ok(count) => offset += count,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(5));
            }
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

fn check_deadline(deadline: std::time::Instant, stopped: &AtomicBool) -> std::io::Result<()> {
    if stopped.load(Ordering::Acquire) || std::time::Instant::now() >= deadline {
        Err(std::io::Error::new(
            std::io::ErrorKind::TimedOut,
            "Browser connection stopped or timed out.",
        ))
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn slow_client_cannot_hold_shutdown() {
        let control = crate::browser_control::BrowserControl::new().unwrap();
        let mut stream = UnixStream::connect(control.server.path()).unwrap();
        stream.write_all(b"{").unwrap();
        thread::sleep(Duration::from_millis(30));
        let start = std::time::Instant::now();
        drop(control);
        assert!(start.elapsed() < Duration::from_millis(500));
    }
}
