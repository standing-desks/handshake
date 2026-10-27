//! App-wide, temporary sleep prevention, independent of folder and agent lifetimes.
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;

use thiserror::Error;

static CONTROLLER: Mutex<Controller> = Mutex::new(Controller { child: None });

#[derive(Debug, Error)]
pub enum KeepAwakeError {
    #[error("Keep Awake is only available on macOS")]
    Unsupported,
    #[error("Keep Awake could not access its process: {0}")]
    Process(#[from] std::io::Error),
    #[error("Keep Awake state is unavailable")]
    Poisoned,
}

/// Reads the live state, optionally enabling or disabling it for the whole application process.
/// Call with `Some(false)` during normal app shutdown. The child also watches this process so
/// a crash cannot leave sleep prevention running. State is never persisted.
///
/// # Errors
/// Returns an error if process supervision fails or the platform does not support Keep Awake.
pub fn keep_awake(enabled: Option<bool>) -> Result<bool, KeepAwakeError> {
    let mut controller = CONTROLLER.lock().map_err(|_| KeepAwakeError::Poisoned)?;
    if let Some(enabled) = enabled {
        controller.set(enabled, || {
            if !cfg!(target_os = "macos") {
                return Err(KeepAwakeError::Unsupported);
            }
            Ok(Command::new("/usr/bin/caffeinate")
                .args(["-disu", "-w", &std::process::id().to_string()])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()?)
        })?;
    }
    Ok(controller.active()?)
}

#[derive(Default)]
struct Controller {
    child: Option<Child>,
}

impl Controller {
    fn active(&mut self) -> std::io::Result<bool> {
        if let Some(child) = &mut self.child
            && child.try_wait()?.is_some()
        {
            self.child = None;
        }
        Ok(self.child.is_some())
    }

    fn set(
        &mut self,
        enabled: bool,
        launch: impl FnOnce() -> Result<Child, KeepAwakeError>,
    ) -> Result<(), KeepAwakeError> {
        let active = self.active()?;
        if enabled && !active {
            self.child = Some(launch()?);
        } else if !enabled {
            self.stop()?;
        }
        Ok(())
    }

    fn stop(&mut self) -> std::io::Result<()> {
        if let Some(child) = &mut self.child {
            child.kill()?;
            child.wait()?;
        }
        self.child = None;
        Ok(())
    }
}

impl Drop for Controller {
    fn drop(&mut self) {
        if let Err(error) = self.stop() {
            tracing::warn!(%error, "Keep Awake process cleanup failed");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sleeper() -> Result<Child, KeepAwakeError> {
        Ok(Command::new("/bin/sleep").arg("30").spawn()?)
    }

    #[test]
    fn repeated_enable_reuses_the_child_and_disable_reaps_it() {
        let mut controller = Controller::default();
        assert!(!controller.active().unwrap());
        controller.set(true, sleeper).unwrap();
        let pid = controller.child.as_ref().unwrap().id();
        controller.set(true, || panic!("already running")).unwrap();
        assert_eq!(controller.child.as_ref().unwrap().id(), pid);
        controller
            .set(false, || panic!("disable must not launch"))
            .unwrap();
        assert!(!controller.active().unwrap());
        assert!(
            !Command::new("/bin/kill")
                .args(["-0", &pid.to_string()])
                .stderr(Stdio::null())
                .status()
                .unwrap()
                .success()
        );
        controller.set(false, sleeper).unwrap();
    }

    #[test]
    fn launch_failure_stays_off_and_can_be_retried() {
        let mut controller = Controller::default();
        assert!(
            controller
                .set(true, || Err(std::io::Error::from(
                    std::io::ErrorKind::NotFound
                )
                .into()))
                .is_err()
        );
        assert!(!controller.active().unwrap());
        controller.set(true, sleeper).unwrap();
        assert!(controller.active().unwrap());
    }

    #[test]
    fn external_exit_is_reaped_and_can_be_restarted() {
        let mut controller = Controller::default();
        controller.set(true, sleeper).unwrap();
        controller.child.as_mut().unwrap().kill().unwrap();
        controller.child.as_mut().unwrap().wait().unwrap();
        assert!(!controller.active().unwrap());
        controller.set(true, sleeper).unwrap();
        assert!(controller.active().unwrap());
    }
}
