use super::error::BridgeError;
use super::ffi::{self, HandshakeBuffer, HandshakeStatus, catch_status};
use super::protocol::files::{Version, encode_preview, encode_save};
use handshake_core::memories::MemoryRequest;
use serde::Deserialize;

#[unsafe(no_mangle)]
/// Lists local memory sources without an application runtime.
///
/// # Safety
/// Follows the bounded input and output ownership contracts in `handshake_bridge.h`.
pub unsafe extern "C" fn handshake_memory_catalog(
    bytes: *const u8,
    length: usize,
    output: *mut HandshakeBuffer,
) -> HandshakeStatus {
    // SAFETY: Forwarded caller contract, checked by the shared FFI helpers.
    unsafe { request(bytes, length, output, false) }
}

#[unsafe(no_mangle)]
/// Reads one discovered memory source by its opaque ID.
///
/// # Safety
/// Follows the bounded input and output ownership contracts in `handshake_bridge.h`.
pub unsafe extern "C" fn handshake_memory_read(
    bytes: *const u8,
    length: usize,
    output: *mut HandshakeBuffer,
) -> HandshakeStatus {
    // SAFETY: Forwarded caller contract, checked by the shared FFI helpers.
    unsafe { request(bytes, length, output, true) }
}

unsafe fn request(
    bytes: *const u8,
    length: usize,
    output: *mut HandshakeBuffer,
    read: bool,
) -> HandshakeStatus {
    catch_status(|| {
        // SAFETY: Null is rejected before the output is initialized.
        unsafe { ffi::initialize_buffer(output) }?;
        // SAFETY: The caller provides readable input under the documented length bound.
        let response = unsafe {
            ffi::with_input_bytes(bytes, length, super::MAX_COMMAND_BYTES, |bytes| {
                let request: MemoryRequest =
                    serde_json::from_slice(bytes).map_err(|_| BridgeError::MalformedCommand)?;
                if read {
                    let read = handshake_core::memories::read(&request)?;
                    let mut value = serde_json::to_value(&read)?;
                    value["file"] = read
                        .file
                        .as_ref()
                        .map_or(serde_json::Value::Null, encode_preview);
                    Ok(serde_json::to_vec(&value)?)
                } else {
                    Ok(serde_json::to_vec(&handshake_core::memories::catalog(
                        &request,
                    )?)?)
                }
            })
        }?;
        // SAFETY: The output was validated before allocating an owned response.
        unsafe { ffi::write_buffer(output, HandshakeBuffer::from_vec(response)) }
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SaveRequest {
    source: MemoryRequest,
    text: String,
    expected_version: Version,
    overwrite: bool,
}

#[unsafe(no_mangle)]
/// Saves one discovered local Markdown file after checking its disk version.
///
/// # Safety
/// Follows the bounded input and output ownership contracts in `handshake_bridge.h`.
pub unsafe extern "C" fn handshake_memory_save(
    bytes: *const u8,
    length: usize,
    output: *mut HandshakeBuffer,
) -> HandshakeStatus {
    catch_status(|| {
        // SAFETY: Null is rejected before initialization; input uses the shared bound.
        unsafe { ffi::initialize_buffer(output) }?;
        // SAFETY: The caller supplies readable bytes; the helper rejects invalid lengths.
        let response = unsafe {
            ffi::with_input_bytes(bytes, length, super::MAX_FILE_SAVE_BYTES, |bytes| {
                let request: SaveRequest =
                    serde_json::from_slice(bytes).map_err(|_| BridgeError::MalformedCommand)?;
                Ok(encode_save(handshake_core::memories::save(
                    &request.source,
                    request.text,
                    request.expected_version.into(),
                    request.overwrite,
                ))?)
            })
        }?;
        // SAFETY: The output was validated before allocating an owned response.
        unsafe { ffi::write_buffer(output, HandshakeBuffer::from_vec(response)) }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::TEST_LOCK;

    #[test]
    fn memory_calls_reject_invalid_pointers_and_oversized_requests() {
        let _guard = TEST_LOCK.lock().expect("test lock should be available");
        let mut output = HandshakeBuffer::empty();
        // SAFETY: All rejected arguments are checked without dereferencing them.
        unsafe {
            assert_eq!(
                handshake_memory_catalog(std::ptr::null(), 1, &raw mut output),
                HandshakeStatus::NullPointer
            );
            assert_eq!(
                handshake_memory_read(
                    std::ptr::null(),
                    super::super::MAX_COMMAND_BYTES + 1,
                    &raw mut output
                ),
                HandshakeStatus::InvalidArgument
            );
            assert_eq!(
                handshake_memory_catalog(std::ptr::null(), 0, std::ptr::null_mut()),
                HandshakeStatus::NullPointer
            );
            assert_eq!(
                handshake_memory_save(std::ptr::null(), 1, &raw mut output),
                HandshakeStatus::NullPointer
            );
            assert_eq!(
                handshake_memory_save(
                    std::ptr::null(),
                    super::super::MAX_FILE_SAVE_BYTES + 1,
                    &raw mut output
                ),
                HandshakeStatus::InvalidArgument
            );
        }
        assert!(output.data.is_null());
    }
}
