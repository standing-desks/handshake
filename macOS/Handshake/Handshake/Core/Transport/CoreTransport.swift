import Foundation

enum CoreRunState: Equatable {
    case idle
    case starting
    case running
    case failed(String)
}

nonisolated enum CoreFailure: Error, Equatable, LocalizedError, Sendable {
    case commandRejected(code: String, message: String)
    case failed(String)
    case cursorExpired
    case empty
    case internalError
    case invalidArgument
    case invalidUTF8
    case malformedCommand
    case nullPointer
    case notRunning
    case terminalNotRunning
    case panic
    case requestIDOverflow
    case unexpectedCommandResult
    case unknownStatus(UInt32)

    var errorDescription: String? {
        switch self {
        case .commandRejected(let code, let message):
            "handshake-core rejected the command (\(code)): \(message)"
        case .failed(let message):
            "handshake-core failed: \(message)"
        case .cursorExpired:
            "The handshake-core event cursor expired."
        case .empty:
            "handshake-core has no value available."
        case .internalError:
            "handshake-core reported an internal error."
        case .invalidArgument:
            "handshake-core received an invalid argument."
        case .invalidUTF8:
            "handshake-core received invalid UTF-8."
        case .malformedCommand:
            "The handshake-core command was malformed."
        case .nullPointer:
            "handshake-core received a null pointer."
        case .notRunning:
            "handshake-core isn't running."
        case .terminalNotRunning:
            "The terminal process has ended."
        case .panic:
            "handshake-core panicked."
        case .requestIDOverflow:
            "The handshake-core request ID counter overflowed."
        case .unexpectedCommandResult:
            "handshake-core returned an unexpected command result."
        case .unknownStatus(let status):
            "handshake-core returned unknown status \(status)."
        }
    }
}

nonisolated protocol CoreTransport: Sendable {
    func browserControl(_ request: Data) async throws -> Data
    func open() async throws -> CoreSnapshot
    func close() async
    func send(_ command: CoreCommand) async throws -> CoreCommandReceipt
    func snapshot() async throws -> CoreSnapshot
    func pollFiles(_ request: FileBrowserRequest) async throws -> FileBrowserSnapshot?
    func saveFile(_ request: FileSaveRequest) async throws -> FileSaveResult
    func experimental() async throws -> ExperimentalSnapshot
    func setExperimentalFeature(_ id: ExperimentalFeatureID, enabled: Bool, expectedVersion: FileVersion) async throws
        -> FileSaveResult
    func configFile() async throws -> FilePreview
    func keepAwake(_ enabled: Bool?) async throws -> Bool
    func memoryCatalog(_ request: CoreMemoryRequest) async throws -> CoreMemoryCatalog
    func memoryRead(_ request: CoreMemoryRequest) async throws -> CoreMemoryRead
    func memorySave(_ request: CoreMemorySaveRequest) async throws -> FileSaveResult
    func handshakeMemories(folder: String, action: HandshakeMemoryAction) async throws -> HandshakeMemorySnapshot
    func nativeMemoryImport(_ request: NativeMemoryImportRequest) async throws -> NativeMemoryImportSnapshot
    func sharedMemory(folder: String, action: SharedMemoryAction) async throws -> SharedMemorySnapshot
    func saveConfigFile(_ request: FileSaveRequest) async throws -> FileSaveResult
    func harnessModels(_ request: HarnessModelsRequest) async throws -> CoreHarnessModelsResult
    func events(after sequence: UInt64, limit: UInt32) async throws -> [CoreEvent]
    func workflowTrace(workflowID: UInt64, before: UInt64?, limit: UInt32) async throws -> CoreWorkflowTracePage
    func traceEvents(spanID: UInt64, after: UInt64?, limit: UInt32) async throws -> CoreTraceEventsPage
    func traceActivities(spanID: UInt64, after: UInt64?, limit: UInt32) async throws -> CoreTraceActivitiesPage
    func traceDetail(activityID: UInt64, output: Bool, offset: UInt64, limit: UInt32) async throws
        -> CoreTraceDetailPage
    func nextTerminalChunk() async throws -> CoreTerminalChunk?
    func traceStorage(spanID: UInt64?, operation: UInt32) async throws -> CoreTraceStorageStatus
    func terminalTranscript(terminalID: UInt64, offset: UInt64, limit: UInt32) async throws -> CoreTranscriptPage?
    func writeTerminalInput(terminalID: UInt64, bytes: Data) async throws
    func writeTerminalResponse(terminalID: UInt64, bytes: Data) async throws
    func resizeTerminal(terminalID: UInt64, size: CoreTerminalSize) async throws
}

extension CoreTransport {
    func browserControl(_ request: Data) async throws -> Data { throw CoreFailure.unexpectedCommandResult }
    func keepAwake(_ enabled: Bool?) async throws -> Bool { throw CoreFailure.unexpectedCommandResult }

    func handshakeMemories(folder: String, action: HandshakeMemoryAction) async throws -> HandshakeMemorySnapshot {
        throw CoreFailure.unexpectedCommandResult
    }

    func nativeMemoryImport(_ request: NativeMemoryImportRequest) async throws -> NativeMemoryImportSnapshot {
        throw CoreFailure.unexpectedCommandResult
    }

    func sharedMemory(folder: String, action: SharedMemoryAction) async throws -> SharedMemorySnapshot {
        throw CoreFailure.unexpectedCommandResult
    }

    func memoryCatalog(_ request: CoreMemoryRequest) async throws -> CoreMemoryCatalog {
        throw CoreFailure.unexpectedCommandResult
    }

    func memoryRead(_ request: CoreMemoryRequest) async throws -> CoreMemoryRead {
        throw CoreFailure.unexpectedCommandResult
    }

    func memorySave(_ request: CoreMemorySaveRequest) async throws -> FileSaveResult {
        throw CoreFailure.unexpectedCommandResult
    }

    func experimental() async throws -> ExperimentalSnapshot { throw CoreFailure.unexpectedCommandResult }
    func setExperimentalFeature(
        _ id: ExperimentalFeatureID, enabled: Bool, expectedVersion: FileVersion
    ) async throws -> FileSaveResult {
        throw CoreFailure.unexpectedCommandResult
    }

    func configFile() async throws -> FilePreview { throw CoreFailure.unexpectedCommandResult }

    func saveConfigFile(_ request: FileSaveRequest) async throws -> FileSaveResult {
        throw CoreFailure.unexpectedCommandResult
    }

    func writeTerminalResponse(terminalID: UInt64, bytes: Data) async throws {
        try await writeTerminalInput(terminalID: terminalID, bytes: bytes)
    }

    /// Test transports without harnesses report that none are installed.
    func harnessModels(_ request: HarnessModelsRequest) async throws -> CoreHarnessModelsResult {
        .failed("\(request.harness.displayName) isn't available.")
    }

    func terminalTranscript(terminalID: UInt64, offset: UInt64, limit: UInt32) async throws -> CoreTranscriptPage? {
        throw CoreFailure.unexpectedCommandResult
    }
}
