//! Path/buffer adaptation only; copying, validation and publication belong to core.
use std::path::Path;

use crate::error::BridgeError;
use crate::ffi::{self, HandshakeBuffer, HandshakeStatus, catch_status};

#[unsafe(no_mangle)]
/// Prepares a production data directory without opening a client. A successful ABI call returns
/// JSON `{error: null}` or `{error: "actionable migration failure"}` in a caller-owned buffer.
///
/// # Safety
/// The output must be aligned writable storage for an empty buffer. Each nonempty input must
/// identify its stated number of readable bytes. Lengths above `PATH_MAX` are rejected before reads;
/// null pointers for nonempty inputs are rejected. Release output with `handshake_buffer_release`.
pub unsafe extern "C" fn handshake_migrate_data(
    legacy: *const u8,
    legacy_length: usize,
    destination: *const u8,
    destination_length: usize,
    output: *mut HandshakeBuffer,
) -> HandshakeStatus {
    catch_status(|| {
        // SAFETY: The caller guarantees writable output storage; null is rejected by the helper.
        unsafe { ffi::write_buffer(output, HandshakeBuffer::empty()) }?;
        // SAFETY: Length/pointer bounds are checked before borrowing inputs for this callback.
        let response = unsafe {
            ffi::with_input_bytes(legacy, legacy_length, crate::MAX_PATH_BYTES, |legacy| {
                ffi::with_input_bytes(
                    destination,
                    destination_length,
                    crate::MAX_PATH_BYTES,
                    |destination| {
                        let legacy =
                            std::str::from_utf8(legacy).map_err(|_| BridgeError::InvalidUtf8)?;
                        let destination = std::str::from_utf8(destination)
                            .map_err(|_| BridgeError::InvalidUtf8)?;
                        let error = handshake_core::migrate_data_directory(
                            Path::new(legacy),
                            Path::new(destination),
                        )
                        .err()
                        .map(|error| error.to_string());
                        Ok(serde_json::to_vec(&serde_json::json!({"error": error}))?)
                    },
                )
            })
        }?;
        // SAFETY: Output is valid and empty after initialization above.
        unsafe { ffi::write_buffer(output, HandshakeBuffer::from_vec(response)) }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{HandshakeClient, handshake_buffer_release, handshake_client_destroy};
    use handshake_core::{Application, Command, RequestId, config::Config};

    fn migrate(legacy: &Path, destination: &Path) -> serde_json::Value {
        let legacy = legacy.to_str().unwrap().as_bytes();
        let destination = destination.to_str().unwrap().as_bytes();
        let mut output = HandshakeBuffer::empty();
        // SAFETY: Live path bytes and initialized output; output is consumed once below.
        assert_eq!(
            unsafe {
                handshake_migrate_data(
                    legacy.as_ptr(),
                    legacy.len(),
                    destination.as_ptr(),
                    destination.len(),
                    &raw mut output,
                )
            },
            HandshakeStatus::Ok
        );
        // SAFETY: Successful output owns exactly length readable bytes until release.
        let result = serde_json::from_slice(unsafe {
            std::slice::from_raw_parts(output.data, output.length)
        })
        .unwrap();
        // SAFETY: The live output allocation is released exactly once.
        assert_eq!(
            unsafe { handshake_buffer_release(&raw mut output) },
            HandshakeStatus::Ok
        );
        result
    }

    #[test]
    fn migrates_disposable_data_and_reports_a_live_writer_without_creating_destination() {
        let _guard = crate::test_support::TEST_LOCK.lock().unwrap();
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("Twine");
        let destination = root.path().join("Handshake");
        let folder = tempfile::tempdir().unwrap();
        let app = Application::with_config(&source, Config::default()).unwrap();
        app.handle_command(
            RequestId(1),
            Command::OpenFolder {
                path: folder.path().into(),
            },
        )
        .unwrap();
        assert!(
            migrate(&source, &destination)["error"]
                .as_str()
                .unwrap()
                .contains("in use")
        );
        assert!(!destination.exists());
        drop(app);
        assert!(migrate(&source, &destination)["error"].is_null());
        let client = HandshakeClient::new(&destination).unwrap();
        let snapshot: serde_json::Value =
            serde_json::from_slice(&client.snapshot().unwrap()).unwrap();
        assert_eq!(
            snapshot["folders"]["openFolder"],
            folder.path().to_str().unwrap()
        );
        // SAFETY: The client pointer comes from Box::into_raw and is destroyed once.
        assert_eq!(
            unsafe { handshake_client_destroy(Box::into_raw(Box::new(client))) },
            HandshakeStatus::Ok
        );
    }

    #[test]
    fn rejects_bad_pointers_lengths_and_utf8_with_empty_output() {
        let _guard = crate::test_support::TEST_LOCK.lock().unwrap();
        let mut output = HandshakeBuffer::empty();
        for (bytes, length, expected) in [
            (std::ptr::null(), 1, HandshakeStatus::NullPointer),
            (
                std::ptr::null(),
                crate::MAX_PATH_BYTES + 1,
                HandshakeStatus::InvalidArgument,
            ),
            (b"\xff".as_ptr(), 1, HandshakeStatus::InvalidUtf8),
        ] {
            // SAFETY: Invalid inputs are rejected before any invalid access; output is writable.
            assert_eq!(
                unsafe {
                    handshake_migrate_data(bytes, length, b"/tmp/x".as_ptr(), 6, &raw mut output)
                },
                expected
            );
            assert!(output.data.is_null());
            assert_eq!(output.length, 0);
        }
        // SAFETY: Null output is rejected before either input is read.
        assert_eq!(
            unsafe {
                handshake_migrate_data(
                    std::ptr::null(),
                    1,
                    std::ptr::null(),
                    1,
                    std::ptr::null_mut(),
                )
            },
            HandshakeStatus::NullPointer
        );
    }
}
