use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use portable_pty::Child;
use tracing::warn;

use super::TerminalExit;
#[cfg(unix)]
use crate::process::signal_process_group;
#[cfg(target_os = "macos")]
use crate::process::signal_session;

const SUPERVISOR_POLL_INTERVAL: Duration = Duration::from_millis(10);
const STOP_ACK_TIMEOUT: Duration = Duration::from_secs(2);
const STOP_RETRY_INTERVAL: Duration = Duration::from_millis(10);

type ExitResult = Result<TerminalExit, String>;
pub(super) type SharedChild = Arc<Mutex<ChildProcess>>;

pub(super) struct ChildProcess {
    child: Box<dyn Child + Send + Sync>,
    process_id: Option<u32>,
    exit: Option<ExitResult>,
}

/// Wraps a spawned child so its exit is observed and reaped exactly once.
pub(super) fn shared_child(child: Box<dyn Child + Send + Sync>) -> SharedChild {
    let process_id = child.process_id();
    Arc::new(Mutex::new(ChildProcess {
        child,
        process_id,
        exit: None,
    }))
}

pub(super) fn process_id(child: &SharedChild) -> Option<u32> {
    child.lock().ok()?.process_id
}

pub(super) fn wait_for_child(
    child: &SharedChild,
    mut poll: impl FnMut(),
) -> Result<TerminalExit, String> {
    loop {
        let mut process = child
            .lock()
            .map_err(|_| "terminal child lock is poisoned".to_owned())?;
        if let Some(exit) = &process.exit {
            return exit.clone();
        }
        match child_exited_without_reaping(&mut process) {
            Ok(true) => {
                if let Some(exit) = &process.exit {
                    return exit.clone();
                }
                let exit = terminate_running_process(&mut process);
                process.exit = Some(exit.clone());
                return exit;
            }
            Ok(false) => {}
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error.to_string()),
        }
        drop(process);
        poll();
        thread::sleep(SUPERVISOR_POLL_INTERVAL);
    }
}

/// Checks the owned child without reaping it or signaling its process group.
pub(super) fn child_is_running(child: &SharedChild) -> bool {
    let Ok(mut process) = child.lock() else {
        return false;
    };
    process.exit.is_none() && matches!(child_exited_without_reaping(&mut process), Ok(false))
}

pub(super) fn terminate_unobserved_child(child: &SharedChild) {
    terminate_child(child);
}

pub(super) fn terminate_child(child: &SharedChild) {
    let mut process = match child.lock() {
        Ok(process) => process,
        Err(poisoned) => {
            warn!("terminal child lock poisoned during shutdown; recovering owned child");
            poisoned.into_inner()
        }
    };
    if process.exit.is_some() {
        return;
    }
    loop {
        match child_exited_without_reaping(&mut process) {
            Ok(_) => break,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) if is_no_child_error(&error) => {
                process.exit = Some(Err(error.to_string()));
                return;
            }
            Err(error) => {
                warn!(%error, "failed to inspect terminal process; forcing shutdown");
                break;
            }
        }
    }
    if process.exit.is_some() {
        return;
    }
    let exit = terminate_running_process(&mut process);
    process.exit = Some(exit);
}

#[cfg(unix)]
fn child_exited_without_reaping(process: &mut ChildProcess) -> std::io::Result<bool> {
    let process_id = process
        .process_id
        .and_then(|value| libc::pid_t::try_from(value).ok())
        .ok_or_else(|| std::io::Error::other("terminal child has no usable process ID"))?;
    crate::process::child_exited_without_reaping(process_id)
}

#[cfg(not(unix))]
fn child_exited_without_reaping(process: &mut ChildProcess) -> std::io::Result<bool> {
    process.child.try_wait().map(|status| {
        if let Some(status) = status {
            process.exit = Some(Ok(TerminalExit {
                exit_code: status.exit_code(),
                signal: status.signal().map(ToOwned::to_owned),
            }));
            true
        } else {
            false
        }
    })
}

#[cfg(unix)]
fn is_no_child_error(error: &std::io::Error) -> bool {
    error.raw_os_error() == Some(libc::ECHILD)
}

#[cfg(not(unix))]
const fn is_no_child_error(_error: &std::io::Error) -> bool {
    false
}

#[cfg(unix)]
fn terminate_running_process(process: &mut ChildProcess) -> ExitResult {
    let Some(process_id) = process
        .process_id
        .and_then(|value| i32::try_from(value).ok())
    else {
        warn!("terminal child has no usable process ID; killing the direct child");
        process.child.kill().map_err(|error| error.to_string())?;
        return reap_child(process);
    };
    if let Err(error) = signal_process_group(process_id, libc::SIGHUP)
        && error.raw_os_error() != Some(libc::ESRCH)
    {
        warn!(%error, process_id, "failed to hang up terminal process group");
    }
    #[cfg(target_os = "macos")]
    if let Err(error) = signal_session(process_id, libc::SIGHUP) {
        warn!(%error, process_id, "failed to hang up terminal session");
    }
    thread::sleep(Duration::from_millis(250));
    if let Err(error) = signal_process_group(process_id, libc::SIGKILL) {
        if error.raw_os_error() != Some(libc::ESRCH) {
            warn!(%error, process_id, "failed to kill terminal process group");
        }
        // The shell may have changed process groups. Still terminate the child Handshake spawned.
        let _ = process.child.kill();
    }
    #[cfg(target_os = "macos")]
    if let Err(error) = signal_session(process_id, libc::SIGKILL) {
        warn!(%error, process_id, "failed to kill terminal session");
    }
    reap_child(process)
}

fn reap_child(process: &mut ChildProcess) -> ExitResult {
    process
        .child
        .wait()
        .map(|status| TerminalExit {
            exit_code: status.exit_code(),
            signal: status.signal().map(ToOwned::to_owned),
        })
        .map_err(|error| error.to_string())
}

#[cfg(not(unix))]
fn terminate_running_process(process: &mut ChildProcess) -> ExitResult {
    process.child.kill().map_err(|error| error.to_string())?;
    reap_child(process)
}

/// Freeze descendants before killing them, so a running child cannot fork past cleanup.
/// The persistent wrapper and the shell are deliberately outside this set.
pub(super) fn force_stop_harness_children(
    owner: libc::pid_t,
    shell: libc::pid_t,
    started: (u64, u64),
) -> std::io::Result<()> {
    if owner <= 0 || owner == shell || unsafe { libc::getsid(owner) } != shell {
        return Err(std::io::Error::other(
            "harness no longer belongs to this shell",
        ));
    }
    let Some(root) = native_process(owner)? else {
        return Ok(());
    };
    if root.started != started {
        return Ok(());
    }
    let mut pending = vec![(owner, root.parent)];
    let mut stopped = Vec::new();
    let result = (|| {
        while let Some((pid, parent)) = pending.pop() {
            let Some(identity) = native_process(pid)? else {
                continue;
            };
            // Ancestry establishes ownership even when a harness child calls setsid().
            if pid == shell || identity.parent != parent {
                continue;
            }
            stopped.push((pid, identity.started));
            let verified = stop_process(&identity, || native_process(pid), || request_stop(pid))?;
            if verified {
                pending.extend(child_pids(pid)?.into_iter().map(|child| (child, pid)));
            }
        }
        Ok(())
    })();
    // Kill children before their frozen parents, retaining every PID until its last signal.
    // Even an enumeration error must not leave a frozen child behind.
    let mut failure = result.err();
    for (pid, started) in stopped.into_iter().rev() {
        match native_process(pid) {
            Ok(Some(current)) if current.started == started => {
                if unsafe { libc::kill(pid, libc::SIGKILL) } != 0 {
                    let error = std::io::Error::last_os_error();
                    if error.raw_os_error() != Some(libc::ESRCH) {
                        unsafe { libc::kill(pid, libc::SIGCONT) };
                        failure.get_or_insert(error);
                    }
                }
            }
            Err(error) => {
                // Its frozen parent cannot reap this child while cleanup retains it.
                unsafe { libc::kill(pid, libc::SIGCONT) };
                failure.get_or_insert(error);
            }
            _ => {}
        }
    }
    failure.map_or(Ok(()), Err)
}

/// A successful request is not an acknowledgment; retry only the same owned process.
fn stop_process(
    expected: &NativeProcess,
    mut inspect: impl FnMut() -> std::io::Result<Option<NativeProcess>>,
    mut request: impl FnMut() -> std::io::Result<bool>,
) -> std::io::Result<bool> {
    let deadline = std::time::Instant::now() + STOP_ACK_TIMEOUT;
    while let Some(current) = inspect()? {
        if current.started != expected.started || current.parent != expected.parent {
            return Ok(false);
        }
        if current.stopped {
            return Ok(true);
        }
        if std::time::Instant::now() >= deadline {
            return Err(std::io::Error::other("harness child did not stop"));
        }
        if !request()? {
            return Ok(false);
        }
        thread::sleep(STOP_RETRY_INTERVAL);
    }
    Ok(false)
}

fn request_stop(pid: libc::pid_t) -> std::io::Result<bool> {
    // SAFETY: the caller revalidates this owned process's parent and birth identity.
    if unsafe { libc::kill(pid, libc::SIGSTOP) } == 0 {
        return Ok(true);
    }
    let error = std::io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::ESRCH) {
        Ok(false)
    } else {
        Err(error)
    }
}

pub(super) struct NativeProcess {
    parent: libc::pid_t,
    stopped: bool,
    pub(super) started: (u64, u64),
}

#[cfg(target_os = "macos")]
pub(super) fn native_process(pid: libc::pid_t) -> std::io::Result<Option<NativeProcess>> {
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = i32::try_from(std::mem::size_of_val(&info)).expect("native process info fits i32");
    let result =
        unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, (&raw mut info).cast(), size) };
    if result == size {
        return Ok(Some(NativeProcess {
            parent: i32::try_from(info.pbi_ppid)
                .map_err(|_| std::io::Error::other("invalid parent PID"))?,
            stopped: info.pbi_status == libc::SSTOP || info.pbi_status == libc::SZOMB,
            started: (info.pbi_start_tvsec, info.pbi_start_tvusec),
        }));
    }
    let error = std::io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::ESRCH) {
        Ok(None)
    } else {
        Err(error)
    }
}

#[cfg(not(target_os = "macos"))]
pub(super) fn native_process(pid: libc::pid_t) -> std::io::Result<Option<NativeProcess>> {
    let stat = match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
        Ok(stat) => stat,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    let fields: Vec<_> = stat
        .rsplit_once(')')
        .ok_or_else(|| std::io::Error::other("invalid process info"))?
        .1
        .split_whitespace()
        .collect();
    Ok(Some(NativeProcess {
        parent: fields[1]
            .parse()
            .map_err(|_| std::io::Error::other("invalid parent PID"))?,
        stopped: matches!(fields[0], "T" | "t" | "Z"),
        started: (
            fields[19]
                .parse()
                .map_err(|_| std::io::Error::other("invalid process identity"))?,
            0,
        ),
    }))
}

#[cfg(target_os = "macos")]
fn child_pids(parent: libc::pid_t) -> std::io::Result<Vec<libc::pid_t>> {
    let mut capacity = 64;
    loop {
        let mut pids = vec![0; capacity];
        let bytes = std::mem::size_of_val(pids.as_slice());
        let count = unsafe {
            libc::proc_listchildpids(
                parent,
                pids.as_mut_ptr().cast(),
                i32::try_from(bytes)
                    .map_err(|_| std::io::Error::other("too many harness children"))?,
            )
        };
        if count < 0 {
            return Err(std::io::Error::last_os_error());
        }
        let count =
            usize::try_from(count).map_err(|_| std::io::Error::other("invalid child count"))?;
        if count == capacity {
            capacity *= 2;
            continue;
        }
        pids.truncate(count);
        return Ok(pids);
    }
}

#[cfg(not(target_os = "macos"))]
fn child_pids(parent: libc::pid_t) -> std::io::Result<Vec<libc::pid_t>> {
    let mut children = Vec::new();
    for entry in std::fs::read_dir("/proc")?.flatten() {
        let Ok(pid) = entry.file_name().to_string_lossy().parse::<libc::pid_t>() else {
            continue;
        };
        let Ok(stat) = std::fs::read_to_string(entry.path().join("stat")) else {
            continue;
        };
        if stat
            .rsplit_once(')')
            .and_then(|(_, tail)| tail.split_whitespace().nth(1))
            .and_then(|value| value.parse::<libc::pid_t>().ok())
            == Some(parent)
        {
            children.push(pid);
        }
    }
    Ok(children)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    #[test]
    fn stop_retries_a_successful_request_without_an_acknowledgment() {
        let expected = NativeProcess {
            parent: 42,
            stopped: false,
            started: (1, 2),
        };
        let requests = Cell::new(0);
        let stopped = stop_process(
            &expected,
            || {
                Ok(Some(NativeProcess {
                    parent: expected.parent,
                    started: expected.started,
                    stopped: requests.get() >= 2,
                }))
            },
            || {
                requests.set(requests.get() + 1);
                Ok(true)
            },
        )
        .unwrap();
        assert!(stopped);
        assert_eq!(requests.get(), 2);
    }

    #[test]
    fn stop_retries_never_signal_a_changed_birth_or_parent() {
        for changed_parent in [false, true] {
            let expected = NativeProcess {
                parent: 42,
                stopped: false,
                started: (1, 2),
            };
            let requests = Cell::new(0);
            let stopped = stop_process(
                &expected,
                || {
                    let changed = requests.get() > 0;
                    Ok(Some(NativeProcess {
                        parent: if changed && changed_parent { 43 } else { 42 },
                        started: if changed && !changed_parent {
                            (1, 3)
                        } else {
                            (1, 2)
                        },
                        stopped: false,
                    }))
                },
                || {
                    requests.set(requests.get() + 1);
                    Ok(true)
                },
            )
            .unwrap();
            assert!(!stopped);
            assert_eq!(requests.get(), 1);
        }
    }
}
