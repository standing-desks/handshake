use handshake_core::ApplicationError;
use thiserror::Error;

#[derive(Debug, Error)]
pub(crate) enum BridgeError {
    #[error(transparent)]
    Memory(#[from] handshake_core::memories::MemoryError),
    #[error(transparent)]
    Config(#[from] handshake_core::config::ConfigEditError),
    #[error(transparent)]
    Application(#[from] ApplicationError),
    #[error("input exceeds the maximum size")]
    InputTooLarge,
    #[error("no value is available")]
    Empty,
    #[error("invalid bridge argument")]
    InvalidArgument,
    #[error("input is not valid UTF-8")]
    InvalidUtf8,
    #[error("command is not valid JSON")]
    MalformedCommand,
    #[error("required pointer is null")]
    NullPointer,
    #[error("failed to initialize Rust logging: {0}")]
    Subscriber(String),
    #[error(transparent)]
    Serialization(#[from] serde_json::Error),
}
