import Foundation

@testable import Handshake

/// Holds each browser poll until the test releases it, including after cancellation.
actor DeferredBrowserTransport {
    private var polls: [CheckedContinuation<Data, Never>] = []
    private(set) var pollCount = 0

    func browserControl(_ request: Data) async throws -> Data {
        let command = try JSONSerialization.jsonObject(with: request) as? [String: Any]
        guard command?["action"] as? String == "poll" else { return Data("{}".utf8) }
        pollCount += 1
        return await withCheckedContinuation { polls.append($0) }
    }

    func releasePoll(_ json: String = "{}") { polls.removeFirst().resume(returning: Data(json.utf8)) }
    func open() -> CoreSnapshot { .testReady() }
    func snapshot() -> CoreSnapshot { .testReady() }
    func close() {}
    func send(_ command: CoreCommand) throws -> CoreCommandReceipt { throw CoreFailure.unexpectedCommandResult }
    func pollFiles(_ request: FileBrowserRequest) throws -> FileBrowserSnapshot? {
        throw CoreFailure.unexpectedCommandResult
    }
    func saveFile(_ request: FileSaveRequest) throws -> FileSaveResult { throw CoreFailure.unexpectedCommandResult }
    func events(after sequence: UInt64, limit: UInt32) -> [CoreEvent] { [] }
    func nextTerminalChunk() -> CoreTerminalChunk? { nil }
    func writeTerminalInput(terminalID: UInt64, bytes: Data) throws { throw CoreFailure.unexpectedCommandResult }
    func resizeTerminal(terminalID: UInt64, size: CoreTerminalSize) throws { throw CoreFailure.unexpectedCommandResult }
}

// Keep the actor conformance separate for Xcode's batch compiler.
extension DeferredBrowserTransport: CoreTransport {}
