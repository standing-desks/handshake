import AppKit
import Foundation
import SwiftTerm
import Testing

@testable import Handshake

@MainActor
struct TerminalCursorStyleTests {
    @Test(arguments: [
        ("block", CoreTerminalConfig.CursorStyle.block),
        ("underline", CoreTerminalConfig.CursorStyle.underline),
        ("bar", CoreTerminalConfig.CursorStyle.bar),
    ])
    func cursorStyleDecodesFromJSON(value: String, expected: CoreTerminalConfig.CursorStyle) throws {
        let json =
            "{\"font_family\":\"\",\"font_size\":13,\"cursor_style\":\"\(value)\",\"cursor_blink\":true,\"colors\":{}}"
        let config = try JSONDecoder().decode(CoreTerminalConfig.self, from: Data(json.utf8))
        #expect(config.cursorStyle == expected)
        #expect(config.cursorBlink == true)
    }

    @Test func applyCursorStyleSetsTheTerminalCursorShape() {
        let terminal = MetalTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        terminal.automaticallyFocuses = false
        terminal.applyCursorStyle(.block, blink: true)
        #expect(terminal.getTerminal().options.cursorStyle == .blinkBlock)
        terminal.applyCursorStyle(.underline, blink: true)
        #expect(terminal.getTerminal().options.cursorStyle == .blinkUnderline)
        terminal.applyCursorStyle(.bar, blink: true)
        #expect(terminal.getTerminal().options.cursorStyle == .blinkBar)
    }

    @Test func blinkFalseProducesSteadyVariants() {
        let terminal = MetalTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        terminal.automaticallyFocuses = false
        terminal.applyCursorStyle(.block, blink: false)
        #expect(terminal.getTerminal().options.cursorStyle == .steadyBlock)
        terminal.applyCursorStyle(.underline, blink: false)
        #expect(terminal.getTerminal().options.cursorStyle == .steadyUnderline)
        terminal.applyCursorStyle(.bar, blink: false)
        #expect(terminal.getTerminal().options.cursorStyle == .steadyBar)
    }

    @Test func applyCursorStyleDoesNotOverrideTerminalChangesWhenConfigIsUnchanged() {
        let terminal = MetalTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        terminal.automaticallyFocuses = false
        terminal.applyCursorStyle(.block, blink: true)
        #expect(terminal.getTerminal().options.cursorStyle == .blinkBlock)
        // Simulate a terminal app (e.g. vim) changing the cursor via escape code
        terminal.getTerminal().setCursorStyle(.steadyBar)
        #expect(terminal.getTerminal().options.cursorStyle == .steadyBar)
        // SwiftUI re-renders with the same config — must not override vim's cursor
        terminal.applyCursorStyle(.block, blink: true)
        #expect(terminal.getTerminal().options.cursorStyle == .steadyBar)
    }

    @Test func clientResolvesCursorStyleFromTheCoreSnapshot() async throws {
        let transport = DelayedStartTransport(
            snapshot: .testReady(terminal: .init(fontFamily: "", fontSize: 13, cursorStyle: .bar))
        )
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await client.waitUntilRunning()
        #expect(client.terminalCursorStyle == .bar)
        #expect(client.terminalCursorBlink == true)
    }

    @Test func clientResolvesCursorBlinkFromTheCoreSnapshot() async throws {
        let transport = DelayedStartTransport(
            snapshot: .testReady(terminal: .init(fontFamily: "", fontSize: 13, cursorBlink: false))
        )
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await client.waitUntilRunning()
        #expect(client.terminalCursorBlink == false)
    }
}
