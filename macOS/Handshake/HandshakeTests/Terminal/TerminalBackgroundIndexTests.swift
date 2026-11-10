import AppKit
import SwiftTerm
import Testing

@testable import Handshake

@MainActor
struct TerminalBackgroundIndexTests {
    @Test func unchangedMarkersAndVisibilityDoNotReadHistoryAgain() async throws {
        let bytes = Data(("first\r\n" + String(repeating: "output\r\n", count: 8_000)).utf8)
        let transport = TranscriptFixtureTransport(bytes: bytes)
        let client = CoreClient(transport: transport)
        let view = MetalTerminalView(frame: .zero)
        view.resize(cols: 80, rows: 24)
        let state = TerminalMinimapState()
        state.view = view
        view.minimapState = state
        state.beginFeed()
        view.feed(byteArray: Array(bytes)[...])
        state.received(through: UInt64(bytes.count))
        state.refresh()
        let markers = [TerminalMinimapTests.marker(offset: 0)]
        await state.loadMarkers(markers, terminalID: 41, client: client)
        #expect(state.markerRows[7] == 0)
        let reads = await transport.readLimits.count
        for _ in 0..<8 {
            view.setVisible(false)
            view.setVisible(true)
            await state.loadMarkers(markers, terminalID: 41, client: client)
        }
        #expect(await transport.readLimits.count == reads)
        #expect(state.markerRows[7] == 0)
    }

    @Test func liveMarkerWhileScrolledUpUsesTheLiveCursorBase() async throws {
        let transport = TranscriptFixtureTransport(bytes: nil)
        let client = CoreClient(transport: transport)
        let view = MetalTerminalView(frame: .zero)
        view.resize(cols: 80, rows: 24)
        let state = TerminalMinimapState()
        state.view = view
        view.minimapState = state
        let old = Array(String(repeating: "old output\r\n", count: 100).utf8)
        state.feed(old[...], offset: 0, into: view)
        state.refresh()
        view.scrollTo(row: 0)
        let next = Array("new command\r\nRESULT".utf8)
        let boundary = UInt64(old.count + "new command\r\n".utf8.count)
        await state.loadMarkers([TerminalMinimapTests.marker(offset: boundary)], terminalID: 41, client: client)
        let expected = view.getTerminal().liveCursorRow + 1
        state.feed(next[...], offset: UInt64(old.count), into: view)
        state.refresh()
        #expect(state.markerRows[7] == expected)
        #expect(TerminalMinimapGeometry.logicalLine(at: expected, in: view.getTerminal()) == "RESULT")
    }

    @Test func latePromptHookUsesItsRetainedBoundaryWithoutReadingTheTranscript() async {
        let transport = TranscriptFixtureTransport(bytes: nil)
        let client = CoreClient(transport: transport)
        let view = MetalTerminalView(frame: .zero)
        view.resize(cols: 80, rows: 24)
        let state = TerminalMinimapState()
        state.view = view
        let prefix = Array(
            (String(repeating: "earlier\r\n", count: 100)
                + "❯ Check output\r\n──────────\r\n? for shortcuts\r\n").utf8)
        state.feed(prefix[...], offset: 0, into: view)
        state.feed(Array("response\r\nlater\r\n".utf8)[...], offset: UInt64(prefix.count), into: view)
        await state.loadMarkers(
            [TerminalMinimapTests.marker(offset: UInt64(prefix.count))], terminalID: 41, client: client)
        #expect(state.markerRows[7] == 100)
        #expect(await transport.readLimits.isEmpty)
    }

    @Test func commandNavigationIncludesInputEvenAfterTheOutputMarkerWasCached() async throws {
        let input = "$ command\r\n"
        let bytes = Data((input + "result\r\n" + String(repeating: "later\r\n", count: 100)).utf8)
        let client = CoreClient(transport: TranscriptFixtureTransport(bytes: bytes))
        let view = MetalTerminalView(frame: .zero)
        view.resize(cols: 80, rows: 24)
        let state = TerminalMinimapState()
        state.view = view
        state.beginFeed()
        view.feed(byteArray: Array(bytes)[...])
        state.received(through: UInt64(bytes.count))
        state.refresh()
        let marker = TerminalMinimapTests.marker(offset: UInt64(input.utf8.count))
        let shell = CoreTraceLane(laneID: 3, workflowID: 1, name: "Shell", isAgent: false, role: nil, harness: nil)
        await state.loadMarkers(
            [.init(step: marker.step, lane: shell, event: marker.event)], terminalID: 41, client: client)
        #expect(state.markerRows[7] == 1)
        let anchor = try #require(marker.anchor)
        #expect(try await state.scroll(to: anchor, includingInput: true, client: client))
        #expect(view.getTerminal().getTopVisibleRow() == 0)
    }
}
