#ifndef HANDSHAKE_BRIDGE_H
#define HANDSHAKE_BRIDGE_H

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct HandshakeClient HandshakeClient;

typedef enum HandshakeStatus {
    HANDSHAKE_STATUS_OK = 0,
    HANDSHAKE_STATUS_EMPTY = 1,
    HANDSHAKE_STATUS_NULL_POINTER = 2,
    HANDSHAKE_STATUS_INVALID_UTF8 = 3,
    HANDSHAKE_STATUS_MALFORMED_COMMAND = 4,
    HANDSHAKE_STATUS_INVALID_ARGUMENT = 5,
    HANDSHAKE_STATUS_CURSOR_EXPIRED = 6,
    HANDSHAKE_STATUS_INTERNAL_ERROR = 7,
    HANDSHAKE_STATUS_PANIC = 8,
    HANDSHAKE_STATUS_TERMINAL_NOT_RUNNING = 9,
} HandshakeStatus;

typedef struct HandshakeBuffer {
    // Rust-allocated bytes. After a successful bridge call, the caller owns this allocation and
    // must pass the unchanged pointer/length pair to handshake_buffer_release exactly once.
    uint8_t *data;
    size_t length;
} HandshakeBuffer;

typedef struct HandshakeTerminalChunk {
    uint64_t terminal_id;
    uint64_t offset;
    HandshakeBuffer bytes;
} HandshakeTerminalChunk;

// Explicit production migration. Input paths use the same pointer/length bounds as client_create.
// Does not open a client. Output JSON is {error:null} or {error:"actionable failure"}; release it
// with handshake_buffer_release. Keep the startup/error screen visible until success.
HandshakeStatus handshake_migrate_data(
    const uint8_t *legacy, size_t legacy_length,
    const uint8_t *destination, size_t destination_length, HandshakeBuffer *out_result
);

// User settings access requires no client or open folder. Reads return a FilePreview JSON;
// saves accept the file-save request and return saved/conflict/failed JSON. Only the configured
// user config file can be saved. Output ownership follows handshake_buffer_release.
// Save input is bounded to 12 MiB + 16 KiB; pointer/length rules match handshake_client_save_file.
HandshakeStatus handshake_config_file(HandshakeBuffer *out_file);
// App-wide Keep Awake: operation 0 reads, 1 enables, 2 disables. No folder client is needed.
// Returns {enabled:bool,error:null} or {error:string}. Release output with handshake_buffer_release.
// Disable during normal app shutdown; the core also ties the child to this process's lifetime.
HandshakeStatus handshake_keep_awake(uint32_t operation, HandshakeBuffer *out_result);
// Read {type:"read"}, or set {type:"set",id,enabled,expectedVersion}.
// No folder runtime is required; config-file versions and output ownership are preserved.
HandshakeStatus handshake_feature_flags(const uint8_t *bytes, size_t length, HandshakeBuffer *out_result);
// Local memory discovery and reading. Request JSON: {folder?, sourceId?, examplesRoot?}.
// Catalog returns sources and discovery diagnostics; read requires a discovered sourceId.
// No client is needed. Input/ownership rules match send_command and handshake_buffer_release.
HandshakeStatus handshake_memory_catalog(const uint8_t *bytes, size_t length, HandshakeBuffer *out_catalog);
HandshakeStatus handshake_memory_read(const uint8_t *bytes, size_t length, HandshakeBuffer *out_source);
// Explicit Markdown save: {source: <memory request>, text, expectedVersion, overwrite}.
// Returns saved/conflict/failed JSON. Input bound and pointer rules match save_file;
// no client is needed, and output ownership follows handshake_buffer_release.
HandshakeStatus handshake_memory_save(const uint8_t *bytes, size_t length, HandshakeBuffer *out_result);
// Project memory operations: local core policy and owned output follow the contracts above.
HandshakeStatus handshake_shared_memory(const uint8_t *bytes, size_t length, HandshakeBuffer *out_result);
HandshakeStatus handshake_native_memory_import(const uint8_t *bytes, size_t length, HandshakeBuffer *out_result);
HandshakeStatus handshake_project_memories(const uint8_t *bytes, size_t length, HandshakeBuffer *out_result);
HandshakeStatus handshake_config_save_file(const uint8_t *request_bytes, size_t request_length, HandshakeBuffer *out_result);

// A null out parameter is rejected with HANDSHAKE_STATUS_NULL_POINTER. Otherwise it must point to
// aligned, writable storage and must not contain an unreleased bridge allocation. Bridge functions
// initialize valid out parameters to an empty value before work. Every non-null client must be a
// live pointer returned by handshake_client_create; calls for a client are serialized, and the client is
// destroyed exactly once after its calls finish. Functions other than destroy reject a null client.
//
// data_directory is the absolute UTF-8 path of the directory where the core keeps its database.
// A path longer than 1024 bytes is rejected without reading data_directory. For a nonzero length at
// or below that limit, a null data_directory is rejected; otherwise it must identify
// data_directory_length readable bytes for the duration of this call.
HandshakeStatus handshake_client_create(
    const uint8_t *data_directory,
    size_t data_directory_length,
    HandshakeClient **out_client
);
HandshakeStatus handshake_client_destroy(HandshakeClient *client);

// Same pointer/length contract as handshake_client_create. Window clients share durable history,
// but each owns its own folder, event stream, workflows, and processes.
HandshakeStatus handshake_client_create_window(const uint8_t *data_directory, size_t data_directory_length, HandshakeClient **out_client);

// Returns a caller-owned JSON array of folders to restore. Same contracts as get_snapshot.
HandshakeStatus handshake_client_restorable_folders(HandshakeClient *client, HandshakeBuffer *out_result);

// A command larger than 1 MiB is rejected without reading command_bytes. For a nonzero command at
// or below that limit, a null command_bytes is rejected; otherwise it must identify command_length
// readable bytes for the duration of this call.
HandshakeStatus handshake_client_send_command(
    HandshakeClient *client,
    const uint8_t *command_bytes,
    size_t command_length,
    HandshakeBuffer *out_response
);

HandshakeStatus handshake_client_snapshot(HandshakeClient *client, HandshakeBuffer *out_snapshot);

// Poll expanded directories and a selected file. Same input and ownership rules as send_command.
// Returns EMPTY while a scan is pending or the supplied revision is current (no owned buffer).
HandshakeStatus handshake_client_poll_files(
    HandshakeClient *client, const uint8_t *request_bytes, size_t request_length, HandshakeBuffer *out_snapshot
);

// Starts listing a harness's models and effort levels on a core thread; returns at once. Request
// {"harness": "codex" | "claudeCode" | "pi"}, with the same input rules as send_command. Poll until
// it isn't EMPTY: the JSON status is listed (with models) or failed (with message). Destroy exactly
// once; destroying a pending request stops the harness.
typedef struct HandshakeModelsRequest HandshakeModelsRequest;
HandshakeStatus handshake_client_request_harness_models(
    HandshakeClient *client, const uint8_t *request_bytes, size_t request_length, HandshakeModelsRequest **out_request
);
HandshakeStatus handshake_models_request_poll(HandshakeModelsRequest *request, HandshakeBuffer *out_models);
HandshakeStatus handshake_models_request_destroy(HandshakeModelsRequest *request);

// Saves UTF-8 text through core with version checking. JSON result status is saved, conflict,
// or failed. Allows escaped text up to the 2 MiB file limit; release JSON with handshake_buffer_release.
// Pointer rules match send_command; input is bounded to 12 MiB + 16 KiB before dereference.
HandshakeStatus handshake_client_save_file(
    HandshakeClient *client, const uint8_t *request_bytes, size_t request_length, HandshakeBuffer *out_result
);

HandshakeStatus handshake_client_events_after(
    HandshakeClient *client,
    uint64_t sequence,
    uint32_t limit,
    HandshakeBuffer *out_events
);

// Trace pages contain JSON metadata, never terminal bytes. Limits are 1..200.
// A zero cursor starts at the newest spans or the first events, respectively.
HandshakeStatus handshake_client_workflow_trace(
    HandshakeClient *client, uint64_t workflow_id, uint64_t before_span_id,
    uint32_t limit, HandshakeBuffer *out_page
);
HandshakeStatus handshake_client_trace_events(
    HandshakeClient *client, uint64_t span_id, uint64_t after_event_id,
    uint32_t limit, HandshakeBuffer *out_page
);
HandshakeStatus handshake_client_trace_activities(
    HandshakeClient *client, uint64_t span_id, uint64_t after_activity_id,
    uint32_t limit, HandshakeBuffer *out_page
);

// Full details are UTF-8 pages of 4..65536 bytes. Offsets are UTF-8 boundaries;
// nextOffset is null at the end. Expired detail files return an explicit error.
HandshakeStatus handshake_client_trace_detail(
    HandshakeClient *client, uint64_t activity_id, bool output, uint64_t offset,
    uint32_t limit, HandshakeBuffer *out_page
);
// Operations: 0 status, 1 pin, 2 unpin, 3 request background cleanup.
// Status includes clearGeneration and completedClearGeneration as cleanup receipts.
HandshakeStatus handshake_client_trace_storage(
    HandshakeClient *client, uint64_t span_id, uint32_t operation, HandshakeBuffer *out_page
);

HandshakeStatus handshake_client_next_terminal_chunk(
    HandshakeClient *client,
    HandshakeTerminalChunk *out_chunk
);

// Nonblocking transcript requests. Empty from start means the bounded queue is full; Empty from
// poll means the read is pending. Continue servicing live I/O between attempts. Destroy each request
// once, even when canceled. Poll returns a binary buffer released with handshake_buffer_release.
// Little-endian u64 flags: 1 = expired (no other fields), 2 = complete replay prefix available.
// Otherwise u64 offset, next_offset, end_offset, resize_count; then resize_count records of
// u64 byte_offset and u16 rows, columns, pixel_width, pixel_height; then the raw output bytes.
typedef struct HandshakeTranscriptRequest HandshakeTranscriptRequest;
HandshakeStatus handshake_client_request_transcript(
    HandshakeClient *client, uint64_t terminal_id, uint64_t offset, uint32_t limit, HandshakeTranscriptRequest **out_request
);
HandshakeStatus handshake_transcript_request_poll(HandshakeTranscriptRequest *request, HandshakeBuffer *out_page);
HandshakeStatus handshake_transcript_request_destroy(HandshakeTranscriptRequest *request);

// Sends raw user input to a live terminal. Inputs larger than 64 KiB are rejected without reading
// input_bytes. A null input pointer is valid only when input_length is zero.
// Writes and resizes return HANDSHAKE_STATUS_TERMINAL_NOT_RUNNING after the process stops;
// its remaining output and transcript stay readable until the terminal is closed.
HandshakeStatus handshake_client_write_terminal_input(
    HandshakeClient *client,
    uint64_t terminal_id,
    const uint8_t *input_bytes,
    size_t input_length
);

// Sends terminal-generated protocol replies. Pointer and size contracts match user input.
HandshakeStatus handshake_client_write_terminal_response(
    HandshakeClient *client,
    uint64_t terminal_id,
    const uint8_t *input_bytes,
    size_t input_length
);

HandshakeStatus handshake_client_resize_terminal(
    HandshakeClient *client,
    uint64_t terminal_id,
    uint16_t rows,
    uint16_t columns,
    uint16_t pixel_width,
    uint16_t pixel_height
);

// Releases a caller-owned bridge buffer and clears its fields. An already-empty buffer is accepted.
// A null HandshakeBuffer pointer is rejected. Otherwise it must identify aligned, writable storage; a
// nonempty pointer/length pair must be unchanged from the successful bridge call that returned it
// and must be released exactly once.
HandshakeStatus handshake_buffer_release(HandshakeBuffer *buffer);

#ifdef __cplusplus
}
#endif

#endif
