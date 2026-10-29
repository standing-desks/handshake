//! Window-scoped browser commands. The native host executes operations; core owns authority.
mod server;
pub use server::request;

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex, mpsc};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

pub const REQUEST_LIMIT: usize = 64 * 1024;
pub const RESPONSE_LIMIT: usize = 12 * 1024 * 1024;
const TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
pub enum Action {
    List,
    Open {
        url: String,
    },
    Navigate {
        url: String,
    },
    Snapshot,
    Click {
        element: String,
    },
    Hover {
        element: String,
    },
    Select {
        element: String,
        value: String,
    },
    Fill {
        element: String,
        text: String,
    },
    Press {
        key: String,
    },
    Scroll {
        dy: i32,
    },
    Screenshot,
    Wait {
        text: String,
    },
    WaitUrl {
        text: String,
    },
    WaitElement {
        element: String,
        state: ElementState,
    },
    WaitLoad,
    Console,
    Close,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ElementState {
    Visible,
    Hidden,
    Enabled,
}

pub(crate) fn cli_path() -> std::io::Result<std::path::PathBuf> {
    let exe = std::env::current_exe()?;
    let parent = exe
        .parent()
        .ok_or_else(|| std::io::Error::other("Missing application directory"))?;
    Ok(parent.parent().unwrap_or(parent).join("Helpers/handshake"))
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub token: String,
    pub tab: Option<String>,
    pub action: Action,
}

#[derive(Clone, Serialize)]
pub struct Job {
    pub id: String,
    pub session: String,
    pub tab: String,
    pub action: Action,
}

#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum HostCommand {
    Poll,
    Complete { id: String, result: Value },
    Stop { session: String },
    Closed { tab: String },
}

struct Pending {
    job: Job,
    deadline: Instant,
    reply: mpsc::SyncSender<Value>,
}

#[derive(Default)]
struct State {
    enabled: bool,
    sessions: HashMap<String, String>,
    owners: HashMap<String, String>,
    pending: HashMap<String, Pending>,
    queue: VecDeque<String>,
}

pub struct BrowserControl {
    state: Arc<Mutex<State>>,
    server: server::Server,
}

pub(crate) fn failure(code: &str, message: &str) -> Value {
    json!({"ok":false,"error":{"code":code,"message":message}})
}

impl BrowserControl {
    /// Creates a private Unix socket for one window runtime.
    /// # Errors
    /// Returns an I/O error if the listener cannot be created.
    pub fn new() -> std::io::Result<Self> {
        let state = Arc::new(Mutex::new(State::default()));
        let server = server::Server::start(Arc::clone(&state))?;
        Ok(Self { state, server })
    }

    pub(crate) fn is_enabled(&self) -> bool {
        self.state.lock().is_ok_and(|state| state.enabled)
    }

    pub(crate) fn set_enabled(&self, enabled: bool) {
        if let Ok(mut state) = self.state.lock() {
            state.enabled = enabled;
            if !enabled {
                state.sessions.clear();
                state.owners.clear();
                state.cancel(|_| true, "Browser control was disabled in Settings.");
                state.queue.clear();
            }
        }
    }

    pub(crate) fn environment(&self, terminal: u64) -> Vec<(String, String)> {
        let Ok(mut state) = self.state.lock() else {
            return Vec::new();
        };
        if !state.enabled {
            return Vec::new();
        }
        let token = uuid::Uuid::new_v4().to_string();
        let session = format!("Terminal {terminal}");
        state.sessions.insert(token.clone(), session);
        let mut environment = vec![
            (
                "HANDSHAKE_BROWSER_SOCKET".into(),
                self.server.path().to_string_lossy().into_owned(),
            ),
            ("HANDSHAKE_BROWSER_TOKEN".into(), token),
        ];
        if let Ok(cli) = cli_path() {
            environment.push(("HANDSHAKE_CLI".into(), cli.to_string_lossy().into_owned()));
        }
        environment
    }

    pub(crate) fn stop_terminal(&self, terminal: u64) {
        let _ = self.host(HostCommand::Stop {
            session: format!("Terminal {terminal}"),
        });
    }

    #[cfg(test)]
    pub(crate) fn session_count(&self) -> usize {
        self.state.lock().unwrap().sessions.len()
    }

    /// Applies a host command without waiting on `WebKit` or a socket client.
    #[must_use]
    pub fn host(&self, command: HostCommand) -> Value {
        let Ok(mut state) = self.state.lock() else {
            return failure("unavailable", "Browser control is unavailable.");
        };
        state.expire();
        match command {
            HostCommand::Poll => {
                let jobs: Vec<_> = state.queue.drain(..).collect();
                let jobs: Vec<_> = jobs
                    .iter()
                    .filter_map(|id| state.pending.get(id).map(|p| p.job.clone()))
                    .collect();
                json!({"jobs":jobs,"owners":state.owners,"active":state.pending.keys().collect::<Vec<_>>()})
            }
            HostCommand::Complete { id, result } => {
                if let Some(pending) = state.pending.remove(&id) {
                    if matches!(pending.job.action, Action::Close)
                        || (matches!(pending.job.action, Action::Open { .. })
                            && result["ok"] != true)
                    {
                        state.owners.remove(&pending.job.tab);
                    }
                    let _ = pending.reply.send(result);
                }
                json!({"ok":true})
            }
            HostCommand::Stop { session } => {
                state.sessions.retain(|_, value| value != &session);
                state.owners.retain(|_, value| value != &session);
                state.cancel(
                    |p| p.job.session == session,
                    "Browser control was stopped. Start a new terminal to grant control again.",
                );
                json!({"ok":true})
            }
            HostCommand::Closed { tab } => {
                state.owners.remove(&tab);
                state.cancel(|p| p.job.tab == tab, "The browser tab was closed.");
                json!({"ok":true})
            }
        }
    }
}

impl State {
    fn expire(&mut self) {
        self.cancel(
            |p| Instant::now() >= p.deadline,
            "Browser command timed out.",
        );
        self.queue.retain(|id| self.pending.contains_key(id));
    }

    fn cancel(&mut self, predicate: impl Fn(&Pending) -> bool, message: &str) {
        let owners = &mut self.owners;
        self.pending.retain(|_, p| {
            if predicate(p) {
                if matches!(p.job.action, Action::Open { .. }) {
                    owners.remove(&p.job.tab);
                }
                let _ = p.reply.send(failure("cancelled", message));
                false
            } else {
                true
            }
        });
    }

    fn submit(&mut self, request: Request) -> Result<mpsc::Receiver<Value>, Value> {
        self.expire();
        if !self.enabled {
            return Err(failure(
                "feature_disabled",
                "Enable Agent browser control in Settings > Experimental, then start a new terminal or agent.",
            ));
        }
        let session = self
            .sessions
            .get(&request.token)
            .ok_or_else(|| {
                failure(
                    "unauthorized",
                    "This terminal has no browser authority, or the user stopped it.",
                )
            })?
            .clone();
        if self.pending.len() >= 16 || self.pending.values().any(|p| p.job.session == session) {
            return Err(failure(
                "busy",
                "Wait for the current browser command to finish.",
            ));
        }
        let tab = if matches!(request.action, Action::Open { .. }) {
            let id = uuid::Uuid::new_v4().to_string();
            self.owners.insert(id.clone(), session.clone());
            id
        } else if matches!(request.action, Action::List) {
            String::new()
        } else {
            let id = request.tab.ok_or_else(|| {
                failure("invalid", "Specify --tab using the ID returned by open.")
            })?;
            if self.owners.get(&id) != Some(&session) {
                return Err(failure(
                    "not_owned",
                    "This tab is not controlled by this terminal. Open a browser tab first.",
                ));
            }
            id
        };
        let id = uuid::Uuid::new_v4().to_string();
        let (reply, receiver) = mpsc::sync_channel(1);
        self.queue.push_back(id.clone());
        self.pending.insert(
            id.clone(),
            Pending {
                job: Job {
                    id,
                    session,
                    tab,
                    action: request.action,
                },
                deadline: Instant::now() + TIMEOUT,
                reply,
            },
        );
        Ok(receiver)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(token: &str, tab: Option<String>, action: Action) -> Request {
        Request {
            token: token.into(),
            tab,
            action,
        }
    }

    #[test]
    fn flag_defaults_off_and_disabling_revokes_pending_and_future_authority() {
        let control = BrowserControl::new().unwrap();
        assert!(!control.is_enabled());
        assert_eq!(control.environment(1), Vec::<(String, String)>::new());
        control.set_enabled(true);
        let token = control.environment(1)[1].1.clone();
        let receiver = control
            .state
            .lock()
            .unwrap()
            .submit(request(
                &token,
                None,
                Action::Open {
                    url: "https://example.test".into(),
                },
            ))
            .unwrap();
        let job = control.host(HostCommand::Poll)["jobs"][0].clone();
        control.set_enabled(false);
        assert_eq!(receiver.recv().unwrap()["error"]["code"], "cancelled");
        assert_eq!(control.environment(2), Vec::<(String, String)>::new());
        let rejected = control
            .state
            .lock()
            .unwrap()
            .submit(request(&token, None, Action::List))
            .unwrap_err();
        assert_eq!(rejected["error"]["code"], "feature_disabled");
        let _ = control.host(HostCommand::Complete {
            id: job["id"].as_str().unwrap().into(),
            result: json!({"ok":true}),
        });
        control.set_enabled(true);
        assert!(
            control.host(HostCommand::Poll)["owners"]
                .as_object()
                .unwrap()
                .is_empty()
        );
        let rejected = control
            .state
            .lock()
            .unwrap()
            .submit(request(&token, None, Action::List))
            .unwrap_err();
        assert_eq!(rejected["error"]["code"], "unauthorized");
        assert_eq!(control.environment(3).len(), 3);
    }

    #[test]
    fn ownership_stop_and_late_completion_are_enforced() {
        let control = BrowserControl::new().unwrap();
        control.set_enabled(true);
        let env = control.environment(1);
        let token = &env[1].1;
        let other = control.environment(2)[1].1.clone();
        let receiver = control
            .state
            .lock()
            .unwrap()
            .submit(request(
                token,
                None,
                Action::Open {
                    url: "https://example.com".into(),
                },
            ))
            .unwrap();
        let poll = control.host(HostCommand::Poll);
        let job = &poll["jobs"][0];
        let tab = job["tab"].as_str().unwrap().to_owned();
        assert!(
            control
                .state
                .lock()
                .unwrap()
                .submit(request(&other, Some(tab), Action::Snapshot))
                .is_err()
        );
        control.stop_terminal(1);
        assert_eq!(receiver.recv().unwrap()["error"]["code"], "cancelled");
        let _ = control.host(HostCommand::Complete {
            id: job["id"].as_str().unwrap().into(),
            result: json!({"ok":true}),
        });
        assert!(
            control
                .state
                .lock()
                .unwrap()
                .submit(request(token, None, Action::List))
                .is_err()
        );
        assert!(
            control.host(HostCommand::Poll)["owners"]
                .as_object()
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn expired_requests_do_not_execute_and_other_sessions_progress() {
        let mut state = State {
            enabled: true,
            ..State::default()
        };
        state.sessions.insert("token".into(), "one".into());
        let receiver = state.submit(request("token", None, Action::List)).unwrap();
        assert!(state.submit(request("token", None, Action::List)).is_err());
        state.pending.values_mut().next().unwrap().deadline = Instant::now();
        state.expire();
        assert!(state.queue.is_empty());
        assert_eq!(receiver.recv().unwrap()["ok"], false);
        assert!(state.submit(request("token", None, Action::List)).is_ok());
    }

    #[test]
    fn expired_open_releases_reserved_ownership() {
        let mut state = State {
            enabled: true,
            ..State::default()
        };
        state.sessions.insert("token".into(), "one".into());
        let receiver = state
            .submit(request(
                "token",
                None,
                Action::Open {
                    url: "https://example.test".into(),
                },
            ))
            .unwrap();
        assert_eq!(state.owners.len(), 1);
        state.pending.values_mut().next().unwrap().deadline = Instant::now();
        state.expire();
        assert!(state.owners.is_empty());
        assert!(state.queue.is_empty());
        assert_eq!(receiver.recv().unwrap()["ok"], false);
    }

    #[test]
    fn cli_wire_round_trip_and_shutdown() {
        let control = BrowserControl::new().unwrap();
        control.set_enabled(true);
        let env = control.environment(1);
        let path = std::path::PathBuf::from(&env[0].1);
        let token = env[1].1.clone();
        let worker = std::thread::spawn(move || {
            super::request(&path, &request(&token, None, Action::List)).unwrap()
        });
        let deadline = Instant::now() + Duration::from_secs(3);
        let id = loop {
            let poll = control.host(HostCommand::Poll);
            if let Some(id) = poll["jobs"][0]["id"].as_str() {
                break id.to_owned();
            }
            assert!(Instant::now() < deadline, "request did not reach the host");
            std::thread::sleep(Duration::from_millis(10));
        };
        let _ = control.host(HostCommand::Complete {
            id,
            result: json!({"ok":true,"content":"[]"}),
        });
        assert_eq!(worker.join().unwrap()["ok"], true);
        let path = control.server.path();
        let unauthorized = super::request(&path, &request("unknown", None, Action::List)).unwrap();
        assert_eq!(unauthorized["error"]["code"], "unauthorized");
        drop(control);
        assert!(!path.exists());
    }
}
