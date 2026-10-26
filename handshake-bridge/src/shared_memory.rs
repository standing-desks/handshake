use super::error::BridgeError;
use super::ffi::{self, HandshakeBuffer, HandshakeStatus, catch_status};

#[unsafe(no_mangle)]
/// Performs a bounded folder memory operation; storage and policy are owned by core.
///
/// # Safety
/// Uses the bounded input and owned output contracts in `handshake_bridge.h`.
pub unsafe extern "C" fn handshake_shared_memory(
    bytes: *const u8,
    length: usize,
    output: *mut HandshakeBuffer,
) -> HandshakeStatus {
    catch_status(|| {
        // SAFETY: Shared helpers validate pointers and lengths before dereferencing.
        unsafe { ffi::initialize_buffer(output) }?;
        // SAFETY: Forwarded caller contract, enforced by the shared bounded reader.
        let response = unsafe {
            ffi::with_input_bytes(bytes, length, super::MAX_COMMAND_BYTES, |bytes| {
                let request = serde_json::from_slice::<
                    handshake_core::memories::shared::SharedRequest,
                >(bytes)
                .map_err(|_| BridgeError::MalformedCommand)?;
                let value = match handshake_core::memories::shared::execute(&request) {
                    Ok(snapshot) => serde_json::json!({"snapshot": snapshot, "error": null}),
                    Err(error) => serde_json::json!({"snapshot": null, "error": error.to_string()}),
                };
                Ok(serde_json::to_vec(&value)?)
            })
        }?;
        // SAFETY: Output was validated before allocating the response buffer.
        unsafe { ffi::write_buffer(output, HandshakeBuffer::from_vec(response)) }
    })
}
