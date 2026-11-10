import Foundation
import SwiftTerm

nonisolated struct TerminalIndexPoint: Sendable {
    let id: UInt64
    let anchor: CoreTraceAnchor
    var inputText: String?
    var includesInput = false
}

nonisolated struct TerminalIndexResult: Sendable {
    nonisolated struct Row: Sendable {
        let row: Int
        let text: String
        let input: String?
    }
    let columns: Int
    let screenRows: Int
    let trimmed: Int
    let rows: [UInt64: Row]
}

/// A retained historical index. All ANSI interpretation, text extraction, and row searches run
/// here. Visibility changes never enter the request or invalidate completed work.
actor TerminalIndexWorker {
    private var replay = TerminalReplay()
    private var points: [UInt64: TerminalIndexPoint] = [:]
    private var anchors: [UInt64: TerminalMinimapAnchor] = [:]
    private var inputs: [UInt64: String] = [:]
    private var generation = 0
    private var terminalID: UInt64?
    private var geometry: [CoreTranscriptSize] = []

    func index(
        terminalID: UInt64, end: UInt64, points requested: [TerminalIndexPoint], sizes: [CoreTranscriptSize]? = nil,
        prefix: [TerminalReplayPrefix] = [], columns: Int? = nil, rows: Int? = nil, client: CoreClient
    ) async throws -> TerminalIndexResult {
        generation += 1
        resetIfNeeded(terminalID: terminalID, end: end, requested: requested, sizes: sizes, prefix: prefix)
        self.terminalID = terminalID
        if let sizes { geometry = sizes }
        for point in requested { points[point.id] = point }
        try await advance(
            terminalID: terminalID, end: end, requested: requested, sizes: sizes,
            client: client)
        return result(columns: columns, rows: rows)
    }

    private func result(columns: Int?, rows: Int?) -> TerminalIndexResult {
        let terminal = replay.terminal
        if let columns, let rows { terminal.resize(cols: columns, rows: rows) }
        var result: [UInt64: TerminalIndexResult.Row] = [:]
        if !terminal.isCurrentBufferAlternate {
            for (id, saved) in anchors {
                var anchor = saved
                guard let row = anchor.resolve(terminal: terminal) else { continue }
                anchors[id] = anchor
                result[id] = .init(row: row, text: anchor.line.translateToString(), input: inputs[id])
            }
        }
        return .init(
            columns: terminal.cols, screenRows: terminal.rows, trimmed: terminal.buffer.totalLinesTrimmed, rows: result)
    }

    private func resetIfNeeded(
        terminalID: UInt64, end: UInt64, requested: [TerminalIndexPoint], sizes: [CoreTranscriptSize]?,
        prefix: [TerminalReplayPrefix]
    ) {
        let changed = requested.contains { point in
            guard point.anchor.byteOffset < replay.offset else { return false }
            return points[point.id]?.anchor != point.anchor || points[point.id]?.inputText != point.inputText
                || points[point.id]?.includesInput != point.includesInput
        }
        let geometryChanged = sizes.map { !geometry.starts(with: $0.prefix(geometry.count)) } ?? false
        if self.terminalID != terminalID || end < replay.offset || changed || geometryChanged {
            replay = TerminalReplay()
            anchors = [:]
            inputs = [:]
            points = [:]
            for entry in prefix {
                replay.terminal.resize(cols: entry.columns, rows: entry.rows)
                replay.terminal.feed(text: entry.text)
            }
        }
    }

    private func advance(
        terminalID: UInt64, end: UInt64, requested: [TerminalIndexPoint], sizes: [CoreTranscriptSize]?,
        client: CoreClient
    ) async throws {
        let requestGeneration = generation
        let ordered = requested.sorted { $0.anchor.byteOffset < $1.anchor.byteOffset }
        repeat {
            if let sizes {
                try replay.applyBoundarySizes(
                    sizes.filter { $0.offset == replay.offset }.map {
                        CoreTraceSize(rows: $0.rows, columns: $0.columns)
                    })
            }
            for point in ordered where point.anchor.byteOffset == replay.offset {
                if sizes == nil, let boundary = point.anchor.boundarySizes { try replay.applyBoundarySizes(boundary) }
                capture(point)
            }
            if replay.offset >= end { break }
            let next = ordered.first { $0.anchor.byteOffset > replay.offset }?.anchor.byteOffset ?? end
            let offset = replay.offset
            let result = try await client.terminalTranscript(
                terminalID: terminalID, offset: offset, limit: UInt32(min(64 * 1024, min(next, end) - offset)))
            try Task.checkCancellation()
            guard requestGeneration == generation else { throw CancellationError() }
            guard let page = result, page.replayAvailable, page.nextOffset > offset, page.nextOffset <= end else {
                throw IndexFailure.expired
            }
            try replay.append(
                .init(
                    offset: offset, nextOffset: page.nextOffset, endOffset: page.endOffset,
                    sizes: sizes?.filter { $0.offset > offset && $0.offset < page.nextOffset } ?? page.sizes,
                    bytes: page.bytes, replayAvailable: true))
        } while true
    }

    enum IndexFailure: Error { case expired }

    private func capture(_ point: TerminalIndexPoint) {
        let terminal = replay.terminal
        guard point.anchor.boundarySizes != nil, !terminal.isCurrentBufferAlternate else { return }
        let cursor = terminal.getTopVisibleRow() + terminal.getCursorLocation().y
        let prompt = point.inputText.flatMap {
            TerminalMinimapGeometry.inputRow(before: cursor, matching: $0, in: terminal)
        }
        let row =
            prompt ?? (point.includesInput ? TerminalMinimapGeometry.inputRow(before: cursor, in: terminal) : cursor)
        anchors[point.id] = TerminalMinimapAnchor(terminal: terminal, row: row)
        if prompt != nil || point.includesInput {
            inputs[point.id] = TerminalMinimapGeometry.logicalLine(at: row, in: terminal)
        }
    }
}
