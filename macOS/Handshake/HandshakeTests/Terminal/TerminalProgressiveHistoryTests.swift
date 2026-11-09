import AppKit
import SwiftTerm
import SwiftUI
import Testing

@testable import Handshake

@MainActor
struct TerminalProgressiveHistoryTests {
    @Test func cachedTailAppearsBeforeOlderPagesWithoutReplayingTheTranscript() async throws {
        let bytes = Data(("FIRST_ROW\r\n" + String(repeating: "styled output\r\n", count: 4_000) + "LATEST_ROW").utf8)
        let transport = TranscriptFixtureTransport(bytes: bytes)
        let client = CoreClient(transport: transport)
        let first = TerminalHistoryWorker()
        _ = try await first.prepare(terminalID: 41, columns: 80, client: client)
        let reads = await transport.readLimits.count
        let reopened = TerminalHistoryWorker()
        let index = try await reopened.prepare(terminalID: 41, columns: 80, client: client)
        #expect(await transport.readLimits.count == reads + 1)
        let view = MetalTerminalView(frame: .zero)
        view.resize(cols: 80, rows: 24)
        let tail = try #require(index.pages.indices.last)
        view.getTerminal().replaceDisplayHistory(
            try await reopened.pageRows(index: index, page: tail, terminalID: 41, client: client))
        let initial = view.getTerminal().getBufferAsData()
        #expect(initial.contains(Data("LATEST_ROW".utf8)))
        #expect(!initial.contains(Data("FIRST_ROW".utf8)))
        for page in index.pages.indices.dropLast().reversed() {
            view.getTerminal().prependDisplayHistory(
                try await reopened.pageRows(index: index, page: page, terminalID: 41, client: client))
        }
        #expect(view.getTerminal().getBufferAsData().contains(Data("FIRST_ROW".utf8)))
        #expect(await transport.readLimits.count == reads + 1)
    }

    @Test func missingCachedPageFallsBackToCanonicalBytesAfterTheTailLoads() async throws {
        let bytes = Data(("FIRST_ROW\r\n" + String(repeating: "output\r\n", count: 500) + "LATEST_ROW").utf8)
        let transport = TranscriptFixtureTransport(bytes: bytes)
        let client = CoreClient(transport: transport)
        let worker = TerminalHistoryWorker()
        let index = try await worker.prepare(terminalID: 41, columns: 80, client: client)
        await transport.evictDisplayPage(terminalID: 41, key: try #require(index.pages.first))
        let view = MetalTerminalView(frame: .zero)
        view.resize(cols: 80, rows: 24)
        let offset = try await TerminalRestoration.restore(history: [], current: 41, client: client, view: view)
        #expect(offset == bytes.count)
        let text = view.getTerminal().getBufferAsData()
        #expect(text.contains(Data("FIRST_ROW".utf8)))
        #expect(text.contains(Data("LATEST_ROW".utf8)))
    }

    @Test(arguments: [20, 40])
    func resizeDuringPreparationReflowsBeforeInstallingRows(rows: Int) async throws {
        let bytes = Data(("A long line with emoji 👩🏽‍💻 and multiple wrapped words\r\n" + "last").utf8)
        let transport = TranscriptFixtureTransport(bytes: bytes, delayed: true)
        let client = CoreClient(transport: transport)
        let view = MetalTerminalView(frame: .zero)
        view.resize(cols: 80, rows: 24)
        let task = Task { try await TerminalRestoration.restore(history: [], current: 41, client: client, view: view) }
        try await waitUntil { await transport.hasPendingRead }
        view.resize(cols: 12, rows: rows)
        await transport.setDelayed(false)
        await transport.release()
        _ = try await task.value
        let expected = TerminalReplay()
        try expected.append(
            .init(
                offset: 0, nextOffset: UInt64(bytes.count), endOffset: UInt64(bytes.count),
                sizes: [.init(offset: 0, rows: 24, columns: 80)], bytes: bytes, replayAvailable: true))
        expected.terminal.resize(cols: 12, rows: rows)
        #expect(view.getTerminal().getBufferAsData() == expected.terminal.getBufferAsData())
    }

    @Test func clearingWhileHistoryWaitsRejectsStaleRows() async throws {
        let transport = TranscriptFixtureTransport(bytes: Data("OLD_HISTORY".utf8), delayed: true)
        let client = CoreClient(transport: transport)
        let view = MetalTerminalView(frame: .zero)
        let task = Task {
            try await TerminalRestoration.restore(history: [10], current: nil, client: client, view: view)
        }
        try await waitUntil { await transport.hasPendingRead }
        view.feed(text: "\u{1B}[3J\u{1B}[2J\u{1B}[HLIVE_PROMPT")
        await transport.setDelayed(false)
        await transport.release()
        do {
            _ = try await task.value
            Issue.record("A cleared buffer must reject stale historical pages")
        } catch is CancellationError {}
        #expect(!view.getTerminal().getBufferAsData().contains(Data("OLD_HISTORY".utf8)))
        #expect(view.getTerminal().getBufferAsData().contains(Data("LIVE_PROMPT".utf8)))
    }

    @Test func finalAlternateScreenIsRestoredAsReadOnlyContent() async throws {
        let bytes = Data("normal\r\n\u{1B}[?1049h\u{1B}[2J\u{1B}[HALTERNATE_FINAL 👩🏽‍💻".utf8)
        let client = CoreClient(transport: TranscriptFixtureTransport(bytes: bytes))
        let view = MetalTerminalView(frame: .zero)
        _ = try await TerminalRestoration.restore(history: [], current: 41, client: client, view: view)
        #expect(view.getTerminal().getBufferAsData().contains(Data("ALTERNATE_FINAL 👩🏽‍💻".utf8)))
        #expect(!view.getTerminal().isCurrentBufferAlternate)
    }

    @Test func parsedRowsPreserveStylesGraphemesAndTheLiveCursor() {
        let old = TerminalReplay()
        old.terminal.feed(text: "\u{1B}[31mred 👩🏽‍💻\u{1B}[0m\r\n")
        let rows = old.terminal.displayHistoryRows(in: 0..<1)
        let live = TerminalReplay()
        live.terminal.feed(text: "new prompt")
        let cursor = live.terminal.getCursorLocation()
        live.terminal.prependDisplayHistory(rows)
        #expect(live.terminal.getCursorLocation().x == cursor.x)
        #expect(live.terminal.getCursorLocation().y == cursor.y)
        #expect(live.terminal.bufferLine(atRow: 0)?[0].attribute.fg == .ansi256(code: 1))
        #expect(live.terminal.getBufferAsData().contains(Data("red 👩🏽‍💻".utf8)))
        #expect(live.terminal.getBufferAsData().contains(Data("new prompt".utf8)))
    }

    @Test func shortOutputFromATallerSavedScreenStaysVisibleInAShortPane() async throws {
        let transport = TranscriptFixtureTransport(bytes: Data("TOP_OF_TALL_SCREEN".utf8))
        let client = CoreClient(transport: transport)
        let worker = TerminalHistoryWorker()
        // Exercise the same normalization against a tall cached display and a short destination.
        _ = try await worker.prepare(terminalID: 41, columns: 80, rows: 100, client: client)
        let view = MetalTerminalView(frame: .zero)
        view.resize(cols: 80, rows: 20)
        _ = try await TerminalRestoration.restore(history: [], current: 41, client: client, view: view)
        let terminal = view.getTerminal()
        #expect(
            TerminalMinimapGeometry.logicalLine(at: terminal.getTopVisibleRow(), in: terminal) == "TOP_OF_TALL_SCREEN")
    }

    @Test func unavailableExitedTranscriptStopsRetryingAndReportsFailure() async throws {
        let transport = TranscriptFixtureTransport(
            bytes: Data("pruned".utf8), replayAvailable: false,
            chunks: [.init(terminalID: 41, offset: 0, bytes: Data("pruned".utf8))])
        let client = CoreClient(transport: transport)
        client.start()
        try await client.waitUntilRunning()
        defer { Task { await client.stop() } }
        var failure: String?
        let controller = TerminalController(
            coreClient: client, terminalID: 41,
            failureMessage: Binding(get: { failure }, set: { failure = $0 }))
        controller.restoresOutput = true
        let view = MetalTerminalView(frame: .zero)
        controller.start(view: view)
        defer { controller.stop() }
        try await waitUntil { failure != nil }
        let reads = await transport.readLimits.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(await transport.readLimits.count == reads)
        #expect(reads <= 2)
    }

    @Test func replacingAReadOnlyScreenTranslatesTheCursorToADifferentViewportHeight() {
        let source = TerminalReplay()
        source.terminal.resize(cols: 80, rows: 24)
        source.terminal.feed(text: String(repeating: "line\r\n", count: 100) + "\u{1B}[4;6H")
        let absolute = source.terminal.liveCursorRow
        let destination = TerminalReplay()
        destination.terminal.resize(cols: 80, rows: 40)
        destination.terminal.replaceDisplayHistory(
            source.terminal.displayHistoryRows(in: 0..<source.terminal.displayHistoryCount),
            cursorColumn: source.terminal.getCursorLocation().x, cursorRow: source.terminal.getCursorLocation().y,
            sourceRows: source.terminal.rows)
        #expect(destination.terminal.liveCursorRow == absolute)
        #expect(destination.terminal.getCursorLocation().x == 5)
    }

    @Test func exitTailArrivingDuringRestorationIsNotOverwritten() async throws {
        let first = Data("FIRST\r\n".utf8)
        let transport = TranscriptFixtureTransport(bytes: first, delayed: true)
        let client = CoreClient(transport: transport)
        client.start()
        try await client.waitUntilRunning()
        defer { Task { await client.stop() } }
        let view = MetalTerminalView(frame: .zero)
        let controller = TerminalController(coreClient: client, terminalID: 41, failureMessage: .constant(nil))
        controller.restoresOutput = true
        controller.start(view: view)
        defer { controller.stop() }
        try await waitUntil { await transport.hasPendingRead }
        let suffix = Data("EXIT_TAIL".utf8)
        await transport.replaceTranscript(terminalID: 41, bytes: first + suffix)
        await transport.enqueue(.init(terminalID: 41, offset: UInt64(first.count), bytes: suffix))
        await transport.setDelayed(false)
        await transport.release()
        try await waitUntil { view.getTerminal().getBufferAsData().contains(suffix) }
        #expect(view.getTerminal().getBufferAsData().contains(Data("FIRST".utf8)))
    }
}
