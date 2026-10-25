use super::error::BridgeError;
use super::ffi::{self, TwineBuffer, TwineStatus, catch_status};

#[unsafe(no_mangle)]
/// Inspects native memory or invokes the harness-owned importer on explicit request.
///
/// # Safety
/// Uses the bounded input and owned output contracts in `twine_bridge.h`.
pub unsafe extern "C" fn twine_native_memory_import(
    bytes: *const u8,
    length: usize,
    output: *mut TwineBuffer,
) -> TwineStatus {
    catch_status(|| {
        // SAFETY: Shared helpers validate pointers and lengths before dereferencing.
        unsafe { ffi::initialize_buffer(output) }?;
        // SAFETY: Forwarded caller contract, enforced by the shared bounded reader.
        let response = unsafe {
            ffi::with_input_bytes(bytes, length, super::MAX_COMMAND_BYTES, |bytes| {
                let request = serde_json::from_slice::<
                    twine_core::memories::native_import::NativeImportRequest,
                >(bytes)
                .map_err(|_| BridgeError::MalformedCommand)?;
                let value = match twine_core::memories::native_import::execute(&request) {
                    Ok(snapshot) => serde_json::json!({"snapshot": snapshot, "error": null}),
                    Err(error) => serde_json::json!({"snapshot": null, "error": error.to_string()}),
                };
                Ok(serde_json::to_vec(&value)?)
            })
        }?;
        // SAFETY: Output was validated before allocating the response buffer.
        unsafe { ffi::write_buffer(output, TwineBuffer::from_vec(response)) }
    })
}

#[unsafe(no_mangle)]
/// Reads Twine AMIS memory state or changes project sharing policy.
///
/// # Safety
/// Uses the bounded input and owned output contracts in `twine_bridge.h`.
pub unsafe extern "C" fn twine_twine_memories(
    bytes: *const u8,
    length: usize,
    output: *mut TwineBuffer,
) -> TwineStatus {
    catch_status(|| {
        // SAFETY: Shared helpers validate pointers and lengths before dereferencing.
        unsafe { ffi::initialize_buffer(output) }?;
        // SAFETY: Forwarded caller contract, enforced by the shared bounded reader.
        let response = unsafe {
            ffi::with_input_bytes(bytes, length, super::MAX_COMMAND_BYTES, |bytes| {
                let request = serde_json::from_slice::<twine_core::memories::twine::Request>(bytes)
                    .map_err(|_| BridgeError::MalformedCommand)?;
                let value = match twine_core::memories::twine::execute(&request) {
                    Ok(snapshot) => serde_json::json!({"snapshot": snapshot, "error": null}),
                    Err(error) => serde_json::json!({"snapshot": null, "error": error.to_string()}),
                };
                Ok(serde_json::to_vec(&value)?)
            })
        }?;
        // SAFETY: Output was validated before allocating the response buffer.
        unsafe { ffi::write_buffer(output, TwineBuffer::from_vec(response)) }
    })
}
