import SwiftUI

/// Agent connections and run actions, shared by the Tabs and Bento terminal strips.
struct WorkflowRunControls: View {
    @Environment(CoreClient.self) private var client
    let workflowID: UInt64
    let run: CoreWorkflowRun
    let selectedAgentID: UInt64?
    let reportFailure: (String) -> Void
    var didChangeConnection: () -> Void = {}
    @State private var showsGraph = false
    @State private var showsResults = false

    private var hasLiveAgents: Bool {
        run.agents.contains { $0.harnessRunning == true }
    }

    private var recoveryTarget: (workflow: CoreWorkflow, agent: CoreAgent)? {
        guard let selectedAgentID,
            let workflow = client.snapshot?.workflows.workflows.first(where: { $0.id == workflowID }),
            let agent = workflow.agents.first(where: { $0.id == selectedAgentID }),
            run.agents.first(where: { $0.id == selectedAgentID })?.harness != .nouli,
            run.agents.first(where: { $0.id == selectedAgentID })?.harnessRunning == false
        else { return nil }
        return (workflow, agent)
    }

    @ViewBuilder private var recoveryControls: some View {
        if let target = recoveryTarget {
            ResumeAgentButton(workflow: target.workflow, agentID: target.agent.id)
            if client.terminalStatus(for: target.agent.terminalID) != .running {
                Button("Restart shell", systemImage: "terminal") {
                    Task {
                        do {
                            let receipt = try await client.send(
                                .recoverAgent(
                                    workflowID: workflowID,
                                    agentID: target.agent.id, session: nil, shellOnly: true))
                            if let error = receipt.error { reportFailure(error.message) }
                        } catch { reportFailure(error.localizedDescription) }
                    }
                }
            }
        }
    }

    var body: some View {
        HStack(spacing: AgentSubtabLayout.actionSpacing) {
            if run.agents.count > 1 {
                Button {
                    Task {
                        do {
                            try await client.setWorkflowAgentsDisconnected(
                                workflowID: workflowID, agentsDisconnected: !run.agentsDisconnected)
                            didChangeConnection()
                        } catch { reportFailure(error.localizedDescription) }
                    }
                } label: {
                    Label(
                        run.agentsDisconnected ? "Reconnect agents" : "Disconnect agents",
                        systemImage: "link")
                }
                .disabled(client.workflowModeChanges[workflowID] != nil)
                .help(
                    run.agentsDisconnected
                        ? "Restore workflow connections for new messages. Earlier work stays independent."
                        : "Stop handoffs between agents. Current work and conversations remain available."
                )
                .accessibilityLabel(run.agentsDisconnected ? "Reconnect agents" : "Disconnect agents")
                .accessibilityValue(run.agentsDisconnected ? "Disconnected" : "Connected")
                .accessibilityIdentifier("workflowAgentConnections")
            }
            recoveryControls
            if let type = run.workflowType {
                Button {
                    showsGraph.toggle()
                } label: {
                    Label(type.definition.name, systemImage: "flowchart")
                }
                .help("\(type.definition.name) workflow")
                .accessibilityLabel("Show \(type.definition.name) workflow graph")
                .accessibilityIdentifier("inspectWorkflowType")
                .popover(isPresented: $showsGraph) {
                    WorkflowTypeInspector(type: type, run: run)
                        .appZoom()
                }
            }
            if !run.outputs.isEmpty {
                Button("Results", systemImage: "checklist") { showsResults = true }
                    .help("Show workflow results").accessibilityIdentifier("workflowResults")
                    .popover(isPresented: $showsResults) {
                        WorkflowResultsPopover(workflowID: workflowID, run: run, reportFailure: reportFailure).appZoom()
                    }
            }
            if run.status == .running || hasLiveAgents {
                Button {
                    Task {
                        do { try await client.forceStopWorkflowAgents(workflowID: workflowID) } catch {
                            reportFailure(error.localizedDescription)
                        }
                    }
                } label: {
                    Label("Force stop agents", systemImage: "stop.fill")
                }
                .help("Force stop agents and their child processes. Their panes return to usable shells.")
                .accessibilityIdentifier("workflowForceStop")
            }
        }
        .labelStyle(.iconOnly)
        .controlSize(.small)

    }
}

#Preview {
    WorkflowRunControls(
        workflowID: 1,
        run: .init(
            generation: 1, stage: "Review", status: .running, message: nil, needsTask: false,
            agents: [.init(agentId: 1, active: true, done: false, reviewer: true, harness: .codex, targets: [])]),
        selectedAgentID: 1, reportFailure: { _ in }
    )
    .environment(CoreClient(transport: CoreWorker(dataDirectory: AppPaths.previewDirectory)))
    .frame(width: 650)
}
