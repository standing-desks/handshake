import AppKit
import SwiftTerm
import SwiftUI
import Testing

@testable import Handshake

@MainActor
struct TerminalTraceNavigationTests {
    @Test func traceJumpSelectsAnEarlierCommandAfterBackgroundRestoration() async throws {
        let bytes = Data(("EARLY_COMMAND\r\n" + String(repeating: "later output\r\n", count: 8_000)).utf8)
        let transport = TranscriptFixtureTransport(bytes: bytes, delayed: true)
        let client = CoreClient(transport: transport)
        client.start()
        try await client.waitUntilRunning()
        defer { Task { await client.stop() } }
        let view = MetalTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let minimap = TerminalMinimapState()
        minimap.view = view
        view.minimapState = minimap
        let navigation = TraceTerminalNavigation()
        let hosting = NSHostingView(
            rootView: Color.clear.modifier(
                TerminalTraceNavigation(terminalID: 41, historyTerminalIDs: [], isVisible: true, minimap: minimap)
            ).environment(client).environment(navigation))
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        let controller = TerminalController(coreClient: client, terminalID: 41, failureMessage: .constant(nil))
        controller.restoresOutput = true
        view.terminalDelegate = controller
        controller.start(view: view)
        defer { controller.stop() }
        try await waitUntil { await transport.hasPendingRead }
        #expect(!view.isHidden)
        navigation.scrollTarget = TraceTerminalTarget(
            workflowID: 1, agentID: nil, anchor: .init(terminalID: 41, byteOffset: 0),
            timestamp: 1, message: "Earlier command")
        await transport.setDelayed(false)
        await transport.release()
        try await waitUntil { minimap.receivedOffset == UInt64(bytes.count) }
        try await waitUntil { !minimap.geometry.isLive }
        #expect(navigation.target == nil)
        #expect(
            TerminalMinimapGeometry.logicalLine(at: view.getTerminal().getTopVisibleRow(), in: view.getTerminal())
                == "EARLY_COMMAND")
    }
}
