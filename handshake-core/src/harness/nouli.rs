//! Owned, cancellable evaluations using the Nouli library bundled into `HandshakeCore`.
use std::path::{Path, PathBuf};
use std::sync::{Arc, mpsc};
use std::thread::JoinHandle;
use std::time::Duration;

use nouli_core::{
    engine::{
        Engine, EvaluationInput,
        execution::{NativeProvider, TokioClock},
    },
    history::{EvaluationRequest, ModelSelection, SessionSelection, StandingChanges},
    limits::count::ByteCounter,
    protocol::{Report, ResultEnvelope, TurnReport},
};
use serde_json::Value;
use thiserror::Error;
use tokio_util::sync::CancellationToken;

use super::LoginPath;
use crate::workflow_type::DecisionNode;

mod credentials;
#[cfg(test)]
pub(crate) mod fixture;
mod settings;

const MAX_OUTPUT: usize = 2 * 1024 * 1024;
const TIMEOUT: Duration = Duration::from_secs(600);

#[derive(Debug, Error)]
pub(crate) enum NouliError {
    #[error("Could not start the bundled Nouli runtime.")]
    Io(#[from] std::io::Error),
    #[error("Nouli exceeded the decision time or output limit.")]
    Limit,
    #[error("Nouli returned an invalid decision report.")]
    Report,
    #[error("Nouli evaluation was cancelled.")]
    Cancelled,
    #[error("{0}")]
    Evaluation(String),
    #[error(transparent)]
    Settings(#[from] settings::SettingsError),
}

pub(crate) struct Invocation {
    cancel: CancellationToken,
    worker: Option<JoinHandle<()>>,
    receiver: mpsc::Receiver<Result<Value, String>>,
    completed: Option<Result<Value, String>>,
}

impl Invocation {
    pub(crate) fn start(
        folder: &Path,
        node: &DecisionNode,
        request: &Value,
        home: Option<PathBuf>,
        login_path: Arc<LoginPath>,
    ) -> Result<Self, NouliError> {
        if serde_json::to_vec(request)
            .map_err(|_| NouliError::Report)?
            .len()
            > 128 * 1024
        {
            return Err(NouliError::Limit);
        }
        let (folder, node, request) = (folder.to_owned(), node.clone(), request.clone());
        let environment = std::env::vars_os().collect();
        let cancel = CancellationToken::new();
        let token = cancel.clone();
        let (sender, receiver) = mpsc::sync_channel(1);
        let worker = crate::blocking_worker::spawn("nouli-decision".into(), move || {
            let result = (|| {
                let settings = settings::Settings::load(&folder, home, environment)?;
                let credential = settings.credential(&node, &token, &login_path)?;
                if token.is_cancelled() {
                    return Err(NouliError::Cancelled);
                }
                let runtime = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()?;
                let result = runtime.block_on(async {
                    tokio::select! {
                        biased;
                        () = token.cancelled() => Err(NouliError::Cancelled),
                        result = tokio::time::timeout(TIMEOUT, evaluate(&settings, &node, request, credential, &token)) => result.map_err(|_| NouliError::Limit)?,
                    }
                });
                // DNS resolution can use Tokio's blocking pool; it must not hold shutdown open.
                runtime.shutdown_timeout(Duration::from_millis(100));
                result
            })();
            let _ = sender.send(result.map_err(|error: NouliError| error.to_string()));
        })?;
        Ok(Self {
            cancel,
            worker: Some(worker),
            receiver,
            completed: None,
        })
    }

    pub(crate) fn poll(&mut self) -> Option<Result<Value, String>> {
        if self.completed.is_none() {
            self.completed = match self.receiver.try_recv() {
                Ok(result) => Some(result),
                Err(mpsc::TryRecvError::Empty) => None,
                Err(mpsc::TryRecvError::Disconnected) => Some(Err(
                    "The bundled Nouli worker stopped before returning a result.".into(),
                )),
            };
        }
        self.completed.clone()
    }
}

impl Drop for Invocation {
    fn drop(&mut self) {
        self.cancel.cancel();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

async fn evaluate(
    settings: &settings::Settings,
    node: &DecisionNode,
    request: Value,
    credential: Option<(nouli_core::config::auth::CredentialSource, String)>,
    cancel: &CancellationToken,
) -> Result<Value, NouliError> {
    let request = EvaluationRequest {
        turn: serde_json::from_value(request).map_err(|_| NouliError::Report)?,
        session: SessionSelection::New { name: None },
        standing: StandingChanges::default(),
        updates: vec![],
        required_records: vec![],
        request_id: None,
        model: ModelSelection {
            provider: node.provider.clone(),
            model: node.model.clone(),
        },
    };
    let engine = Engine {
        provider: NativeProvider,
        counter: ByteCounter,
        clock: TokioClock,
    };
    let result = engine
        .evaluate_ephemeral(
            None,
            EvaluationInput {
                request: &request,
                config: &settings.config,
                overrides: &settings.overrides,
                home: &settings.home,
                retry_interrupted: false,
            },
            |source| {
                credential
                    .as_ref()
                    .filter(|(origin, _)| origin == source)
                    .map(|(_, value)| value.clone())
            },
            cancel,
        )
        .await
        .map_err(|error| {
            let report = error.report();
            let message = match &error {
                nouli_core::engine::EngineError::Provider(
                    nouli_core::provider::ProviderError::Transport(source),
                ) => source.to_string(),
                _ => report.message,
            };
            NouliError::Evaluation(format!(
                "Nouli: {} ({}). Configuration: {}",
                message,
                report.code,
                settings.path.display()
            ))
        })?;
    let envelope = ResultEnvelope::new(Report::Turn(Box::new(TurnReport {
        questions: result.request.questions,
        session: None,
        turn: None,
        outcome: result.outcome,
        manifest: result.manifest,
        replayed: false,
    })));
    let bytes = serde_json::to_vec(&envelope).map_err(|_| NouliError::Report)?;
    if bytes.len() > MAX_OUTPUT {
        return Err(NouliError::Limit);
    }
    serde_json::from_slice(&bytes).map_err(|_| NouliError::Report)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::time::Instant;

    #[test]
    fn bundled_engine_reads_saved_credentials_without_cli_and_does_not_export_secrets() {
        let home = tempfile::tempdir().unwrap();
        let folder = tempfile::tempdir().unwrap();
        let provider = fixture::Provider::new(home.path());
        let path = home.path().join(".nouli/auth.toml");
        std::fs::write(
            &path,
            "[providers.fixture]\ntype = \"api_key\"\nkey = \"SENTINEL_STORED_KEY\"\n",
        )
        .unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
        let node: DecisionNode =
            serde_json::from_value(serde_json::json!({"kind":"noul","question":"Is it ready?"}))
                .unwrap();
        let mut call = Invocation::start(
            folder.path(),
            &node,
            &node.request("A task", "Evidence"),
            Some(home.path().into()),
            Arc::new(LoginPath::ready(None)),
        )
        .unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        let report = loop {
            if let Some(result) = call.poll() {
                break result.unwrap();
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(5));
        };
        assert_eq!(node.route(&report).unwrap(), "yes");
        assert_eq!(provider.calls(), 1);
        assert!(
            provider.received.lock().unwrap()[0]["headers"]
                .as_str()
                .unwrap()
                .contains("Bearer SENTINEL_STORED_KEY")
        );
        assert!(!report.to_string().contains("SENTINEL_STORED_KEY"));
        assert_eq!(
            std::fs::read_dir(home.path().join(".nouli"))
                .unwrap()
                .count(),
            2
        );
        assert_eq!(call.poll().unwrap().unwrap(), report);
    }
}
