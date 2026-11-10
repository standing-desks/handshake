import Foundation
import Testing

@testable import Handshake

@MainActor
struct WorkflowAgentConnectionTests {
    @Test func olderRunSnapshotsDefaultToAgentsDisconnectedOff() throws {
        let json = #"{"generation":2,"stage":"Review","status":"completed","needsTask":false,"agents":[]}"#
        let run = try JSONDecoder().decode(CoreWorkflowRun.self, from: Data(json.utf8))
        #expect(!run.agentsDisconnected)
        #expect(run.modeRevision == 0)
    }

    @Test(arguments: ["implementer", "reviewer"])
    func graphInputCanStartCoordinationInEitherConversation(role: String) async throws {
        var snapshot = Self.snapshot(agentsDisconnected: false, role: role)
        var definition = try #require(snapshot.workflows.workflows[0].run?.workflowType?.definition)
        definition.stages = []
        var graph = CoreWorkflowType.Graph()
        graph.edges = [.init(id: "work", from: "implementer", to: "reviewer", event: .done)]
        definition.graph = graph
        snapshot.workflows.workflows[0].run?.workflowType = .init(
            reference: .init(builtin: "adversarial"), definition: definition)
        let transport = WorkflowModeTransport(snapshot: snapshot)
        let client = CoreClient(transport: transport)
        client.start()
        try await client.waitUntilRunning()
        try await client.prepareWorkflowInput(workflowID: 3, agentID: 4)()
        try await client.writeTerminalInput(terminalID: 40, bytes: Data("task\r".utf8))
        #expect(await transport.continuations == [0])
        await client.stop()
    }

    @Test(arguments: [true, false])
    func modeCommandCarriesTheChoiceAndObservedRevisions(agentsDisconnected: Bool) throws {
        let envelope = CommandEnvelope(
            requestID: 1,
            command: .setWorkflowAgentsDisconnected(
                workflowID: 3, generation: 5, modeRevision: 2, agentsDisconnected: agentsDisconnected))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
        let command = try #require(object["command"] as? [String: Any])
        #expect(command["type"] as? String == "setWorkflowAgentsDisconnected")
        #expect(command["workflowId"] as? Int == 3)
        #expect(command["generation"] as? Int == 5)
        #expect(command["modeRevision"] as? Int == 2)
        #expect(command["agentsDisconnected"] as? Bool == agentsDisconnected)
    }

    @Test func privateQueuedInputStaysPrivateAfterTurningAgentsDisconnectedOff() async throws {
        let transport = WorkflowModeTransport(snapshot: Self.snapshot(agentsDisconnected: true))
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await client.waitUntilRunning()
        let privateInput = client.prepareWorkflowInput(workflowID: 3, agentID: 4)
        try await client.setWorkflowAgentsDisconnected(workflowID: 3, agentsDisconnected: false)
        try await privateInput()
        try await client.writeTerminalInput(terminalID: 40, bytes: Data("private\r".utf8))
        #expect(await transport.continuations.isEmpty)
        try await client.continueWorkflowIfNeeded(workflowID: 3, agentID: 4)
        try await client.writeTerminalInput(terminalID: 40, bytes: Data("fresh\r".utf8))
        #expect(await transport.continuations == [1])
    }

    @Test(arguments: [true, false])
    func inputDuringASwitchWaitsForAuthoritativeState(agentsDisconnected: Bool) async throws {
        let transport = WorkflowModeTransport(snapshot: Self.snapshot(agentsDisconnected: !agentsDisconnected))
        await transport.holdEvents()
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await client.waitUntilRunning()
        let switchTask = Task {
            try await client.setWorkflowAgentsDisconnected(workflowID: 3, agentsDisconnected: agentsDisconnected)
        }
        try await waitUntil { await transport.hasModeChange }
        #expect(client.snapshot?.workflows.workflows.first?.run?.agentsDisconnected == !agentsDisconnected)
        let preparation = client.prepareWorkflowInput(workflowID: 3, agentID: 4)
        var prepared = false
        let input = Task {
            try await preparation()
            prepared = true
        }
        await Task.yield()
        #expect(prepared)
        #expect(await transport.continuations.isEmpty)
        await transport.releaseEvents()
        try await switchTask.value
        try await input.value
        try await client.writeTerminalInput(terminalID: 40, bytes: Data("during switch\r".utf8))
        #expect(client.workflowModeChanges.isEmpty)
        #expect(client.snapshot?.workflows.workflows.first?.run?.agentsDisconnected == agentsDisconnected)
        #expect(await transport.continuations == (agentsDisconnected ? [] : [1]))
    }

    @Test func switchingModeDoesNotSkipConcurrentCommandCompletions() async throws {
        let transport = WorkflowModeTransport(snapshot: Self.snapshot(agentsDisconnected: false))
        await transport.holdEvents()
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await client.waitUntilRunning()
        var pingResult: CoreCommandResult?
        let ping = Task { pingResult = try await client.sendAndAwaitCompletion(.ping) }
        try await waitUntil { await transport.hasPing }
        let change = Task { try await client.setWorkflowAgentsDisconnected(workflowID: 3, agentsDisconnected: true) }
        try await waitUntil { await transport.hasModeChange }
        await transport.releaseEvents()
        try await waitUntil { pingResult != nil && client.workflowModeChanges.isEmpty }
        try await ping.value
        try await change.value
        #expect(pingResult == .pong)
    }

    @Test func anOlderWorkflowInputKeepsItsRevisionAcrossTwoSwitches() async throws {
        let transport = WorkflowModeTransport(snapshot: Self.snapshot(agentsDisconnected: false))
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await client.waitUntilRunning()
        let queued = client.prepareWorkflowInput(workflowID: 3, agentID: 4)
        try await client.setWorkflowAgentsDisconnected(workflowID: 3, agentsDisconnected: true)
        try await client.setWorkflowAgentsDisconnected(workflowID: 3, agentsDisconnected: false)
        try await queued()
        try await client.writeTerminalInput(terminalID: 40, bytes: Data("older\r".utf8))
        #expect(await transport.preparedRevisions == [0])
        #expect(await transport.continuations.isEmpty)
        try await client.continueWorkflowIfNeeded(workflowID: 3, agentID: 4)
        try await client.writeTerminalInput(terminalID: 40, bytes: Data("fresh\r".utf8))
        #expect(await transport.continuations == [2])
    }

    @Test func aRejectedSwitchKeepsThePreviousMode() async throws {
        let transport = WorkflowModeTransport(snapshot: Self.snapshot(agentsDisconnected: false))
        await transport.rejectSwitch()
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await client.waitUntilRunning()
        await #expect(throws: CoreFailure.self) {
            try await client.setWorkflowAgentsDisconnected(workflowID: 3, agentsDisconnected: true)
        }
        #expect(client.workflowModeChanges.isEmpty)
        #expect(client.snapshot?.workflows.workflows.first?.run?.agentsDisconnected == false)
    }

    private static func snapshot(agentsDisconnected: Bool, role: String = "implementer") -> CoreSnapshot {
        let type = CoreWorkflowType(
            reference: .init(builtin: "adversarial"),
            definition: .init(
                name: "Adversarial", description: "", roles: [],
                stages: [
                    .init(
                        id: "implement", name: "Implement", roles: ["implementer"],
                        completion: .init(rule: .allRolesDone))
                ]))
        let run = CoreWorkflowRun(
            generation: 2, stage: "Review", status: .completed, message: nil, needsTask: false,
            agents: [
                .init(
                    agentId: 4, active: false, done: true, reviewer: false, harness: .codex, targets: [],
                    role: role)
            ],
            workflowType: type, agentsDisconnected: agentsDisconnected)
        var snapshot = CoreSnapshot.testReady()
        snapshot.workflows.workflows = [
            .init(
                workflowID: 3, sessionID: 1, name: "Adversarial", kind: .agents, terminalID: 0,
                agents: [.init(agentID: 4, role: role, terminalID: 40)], status: .running,
                startedAt: 1, endedAt: 2, run: run)
        ]
        snapshot.terminals = [.init(terminalID: 40, status: .running)]
        return snapshot
    }
}

private actor WorkflowModeTransport {
    private var state: CoreSnapshot
    private var holdsEvents = false
    private var rejectsSwitch = false
    private var pendingEvents: [CoreEvent] = []
    private var nextRequestID: UInt64 = 1
    private(set) var continuations: [UInt64] = []
    private(set) var preparedRevisions: [UInt64] = []
    private(set) var hasModeChange = false
    private(set) var hasPing = false

    init(snapshot: CoreSnapshot) { state = snapshot }
    func holdEvents() { holdsEvents = true }
    func rejectSwitch() { rejectsSwitch = true }
    func releaseEvents() { holdsEvents = false }
    func open() -> CoreSnapshot { state }
    func close() {}
    func snapshot() -> CoreSnapshot { state }
    func send(_ command: CoreCommand) -> CoreCommandReceipt {
        let requestID = nextRequestID
        nextRequestID += 1
        switch command {
        case .setWorkflowAgentsDisconnected(_, _, _, let agentsDisconnected):
            if rejectsSwitch {
                return .init(
                    requestID: requestID, status: .rejected, error: .init(code: "stale", message: "The run changed."))
            }
            state.workflows.workflows[0].run?.agentsDisconnected = agentsDisconnected
            state.workflows.workflows[0].run?.modeRevision += 1
            state.sequence += 1
            hasModeChange = true
            pendingEvents.append(.init(sequence: state.sequence, event: .workflowChanged(state.workflows.workflows[0])))
        case .ping:
            state.sequence += 1
            hasPing = true
            pendingEvents.append(
                .init(sequence: state.sequence, event: .commandCompleted(requestID: requestID, result: .pong)))
        case .continueWorkflowRun(_, _, _, let revision):
            preparedRevisions.append(revision)
            let shouldCoordinate =
                state.workflows.workflows[0].run?.agentsDisconnected == false
                && state.workflows.workflows[0].run?.modeRevision == revision
            if shouldCoordinate {
                continuations.append(revision)
            }
        default: break
        }
        return .init(requestID: requestID, status: .accepted, error: nil)
    }
    func events(after sequence: UInt64, limit: UInt32) -> [CoreEvent] {
        holdsEvents ? [] : Array(pendingEvents.filter { $0.sequence > sequence }.prefix(Int(limit)))
    }
    func nextTerminalChunk() -> CoreTerminalChunk? { nil }
    func writeWorkflowInput(terminalID: UInt64, bytes: Data, context: CoreWorkflowInputContext) {
        preparedRevisions.append(context.modeRevision)
        let connected = state.workflows.workflows[0].run?.agentsDisconnected == false
        if connected && state.workflows.workflows[0].run?.modeRevision == context.modeRevision {
            continuations.append(context.modeRevision)
        }
    }
    func writeTerminalInput(terminalID: UInt64, bytes: Data) {}
    func resizeTerminal(terminalID: UInt64, size: CoreTerminalSize) {}
    func saveFile(_ request: FileSaveRequest) throws -> FileSaveResult { throw CoreFailure.invalidArgument }
    func pollFiles(_ request: FileBrowserRequest) throws -> FileBrowserSnapshot? { throw CoreFailure.invalidArgument }
}

extension WorkflowModeTransport: CoreTransport {}
