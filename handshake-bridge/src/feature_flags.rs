//! Feature-flag request adaptation; settings policy and persistence remain in core.
use serde::Deserialize;
use serde_json::json;

use crate::error::BridgeError;
use crate::ffi::{self, HandshakeBuffer, HandshakeStatus, catch_status};
use crate::protocol::files::{Version, encode_preview, encode_save};

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "camelCase", deny_unknown_fields)]
enum Request {
    Read,
    Set {
        id: handshake_core::config::FeatureFlag,
        enabled: bool,
        #[serde(rename = "expectedVersion")]
        expected_version: Version,
    },
}

#[unsafe(no_mangle)]
/// Reads the feature catalog or updates one receiver-owned flag with version protection.
/// # Safety
/// Input and owned output follow the bounded pointer contracts in `handshake_bridge.h`.
pub unsafe extern "C" fn handshake_feature_flags(
    bytes: *const u8,
    length: usize,
    output: *mut HandshakeBuffer,
) -> HandshakeStatus {
    catch_status(|| {
        // SAFETY: output is checked before reading any caller input or allocating a result.
        unsafe { ffi::initialize_buffer(output) }?;
        // SAFETY: the common reader validates the supplied pointer and bounds.
        let response = unsafe {
            ffi::with_input_bytes(bytes, length, crate::MAX_COMMAND_BYTES, |bytes| {
                let request = serde_json::from_slice::<Request>(bytes)
                    .map_err(|_| BridgeError::MalformedCommand)?;
                let value = match request {
                    Request::Read => match handshake_core::config::read_feature_flags() {
                        Ok(snapshot) => {
                            json!({"snapshot":{"flags":snapshot.flags,"file":encode_preview(&snapshot.file)},"error":null})
                        }
                        Err(error) => json!({"error":error.to_string()}),
                    },
                    Request::Set {
                        id,
                        enabled,
                        expected_version,
                    } => {
                        let result = handshake_core::config::set_feature_flag(
                            id,
                            enabled,
                            expected_version.into(),
                        );
                        json!({"result":serde_json::from_slice::<serde_json::Value>(&encode_save(result)?)?,"error":null})
                    }
                };
                Ok(serde_json::to_vec(&value)?)
            })
        }?;
        // SAFETY: output is initialized and has one owned allocation, released by the caller.
        unsafe { ffi::write_buffer(output, HandshakeBuffer::from_vec(response)) }
    })
}
