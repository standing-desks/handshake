import Foundation

@testable import Handshake

actor DeferredMemoryTransport {
    private var twineResult: Result<HandshakeMemorySnapshot, CoreFailure>?
    private var twineActions: [HandshakeMemoryAction] = []
    private var pendingHandshake: [CheckedContinuation<HandshakeMemorySnapshot, any Error>] = []
    private var defersHandshake = false

    func setHandshakeResult(_ result: Result<HandshakeMemorySnapshot, CoreFailure>) { twineResult = result }
    func deferHandshakeRequests() { defersHandshake = true }
    func handshakeMemories(folder: String, action: HandshakeMemoryAction) async throws -> HandshakeMemorySnapshot {
        twineActions.append(action)
        if defersHandshake { return try await withCheckedThrowingContinuation { pendingHandshake.append($0) } }
        guard let twineResult else { throw CoreFailure.unexpectedCommandResult }
        return try twineResult.get()
    }
    func completeHandshake(_ index: Int, result: Result<HandshakeMemorySnapshot, any Error>) {
        pendingHandshake[index].resume(with: result)
    }
    func receivedHandshakeActions() -> [HandshakeMemoryAction] { twineActions }
    func waitForHandshakeActions(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while twineActions.count < count {
            guard ContinuousClock.now < deadline else {
                throw CoreFailure.failed("No Handshake memory request arrived.")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private var catalogs: [CheckedContinuation<CoreMemoryCatalog, any Error>] = []
    private var saveResult: FileSaveResult?
    private var reads: [CheckedContinuation<CoreMemoryRead, any Error>] = []
    private var sharedResult: SharedMemorySnapshot?
    private var failsSharedRead = false
    private var nativeImportResult: Result<NativeMemoryImportSnapshot, CoreFailure>?
    private var nativeImportRequests: [NativeMemoryImportRequest] = []
    private var defersNativeImports = false
    private var nativeImports: [CheckedContinuation<NativeMemoryImportSnapshot, any Error>] = []

    func setNativeImportResult(_ result: Result<NativeMemoryImportSnapshot, CoreFailure>) {
        nativeImportResult = result
    }

    func deferNativeImports() { defersNativeImports = true }

    func nativeMemoryImport(_ request: NativeMemoryImportRequest) async throws -> NativeMemoryImportSnapshot {
        nativeImportRequests.append(request)
        if defersNativeImports {
            return try await withCheckedThrowingContinuation { nativeImports.append($0) }
        }
        guard let nativeImportResult else { throw CoreFailure.unexpectedCommandResult }
        return try nativeImportResult.get()
    }

    func receivedNativeImportRequests() -> [NativeMemoryImportRequest] { nativeImportRequests }

    func completeNativeImport(_ index: Int, result: Result<NativeMemoryImportSnapshot, any Error>) {
        nativeImports[index].resume(with: result)
    }

    func waitForNativeImports(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while nativeImports.count < count {
            guard ContinuousClock.now < deadline else { throw CoreFailure.failed("No native memory request arrived.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func setSharedResult(_ result: SharedMemorySnapshot, failRead: Bool) {
        sharedResult = result
        failsSharedRead = failRead
    }
    func sharedMemory(folder: String, action: SharedMemoryAction) throws -> SharedMemorySnapshot {
        if action.operation == "read", failsSharedRead { throw CoreFailure.failed("Detail read unavailable.") }
        guard let sharedResult else { throw CoreFailure.unexpectedCommandResult }
        return sharedResult
    }

    func memoryCatalog(_ request: CoreMemoryRequest) async throws -> CoreMemoryCatalog {
        try await withCheckedThrowingContinuation { catalogs.append($0) }
    }
    func memoryRead(_ request: CoreMemoryRequest) async throws -> CoreMemoryRead {
        try await withCheckedThrowingContinuation { reads.append($0) }
    }
    func setSaveResult(_ result: FileSaveResult) { saveResult = result }
    func memorySave(_ request: CoreMemorySaveRequest) async throws -> FileSaveResult {
        guard let saveResult else { throw CoreFailure.unexpectedCommandResult }
        return saveResult
    }
    func completeCatalog(_ index: Int, result: Result<CoreMemoryCatalog, any Error>) {
        catalogs[index].resume(with: result)
    }
    func completeRead(_ index: Int, result: Result<CoreMemoryRead, any Error>) {
        reads[index].resume(with: result)
    }
    func waitForCatalogs(_ count: Int) async throws {
        // Parallel native-framework startup can delay the model's queued MainActor task in CI.
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while catalogs.count < count {
            guard ContinuousClock.now < deadline else { throw CoreFailure.failed("No memory catalog request arrived.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func waitForReads(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while reads.count < count {
            guard ContinuousClock.now < deadline else { throw CoreFailure.failed("No memory read request arrived.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func open() throws -> CoreSnapshot { throw CoreFailure.unexpectedCommandResult }
    func close() {}
    func send(_ command: CoreCommand) throws -> CoreCommandReceipt { throw CoreFailure.unexpectedCommandResult }
    func snapshot() throws -> CoreSnapshot { throw CoreFailure.unexpectedCommandResult }
    func pollFiles(_ request: FileBrowserRequest) throws -> FileBrowserSnapshot? {
        throw CoreFailure.unexpectedCommandResult
    }
    func saveFile(_ request: FileSaveRequest) throws -> FileSaveResult { throw CoreFailure.unexpectedCommandResult }
    func events(after sequence: UInt64, limit: UInt32) -> [CoreEvent] { [] }
    func nextTerminalChunk() -> CoreTerminalChunk? { nil }
    func writeTerminalInput(terminalID: UInt64, bytes: Data) throws { throw CoreFailure.unexpectedCommandResult }
    func resizeTerminal(terminalID: UInt64, size: CoreTerminalSize) throws { throw CoreFailure.unexpectedCommandResult }
}

// Declaring this conformance on the actor fails to compile in batch mode in Xcode 27.0.
extension DeferredMemoryTransport: CoreTransport {}
