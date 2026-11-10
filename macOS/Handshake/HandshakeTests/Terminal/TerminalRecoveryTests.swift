import Foundation
import SwiftTerm
import SwiftUI
import Testing

@testable import Handshake

@MainActor
struct TerminalRecoveryTests {
    @Test func transientOutputFailureDoesNotStopTheSameViewOrItsInput() async throws {
        var snapshot = CoreSnapshot.testReady()
        snapshot.terminals = [.init(terminalID: 41, status: .running)]
        let transport = RecoveryTransport(snapshot: snapshot)
        await transport.setOutputUnavailable(true)
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await client.waitUntilRunning()
        var failure: String?
        let controller = TerminalController(
            coreClient: client, terminalID: 41,
            failureMessage: Binding(get: { failure }, set: { failure = $0 }))
        let view = MetalTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        view.terminalDelegate = controller
        controller.start(view: view)
        defer { controller.stop() }
        try await waitUntil { failure != nil }
        await transport.setOutputUnavailable(false)
        await transport.enqueue(.init(terminalID: 41, offset: 0, bytes: Data("recovered output".utf8)))
        try await waitUntil {
            String(data: view.getTerminal().getBufferAsData(), encoding: .utf8)?.contains("recovered output") == true
        }
        view.insertText("still interactive", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await waitUntil { await transport.input == Data("still interactive".utf8) }
        #expect(client.runState == .running)
    }

    @Test func abandonedOutputDoesNotStarveAnotherPaneAndGapReplayAnswersQueries() async throws {
        var snapshot = CoreSnapshot.testReady()
        snapshot.terminals = [.init(terminalID: 41, status: .running), .init(terminalID: 99, status: .running)]
        let transport = RecoveryTransport(snapshot: snapshot)
        let prefix = Data("\u{1B}[6nreplayed prefix ".utf8)
        await transport.replay(prefix, failingOnce: true)
        await transport.enqueue(.init(terminalID: 99, offset: 0, bytes: Data(repeating: 120, count: 1024 * 1024 + 1)))
        await transport.enqueue(.init(terminalID: 41, offset: UInt64(prefix.count), bytes: Data("live tail".utf8)))
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await client.waitUntilRunning()
        let controller = TerminalController(coreClient: client, terminalID: 41, failureMessage: .constant(nil))
        let view = MetalTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        view.terminalDelegate = controller
        controller.start(view: view)
        defer { controller.stop() }
        try await waitUntil {
            String(data: view.getTerminal().getBufferAsData(), encoding: .utf8)?.contains("replayed prefix live tail")
                == true
        }
        try await waitUntil { !(await transport.responses).isEmpty }
        #expect(await transport.replayReads >= 2)
        #expect(client.runState == .running)
    }
}
