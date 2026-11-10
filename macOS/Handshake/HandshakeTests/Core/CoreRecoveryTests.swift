import Foundation
import Testing

@testable import Handshake

@MainActor
struct CoreRecoveryTests {
    @Test func failedCursorSnapshotRecoveryPreservesLiveTerminalAccess() async throws {
        var snapshot = CoreSnapshot.testReady()
        snapshot.terminals = [.init(terminalID: 41, status: .running)]
        let transport = RecoveryTransport(snapshot: snapshot)
        await transport.failCursorRecoveryOnce()
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await client.waitUntilRunning()
        try await waitUntil { client.snapshot?.sequence == 42 }
        #expect(await transport.snapshotReads >= 2)
        #expect(client.runState == .running)
        try await client.writeTerminalInput(terminalID: 41, bytes: Data("available".utf8))
        #expect(await transport.input == Data("available".utf8))
    }

    @Test func sameTerminalResumeNeverTreatsTheLiveShellAsClosedHistory() async throws {
        var snapshot = CoreSnapshot.testReady()
        snapshot.terminals = [.init(terminalID: 41, status: .running)]
        var workflow = CoreWorkflow(
            workflowID: 3, sessionID: 1, name: "Codex", kind: .singleAgent,
            harness: .codex, terminalID: 41, status: .exited, startedAt: 1, endedAt: nil)
        snapshot.workflows.workflows = [workflow]
        let transport = RecoveryTransport(snapshot: snapshot)
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await client.waitUntilRunning()
        workflow = CoreWorkflow(
            workflowID: 3, sessionID: 1, name: "Codex", kind: .singleAgent,
            harness: .codex, terminalID: 41, status: .running, startedAt: 1, endedAt: nil)
        workflow.restored = true
        workflow.terminalHistory = [.init(terminalID: 41, agentID: nil)]
        await transport.change(workflow)
        try await waitUntil { client.snapshot?.workflows.workflows.first?.restored == true }
        #expect(client.terminalStatus(for: 41) == .running)
        await transport.enqueue(.init(terminalID: 41, offset: 0, bytes: Data("resumed".utf8)))
        var received: CoreTerminalChunk?
        try await waitUntil {
            received = try? await client.nextTerminalChunk(for: 41)
            return received != nil
        }
        #expect(received?.bytes == Data("resumed".utf8))
        try await client.writeTerminalInput(terminalID: 41, bytes: Data("next prompt".utf8))
        #expect(await transport.input == Data("next prompt".utf8))
    }

    @Test(arguments: [true, false]) func recoveryEncodingKeepsTheSelectedAgentAndAction(shellOnly: Bool) throws {
        let envelope = CommandEnvelope(
            requestID: 1,
            command: .recoverAgent(
                workflowID: 3, agentID: 4,
                session: nil, shellOnly: shellOnly))
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
        let command = try #require(json["command"] as? [String: Any])
        #expect(command["type"] as? String == "recoverAgent")
        #expect(command["agentId"] as? Int == 4)
        #expect(command["shellOnly"] as? Bool == shellOnly)
    }
}
