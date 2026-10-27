use serde_json::json;

use crate::error::BridgeError;
use crate::ffi::{self, HandshakeBuffer, HandshakeStatus, catch_status};

#[unsafe(no_mangle)]
/// Reads (0), enables (1), or disables (2) the app-wide Keep Awake process.
/// # Safety
/// Output must be aligned writable storage without an unreleased allocation. Null is rejected.
pub unsafe extern "C" fn handshake_keep_awake(
    operation: u32,
    output: *mut HandshakeBuffer,
) -> HandshakeStatus {
    catch_status(|| {
        // SAFETY: The helper checks null before any operation can change core state.
        unsafe { ffi::initialize_buffer(output) }?;
        let enabled = match operation {
            0 => None,
            1 => Some(true),
            2 => Some(false),
            _ => return Err(BridgeError::InvalidArgument),
        };
        let response = match handshake_core::keep_awake(enabled) {
            Ok(enabled) => json!({"enabled": enabled, "error": null}),
            Err(error) => json!({"error": error.to_string()}),
        };
        let bytes = serde_json::to_vec(&response)?;
        // SAFETY: Validated output receives one allocation, released with handshake_buffer_release.
        unsafe { ffi::write_buffer(output, HandshakeBuffer::from_vec(bytes)) }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invalid_requests_do_not_change_power_state_or_allocate_output() {
        // SAFETY: Null is explicitly accepted for validation; the second call owns empty output.
        unsafe {
            assert_eq!(
                handshake_keep_awake(1, std::ptr::null_mut()),
                HandshakeStatus::NullPointer
            );
            let mut output = HandshakeBuffer::empty();
            assert_eq!(
                handshake_keep_awake(3, &raw mut output),
                HandshakeStatus::InvalidArgument
            );
            assert!(output.data.is_null());
            assert_eq!(output.length, 0);
        }
    }
}
