import Foundation
import SwiftTerm

nonisolated struct TerminalHistorySnapshot: Sendable {
    nonisolated struct Grid: Sendable {
        let rows: Int
        let cols: Int
    }
    let id: UUID
    let text: String
    let outputStartRange: NSRange?
    let offset: UInt64
    let terminal: Grid
    let lines: [String]
}

actor TerminalTraceHistoryWorker {
    func load(_ target: TraceTerminalTarget, client: CoreClient) async throws -> TerminalHistorySnapshot {
        guard let boundarySizes = target.anchor.boundarySizes else { throw HistoryFailure.expired }
        let replay = TerminalReplay()
        var endOffset: UInt64? = target.readToCurrentEnd ? nil : target.anchor.byteOffset
        try markCommandStart(target, replay: replay)
        // Even an anchor at zero checks retention; an expired prefix cannot be guessed.
        repeat {
            let remaining = endOffset.map { $0 - replay.offset } ?? 64 * 1024
            let page = try await retainedPage(target, replay: replay, remaining: remaining, client: client)
            if endOffset == nil { endOffset = page.endOffset }
            if reachedEnd(page, replay: replay, endOffset: endOffset, remaining: remaining) { break }
            guard page.nextOffset > replay.offset, page.nextOffset <= (endOffset ?? 0) else {
                throw CoreFailure.unexpectedCommandResult
            }
            try replay.append(page)
            try markCommandStart(target, replay: replay)
            await Task.yield()
        } while replay.offset < (endOffset ?? 0)
        try Task.checkCancellation()
        if !target.readToCurrentEnd { try replay.applyBoundarySizes(boundarySizes) }
        return .init(
            id: UUID(), text: replay.text, outputStartRange: replay.outputStartRange,
            offset: replay.offset, terminal: .init(rows: replay.terminal.rows, cols: replay.terminal.cols),
            lines: replay.text.components(separatedBy: "\n"))
    }
    enum HistoryFailure: Error { case expired }
    private func reachedEnd(
        _ page: CoreTranscriptPage, replay: TerminalReplay, endOffset: UInt64?, remaining: UInt64
    ) -> Bool {
        remaining == 0 || (page.nextOffset == replay.offset && replay.offset == endOffset)
    }

    private func retainedPage(
        _ target: TraceTerminalTarget, replay: TerminalReplay, remaining: UInt64, client: CoreClient
    ) async throws -> CoreTranscriptPage {
        var readBytes = min(remaining, 64 * 1024)
        if let start = target.outputStartAnchor, start.byteOffset > replay.offset {
            readBytes = min(readBytes, start.byteOffset - replay.offset)
        }
        let page = try await client.terminalTranscript(
            terminalID: target.anchor.terminalID, offset: replay.offset, limit: UInt32(max(1, readBytes)))
        try Task.checkCancellation()
        guard let page, page.replayAvailable || (target.anchor.byteOffset == 0 && page.endOffset == 0) else {
            throw HistoryFailure.expired
        }
        return page
    }

    private func markCommandStart(_ target: TraceTerminalTarget, replay: TerminalReplay) throws {
        guard let start = target.outputStartAnchor, replay.offset == start.byteOffset else { return }
        guard let sizes = start.boundarySizes else { throw HistoryFailure.expired }
        try replay.applyBoundarySizes(sizes)
        replay.markOutputStart(includingInput: target.includesInput, inputText: target.inputText)
    }

}
