import Foundation
import SwiftTerm

nonisolated struct TerminalDisplayIndex: Codable, Sendable {
    static let format = 4
    var version = Self.format
    let terminalID: UInt64
    let sourceOffset: UInt64
    let columns: Int
    let screenRows: Int
    let cursorColumn: Int
    let cursorRow: Int
    let clearsHistory: Bool
    let count: Int
    let pages: [UInt64]
    let pageCounts: [Int]
}

/// Owns every mutable historical emulator. Only values leave this actor; AppKit never enters it.
actor TerminalHistoryWorker {
    private var replay = TerminalReplay()
    private var terminalID: UInt64?
    private var previousBuffer: Buffer?
    private let retainsPages: Bool

    init(retainsPages: Bool = true) { self.retainsPages = retainsPages }

    private var signatures: [[UInt64]] = []
    private var pageKeys: [UInt64] = []
    private var memoryPages: [UInt64: [TerminalDisplayRow]] = [:]
    private let pageSize = 128

    func prepare(
        terminalID: UInt64, columns: Int, rows: Int? = nil, client: CoreClient
    ) async throws -> TerminalDisplayIndex {
        let first = try await client.terminalTranscript(terminalID: terminalID, offset: 0, limit: 64 * 1024)
        guard let first, first.replayAvailable || first.endOffset == 0 else { throw HistoryError.expired }
        if let index = await cachedIndex(id: terminalID, end: first.endOffset, client: client) {
            if index.columns == columns, rows == nil || index.screenRows == rows { return index }
            // Reflow belongs to the private emulator, including wrapped graphemes spanning pages.
            var restored: [TerminalDisplayRow] = []
            for page in index.pages.indices {
                restored += try await pageRows(index: index, page: page, terminalID: terminalID, client: client)
            }
            replay = TerminalReplay()
            replay.terminal.resize(cols: index.columns, rows: index.screenRows)
            replay.terminal.replaceDisplayHistory(
                restored, cursorColumn: index.cursorColumn, cursorRow: index.cursorRow)
            replay.terminal.resize(cols: columns, rows: rows ?? replay.terminal.rows)
            return try await save(
                terminalID, offset: first.endOffset, client: client, clearsHistory: index.clearsHistory)
        }
        self.terminalID = terminalID
        try replay.append(first)
        try await advance(to: first.endOffset, terminalID: terminalID, client: client)
        replay.terminal.resize(cols: columns, rows: rows ?? replay.terminal.rows)
        return try await save(terminalID, offset: first.endOffset, client: client)
    }

    private func cachedIndex(id: UInt64, end: UInt64, client: CoreClient) async -> TerminalDisplayIndex? {
        guard let bytes = try? await client.terminalDisplayCache(terminalID: id, operation: .read(key: 0)),
            let index = try? Self.decode(TerminalDisplayIndex.self, bytes),
            index.version == TerminalDisplayIndex.format, index.terminalID == id, index.sourceOffset == end,
            index.columns > 0, index.columns <= 4096, index.screenRows > 0, index.screenRows <= 4096,
            index.pages.count <= 1024, index.pages.count == index.pageCounts.count,
            !index.pages.isEmpty, index.count <= 104_096,
            index.pageCounts.allSatisfy({ $0 > 0 && $0 <= pageSize + index.screenRows }),
            index.count == index.pageCounts.reduce(0, +)
        else { return nil }
        return index
    }

    /// The live controller coalesces offsets while this actor works. It never queues unbounded bytes.
    func update(
        terminalID: UInt64, through offset: UInt64, sizes: [CoreTranscriptSize], client: CoreClient
    ) async throws {
        if self.terminalID == nil { self.terminalID = terminalID }
        guard self.terminalID == terminalID, offset >= replay.offset else { return }
        try await advance(to: offset, terminalID: terminalID, sizes: sizes, client: client)
        _ = try await save(terminalID, offset: offset, client: client)
    }

    private func advance(
        to end: UInt64, terminalID: UInt64, sizes: [CoreTranscriptSize]? = nil, client: CoreClient
    ) async throws {
        while replay.offset < end {
            let offset = replay.offset
            let result = try await client.terminalTranscript(
                terminalID: terminalID, offset: offset, limit: UInt32(min(64 * 1024, end - offset)))
            try Task.checkCancellation()
            guard let page = result, page.replayAvailable, page.nextOffset > offset, page.nextOffset <= end else {
                throw HistoryError.expired
            }
            let geometry = sizes?.filter { $0.offset >= offset && $0.offset < page.nextOffset } ?? page.sizes
            try replay.append(
                .init(
                    offset: offset, nextOffset: page.nextOffset, endOffset: page.endOffset, sizes: geometry,
                    bytes: page.bytes, replayAvailable: true))
        }
    }

    func pageRows(
        index: TerminalDisplayIndex, page: Int, terminalID: UInt64, client: CoreClient
    ) async throws -> [TerminalDisplayRow] {
        let key = index.pages[page]
        if let rows = memoryPages[key] { return rows }
        if let rows = try await cachedRows(index: index, page: page, id: terminalID, client: client) { return rows }
        // Eviction or corruption is a cache miss. Reconstruct privately from canonical bytes,
        // preserving the snapshot's coverage; never append ANSI to the visible terminal.
        replay = TerminalReplay()
        try await advance(to: index.sourceOffset, terminalID: terminalID, client: client)
        replay.terminal.resize(cols: index.columns, rows: index.screenRows)
        guard replay.terminal.displayHistoryCount == index.count else { throw HistoryError.expired }
        for position in index.pages.indices {
            let start = index.pageCounts.prefix(position).reduce(0, +)
            memoryPages[index.pages[position]] = replay.terminal.displayHistoryRows(
                in: start..<(start + index.pageCounts[position]))
        }
        return memoryPages[key] ?? []
    }

    private func cachedRows(
        index: TerminalDisplayIndex, page: Int, id: UInt64, client: CoreClient
    ) async throws -> [TerminalDisplayRow]? {
        guard
            let bytes = try await client.terminalDisplayCache(terminalID: id, operation: .read(key: index.pages[page])),
            let rows = try? Self.decode([TerminalDisplayRow].self, bytes),
            rows.count == index.pageCounts[page], valid(rows)
        else { return nil }
        return rows
    }

    private func valid(_ rows: [TerminalDisplayRow]) -> Bool { rows.allSatisfy { $0.cells.count <= 4096 } }

    private func resetPagesIfNeeded(_ terminal: Terminal) {
        if previousBuffer !== terminal.displayHistoryBuffer {
            signatures = []
            pageKeys = []
            previousBuffer = terminal.displayHistoryBuffer
        }
    }

    private func save(
        _ terminalID: UInt64, offset sourceOffset: UInt64, client: CoreClient, clearsHistory: Bool? = nil
    ) async throws -> TerminalDisplayIndex {
        let terminal = replay.terminal
        let count = terminal.displayHistoryCount
        resetPagesIfNeeded(terminal)
        var keys: [UInt64] = []
        var counts: [Int] = []
        var nextSignatures: [[UInt64]] = []
        var nextMemory: [UInt64: [TerminalDisplayRow]] = [:]
        let tailStart = max(0, (count - max(pageSize, terminal.rows)) / pageSize * pageSize)
        var ranges = stride(from: 0, to: tailStart, by: pageSize).map { $0..<min(tailStart, $0 + pageSize) }
        ranges.append(tailStart..<count)
        for (position, range) in ranges.enumerated() {
            try Task.checkCancellation()
            let signature = range.flatMap { row -> [UInt64] in
                guard let line = terminal.displayHistoryLine(at: row) else { return [] }
                return [UInt64(UInt(bitPattern: ObjectIdentifier(line))), line.generation]
            }
            let key: UInt64
            let unchanged =
                signatures.indices.contains(position) && signatures[position] == signature
                && pageKeys.indices.contains(position)
            if unchanged {
                key = pageKeys[position]
                nextMemory[key] = memoryPages[key]
            } else {
                key = UInt64.random(in: 1...UInt64.max)
                let rows = terminal.displayHistoryRows(in: range)
                if retainsPages { nextMemory[key] = rows }
                let bytes = try Self.encode(rows)
                _ = try? await client.terminalDisplayCache(
                    terminalID: terminalID, operation: .write(key: key, sourceOffset: sourceOffset, bytes: bytes))
            }
            keys.append(key)
            counts.append(range.count)
            nextSignatures.append(signature)
        }
        let index = TerminalDisplayIndex(
            terminalID: terminalID, sourceOffset: sourceOffset, columns: terminal.cols, screenRows: terminal.rows,
            cursorColumn: terminal.getCursorLocation().x, cursorRow: terminal.getCursorLocation().y,
            clearsHistory: clearsHistory ?? (terminal.displayHistoryEpoch > 0), count: count, pages: keys,
            pageCounts: counts)
        // Publish the directory only after its pages. Interrupted writes leave the old directory valid.
        try Task.checkCancellation()
        _ = try? await client.terminalDisplayCache(
            terminalID: terminalID, operation: .write(key: 0, sourceOffset: sourceOffset, bytes: try Self.encode(index))
        )
        try Task.checkCancellation()
        signatures = nextSignatures
        pageKeys = keys
        memoryPages = nextMemory
        return index
    }

    nonisolated private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let bytes = try encoder.encode(value)
        return try (bytes as NSData).compressed(using: .lzfse) as Data
    }

    nonisolated private static func decode<T: Decodable>(_ type: T.Type, _ bytes: Data) throws -> T {
        // Core caps compressed pages; refuse excessive expansion before decoding cells.
        let data = try (bytes as NSData).decompressed(using: .lzfse) as Data
        guard data.count <= 16 * 1024 * 1024 else { throw HistoryError.expired }
        return try PropertyListDecoder().decode(type, from: data)
    }

    enum HistoryError: Error { case expired }
}
