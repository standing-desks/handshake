import Foundation

@testable import Handshake

actor TranscriptFixtureTransport {
    private let bytes: Data?
    private var extraTranscripts: [UInt64: Data] = [:]
    private let transcripts: [UInt64: Data]
    private let fixtureSnapshot: CoreSnapshot
    private var chunks: [CoreTerminalChunk]
    private(set) var writes: [Data] = []
    private var displayCache: [UInt64: [UInt64: Data]] = [:]
    private(set) var cacheReads: [UInt64] = []
    private let replayAvailable: Bool
    private var delayed: Bool
    private var trace: CoreWorkflowTracePage?
    private var recordedEvents: [CoreTraceEvent]
    private var pending: [CheckedContinuation<Void, Never>] = []
    private(set) var readLimits: [UInt32] = []
    var hasPendingRead: Bool { !pending.isEmpty }

    init(
        bytes: Data?, replayAvailable: Bool = true, delayed: Bool = false,
        trace: CoreWorkflowTracePage? = nil, recordedEvents: [CoreTraceEvent] = [],
        transcripts: [UInt64: Data] = [:], snapshot: CoreSnapshot? = nil, chunks: [CoreTerminalChunk] = []
    ) {
        fixtureSnapshot = snapshot ?? .testReady()
        self.chunks = chunks
        self.bytes = bytes
        self.transcripts = transcripts
        self.replayAvailable = replayAvailable
        self.delayed = delayed
        self.trace = trace
        self.recordedEvents = recordedEvents
    }

    func release() {
        let reads = pending
        pending = []
        for read in reads { read.resume() }
    }

    func setDelayed(_ value: Bool) { delayed = value }

    func replaceEvents(_ events: [CoreTraceEvent]) { recordedEvents = events }
    func replaceTrace(_ trace: CoreWorkflowTracePage) { self.trace = trace }

    func terminalTranscript(terminalID: UInt64, offset: UInt64, limit: UInt32) async -> CoreTranscriptPage? {
        readLimits.append(limit)
        if delayed { await withCheckedContinuation { pending.append($0) } }
        guard let bytes = extraTranscripts[terminalID] ?? transcripts[terminalID] ?? bytes else { return nil }
        let start = min(Int(offset), bytes.count)
        let end = min(start + Int(limit), bytes.count)
        return .init(
            offset: offset, nextOffset: UInt64(end), endOffset: UInt64(bytes.count),
            sizes: offset == 0 && end > 0 ? [.init(offset: 0, rows: 24, columns: 80)] : [],
            bytes: bytes.subdata(in: start..<end), replayAvailable: replayAvailable)
    }

    func terminalDisplayCache(terminalID: UInt64, operation: CoreDisplayCacheOperation) -> Data? {
        switch operation {
        case .read(let key):
            cacheReads.append(key)
            return displayCache[terminalID]?[key]
        case .write(let key, _, let bytes):
            displayCache[terminalID, default: [:]][key] = bytes
            return nil
        }
    }

    func evictDisplayPage(terminalID: UInt64, key: UInt64) { displayCache[terminalID]?[key] = nil }
    func enqueue(_ chunk: CoreTerminalChunk) { chunks.append(chunk) }
    func replaceTranscript(terminalID: UInt64, bytes: Data) { extraTranscripts[terminalID] = bytes }
    func open() -> CoreSnapshot { fixtureSnapshot }
    func close() {}
    func snapshot() -> CoreSnapshot { fixtureSnapshot }
    func pollFiles(_ request: FileBrowserRequest) -> FileBrowserSnapshot? { nil }
    func saveFile(_ request: FileSaveRequest) throws -> FileSaveResult { throw CoreFailure.unexpectedCommandResult }
    func send(_ command: CoreCommand) -> CoreCommandReceipt {
        CoreCommandReceipt(requestID: 1, status: .accepted, error: nil)
    }
    func events(after sequence: UInt64, limit: UInt32) -> [CoreEvent] { [] }
    func nextTerminalChunk() -> CoreTerminalChunk? { chunks.isEmpty ? nil : chunks.removeFirst() }
    func writeTerminalInput(terminalID: UInt64, bytes: Data) { writes.append(bytes) }
    func resizeTerminal(terminalID: UInt64, size: CoreTerminalSize) {}
    func workflowTrace(workflowID: UInt64, before: UInt64?, limit: UInt32) throws -> CoreWorkflowTracePage {
        if let trace { return trace }
        throw CoreFailure.unexpectedCommandResult
    }
    func traceEvents(spanID: UInt64, after: UInt64?, limit: UInt32) throws -> CoreTraceEventsPage {
        guard let trace else { throw CoreFailure.unexpectedCommandResult }
        let remaining = recordedEvents.filter { $0.spanID == spanID && $0.id > (after ?? 0) }
        let events = Array(remaining.prefix(Int(limit)))
        return .init(
            workflowID: trace.summary.workflowID, spanID: spanID, revision: trace.summary.revision,
            events: events, nextAfter: remaining.count > events.count ? events.last?.id : nil)
    }
}

// Declaring this conformance on the actor fails to compile in batch mode in Xcode 27.0.
extension TranscriptFixtureTransport: CoreTransport {}
