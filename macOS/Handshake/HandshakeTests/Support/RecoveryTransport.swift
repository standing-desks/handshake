import Foundation

@testable import Handshake

/// Faults injected into polling and replay while the same terminal stays alive.
actor RecoveryTransport {
    private var state: CoreSnapshot
    private var eventsToDeliver: [CoreEvent] = []
    private var output: [CoreTerminalChunk] = []
    private var transcript = Data()
    private var outputFailures = 0
    private var outputUnavailable = false
    private var replayFailures = 0
    private var cursorRecovery = false
    private var snapshotFailures = 0
    private(set) var snapshotReads = 0
    private(set) var replayReads = 0
    private(set) var input = Data()
    private(set) var responses = Data()

    init(snapshot: CoreSnapshot) { state = snapshot }
    func setOutputUnavailable(_ value: Bool) { outputUnavailable = value }
    func replay(_ bytes: Data, failingOnce: Bool) {
        transcript = bytes
        replayFailures = failingOnce ? 1 : 0
    }
    func failCursorRecoveryOnce() {
        cursorRecovery = true
        snapshotFailures = 1
    }
    func enqueue(_ chunk: CoreTerminalChunk) { output.append(chunk) }
    func change(_ workflow: CoreWorkflow) {
        state.sequence += 1
        state.workflows.workflows = [workflow]
        eventsToDeliver.append(.init(sequence: state.sequence, event: .workflowChanged(workflow)))
    }
    func open() -> CoreSnapshot { state }
    func close() {}
    func snapshot() throws -> CoreSnapshot {
        snapshotReads += 1
        if snapshotFailures > 0 {
            snapshotFailures -= 1
            throw CoreFailure.internalError
        }
        if cursorRecovery { state.sequence = 42 }
        return state
    }
    func events(after sequence: UInt64, limit: UInt32) throws -> [CoreEvent] {
        if cursorRecovery && sequence < 42 { throw CoreFailure.cursorExpired }
        return Array(eventsToDeliver.filter { $0.sequence > sequence }.prefix(Int(limit)))
    }
    func nextTerminalChunk() throws -> CoreTerminalChunk? {
        if outputUnavailable { throw CoreFailure.internalError }
        if outputFailures > 0 {
            outputFailures -= 1
            throw CoreFailure.internalError
        }
        return output.isEmpty ? nil : output.removeFirst()
    }
    func terminalTranscript(terminalID: UInt64, offset: UInt64, limit: UInt32) throws -> CoreTranscriptPage? {
        replayReads += 1
        if replayFailures > 0 {
            replayFailures -= 1
            throw CoreFailure.internalError
        }
        let start = min(Int(offset), transcript.count)
        let end = min(start + Int(limit), transcript.count)
        return .init(
            offset: offset, nextOffset: UInt64(end), endOffset: UInt64(transcript.count), sizes: [],
            bytes: transcript.subdata(in: start..<end), replayAvailable: false)
    }
    func writeTerminalInput(terminalID: UInt64, bytes: Data) { input.append(bytes) }
    func writeTerminalResponse(terminalID: UInt64, bytes: Data) { responses.append(bytes) }
    func resizeTerminal(terminalID: UInt64, size: CoreTerminalSize) {}
    func send(_ command: CoreCommand) -> CoreCommandReceipt { .init(requestID: 1, status: .accepted, error: nil) }
    func pollFiles(_ request: FileBrowserRequest) -> FileBrowserSnapshot? { nil }
    func saveFile(_ request: FileSaveRequest) throws -> FileSaveResult { throw CoreFailure.unexpectedCommandResult }
}

extension RecoveryTransport: CoreTransport {}
